// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/*────────────────────────── OpenZeppelin v5.3 Upgradeables ────────────────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/*───────────────────────── POP libs / interface stubs ───────────────────────*/
import {ValidationLib} from "./libs/ValidationLib.sol";
import {HatManager} from "./libs/HatManager.sol";
import {WebAuthnLib} from "./libs/WebAuthnLib.sol";

/*───────────────────────── ZK Email surface ────────────────────────*/
import {IZkEmailGroth16Verifier, ZkEmailProof} from "./zkemail/IVerifier.sol";
import {IDKIMRegistry} from "./zkemail/IDKIMRegistry.sol";

interface IExecutorHatMinter {
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
}

interface IUniversalAccountRegistry {
    function registerAccountByPasskeySig(
        bytes32 credentialId,
        bytes32 pubKeyX,
        bytes32 pubKeyY,
        uint256 salt,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth
    ) external;
}

interface IUniversalPasskeyAccountFactory {
    function createAccount(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY, uint256 salt)
        external
        returns (address account);
}

/**
 * @title  ZkEmailInvites
 * @notice Per-org module that lets an executor pre-authorize whole email domains to claim role hats
 *         by submitting a DKIM-backed ZK Email proof on-chain — generated entirely client-side.
 * @dev    Verification model (the `PopRoleClaim` Groth16 circuit, 3 public signals):
 *           1. `pubkeyHash`     — Poseidon hash of the sender's DKIM RSA pubkey. The on-chain
 *              `IDKIMRegistry` maps an allowlisted domain -> this hash, so the domain need not be
 *              extracted in-circuit: the submitter passes `proof.domainName` and the registry binds
 *              it to `pubkeyHash` (`isKeyHashValid`). A forged domain string fails that check.
 *           2. `emailNullifier` — `poseidon(poseidon(signature))`; per-org replay guard.
 *           3. `claimerAddress` — parsed in-circuit from the signed command
 *              "Claim POP role for 0x<addr>" and supplied on-chain as the third public signal
 *              (`uint256(uint160(claimer))`). This binds a proof to exactly one recipient, so a
 *              claim is permissionless to submit (gasless via PaymasterHub from a fresh
 *              `PasskeyAccount`, or as a plain EOA tx) yet can only ever mint to the bound address.
 *
 *         Per-email rules (`setEmailRule`) are retained as forward-compatible admin scaffolding but
 *         are NOT yet claimable: a strict per-email allowlist needs an in-circuit email-identity
 *         commitment, which the lean v1 circuit deliberately omits (Phase 5). Only domain rules are
 *         claimable today.
 *
 *         Same UX as the passkey QuickJoin: claim selectors are auto-whitelisted in `PaymasterHub`,
 *         so a freshly-deployed `PasskeyAccount` can claim a role gaslessly via ERC-4337.
 */
