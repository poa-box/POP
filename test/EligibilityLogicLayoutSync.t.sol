// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {MockHatsEligibilityAware} from "./mocks/MockHatsEligibilityAware.sol";

/**
 * @title EligibilityLogicLayoutSyncTest — functional ERC-7201 layout-divergence guard
 * @notice EligibilityModule offloads its heavy derived-eligibility / claim / getWearerStatus bodies to
 *         {EligibilityLogic}, a DELEGATECALL library that RE-DECLARES the module's ERC-7201 `Layout`
 *         struct at the SAME storage slot (`keccak256("poa.eligibilitymodule.storage")`). Because the
 *         library executes in the module's storage context, the two Layout definitions MUST stay
 *         byte-identical — field order, types, and count. There is NO compiler check that enforces this:
 *         if someone appends/reorders a field in one struct and not the other, every field AFTER the
 *         divergence point silently reads/writes the WRONG slot, and the module keeps compiling.
 *
 *         This suite is that missing check, expressed FUNCTIONALLY. For every field family the library
 *         touches, it writes the field through one execution context and reads it back through the OTHER:
 *
 *           - LIB-write  → MODULE-read : e.g. `grantWearerEligibility`/`setGroupEligibility` run in the
 *             library and store into `wearerRules`/`hasSpecificWearerRules`/`groupMemberHats`/
 *             `groupMembershipRefCount`; module-native getters (`wearerRules()`, `getGroupMemberHats()`,
 *             the `NestedDerivedHat` refcount guard) must observe those exact values.
 *           - MODULE-write → LIB-read : module-native setters (`setWearerEligibility`,
 *             `setDefaultEligibility`, `configureVouching` + `vouchFor`, `setEmailVerified`) store into
 *             `wearerRules`/`defaultRules`/`vouchConfigs`/`currentVouchCount`/`wearerVouchEpoch`/
 *             `vouchConfigEpoch`/`voucherRecordEpoch`/`vouchers`/`emailVerified`; the library's
 *             `getWearerStatus` (email/vouch/default/kick/derived resolution) must read those exact slots.
 *           - `roleManager` is written module-side and read by the module wrapper's
 *             `onlySuperAdminOrRoleManager` gate; a lib-bodied entrypoint invoked AS the RoleManager
 *             proves the gate and the lib see the same slot.
 *
 *         Any struct drift between {EligibilityModule.Layout} and {EligibilityLogic.Layout} therefore
 *         makes at least one assertion here fail loudly, instead of shipping silent storage corruption.
 *         Uses {MockHatsEligibilityAware} (constant hat ids, no fork) since only EM storage alignment —
 *         not Hats semantics — is under test.
 */
