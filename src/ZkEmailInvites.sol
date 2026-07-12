// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/*────────────────────────── OpenZeppelin v5.3 Upgradeables ────────────────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/*───────────────────────── POP libs / interface stubs ───────────────────────*/
import {ValidationLib} from "./libs/ValidationLib.sol";
import {WebAuthnLib} from "./libs/WebAuthnLib.sol";

/*───────────────────────── ZK Email surface ────────────────────────*/
import {
    IZkEmailGroth16Verifier,
    IZkEmailGroth16VerifierV2,
    ZkEmailProof,
    ZkEmailProofV2
} from "./zkemail/IVerifier.sol";
import {IDKIMRegistry} from "./zkemail/IDKIMRegistry.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

interface IExecutorHatMinter {
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
    /// @notice The org's Hats instance the Executor mints through (added as an Executor view getter).
    function hats() external view returns (IHats);
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
 * @notice Per-org module that lets members claim role hats by proving control of their email entirely
 *         client-side (ZK), gated by an org "allowed emails" allowlist that lives on IPFS and is
 *         committed on-chain by a single merkle root. Whole DOMAINS and SPECIFIC addresses are both
 *         supported. Verification is 100% on-chain — no relayer/oracle.
 *
 * @dev    Allowlist = a JSON file on IPFS (domains + specific emails -> role hat IDs). Its merkle root
 *         + CID are the on-chain `merkleRoot`/`allowlistCid` (set by the executor = governance, or at
 *         deploy). A claim carries a merkle proof for the claimer's entry; the contract verifies:
 *           - the Groth16 email proof (domain circuit: 4 signals; specific-email circuit: 5 signals),
 *             both exposing `fromDomainHash` — a Poseidon commitment to the PROVEN From-address domain,
 *           - the DKIM key for that PROVEN domain (`PoaDKIMRegistry.isKeyHashValid(fromDomainHash, ..)`),
 *           - the merkle proof that `(kind, identifier, hatIds)` is in the active allowlist root,
 *           - a single-use nullifier,
 *         then mints `hatIds` to the in-circuit-bound claimer. Two-phase authority: a metadata admin
 *         *stages* an allowlist in the org metadata (off-chain); the executor *activates* it here via
 *         `setActiveAllowlist` (governance), or the founder activates at deploy.
 *
 *         Leaf encoding matches OpenZeppelin `StandardMerkleTree` / `PaymentManager`:
 *         `keccak256(bytes.concat(keccak256(abi.encode(uint8 kind, bytes32 id, uint256[] hatIds))))`
 *         with `kind 0 = domain (id = fromDomainHash)`, `kind 1 = email (id = emailHash)`. Both ids are
 *         circuit-proven Poseidon commitments, so the domain is no longer caller-supplied (Blocker 2).
 *
 *         Dormant until a root is set (`merkleRoot == 0` -> every claim reverts), so a deployed-but-
 *         unactivated module is inert and existing org flows are unaffected.
 *
 *         NOTE (ERC-7201): this namespaced `Layout` was reshaped pre-mainnet (no production proxy holds
 *         the prior layout; Test6 re-initializes). After the first mainnet deploy this struct is
 *         APPEND-ONLY forever — never reorder/remove fields.
 */
contract ZkEmailInvites is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable {
    using ValidationLib for address;

    /* ───────── Errors ───────── */
    error Unauthorized();
    error InvalidProof();
    error InvalidDKIMKey();
    error NullifierAlreadyUsed();
    error AllowlistNotActive();
    error NotInAllowlist();
    error EmptyHats();
    error ZeroClaimer();
    error PasskeyFactoryNotSet();
    /// @dev H-03 parity: a hat that is OPEN-TO-EVERYONE (default-eligible for an arbitrary address) must
    ///      not be mintable via the email-claim path — that is the same self-mint escalation the audit
    ///      closed on QuickJoin (an allowlisted open hat like ELIGIBILITY_ADMIN → org takeover).
    error HatOpenlyClaimable(uint256 hatId);

    /* ───────── Constants ────── */
    bytes4 public constant MODULE_ID = bytes4(keccak256("ZkEmailInvites"));
    uint8 private constant LEAF_DOMAIN = 0;
    uint8 private constant LEAF_EMAIL = 1;

    /// @dev H-03 probe: a domain-separated sentinel that can never be a legitimate wearer/vouched
    ///      address. If the org's eligibility module reports it eligible for a hat, that hat is
    ///      default-open (self-mintable by anyone) and is rejected on the claim path. Gated role hats
    ///      report it NOT eligible, so they pass and remain subject to the per-user eligibility check
    ///      inside Hats.mintHat. Distinct constant from QuickJoin's — same construction, module-scoped.
    address private constant _CLAIM_PROBE = address(uint160(uint256(keccak256("poa.zkemailinvites.claim.probe"))));

    /* ───────── Passkey enrollment (mirrors QuickJoin shape) ───────── */
    struct PasskeyEnrollment {
        bytes32 credentialId;
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        uint256 salt;
    }

    /* ───────── ERC-7201 Storage ──────── */
    /// @custom:storage-location erc7201:poa.zkemailinvites.storage
    struct Layout {
        address executor;
        IZkEmailGroth16Verifier domainVerifier; // 3-signal (PopRoleClaim)
        IZkEmailGroth16VerifierV2 emailVerifier; // 4-signal (PopRoleClaimV2)
        IDKIMRegistry dkimRegistry;
        IUniversalAccountRegistry accountRegistry;
        IUniversalPasskeyAccountFactory universalFactory;
        bytes32 merkleRoot; // active allowlist root (0 = dormant)
        bytes32 allowlistCid; // active allowlist IPFS CID digest (bytes32 of the CIDv0)
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
    event ActiveAllowlistSet(bytes32 indexed merkleRoot, bytes32 indexed allowlistCid);
    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event RoleClaimedByEmail(address indexed claimer, bytes32 indexed emailHash, uint256[] hatIds, bytes32 nullifier);
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
        bytes32 indexed emailHash,
        uint256[] hatIds
    );
    event DomainVerifierUpdated(address indexed verifier);
    event EmailVerifierUpdated(address indexed verifier);
    event DKIMRegistryUpdated(address indexed registry);
    event AccountRegistryUpdated(address indexed registry);
    event UniversalFactoryUpdated(address indexed factory);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ───────── Initialiser ───── */
    /// @param initialRoot Optional active allowlist root at deploy (0 = dormant; activate later via governance).
    /// @param initialCid  IPFS CID digest of the allowlist file `initialRoot` commits to (0 if dormant).
    function initialize(
        address executor_,
        address domainVerifier_,
        address emailVerifier_,
        address dkimRegistry_,
        address accountRegistry_,
        address universalFactory_,
        bytes32 initialRoot,
        bytes32 initialCid
    ) external initializer {
        executor_.requireNonZeroAddress();
        domainVerifier_.requireNonZeroAddress();
        emailVerifier_.requireNonZeroAddress();
        dkimRegistry_.requireNonZeroAddress();
        accountRegistry_.requireNonZeroAddress();
        // universalFactory MAY be address(0) at init — matches QuickJoin's late-bind pattern.

        __Context_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.executor = executor_;
        l.domainVerifier = IZkEmailGroth16Verifier(domainVerifier_);
        l.emailVerifier = IZkEmailGroth16VerifierV2(emailVerifier_);
        l.dkimRegistry = IDKIMRegistry(dkimRegistry_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.universalFactory = IUniversalPasskeyAccountFactory(universalFactory_);

        // Emit the initial wiring as events (mirrors the setters) so indexers read config from logs.
        emit DomainVerifierUpdated(domainVerifier_);
        emit EmailVerifierUpdated(emailVerifier_);
        emit DKIMRegistryUpdated(dkimRegistry_);
        emit AccountRegistryUpdated(accountRegistry_);
        emit UniversalFactoryUpdated(universalFactory_);

        // Optional deploy-time activation (founder configures email-join at genesis).
        if (initialRoot != bytes32(0)) {
            l.merkleRoot = initialRoot;
            l.allowlistCid = initialCid;
            emit ActiveAllowlistSet(initialRoot, initialCid);
        }
    }

    /* ───────── Modifiers ─────── */
    modifier onlyExecutor() {
        if (_msgSender() != _layout().executor) revert Unauthorized();
        _;
    }

    /* ───────── Admin (executor-gated = governance) ─────── */

    /// @notice Activate (or rotate) the org's allowlist. `root` commits to the allowlist JSON at `cid`.
    /// @dev    Set `root == 0` to dormant the module. This is the governance "activate" step; the
    ///         *proposed* allowlist is staged off-chain in the org metadata by a metadata admin.
    function setActiveAllowlist(bytes32 root, bytes32 cid) external onlyExecutor {
        Layout storage l = _layout();
        l.merkleRoot = root;
        l.allowlistCid = cid;
        emit ActiveAllowlistSet(root, cid);
    }

    function setDomainVerifier(address v) external onlyExecutor {
        v.requireNonZeroAddress();
        _layout().domainVerifier = IZkEmailGroth16Verifier(v);
        emit DomainVerifierUpdated(v);
    }

    function setEmailVerifier(address v) external onlyExecutor {
        v.requireNonZeroAddress();
        _layout().emailVerifier = IZkEmailGroth16VerifierV2(v);
        emit EmailVerifierUpdated(v);
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

    /// @notice Claim role hats for a whole-domain allowlist entry.
    /// @param proof      Domain ZK Email proof (binds `claimer` as signal[2]).
    /// @param claimer    Recipient (must equal the in-circuit-bound address).
    /// @param hatIds     The hat IDs this allowlist entry grants (must match the merkle leaf).
    /// @param merkleProof Proof that `(domain, hatIds)` is in the active allowlist root.
    function claimRoleByDomain(
        ZkEmailProof calldata proof,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        bytes32 dh = _claimDomain(proof, claimer, hatIds, merkleProof);
        emit RoleClaimedByDomain(claimer, dh, hatIds, proof.emailNullifier);
    }

    /// @notice Claim role hats for a SPECIFIC-address allowlist entry (uses the v2 circuit's `emailHash`).
    function claimRoleByEmail(
        ZkEmailProofV2 calldata proof,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        _claimEmail(proof, claimer, hatIds, merkleProof);
        emit RoleClaimedByEmail(claimer, proof.emailHash, hatIds, proof.emailNullifier);
    }

    /* ───────── User: combined register + claim paths (first-time passkey onboarding) ─────── */

    function registerAndClaimByDomainWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        ZkEmailProof calldata proof,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external nonReentrant returns (address account) {
        account = _registerAndCreateAccount(passkey, username, deadline, nonce, auth);
        bytes32 dh = _claimDomain(proof, account, hatIds, merkleProof);
        emit RegisteredAndClaimedByDomain(account, passkey.credentialId, username, dh, hatIds);
    }

    function registerAndClaimByEmailWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        ZkEmailProofV2 calldata proof,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external nonReentrant returns (address account) {
        account = _registerAndCreateAccount(passkey, username, deadline, nonce, auth);
        _claimEmail(proof, account, hatIds, merkleProof);
        emit RegisteredAndClaimedByEmail(account, passkey.credentialId, username, proof.emailHash, hatIds);
    }

    /* ───────── Internals ─────── */
    function _claimDomain(
        ZkEmailProof calldata proof,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) private returns (bytes32 dh) {
        Layout storage l = _layout();
        dh = _commonPreChecks(l, claimer, proof.emailNullifier, proof.fromDomainHash, proof.pubkeyHash, hatIds.length);

        uint256[4] memory signals;
        signals[0] = uint256(proof.pubkeyHash);
        signals[1] = uint256(proof.emailNullifier);
        signals[2] = uint256(uint160(claimer));
        signals[3] = uint256(proof.fromDomainHash);
        if (!l.domainVerifier.verifyProof(proof.pA, proof.pB, proof.pC, signals)) revert InvalidProof();

        _verifyLeaf(l.merkleRoot, _leaf(LEAF_DOMAIN, dh, hatIds), merkleProof);
        _rejectOpenClaimHats(l.executor, hatIds);
        l.usedNullifiers[proof.emailNullifier] = true;
        IExecutorHatMinter(l.executor).mintHatsForUser(claimer, hatIds);
    }

    function _claimEmail(
        ZkEmailProofV2 calldata proof,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) private {
        Layout storage l = _layout();
        // Domain still bound (anti-forgery: the PROVEN signing domain), but identity is `emailHash`.
        _commonPreChecks(l, claimer, proof.emailNullifier, proof.fromDomainHash, proof.pubkeyHash, hatIds.length);

        uint256[5] memory signals;
        signals[0] = uint256(proof.pubkeyHash);
        signals[1] = uint256(proof.emailNullifier);
        signals[2] = uint256(uint160(claimer));
        signals[3] = uint256(proof.emailHash);
        signals[4] = uint256(proof.fromDomainHash);
        if (!l.emailVerifier.verifyProof(proof.pA, proof.pB, proof.pC, signals)) revert InvalidProof();

        _verifyLeaf(l.merkleRoot, _leaf(LEAF_EMAIL, proof.emailHash, hatIds), merkleProof);
        _rejectOpenClaimHats(l.executor, hatIds);
        l.usedNullifiers[proof.emailNullifier] = true;
        IExecutorHatMinter(l.executor).mintHatsForUser(claimer, hatIds);
    }

    /// @dev H-03 parity gate. Reverts {HatOpenlyClaimable} if any requested hat is open-to-everyone
    ///      (the org's eligibility module marks the domain-separated {_CLAIM_PROBE} sentinel eligible).
    ///      FAIL CLOSED: a reverting probe (eligibility module missing / non-conforming) cannot prove the
    ///      hat is gated, so it is rejected too. Reads the Hats instance from the Executor (single source
    ///      of truth) rather than a duplicate field in this module's storage — so the fix ships as a pure
    ///      impl upgrade with no migration of already-deployed proxies.
    function _rejectOpenClaimHats(address executor_, uint256[] calldata hatIds) private view {
        IHats hatsContract = IExecutorHatMinter(executor_).hats();
        for (uint256 i; i < hatIds.length; ++i) {
            try hatsContract.isEligible(_CLAIM_PROBE, hatIds[i]) returns (bool probeEligible) {
                if (probeEligible) revert HatOpenlyClaimable(hatIds[i]);
            } catch {
                revert HatOpenlyClaimable(hatIds[i]);
            }
        }
    }

    /// @dev Cheap, shared pre-checks: non-zero claimer + hats, active allowlist, fresh nullifier, valid
    ///      DKIM key for the PROVEN From-domain. `fromDomainHash` is a circuit public signal (verified by
    ///      the Groth16 check in the caller), so the DKIM key is bound to the actual sending domain — not
    ///      a caller-supplied string. Returns it for use as the domain merkle-leaf identity.
    function _commonPreChecks(
        Layout storage l,
        address claimer,
        bytes32 nullifier,
        bytes32 fromDomainHash,
        bytes32 pubkeyHash,
        uint256 hatCount
    ) private view returns (bytes32 dh) {
        if (claimer == address(0)) revert ZeroClaimer();
        if (hatCount == 0) revert EmptyHats();
        if (l.merkleRoot == bytes32(0)) revert AllowlistNotActive();
        if (l.usedNullifiers[nullifier]) revert NullifierAlreadyUsed();
        dh = fromDomainHash;
        if (!l.dkimRegistry.isKeyHashValid(dh, pubkeyHash)) revert InvalidDKIMKey();
    }

    /// @dev OZ StandardMerkleTree leaf: double-keccak of abi.encode(kind, id, hatIds).
    function _leaf(uint8 kind, bytes32 id, uint256[] calldata hatIds) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _verifyLeaf(bytes32 root, bytes32 leaf, bytes32[] calldata merkleProof) private pure {
        if (!MerkleProof.verifyCalldata(merkleProof, root, leaf)) revert NotInAllowlist();
    }

    // (domain identity is now the circuit-proven `fromDomainHash` Poseidon commitment; the old ASCII
    //  `_lower` helper for hashing a caller-supplied domain string is no longer needed.)

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

    /* ───────── Views ─────── */
    function executor() external view returns (address) {
        return _layout().executor;
    }

    function domainVerifier() external view returns (IZkEmailGroth16Verifier) {
        return _layout().domainVerifier;
    }

    function emailVerifier() external view returns (IZkEmailGroth16VerifierV2) {
        return _layout().emailVerifier;
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

    function merkleRoot() external view returns (bytes32) {
        return _layout().merkleRoot;
    }

    function allowlistCid() external view returns (bytes32) {
        return _layout().allowlistCid;
    }

    function isNullifierUsed(bytes32 n) external view returns (bool) {
        return _layout().usedNullifiers[n];
    }
}
