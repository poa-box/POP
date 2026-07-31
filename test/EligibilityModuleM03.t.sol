// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/EligibilityModule.sol";
import "../src/ToggleModule.sol";
import "./mocks/MockHats.sol";

/**
 * @title EligibilityModuleM03Test
 * @notice Regression coverage for audit finding M-03: a default-eligible hat silently satisfies
 *         eligibility for every wearer, bypassing the vouch quorum whenever vouching is enabled with
 *         combineWithHierarchy (getWearerStatus ORs the hierarchy path in). Both mutation entrypoints
 *         (setDefaultEligibility and configureVouching, both onlySuperAdmin) now reject the conflicting
 *         combination in either order.
 */
contract EligibilityModuleM03Test is Test {
    EligibilityModule eligibility;
    ToggleModule toggle;
    MockHats hats;

    address superAdmin = address(1);

    uint256 constant HAT = 100;
    uint256 constant VOUCHER_HAT = 400;

    event DefaultEligibilityUpdated(uint256 indexed hatId, bool eligible, bool standing, address indexed admin);
    event VouchConfigSet(
        uint256 indexed hatId, uint32 quorum, uint256 membershipHatId, bool enabled, bool combineWithHierarchy
    );

    function setUp() public {
        hats = new MockHats();

        EligibilityModule eligibilityImpl = new EligibilityModule();
        ToggleModule toggleImpl = new ToggleModule();

        UpgradeableBeacon eligibilityBeacon = new UpgradeableBeacon(address(eligibilityImpl), address(this));
        UpgradeableBeacon toggleBeacon = new UpgradeableBeacon(address(toggleImpl), address(this));

        bytes memory eligibilityInit =
            abi.encodeWithSelector(EligibilityModule.initialize.selector, superAdmin, address(hats), address(0));
        bytes memory toggleInit = abi.encodeWithSelector(ToggleModule.initialize.selector, superAdmin);

        eligibility = EligibilityModule(address(new BeaconProxy(address(eligibilityBeacon), eligibilityInit)));
        toggle = ToggleModule(address(new BeaconProxy(address(toggleBeacon), toggleInit)));

        vm.startPrank(superAdmin);
        eligibility.setToggleModule(address(toggle));
        toggle.setEligibilityModule(address(eligibility));
        vm.stopPrank();
    }

    /*───────────── Direction 1: enabling default-eligibility on a vouch+combine hat ─────────────*/

    function testSetDefaultEligibilityRevertsWhenVouchCombineEnabled() public {
        // Configure vouching with combineWithHierarchy = true (quorum > 0 => enabled).
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        // Now enabling default-eligibility must revert (it would bypass the quorum).
        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.setDefaultEligibility(HAT, true, true);
    }

    function testSetDefaultEligibilityAllowedWhenVouchDoesNotCombine() public {
        // combineWithHierarchy = false: vouching alone gates eligibility, so default-eligible is fine.
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, false);

        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertTrue(eligible, "default eligible should be set when vouch does not combine");
    }

    function testSetDefaultEligibilityAllowedWhenVouchDisabled() public {
        // No vouch config at all: default-eligible is fine.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertTrue(eligible, "default eligible should be set when no vouching");
    }

    function testSetDefaultEligibilityFalseAlwaysAllowedEvenWithVouchCombine() public {
        // Disabling default-eligibility (eligible=false) is always safe, even with vouch+combine.
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, false, true);

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertFalse(eligible, "default eligible false must always be allowed");
    }

    /*───────────── Direction 2: enabling vouch+combine on a default-eligible hat ─────────────*/

    function testConfigureVouchingRevertsWhenDefaultEligible() public {
        // Hat is default-eligible.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        // Enabling vouch+combine must revert (quorum would be a no-op).
        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);
    }

    function testConfigureVouchingAllowedWhenDefaultEligibleButNoCombine() public {
        // Default-eligible + vouch WITHOUT combine: vouching replaces hierarchy, no conflict.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, false);

        assertTrue(eligibility.isVouchingEnabled(HAT), "vouching should be enabled");
        assertFalse(eligibility.combinesWithHierarchy(HAT), "combine should be false");
    }

    function testConfigureVouchingAllowedWhenNotDefaultEligible() public {
        // Hat is default NOT-eligible: vouch+combine is the intended secure config.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, false, true);

        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        assertTrue(eligibility.isVouchingEnabled(HAT), "vouching should be enabled");
        assertTrue(eligibility.combinesWithHierarchy(HAT), "combine should be true");
    }

    function testConfigureVouchingDisableAllowedOnDefaultEligible() public {
        // Disabling vouching (quorum 0) on a default-eligible hat is always fine.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 0, VOUCHER_HAT, true); // quorum 0 => disabled

        assertFalse(eligibility.isVouchingEnabled(HAT), "vouching should be disabled");
    }

    /*───────────── Sanity: the escape hatch works (clear one side, then set the other) ─────────────*/

    function testEscapeHatchClearDefaultThenEnableVouchCombine() public {
        // Start default-eligible, then governance flips it off and enables vouch+combine.
        vm.startPrank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);
        eligibility.setDefaultEligibility(HAT, false, true); // clear default-eligible first
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true); // now allowed
        vm.stopPrank();

        assertTrue(eligibility.isVouchingEnabled(HAT));
        assertTrue(eligibility.combinesWithHierarchy(HAT));
    }

    /*═══════════════════════════════════════════════════════════════════════════════════════════════
     * M-03 COMPLETENESS: the guard must fire in EVERY superAdmin writer of defaultRules / vouchConfigs,
     * not just setDefaultEligibility / configureVouching. The production org-deploy path uses ONLY the
     * batch functions (HatsTreeSetup.batchSetDefaultEligibility -> OrgDeployer.batchConfigureVouching),
     * so a misconfigured JSON (defaults.eligible=true + vouching.enabled + combine=true) MUST fail
     * loudly at deploy rather than silently shipping the vouch-quorum bypass.
     *═══════════════════════════════════════════════════════════════════════════════════════════════*/

    /*───────────── batchSetDefaultEligibility (default-eligibility writer) ─────────────*/

    function testBatchSetDefaultEligibilityRevertsWhenVouchCombineEnabled() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        uint256[] memory hatIds = _one(HAT);
        bool[] memory eligibles = _oneBool(true);
        bool[] memory standings = _oneBool(true);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);
    }

    function testBatchSetDefaultEligibilityRevertsOnLaterConflictingEntry() public {
        // First entry is safe, the second conflicts — the whole batch must revert (atomic, no partial).
        uint256 safeHat = 777;
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        uint256[] memory hatIds = new uint256[](2);
        hatIds[0] = safeHat;
        hatIds[1] = HAT;
        bool[] memory eligibles = new bool[](2);
        eligibles[0] = true;
        eligibles[1] = true;
        bool[] memory standings = new bool[](2);
        standings[0] = true;
        standings[1] = true;

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.batchSetDefaultEligibility(hatIds, eligibles, standings);

        // Safe entry must NOT have been persisted (revert rolls back).
        (bool safeEligible,) = eligibility.getDefaultRules(safeHat);
        assertFalse(safeEligible, "no partial write on batch revert");
    }

    function testBatchSetDefaultEligibilityAllowedWhenNotEligible() public {
        // eligible=false is always safe even on a vouch+combine hat.
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        vm.prank(superAdmin);
        eligibility.batchSetDefaultEligibility(_one(HAT), _oneBool(false), _oneBool(true));

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertFalse(eligible);
    }

    function testBatchSetDefaultEligibilityAllowedWhenVouchDoesNotCombine() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, false);

        vm.prank(superAdmin);
        eligibility.batchSetDefaultEligibility(_one(HAT), _oneBool(true), _oneBool(true));

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertTrue(eligible);
    }

    /*───────────── batchConfigureVouching (vouch-config writer, reverse direction) ─────────────*/

    function testBatchConfigureVouchingRevertsWhenDefaultEligible() public {
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        uint256[] memory hatIds = _one(HAT);
        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 2;
        uint256[] memory membershipHatIds = _one(VOUCHER_HAT);
        bool[] memory combine = _oneBool(true);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combine);
    }

    function testBatchConfigureVouchingAllowedWhenNotDefaultEligible() public {
        // The secure production config: defaults.eligible=false, then vouch+combine.
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, false, true);

        uint256[] memory hatIds = _one(HAT);
        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 2;
        uint256[] memory membershipHatIds = _one(VOUCHER_HAT);
        bool[] memory combine = _oneBool(true);

        vm.prank(superAdmin);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combine);

        assertTrue(eligibility.isVouchingEnabled(HAT));
        assertTrue(eligibility.combinesWithHierarchy(HAT));
    }

    function testBatchConfigureVouchingAllowedWhenNoCombine() public {
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);

        uint256[] memory hatIds = _one(HAT);
        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 2;
        uint256[] memory membershipHatIds = _one(VOUCHER_HAT);
        bool[] memory combine = _oneBool(false); // no combine => vouch replaces hierarchy, safe

        vm.prank(superAdmin);
        eligibility.batchConfigureVouching(hatIds, quorums, membershipHatIds, combine);

        assertTrue(eligibility.isVouchingEnabled(HAT));
        assertFalse(eligibility.combinesWithHierarchy(HAT));
    }

    /*───────────── registerHatCreation (default-eligibility writer) ─────────────*/

    function testRegisterHatCreationRevertsWhenVouchCombineEnabled() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.registerHatCreation(HAT, VOUCHER_HAT, true, true);
    }

    function testRegisterHatCreationAllowedWhenNotEligible() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        vm.prank(superAdmin);
        eligibility.registerHatCreation(HAT, VOUCHER_HAT, false, true);

        (bool eligible,) = eligibility.getDefaultRules(HAT);
        assertFalse(eligible);
    }

    /*───────────── batchRegisterHatCreation (default-eligibility writer) ─────────────*/

    function testBatchRegisterHatCreationRevertsWhenVouchCombineEnabled() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.batchRegisterHatCreation(_one(HAT), _one(VOUCHER_HAT), _oneBool(true), _oneBool(true));
    }

    /*───────────── batchRegisterHatCreationWithMetadata (default-eligibility writer) ─────────────*/

    function testBatchRegisterHatCreationWithMetadataRevertsWhenVouchCombineEnabled() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, VOUCHER_HAT, true);

        string[] memory names = new string[](1);
        names[0] = "ROLE";
        bytes32[] memory cids = new bytes32[](1);
        cids[0] = bytes32(0);

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.batchRegisterHatCreationWithMetadata(
            _one(HAT), _one(VOUCHER_HAT), _oneBool(true), _oneBool(true), names, cids
        );
    }

    /*───────────── createHatWithEligibility (default-eligibility writer) ─────────────*/

    function testCreateHatWithEligibilityRevertsWhenVouchCombineEnabled() public {
        // MockHats.createHat returns parentHatId + 1, so pre-configure vouch+combine on that id.
        uint256 parentHat = 900;
        uint256 newHat = parentHat + 1;
        vm.prank(superAdmin);
        eligibility.configureVouching(newHat, 2, VOUCHER_HAT, true);

        address[] memory noWearers = new address[](0);
        bool[] memory noFlags = new bool[](0);
        EligibilityModule.CreateHatParams memory params = EligibilityModule.CreateHatParams({
            parentHatId: parentHat,
            details: "role",
            maxSupply: 10,
            _mutable: true,
            imageURI: "",
            defaultEligible: true,
            defaultStanding: true,
            mintToAddresses: noWearers,
            wearerEligibleFlags: noFlags,
            wearerStandingFlags: noFlags
        });

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DefaultEligibilityConflictsWithVouch.selector);
        eligibility.createHatWithEligibility(params);
    }

    /*───────────── Test helpers ─────────────*/

    function _one(uint256 v) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _oneBool(bool v) private pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = v;
    }
}