contract EligibilityLogicLayoutSyncTest is Test {
    EligibilityModule internal em;
    ToggleModule internal toggle;
    MockHatsEligibilityAware internal hats;

    address internal superAdmin = makeAddr("superAdmin");
    address internal roleManagerAddr = makeAddr("roleManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal voucher = makeAddr("voucher");

    // Constant hat ids (the mock does not allocate sequential ids for us).
    uint256 internal constant H_RULES = 10; // explicit per-wearer rules
    uint256 internal constant H_DEFAULT = 20; // default rules
    uint256 internal constant H_VOUCH = 30; // vouch config + epochs
    uint256 internal constant MEMBERSHIP_HAT = 31; // who may vouch
    uint256 internal constant H_EMAIL = 40; // email-verified
    uint256 internal constant MARKER = 50; // derived group marker
    uint256 internal constant MEMBER = 51; // derived member identity
    uint256 internal constant MEMBER2 = 52; // spare identity

    function setUp() public {
        hats = new MockHatsEligibilityAware();

        toggle = ToggleModule(
            address(
                new ERC1967Proxy(address(new ToggleModule()), abi.encodeCall(ToggleModule.initialize, (superAdmin)))
            )
        );
        em = EligibilityModule(
            address(
                new ERC1967Proxy(
                    address(new EligibilityModule()),
                    abi.encodeCall(EligibilityModule.initialize, (superAdmin, address(hats), address(toggle)))
                )
            )
        );
        hats.setEligibilityModule(address(em));

        vm.startPrank(superAdmin);
        toggle.setEligibilityModule(address(em));
        em.setRoleManager(roleManagerAddr);
        vm.stopPrank();
    }

    /*═══════════ wearerRules + hasSpecificWearerRules ═══════════*/

    /// LIB-write (grantWearerEligibility) -> MODULE-read (wearerRules/hasSpecificWearerRules getters).
    function testWearerRules_LibWriteModuleRead() public {
        vm.prank(roleManagerAddr);
        em.grantWearerEligibility(bob, H_RULES); // executes in EligibilityLogic

        EligibilityModule.WearerRules memory r = em.wearerRules(bob, H_RULES); // module-native slot read
        assertEq(r.flags, 0x03, "lib-written wearer flags must land in the module's wearerRules slot");
        assertTrue(em.hasSpecificWearerRules(bob, H_RULES), "lib-written specific-rules flag visible to module");
        (bool e, bool s) = em.getWearerRules(bob, H_RULES);
        assertTrue(e && s, "decoded eligible+standing");
    }

    /// MODULE-write (setWearerEligibility) -> LIB-read (getWearerStatus resolution, incl. kick).
    function testWearerRules_ModuleWriteLibRead() public {
        vm.prank(superAdmin);
        em.setWearerEligibility(alice, H_RULES, true, true); // module-native write
        (bool e1, bool s1) = em.getWearerStatus(alice, H_RULES); // executes in EligibilityLogic
        assertTrue(e1 && s1, "lib getWearerStatus reads the module-written explicit rule");

        vm.prank(superAdmin);
        em.setWearerEligibility(alice, H_RULES, false, false); // kick
        (bool e2, bool s2) = em.getWearerStatus(alice, H_RULES);
        assertFalse(e2 || s2, "lib sees the kick written module-side (same wearerRules slot)");
    }

    /*═══════════ defaultRules ═══════════*/

    /// MODULE-write (setDefaultEligibility) -> LIB-read (getWearerStatus default path) + module getter.
    function testDefaultRules_ModuleWriteLibRead() public {
        vm.prank(superAdmin);
        em.setDefaultEligibility(H_DEFAULT, true, true);

        (bool de, bool ds) = em.getDefaultRules(H_DEFAULT); // module-native
        assertTrue(de && ds, "module getter reads defaultRules");

        (bool e, bool s) = em.getWearerStatus(carol, H_DEFAULT); // lib reads defaultRules for a rule-less wearer
        assertTrue(e && s, "lib getWearerStatus resolves via the module-written defaultRules slot");
    }

    /*═══════════ vouchConfigs + currentVouchCount + epochs + vouchers ═══════════*/

    /// MODULE-write (configureVouching + vouchFor) -> LIB-read (getWearerStatus vouch path).
    function testVouchFields_ModuleWriteLibRead() public {
        vm.startPrank(superAdmin);
        em.configureVouching(H_VOUCH, 1, MEMBERSHIP_HAT, false); // writes vouchConfigs + bumps vouchConfigEpoch
        em.setDefaultEligibility(MEMBERSHIP_HAT, true, true); // make the voucher a real wearer of the membership hat
        vm.stopPrank();
        hats.mintHat(MEMBERSHIP_HAT, voucher);

        // Before any vouch the lib must read a zero count -> not eligible.
        (bool ePre,) = em.getWearerStatus(alice, H_VOUCH);
        assertFalse(ePre, "no vouches yet");

        vm.prank(voucher);
        em.vouchFor(alice, H_VOUCH); // writes currentVouchCount / wearerVouchEpoch / voucherRecordEpoch / vouchers

        assertEq(em.currentVouchCount(H_VOUCH, alice), 1, "module getter reads currentVouchCount");
        assertTrue(em.vouchers(H_VOUCH, alice, voucher), "module getter reads the vouchers mapping");
        assertTrue(em.isVouchingEnabled(H_VOUCH), "module getter reads vouchConfigs flags");

        // The lib's getWearerStatus must read the SAME currentVouchCount / wearerVouchEpoch /
        // vouchConfigEpoch slots the module wrote, and clear the quorum.
        (bool e, bool s) = em.getWearerStatus(alice, H_VOUCH);
        assertTrue(e && s, "lib reads module-written vouch count + epochs to satisfy the quorum");
    }

    /*═══════════ emailVerified ═══════════*/

    /// MODULE-write (setEmailVerified) -> LIB-read (getWearerStatus email path) + module getter.
    function testEmailVerified_ModuleWriteLibRead() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = H_EMAIL;
        vm.prank(superAdmin);
        em.setEmailVerified(alice, ids);

        assertTrue(em.isEmailVerified(alice, H_EMAIL), "module getter reads emailVerified");
        (bool e, bool s) = em.getWearerStatus(alice, H_EMAIL); // lib email branch
        assertTrue(e && s, "lib getWearerStatus reads the module-written emailVerified slot");
    }

    /*═══════════ groupMemberHats (derived) ═══════════*/

    /// LIB-write (setGroupEligibility) -> MODULE-read (getGroupMemberHats) AND LIB-read (derived status).
    function testGroupMemberHats_LibWriteBothReads() public {
        vm.prank(roleManagerAddr);
        em.setGroupEligibility(MARKER, _one(MEMBER)); // executes in EligibilityLogic

        uint256[] memory got = em.getGroupMemberHats(MARKER); // module-native slot read
        assertEq(got.length, 1, "module reads lib-written groupMemberHats length");
        assertEq(got[0], MEMBER, "module reads lib-written groupMemberHats value");

        // A wearer of the member hat becomes derived-eligible for the marker (lib reads the same slot).
        vm.prank(superAdmin);
        em.setDefaultEligibility(MEMBER, true, true);
        hats.mintHat(MEMBER, alice);
        (bool e, bool s) = em.getWearerStatus(alice, MARKER);
        assertTrue(e && s, "lib derived path reads the groupMemberHats slot it wrote");
    }

    /*═══════════ groupMembershipRefCount ═══════════*/

    /// LIB-write (refcount increment inside setGroupEligibility) -> LIB-read (NestedDerivedHat guard).
    function testGroupMembershipRefCount_LibWriteLibRead() public {
        vm.prank(roleManagerAddr);
        em.setGroupEligibility(MARKER, _one(MEMBER)); // refcount[MEMBER] -> 1

        // The target-side nesting guard reads refcount[groupHatId]; making MEMBER a derived hat now must
        // revert because it is already listed as a member elsewhere (refcount > 0).
        vm.prank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.NestedDerivedHat.selector);
        em.setGroupEligibility(MEMBER, _one(MEMBER2));

        // Clearing the marker's list decrements the refcount back to 0, re-enabling MEMBER as a group.
        vm.prank(roleManagerAddr);
        em.setGroupEligibility(MARKER, new uint256[](0));
        vm.prank(roleManagerAddr);
        em.setGroupEligibility(MEMBER, _one(MEMBER2)); // no revert => refcount decremented in the same slot
        assertEq(em.getGroupMemberHats(MEMBER).length, 1, "MEMBER usable as a group after refcount release");
    }

    /*═══════════ roleManager ═══════════*/

    /// MODULE-write (setRoleManager) -> MODULE-read, and the lib-bodied entrypoint honours the same slot.
    function testRoleManager_SlotSharedByModuleGateAndLib() public {
        assertEq(em.roleManager(), roleManagerAddr, "module getter reads roleManager slot");

        // A lib-bodied entrypoint (setGroupEligibility) is gated by the module wrapper's
        // onlySuperAdminOrRoleManager, which reads the roleManager slot: the RoleManager must pass.
        vm.prank(roleManagerAddr);
        em.setGroupEligibility(MARKER, _one(MEMBER));
        assertEq(em.getGroupMemberHats(MARKER)[0], MEMBER, "roleManager-gated lib write succeeded");

        // Repoint the roleManager and confirm the OLD address is now rejected (slot actually moved).
        vm.prank(superAdmin);
        em.setRoleManager(bob);
        assertEq(em.roleManager(), bob, "roleManager updated");
        vm.prank(roleManagerAddr);
        vm.expectRevert(EligibilityModule.NotSuperAdminOrRoleManager.selector);
        em.setGroupEligibility(MARKER, new uint256[](0));
    }

    /*═══════════ full-struct sweep ═══════════*/

    /// Writes EVERY field family, then reads each back through the OPPOSITE execution context in one
    /// test — a cross-field shift anywhere in the Layout breaks at least one leg.
    function testFullStructSweep_CrossContext() public {
        // MODULE writes.
        vm.startPrank(superAdmin);
        em.setWearerEligibility(alice, H_RULES, true, true);
        em.setDefaultEligibility(H_DEFAULT, true, true);
        em.configureVouching(H_VOUCH, 1, MEMBERSHIP_HAT, false);
        em.setDefaultEligibility(MEMBERSHIP_HAT, true, true);
        em.setDefaultEligibility(MEMBER, true, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = H_EMAIL;
        em.setEmailVerified(alice, ids);
        vm.stopPrank();
        hats.mintHat(MEMBERSHIP_HAT, voucher);
        vm.prank(voucher);
        em.vouchFor(bob, H_VOUCH);

        // LIB writes.
        vm.startPrank(roleManagerAddr);
        em.grantWearerEligibility(carol, H_RULES);
        em.setGroupEligibility(MARKER, _one(MEMBER));
        vm.stopPrank();
        hats.mintHat(MEMBER, alice);

        // LIB reads of MODULE-written state (getWearerStatus).
        assertTrue(_elig(alice, H_RULES), "explicit rule (module) read by lib");
        assertTrue(_elig(carol, H_DEFAULT), "default rule (module) read by lib");
        assertTrue(_elig(bob, H_VOUCH), "vouch count+epochs (module) read by lib");
        assertTrue(_elig(alice, H_EMAIL), "emailVerified (module) read by lib");
        assertTrue(_elig(alice, MARKER), "derived membership (lib) read by lib");

        // MODULE reads of LIB-written state (native getters).
        assertTrue(em.hasSpecificWearerRules(carol, H_RULES), "lib grant read by module");
        assertEq(em.getGroupMemberHats(MARKER)[0], MEMBER, "lib group list read by module");
        // MODULE reads of MODULE-written state (native getters over the same slots the lib also reads).
        assertEq(em.currentVouchCount(H_VOUCH, bob), 1, "vouch count native read");
        assertTrue(em.isEmailVerified(alice, H_EMAIL), "email native read");
        (bool de, bool ds) = em.getDefaultRules(H_DEFAULT);
        assertTrue(de && ds, "default native read");
    }

    /*═══════════ helpers ═══════════*/

    function _elig(address w, uint256 h) internal view returns (bool e) {
        (e,) = em.getWearerStatus(w, h);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }
}
