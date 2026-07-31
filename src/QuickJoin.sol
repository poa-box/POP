// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/*────────────────────────── OpenZeppelin v5.3 Upgradeables ────────────────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/*───────────────────────── Interface minimal stubs ───────────────────────*/
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {WebAuthnLib} from "./libs/WebAuthnLib.sol";

interface IUniversalAccountRegistry {
    function getUsername(address account) external view returns (string memory);
    function registerAccountBySig(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external;
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

interface IExecutorHatMinter {
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
}

interface IUniversalPasskeyAccountFactory {
    function createAccount(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY, uint256 salt)
        external
        returns (address account);
}

/*──────────────────────────────  Contract  ───────────────────────────────*/
contract QuickJoin is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable {
    /* ───────── Errors ───────── */
    error InvalidAddress();
    error OnlyMasterDeploy();
    error ZeroUser();
    error NoUsername();
    error Unauthorized();
    error PasskeyFactoryNotSet();
    /// @dev H-03: a hat that is OPEN-TO-EVERYONE (default-eligible for an arbitrary address) must not
    ///      be mintable via the caller-specified claim paths — that is the H-03 self-mint escalation.
    error HatOpenlyClaimable(uint256 hatId);

    /* ───────── Constants ────── */
    bytes4 public constant MODULE_ID = bytes4(keccak256("QuickJoin"));

    /// @dev H-03: fixed probe address used to detect whether a hat is open-to-everyone. It is derived
    ///      from a domain-separated hash so it can never be a legitimate wearer/vouched address. If the
    ///      org's eligibility module reports THIS address as eligible for a hat, the hat is default-open
    ///      and self-mintable by anyone — so it is rejected on the claim paths. Gated hats (Delegate/
    ///      Agent) report this address as NOT eligible, so they pass the gate and are then subject to
    ///      the per-user eligibility check inside Hats.mintHat (reverts NotEligible if the caller isn't
    ///      actually vouched).
    address private constant _CLAIM_PROBE = address(uint160(uint256(keccak256("poa.quickjoin.claim.probe"))));

    /* ───────── ERC-7201 Storage ──────── */
    /// @custom:storage-location erc7201:poa.quickjoin.storage
    struct Layout {
        IHats hats;
        IUniversalAccountRegistry accountRegistry;
        address masterDeployAddress;
        address executor;
        uint256[] memberHatIds; // hat IDs to mint when users join
        IUniversalPasskeyAccountFactory universalFactory; // Universal factory for passkey accounts
    }

    /* ───────── Passkey Enrollment Struct ──────── */
    struct PasskeyEnrollment {
        bytes32 credentialId;
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        uint256 salt;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.quickjoin.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /* ───────── Events ───────── */
    event AddressesUpdated(address hats, address registry, address master);
    event ExecutorUpdated(address newExecutor);
    event MemberHatIdsUpdated(uint256[] hatIds);
    event QuickJoined(address indexed user, uint256[] hatIds);
    event QuickJoinedByMaster(address indexed master, address indexed user, uint256[] hatIds);
    event UniversalFactoryUpdated(address indexed universalFactory);
    event QuickJoinedWithPasskeyByMaster(
        address indexed master, address indexed account, bytes32 indexed credentialId, uint256[] hatIds
    );
    event RegisterAndQuickJoined(address indexed user, string username, uint256[] hatIds);
    event RegisterAndQuickJoinedWithPasskey(
        address indexed account, bytes32 indexed credentialId, string username, uint256[] hatIds
    );
    event RegisterAndQuickJoinedWithPasskeyByMaster(
        address indexed master, address indexed account, bytes32 indexed credentialId, string username, uint256[] hatIds
    );
    event HatsClaimed(address indexed user, uint256[] claimHatIds);
    event RegisterAndClaimedHats(address indexed user, string username, uint256[] claimHatIds);
    event RegisterAndClaimedHatsWithPasskey(
        address indexed account, bytes32 indexed credentialId, string username, uint256[] claimHatIds
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ───────── Initialiser ───── */
    function initialize(
        address executor_,
        address hats_,
        address accountRegistry_,
        address masterDeploy_,
        uint256[] calldata memberHatIds_
    ) external initializer {
        if (
            executor_ == address(0) || hats_ == address(0) || accountRegistry_ == address(0)
                || masterDeploy_ == address(0)
        ) revert InvalidAddress();

        __Context_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.executor = executor_;
        l.hats = IHats(hats_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.masterDeployAddress = masterDeploy_;

        // Set member hat IDs using HatManager
        for (uint256 i = 0; i < memberHatIds_.length; i++) {
            HatManager.setHatInArray(l.memberHatIds, memberHatIds_[i], true);
        }

        emit AddressesUpdated(hats_, accountRegistry_, masterDeploy_);
        emit ExecutorUpdated(executor_);
        emit MemberHatIdsUpdated(memberHatIds_);
    }

    /* ───────── Modifiers ─────── */
    modifier onlyMasterDeploy() {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && _msgSender() != l.masterDeployAddress) revert OnlyMasterDeploy();
        _;
    }

    modifier onlyExecutor() {
        if (_msgSender() != _layout().executor) revert Unauthorized();
        _;
    }

    /* ─────── Admin / DAO setters (executor-gated) ─────── */
    function updateAddresses(address hats_, address accountRegistry_, address masterDeploy_) external onlyExecutor {
        if (hats_ == address(0) || accountRegistry_ == address(0) || masterDeploy_ == address(0)) {
            revert InvalidAddress();
        }

        Layout storage l = _layout();
        l.hats = IHats(hats_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.masterDeployAddress = masterDeploy_;

        emit AddressesUpdated(hats_, accountRegistry_, masterDeploy_);
    }

    function updateMemberHatIds(uint256[] calldata memberHatIds_) external onlyExecutor {
        Layout storage l = _layout();

        // Clear existing hat IDs using HatManager
        HatManager.clearHatArray(l.memberHatIds);

        // Set new hat IDs using HatManager
        for (uint256 i = 0; i < memberHatIds_.length; i++) {
            HatManager.setHatInArray(l.memberHatIds, memberHatIds_[i], true);
        }

        emit MemberHatIdsUpdated(memberHatIds_);
    }

    function setExecutor(address newExec) external onlyExecutor {
        if (newExec == address(0)) revert InvalidAddress();
        _layout().executor = newExec;
        emit ExecutorUpdated(newExec);
    }

    function setUniversalFactory(address factory) external onlyMasterDeploy {
        _layout().universalFactory = IUniversalPasskeyAccountFactory(factory);
        emit UniversalFactoryUpdated(factory);
    }

    /* ───────── Internal helper ─────── */

    /// @dev H-03: reject any caller-specified claim hat that is OPEN-TO-EVERYONE (default-eligible for
    ///      an arbitrary address). Such a hat is self-mintable by anyone via this path — exactly the
    ///      H-03 escalation (e.g. the org's ELIGIBILITY_ADMIN hat, which is open by default). A GATED
    ///      hat (Delegate/Agent, defaults.eligible=false + vouching) is NOT rejected here: it is then
    ///      subject to the per-user check inside Hats.mintHat, which reverts NotEligible unless the
    ///      caller was actually vouched. Open base roles (Neighbor) are auto-minted via the normal join
    ///      path (memberHatIds), never claimed, so blocking them from the claim path breaks nothing.
    ///
    ///      Openness is detected by probing eligibility for `_CLAIM_PROBE`, a domain-separated sentinel
    ///      that can never be a legitimate wearer. If the probe reports eligible, the hat is open →
    ///      revert. FAIL CLOSED: if the eligibility probe reverts (module missing / non-conforming), the
    ///      hat's openness cannot be established, so it is rejected as well.
    ///
    ///      An EMPTY `claimHatIds` input is a no-op here (returns false); callers skip the mint,
    ///      preserving the pre-upgrade register-only behavior of the register+claim paths.
    /// @return hasHats True if at least one hat was requested (all passed the open-hat gate) and should
    ///         be minted.
    function _rejectOpenClaimHats(uint256[] calldata claimHatIds) private view returns (bool hasHats) {
        uint256 length = claimHatIds.length;
        if (length == 0) return false;
        IHats hatsContract = _layout().hats;
        for (uint256 i = 0; i < length; i++) {
            uint256 hatId = claimHatIds[i];
            // FAIL CLOSED: a reverting probe (module missing / non-conforming) is treated as
            // "cannot prove gated" → reject. A returned `true` means the hat is open → reject.
            try hatsContract.isEligible(_CLAIM_PROBE, hatId) returns (bool probeEligible) {
                if (probeEligible) revert HatOpenlyClaimable(hatId);
            } catch {
                revert HatOpenlyClaimable(hatId);
            }
        }
        return true;
    }

    function _quickJoin(address user) private nonReentrant {
        if (user == address(0)) revert ZeroUser();

        Layout storage l = _layout();

        // Request executor to mint all configured member hats to the user
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(user, l.memberHatIds);
        }

        emit QuickJoined(user, l.memberHatIds);
    }

    /* ───────── Public user paths ─────── */

    /// caller already registered a username elsewhere
    function quickJoinWithUser() external nonReentrant {
        Layout storage l = _layout();
        string memory existing = l.accountRegistry.getUsername(_msgSender());
        if (bytes(existing).length == 0) revert NoUsername();

        // Request executor to mint all configured member hats to the user
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(_msgSender(), l.memberHatIds);
        }

        emit QuickJoined(_msgSender(), l.memberHatIds);
    }

    /* ───────── Passkey join paths ─────── */

    /// @notice Master-deploy path for passkey onboarding
    /// @param passkey Passkey enrollment data
    /// @return account The created passkey account address
    function quickJoinWithPasskeyMasterDeploy(PasskeyEnrollment calldata passkey)
        external
        onlyMasterDeploy
        nonReentrant
        returns (address account)
    {
        Layout storage l = _layout();
        if (address(l.universalFactory) == address(0)) revert PasskeyFactoryNotSet();

        // 1. Create PasskeyAccount via universal factory (returns existing if already deployed)
        account = l.universalFactory
            .createAccount(passkey.credentialId, passkey.publicKeyX, passkey.publicKeyY, passkey.salt);

        // 2. Mint member hats to the account
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(account, l.memberHatIds);
        }

        emit QuickJoinedWithPasskeyByMaster(_msgSender(), account, passkey.credentialId, l.memberHatIds);
    }

    /* ───────── Register + join paths ─────── */

    /// @notice Register a username and join the org in one transaction (EOA users).
    /// @dev The sponsor (msg.sender) pays gas; the user proves consent via EIP-712 signature.
    /// @param user      The EOA address to register and onboard.
    /// @param username  The desired username.
    /// @param deadline  Signature expiration timestamp.
    /// @param nonce     The user's current nonce on the registry.
    /// @param signature The user's EIP-712 signature authorizing registration.
    function registerAndQuickJoin(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant {
        if (user == address(0)) revert ZeroUser();

        Layout storage l = _layout();

        // 1. Register the username via signature (reverts if sig invalid)
        l.accountRegistry.registerAccountBySig(user, username, deadline, nonce, signature);

        // 2. Mint member hats
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(user, l.memberHatIds);
        }

        emit RegisterAndQuickJoined(user, username, l.memberHatIds);
    }

    /// @notice Create a passkey account, register a username, and join the org in one transaction.
    /// @dev The sponsor pays gas; the user proves consent via WebAuthn passkey assertion.
    ///      The account address is derived from the passkey enrollment data (never passed in).
    /// @param passkey   Passkey enrollment data (credentialId, publicKeyX, publicKeyY, salt).
    /// @param username  The desired username for the new passkey account.
    /// @param deadline  Assertion expiration timestamp.
    /// @param nonce     The account's current nonce on the registry.
    /// @param auth      The WebAuthn assertion data proving passkey ownership.
    /// @return account  The created/existing passkey account address.
    function registerAndQuickJoinWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth
    ) external nonReentrant returns (address account) {
        Layout storage l = _layout();
        if (address(l.universalFactory) == address(0)) revert PasskeyFactoryNotSet();

        // 1. Register the username via passkey sig (reverts if invalid)
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

        // 2. Create PasskeyAccount (returns existing if already deployed)
        account = l.universalFactory
            .createAccount(passkey.credentialId, passkey.publicKeyX, passkey.publicKeyY, passkey.salt);

        // 3. Mint member hats
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(account, l.memberHatIds);
        }

        emit RegisterAndQuickJoinedWithPasskey(account, passkey.credentialId, username, l.memberHatIds);
    }

