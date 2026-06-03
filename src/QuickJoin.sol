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
import {WebAuthnLib} from "./libs/WebAuthnLib.sol";
import {IRoleBundleHatter} from "./interfaces/IRoleBundleHatter.sol";

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

    /* ───────── Constants ────── */
    bytes4 public constant MODULE_ID = bytes4(keccak256("QuickJoin"));

    /* ───────── ERC-7201 Storage ──────── */
    /// @custom:storage-location erc7201:poa.quickjoin.storage
    struct Layout {
        IHats hats;
        IUniversalAccountRegistry accountRegistry;
        address masterDeployAddress;
        address executor;
        uint256[] memberHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        IUniversalPasskeyAccountFactory universalFactory; // Universal factory for passkey accounts
        // ─── Hats-native: single member role hat + RoleBundleHatter for bundle expansion ───
        uint256 memberHat; // member role hat granted on join (bundle expands to capability hats)
        IRoleBundleHatter roleBundleHatter; // routes mintRole through the hatter so bundles auto-mint
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
    event MemberHatUpdated(uint256 memberHat);
    event RoleBundleHatterUpdated(address indexed roleBundleHatter);
    event QuickJoined(address indexed user, uint256 memberHat);
    event QuickJoinedByMaster(address indexed master, address indexed user, uint256 memberHat);
    event UniversalFactoryUpdated(address indexed universalFactory);
    event QuickJoinedWithPasskeyByMaster(
        address indexed master, address indexed account, bytes32 indexed credentialId, uint256 memberHat
    );
    event RegisterAndQuickJoined(address indexed user, string username, uint256 memberHat);
    event RegisterAndQuickJoinedWithPasskey(
        address indexed account, bytes32 indexed credentialId, string username, uint256 memberHat
    );
    event RegisterAndQuickJoinedWithPasskeyByMaster(
        address indexed master,
        address indexed account,
        bytes32 indexed credentialId,
        string username,
        uint256 memberHat
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
    /// @param executor_ Org's Executor (governance entry point)
    /// @param hats_ Hats Protocol address
    /// @param accountRegistry_ Universal account registry for username lookups
    /// @param masterDeploy_ Address authorized to run master-deploy paths
    /// @param memberHat_ Member role hat granted on join; RoleBundleHatter expands the bundle
    /// @param roleBundleHatter_ Per-org RoleBundleHatter proxy
    function initialize(
        address executor_,
        address hats_,
        address accountRegistry_,
        address masterDeploy_,
        uint256 memberHat_,
        address roleBundleHatter_
    ) external initializer {
        if (
            executor_ == address(0) || hats_ == address(0) || accountRegistry_ == address(0)
                || masterDeploy_ == address(0)
        ) revert InvalidAddress();
        // roleBundleHatter may be address(0) during bootstrap; must be set via
        // setRoleBundleHatter before any actual join flow uses memberHat.

        __Context_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.executor = executor_;
        l.hats = IHats(hats_);
        l.accountRegistry = IUniversalAccountRegistry(accountRegistry_);
        l.masterDeployAddress = masterDeploy_;
        l.memberHat = memberHat_;
        l.roleBundleHatter = IRoleBundleHatter(roleBundleHatter_);

        emit AddressesUpdated(hats_, accountRegistry_, masterDeploy_);
        emit ExecutorUpdated(executor_);
        emit MemberHatUpdated(memberHat_);
        emit RoleBundleHatterUpdated(roleBundleHatter_);
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

    function setMemberHat(uint256 memberHat_) external onlyExecutor {
        _layout().memberHat = memberHat_;
        emit MemberHatUpdated(memberHat_);
    }

    function setRoleBundleHatter(address roleBundleHatter_) external onlyExecutor {
        if (roleBundleHatter_ == address(0)) revert InvalidAddress();
        _layout().roleBundleHatter = IRoleBundleHatter(roleBundleHatter_);
        emit RoleBundleHatterUpdated(roleBundleHatter_);
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
    function _quickJoin(address user) private nonReentrant {
        if (user == address(0)) revert ZeroUser();
        _mintMemberRole(user);
    }

    /// @dev Routes member-role minting through RoleBundleHatter so the configured
    ///      capability-hat bundle gets auto-minted in the same call.
    function _mintMemberRole(address user) private {
        Layout storage l = _layout();
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, user);
        }
        emit QuickJoined(user, memberHat);
    }

    /* ───────── Public user paths ─────── */

    /// caller already registered a username elsewhere
    function quickJoinWithUser() external nonReentrant {
        Layout storage l = _layout();
        string memory existing = l.accountRegistry.getUsername(_msgSender());
        if (bytes(existing).length == 0) revert NoUsername();

        _mintMemberRole(_msgSender());
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

        // 2. Mint member role hat + bundle to the account via RoleBundleHatter
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, account);
        }

        emit QuickJoinedWithPasskeyByMaster(_msgSender(), account, passkey.credentialId, memberHat);
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

        // 2. Mint member role hat + bundle via RoleBundleHatter
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, user);
        }

        emit RegisterAndQuickJoined(user, username, memberHat);
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

        // 3. Mint member role hat + bundle via RoleBundleHatter
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, account);
        }

        emit RegisterAndQuickJoinedWithPasskey(account, passkey.credentialId, username, memberHat);
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

        if (claimHatIds.length > 0) {
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

        Layout storage l = _layout();

        // 1. Register username
        l.accountRegistry.registerAccountBySig(user, username, deadline, nonce, signature);

        // 2. Mint claimed hats
        if (claimHatIds.length > 0) {
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

        // 3. Mint claimed hats
        if (claimHatIds.length > 0) {
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

        // 3. Mint member role hat + bundle via RoleBundleHatter
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, account);
        }

        emit RegisterAndQuickJoinedWithPasskeyByMaster(_msgSender(), account, passkey.credentialId, username, memberHat);
    }

    /* ───────── Master-deploy helper paths ─────── */

    function quickJoinNoUserMasterDeploy(address newUser) external onlyMasterDeploy {
        _quickJoin(newUser);
        emit QuickJoinedByMaster(_msgSender(), newUser, _layout().memberHat);
    }

    function quickJoinWithUserMasterDeploy(address newUser) external onlyMasterDeploy nonReentrant {
        if (newUser == address(0)) revert ZeroUser();
        Layout storage l = _layout();
        string memory existing = l.accountRegistry.getUsername(newUser);
        if (bytes(existing).length == 0) revert NoUsername();

        // Mint member role hat + bundle via RoleBundleHatter
        uint256 memberHat = l.memberHat;
        if (memberHat != 0 && address(l.roleBundleHatter) != address(0)) {
            l.roleBundleHatter.mintRole(memberHat, newUser);
        }

        emit QuickJoinedByMaster(_msgSender(), newUser, memberHat);
    }

    /* ───────── Misc view helpers ─────── */
    /// @notice Backwards-compat array getter; returns single-element array with the
    ///         current member capability hat.
    function memberHatIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().memberHat;
    }

    function memberHat() external view returns (uint256) {
        return _layout().memberHat;
    }

    function roleBundleHatter() external view returns (address) {
        return address(_layout().roleBundleHatter);
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
        return 1;
    }

    function isMemberHat(uint256 hatId) external view returns (bool) {
        return hatId != 0 && hatId == _layout().memberHat;
    }

    function universalFactory() external view returns (IUniversalPasskeyAccountFactory) {
        return _layout().universalFactory;
    }
}
