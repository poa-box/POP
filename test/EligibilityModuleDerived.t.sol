// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/EligibilityModule.sol";
import "../src/ToggleModule.sol";
import "./mocks/MockHatsEligibilityAware.sol";

/**
 * @title EligibilityModuleDerivedTest
 * @notice W1 coverage: derived (group) eligibility, the bidirectional derived<->vouch guard, flat
 *         one-level nesting + refcount lifecycle, the claimHat/claimHats specific-source rules
 *         (H-03 class), grant-only RoleManager authority, and the paymaster-onboarding regression
 *         (vouched-not-wearing stays isEligible). Uses {MockHatsEligibilityAware} so `balanceOf`
 *         reflects live eligibility (auto-revocation on losing the last member hat, C-1).
 */
contract EligibilityModuleDerivedTest is Test {
    EligibilityModule eligibility;
    ToggleModule toggle;
    MockHatsEligibilityAware hats;

    address superAdmin = address(0xA11CE);
    address roleManagerAddr = address(0x501E);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address voucher = address(0xC0FFEE);
    address rando = address(0xBAD);

    uint256 constant MEMBER_HAT = 100; // President identity hat
    uint256 constant MEMBER_HAT2 = 101; // VP identity hat
    uint256 constant MEMBER_HAT3 = 102; // spare identity hat
    uint256 constant GROUP_HAT = 500; // Executives marker hat
    uint256 constant GROUP_HAT2 = 501; // second marker
    uint256 constant VOUCHER_HAT = 400;

    event HatClaimed(address indexed wearer, uint256 indexed hatId);
    event GroupEligibilitySet(uint256 indexed groupHatId, uint256[] memberHats);
    event HatConfigUpdated(uint256 indexed hatId, uint32 newMaxSupply);
    event RoleManagerSet(address indexed roleManager);
    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );

    function setUp() public {
        hats = new MockHatsEligibilityAware();

        EligibilityModule eligibilityImpl = new EligibilityModule();
        ToggleModule toggleImpl = new ToggleModule();

        UpgradeableBeacon eligibilityBeacon = new UpgradeableBeacon(address(eligibilityImpl), address(this));
        UpgradeableBeacon toggleBeacon = new UpgradeableBeacon(address(toggleImpl), address(this));

        bytes memory eligibilityInit =
            abi.encodeWithSelector(EligibilityModule.initialize.selector, superAdmin, address(hats), address(0));
        bytes memory toggleInit = abi.encodeWithSelector(ToggleModule.initialize.selector, superAdmin);

        eligibility = EligibilityModule(address(new BeaconProxy(address(eligibilityBeacon), eligibilityInit)));
        toggle = ToggleModule(address(new BeaconProxy(address(toggleBeacon), toggleInit)));

        // Wire the mock Hats to consult THIS module for eligibility (models the Hats invariant that
        // balanceOf tracks live eligibility, so losing a member hat auto-zeroes a derived marker).
        hats.setEligibilityModule(address(eligibility));

        vm.startPrank(superAdmin);
        eligibility.setToggleModule(address(toggle));
        toggle.setEligibilityModule(address(eligibility));
        eligibility.setRoleManager(roleManagerAddr);
        vm.stopPrank();
    }

    /*───────────────────────────── helpers ─────────────────────────────*/

    /// @dev Makes `w` an actual wearer of `hat`: explicit eligibility (true,true) + mint.
    function _becomeWearer(address w, uint256 hat) internal {
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(w, hat, true, true);
        hats.mintHat(hat, w);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _two(uint256 a0, uint256 a1) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = a0;
        a[1] = a1;
    }

    /*═══════════════════════════════════ DERIVED ELIGIBILITY ═══════════════════════════════════*/

    function testDerivedGrantsEligibilityToMemberWearer() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
        _becomeWearer(alice, MEMBER_HAT);

        (bool eligible, bool standing) = eligibility.getWearerStatus(alice, GROUP_HAT);
        assertTrue(eligible && standing, "member-hat wearer should be derived-eligible for the marker");

        // Eligibility alone confers NO balance (C-1): not a wearer until a mint happens.
        assertFalse(hats.isWearerOfHat(alice, GROUP_HAT), "derived eligibility must not mint the marker");
        // But Hats.isEligible IS true — the paymaster pre-claim sponsorship path (PLAN 1.4c).
        assertTrue(hats.isEligible(alice, GROUP_HAT), "isEligible must be true pre-claim for sponsorship");
    }

    function testDerivedBalanceRequiresMintThenAutoZeroesOnLosingMemberHat() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
        _becomeWearer(alice, MEMBER_HAT);

        // No balance until minted, even though eligible.
        assertEq(hats.balanceOf(alice, GROUP_HAT), 0, "no marker balance before mint");

        // Self-claim the marker (derived source).
        vm.prank(alice);
        eligibility.claimHat(GROUP_HAT);
        assertEq(hats.balanceOf(alice, GROUP_HAT), 1, "marker minted");
        assertTrue(hats.isWearerOfHat(alice, GROUP_HAT), "now wearing marker");

        // Lose the last member identity hat -> derived eligibility evaporates -> balance auto-zeroes.
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(alice, MEMBER_HAT, false, false);

        (bool eligible,) = eligibility.getWearerStatus(alice, GROUP_HAT);
        assertFalse(eligible, "marker eligibility revoked once last member hat lost");
        assertEq(hats.balanceOf(alice, GROUP_HAT), 0, "marker balance auto-zeroed (no burn call)");
    }

    function testExplicitKickBeatsDerivedMembership() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
        _becomeWearer(alice, MEMBER_HAT);
        hats.mintHat(GROUP_HAT, alice);

        // Explicit ban on the marker itself must win over derived membership.
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(alice, GROUP_HAT, false, false);

        (bool eligible, bool standing) = eligibility.getWearerStatus(alice, GROUP_HAT);
        assertFalse(eligible, "kick wins over derived");
        assertFalse(standing, "kick zeroes standing");
        assertEq(hats.balanceOf(alice, GROUP_HAT), 0, "kicked wearer holds no balance");
    }

    function testGetGroupMemberHatsReflectsConfig() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _two(MEMBER_HAT, MEMBER_HAT2));
        uint256[] memory m = eligibility.getGroupMemberHats(GROUP_HAT);
        assertEq(m.length, 2);
        assertEq(m[0], MEMBER_HAT);
        assertEq(m[1], MEMBER_HAT2);

        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, new uint256[](0)); // clear
        assertEq(eligibility.getGroupMemberHats(GROUP_HAT).length, 0);
    }

    function testSetGroupEligibilityEmitsEvent() public {
        vm.prank(superAdmin);
        vm.expectEmit(true, false, false, true, address(eligibility));
        emit GroupEligibilitySet(GROUP_HAT, _one(MEMBER_HAT));
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
    }

    /*═══════════════════════════ BIDIRECTIONAL DERIVED <-> VOUCH GUARD ═══════════════════════════*/

    function testSetGroupEligibilityRevertsOnVouchEnabledHat() public {
        vm.prank(superAdmin);
        eligibility.configureVouching(GROUP_HAT, 2, VOUCHER_HAT, false); // enabled

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DerivedConflictsWithVouch.selector);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
    }

    function testConfigureVouchingRevertsOnDerivedHat() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DerivedConflictsWithVouch.selector);
        eligibility.configureVouching(GROUP_HAT, 2, VOUCHER_HAT, false);
    }

    function testBatchConfigureVouchingRevertsOnDerivedHat() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        uint256[] memory hatIds = _one(GROUP_HAT);
        uint32[] memory quorums = new uint32[](1);
        quorums[0] = 2;
        uint256[] memory membership = _one(VOUCHER_HAT);
        bool[] memory combine = new bool[](1);
        combine[0] = false;

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.DerivedConflictsWithVouch.selector);
        eligibility.batchConfigureVouching(hatIds, quorums, membership, combine);
    }

    function testDisablingVouchingOnDerivedHatIsSafe() public {
        // A hat with derived config may still receive a *disabling* vouch call (quorum 0) with no revert.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        vm.prank(superAdmin);
        eligibility.configureVouching(GROUP_HAT, 0, VOUCHER_HAT, false); // disabled — allowed
        assertFalse(eligibility.isVouchingEnabled(GROUP_HAT));
    }

    /*═══════════════════════════════ NESTING + REFCOUNT LIFECYCLE ═══════════════════════════════*/

    function testNestingRejectedWhenMemberHasDerivedConfig() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT2, _one(MEMBER_HAT)); // GROUP_HAT2 is now a derived hat

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        eligibility.setGroupEligibility(GROUP_HAT, _one(GROUP_HAT2)); // member has its own derived config
    }

    function testNestingRejectedWhenTargetIsMemberElsewhere() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT)); // MEMBER_HAT refcount -> 1

        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        eligibility.setGroupEligibility(MEMBER_HAT, _one(MEMBER_HAT2)); // MEMBER_HAT is a member elsewhere
    }

    function testNestingRejectedOnSelfReference() public {
        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        eligibility.setGroupEligibility(GROUP_HAT, _one(GROUP_HAT));
    }

    function testRefcountLifecycleAcrossReplaceAndClear() public {
        // Config with two members: both get refcount 1.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _two(MEMBER_HAT, MEMBER_HAT2));

        // MEMBER_HAT is now a member elsewhere -> cannot itself become a derived hat.
        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        eligibility.setGroupEligibility(MEMBER_HAT, _one(MEMBER_HAT3));

        // Replace the list with only MEMBER_HAT2: MEMBER_HAT's refcount drops to 0.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT2));

        // MEMBER_HAT (refcount 0 now) CAN become a derived hat.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(MEMBER_HAT, _one(MEMBER_HAT3));
        assertEq(
            eligibility.getGroupMemberHats(MEMBER_HAT).length, 1, "MEMBER_HAT became derived after refcount cleared"
        );

        // MEMBER_HAT2 is still a member of GROUP_HAT -> still cannot become derived.
        vm.prank(superAdmin);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        eligibility.setGroupEligibility(MEMBER_HAT2, _one(MEMBER_HAT3));

        // Clear GROUP_HAT -> MEMBER_HAT2 refcount drops to 0 -> now MEMBER_HAT2 can become derived.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, new uint256[](0));
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(MEMBER_HAT2, _one(MEMBER_HAT3));
        assertEq(eligibility.getGroupMemberHats(MEMBER_HAT2).length, 1, "MEMBER_HAT2 became derived after clear");
    }

    /*═══════════════════════════════════ CLAIM — SPECIFIC SOURCES ═══════════════════════════════════*/

    function testClaimHatExplicitRuleSource() public {
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(eligibility));
        emit HatClaimed(alice, MEMBER_HAT);
        eligibility.claimHat(MEMBER_HAT);

        assertTrue(hats.isWearerOfHat(alice, MEMBER_HAT));
    }

    function testClaimHatVouchSource() public {
        uint256 hatX = 700;
        vm.prank(superAdmin);
        eligibility.configureVouching(hatX, 1, VOUCHER_HAT, false);
        _becomeWearer(voucher, VOUCHER_HAT);

        vm.prank(voucher);
        eligibility.vouchFor(alice, hatX);

        vm.prank(alice);
        eligibility.claimHat(hatX);
        assertTrue(hats.isWearerOfHat(alice, hatX));
    }

    function testClaimHatEmailSource() public {
        uint256 hatX = 701;
        vm.prank(superAdmin);
        eligibility.setEmailVerified(alice, _one(hatX));

        vm.prank(alice);
        eligibility.claimHat(hatX);
        assertTrue(hats.isWearerOfHat(alice, hatX));
    }

    function testClaimHatDerivedSource() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
        _becomeWearer(alice, MEMBER_HAT);

        vm.prank(alice);
        eligibility.claimHat(GROUP_HAT);
        assertTrue(hats.isWearerOfHat(alice, GROUP_HAT));
    }

    function testClaimHatDefaultOpenReverts() public {
        uint256 hatX = 702;
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(hatX, true, true); // default-open, no specific source

        (bool eligible, bool standing) = eligibility.getWearerStatus(alice, hatX);
        assertTrue(eligible && standing, "default-open makes wearer eligible...");

        vm.prank(alice);
        vm.expectRevert(EligibilityModule.NotClaimableHat.selector); // ...but not CLAIMABLE (H-03)
        eligibility.claimHat(hatX);
    }

    function testClaimHatAlreadyWearingReverts() public {
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        vm.prank(alice);
        eligibility.claimHat(MEMBER_HAT);

        vm.prank(alice);
        vm.expectRevert(EligibilityModule.AlreadyWearingHat.selector);
        eligibility.claimHat(MEMBER_HAT);
    }

    /*═══════════════════════════════════ CLAIM — BATCH (OFFER ACCEPTANCE) ═══════════════════════════════════*/

    function testClaimHatsOfferAcceptanceIdentityThenMarker() public {
        // The offer: explicit rule on the identity hat + derived config on the marker.
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        // Accept both in ONE tx: identity minted first makes alice derived-eligible for the marker
        // within the same call.
        vm.prank(alice);
        eligibility.claimHats(_two(MEMBER_HAT, GROUP_HAT));

        assertTrue(hats.isWearerOfHat(alice, MEMBER_HAT), "identity minted");
        assertTrue(hats.isWearerOfHat(alice, GROUP_HAT), "marker minted via same-call derivation");
    }

    function testClaimHatsSkipsAlreadyWornEntries() public {
        // alice already wears the identity hat; only the marker should mint.
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        _becomeWearer(alice, MEMBER_HAT); // now wearing
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        vm.prank(alice);
        eligibility.claimHats(_two(MEMBER_HAT, GROUP_HAT)); // MEMBER_HAT skipped, GROUP_HAT minted
        assertTrue(hats.isWearerOfHat(alice, GROUP_HAT));
    }

    function testClaimHatsRevertsOnIneligibleEntryAndRollsBack() public {
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT); // claimable
        uint256 hatY = 703;
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(hatY, true, true); // default-open => not claimable

        vm.prank(alice);
        vm.expectRevert(EligibilityModule.NotClaimableHat.selector);
        eligibility.claimHats(_two(MEMBER_HAT, hatY));

        // Whole call rolled back: the first (valid) entry must NOT have minted.
        assertFalse(hats.isWearerOfHat(alice, MEMBER_HAT), "batch is atomic - no partial mint");
    }

    function testClaimHatsLengthCap() public {
        uint256[] memory many = new uint256[](21);
        for (uint256 i; i < 21; i++) {
            many[i] = 1000 + i;
        }
        vm.prank(alice);
        vm.expectRevert(EligibilityModule.TooManyClaims.selector);
        eligibility.claimHats(many);
    }

    /*═══════════════════════════════════ GRANT-ONLY AUTHORITY MATRIX ═══════════════════════════════════*/

    function testGrantWearerEligibilitySuperAdminOk() public {
        vm.prank(superAdmin);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        (bool e, bool s) = eligibility.getWearerRules(alice, MEMBER_HAT);
        assertTrue(e && s, "grant sets (true,true)");
        assertTrue(eligibility.hasSpecificWearerRules(alice, MEMBER_HAT));
    }

    function testGrantWearerEligibilityRoleManagerOk() public {
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        (bool e, bool s) = eligibility.getWearerRules(alice, MEMBER_HAT);
        assertTrue(e && s);
    }

    function testGrantWearerEligibilityRandoReverts() public {
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
    }

    /*═══════════════════════════════════ ROLE MANAGER AUTH SCOPING ═══════════════════════════════════*/

    function testRoleManagerCanCallWhitelistedFunctions() public {
        vm.startPrank(roleManagerAddr);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
        eligibility.grantWearerEligibility(alice, MEMBER_HAT);
        eligibility.updateHatConfig(MEMBER_HAT, 5);
        eligibility.setDefaultEligibility(800, false, true);
        eligibility.configureVouching(801, 2, VOUCHER_HAT, false);
        eligibility.mintHatToAddress(MEMBER_HAT, bob);
        eligibility.clearWearerEligibility(alice, MEMBER_HAT);
        eligibility.updateHatMetadata(MEMBER_HAT, "Pres", bytes32(0));
        vm.stopPrank();
    }

    function testRoleManagerCannotCallSuperAdminOnlyFunctions() public {
        vm.startPrank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.transferSuperAdmin(rando);

        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.setToggleModule(rando);

        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.setWearerEligibility(alice, MEMBER_HAT, false, false); // bans stay governance-only

        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.pause();

        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.setRoleManager(rando);
        vm.stopPrank();
    }

    function testRandoCannotCallWhitelistedFunctions() public {
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.updateHatConfig(MEMBER_HAT, 5);
    }

    function testSetRoleManagerOnlySuperAdminAndClear() public {
        vm.prank(superAdmin);
        vm.expectEmit(true, false, false, false, address(eligibility));
        emit RoleManagerSet(address(0xFEED));
        eligibility.setRoleManager(address(0xFEED));
        assertEq(eligibility.roleManager(), address(0xFEED));

        // Clearing to address(0) disables the secondary admin entirely.
        vm.prank(superAdmin);
        eligibility.setRoleManager(address(0));
        assertEq(eligibility.roleManager(), address(0));

        // The old roleManager address can no longer call whitelisted functions.
        vm.prank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));
    }

    /*═══════════════════════════════════ updateHatConfig / Checked variant ═══════════════════════════════════*/

    function testUpdateHatConfigSetsMaxSupplyAndEmits() public {
        vm.prank(roleManagerAddr);
        vm.expectEmit(true, false, false, true, address(eligibility));
        emit HatConfigUpdated(MEMBER_HAT, 42);
        eligibility.updateHatConfig(MEMBER_HAT, 42);
        assertEq(hats.getHatMaxSupply(MEMBER_HAT), 42);
    }

    function testCreateHatWithEligibilityCheckedDriftReverts() public {
        uint256 parent = 900; // MockHats.createHat returns parent + 1
        EligibilityModule.CreateHatParams memory params = _emptyCreateParams(parent);

        vm.prank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.UnexpectedHatId.selector);
        eligibility.createHatWithEligibilityChecked(params, parent + 2); // wrong expected id
    }

    function testCreateHatWithEligibilityCheckedMatchingIdSucceeds() public {
        uint256 parent = 901;
        EligibilityModule.CreateHatParams memory params = _emptyCreateParams(parent);

        vm.prank(roleManagerAddr);
        uint256 id = eligibility.createHatWithEligibilityChecked(params, parent + 1);
        assertEq(id, parent + 1);
    }

    function testCreateHatWithEligibilityCheckedZeroSkipsCheck() public {
        uint256 parent = 902;
        EligibilityModule.CreateHatParams memory params = _emptyCreateParams(parent);

        vm.prank(roleManagerAddr);
        uint256 id = eligibility.createHatWithEligibilityChecked(params, 0); // 0 = skip drift guard
        assertEq(id, parent + 1);
    }

    function _emptyCreateParams(uint256 parent) internal pure returns (EligibilityModule.CreateHatParams memory) {
        address[] memory noWearers = new address[](0);
        bool[] memory noFlags = new bool[](0);
        return EligibilityModule.CreateHatParams({
            parentHatId: parent,
            details: "role",
            maxSupply: 10,
            _mutable: false,
            imageURI: "",
            defaultEligible: false,
            defaultStanding: true,
            mintToAddresses: noWearers,
            wearerEligibleFlags: noFlags,
            wearerStandingFlags: noFlags
        });
    }

    /*═══════════════════════════════════ REGRESSIONS (ADDITIVE / ONBOARDING) ═══════════════════════════════════*/

    function testVouchedNotWearingStaysEligibleForPaymasterOnboarding() public {
        uint256 hatX = 950;
        vm.prank(superAdmin);
        eligibility.configureVouching(hatX, 1, VOUCHER_HAT, false);
        _becomeWearer(voucher, VOUCHER_HAT);
        vm.prank(voucher);
        eligibility.vouchFor(alice, hatX);

        // Eligible (and Hats.isEligible) WITHOUT wearing — the paymaster CLAIM-subject pre-check
        // (PaymasterHub._validateSubjectEligibility) must still sponsor the claim tx (PLAN 1.4c).
        (bool eligible, bool standing) = eligibility.getWearerStatus(alice, hatX);
        assertTrue(eligible && standing, "vouched user eligible pre-claim");
        assertTrue(hats.isEligible(alice, hatX), "Hats.isEligible true pre-claim");
        assertFalse(hats.isWearerOfHat(alice, hatX), "not yet wearing");
    }

    function testNoDerivedConfigReturnsUnchangedPaths() public {
        // Presence of derived config on GROUP_HAT must NOT affect unrelated hats' resolution.
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(GROUP_HAT, _one(MEMBER_HAT));

        // (a) default-eligible hat: unchanged.
        uint256 defHat = 960;
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(defHat, true, true);
        (bool de,) = eligibility.getWearerStatus(bob, defHat);
        assertTrue(de, "default path unaffected");

        // (b) explicit kick on a non-derived hat: unchanged (false,false).
        uint256 kickHat = 961;
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(bob, kickHat, false, false);
        (bool ke, bool ks) = eligibility.getWearerStatus(bob, kickHat);
        assertFalse(ke);
        assertFalse(ks);

        // (c) a hat with no config at all: (false,false), and NOT derived-eligible for bob.
        (bool ne,) = eligibility.getWearerStatus(bob, 962);
        assertFalse(ne, "no-config hat stays ineligible");
    }
}
