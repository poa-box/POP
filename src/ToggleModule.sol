// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

/**
 * @title ToggleModule
 * @notice A module for toggling Hats active or inactive.
 *
 *         The Hats Protocol calls getHatStatus(uint256) and expects a uint256:
 *         1 indicates "active," and 0 indicates "inactive."
 */
contract ToggleModule is Initializable {
    /*═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════*/

    error NotToggleAdmin();
    error ZeroAddress();

    /*═════════════════════════════════════ ERC-7201 STORAGE ═════════════════════════════════════*/

    /// @custom:storage-location erc7201:poa.togglemodule.storage
    struct Layout {
        /// @notice The admin who can toggle hat status
        address admin;
        /// @notice The eligibility module address that can also toggle hat status
        address eligibilityModule;
        /// @notice Whether each hat is active or not
        /// @dev hatId => bool (true = active, false = inactive)
        mapping(uint256 => bool) hatActive;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.togglemodule.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Emitted when a hat's status is toggled
    event HatToggled(uint256 indexed hatId, bool newStatus);

    /// @notice Emitted when admin is transferred
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when the eligibility module address is set
    event EligibilityModuleSet(address indexed oldModule, address indexed newModule);

    /// @notice Emitted when the module is initialized
    event ToggleModuleInitialized(address indexed admin);

    /**
     * @notice Initialize the module with admin
     * @param _admin The admin address
     */
    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        l.admin = _admin;
        emit ToggleModuleInitialized(_admin);
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Restricts certain calls so only the admin or eligibility module can perform them
     */
    modifier onlyAdmin() {
        Layout storage l = _layout();
        if (msg.sender != l.admin && msg.sender != l.eligibilityModule) revert NotToggleAdmin();
        _;
    }

    /**
     * @notice Sets an individual hat's active status
     * @param hatId The ID of the hat being toggled
     * @param _active Whether this hat is active (true) or inactive (false)
     */
    function setHatStatus(uint256 hatId, bool _active) external onlyAdmin {
        Layout storage l = _layout();
        l.hatActive[hatId] = _active;
        emit HatToggled(hatId, _active);
    }

    /**
     * @notice Batch set multiple hats' active status
     * @dev Sets status for multiple hats in a single call - gas optimized for legacy tree setup (HatsTreeSetup, deleted in Wave F)
     * @param hatIds Array of hat IDs to toggle
     * @param actives Array of active statuses (must match hatIds length)
     */
    function batchSetHatStatus(uint256[] calldata hatIds, bool[] calldata actives) external onlyAdmin {
        uint256 length = hatIds.length;
        require(length == actives.length, "Array length mismatch");

        Layout storage l = _layout();

        unchecked {
            for (uint256 i; i < length; ++i) {
                l.hatActive[hatIds[i]] = actives[i];
                emit HatToggled(hatIds[i], actives[i]);
            }
        }
    }

    /**
     * @notice The Hats Protocol calls this function to determine if `hatId` is active.
     * @param hatId The ID of the hat being checked
     * @return status 1 if active, 0 if inactive
     */
    function getHatStatus(uint256 hatId) external view returns (uint256 status) {
        // Return 1 for active, 0 for inactive
        return _layout().hatActive[hatId] ? 1 : 0;
    }

    /**
     * @notice Transfer admin rights of this module to a new admin
     * @param newAdmin The new admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        address oldAdmin = l.admin;
        l.admin = newAdmin;
        emit AdminTransferred(oldAdmin, newAdmin);
    }

    /**
     * @notice Set the eligibility module address that can also toggle hat status
     * @param _eligibilityModule The eligibility module address
     */
    function setEligibilityModule(address _eligibilityModule) external {
        if (_eligibilityModule == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        // Only allow admin to set this, but don't use the modifier since eligibility module might not be set yet
        if (msg.sender != l.admin) revert NotToggleAdmin();
        address oldModule = l.eligibilityModule;
        l.eligibilityModule = _eligibilityModule;
        emit EligibilityModuleSet(oldModule, _eligibilityModule);
    }

    /**
     * @notice Get the current admin address
     * @return admin The admin address
     */
    function admin() external view returns (address) {
        return _layout().admin;
    }

    /**
     * @notice Get the current eligibility module address
     * @return eligibilityModule The eligibility module address that can also toggle hat status
     */
    function eligibilityModule() external view returns (address) {
        return _layout().eligibilityModule;
    }

    /**
     * @notice Check if a hat is active
     * @param hatId The hat ID to check
     * @return active Whether the hat is active
     */
    function hatActive(uint256 hatId) external view returns (bool) {
        return _layout().hatActive[hatId];
    }
}
