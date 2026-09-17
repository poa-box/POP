// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/EligibilityModule.sol";
import "../src/ToggleModule.sol";
import "./mocks/MockHats.sol";

/**
 * @title BatchFunctionsTest
 * @notice Tests for all batch functions in EligibilityModule and ToggleModule
 * @dev Tests gas-optimized batch operations added for org deployment
 */
contract BatchFunctionsTest is Test {
    EligibilityModule eligibility;
    ToggleModule toggle;
    MockHats hats;

    address superAdmin = address(1);
    address user1 = address(2);
    address user2 = address(3);
    address user3 = address(4);
    address unauthorized = address(5);

    uint256 constant HAT_1 = 100;
    uint256 constant HAT_2 = 200;
    uint256 constant HAT_3 = 300;
    uint256 constant VOUCHER_HAT = 400;

    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );
    event DefaultEligibilityUpdated(uint256 indexed hatId, bool eligible, bool standing, address indexed admin);
    event HatCreatedWithEligibility(
        address indexed creator,
        uint256 indexed parentHatId,
        uint256 indexed newHatId,
        bool defaultEligible,
        bool defaultStanding,
        uint256 mintedCount
    );
    event VouchConfigSet(
        uint256 indexed hatId, uint32 quorum, uint256 membershipHatId, bool enabled, bool combineWithHierarchy
    );
    event HatToggled(uint256 indexed hatId, bool newStatus);

    function setUp() public {
        hats = new MockHats();

        // Deploy implementations
        EligibilityModule eligibilityImpl = new EligibilityModule();
        ToggleModule toggleImpl = new ToggleModule();

        // Create beacons
        UpgradeableBeacon eligibilityBeacon = new UpgradeableBeacon(address(eligibilityImpl), address(this));
        UpgradeableBeacon toggleBeacon = new UpgradeableBeacon(address(toggleImpl), address(this));

        // Deploy proxies with initialization data
        bytes memory eligibilityInit = abi.encodeWithSelector(
            EligibilityModule.initialize.selector,
            superAdmin,
            address(hats),
            address(0) // toggleModule set later
        );
        bytes memory toggleInit = abi.encodeWithSelector(ToggleModule.initialize.selector, superAdmin);

        eligibility = EligibilityModule(address(new BeaconProxy(address(eligibilityBeacon), eligibilityInit)));
        toggle = ToggleModule(address(new BeaconProxy(address(toggleBeacon), toggleInit)));

        // Wire modules together
        vm.startPrank(superAdmin);
        eligibility.setToggleModule(address(toggle));
        toggle.setEligibilityModule(address(eligibility));
        vm.stopPrank();
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                            batchSetWearerEligibilityMultiHat Tests                                ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchSetWearerEligibilityMultiHat_success() public {
        address[] memory wearers = new address[](3);
        wearers[0] = user1;
        wearers[1] = user2;
        wearers[2] = user3;

        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        vm.prank(superAdmin);
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);

        // Verify eligibility was set for each pair
        (bool eligible1, bool standing1) = eligibility.getWearerRules(user1, HAT_1);
        (bool eligible2, bool standing2) = eligibility.getWearerRules(user2, HAT_2);
        (bool eligible3, bool standing3) = eligibility.getWearerRules(user3, HAT_3);

        assertTrue(eligible1 && standing1, "User1 should be eligible for HAT_1");
        assertTrue(eligible2 && standing2, "User2 should be eligible for HAT_2");
        assertTrue(eligible3 && standing3, "User3 should be eligible for HAT_3");
    }

    function test_batchSetWearerEligibilityMultiHat_emptyArrays() public {
        address[] memory wearers = new address[](0);
        uint256[] memory hatIds = new uint256[](0);

        vm.prank(superAdmin);
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
        // Should succeed with empty arrays
    }

    function test_batchSetWearerEligibilityMultiHat_arrayLengthMismatch() public {
        address[] memory wearers = new address[](2);
        wearers[0] = user1;
        wearers[1] = user2;

        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.ArrayLengthMismatch.selector);
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
    }

    function test_batchSetWearerEligibilityMultiHat_notSuperAdmin() public {
        address[] memory wearers = new address[](1);
        wearers[0] = user1;

        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        vm.prank(unauthorized);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
    }

    function test_batchSetWearerEligibilityMultiHat_whenPaused() public {
        vm.prank(superAdmin);
        eligibility.pause();

        address[] memory wearers = new address[](1);
        wearers[0] = user1;

        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        vm.prank(superAdmin);
        vm.expectRevert("Contract is paused");
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
    }

    function test_batchSetWearerEligibilityMultiHat_emitsEvents() public {
        address[] memory wearers = new address[](2);
        wearers[0] = user1;
        wearers[1] = user2;

        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        vm.prank(superAdmin);
        vm.expectEmit(true, true, true, true);
        emit WearerEligibilityUpdated(user1, HAT_1, true, true, superAdmin);
        vm.expectEmit(true, true, true, true);
        emit WearerEligibilityUpdated(user2, HAT_2, true, true, superAdmin);
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                batchSetDefaultEligibility Tests                                   ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchSetDefaultEligibility_success() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        bool[] memory eligibles = new bool[](3);
        eligibles[0] = true;
        eligibles[1] = false;
        eligibles[2] = true;

        bool[] memory standings = new bool[](3);
        standings[0] = true;
        standings[1] = true;
        standings[2] = false;

        vm.prank(superAdmin);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);

        (bool e1, bool s1) = eligibility.getDefaultRules(HAT_1);
        (bool e2, bool s2) = eligibility.getDefaultRules(HAT_2);
        (bool e3, bool s3) = eligibility.getDefaultRules(HAT_3);

        assertTrue(e1 && s1, "HAT_1 should have eligible=true, standing=true");
        assertTrue(!e2 && s2, "HAT_2 should have eligible=false, standing=true");
        assertTrue(e3 && !s3, "HAT_3 should have eligible=true, standing=false");
    }

    function test_batchSetDefaultEligibility_emptyArrays() public {
        uint256[] memory hatIds = new uint256[](0);
        bool[] memory eligibles = new bool[](0);
        bool[] memory standings = new bool[](0);

        vm.prank(superAdmin);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    function test_batchSetDefaultEligibility_arrayLengthMismatch() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        bool[] memory eligibles = new bool[](3);
        bool[] memory standings = new bool[](2);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.ArrayLengthMismatch.selector);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    function test_batchSetDefaultEligibility_notSuperAdmin() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        bool[] memory eligibles = new bool[](1);
        eligibles[0] = true;

        bool[] memory standings = new bool[](1);
        standings[0] = true;

        vm.prank(unauthorized);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    function test_batchSetDefaultEligibility_whenPaused() public {
        vm.prank(superAdmin);
        eligibility.pause();

        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        bool[] memory eligibles = new bool[](1);
        eligibles[0] = true;

        bool[] memory standings = new bool[](1);
        standings[0] = true;

        vm.prank(superAdmin);
        vm.expectRevert("Contract is paused");
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    function test_batchSetDefaultEligibility_emitsEvents() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        bool[] memory eligibles = new bool[](2);
        eligibles[0] = true;
        eligibles[1] = false;

        bool[] memory standings = new bool[](2);
        standings[0] = true;
        standings[1] = true;

        vm.prank(superAdmin);
        vm.expectEmit(true, true, true, true);
        emit DefaultEligibilityUpdated(HAT_1, true, true, superAdmin);
        vm.expectEmit(true, true, true, true);
        emit DefaultEligibilityUpdated(HAT_2, false, true, superAdmin);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                    batchMintHats Tests                                            ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchMintHats_success() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        address[] memory wearers = new address[](3);
        wearers[0] = user1;
        wearers[1] = user2;
        wearers[2] = user3;

        vm.prank(superAdmin);
        eligibility.batchMintHats(hatIds, wearers);

        // Verify hats were minted (via MockHats)
        assertTrue(hats.isWearerOfHat(user1, HAT_1), "User1 should wear HAT_1");
        assertTrue(hats.isWearerOfHat(user2, HAT_2), "User2 should wear HAT_2");
        assertTrue(hats.isWearerOfHat(user3, HAT_3), "User3 should wear HAT_3");
    }

    function test_batchMintHats_emptyArrays() public {
        uint256[] memory hatIds = new uint256[](0);
        address[] memory wearers = new address[](0);

        vm.prank(superAdmin);
        eligibility.batchMintHats(hatIds, wearers);
    }

    function test_batchMintHats_arrayLengthMismatch() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        address[] memory wearers = new address[](3);
        wearers[0] = user1;
        wearers[1] = user2;
        wearers[2] = user3;

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.ArrayLengthMismatch.selector);
        eligibility.batchMintHats(hatIds, wearers);
    }

    function test_batchMintHats_notSuperAdmin() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        address[] memory wearers = new address[](1);
        wearers[0] = user1;

        vm.prank(unauthorized);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.batchMintHats(hatIds, wearers);
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                batchRegisterHatCreation Tests                                     ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchRegisterHatCreation_success() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        uint256[] memory parentHatIds = new uint256[](3);
        parentHatIds[0] = 1; // topHat
        parentHatIds[1] = HAT_1;
        parentHatIds[2] = HAT_1;

        bool[] memory defaultEligibles = new bool[](3);
        defaultEligibles[0] = true;
        defaultEligibles[1] = true;
        defaultEligibles[2] = false;

        bool[] memory defaultStandings = new bool[](3);
        defaultStandings[0] = true;
        defaultStandings[1] = true;
        defaultStandings[2] = true;

        vm.prank(superAdmin);
        eligibility.batchRegisterHatCreation(hatIds, parentHatIds, defaultEligibles, defaultStandings);

        // Verify default rules were set
        (bool e1, bool s1) = eligibility.getDefaultRules(HAT_1);
        (bool e2, bool s2) = eligibility.getDefaultRules(HAT_2);
        (bool e3, bool s3) = eligibility.getDefaultRules(HAT_3);

        assertTrue(e1 && s1, "HAT_1 defaults should be set");
        assertTrue(e2 && s2, "HAT_2 defaults should be set");
        assertTrue(!e3 && s3, "HAT_3 defaults should be set");
    }

    function test_batchRegisterHatCreation_emptyArrays() public {
        uint256[] memory hatIds = new uint256[](0);
        uint256[] memory parentHatIds = new uint256[](0);
        bool[] memory defaultEligibles = new bool[](0);
        bool[] memory defaultStandings = new bool[](0);

        vm.prank(superAdmin);
        eligibility.batchRegisterHatCreation(hatIds, parentHatIds, defaultEligibles, defaultStandings);
    }

    function test_batchRegisterHatCreation_arrayLengthMismatch() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        uint256[] memory parentHatIds = new uint256[](3);
        bool[] memory defaultEligibles = new bool[](2);
        bool[] memory defaultStandings = new bool[](2);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.ArrayLengthMismatch.selector);
        eligibility.batchRegisterHatCreation(hatIds, parentHatIds, defaultEligibles, defaultStandings);
    }

    function test_batchRegisterHatCreation_notSuperAdmin() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        uint256[] memory parentHatIds = new uint256[](1);
        parentHatIds[0] = 1;

        bool[] memory defaultEligibles = new bool[](1);
        defaultEligibles[0] = true;

        bool[] memory defaultStandings = new bool[](1);
        defaultStandings[0] = true;

        vm.prank(unauthorized);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.batchRegisterHatCreation(hatIds, parentHatIds, defaultEligibles, defaultStandings);
    }

    function test_batchRegisterHatCreation_emitsEvents() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        uint256[] memory parentHatIds = new uint256[](2);
        parentHatIds[0] = 1;
        parentHatIds[1] = HAT_1;

        bool[] memory defaultEligibles = new bool[](2);
        defaultEligibles[0] = true;
        defaultEligibles[1] = false;

        bool[] memory defaultStandings = new bool[](2);
        defaultStandings[0] = true;
        defaultStandings[1] = true;

        vm.prank(superAdmin);
        vm.expectEmit(true, true, true, true);
        emit DefaultEligibilityUpdated(HAT_1, true, true, superAdmin);
        vm.expectEmit(true, true, true, true);
        emit HatCreatedWithEligibility(superAdmin, 1, HAT_1, true, true, 0);
        vm.expectEmit(true, true, true, true);
        emit DefaultEligibilityUpdated(HAT_2, false, true, superAdmin);
        vm.expectEmit(true, true, true, true);
        emit HatCreatedWithEligibility(superAdmin, HAT_1, HAT_2, false, true, 0);
        eligibility.batchRegisterHatCreation(hatIds, parentHatIds, defaultEligibles, defaultStandings);
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                batchConfigureVouching Tests                                       ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchConfigureVouching_success() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        uint32[] memory quorums = new uint32[](3);
        quorums[0] = 2;
        quorums[1] = 3;
        quorums[2] = 1;

        uint256[] memory membershipHatIds = new uint256[](3);
        membershipHatIds[0] = VOUCHER_HAT;
        membershipHatIds[1] = VOUCHER_HAT;
        membershipHatIds[2] = VOUCHER_HAT;

        bool[] memory combineFlags = new bool[](3);
        combineFlags[0] = false;
        combineFlags[1] = true;
        combineFlags[2] = false;

        vm.prank(superAdmin);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);

        // Verify vouching configs
        EligibilityModule.VouchConfig memory config1 = eligibility.getVouchConfig(HAT_1);
        EligibilityModule.VouchConfig memory config2 = eligibility.getVouchConfig(HAT_2);
        EligibilityModule.VouchConfig memory config3 = eligibility.getVouchConfig(HAT_3);

        assertEq(config1.quorum, 2, "HAT_1 quorum should be 2");
        assertEq(config1.membershipHatId, VOUCHER_HAT, "HAT_1 membershipHatId should be VOUCHER_HAT");
        assertTrue(eligibility.isVouchingEnabled(HAT_1), "HAT_1 vouching should be enabled");
        assertFalse(eligibility.combinesWithHierarchy(HAT_1), "HAT_1 should not combine with hierarchy");

        assertEq(config2.quorum, 3, "HAT_2 quorum should be 3");
        assertTrue(eligibility.combinesWithHierarchy(HAT_2), "HAT_2 should combine with hierarchy");

        assertEq(config3.quorum, 1, "HAT_3 quorum should be 1");
    }

    function test_batchConfigureVouching_emptyArrays() public {
        uint256[] memory hatIds = new uint256[](0);
        uint32[] memory quorums = new uint32[](0);
        uint256[] memory membershipHatIds = new uint256[](0);
        bool[] memory combineFlags = new bool[](0);

        vm.prank(superAdmin);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);
    }

    function test_batchConfigureVouching_arrayLengthMismatch() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        uint32[] memory quorums = new uint32[](3);
        uint256[] memory membershipHatIds = new uint256[](2);
        bool[] memory combineFlags = new bool[](2);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.ArrayLengthMismatch.selector);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);
    }

    function test_batchConfigureVouching_notSuperAdmin() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 2;

        uint256[] memory membershipHatIds = new uint256[](1);
        membershipHatIds[0] = VOUCHER_HAT;

        bool[] memory combineFlags = new bool[](1);
        combineFlags[0] = false;

        vm.prank(unauthorized);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);
    }

    function test_batchConfigureVouching_emitsEvents() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        uint32[] memory quorums = new uint32[](2);
        quorums[0] = 2;
        quorums[1] = 0; // Disabled

        uint256[] memory membershipHatIds = new uint256[](2);
        membershipHatIds[0] = VOUCHER_HAT;
        membershipHatIds[1] = VOUCHER_HAT;

        bool[] memory combineFlags = new bool[](2);
        combineFlags[0] = true;
        combineFlags[1] = false;

        vm.prank(superAdmin);
        vm.expectEmit(true, true, true, true);
        emit VouchConfigSet(HAT_1, 2, VOUCHER_HAT, true, true);
        vm.expectEmit(true, true, true, true);
        emit VouchConfigSet(HAT_2, 0, VOUCHER_HAT, false, false);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);
    }

    function test_batchConfigureVouching_disablesWithZeroQuorum() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 0; // Zero quorum = disabled

        uint256[] memory membershipHatIds = new uint256[](1);
        membershipHatIds[0] = VOUCHER_HAT;

        bool[] memory combineFlags = new bool[](1);
        combineFlags[0] = false;

        vm.prank(superAdmin);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);

        assertFalse(eligibility.isVouchingEnabled(HAT_1), "Vouching should be disabled with zero quorum");
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                  batchSetHatStatus Tests                                          ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchSetHatStatus_success() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;

        bool[] memory actives = new bool[](3);
        actives[0] = true;
        actives[1] = false;
        actives[2] = true;

        vm.prank(superAdmin);
        toggle.batchSetHatStatus(hatIds, actives);

        assertTrue(toggle.hatActive(HAT_1), "HAT_1 should be active");
        assertFalse(toggle.hatActive(HAT_2), "HAT_2 should be inactive");
        assertTrue(toggle.hatActive(HAT_3), "HAT_3 should be active");
    }

    function test_batchSetHatStatus_emptyArrays() public {
        uint256[] memory hatIds = new uint256[](0);
        bool[] memory actives = new bool[](0);

        vm.prank(superAdmin);
        toggle.batchSetHatStatus(hatIds, actives);
    }

    function test_batchSetHatStatus_arrayLengthMismatch() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        bool[] memory actives = new bool[](3);

        vm.prank(superAdmin);
        vm.expectRevert("Array length mismatch");
        toggle.batchSetHatStatus(hatIds, actives);
    }

    function test_batchSetHatStatus_notAdmin() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        bool[] memory actives = new bool[](1);
        actives[0] = true;

        vm.prank(unauthorized);
        vm.expectRevert(ToggleModule.NotToggleAdmin.selector);
        toggle.batchSetHatStatus(hatIds, actives);
    }

    function test_batchSetHatStatus_verifyStatus() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        bool[] memory actives = new bool[](2);
        actives[0] = true;
        actives[1] = true;

        vm.prank(superAdmin);
        toggle.batchSetHatStatus(hatIds, actives);

        // Check via getHatStatus (returns 1 for active, 0 for inactive)
        assertEq(toggle.getHatStatus(HAT_1), 1, "HAT_1 status should be 1 (active)");
        assertEq(toggle.getHatStatus(HAT_2), 1, "HAT_2 status should be 1 (active)");

        // Now deactivate
        actives[0] = false;
        actives[1] = false;

        vm.prank(superAdmin);
        toggle.batchSetHatStatus(hatIds, actives);

        assertEq(toggle.getHatStatus(HAT_1), 0, "HAT_1 status should be 0 (inactive)");
        assertEq(toggle.getHatStatus(HAT_2), 0, "HAT_2 status should be 0 (inactive)");
    }

    function test_batchSetHatStatus_emitsEvents() public {
        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;

        bool[] memory actives = new bool[](2);
        actives[0] = true;
        actives[1] = false;

        vm.prank(superAdmin);
        vm.expectEmit(true, true, true, true);
        emit HatToggled(HAT_1, true);
        vm.expectEmit(true, true, true, true);
        emit HatToggled(HAT_2, false);
        toggle.batchSetHatStatus(hatIds, actives);
    }

    function test_batchSetHatStatus_eligibilityModuleCanCall() public {
        // The eligibility module should also be able to call this
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_1;

        bool[] memory actives = new bool[](1);
        actives[0] = true;

        vm.prank(address(eligibility));
        toggle.batchSetHatStatus(hatIds, actives);

        assertTrue(toggle.hatActive(HAT_1), "Eligibility module should be able to toggle");
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════════
    ║                                    Gas Comparison Tests                                           ║
    ═══════════════════════════════════════════════════════════════════════════════════════════════════*/

    function test_batchSetWearerEligibility_gasComparison() public {
        // Setup 10 users and hats
        address[] memory wearers = new address[](10);
        uint256[] memory hatIds = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            wearers[i] = address(uint160(100 + i));
            hatIds[i] = 1000 + i;
        }

        // Measure batch call gas
        vm.prank(superAdmin);
        uint256 gasBefore = gasleft();
        eligibility.batchSetWearerEligibilityMultiHat(wearers, hatIds, true, true);
        uint256 batchGas = gasBefore - gasleft();

        // Batch should be efficient (threshold adjusted for test environment overhead)
        assertTrue(batchGas < 600000, "Batch operation should use less than 600k gas");
    }

    function test_batchConfigureVouching_gasComparison() public {
        // Setup 5 hats with vouching
        uint256[] memory hatIds = new uint256[](5);
        uint32[] memory quorums = new uint32[](5);
        uint256[] memory membershipHatIds = new uint256[](5);
        bool[] memory combineFlags = new bool[](5);

        for (uint256 i = 0; i < 5; i++) {
            hatIds[i] = 1000 + i;
            quorums[i] = uint32(i + 1);
            membershipHatIds[i] = VOUCHER_HAT;
            combineFlags[i] = i % 2 == 0;
        }

        // Measure batch call gas
        vm.prank(superAdmin);
        uint256 gasBefore = gasleft();
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combineFlags);
        uint256 batchGas = gasBefore - gasleft();

        // Batch should be efficient (threshold accounts for epoch tracking storage writes)
        assertTrue(batchGas < 600000, "Batch vouching should use less than 600k gas");
    }
}
