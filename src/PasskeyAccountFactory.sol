// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/*──────────────────── OpenZeppelin ────────────────────────────────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/*──────────────────── Local Imports ────────────────────────────────────*/
import {PasskeyAccount} from "./PasskeyAccount.sol";

/**
 * @title PasskeyAccountFactory
 * @author POA Team
 * @notice Universal factory for deploying PasskeyAccount smart wallets
 * @dev Features:
 *      - CREATE2 deterministic deployment
 *      - Global POA-level configuration (guardian, recovery delay)
 *      - Counterfactual address computation
 *      - Integration with ERC-4337 EntryPoint
 *
 *      Architecture:
 *      - Uses ERC-7201 namespaced storage for upgrade safety
 *      - Deployed as infrastructure singleton (not per-org)
 *      - Creates PasskeyAccount instances as BeaconProxy
 *      - Governed by PoaManager
 */
contract PasskeyAccountFactory is Initializable {
    /*──────────────────────────── Structs ──────────────────────────────*/

    /**
     * @notice Global POA configuration
     * @param poaGuardian POA recovery guardian address
     * @param recoveryDelay Recovery delay in seconds
     * @param maxCredentialsPerAccount Maximum passkeys per account
     * @param paused Whether account creation is paused
     */
    struct GlobalConfig {
        address poaGuardian;
        uint48 recoveryDelay;
        uint8 maxCredentialsPerAccount;
        bool paused;
    }

    /*──────────────────────────── Constants ────────────────────────────*/

    /// @notice Default max credentials per account
    uint8 public constant DEFAULT_MAX_CREDENTIALS = 10;

    /// @notice Default recovery delay (7 days)
    uint48 public constant DEFAULT_RECOVERY_DELAY = 7 days;

    /// @notice Module identifier
    bytes4 public constant MODULE_ID = bytes4(keccak256("PasskeyAccountFactory"));

    /*──────────────────────── ERC-7201 Storage ──────────────────────────*/

    /// @custom:storage-location erc7201:poa.passkeyaccountfactory.storage
    struct Layout {
        // The beacon for PasskeyAccount proxies
        address accountBeacon;
        // The PoaManager that governs this factory
        address poaManager;
        // Global configuration
        GlobalConfig globalConfig;
        // Track deployed accounts
        mapping(address => bool) deployedAccounts;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.passkeyaccountfactory.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*──────────────────────────── Events ───────────────────────────────*/

    /// @notice Emitted when a new account is created
    event AccountCreated(address indexed account, bytes32 credentialId, address indexed owner);

    /// @notice Emitted when global config is updated
    event GlobalConfigUpdated(address guardian, uint48 recoveryDelay, uint8 maxCredentials);

    /// @notice Emitted when PoaManager is updated
    event PoaManagerUpdated(address indexed oldPoaManager, address indexed newPoaManager);

    /// @notice Emitted when factory is paused/unpaused
    event PausedStateChanged(bool paused);

    /*──────────────────────────── Errors ───────────────────────────────*/

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when factory is paused
    error Paused();

    /// @notice Thrown when account already exists
    error AccountExists();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when beacon is not set
    error BeaconNotSet();

    /*──────────────────────────── Modifiers ────────────────────────────*/

    /// @notice Restrict to PoaManager only
    modifier onlyPoaManager() {
        if (msg.sender != _layout().poaManager) revert Unauthorized();
        _;
    }

    /// @notice Ensure factory is not paused
    modifier whenNotPaused() {
        if (_layout().globalConfig.paused) revert Paused();
        _;
    }

    /*──────────────────────────── Constructor ──────────────────────────*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*──────────────────────────── Initializer ──────────────────────────*/

    /**
     * @notice Initialize the universal factory
     * @param poaManager_ The PoaManager that governs this factory
     * @param accountBeacon_ The beacon for PasskeyAccount proxies
     * @param poaGuardian_ The POA recovery guardian
     * @param recoveryDelay_ The recovery delay in seconds
     */
    function initialize(address poaManager_, address accountBeacon_, address poaGuardian_, uint48 recoveryDelay_)
        external
        initializer
    {
        if (poaManager_ == address(0)) revert ZeroAddress();
        if (accountBeacon_ == address(0)) revert ZeroAddress();

        Layout storage l = _layout();
        l.poaManager = poaManager_;
        l.accountBeacon = accountBeacon_;
        l.globalConfig = GlobalConfig({
            poaGuardian: poaGuardian_,
            recoveryDelay: recoveryDelay_ > 0 ? recoveryDelay_ : DEFAULT_RECOVERY_DELAY,
            maxCredentialsPerAccount: DEFAULT_MAX_CREDENTIALS,
            paused: false
        });

        emit PoaManagerUpdated(address(0), poaManager_);
        emit GlobalConfigUpdated(poaGuardian_, l.globalConfig.recoveryDelay, DEFAULT_MAX_CREDENTIALS);
    }

    /*──────────────────────────── Governance ──────────────────────────*/

    /**
     * @notice Update the POA guardian recorded in global config
     * @param newGuardian New guardian address
     * @dev M-06/H-04: this value is NO LONGER baked into new-account init data. It does not affect
     *      counterfactual addresses and grants no recovery power on any account. Recovery guardians
     *      are configured per-account via PasskeyAccount.addGuardian. Kept for informational use.
     */
    function setPoaGuardian(address newGuardian) external onlyPoaManager {
        Layout storage l = _layout();
        l.globalConfig.poaGuardian = newGuardian;
        emit GlobalConfigUpdated(newGuardian, l.globalConfig.recoveryDelay, l.globalConfig.maxCredentialsPerAccount);
    }

    /**
     * @notice Update the recovery delay recorded in global config
     * @param newDelay New recovery delay in seconds
     * @dev M-06: this value is NO LONGER baked into new-account init data and does not affect
     *      counterfactual addresses. Each account's recovery delay is managed per-account via
     *      PasskeyAccount.setRecoveryDelay (defaulting to the account's minimum).
     */
    function setRecoveryDelay(uint48 newDelay) external onlyPoaManager {
        Layout storage l = _layout();
        l.globalConfig.recoveryDelay = newDelay;
        emit GlobalConfigUpdated(l.globalConfig.poaGuardian, newDelay, l.globalConfig.maxCredentialsPerAccount);
    }

    /**
     * @notice Update the max credentials per account
     * @param maxCredentials New max credentials
     */
    function setMaxCredentials(uint8 maxCredentials) external onlyPoaManager {
        Layout storage l = _layout();
        l.globalConfig.maxCredentialsPerAccount = maxCredentials;
        emit GlobalConfigUpdated(l.globalConfig.poaGuardian, l.globalConfig.recoveryDelay, maxCredentials);
    }

    /**
     * @notice Pause or unpause account creation
     * @param paused Whether to pause
     */
    function setPaused(bool paused) external onlyPoaManager {
        _layout().globalConfig.paused = paused;
        emit PausedStateChanged(paused);
    }

    /**
     * @notice Update the PoaManager
     * @param newPoaManager New PoaManager address
     */
    function setPoaManager(address newPoaManager) external onlyPoaManager {
        if (newPoaManager == address(0)) revert ZeroAddress();

        Layout storage l = _layout();
        address oldPoaManager = l.poaManager;
        l.poaManager = newPoaManager;

        emit PoaManagerUpdated(oldPoaManager, newPoaManager);
    }

    /*──────────────────────────── Account Creation ────────────────────*/

    /**
     * @notice Create a new PasskeyAccount
     * @param credentialId Initial credential ID
     * @param pubKeyX Credential public key X coordinate
     * @param pubKeyY Credential public key Y coordinate
     * @param salt Additional salt for CREATE2
     * @return account The deployed account address
     */
    function createAccount(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY, uint256 salt)
        external
        whenNotPaused
        returns (address account)
    {
        Layout storage l = _layout();

        // Verify beacon is set
        if (l.accountBeacon == address(0)) revert BeaconNotSet();

        // Compute deterministic address
        account = getAddress(credentialId, pubKeyX, pubKeyY, salt);

        // Return existing if already deployed
        if (account.code.length > 0) {
            return account;
        }

        // Build initialization data.
        // M-06: NO mutable guardian/recovery-delay config is included, so the counterfactual
        // address is a pure function of (factory, credentialId, pubKeyX, pubKeyY, salt) and never
        // shifts when factory global config changes. Recovery config is set per-account, lazily.
        bytes memory initData = abi.encodeWithSelector(
            PasskeyAccount.initialize.selector,
            address(this), // factory
            credentialId,
            pubKeyX,
            pubKeyY
        );

        // Deploy via CREATE2
        bytes32 create2Salt = _computeSalt(credentialId, pubKeyX, pubKeyY, salt);

        account = address(new BeaconProxy{salt: create2Salt}(l.accountBeacon, initData));

        // Track deployment
        l.deployedAccounts[account] = true;

        emit AccountCreated(account, credentialId, msg.sender);
    }

    /**
     * @notice Compute the counterfactual address for an account
     * @param credentialId Initial credential ID
     * @param pubKeyX Credential public key X coordinate
     * @param pubKeyY Credential public key Y coordinate
     * @param salt Additional salt for CREATE2
     * @return account The predicted account address
     * @dev M-06: the returned address is a pure function of (credentialId, pubKeyX, pubKeyY, salt)
     *      and the immutable factory/beacon. It does NOT depend on any mutable global config
     *      (poaGuardian, recoveryDelay), so changing that config never moves an account address.
     */
    function getAddress(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY, uint256 salt)
        public
        view
        returns (address account)
    {
        Layout storage l = _layout();

        // Build initialization data — M-06: identical to createAccount's init data. It intentionally
        // excludes the mutable globalConfig (guardian/recoveryDelay), so getAddress is a pure
        // function of (credentialId, pubKeyX, pubKeyY, salt) and does not depend on factory config.
        bytes memory initData = abi.encodeWithSelector(
            PasskeyAccount.initialize.selector,
            address(this), // factory
            credentialId,
            pubKeyX,
            pubKeyY
        );

        // Compute bytecode hash
        bytes memory proxyBytecode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(l.accountBeacon, initData));

        bytes32 create2Salt = _computeSalt(credentialId, pubKeyX, pubKeyY, salt);

        return Create2.computeAddress(create2Salt, keccak256(proxyBytecode));
    }

    /*──────────────────────────── View Functions ──────────────────────*/

    /**
     * @notice Get global configuration
     * @return config The global configuration
     */
    function getGlobalConfig() external view returns (GlobalConfig memory config) {
        return _layout().globalConfig;
    }

    /**
     * @notice Check if an address is a deployed account
     * @param account Address to check
     * @return deployed True if this factory deployed the account
     */
    function isDeployedAccount(address account) external view returns (bool deployed) {
        return _layout().deployedAccounts[account];
    }

    /**
     * @notice Get the account beacon address
     * @return beacon The beacon address
     */
    function accountBeacon() external view returns (address beacon) {
        return _layout().accountBeacon;
    }

    /**
     * @notice Get the PoaManager address
     * @return The PoaManager address
     */
    function poaManager() external view returns (address) {
        return _layout().poaManager;
    }

    /**
     * @notice Get the POA guardian address
     * @return guardian The guardian address
     */
    function poaGuardian() external view returns (address guardian) {
        return _layout().globalConfig.poaGuardian;
    }

    /**
     * @notice Check if factory is paused
     * @return paused Whether factory is paused
     */
    function isPaused() external view returns (bool paused) {
        return _layout().globalConfig.paused;
    }

    /*──────────────────────────── Internal Helpers ────────────────────*/

    /**
     * @notice Compute CREATE2 salt
     * @param credentialId Credential identifier
     * @param pubKeyX Public key X coordinate
     * @param pubKeyY Public key Y coordinate
     * @param salt Additional salt
     * @return The computed salt
     */
    function _computeSalt(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(credentialId, pubKeyX, pubKeyY, salt));
    }
}
