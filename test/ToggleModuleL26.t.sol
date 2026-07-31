// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/ToggleModule.sol";

/**
 * @title ToggleModuleL26Test
 * @notice Regression coverage for audit finding L-26: ToggleModule.setEligibilityModule lacked a
 *         zero-address check, an event, and a getter. All three are now present.
 */
contract ToggleModuleL26Test is Test {
    ToggleModule toggle;

    address admin = address(0xA11CE);
    address eligModule = address(0xE11B);

    event EligibilityModuleSet(address indexed oldModule, address indexed newModule);

    function setUp() public {
        ToggleModule impl = new ToggleModule();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        bytes memory init = abi.encodeWithSelector(ToggleModule.initialize.selector, admin);
        toggle = ToggleModule(address(new BeaconProxy(address(beacon), init)));
    }

    function testSetEligibilityModuleStoresAndGetterReturns() public {
        // Getter starts at zero.
        assertEq(toggle.eligibilityModule(), address(0), "should start unset");

        vm.prank(admin);
        toggle.setEligibilityModule(eligModule);

        assertEq(toggle.eligibilityModule(), eligModule, "getter should return set module");
    }

    function testSetEligibilityModuleEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit EligibilityModuleSet(address(0), eligModule);
        toggle.setEligibilityModule(eligModule);
    }

    function testSetEligibilityModuleEmitsOldModuleOnUpdate() public {
        vm.startPrank(admin);
        toggle.setEligibilityModule(eligModule);

        address newModule = address(0xBEEF);
        vm.expectEmit(true, true, false, false);
        emit EligibilityModuleSet(eligModule, newModule);
        toggle.setEligibilityModule(newModule);
        vm.stopPrank();

        assertEq(toggle.eligibilityModule(), newModule);
    }

    function testSetEligibilityModuleZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(ToggleModule.ZeroAddress.selector);
        toggle.setEligibilityModule(address(0));
    }

    function testSetEligibilityModuleOnlyAdmin() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ToggleModule.NotToggleAdmin.selector);
        toggle.setEligibilityModule(eligModule);
    }

    function testEligibilityModuleCanToggleAfterSet() public {
        vm.prank(admin);
        toggle.setEligibilityModule(eligModule);

        // The set eligibility module is now authorized to toggle hat status.
        vm.prank(eligModule);
        toggle.setHatStatus(1, true);
        assertTrue(toggle.hatActive(1), "eligibility module should be able to toggle");
    }
}