contract ZkEmailInvites is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable {
    using ValidationLib for address;

    /* ───────── Errors ───────── */
    error Unauthorized();
    error InvalidProof();
    error InvalidDKIMKey();
    error NullifierAlreadyUsed();
    error DomainNotAllowed();
    error RuleExpired();
    error EmptyHats();
    error EmptyDomain();
    error ZeroClaimer();
    error PasskeyFactoryNotSet();

    /* ───────── Constants ────── */
    bytes4 public constant MODULE_ID = bytes4(keccak256("ZkEmailInvites"));

    /* ───────── Passkey enrollment (mirrors QuickJoin shape) ───────── */
    struct PasskeyEnrollment {
        bytes32 credentialId;
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        uint256 salt;
    }

    /* ───────── Rule structs ───────── */
    struct DomainRule {
        uint256[] hatIds;
        uint64 expiry; // 0 = never expires
        bool exists;
    }

    struct EmailRule {
        uint256[] hatIds;
        uint64 expiry;
        bool exists;
        bool claimed; // one-shot (Phase 5: claim path)
    }

    /* ───────── Deploy-time rule inputs (set atomically in `initialize`) ───────── */
    /// @dev Hat IDs are pre-resolved by the caller (ModulesFactory resolves role-index bitmaps
    ///      to hat IDs). These let an org pre-load its allowlist at deploy time so no follow-up
    ///      governance call is needed before the first claim.
    struct InitDomainRule {
        string domain;
        uint256[] hatIds;
        uint64 expiry;
    }

    struct InitEmailRule {
        bytes32 emailHash; // commitment consumed by the Phase-5 per-email circuit
        uint256[] hatIds;
        uint64 expiry;
    }

    /* ───────── ERC-7201 Storage ──────── */
    /// @custom:storage-location erc7201:poa.zkemailinvites.storage
    struct Layout {
        address executor;
        IZkEmailGroth16Verifier verifier;
        IDKIMRegistry dkimRegistry;
        IUniversalAccountRegistry accountRegistry;
        IUniversalPasskeyAccountFactory universalFactory;
        mapping(bytes32 domainHash => DomainRule) domainRules;
        mapping(bytes32 emailHash => EmailRule) emailRules;
        mapping(bytes32 nullifier => bool) usedNullifiers;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.zkemailinvites.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /* ───────── Events ───────── */
    event DomainRuleSet(bytes32 indexed domainHash, uint256[] hatIds, uint64 expiry);
    event DomainRuleRemoved(bytes32 indexed domainHash);
    event EmailRuleSet(bytes32 indexed emailHash, uint256[] hatIds, uint64 expiry);
    event EmailRuleRemoved(bytes32 indexed emailHash);
    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event RegisteredAndClaimedByDomain(
        address indexed account,
        bytes32 indexed credentialId,
        string username,
        bytes32 indexed domainHash,
        uint256[] hatIds
    );
    event VerifierUpdated(address indexed verifier);
    event DKIMRegistryUpdated(address indexed registry);
    event AccountRegistryUpdated(address indexed registry);
    event UniversalFactoryUpdated(address indexed factory);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ───────── Initialiser ───── */
    /// @param domainRules_ Optional domain rules to pre-load (empty = none; add later via governance).
    /// @param emailRules_  Optional per-email rules to pre-load (empty = none; not claimable until Phase 5).
    function initialize(
        address executor_,
        address verifier_,
        address dkimRegistry_,
        address accountRegistry_,
        address universalFactory_,
        InitDomainRule[] calldata domainRules_,
        InitEmailRule[] calldata emailRules_
    ) external initializer {
        executor_.requireNonZeroAddress();
        verifier_.requireNonZeroAddress();
        dkimRegistry_.requireNonZeroAddress();
        accountRegistry_.requireNonZeroAddress();
        // universalFactory MAY be address(0) at init — matches QuickJoin's late-bind pattern.

        __Context_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.executor = executor_;
        l.verifier = IZkEmailGroth16Verifier(verifier_);
        l.dkimRegistry = IDKIMRegistry(dkimRegistry_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.universalFactory = IUniversalPasskeyAccountFactory(universalFactory_);

        // Emit the initial wiring as events (mirrors the setters) so indexers can observe config
        // from event logs rather than on-chain reads. (Init rules already emit below.)
        emit VerifierUpdated(verifier_);
        emit DKIMRegistryUpdated(dkimRegistry_);
        emit AccountRegistryUpdated(accountRegistry_);
        emit UniversalFactoryUpdated(universalFactory_);

        // Pre-load any deploy-time rules. Same validation as the executor-gated setters —
        // a malformed rule (empty domain / empty hats) reverts the whole deployment (loud).
        for (uint256 i; i < domainRules_.length; ++i) {
            _writeDomainRule(domainRules_[i].domain, domainRules_[i].hatIds, domainRules_[i].expiry);
        }
        for (uint256 i; i < emailRules_.length; ++i) {
            _writeEmailRule(emailRules_[i].emailHash, emailRules_[i].hatIds, emailRules_[i].expiry);
        }
    }

    /* ───────── Modifiers ─────── */
    modifier onlyExecutor() {
        if (_msgSender() != _layout().executor) revert Unauthorized();
        _;
    }

    /* ───────── Admin: rule management (executor-gated) ─────── */
    function setDomainRule(string calldata domain, uint256[] calldata hatIds, uint64 expiry) external onlyExecutor {
        _writeDomainRule(domain, hatIds, expiry);
    }

    function removeDomainRule(string calldata domain) external onlyExecutor {
        bytes32 dh = keccak256(bytes(_lower(domain)));
        delete _layout().domainRules[dh];
        emit DomainRuleRemoved(dh);
    }

    /// @dev Per-email rules are forward-compat scaffolding: settable now, claimable in Phase 5 once a
    ///      per-email circuit exposes an email-identity commitment matching `emailHash`.
    function setEmailRule(bytes32 emailHash, uint256[] calldata hatIds, uint64 expiry) external onlyExecutor {
        _writeEmailRule(emailHash, hatIds, expiry);
    }

    function removeEmailRule(bytes32 emailHash) external onlyExecutor {
        delete _layout().emailRules[emailHash];
        emit EmailRuleRemoved(emailHash);
    }

    function setVerifier(address v) external onlyExecutor {
        v.requireNonZeroAddress();
        _layout().verifier = IZkEmailGroth16Verifier(v);
        emit VerifierUpdated(v);
    }

    function setDKIMRegistry(address d) external onlyExecutor {
        d.requireNonZeroAddress();
        _layout().dkimRegistry = IDKIMRegistry(d);
        emit DKIMRegistryUpdated(d);
    }

    function setAccountRegistry(address r) external onlyExecutor {
        r.requireNonZeroAddress();
        _layout().accountRegistry = IUniversalAccountRegistry(r);
        emit AccountRegistryUpdated(r);
    }

    function setUniversalFactory(address f) external onlyExecutor {
        _layout().universalFactory = IUniversalPasskeyAccountFactory(f);
        emit UniversalFactoryUpdated(f);
    }

    /* ───────── User: bare claim path (user already has an account) ─────── */

    /// @notice Claim hats under a pre-registered domain rule.
    /// @param proof   ZK Email proof. `proof.domainName` matches an admin-registered domain rule and
    ///                must be the domain whose DKIM key hash is `proof.pubkeyHash`.
    /// @param claimer Address that receives the hats. Must equal the address bound in-circuit (the
    ///                third public signal), else the Groth16 check fails.
    function claimRoleByDomain(ZkEmailProof calldata proof, address claimer) external nonReentrant {
        bytes32 dh = _verifyProofCommon(proof, claimer);
        uint256[] storage hatIds = _consumeDomainRule(dh);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(claimer, hatIds);
        emit RoleClaimedByDomain(claimer, dh, hatIds, proof.emailNullifier);
    }

    /* ───────── User: combined register + claim path (first-time onboarding) ─────── */

    /// @notice Atomic onboarding: register username via WebAuthn sig + deploy `PasskeyAccount`
    ///         (idempotent if already deployed) + verify email proof + mint domain-rule hats.
    /// @dev    The email proof must be bound to the resulting `account` (in-circuit address signal).
    function registerAndClaimByDomainWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        ZkEmailProof calldata proof
    ) external nonReentrant returns (address account) {
        account = _registerAndCreateAccount(passkey, username, deadline, nonce, auth);
        bytes32 dh = _verifyProofCommon(proof, account);
        uint256[] storage hatIds = _consumeDomainRule(dh);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(account, hatIds);
        emit RegisteredAndClaimedByDomain(account, passkey.credentialId, username, dh, hatIds);
    }

    /* ───────── Internals ─────── */
    function _registerAndCreateAccount(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth
    ) private returns (address account) {
        Layout storage l = _layout();
        if (address(l.universalFactory) == address(0)) revert PasskeyFactoryNotSet();

        l.accountRegistry
            .registerAccountByPasskeySig(
                passkey.credentialId,
                passkey.publicKeyX,
                passkey.publicKeyY,
                passkey.salt,
                username,
                deadline,
                nonce,
                auth
            );
        // Idempotent: returns the existing address if the account is already deployed.
        account = l.universalFactory
            .createAccount(passkey.credentialId, passkey.publicKeyX, passkey.publicKeyY, passkey.salt);
    }

    /// @dev Verifies a claim: nullifier-fresh, DKIM key valid for the claimed domain, and the Groth16
    ///      proof binds `claimer` (signal[2]). Marks the nullifier used. Returns the domain hash.
    function _verifyProofCommon(ZkEmailProof calldata proof, address claimer) private returns (bytes32 dh) {
        if (claimer == address(0)) revert ZeroClaimer();
        Layout storage l = _layout();
        if (l.usedNullifiers[proof.emailNullifier]) revert NullifierAlreadyUsed();

        dh = keccak256(bytes(_lower(proof.domainName)));
        if (!l.dkimRegistry.isKeyHashValid(dh, proof.pubkeyHash)) revert InvalidDKIMKey();

        uint256[3] memory signals;
        signals[0] = uint256(proof.pubkeyHash);
        signals[1] = uint256(proof.emailNullifier);
        signals[2] = uint256(uint160(claimer));
        if (!l.verifier.verifyProof(proof.pA, proof.pB, proof.pC, signals)) revert InvalidProof();

        l.usedNullifiers[proof.emailNullifier] = true;
    }

    function _consumeDomainRule(bytes32 dh) private view returns (uint256[] storage) {
        DomainRule storage rule = _layout().domainRules[dh];
        if (!rule.exists) revert DomainNotAllowed();
        if (rule.expiry != 0 && block.timestamp > rule.expiry) revert RuleExpired();
        return rule.hatIds;
    }

    /// @dev Shared writer for domain rules. Used by the executor-gated `setDomainRule` and by
    ///      `initialize` (deploy-time pre-load). `memory` params so both calldata and
    ///      in-memory (init) callers can reuse it.
    function _writeDomainRule(string memory domain, uint256[] memory hatIds, uint64 expiry) private {
        if (bytes(domain).length == 0) revert EmptyDomain();
        if (hatIds.length == 0) revert EmptyHats();
        bytes32 dh = keccak256(bytes(_lower(domain)));
        DomainRule storage r = _layout().domainRules[dh];
        HatManager.clearHatArray(r.hatIds);
        for (uint256 i; i < hatIds.length; ++i) {
            HatManager.setHatInArray(r.hatIds, hatIds[i], true);
        }
        r.expiry = expiry;
        r.exists = true;
        emit DomainRuleSet(dh, hatIds, expiry);
    }

    /// @dev Shared writer for email rules. Resets `claimed` so re-issuing an invite is allowed.
    function _writeEmailRule(bytes32 emailHash, uint256[] memory hatIds, uint64 expiry) private {
        if (hatIds.length == 0) revert EmptyHats();
        EmailRule storage r = _layout().emailRules[emailHash];
        HatManager.clearHatArray(r.hatIds);
        for (uint256 i; i < hatIds.length; ++i) {
            HatManager.setHatInArray(r.hatIds, hatIds[i], true);
        }
        r.expiry = expiry;
        r.exists = true;
        r.claimed = false;
        emit EmailRuleSet(emailHash, hatIds, expiry);
    }

    /// @dev ASCII lowercase — domain names are ASCII per RFC 1035.
    function _lower(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 32);
            }
        }
        return string(b);
    }

    /* ───────── Views ─────── */
    function executor() external view returns (address) {
        return _layout().executor;
    }

    function verifier() external view returns (IZkEmailGroth16Verifier) {
        return _layout().verifier;
    }

    function dkimRegistry() external view returns (IDKIMRegistry) {
        return _layout().dkimRegistry;
    }

    function accountRegistry() external view returns (IUniversalAccountRegistry) {
        return _layout().accountRegistry;
    }

    function universalFactory() external view returns (IUniversalPasskeyAccountFactory) {
        return _layout().universalFactory;
    }

    function getDomainRule(bytes32 domainHash)
        external
        view
        returns (uint256[] memory hatIds, uint64 expiry, bool exists)
    {
        DomainRule storage r = _layout().domainRules[domainHash];
        return (HatManager.getHatArray(r.hatIds), r.expiry, r.exists);
    }

    function getEmailRule(bytes32 emailHash)
        external
        view
        returns (uint256[] memory hatIds, uint64 expiry, bool exists, bool claimed)
    {
        EmailRule storage r = _layout().emailRules[emailHash];
        return (HatManager.getHatArray(r.hatIds), r.expiry, r.exists, r.claimed);
    }

    function isNullifierUsed(bytes32 n) external view returns (bool) {
        return _layout().usedNullifiers[n];
    }
}
