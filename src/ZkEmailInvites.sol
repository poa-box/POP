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

/*───────────────────────── ZK Email vendored surface ────────────────────────*/
import {IVerifier, EmailProof} from "./zkemail/IVerifier.sol";
import {IDKIMRegistry} from "./zkemail/IDKIMRegistry.sol";
import {CommandUtils} from "./zkemail/CommandUtils.sol";

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
 * @notice Per-org module that lets an executor pre-authorize email addresses or whole domains
 *         to claim role hats by submitting a DKIM-backed ZK Email proof on-chain.
 * @dev    - Verification happens at claim time via an `IVerifier` (Groth16) and an `IDKIMRegistry`
 *           (ERC-7969 minimal interface) attached at init.
 *         - Same UX as the existing passkey QuickJoin: claim selectors are auto-whitelisted in
 *           `PaymasterHub`, so a freshly-deployed `PasskeyAccount` can claim a role gaslessly via
 *           ERC-4337.
 *         - Two binding mechanisms: per-domain wildcard ("anthropic.com -> MEMBER") and per-email
 *           commitment ("alice at anthropic.com -> CONTRIBUTOR" keyed on the proof's `accountSalt`,
 *           which is `Poseidon(emailAddress, accountCode)` derived off-chain by the admin).
 *         - Replay protection: per-org `usedNullifiers` mapping on `proof.emailNullifier`.
 *           Per-rule idempotency: per-email one-shot; per-domain one-shot-per-domain.
 *         - Address binding: the proof's `maskedCommand` must end with the `claimer` address as
 *           a "0x..." hex string (e.g. body or subject: "Claim POP role for 0xABC...").
 *         - Account code required: proofs MUST carry an embedded account code
 *           (`isCodeExist == true`). Otherwise `accountSalt` is not a real
 *           Poseidon(emailAddress, accountCode) commitment, which would break both per-email
 *           rule lookups and per-domain claim idempotency. Such proofs are rejected.
 *
 * Trust model
 * -----------
 *         - `accountSalt = Poseidon(emailAddress, accountCode)` is the proof's only deterministic
 *           binding to the email address. `accountCode` is user-chosen at proof-generation time.
 *           For **per-email rules** (`setEmailRule`) the admin computes `accountSalt` off-chain
 *           using a fixed, protocol-known `accountCode` — a user who rotates `accountCode` cannot
 *           produce a proof matching the stored salt, so the per-email allowlist is strict.
 *           For **per-domain rules** (`setDomainRule`) the same email + a different `accountCode`
 *           yields a different `accountSalt`, which means an adversarial user CAN re-claim the
 *           same domain rule with the same email under a new salt. Per-domain rules are therefore
 *           "good-faith one-per-(email, accountCode)" — strict one-claim-per-email would require
 *           a custom circuit exposing `hash(emailAddress)` directly.
 *
 * Re-set semantics
 * ----------------
 *         - `setEmailRule(salt, ...)` resets `EmailRule.claimed = false`, allowing the admin to
 *           explicitly re-issue an invitation for the same email (e.g. to upgrade the role).
 *         - `setDomainRule(domain, ...)` does NOT clear the per-`(accountSalt, domainHash)`
 *           entries in `claimedByDomain`. Re-setting a domain rule will not let prior claimers
 *           double-claim that domain. To intentionally allow a clean re-claim under a domain
 *           rule, the admin must update the domain *string* (different hash) or accept the
 *           sticky claim state.
 */
