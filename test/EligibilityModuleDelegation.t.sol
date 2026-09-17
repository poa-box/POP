// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/EligibilityModule.sol";
import "../src/ToggleModule.sol";
import "./mocks/MockHatsEligibilityAware.sol";

/**
 * @title EligibilityModuleDelegationTest
 * @notice W12 coverage for the delegation wave: FIX 0 explicit-ban supremacy (an explicit (false,false)
 *         rule beats vouch/email/derived/default on EVERY path), FIX 1 provenance (0x04 DELEGATION_MANAGED
 *         bit set by kicks + RM-mediated writes, auto-cleared by every direct superAdmin writer), and
 *         Primitive B (the delegated-kick lifecycle: configureKick / kickWearer / finalizeKick / cancelKick
 *         / unkickWearer with governance supremacy, effect delays, and the honest KickIneffective belt).
 *         Uses {MockHatsEligibilityAware} so `balanceOf`/`isWearerOfHat` reflect LIVE eligibility — an
 *         explicit ban zeroes the balance with no burn call, exactly as the supremacy invariant relies on.
 */
contract EligibilityModuleDelegationTest is Test {
    EligibilityModule eligibility;
    ToggleModule toggle;
    MockHatsEligibilityAware hats;

    address superAdmin = address(0xA11CE);
    address roleManagerAddr = address(0x501E);
    address kicker = address(0x11C6);
    address victim = address(0x71C7);
    address voucher = address(0xC0FFEE);
    address voucher2 = address(0xC0FFEF);
    address rando = address(0xBAD);

    uint256 constant HAT = 100; // the target identity hat
    uint256 constant KICKER_HAT = 200; // wearers may kick/unkick HAT wearers
    uint256 constant MEMBERSHIP_HAT = 400; // who may vouch
    uint256 constant MARKER = 500; // derived group marker
    uint256 constant MEMBER_HAT = 501; // derived member identity

    event KickConfigSet(uint256 indexed hatId, uint256 indexed kickerHatId, uint32 delaySecs, bool enabled);
    event KickPending(uint256 indexed hatId, address indexed wearer, address indexed kicker, uint64 effectiveAt);
    event KickCancelled(uint256 indexed hatId, address indexed wearer, address indexed by);
    event WearerKicked(uint256 indexed hatId, address indexed wearer, address indexed kicker);
    event WearerUnkicked(uint256 indexed hatId, address indexed wearer, address indexed by);

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

        hats.setEligibilityModule(address(eligibility));

        vm.startPrank(superAdmin);
        eligibility.setToggleModule(address(toggle));
        toggle.setEligibilityModule(address(eligibility));
        eligibility.setRoleManager(roleManagerAddr);
        vm.stopPrank();

        // The kicker wears the kicker hat (explicit eligibility + mint).
        _becomeWearer(kicker, KICKER_HAT);
    }

    /*───────────────────────────── helpers ─────────────────────────────*/

    function _becomeWearer(address w, uint256 hat) internal {
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(w, hat, true, true);
        hats.mintHat(hat, w);
    }

    function _configureImmediateKick() internal {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 0, true);
    }

    function _flags(address w, uint256 hat) internal view returns (bool hasRule, uint8 f) {
        return eligibility.getWearerRuleFlags(w, hat);
    }

    function _status(address w, uint256 hat) internal view returns (bool e, bool s) {
        return eligibility.getWearerStatus(w, hat);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _oneAddr(address v) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = v;
    }

    function _oneBool(bool v) internal pure returns (bool[] memory a) {
        a = new bool[](1);
        a[0] = v;
    }

    /// @dev Make `w` vouch-eligible for HAT under combine=`combine`; returns HAT with quorum-1 met.
    function _setupVouchWearer(address w, bool combine) internal {
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 1, MEMBERSHIP_HAT, combine);
        _becomeWearer(voucher, MEMBERSHIP_HAT);
        vm.prank(voucher);
        eligibility.vouchFor(w, HAT);
    }

    /*═══════════════════════════════════ FIX 0 — SUPREMACY TRUTH TABLE ═══════════════════════════════════*/

    function testSupremacyExplicitBanBeatsVouchCombineTrue() public {
        _setupVouchWearer(victim, true); // vouch quorum met, combine=true
        (bool e0,) = _status(victim, HAT);
        assertTrue(e0, "vouched wearer eligible before ban");

        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false); // governance ban

        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "explicit (false,false) beats a met vouch quorum under combine=true");
    }

    function testSupremacyExplicitBanBeatsVouchCombineFalse() public {
        _setupVouchWearer(victim, false); // vouch quorum met, combine=false
        (bool e0,) = _status(victim, HAT);
        assertTrue(e0, "vouched wearer eligible before ban");

        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false);

        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "explicit ban beats vouch even under combine=false (which used to ignore rules)");
    }

    function testSupremacyExplicitBanBeatsEmail() public {
        vm.prank(superAdmin);
        eligibility.setEmailVerified(victim, _one(HAT));
        (bool e0,) = _status(victim, HAT);
        assertTrue(e0, "email-verified eligible before ban");

        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false);
        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "explicit ban beats email");
    }

    function testSupremacyExplicitBanBeatsDerived() public {
        vm.prank(superAdmin);
        eligibility.setGroupEligibility(MARKER, _one(MEMBER_HAT));
        _becomeWearer(victim, MEMBER_HAT);
        (bool e0,) = _status(victim, MARKER);
        assertTrue(e0, "derived-eligible before ban");

        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, MARKER, false, false);
        (bool e, bool s) = _status(victim, MARKER);
        assertFalse(e || s, "explicit ban beats derived membership");
    }

    function testSupremacyExplicitBanBeatsDefault() public {
        vm.prank(superAdmin);
        eligibility.setDefaultEligibility(HAT, true, true);
        (bool e0,) = _status(victim, HAT);
        assertTrue(e0, "default-open eligible before ban");

        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false);
        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "explicit ban beats default-open");
    }

    function testExplicitTrueTrueKeepsAdditiveOR() public {
        // combine=true, quorum NOT met (no vouches): explicit (true,true) must NOT short-circuit — it
        // combines additively and confers eligibility via the hierarchy leg.
        vm.prank(superAdmin);
        eligibility.configureVouching(HAT, 2, MEMBERSHIP_HAT, true);
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, true, true);

        (bool e, bool s) = _status(victim, HAT);
        assertTrue(e && s, "explicit (true,true) stays additive (no supremacy short-circuit)");
    }

    /*═══════════════════════════════════ FIX 1 — PROVENANCE LIFECYCLE ═══════════════════════════════════*/

    function testProvenanceSetByRoleManagerGrant() public {
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(victim, HAT);
        (bool hasRule, uint8 f) = _flags(victim, HAT);
        assertTrue(hasRule, "rule exists");
        assertEq(f, 0x07, "RM-mediated grant carries (true,true|0x04)");
    }

    function testProvenanceNotSetBySuperAdminGrant() public {
        vm.prank(superAdmin);
        eligibility.grantWearerEligibility(victim, HAT);
        (, uint8 f) = _flags(victim, HAT);
        assertEq(f, 0x03, "direct superAdmin grant stays governance-owned (no 0x04)");
    }

    function testProvenanceSetByKick() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT); // (true,true) governance grant, kickable
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
        (bool hasRule, uint8 f) = _flags(victim, HAT);
        assertTrue(hasRule, "kick writes a rule");
        assertEq(f, 0x04, "kick writes (false,false|0x04)");
    }

    /// Walk all SIX direct superAdmin writers — each must overwrite the flags byte and clear the 0x04 bit.
    function testProvenanceClearedByAllDirectSuperAdminWriters() public {
        // Writer 1: setWearerEligibility.
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, true, true);
        _assertNoProvenance(victim, HAT, "setWearerEligibility");

        // Writer 2: setBulkWearerEligibility.
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.setBulkWearerEligibility(_oneAddr(victim), HAT, true, true);
        _assertNoProvenance(victim, HAT, "setBulkWearerEligibility");

        // Writer 3: batchSetWearerEligibility.
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.batchSetWearerEligibility(HAT, _oneAddr(victim), _oneBool(true), _oneBool(true));
        _assertNoProvenance(victim, HAT, "batchSetWearerEligibility");

        // Writer 4: batchSetWearerEligibilityMultiHat.
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.batchSetWearerEligibilityMultiHat(_oneAddr(victim), _one(HAT), true, true);
        _assertNoProvenance(victim, HAT, "batchSetWearerEligibilityMultiHat");

        // Writer 5: clearWearerEligibility (superAdmin) — removes the rule entirely.
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.clearWearerEligibility(victim, HAT);
        (bool hasRule5,) = _flags(victim, HAT);
        assertFalse(hasRule5, "clearWearerEligibility removes rule + provenance");

        // Writer 6: grantWearerEligibility (superAdmin path).
        _seedProvenance(victim, HAT);
        vm.prank(superAdmin);
        eligibility.grantWearerEligibility(victim, HAT);
        _assertNoProvenance(victim, HAT, "grantWearerEligibility(superAdmin)");
    }

    function _seedProvenance(address w, uint256 hat) internal {
        // RM grant gives a (true,true|0x04) provenance-set starting state.
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(w, hat);
        (, uint8 f) = _flags(w, hat);
        assertEq(f, 0x07, "seed provenance");
    }

    function _assertNoProvenance(address w, uint256 hat, string memory ctx) internal view {
        (, uint8 f) = _flags(w, hat);
        assertEq(f & 0x04, 0, ctx);
    }

    /*═══════════════════════════════════ KICK — GOVERNANCE SUPREMACY ═══════════════════════════════════*/

    function testKickRevertsOnGovernanceBannedWearer() public {
        _configureImmediateKick();
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false); // governance ban (0x00)

        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.CannotKickGovernanceRuled.selector);
        eligibility.kickWearer(victim, HAT);
    }

    function testKickRevertsOnGovernancePartialRule() public {
        _configureImmediateKick();
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, true, false); // governance non-(true,true) (0x01)

        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.CannotKickGovernanceRuled.selector);
        eligibility.kickWearer(victim, HAT);
    }

    function testKickAllowedOnGovernanceTrueTrueGrant() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT); // governance (true,true) grant is kickable
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
        (, uint8 f) = _flags(victim, HAT);
        assertEq(f, 0x04, "kick overrides a (true,true) grant");
    }

    function testKickRevertsForNonKickerHatWearer() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT);
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotAuthorizedToKick.selector);
        eligibility.kickWearer(victim, HAT);
    }

    function testKickRevertsWhenConfigDisabled() public {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 0, false); // disabled
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.KickNotEnabled.selector);
        eligibility.kickWearer(victim, HAT);
    }

    /*═══════════════════════════════════ KICK — IMMEDIATE (delay 0) ═══════════════════════════════════*/

    function testImmediateKickBurnsAndBans() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT);
        assertTrue(hats.isWearerOfHat(victim, HAT), "wearing before kick");

        vm.prank(kicker);
        vm.expectEmit(true, true, true, false, address(eligibility));
        emit WearerKicked(HAT, victim, kicker);
        eligibility.kickWearer(victim, HAT);

        assertFalse(hats.isWearerOfHat(victim, HAT), "burned by kick");
        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "banned by kick");
        (, uint8 f) = _flags(victim, HAT);
        assertEq(f, 0x04, "delegated-kick provenance");
    }

    /// @notice KickIneffective belt: under FIX 0 supremacy an explicit (false,false|0x04) rule ALWAYS
    ///         resolves to (false,false), so the reconciled wearer can never still hold the hat — the
    ///         honest-revert is unreachable by construction. We assert the post-kick invariant that makes
    ///         it so (no path leaves the wearer seated), documenting why no still-wearing case exists.
    function testKickIneffectiveUnreachableUnderSupremacy() public {
        _configureImmediateKick();
        // Even a vouch-quorum-met wearer (the historical bypass) is fully removed — supremacy wins, so
        // isWearerOfHat is false after the kick and KickIneffective never fires.
        _setupVouchWearer(victim, true);
        vm.prank(victim);
        eligibility.claimHat(HAT); // now wearing via vouch source
        assertTrue(hats.isWearerOfHat(victim, HAT), "wearing via vouch quorum");

        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT); // does NOT revert KickIneffective
        assertFalse(hats.isWearerOfHat(victim, HAT), "vouched wearer fully removed under supremacy");
    }

    /*═══════════════════════════════════ KICK — DELAYED LIFECYCLE ═══════════════════════════════════*/

    function testDelayedKickPendsThenFinalizes() public {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, true);
        _becomeWearer(victim, HAT);

        uint64 expectedAt = uint64(block.timestamp) + 1000;
        vm.prank(kicker);
        vm.expectEmit(true, true, true, true, address(eligibility));
        emit KickPending(HAT, victim, kicker, expectedAt);
        eligibility.kickWearer(victim, HAT);

        (uint64 at, address k) = eligibility.getPendingKick(HAT, victim);
        assertEq(at, expectedAt, "pending recorded");
        assertEq(k, kicker, "pending kicker recorded");
        assertTrue(hats.isWearerOfHat(victim, HAT), "still wearing during delay");

        // Too early.
        vm.expectRevert(EligibilityModule.KickNotReady.selector);
        eligibility.finalizeKick(victim, HAT);

        // After the delay: permissionless finalize applies the kick.
        vm.warp(block.timestamp + 1000);
        vm.prank(rando);
        vm.expectEmit(true, true, true, false, address(eligibility));
        emit WearerKicked(HAT, victim, kicker);
        eligibility.finalizeKick(victim, HAT);

        assertFalse(hats.isWearerOfHat(victim, HAT), "burned after finalize");
        (uint64 at2,) = eligibility.getPendingKick(HAT, victim);
        assertEq(at2, 0, "pending cleared after finalize");
    }

    function testFinalizeRevertsWhenNoPending() public {
        vm.expectRevert(EligibilityModule.NoPendingKick.selector);
        eligibility.finalizeKick(victim, HAT);
    }

    function testFinalizeRevertsWhenConfigDisabled() public {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, true);
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);

        // Governance revokes the delegation before the delay elapses — the pending kick dies with it.
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, false);

        vm.warp(block.timestamp + 1000);
        vm.expectRevert(EligibilityModule.NotAuthorizedToKick.selector);
        eligibility.finalizeKick(victim, HAT);
        assertTrue(hats.isWearerOfHat(victim, HAT), "victim keeps the hat - pending kick never applied");
    }

    function testFinalizeRevertsWhenKickerLostHat() public {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, true);
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);

        // The original kicker loses their seat — their pending kick dies with their authority.
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(kicker, KICKER_HAT, false, false);

        vm.warp(block.timestamp + 1000);
        vm.expectRevert(EligibilityModule.NotAuthorizedToKick.selector);
        eligibility.finalizeKick(victim, HAT);
    }

    function testFinalizeRevertsWhenGovernanceBanWrittenDuringDelay() public {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, true);
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);

        // Governance writes its own ban during the delay — finalize must not flip its provenance.
        // (setWearerEligibility voids the pending entry, so finalize reverts NoPendingKick.)
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false);

        vm.warp(block.timestamp + 1000);
        vm.expectRevert(EligibilityModule.NoPendingKick.selector);
        eligibility.finalizeKick(victim, HAT);
    }

    /*═══════════════════════════════════ KICK — CANCEL ═══════════════════════════════════*/

    function _pendVictim() internal {
        vm.prank(superAdmin);
        eligibility.configureKick(HAT, KICKER_HAT, 1000, true);
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
    }

    function testCancelByKicker() public {
        _pendVictim();
        vm.prank(kicker);
        vm.expectEmit(true, true, true, false, address(eligibility));
        emit KickCancelled(HAT, victim, kicker);
        eligibility.cancelKick(victim, HAT);
        (uint64 at,) = eligibility.getPendingKick(HAT, victim);
        assertEq(at, 0, "pending cancelled");
    }

    function testCancelBySuperAdmin() public {
        _pendVictim();
        vm.prank(superAdmin);
        eligibility.cancelKick(victim, HAT);
        (uint64 at,) = eligibility.getPendingKick(HAT, victim);
        assertEq(at, 0, "pending cancelled by governance");
    }

    function testCancelByRandoReverts() public {
        _pendVictim();
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotAuthorizedToKick.selector);
        eligibility.cancelKick(victim, HAT);
    }

    function testPendingVoidedByAnyRuleWrite() public {
        _pendVictim();
        // Any governance rule write for the same (wearer, hat) voids the pending kick.
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, true, true);
        (uint64 at,) = eligibility.getPendingKick(HAT, victim);
        assertEq(at, 0, "pending voided by rule write");
        vm.expectRevert(EligibilityModule.NoPendingKick.selector);
        eligibility.finalizeKick(victim, HAT);
    }

    /*═══════════════════════════════════ UNKICK ═══════════════════════════════════*/

    function testUnkickRestoresClaimableState() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
        assertFalse(hats.isWearerOfHat(victim, HAT), "kicked out");

        vm.prank(kicker);
        vm.expectEmit(true, true, true, false, address(eligibility));
        emit WearerUnkicked(HAT, victim, kicker);
        eligibility.unkickWearer(victim, HAT);

        (, uint8 f) = _flags(victim, HAT);
        assertEq(f, 0x07, "unkick restores (true,true|0x04)");
        assertFalse(hats.isWearerOfHat(victim, HAT), "not auto-reminted");

        // The un-kicked wearer self-re-mints via claimHat (specific-source check passes on 0x07).
        vm.prank(victim);
        eligibility.claimHat(HAT);
        assertTrue(hats.isWearerOfHat(victim, HAT), "re-claimed after unkick");
    }

    function testUnkickRevertsOnGovernanceBan() public {
        _configureImmediateKick();
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false); // governance ban (0x00), NOT 0x04
        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.NotDelegatedKick.selector);
        eligibility.unkickWearer(victim, HAT);
    }

    function testUnkickRevertsWhenNoRule() public {
        _configureImmediateKick();
        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.NotDelegatedKick.selector);
        eligibility.unkickWearer(victim, HAT);
    }

    function testUnkickRevertsOnGrantRule() public {
        _configureImmediateKick();
        vm.prank(roleManagerAddr);
        eligibility.grantWearerEligibility(victim, HAT); // 0x07, not exactly 0x04
        vm.prank(kicker);
        vm.expectRevert(EligibilityModule.NotDelegatedKick.selector);
        eligibility.unkickWearer(victim, HAT);
    }

    function testUnkickRevertsForNonKicker() public {
        _configureImmediateKick();
        _becomeWearer(victim, HAT);
        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotAuthorizedToKick.selector);
        eligibility.unkickWearer(victim, HAT);
    }

    /*═══════════════════════════════════ VOUCH INTERACTIONS ═══════════════════════════════════*/

    function testVouchStateSurvivesKickAndReVouchCannotBypassBan() public {
        _configureImmediateKick();
        _setupVouchWearer(victim, true); // quorum 1 met, combine=true
        vm.prank(victim);
        eligibility.claimHat(HAT); // wearing via vouch source

        vm.prank(kicker);
        eligibility.kickWearer(victim, HAT);
        assertFalse(hats.isWearerOfHat(victim, HAT), "kicked despite vouch");

        // Vouch records survive the kick (kept for unkick symmetry).
        assertEq(eligibility.currentVouchCount(HAT, victim), 1, "vouch count preserved");
        assertTrue(eligibility.vouchers(HAT, victim, voucher), "voucher record preserved");

        // Re-vouching (a second voucher) cannot bypass the active supremacy ban.
        _becomeWearer(voucher2, MEMBERSHIP_HAT);
        vm.prank(voucher2);
        eligibility.vouchFor(victim, HAT);
        assertEq(eligibility.currentVouchCount(HAT, victim), 2, "re-vouch counted");

        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "supremacy ban survives re-vouching");
        vm.prank(victim);
        vm.expectRevert(EligibilityModule.NotClaimableHat.selector);
        eligibility.claimHat(HAT);
    }

    /// KUBI-shape regression: a plain governance setWearerEligibility(false,false) now sticks on a
    /// vouch-enabled combine=true hat WITHOUT the historical clearWearerVouches pairing.
    function testKubiGovernanceBanSticksWithoutClearWearerVouches() public {
        _setupVouchWearer(victim, true); // KUBI Executive shape: vouch enabled, combine=true, quorum met
        vm.prank(victim);
        eligibility.claimHat(HAT);
        assertTrue(hats.isWearerOfHat(victim, HAT), "seated via vouch quorum");

        // Governance bans WITHOUT clearing vouches — pre-fix this silently no-op'd (OR with vouch).
        vm.prank(superAdmin);
        eligibility.setWearerEligibility(victim, HAT, false, false);

        (bool e, bool s) = _status(victim, HAT);
        assertFalse(e || s, "ban sticks with no clearWearerVouches");
        assertFalse(hats.isWearerOfHat(victim, HAT), "hat balance auto-zeroed");
    }

    /*═══════════════════════════════════ CONFIG + AUTH ═══════════════════════════════════*/

    function testConfigureKickOnlySuperAdmin() public {
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.configureKick(HAT, KICKER_HAT, 0, true);

        vm.prank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        eligibility.configureKick(HAT, KICKER_HAT, 0, true);
    }

    function testConfigureKickEmitsAndStores() public {
        vm.prank(superAdmin);
        vm.expectEmit(true, true, false, true, address(eligibility));
        emit KickConfigSet(HAT, KICKER_HAT, 42, true);
        eligibility.configureKick(HAT, KICKER_HAT, 42, true);

        EligibilityModule.KickConfig memory cfg = eligibility.getKickConfig(HAT);
        assertEq(cfg.kickerHatId, KICKER_HAT);
        assertEq(cfg.delaySecs, 42);
        assertTrue(cfg.enabled);
    }
}
