// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EligibilityModule} from "../src/EligibilityModule.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

/**
 * @notice Regression suite for finding #4: `authorizedRevokers` was originally checked inside
 *         `onlyHatAdmin`, which gates many functions beyond `setWearerEligibility`. The fix
 *         introduces a narrower `onlyHatAdminOrRevoker` modifier used only by
 *         `setWearerEligibility`. These tests prove the revoker can use that one function
 *         but is blocked from every other admin function on the module.
 */
contract EligibilityModuleRevokerScopeTest is Test {
    EligibilityModule mod;
    MockHats hats;

    address constant SUPER_ADMIN = address(0xA1);
    address constant REVOKER = address(0xBEEF);
    address constant ALICE = address(0xA11CE);
    uint256 constant HAT_ID = 0xABCDE;
    uint256 constant PARENT_HAT_ID = 0xABCDD;

    function setUp() public {
        hats = new MockHats();
        EligibilityModule impl = new EligibilityModule();
        bytes memory init = abi.encodeCall(EligibilityModule.initialize, (SUPER_ADMIN, address(hats), address(0xDEAD)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        mod = EligibilityModule(address(proxy));

        vm.prank(SUPER_ADMIN);
        mod.setAuthorizedRevoker(REVOKER, true);
        assertTrue(mod.isAuthorizedRevoker(REVOKER));
    }

    /* ─────────── Allowed: setWearerEligibility ─────────── */

    function testRevokerCanCallSetWearerEligibility() public {
        // Mock isAdminOfHat to return false for the revoker so the auth has to flow
        // through the `authorizedRevokers` branch, not the hat-admin branch.
        // (MockHats.isAdminOfHat returns wearers[user][hat], so REVOKER not wearing
        // any hat makes isAdminOfHat false — this is the realistic production posture.)
        vm.prank(REVOKER);
        mod.setWearerEligibility(ALICE, HAT_ID, false, false);
        // No assertion needed; if the call didn't revert, the revoker path works.
    }

    /* ─────────── Blocked: every other onlySuperAdmin function ─────────── */

    function testRevokerCannotSetDefaultEligibility() public {
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.setDefaultEligibility(HAT_ID, true, true);
    }

    function testRevokerCannotClearWearerEligibility() public {
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.clearWearerEligibility(ALICE, HAT_ID);
    }

    function testRevokerCannotSetBulkWearerEligibility() public {
        address[] memory wearers = new address[](1);
        wearers[0] = ALICE;
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.setBulkWearerEligibility(wearers, HAT_ID, false, false);
    }

    function testRevokerCannotBatchSetWearerEligibility() public {
        address[] memory wearers = new address[](1);
        wearers[0] = ALICE;
        bool[] memory eligibleFlags = new bool[](1);
        bool[] memory standingFlags = new bool[](1);
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.batchSetWearerEligibility(HAT_ID, wearers, eligibleFlags, standingFlags);
    }

    function testRevokerCannotCreateHatWithEligibility() public {
        EligibilityModule.CreateHatParams memory params = EligibilityModule.CreateHatParams({
            parentHatId: PARENT_HAT_ID,
            details: "",
            maxSupply: 10,
            _mutable: true,
            imageURI: "",
            defaultEligible: true,
            defaultStanding: true,
            mintToAddresses: new address[](0),
            wearerEligibleFlags: new bool[](0),
            wearerStandingFlags: new bool[](0)
        });
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.createHatWithEligibility(params);
    }

    function testRevokerCannotUpdateHatMetadata() public {
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.updateHatMetadata(HAT_ID, "rename", bytes32(0));
    }

    function testRevokerCannotRegisterHatCreation() public {
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.registerHatCreation(HAT_ID, PARENT_HAT_ID, true, true);
    }

    /* ─────────── Sanity: superAdmin still has full access ─────────── */

    function testSuperAdminCanStillSetDefaultEligibility() public {
        vm.prank(SUPER_ADMIN);
        mod.setDefaultEligibility(HAT_ID, true, true);
    }

    function testSuperAdminCanStillSetWearerEligibility() public {
        vm.prank(SUPER_ADMIN);
        mod.setWearerEligibility(ALICE, HAT_ID, true, true);
    }

    /* ─────────── Hat admins have NO special powers post-#167 lockdown ─────────── */

    function testHatAdminCannotSetDefaultEligibility() public {
        // Post-#167 lockdown: being a hat-admin grants no write powers. Only the superAdmin
        // (and authorized revokers, for setWearerEligibility only) may write. A user who merely
        // wears/administers the hat is rejected with NotSuperAdmin.
        address hatAdmin = address(0xBA51C);
        hats.mintHat(HAT_ID, hatAdmin);
        vm.prank(hatAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.setDefaultEligibility(HAT_ID, true, true);
    }

    /* ─────────── Authorization toggle ─────────── */

    function testRevokeAuthorizationBlocksSetWearerEligibility() public {
        vm.prank(SUPER_ADMIN);
        mod.setAuthorizedRevoker(REVOKER, false);
        assertFalse(mod.isAuthorizedRevoker(REVOKER));

        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.setWearerEligibility(ALICE, HAT_ID, false, false);
    }

    function testNonSuperAdminCannotSetAuthorizedRevoker() public {
        vm.prank(REVOKER);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        mod.setAuthorizedRevoker(address(0xCAFE), true);
    }
}