contract ZkEmailInvites is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable {
    using ValidationLib for address;

    /* ───────── Errors ───────── */
    error Unauthorized();
    error InvalidProof();
    error InvalidDKIMKey();
    error NullifierAlreadyUsed();
    error DomainNotAllowed();
    error EmailNotAllowed();
    error RuleExpired();
    error AlreadyClaimed();
    error AddressMismatch();
    error AccountCodeMissing();
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
        bool claimed; // one-shot
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
        bytes32 accountSalt;
        uint256[] hatIds;
        uint64 expiry;
    }

    /* ───────── ERC-7201 Storage ──────── */
    /// @custom:storage-location erc7201:poa.zkemailinvites.storage
    struct Layout {
        address executor;
        IVerifier verifier;
        IDKIMRegistry dkimRegistry;
        IUniversalAccountRegistry accountRegistry;
        IUniversalPasskeyAccountFactory universalFactory;
        mapping(bytes32 domainHash => DomainRule) domainRules;
        mapping(bytes32 accountSalt => EmailRule) emailRules;
        mapping(bytes32 nullifier => bool) usedNullifiers;
        // Per-email idempotency under a given domain rule: same email may not claim
        // under the same domain twice, but may claim across different domains.
        mapping(bytes32 accountSalt => mapping(bytes32 domainHash => bool)) claimedByDomain;
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
    event EmailRuleSet(bytes32 indexed accountSalt, uint256[] hatIds, uint64 expiry);
    event EmailRuleRemoved(bytes32 indexed accountSalt);
    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event RoleClaimedByEmail(address indexed claimer, bytes32 indexed accountSalt, uint256[] hatIds, bytes32 nullifier);
    event RegisteredAndClaimedByDomain(
        address indexed account,
        bytes32 indexed credentialId,
        string username,
        bytes32 indexed domainHash,
        uint256[] hatIds
    );
    event RegisteredAndClaimedByEmail(
        address indexed account,
        bytes32 indexed credentialId,
        string username,
        bytes32 indexed accountSalt,
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
    /// @param emailRules_  Optional per-email rules to pre-load (empty = none).
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
        l.verifier = IVerifier(verifier_);
        l.dkimRegistry = IDKIMRegistry(dkimRegistry_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.universalFactory = IUniversalPasskeyAccountFactory(universalFactory_);

        // Pre-load any deploy-time rules. Same validation as the executor-gated setters —
        // a malformed rule (empty domain / empty hats) reverts the whole deployment (loud).
        for (uint256 i; i < domainRules_.length; ++i) {
            _writeDomainRule(domainRules_[i].domain, domainRules_[i].hatIds, domainRules_[i].expiry);
        }
        for (uint256 i; i < emailRules_.length; ++i) {
            _writeEmailRule(emailRules_[i].accountSalt, emailRules_[i].hatIds, emailRules_[i].expiry);
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

    /// @dev accountSalt is Poseidon(emailAddress, accountCode) — admin derives off-chain using a
    ///      known accountCode (recommend `keccak256(orgId)` truncated to BN254 field size).
    function setEmailRule(bytes32 accountSalt, uint256[] calldata hatIds, uint64 expiry) external onlyExecutor {
        _writeEmailRule(accountSalt, hatIds, expiry);
    }

    function removeEmailRule(bytes32 accountSalt) external onlyExecutor {
        delete _layout().emailRules[accountSalt];
        emit EmailRuleRemoved(accountSalt);
    }

    function setVerifier(address v) external onlyExecutor {
        v.requireNonZeroAddress();
        _layout().verifier = IVerifier(v);
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

    /* ───────── User: bare claim paths (user already has an account) ─────── */

    /// @notice Claim hats under a pre-registered domain rule.
    /// @param proof   Email proof. `proof.domainName` matches an admin-registered domain rule.
    /// @param claimer Address that will receive the hats. Must equal the address encoded in the
    ///                trailing "0x…" hex of `proof.maskedCommand`.
    function claimRoleByDomain(EmailProof calldata proof, address claimer) external nonReentrant {
        _verifyProofCommon(proof, claimer);
        bytes32 dh = keccak256(bytes(_lower(proof.domainName)));
        uint256[] storage hatIds = _consumeDomainRule(dh, proof.accountSalt);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(claimer, hatIds);
        emit RoleClaimedByDomain(claimer, dh, hatIds, proof.emailNullifier);
    }

    /// @notice Claim hats under a pre-registered email rule.
    function claimRoleByEmail(EmailProof calldata proof, address claimer) external nonReentrant {
        _verifyProofCommon(proof, claimer);
        uint256[] storage hatIds = _consumeEmailRule(proof.accountSalt);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(claimer, hatIds);
        emit RoleClaimedByEmail(claimer, proof.accountSalt, hatIds, proof.emailNullifier);
    }

    /* ───────── User: combined register + claim paths (first-time onboarding) ─────── */

    /// @notice Atomic onboarding: register username via WebAuthn sig + deploy `PasskeyAccount`
    ///         (idempotent if already deployed) + verify email proof + mint domain-rule hats.
    /// @dev    The email proof's `maskedCommand` must encode the resulting `account` address.
    function registerAndClaimByDomainWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        EmailProof calldata proof
    ) external nonReentrant returns (address account) {
        account = _registerAndCreateAccount(passkey, username, deadline, nonce, auth);
        _verifyProofCommon(proof, account);

        bytes32 dh = keccak256(bytes(_lower(proof.domainName)));
        uint256[] storage hatIds = _consumeDomainRule(dh, proof.accountSalt);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(account, hatIds);
        emit RegisteredAndClaimedByDomain(account, passkey.credentialId, username, dh, hatIds);
    }

    /// @notice Atomic onboarding under a per-email rule.
    function registerAndClaimByEmailWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        EmailProof calldata proof
    ) external nonReentrant returns (address account) {
        account = _registerAndCreateAccount(passkey, username, deadline, nonce, auth);
        _verifyProofCommon(proof, account);

        uint256[] storage hatIds = _consumeEmailRule(proof.accountSalt);
        IExecutorHatMinter(_layout().executor).mintHatsForUser(account, hatIds);
        emit RegisteredAndClaimedByEmail(account, passkey.credentialId, username, proof.accountSalt, hatIds);
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

    function _verifyProofCommon(EmailProof calldata proof, address claimer) private {
        if (claimer == address(0)) revert ZeroClaimer();
        Layout storage l = _layout();
        if (l.usedNullifiers[proof.emailNullifier]) revert NullifierAlreadyUsed();

        bytes32 dh = keccak256(bytes(_lower(proof.domainName)));
        if (!l.dkimRegistry.isKeyHashValid(dh, proof.publicKeyHash)) revert InvalidDKIMKey();
        if (!l.verifier.verifyEmailProof(proof)) revert InvalidProof();

        // The account code must be embedded: accountSalt = Poseidon(emailAddress, accountCode).
        // When isCodeExist is false the code was absent, so accountSalt is not a trustworthy
        // (email, accountCode) commitment — which both email-rule lookups and per-domain claim
        // idempotency depend on. Checked after verifyEmailProof so isCodeExist is the proven value.
        if (!proof.isCodeExist) revert AccountCodeMissing();

        address bound = CommandUtils.extractTrailingEthAddr(proof.maskedCommand);
        if (bound != claimer) revert AddressMismatch();

        l.usedNullifiers[proof.emailNullifier] = true;
    }

    function _consumeDomainRule(bytes32 dh, bytes32 accountSalt) private returns (uint256[] storage) {
        Layout storage l = _layout();
        DomainRule storage rule = l.domainRules[dh];
        if (!rule.exists) revert DomainNotAllowed();
        if (rule.expiry != 0 && block.timestamp > rule.expiry) revert RuleExpired();
        if (l.claimedByDomain[accountSalt][dh]) revert AlreadyClaimed();
        l.claimedByDomain[accountSalt][dh] = true;
        return rule.hatIds;
    }

    function _consumeEmailRule(bytes32 accountSalt) private returns (uint256[] storage) {
        EmailRule storage rule = _layout().emailRules[accountSalt];
        if (!rule.exists) revert EmailNotAllowed();
        if (rule.expiry != 0 && block.timestamp > rule.expiry) revert RuleExpired();
        if (rule.claimed) revert AlreadyClaimed();
        rule.claimed = true;
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
    function _writeEmailRule(bytes32 accountSalt, uint256[] memory hatIds, uint64 expiry) private {
        if (hatIds.length == 0) revert EmptyHats();
        EmailRule storage r = _layout().emailRules[accountSalt];
        HatManager.clearHatArray(r.hatIds);
        for (uint256 i; i < hatIds.length; ++i) {
            HatManager.setHatInArray(r.hatIds, hatIds[i], true);
        }
        r.expiry = expiry;
        r.exists = true;
        r.claimed = false;
        emit EmailRuleSet(accountSalt, hatIds, expiry);
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

    function verifier() external view returns (IVerifier) {
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

    function getEmailRule(bytes32 accountSalt)
        external
        view
        returns (uint256[] memory hatIds, uint64 expiry, bool exists, bool claimed)
    {
        EmailRule storage r = _layout().emailRules[accountSalt];
        return (HatManager.getHatArray(r.hatIds), r.expiry, r.exists, r.claimed);
    }

    function isNullifierUsed(bytes32 n) external view returns (bool) {
        return _layout().usedNullifiers[n];
    }

    function hasEmailClaimedDomain(bytes32 accountSalt, bytes32 domainHash) external view returns (bool) {
        return _layout().claimedByDomain[accountSalt][domainHash];
    }
}
