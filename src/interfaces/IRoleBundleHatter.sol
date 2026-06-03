// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title IRoleBundleHatter
 * @notice External interface for the RoleBundleHatter — the contract that holds
 *         role-hat → capability-hat composition bundles and atomically mints a role
 *         hat plus its bundle of capability hats to a user. "Permission sets" in the
 *         UI map 1:1 to bundles in this contract.
 */
interface IRoleBundleHatter {
    function mintRole(uint256 roleHat, address user) external;

    function revokeRole(uint256 roleHat, address user) external;

    function setBundle(uint256 roleHat, uint256[] calldata capabilityHats) external;

    function addToBundle(uint256 roleHat, uint256 capabilityHat) external;

    function removeFromBundle(uint256 roleHat, uint256 capabilityHat) external;

    function setAuthorizedMinter(address minter, bool authorized) external;

    function setEligibilityModule(address eligibilityModule_) external;

    function clearDeployer() external;

    function getBundle(uint256 roleHat) external view returns (uint256[] memory);

    function bundleSize(uint256 roleHat) external view returns (uint256);

    function isInBundle(uint256 roleHat, uint256 capabilityHat) external view returns (bool);

    function isAuthorizedMinter(address minter) external view returns (bool);

    function executor() external view returns (address);

    function deployer() external view returns (address);

    function hats() external view returns (address);

    function eligibilityModule() external view returns (address);
}
