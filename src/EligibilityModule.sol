// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "../lib/hats-protocol/src/Interfaces/IHats.sol";
import "../lib/hats-protocol/src/Interfaces/IHatsEligibility.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

/**
 * @notice Minimal interface for ToggleModule - only includes functions we actually use
 */
interface IToggleModule {
    function setHatStatus(uint256 hatId, bool _active) external;
}

/**
 * @title EligibilityModule
 * @notice A hat-based module for configuring eligibility and standing
 *         on a per-hat basis in the Hats Protocol, controlled by admin hats.
 *         Now supports optional N-Vouch eligibility system.
 */
contract EligibilityModule is Initializable, IHatsEligibility {
    /*═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════*/

    error NotSuperAdmin();
    error ZeroAddress();
    error InvalidQuorum();
    error InvalidMembershipHat();
    error CannotVouchForSelf();
    error InvalidHatId();
    error InvalidUser();
    error InvalidJoinTime();
    error ArrayLengthMismatch();
    error VouchingNotEnabled();
    error NotAuthorizedToVouch();
    error AlreadyVouched();
    error HasNotVouched();
    error VouchingRateLimitExceeded();
    error InvalidMaxDailyVouches();
    error NewUserVouchingRestricted();
    error ApplicationAlreadyExists();
    error NoActiveApplication();
    error InvalidApplicationHash();

    /*═════════════════════════════════════════ STRUCTS ═════════════════════════════════════════*/

    /// @notice Per-wearer per-hat configuration for eligibility and standing (packed)
    struct WearerRules {
        uint8 flags; // Packed flags: bit 0 = eligible, bit 1 = standing
    }

    /// @notice Configuration for vouching system per hat (optimized packing)
    struct VouchConfig {
        uint32 quorum; // Number of vouches required
        uint256 membershipHatId; // Hat ID whose wearers can vouch
        uint8 flags; // Packed flags: bit 0 = enabled, bit 1 = combineWithHierarchy
    }

    /// @notice Parameters for creating a hat with eligibility configuration
    struct CreateHatParams {
        uint256 parentHatId;
        string details;
        uint32 maxSupply;
        bool _mutable;
        string imageURI;
        bool defaultEligible;
        bool defaultStanding;
        address[] mintToAddresses;
        bool[] wearerEligibleFlags;
        bool[] wearerStandingFlags;
    }

    /*═════════════════════════════════════ ERC-7201 STORAGE ═════════════════════════════════════*/

    /// @custom:storage-location erc7201:poa.eligibilitymodule.storage
    struct Layout {
        // Slot 1: Core addresses (40 bytes + 24 bytes padding)
        IHats hats; // 20 bytes
        address superAdmin; // 20 bytes
        // Slot 2: Module addresses + hat ID (20 + 20 + 32 = 72 bytes across 3 slots)
        address toggleModule; // 20 bytes
        uint256 eligibilityModuleAdminHat; // 32 bytes (separate slot)
        // Emergency pause state
        bool _paused;
        // Mappings (separate slots each)
        mapping(address => mapping(uint256 => WearerRules)) wearerRules;
        mapping(address => mapping(uint256 => bool)) hasSpecificWearerRules;
        mapping(uint256 => WearerRules) defaultRules;
        mapping(uint256 => VouchConfig) vouchConfigs;
        mapping(uint256 => mapping(address => mapping(address => bool))) vouchers;
        mapping(uint256 => mapping(address => uint32)) currentVouchCount;
        // Rate limiting for vouching
        mapping(address => uint256) userJoinTime;
        mapping(address => mapping(uint256 => uint32)) dailyVouchCount; // user => day => count
        // Role application system
        mapping(uint256 => mapping(address => bytes32)) roleApplications; // hatId => applicant => applicationHash
        mapping(uint256 => address[]) roleApplicants; // hatId => array of applicant addresses
        uint256 _notEntered; // reentrancy guard (moved from slot 0 to ERC-7201 namespace)
        // Vouch epoch tracking: invalidates stale vouch data after resetVouches/reconfigureVouching
        mapping(uint256 => uint256) vouchConfigEpoch; // hatId => epoch counter
        mapping(uint256 => mapping(address => uint256)) wearerVouchEpoch; // hatId => wearer => epoch of their count
        mapping(uint256 => mapping(address => mapping(address => uint256))) voucherRecordEpoch; // hatId => wearer => voucher => epoch
        // Configurable daily vouch limit (0 = use DEFAULT_MAX_DAILY_VOUCHES)
        uint32 maxDailyVouches;
        // Authorized revokers: contracts that may call setWearerEligibility without being a
        // hat admin or the superAdmin. Used to grant RoleBundleHatter authority to cascade-revoke
        // capability hats when a role is revoked. Strictly an additive authorization — does NOT
        // remove any existing checks.
        mapping(address => bool) authorizedRevokers;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.eligibilitymodule.storage");

    /// @dev Use assembly for gas-optimized storage access
    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @dev Returns the effective max daily vouches. Uses storage value if set, otherwise the default.
    /// This provides backward compatibility: existing deployments with maxDailyVouches = 0 (unset)
    /// automatically get DEFAULT_MAX_DAILY_VOUCHES.
    function _getMaxDailyVouches() internal view returns (uint32) {
        uint32 stored = _layout().maxDailyVouches;
        return stored > 0 ? stored : DEFAULT_MAX_DAILY_VOUCHES;
    }

    /*═══════════════════════════════════════ REENTRANCY PROTECTION ═══════════════════════════════════*/

    modifier nonReentrant() {
        Layout storage l = _layout();
        require(l._notEntered != 2, "ReentrancyGuard: reentrant call");
        l._notEntered = 2;
        _;
        l._notEntered = 1;
    }

    modifier whenNotPaused() {
        require(!_layout()._paused, "Contract is paused");
        _;
    }

    /*═══════════════════════════════════════ FLAG CONSTANTS ═══════════════════════════════════════*/

    uint8 private constant ELIGIBLE_FLAG = 0x01; // bit 0
    uint8 private constant STANDING_FLAG = 0x02; // bit 1
    uint8 private constant ENABLED_FLAG = 0x01; // bit 0
    uint8 private constant COMBINE_HIERARCHY_FLAG = 0x02; // bit 1

    /*═══════════════════════════════════ METADATA CONSTANTS ═══════════════════════════════════════*/

    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    /*═══════════════════════════════════ RATE LIMITING CONSTANTS ═══════════════════════════════════*/

    uint32 private constant DEFAULT_MAX_DAILY_VOUCHES = 20;
    uint256 private constant NEW_USER_RESTRICTION_DAYS = 0; // Removed wait period for immediate vouching
    uint256 private constant SECONDS_PER_DAY = 86400;

    /*═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════*/

    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );
    event DefaultEligibilityUpdated(uint256 indexed hatId, bool eligible, bool standing, address indexed admin);

    event BulkWearerEligibilityUpdated(
        address[] wearers, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );
    event SuperAdminTransferred(address indexed oldSuperAdmin, address indexed newSuperAdmin);
    event EligibilityModuleInitialized(address indexed superAdmin, address indexed hatsContract);
    event Vouched(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);
    event VouchRevoked(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);
    event WearerVouchesCleared(address indexed wearer, uint256 indexed hatId, address indexed admin);
    event VouchConfigSet(
        uint256 indexed hatId, uint32 quorum, uint256 membershipHatId, bool enabled, bool combineWithHierarchy
    );
    event UserJoinTimeSet(address indexed user, uint256 indexed joinTime);
    event VouchingRateLimitExceededEvent(address indexed user);
    event NewUserVouchingRestrictedEvent(address indexed user);
    event EligibilityModuleAdminHatSet(uint256 indexed hatId);
    event HatClaimed(address indexed wearer, uint256 indexed hatId);
    event HatCreatedWithEligibility(
        address indexed creator,
        uint256 indexed parentHatId,
        uint256 indexed newHatId,
        bool defaultEligible,
        bool defaultStanding,
        uint256 mintedCount
    );
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event HatMetadataUpdated(uint256 indexed hatId, string name, bytes32 metadataCID);
    event RoleApplicationSubmitted(uint256 indexed hatId, address indexed applicant, bytes32 applicationHash);
    event RoleApplicationWithdrawn(uint256 indexed hatId, address indexed applicant);
    event MaxDailyVouchesSet(uint32 maxDailyVouches);
    event AuthorizedRevokerSet(address indexed revoker, bool authorized);

    /*═════════════════════════════════════════ MODIFIERS ═════════════════════════════════════════*/

    modifier onlySuperAdmin() {
        if (msg.sender != _layout().superAdmin) revert NotSuperAdmin();
        _;
    }

    /// @dev Allows the superAdmin OR an explicitly-authorized revoker to pass. This is the
    ///      ONE narrow exception to the superAdmin-only write lockdown (PR #167): it exists
    ///      so the per-org RoleBundleHatter can cascade-revoke / reset capability-hat
    ///      eligibility during role grant/revoke. `authorizedRevokers` is a superAdmin-managed
    ///      allowlist, so the superAdmin stays in full control of who may write — this does
    ///      NOT reintroduce the removed Hats-hierarchy admin path. Used ONLY by
    ///      `setWearerEligibility`; every other write path stays strictly `onlySuperAdmin`.
    modifier onlySuperAdminOrRevoker() {
        Layout storage l = _layout();
        if (msg.sender != l.superAdmin && !l.authorizedRevokers[msg.sender]) revert NotSuperAdmin();
        _;
    }

    /*═══════════════════════════════════════ INITIALIZATION ═══════════════════════════════════════*/

    constructor() {
        _disableInitializers();
    }

    function initialize(address _superAdmin, address _hats, address _toggleModule) external initializer {
        if (_superAdmin == address(0) || _hats == address(0)) revert ZeroAddress();

        Layout storage l = _layout();
        l._notEntered = 1;
        l.superAdmin = _superAdmin;
        l.hats = IHats(_hats);
        l.toggleModule = _toggleModule;
        l._paused = false;
        emit EligibilityModuleInitialized(_superAdmin, _hats);
    }

    /*═══════════════════════════════════ PAUSE MANAGEMENT ═══════════════════════════════════════*/

    function pause() external onlySuperAdmin {
        _layout()._paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlySuperAdmin {
        _layout()._paused = false;
        emit Unpaused(msg.sender);
    }

    function paused() external view returns (bool) {
        return _layout()._paused;
    }

    /*═══════════════════════════════════ ELIGIBILITY MANAGEMENT ═══════════════════════════════════════*/

    function setWearerEligibility(address wearer, uint256 hatId, bool _eligible, bool _standing)
        external
        onlySuperAdminOrRevoker
        whenNotPaused
    {
        if (wearer == address(0)) revert ZeroAddress();
        _setWearerEligibilityInternal(wearer, hatId, _eligible, _standing);
    }

    function setDefaultEligibility(uint256 hatId, bool _eligible, bool _standing)
        external
        onlySuperAdmin
        whenNotPaused
    {
        Layout storage l = _layout();
        l.defaultRules[hatId] = WearerRules(_packWearerFlags(_eligible, _standing));
        emit DefaultEligibilityUpdated(hatId, _eligible, _standing, msg.sender);
    }

    function clearWearerEligibility(address wearer, uint256 hatId) external onlySuperAdmin whenNotPaused {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        delete l.wearerRules[wearer][hatId];
        delete l.hasSpecificWearerRules[wearer][hatId];
        emit WearerEligibilityUpdated(wearer, hatId, false, false, msg.sender);
    }

    function setBulkWearerEligibility(address[] calldata wearers, uint256 hatId, bool _eligible, bool _standing)
        external
        onlySuperAdmin
    {
        uint256 length = wearers.length;
        if (length == 0) revert ArrayLengthMismatch();

        uint8 packedFlags = _packWearerFlags(_eligible, _standing);
        Layout storage l = _layout();

        // Use unchecked for gas optimization in the loop only
        for (uint256 i; i < length;) {
            address wearer = wearers[i];
            if (wearer == address(0)) revert ZeroAddress();
            l.wearerRules[wearer][hatId] = WearerRules(packedFlags);
            l.hasSpecificWearerRules[wearer][hatId] = true;
            unchecked {
                ++i;
            }
        }
        emit BulkWearerEligibilityUpdated(wearers, hatId, _eligible, _standing, msg.sender);
    }

    /// @dev Internal function to reduce code duplication
    function _setWearerEligibilityInternal(address wearer, uint256 hatId, bool _eligible, bool _standing) internal {
        Layout storage l = _layout();
        l.wearerRules[wearer][hatId] = WearerRules(_packWearerFlags(_eligible, _standing));
        l.hasSpecificWearerRules[wearer][hatId] = true;
        emit WearerEligibilityUpdated(wearer, hatId, _eligible, _standing, msg.sender);
    }

    /*═══════════════════════════════════ BATCH OPERATIONS ═══════════════════════════════════════*/

    function batchSetWearerEligibility(
        uint256 hatId,
        address[] calldata wearers,
        bool[] calldata eligibleFlags,
        bool[] calldata standingFlags
    ) external onlySuperAdmin {
        uint256 length = wearers.length;
        if (length != eligibleFlags.length || length != standingFlags.length) {
            revert ArrayLengthMismatch();
        }

        Layout storage l = _layout();

        // Use unchecked for gas optimization
        unchecked {
            for (uint256 i; i < length; ++i) {
                address wearer = wearers[i];
                l.wearerRules[wearer][hatId] = WearerRules(_packWearerFlags(eligibleFlags[i], standingFlags[i]));
                l.hasSpecificWearerRules[wearer][hatId] = true;
                emit WearerEligibilityUpdated(wearer, hatId, eligibleFlags[i], standingFlags[i], msg.sender);
            }
        }
    }

    /**
     * @notice Batch set wearer eligibility across multiple hats - optimized for HatsTreeSetup
     * @dev Sets eligibility for multiple (wearer, hatId) pairs in a single call
     * @param wearers Array of wearer addresses
     * @param hatIds Array of hat IDs (must match wearers length)
     * @param eligible Eligibility status to set for all pairs
     * @param standing Standing status to set for all pairs
     */
    function batchSetWearerEligibilityMultiHat(
        address[] calldata wearers,
        uint256[] calldata hatIds,
        bool eligible,
        bool standing
    ) external onlySuperAdmin whenNotPaused {
        uint256 length = wearers.length;
        if (length != hatIds.length) revert ArrayLengthMismatch();

        Layout storage l = _layout();
        uint8 packedFlags = _packWearerFlags(eligible, standing);

        unchecked {
            for (uint256 i; i < length; ++i) {
                address wearer = wearers[i];
                uint256 hatId = hatIds[i];
                l.wearerRules[wearer][hatId] = WearerRules(packedFlags);
                l.hasSpecificWearerRules[wearer][hatId] = true;
                emit WearerEligibilityUpdated(wearer, hatId, eligible, standing, msg.sender);
            }
        }
    }

    /**
     * @notice Batch set default eligibility for multiple hats
     * @dev Sets default eligibility rules for multiple hats in a single call
     * @param hatIds Array of hat IDs
     * @param eligibles Array of eligibility flags
     * @param standings Array of standing flags
     */
    function batchSetDefaultEligibility(uint256[] calldata hatIds, bool[] calldata eligibles, bool[] calldata standings)
        external
        onlySuperAdmin
        whenNotPaused
    {
        uint256 length = hatIds.length;
        if (length != eligibles.length || length != standings.length) {
            revert ArrayLengthMismatch();
        }

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 hatId = hatIds[i];
                l.defaultRules[hatId] = WearerRules(_packWearerFlags(eligibles[i], standings[i]));
                emit DefaultEligibilityUpdated(hatId, eligibles[i], standings[i], msg.sender);
            }
        }
    }

    /**
     * @notice Batch mint hats to multiple wearers
     * @dev Mints multiple hats in a single call - optimized for HatsTreeSetup
     * @param hatIds Array of hat IDs to mint
     * @param wearers Array of addresses to receive hats
     */
    function batchMintHats(uint256[] calldata hatIds, address[] calldata wearers) external onlySuperAdmin {
        uint256 length = hatIds.length;
        if (length != wearers.length) revert ArrayLengthMismatch();

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                bool success = l.hats.mintHat(hatIds[i], wearers[i]);
                require(success, "Hat minting failed");
            }
        }
    }

    /**
     * @notice Batch register hat creations for subgraph indexing
     * @dev Registers multiple hats in a single call - optimized for HatsTreeSetup
     * @param hatIds Array of hat IDs that were created
     * @param parentHatIds Array of parent hat IDs
     * @param defaultEligibles Array of default eligibility flags
     * @param defaultStandings Array of default standing flags
     */
    function batchRegisterHatCreation(
        uint256[] calldata hatIds,
        uint256[] calldata parentHatIds,
        bool[] calldata defaultEligibles,
        bool[] calldata defaultStandings
    ) external onlySuperAdmin {
        uint256 length = hatIds.length;
        if (length != parentHatIds.length || length != defaultEligibles.length || length != defaultStandings.length) {
            revert ArrayLengthMismatch();
        }

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 hatId = hatIds[i];
                l.defaultRules[hatId] = WearerRules(_packWearerFlags(defaultEligibles[i], defaultStandings[i]));
                emit DefaultEligibilityUpdated(hatId, defaultEligibles[i], defaultStandings[i], msg.sender);
                emit HatCreatedWithEligibility(
                    msg.sender, parentHatIds[i], hatId, defaultEligibles[i], defaultStandings[i], 0
                );
            }
        }
    }

    /**
     * @dev Registers multiple hats with metadata in a single call - optimized for HatsTreeSetup
     * @dev This version also emits HatMetadataUpdated events for subgraph indexing
     * @param hatIds Array of hat IDs that were created
     * @param parentHatIds Array of parent hat IDs
     * @param defaultEligibles Array of default eligibility flags
     * @param defaultStandings Array of default standing flags
     * @param names Array of role names for metadata
     * @param metadataCIDs Array of IPFS CIDs for extended metadata
     */
    function batchRegisterHatCreationWithMetadata(
        uint256[] calldata hatIds,
        uint256[] calldata parentHatIds,
        bool[] calldata defaultEligibles,
        bool[] calldata defaultStandings,
        string[] calldata names,
        bytes32[] calldata metadataCIDs
    ) external onlySuperAdmin {
        uint256 length = hatIds.length;
        if (
            length != parentHatIds.length || length != defaultEligibles.length || length != defaultStandings.length
                || length != names.length || length != metadataCIDs.length
        ) {
            revert ArrayLengthMismatch();
        }

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 hatId = hatIds[i];
                l.defaultRules[hatId] = WearerRules(_packWearerFlags(defaultEligibles[i], defaultStandings[i]));
                emit DefaultEligibilityUpdated(hatId, defaultEligibles[i], defaultStandings[i], msg.sender);
                emit HatCreatedWithEligibility(
                    msg.sender, parentHatIds[i], hatId, defaultEligibles[i], defaultStandings[i], 0
                );
                // Also emit metadata event for subgraph indexing
                emit HatMetadataUpdated(hatId, names[i], metadataCIDs[i]);
            }
        }
    }

    /*═══════════════════════════════════ HAT CREATION ═══════════════════════════════════════*/

    function createHatWithEligibility(CreateHatParams calldata params)
        external
        onlySuperAdmin
        returns (uint256 newHatId)
    {
        Layout storage l = _layout();

        // Create the new hat
        newHatId = l.hats
            .createHat(
                params.parentHatId,
                params.details,
                params.maxSupply,
                address(this),
                l.toggleModule,
                params._mutable,
                params.imageURI
            );

        // Set default eligibility rules
        l.defaultRules[newHatId] = WearerRules(_packWearerFlags(params.defaultEligible, params.defaultStanding));

        // Automatically activate the hat
        IToggleModule(l.toggleModule).setHatStatus(newHatId, true);

        emit DefaultEligibilityUpdated(newHatId, params.defaultEligible, params.defaultStanding, msg.sender);

        // Handle initial minting if specified
        uint256 mintLength = params.mintToAddresses.length;
        if (mintLength > 0) {
            _handleInitialMinting(
                newHatId, params.mintToAddresses, params.wearerEligibleFlags, params.wearerStandingFlags, mintLength
            );
        }

        emit HatCreatedWithEligibility(
            msg.sender, params.parentHatId, newHatId, params.defaultEligible, params.defaultStanding, mintLength
        );
    }

    /// @notice Register a hat that was created externally and emit the HatCreatedWithEligibility event
    /// @dev Used by HatsTreeSetup to emit events for subgraph indexing without needing admin rights to create hats
    /// @param hatId The ID of the hat that was created
    /// @param parentHatId The ID of the parent hat
    /// @param defaultEligible Whether wearers are eligible by default
    /// @param defaultStanding Whether wearers have good standing by default
    function registerHatCreation(uint256 hatId, uint256 parentHatId, bool defaultEligible, bool defaultStanding)
        external
        onlySuperAdmin
    {
        Layout storage l = _layout();
        l.defaultRules[hatId] = WearerRules(_packWearerFlags(defaultEligible, defaultStanding));
        emit DefaultEligibilityUpdated(hatId, defaultEligible, defaultStanding, msg.sender);
        emit HatCreatedWithEligibility(msg.sender, parentHatId, hatId, defaultEligible, defaultStanding, 0);
    }

    /// @dev Internal function to handle initial minting logic
    function _handleInitialMinting(
        uint256 hatId,
        address[] calldata addresses,
        bool[] calldata eligibleFlags,
        bool[] calldata standingFlags,
        uint256 length
    ) internal {
        Layout storage l = _layout();

        // If specific eligibility flags provided, validate and set them
        if (eligibleFlags.length > 0) {
            if (length != eligibleFlags.length || length != standingFlags.length) {
                revert ArrayLengthMismatch();
            }

            // Set specific eligibility and mint
            unchecked {
                for (uint256 i; i < length; ++i) {
                    address wearer = addresses[i];
                    l.wearerRules[wearer][hatId] = WearerRules(_packWearerFlags(eligibleFlags[i], standingFlags[i]));
                    l.hasSpecificWearerRules[wearer][hatId] = true;

                    bool success = l.hats.mintHat(hatId, wearer);
                    require(success, "Hat minting failed");

                    emit WearerEligibilityUpdated(wearer, hatId, eligibleFlags[i], standingFlags[i], msg.sender);
                }
            }
        } else {
            // Just mint with default eligibility
            unchecked {
                for (uint256 i; i < length; ++i) {
                    bool success = l.hats.mintHat(hatId, addresses[i]);
                    require(success, "Hat minting failed");
                }
            }
        }
    }

    /*═══════════════════════════════════ MODULE MANAGEMENT ═══════════════════════════════════════*/

    function setEligibilityModuleAdminHat(uint256 hatId) external onlySuperAdmin {
        _layout().eligibilityModuleAdminHat = hatId;
        emit EligibilityModuleAdminHatSet(hatId);
    }

    function mintHatToAddress(uint256 hatId, address wearer) external onlySuperAdmin {
        bool success = _layout().hats.mintHat(hatId, wearer);
        require(success, "Hat minting failed");
    }

    function setToggleModule(address _toggleModule) external onlySuperAdmin {
        _layout().toggleModule = _toggleModule;
    }

    function transferSuperAdmin(address newSuperAdmin) external onlySuperAdmin {
        if (newSuperAdmin == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        address oldSuperAdmin = l.superAdmin;
        l.superAdmin = newSuperAdmin;
        emit SuperAdminTransferred(oldSuperAdmin, newSuperAdmin);
    }

    function setUserJoinTime(address user, uint256 joinTime) external onlySuperAdmin {
        _layout().userJoinTime[user] = joinTime;
        emit UserJoinTimeSet(user, joinTime);
    }

    function setUserJoinTimeNow(address user) external onlySuperAdmin {
        _layout().userJoinTime[user] = block.timestamp;
        emit UserJoinTimeSet(user, block.timestamp);
    }

    /// @notice Authorize a contract (typically the per-org RoleBundleHatter) to call
    ///         `setWearerEligibility` for the purpose of cascading capability-hat revocations.
    ///         Strictly additive — does not remove the existing hat-admin or superAdmin checks.
    /// @dev Authorization is narrowly scoped: revokers can ONLY call `setWearerEligibility`
    ///      (via the `onlySuperAdminOrRevoker` modifier). They cannot create hats, set defaults,
    ///      update metadata, or call any other admin-gated function. Only the superAdmin
    ///      (executor in production) can change the revoker list.
    function setAuthorizedRevoker(address revoker, bool authorized) external onlySuperAdmin {
        if (revoker == address(0)) revert ZeroAddress();
        _layout().authorizedRevokers[revoker] = authorized;
        emit AuthorizedRevokerSet(revoker, authorized);
    }

    function isAuthorizedRevoker(address revoker) external view returns (bool) {
        return _layout().authorizedRevokers[revoker];
    }

    /// @notice Set the maximum number of vouches a user can give per day
    /// @param maxVouches New daily vouch limit (must be > 0)
    function setMaxDailyVouches(uint32 maxVouches) external onlySuperAdmin {
        if (maxVouches == 0) revert InvalidMaxDailyVouches();
        _layout().maxDailyVouches = maxVouches;
        emit MaxDailyVouchesSet(maxVouches);
    }

    /// @notice Get the current max daily vouch limit
    function getMaxDailyVouches() external view returns (uint32) {
        return _getMaxDailyVouches();
    }

    /*═══════════════════════════════════ METADATA MANAGEMENT ═══════════════════════════════════════*/

    /**
     * @notice Update hat metadata CID (uses native Hats Protocol changeHatDetails)
     * @dev Emits HatDetailsChanged event from Hats Protocol (subgraph indexable)
     * @param hatId The ID of the hat to update
     * @param name The role name
     * @param metadataCID The IPFS CID for extended metadata (bytes32(0) to clear)
     */
    function updateHatMetadata(uint256 hatId, string memory name, bytes32 metadataCID)
        external
        onlySuperAdmin
        whenNotPaused
    {
        string memory details = _formatHatDetails(name, metadataCID);
        _layout().hats.changeHatDetails(hatId, details);
        // Native HatDetailsChanged event is emitted by Hats Protocol
        emit HatMetadataUpdated(hatId, name, metadataCID);
    }

    /**
     * @notice Format hat details string - uses CID if provided, otherwise name
     * @param name The role name (fallback if no CID)
     * @param metadataCID The IPFS CID for extended metadata (bytes32(0) if none)
     * @return The formatted details string
     */
    function _formatHatDetails(string memory name, bytes32 metadataCID) internal pure returns (string memory) {
        if (metadataCID == bytes32(0)) {
            return name;
        }
        return _bytes32ToHexString(metadataCID);
    }

    /**
     * @notice Convert bytes32 to hex string with 0x prefix
     * @param value The bytes32 value to convert
     * @return The hex string representation
     */
    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory buffer = new bytes(66); // 2 for "0x" + 64 for hex chars
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            buffer[2 + i * 2] = HEX_DIGITS[uint8(value[i] >> 4)];
            buffer[3 + i * 2] = HEX_DIGITS[uint8(value[i] & 0x0f)];
        }
        return string(buffer);
    }

    /*═══════════════════════════════════ VOUCHING SYSTEM ═══════════════════════════════════════*/

    function configureVouching(uint256 hatId, uint32 quorum, uint256 membershipHatId, bool combineWithHierarchy)
        external
        onlySuperAdmin
    {
        Layout storage l = _layout();
        bool enabled = quorum > 0;
        l.vouchConfigs[hatId] = VouchConfig({
            quorum: quorum, membershipHatId: membershipHatId, flags: _packVouchFlags(enabled, combineWithHierarchy)
        });

        // Invalidate stale vouch data from prior configuration
        l.vouchConfigEpoch[hatId]++;

        emit VouchConfigSet(hatId, quorum, membershipHatId, enabled, combineWithHierarchy);
    }

    /**
     * @notice Batch configure vouching for multiple hats
     * @dev Sets vouching configuration for multiple hats in a single call - gas optimized for org deployment
     * @param hatIds Array of hat IDs to configure
     * @param quorums Array of quorum values (number of vouches required)
     * @param membershipHatIds Array of hat IDs whose wearers can vouch
     * @param combineWithHierarchyFlags Array of flags for combining with hierarchy eligibility
     */
    function batchConfigureVouching(
        uint256[] calldata hatIds,
        uint32[] calldata quorums,
        uint256[] calldata membershipHatIds,
        bool[] calldata combineWithHierarchyFlags
    ) external onlySuperAdmin {
        uint256 length = hatIds.length;
        if (length != quorums.length || length != membershipHatIds.length || length != combineWithHierarchyFlags.length)
        {
            revert ArrayLengthMismatch();
        }

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 hatId = hatIds[i];
                bool enabled = quorums[i] > 0;
                l.vouchConfigs[hatId] = VouchConfig({
                    quorum: quorums[i],
                    membershipHatId: membershipHatIds[i],
                    flags: _packVouchFlags(enabled, combineWithHierarchyFlags[i])
                });

                // Invalidate stale vouch data
                l.vouchConfigEpoch[hatId]++;

                emit VouchConfigSet(hatId, quorums[i], membershipHatIds[i], enabled, combineWithHierarchyFlags[i]);
            }
        }
    }

    function vouchFor(address wearer, uint256 hatId) external whenNotPaused {
        if (wearer == address(0)) revert ZeroAddress();
        if (wearer == msg.sender) revert CannotVouchForSelf();

        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];
        if (!_isVouchingEnabled(config.flags)) revert VouchingNotEnabled();

        // Check vouching authorization
        bool isAuthorized = l.hats.isWearerOfHat(msg.sender, config.membershipHatId);

        // If combineWithHierarchy is enabled, also check if voucher has admin privileges for this hat
        if (!isAuthorized && _shouldCombineWithHierarchy(config.flags)) {
            isAuthorized = l.hats.isAdminOfHat(msg.sender, hatId);
        }

        if (!isAuthorized) revert NotAuthorizedToVouch();

        // Epoch-aware stale data handling:
        // If the wearer's count is from a prior epoch, reset it lazily.
        uint256 currentEpoch = l.vouchConfigEpoch[hatId];
        if (l.wearerVouchEpoch[hatId][wearer] != currentEpoch) {
            l.currentVouchCount[hatId][wearer] = 0;
            l.wearerVouchEpoch[hatId][wearer] = currentEpoch;
        }

        // AlreadyVouched: only if this specific voucher's record is from the current epoch
        if (l.vouchers[hatId][wearer][msg.sender] && l.voucherRecordEpoch[hatId][wearer][msg.sender] == currentEpoch) {
            revert AlreadyVouched();
        }

        // SECURITY: Rate limiting checks
        _checkVouchingRateLimit(msg.sender);

        // Record the vouch with its epoch
        l.vouchers[hatId][wearer][msg.sender] = true;
        l.voucherRecordEpoch[hatId][wearer][msg.sender] = currentEpoch;
        uint32 newCount = l.currentVouchCount[hatId][wearer] + 1;
        l.currentVouchCount[hatId][wearer] = newCount;

        // Update daily vouch count
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        uint32 dailyCount = l.dailyVouchCount[msg.sender][currentDay] + 1;
        l.dailyVouchCount[msg.sender][currentDay] = dailyCount;

        emit Vouched(msg.sender, wearer, hatId, newCount);
    }

    function _checkVouchingRateLimit(address user) internal view {
        Layout storage l = _layout();

        // Check if user has been around long enough to vouch
        // NEW_USER_RESTRICTION_DAYS = 0, so anyone can vouch immediately
        uint256 joinTime = l.userJoinTime[user];
        if (joinTime != 0) {
            // Only check if join time is set
            uint256 daysSinceJoined = (block.timestamp - joinTime) / SECONDS_PER_DAY;
            if (daysSinceJoined < NEW_USER_RESTRICTION_DAYS) {
                revert NewUserVouchingRestricted();
            }
        }
        // If joinTime is 0 (never set), allow vouching since NEW_USER_RESTRICTION_DAYS = 0

        // Check daily vouch limit
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        if (l.dailyVouchCount[user][currentDay] >= _getMaxDailyVouches()) {
            revert VouchingRateLimitExceeded();
        }
    }

    function revokeVouch(address wearer, uint256 hatId) external whenNotPaused {
        if (wearer == address(0)) revert ZeroAddress();

        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];
        if (!_isVouchingEnabled(config.flags)) revert VouchingNotEnabled();

        // Only current-epoch vouch records can be revoked
        uint256 currentEpoch = l.vouchConfigEpoch[hatId];
        if (l.wearerVouchEpoch[hatId][wearer] != currentEpoch) revert HasNotVouched();
        if (!l.vouchers[hatId][wearer][msg.sender] || l.voucherRecordEpoch[hatId][wearer][msg.sender] != currentEpoch) {
            revert HasNotVouched();
        }

        // Remove the vouch
        l.vouchers[hatId][wearer][msg.sender] = false;
        uint32 newCount = l.currentVouchCount[hatId][wearer] - 1;
        l.currentVouchCount[hatId][wearer] = newCount;

        // Note: dailyVouchCount is NOT decremented on revocation.
        // It's a rate limiter only — revoking doesn't give back vouch slots.

        emit VouchRevoked(msg.sender, wearer, hatId, newCount);

        // Handle hat revocation if needed
        if (
            !_shouldCombineWithHierarchy(config.flags) && newCount < config.quorum
                && l.hats.isWearerOfHat(wearer, hatId) && !l.hasSpecificWearerRules[wearer][hatId]
        ) {
            l.hats.setHatWearerStatus(hatId, wearer, false, false);
        }
    }

    function resetVouches(uint256 hatId) external onlySuperAdmin {
        Layout storage l = _layout();
        delete l.vouchConfigs[hatId];
        // Increment epoch to invalidate all stale vouch counts and AlreadyVouched records
        l.vouchConfigEpoch[hatId]++;
        emit VouchConfigSet(hatId, 0, 0, false, false);
    }

    /**
     * @notice Surgical per-wearer vouch invalidation for a single hat.
     * @dev Sets `wearerVouchEpoch` to a sentinel value that will never match
     *      `vouchConfigEpoch`, so the wearer's effective vouch count for this
     *      hat is permanently 0 from this point forward (until they get
     *      re-vouched, which writes a fresh epoch via `vouchFor`).
     *      Combined with `setWearerEligibility(wearer, hatId, false, false)`
     *      this is the surgical equivalent of `resetVouches` for one wearer
     *      — does NOT touch other wearers' vouches and does NOT disable
     *      vouching org-wide. Designed for the election-loser case on
     *      vouching-gated hats with available supply.
     * @param wearer The address whose vouch state to clear for this hat
     * @param hatId The hat for which to clear vouches
     */
    function clearWearerVouches(address wearer, uint256 hatId) external onlySuperAdmin whenNotPaused {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        // type(uint256).max guarantees wearerVouchEpoch != vouchConfigEpoch for
        // any future epoch (epoch is incremented one-at-a-time by ~25 lines of
        // code; reaching uint256.max would take 2^256 admin calls).
        l.wearerVouchEpoch[hatId][wearer] = type(uint256).max;
        delete l.currentVouchCount[hatId][wearer];
        emit WearerVouchesCleared(wearer, hatId, msg.sender);
    }

    /**
     * @notice Allows a user to claim a hat they are eligible for after being vouched
     * @dev User must have sufficient vouches to be eligible. This is the claim-based pattern
     *      where users explicitly accept their role rather than having it auto-minted.
     *      The EligibilityModule contract mints the hat using its ELIGIBILITY_ADMIN permissions.
     * @param hatId The ID of the hat to claim
     */
    function claimVouchedHat(uint256 hatId) external whenNotPaused nonReentrant {
        Layout storage l = _layout();

        // Check if caller is eligible to claim this hat
        (bool eligible, bool standing) = this.getWearerStatus(msg.sender, hatId);
        require(eligible && standing, "Not eligible to claim hat");

        // Check if already wearing the hat
        require(!l.hats.isWearerOfHat(msg.sender, hatId), "Already wearing hat");

        // State change BEFORE external call (CEI pattern)
        delete l.roleApplications[hatId][msg.sender];

        // Mint the hat to the caller using EligibilityModule's admin powers
        bool success = l.hats.mintHat(hatId, msg.sender);
        require(success, "Hat minting failed");

        emit HatClaimed(msg.sender, hatId);
    }

    /*═══════════════════════════════════ ROLE APPLICATION SYSTEM ═══════════════════════════════════════*/

    /// @notice Submit an application for a role (hat) that has vouching enabled.
    ///         This is a signaling mechanism — it does not grant eligibility.
    /// @param hatId The hat ID to apply for
    /// @param applicationHash IPFS CID sha256 digest of the application details
    function applyForRole(uint256 hatId, bytes32 applicationHash) external whenNotPaused {
        if (applicationHash == bytes32(0)) revert InvalidApplicationHash();

        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];
        if (!_isVouchingEnabled(config.flags)) revert VouchingNotEnabled();
        if (l.roleApplications[hatId][msg.sender] != bytes32(0)) revert ApplicationAlreadyExists();
        require(!l.hats.isWearerOfHat(msg.sender, hatId), "Already wearing hat");

        l.roleApplicants[hatId].push(msg.sender);
        l.roleApplications[hatId][msg.sender] = applicationHash;

        emit RoleApplicationSubmitted(hatId, msg.sender, applicationHash);
    }

    /// @notice Withdraw a previously submitted role application.
    /// @param hatId The hat ID to withdraw the application from
    function withdrawApplication(uint256 hatId) external whenNotPaused {
        Layout storage l = _layout();
        if (l.roleApplications[hatId][msg.sender] == bytes32(0)) revert NoActiveApplication();

        delete l.roleApplications[hatId][msg.sender];

        emit RoleApplicationWithdrawn(hatId, msg.sender);
    }

    /*═══════════════════════════════════ ELIGIBILITY INTERFACE ═══════════════════════════════════════*/

    function getWearerStatus(address wearer, uint256 hatId) external view returns (bool eligible, bool standing) {
        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];

        bool hierarchyEligible;
        bool hierarchyStanding;
        bool vouchEligible;
        bool vouchStanding;

        // Check hierarchy path
        WearerRules memory rules;
        if (l.hasSpecificWearerRules[wearer][hatId]) {
            rules = l.wearerRules[wearer][hatId];
        } else {
            rules = l.defaultRules[hatId];
        }
        (hierarchyEligible, hierarchyStanding) = _unpackWearerFlags(rules.flags);

        // Check vouch path if enabled (only count vouches from current epoch)
        uint32 effectiveVouchCount =
            (l.wearerVouchEpoch[hatId][wearer] == l.vouchConfigEpoch[hatId]) ? l.currentVouchCount[hatId][wearer] : 0;
        if (_isVouchingEnabled(config.flags) && effectiveVouchCount >= config.quorum) {
            vouchEligible = true;
            vouchStanding = true;
        }

        // Combine results
        if (_isVouchingEnabled(config.flags)) {
            if (_shouldCombineWithHierarchy(config.flags)) {
                eligible = hierarchyEligible || vouchEligible;
                standing = hierarchyStanding || vouchStanding;
            } else {
                eligible = vouchEligible;
                standing = vouchStanding;
            }
        } else {
            eligible = hierarchyEligible;
            standing = hierarchyStanding;
        }

        // If standing is false, eligibility MUST also be false per IHatsEligibility interface
        if (!standing) {
            eligible = false;
        }
    }

    /*═════════════════════════════════════ VIEW FUNCTIONS ═════════════════════════════════════════*/

    function getVouchConfig(uint256 hatId) external view returns (VouchConfig memory) {
        return _layout().vouchConfigs[hatId];
    }

    function isVouchingEnabled(uint256 hatId) external view returns (bool) {
        return _isVouchingEnabled(_layout().vouchConfigs[hatId].flags);
    }

    function combinesWithHierarchy(uint256 hatId) external view returns (bool) {
        return _shouldCombineWithHierarchy(_layout().vouchConfigs[hatId].flags);
    }

    function getWearerRules(address wearer, uint256 hatId) external view returns (bool eligible, bool standing) {
        Layout storage l = _layout();
        if (l.hasSpecificWearerRules[wearer][hatId]) {
            return _unpackWearerFlags(l.wearerRules[wearer][hatId].flags);
        } else {
            return _unpackWearerFlags(l.defaultRules[hatId].flags);
        }
    }

    function getDefaultRules(uint256 hatId) external view returns (bool eligible, bool standing) {
        return _unpackWearerFlags(_layout().defaultRules[hatId].flags);
    }

    function hasVouched(uint256 hatId, address wearer, address voucher) external view returns (bool) {
        return _layout().vouchers[hatId][wearer][voucher];
    }

    /// @notice Whether `user` can mutate eligibility state on this module.
    /// @dev Mirrors the `onlySuperAdmin` gate used by every write path. The `targetHatId`
    ///      parameter is retained for ABI continuity but no longer affects the answer —
    ///      Hats-hierarchical admin status is not consulted (since the lockdown that
    ///      replaced `onlyHatAdmin` with `onlySuperAdmin` on all writes). Off-chain
    ///      callers that need Hats-hierarchy admin info should query Hats directly.
    function hasAdminRights(
        address user,
        uint256 /* targetHatId */
    )
        external
        view
        returns (bool)
    {
        return user == _layout().superAdmin;
    }

    function getUserJoinTime(address user) external view returns (uint256) {
        return _layout().userJoinTime[user];
    }

    function getDailyVouchCount(address user, uint256 day) external view returns (uint32) {
        return _layout().dailyVouchCount[user][day];
    }

    function getCurrentDailyVouchCount(address user) external view returns (uint32) {
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        return _layout().dailyVouchCount[user][currentDay];
    }

    function canUserVouch(address user) external view returns (bool) {
        Layout storage l = _layout();

        // Match the enforcement logic in _checkVouchingRateLimit:
        // If joinTime is set, check the new-user restriction period
        uint256 joinTime = l.userJoinTime[user];
        if (joinTime != 0) {
            uint256 daysSinceJoined = (block.timestamp - joinTime) / SECONDS_PER_DAY;
            if (daysSinceJoined < NEW_USER_RESTRICTION_DAYS) return false;
        }
        // If joinTime is 0, allow (matches _checkVouchingRateLimit which skips the check)

        // Check daily vouch limit
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        return l.dailyVouchCount[user][currentDay] < _getMaxDailyVouches();
    }

    function hasSpecificWearerRules(address wearer, uint256 hatId) external view returns (bool) {
        return _layout().hasSpecificWearerRules[wearer][hatId];
    }

    function getRoleApplication(uint256 hatId, address applicant) external view returns (bytes32) {
        return _layout().roleApplications[hatId][applicant];
    }

    function getRoleApplicants(uint256 hatId) external view returns (address[] memory) {
        return _layout().roleApplicants[hatId];
    }

    function hasActiveApplication(uint256 hatId, address applicant) external view returns (bool) {
        return _layout().roleApplications[hatId][applicant] != bytes32(0);
    }

    /*═════════════════════════════════════ PUBLIC GETTERS ═════════════════════════════════════════*/

    function hats() external view returns (IHats) {
        return _layout().hats;
    }

    function superAdmin() external view returns (address) {
        return _layout().superAdmin;
    }

    function wearerRules(address wearer, uint256 hatId) external view returns (WearerRules memory) {
        return _layout().wearerRules[wearer][hatId];
    }

    function defaultRules(uint256 hatId) external view returns (WearerRules memory) {
        return _layout().defaultRules[hatId];
    }

    function vouchConfigs(uint256 hatId) external view returns (VouchConfig memory) {
        return _layout().vouchConfigs[hatId];
    }

    function vouchers(uint256 hatId, address wearer, address voucher) external view returns (bool) {
        return _layout().vouchers[hatId][wearer][voucher];
    }

    function currentVouchCount(uint256 hatId, address wearer) external view returns (uint32) {
        Layout storage l = _layout();
        // Return 0 for stale-epoch vouch data
        if (l.wearerVouchEpoch[hatId][wearer] != l.vouchConfigEpoch[hatId]) return 0;
        return l.currentVouchCount[hatId][wearer];
    }

    function eligibilityModuleAdminHat() external view returns (uint256) {
        return _layout().eligibilityModuleAdminHat;
    }

    function toggleModule() external view returns (address) {
        return _layout().toggleModule;
    }

    /*═════════════════════════════════════ PURE HELPERS ═════════════════════════════════════════*/

    /// @dev Gas-optimized flag packing using assembly
    function _packWearerFlags(bool eligible, bool standing) internal pure returns (uint8 flags) {
        assembly {
            flags := or(eligible, shl(1, standing))
        }
    }

    /// @dev Gas-optimized flag unpacking using assembly
    function _unpackWearerFlags(uint8 flags) internal pure returns (bool eligible, bool standing) {
        assembly {
            eligible := and(flags, 1)
            standing := and(shr(1, flags), 1)
        }
    }

    function _packVouchFlags(bool enabled, bool combineWithHierarchy) internal pure returns (uint8 flags) {
        assembly {
            flags := or(enabled, shl(1, combineWithHierarchy))
        }
    }

    function _isEligible(uint8 flags) internal pure returns (bool) {
        return (flags & ELIGIBLE_FLAG) != 0;
    }

    function _hasGoodStanding(uint8 flags) internal pure returns (bool) {
        return (flags & STANDING_FLAG) != 0;
    }

    function _isVouchingEnabled(uint8 flags) internal pure returns (bool) {
        return (flags & ENABLED_FLAG) != 0;
    }

    function _shouldCombineWithHierarchy(uint8 flags) internal pure returns (bool) {
        return (flags & COMBINE_HIERARCHY_FLAG) != 0;
    }
}