    /* ───────── Vouch-claim paths: mint caller-specified hats ─────── */

    /// @notice Claim specific hats for an EOA user who already has a username.
    /// @dev Used by vouch-first flow: user was vouched, now claims the specific hat(s).
    ///      Hats Protocol enforces eligibility via EligibilityModule — if the user
    ///      isn't vouched/eligible for a hat, mintHat reverts with NotEligible.
    /// @param claimHatIds Hat IDs to mint (e.g., the Executive hat the user was vouched for)
    function claimHatsWithUser(uint256[] calldata claimHatIds) external nonReentrant {
        Layout storage l = _layout();
        string memory existing = l.accountRegistry.getUsername(_msgSender());
        if (bytes(existing).length == 0) revert NoUsername();

        // H-03: reject any open-to-everyone (default-eligible) hat — those are self-mint escalations.
        // Gated hats pass here and are then gated per-user by Hats.mintHat (reverts NotEligible if the
        // caller wasn't vouched). An empty claimHatIds input is a no-op mint (backward-compatible).
        if (_rejectOpenClaimHats(claimHatIds)) {
            IExecutorHatMinter(l.executor).mintHatsForUser(_msgSender(), claimHatIds);
        }

        emit HatsClaimed(_msgSender(), claimHatIds);
    }

    /// @notice Register username + claim specific hats for an EOA user.
    /// @param user       The EOA address to register and mint hats to.
    /// @param username   The desired username.
    /// @param deadline   EIP-712 signature deadline.
    /// @param nonce      User's current nonce on the registry.
    /// @param signature  EIP-712 ECDSA signature for registration.
    /// @param claimHatIds Hat IDs to mint.
    function registerAndClaimHats(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature,
        uint256[] calldata claimHatIds
    ) external nonReentrant {
        if (user == address(0)) revert ZeroUser();

        // H-03: reject any open-to-everyone (default-eligible) hat — those are self-mint escalations.
        // Gated hats pass here and are then gated per-user by Hats.mintHat. An empty claimHatIds input
        // registers the username without minting (this path historically doubled as register-only).
        bool hasHats = _rejectOpenClaimHats(claimHatIds);

        Layout storage l = _layout();

        // 1. Register username
        l.accountRegistry.registerAccountBySig(user, username, deadline, nonce, signature);

        // 2. Mint claimed hats (skipped for an empty request)
        if (hasHats) {
            IExecutorHatMinter(l.executor).mintHatsForUser(user, claimHatIds);
        }

        emit RegisterAndClaimedHats(user, username, claimHatIds);
    }

    /// @notice Create passkey account, register username, and claim specific hats.
    /// @param passkey    Passkey enrollment data.
    /// @param username   The desired username.
    /// @param deadline   Assertion expiration timestamp.
    /// @param nonce      Account's current nonce on the registry.
    /// @param auth       WebAuthn assertion data proving passkey ownership.
    /// @param claimHatIds Hat IDs to mint.
    /// @return account   The created/existing passkey account address.
    function registerAndClaimHatsWithPasskey(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth,
        uint256[] calldata claimHatIds
    ) external nonReentrant returns (address account) {
        Layout storage l = _layout();
        if (address(l.universalFactory) == address(0)) revert PasskeyFactoryNotSet();

        // H-03: reject any open-to-everyone (default-eligible) hat — those are self-mint escalations.
        // Gated hats pass here and are then gated per-user by Hats.mintHat. An empty claimHatIds input
        // creates the account + registers the username without minting.
        bool hasHats = _rejectOpenClaimHats(claimHatIds);

        // 1. Register username via passkey sig
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

        // 2. Create PasskeyAccount (returns existing if already deployed)
        account = l.universalFactory
            .createAccount(passkey.credentialId, passkey.publicKeyX, passkey.publicKeyY, passkey.salt);

        // 3. Mint claimed hats (skipped for an empty request)
        if (hasHats) {
            IExecutorHatMinter(l.executor).mintHatsForUser(account, claimHatIds);
        }

        emit RegisterAndClaimedHatsWithPasskey(account, passkey.credentialId, username, claimHatIds);
    }

    /// @notice Master-deploy path: create passkey account, register username, and join.
    function registerAndQuickJoinWithPasskeyMasterDeploy(
        PasskeyEnrollment calldata passkey,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        WebAuthnLib.WebAuthnAuth calldata auth
    ) external onlyMasterDeploy nonReentrant returns (address account) {
        Layout storage l = _layout();
        if (address(l.universalFactory) == address(0)) revert PasskeyFactoryNotSet();

        // 1. Register the username via passkey sig (reverts if invalid)
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

        // 2. Create PasskeyAccount
        account = l.universalFactory
            .createAccount(passkey.credentialId, passkey.publicKeyX, passkey.publicKeyY, passkey.salt);

        // 3. Mint member hats
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(account, l.memberHatIds);
        }

        emit RegisterAndQuickJoinedWithPasskeyByMaster(
            _msgSender(), account, passkey.credentialId, username, l.memberHatIds
        );
    }

    /* ───────── Master-deploy helper paths ─────── */

    function quickJoinNoUserMasterDeploy(address newUser) external onlyMasterDeploy {
        _quickJoin(newUser);
        emit QuickJoinedByMaster(_msgSender(), newUser, _layout().memberHatIds);
    }

    function quickJoinWithUserMasterDeploy(address newUser) external onlyMasterDeploy nonReentrant {
        if (newUser == address(0)) revert ZeroUser();
        Layout storage l = _layout();
        string memory existing = l.accountRegistry.getUsername(newUser);
        if (bytes(existing).length == 0) revert NoUsername();

        // Request executor to mint all configured member hats to the user
        if (l.memberHatIds.length > 0) {
            IExecutorHatMinter(l.executor).mintHatsForUser(newUser, l.memberHatIds);
        }

        emit QuickJoinedByMaster(_msgSender(), newUser, l.memberHatIds);
    }

    /* ───────── Misc view helpers ─────── */
    function memberHatIds() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().memberHatIds);
    }

    function hats() external view returns (IHats) {
        return _layout().hats;
    }

    function accountRegistry() external view returns (IUniversalAccountRegistry) {
        return _layout().accountRegistry;
    }

    function executor() external view returns (address) {
        return _layout().executor;
    }

    function masterDeployAddress() external view returns (address) {
        return _layout().masterDeployAddress;
    }

    /* ───────── Hat Management View Functions ─────────── */
    function memberHatCount() external view returns (uint256) {
        return HatManager.getHatCount(_layout().memberHatIds);
    }

    function isMemberHat(uint256 hatId) external view returns (bool) {
        return HatManager.isHatInArray(_layout().memberHatIds, hatId);
    }

    function universalFactory() external view returns (IUniversalPasskeyAccountFactory) {
        return _layout().universalFactory;
    }
}
