// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2Ids} from "../src/libs/AccessV2Ids.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import {MembershipAuthorityLogic} from "../src/libs/MembershipAuthorityLogic.sol";

/// @title MembershipAuthorityBase — shared harness deploying the authority behind an ERC1967Proxy.
/// @dev executor == address(this) so the test contract issues executor-gated calls directly and
///      pranks users for the pause-gated self-service surface. Born paused; unpaused in setUp.
contract MembershipAuthorityBase is Test {
    MembershipAuthority internal auth;

    address internal paymasterHub = address(0xBEEF);
    bytes32 internal constant ORG_ID = keccak256("org.test");

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dave = address(0xDA5E);

    // ── Events mirrored for expectEmit ──
    event RoleClaimed(uint256 indexed subjectId, address indexed user);
    event RoleGranted(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleOffered(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleRemoved(uint256 indexed subjectId, address indexed user, bool banned, address actor, bool delegated);
    event RoleRenounced(uint256 indexed subjectId, address indexed user);
    event MembershipReconciled(uint256 indexed subjectId, address indexed user);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event PendingActionCreated(
        uint256 indexed pendingId,
        uint256 indexed subjectId,
        address indexed user,
        uint8 action,
        address actor,
        uint64 activatesAt
    );
    event ConfigLint(uint256 indexed subjectId, uint8 lintCode);

    function setUp() public virtual {
        auth = _deployAuthority(ORG_ID);
        auth.setPaused(false);
    }

    function _deployAuthority(bytes32 orgId) internal returns (MembershipAuthority a) {
        MembershipAuthority impl = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: address(this), paymasterHub: paymasterHub, orgId: orgId, seed: _emptySeed()
        });
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(MembershipAuthority.initialize, (cfg)));
        a = MembershipAuthority(address(proxy));
    }

    function _emptySeed() internal pure returns (AccessV2Types.OrgAccessSeed memory s) {
        s.subjectIds = new uint256[](0);
        s.subjectKinds = new AccessV2Types.SubjectKind[](0);
        s.subjectNames = new string[](0);
        s.subjectMaxMembers = new uint32[](0);
        s.subjectDefaults = new bool[](0);
        s.groupMemberRoles = new uint256[][](0);
        s.vouchSubjects = new uint256[](0);
        s.vouchQuorums = new uint32[](0);
        s.vouchVoucherSubjects = new uint256[](0);
        s.permSubjects = new uint256[](0);
        s.permKeys = new bytes32[](0);
        s.permCtxs = new bytes32[](0);
        s.permWords = new uint256[](0);
    }

    function _role(string memory name, uint32 maxMembers) internal returns (uint256) {
        return auth.createRole(name, bytes32(0), "", maxMembers);
    }

    function _defaultAllowRole(string memory name) internal returns (uint256 id) {
        id = _role(name, 0);
        auth.setSubjectDefault(id, true, false);
    }

    // Pack a perm word: {exists, inheritGlobal, value}.
    function _word(uint256 value, bool inherit) internal pure returns (uint256 w) {
        w = value | AccessV2PermKeys.EXISTS_BIT;
        if (inherit) w |= AccessV2PermKeys.INHERIT_GLOBAL_BIT;
    }
}

/*═══════════════════════════════ ID arithmetic + two-authority distinctness ═══════════════════════════════*/

contract MembershipAuthorityIdsTest is MembershipAuthorityBase {
    function testNewIdEmbedsAuthorityAndIsV2Namespace() public {
        uint256 id = _role("Member", 0);
        assertEq(AccessV2Ids.embeddedAuthority(id), address(auth), "id embeds authority addr");
        assertFalse(AccessV2Ids.isLegacyNamespace(id), "new id below hats floor");
        assertLt(id, AccessV2Ids.HATS_NAMESPACE_FLOOR, "new id < 2^224");
        assertGe(id, uint256(1) << 64, "id has embedded address bits");
    }

    function testSequentialIdsIncrement() public {
        uint256 a1 = _role("R1", 0);
        uint256 a2 = _role("R2", 0);
        assertEq(a2 - a1, 1, "localSeq increments by one");
    }

    function testTwoAuthoritiesProduceDistinctSubjectKeys() public {
        MembershipAuthority auth2 = _deployAuthority(keccak256("org.second"));
        auth2.setPaused(false);
        uint256 idA = _role("Member", 0);
        uint256 idB = auth2.createRole("Member", bytes32(0), "", 0);
        assertTrue(idA != idB, "distinct authorities => distinct ids");
        // PaymasterHub subject key has NO orgId; global uniqueness rides on the embedded address.
        bytes32 keyA = keccak256(abi.encode("ParticipationToken", idA));
        bytes32 keyB = keccak256(abi.encode("ParticipationToken", idB));
        assertTrue(keyA != keyB, "distinct paymaster subjectKeys");
    }

    function testLegacyIdAdoptionViaSeed() public {
        uint256 legacy = (uint256(42) << 224) | 7; // a Hats-shaped id >= 2^224
        assertTrue(AccessV2Ids.isLegacyNamespace(legacy));
        uint256[] memory ids = new uint256[](1);
        ids[0] = legacy;
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        names[0] = "Adopted";
        uint32[] memory mm = new uint32[](1);
        auth.seedSubjects(ids, kinds, names, mm);
        assertTrue(auth.getSubject(legacy).exists, "adopted legacy id exists verbatim");
    }
}

/*═══════════════════════════════ Eligibility fold truth table ═══════════════════════════════*/

contract MembershipAuthorityFoldTest is MembershipAuthorityBase {
    function testDefaultDenyNoRule() public {
        uint256 r = _role("Titled", 0);
        assertFalse(auth.eligible(r, alice), "deny-default, no rule => ineligible");
    }

    function testDefaultAllow() public {
        uint256 r = _defaultAllowRole("Open");
        assertTrue(auth.eligible(r, alice), "default allow => eligible");
    }

    function testGrantRuleOverridesDenyDefault() public {
        uint256 r = _role("Titled", 0);
        auth.setRule(r, alice, AccessV2Types.RuleKind.Grant, true);
        assertTrue(auth.eligible(r, alice), "grant rule => eligible");
    }

    function testBanSupremacyOverAttestorAllow() public {
        uint256 r = _role("Titled", 0);
        address[] memory u = new address[](1);
        u[0] = alice;
        auth.seedEmailVerified(r, u);
        assertTrue(auth.eligible(r, alice), "email verified => eligible");
        auth.setRule(r, alice, AccessV2Types.RuleKind.Ban, false);
        assertFalse(auth.eligible(r, alice), "ban supremacy over attestor-ALLOW");
    }

    function testBanSupremacyOverDefaultAllow() public {
        uint256 r = _defaultAllowRole("Open");
        auth.setRule(r, alice, AccessV2Types.RuleKind.Ban, false);
        assertFalse(auth.eligible(r, alice), "ban beats default allow");
    }

    function testEmailAttestorAllow() public {
        uint256 r = _role("Titled", 0);
        address[] memory u = new address[](1);
        u[0] = alice;
        auth.seedEmailVerified(r, u);
        assertTrue(auth.eligible(r, alice));
    }

    function testVouchAttestorAllow() public {
        uint256 voucher = _defaultAllowRole("Voucher");
        uint256 r = _role("Vouched", 0);
        auth.configureVouchAttestor(r, 2, voucher);
        // two vouchers who are members of `voucher`
        vm.prank(bob);
        auth.claim(voucher);
        vm.prank(carol);
        auth.claim(voucher);
        assertFalse(auth.eligible(r, alice), "no vouches yet");
        vm.prank(bob);
        auth.vouch(r, alice);
        assertFalse(auth.eligible(r, alice), "one vouch < quorum 2");
        vm.prank(carol);
        auth.vouch(r, alice);
        assertTrue(auth.eligible(r, alice), "quorum met => eligible");
    }
}

/*═══════════════════════════════ Membership state machine + emission contract ═══════════════════════════════*/

contract MembershipAuthorityLifecycleTest is MembershipAuthorityBase {
    function testSelfClaimDefaultAllowEmitsRoleClaimedAndMint() public {
        uint256 r = _defaultAllowRole("Open");
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(alice, address(0), alice, r, 1);
        vm.expectEmit(true, true, false, false);
        emit RoleClaimed(r, alice);
        vm.prank(alice);
        auth.claim(r);
        assertTrue(auth.isMember(r, alice));
        assertEq(auth.balanceOf(alice, r), 1);
        assertEq(auth.memberCount(r), 1);
    }

    function testClaimNotClaimableRevertsOnDenyDefault() public {
        uint256 r = _role("Titled", 0);
        vm.prank(alice);
        vm.expectRevert(IMembershipAuthority.NotClaimable.selector);
        auth.claim(r);
    }

    function testGrantToInOrgMemberEmitsRoleGranted() public {
        uint256 open = _defaultAllowRole("Open");
        uint256 titled = _role("Titled", 0);
        vm.prank(alice);
        auth.claim(open); // alice now in-org
        vm.expectEmit(true, true, false, false);
        emit RoleGranted(titled, alice, address(this), false);
        auth.grant(titled, alice, true);
        assertTrue(auth.isMember(titled, alice));
    }

    function testGrantToOutOfOrgEmitsOfferNoMint() public {
        uint256 titled = _role("Titled", 0);
        vm.expectEmit(true, true, false, false);
        emit RoleOffered(titled, alice, address(this), false);
        auth.grant(titled, alice, true);
        assertFalse(auth.isMember(titled, alice), "offer, not member yet");
        assertEq(auth.balanceOf(alice, titled), 0, "no mint on offer");
        // alice claims the offer
        vm.expectEmit(true, true, false, false);
        emit RoleClaimed(titled, alice);
        vm.prank(alice);
        auth.claim(titled);
        assertTrue(auth.isMember(titled, alice));
    }

    function testRenounceClearsDelegableGrant() public {
        uint256 titled = _role("Titled", 0);
        auth.grant(titled, alice, true); // offer (out of org), delegable
        vm.prank(alice);
        auth.claim(titled);
        assertTrue(auth.isMember(titled, alice));
        vm.expectEmit(true, true, false, false);
        emit RoleRenounced(titled, alice);
        vm.prank(alice);
        auth.renounce(titled);
        assertFalse(auth.isMember(titled, alice));
        // delegable grant was cleared => not re-claimable
        (,,, AccessV2Types.RuleKind k) = auth.getStatus(titled, alice);
        assertEq(uint8(k), uint8(AccessV2Types.RuleKind.None), "delegable grant cleared on renounce");
    }

    function testStickyGrantSurvivesRenounceAndReclaim() public {
        uint256 titled = _role("Titled", 0);
        auth.grant(titled, alice, false); // sticky offer
        vm.prank(alice);
        auth.claim(titled);
        vm.prank(alice);
        auth.renounce(titled);
        assertFalse(auth.isMember(titled, alice), "renounced");
        // sticky rule survives => canClaim reports RenouncedClaimable
        (AccessV2Types.ActionReason reason,,) = auth.canClaim(titled, alice);
        assertEq(uint8(reason), uint8(AccessV2Types.ActionReason.RenouncedClaimable));
        // re-claim works
        vm.prank(alice);
        auth.claim(titled);
        assertTrue(auth.isMember(titled, alice), "re-claimed reserved sticky seat");
    }

    function testSoftRemoveRevertsIneffectiveOnDefaultAllow() public {
        uint256 open = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(open);
        uint8 expected = uint8(1) << uint8(AccessV2Types.EligSource.DefaultAllow);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.RemovalIneffective.selector, expected));
        auth.remove(open, alice, false);
    }

    function testHardRemoveBansAndBurns() public {
        uint256 open = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(open);
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(address(this), alice, address(0), open, 1);
        vm.expectEmit(true, true, false, false);
        emit RoleRemoved(open, alice, true, address(this), false);
        auth.remove(open, alice, true);
        assertFalse(auth.isMember(open, alice));
        assertFalse(auth.eligible(open, alice), "ban makes ineligible despite default allow");
    }

    function testUnremoveRestoresClaimable() public {
        uint256 open = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(open);
        auth.remove(open, alice, true);
        auth.unremove(open, alice);
        assertTrue(auth.eligible(open, alice), "ban cleared => eligible via default allow");
        vm.prank(alice);
        auth.claim(open);
        assertTrue(auth.isMember(open, alice));
    }

    function testReconcileEvictsAfterVouchEpochReset() public {
        uint256 voucher = _defaultAllowRole("Voucher");
        uint256 r = _role("Vouched", 0);
        auth.configureVouchAttestor(r, 1, voucher);
        vm.prank(bob);
        auth.claim(voucher);
        vm.prank(bob);
        auth.vouch(r, alice);
        vm.prank(alice);
        auth.claim(r);
        assertTrue(auth.isMember(r, alice));
        // amnesty: epoch bump invalidates the vouch (config-level lapse; no burn until reconcile)
        auth.resetVouchEpoch(r);
        assertTrue(_accepted(r, alice), "still accepted (config lapse, not yet reconciled)");
        assertFalse(auth.eligible(r, alice), "no longer eligible");
        // permissionless reconcile emits the repair burn + MembershipReconciled
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(address(this), alice, address(0), r, 1);
        vm.expectEmit(true, true, false, false);
        emit MembershipReconciled(r, alice);
        auth.reconcile(r, alice);
        assertFalse(auth.isMember(r, alice));
        assertEq(auth.memberCount(r), 0);
    }

    function testReconcileNoOpWhileEligible() public {
        uint256 r = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(r);
        auth.reconcile(r, alice); // still eligible -> no-op, no revert
        assertTrue(auth.isMember(r, alice));
    }

    function _accepted(uint256 subject, address user) internal view returns (bool a) {
        (a,,,) = auth.getStatus(subject, user);
    }
}

/*═══════════════════════════════ Caps + SubjectFull + reconcile ═══════════════════════════════*/

contract MembershipAuthorityCapsTest is MembershipAuthorityBase {
    function testSubjectFullCarriesLapsedCandidateHint() public {
        // Cap = 1. Seat alice via a vouch attestor (so she can later lapse to become the hint).
        uint256 voucher = _defaultAllowRole("Voucher");
        uint256 r = _role("Capped", 1);
        auth.configureVouchAttestor(r, 1, voucher);
        vm.prank(bob);
        auth.claim(voucher);
        vm.prank(bob);
        auth.vouch(r, alice);
        vm.prank(alice);
        auth.claim(r);
        assertEq(auth.memberCount(r), 1);
        // Amnesty resets the epoch: alice is now accepted-but-ineligible (a lapsed seat), role still full.
        auth.resetVouchEpoch(r);
        assertFalse(auth.eligible(r, alice), "alice lapsed after epoch reset");
        // carol tries to claim the full role via a governance grant offer -> claim reverts SubjectFull
        // carrying alice as the reconcilable lapsed candidate.
        auth.grant(r, carol, true); // carol out-of-org => offer (rule only, no seat check)
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.SubjectFull.selector, r, alice));
        auth.claim(r);
        // reconcile the lapsed seat, then carol's claim succeeds.
        auth.reconcile(r, alice);
        assertEq(auth.memberCount(r), 0);
        vm.prank(carol);
        auth.claim(r);
        assertTrue(auth.isMember(r, carol));
    }

    function testSubjectFullOnGrantSurfacesHint() public {
        uint256 r = _role("Capped", 1);
        uint256 open = _defaultAllowRole("Open");
        // seat alice via a governance grant (in-org first)
        vm.prank(alice);
        auth.claim(open);
        auth.grant(r, alice, true);
        assertEq(auth.memberCount(r), 1);
        // bob in-org, grant to full role reverts SubjectFull; alice still eligible => candidate 0
        vm.prank(bob);
        auth.claim(open);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.SubjectFull.selector, r, address(0)));
        auth.grant(r, bob, true);
    }

    function testRoleLimitPerUser() public {
        uint256[] memory roles = new uint256[](17);
        for (uint256 i; i < 17; i++) {
            roles[i] = _defaultAllowRole(string(abi.encodePacked("R", vm.toString(i))));
        }
        for (uint256 i; i < 16; i++) {
            vm.prank(alice);
            auth.claim(roles[i]);
        }
        vm.prank(alice);
        vm.expectRevert(IMembershipAuthority.RoleLimit.selector);
        auth.claim(roles[16]);
    }
}

/*═══════════════════════════════ Pending / delegation lifecycle ═══════════════════════════════*/

contract MembershipAuthorityDelegationTest is MembershipAuthorityBase {
    uint256 internal member; // managed subject
    uint256 internal managerRole; // manager subject
    uint256 internal open;

    function setUp() public override {
        super.setUp();
        open = _defaultAllowRole("Open");
        member = _role("Member", 0);
        managerRole = _defaultAllowRole("Manager");
        // bob is a manager
        vm.prank(bob);
        auth.claim(managerRole);
        // manager subject manages `member` with grant+remove caps, 1 day delay
        auth.setManagerConfig(member, managerRole, 3, 1 days);
    }

    function testDelegatedGrantPendingThenFinalize() public {
        // alice in-org first (delegatedGrant is to an in-org member)
        vm.prank(alice);
        auth.claim(open);
        vm.expectEmit(false, true, true, false);
        emit PendingActionCreated(1, member, alice, uint8(AccessV2Types.PendingKind.Grant), bob, 0);
        vm.prank(bob);
        uint256 pid = auth.delegatedGrant(member, alice);
        assertEq(pid, 1);
        // finalize before activatesAt reverts NotYetActive
        uint64 at = auth.getPending(pid).activatesAt;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.NotYetActive.selector, at));
        auth.finalize(pid);
        // warp past delay, finalize succeeds
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        auth.finalize(pid);
        assertTrue(auth.isMember(member, alice));
    }

    function testDelegatedOfferClaimIsFinalize() public {
        vm.prank(bob);
        uint256 pid = auth.delegatedOffer(member, alice);
        // claim before activatesAt reverts NotYetActive (capture `at` BEFORE the prank — a view call
        // inside expectRevert's argument would otherwise consume the prank).
        uint64 at = auth.getPending(pid).activatesAt;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.NotYetActive.selector, at));
        auth.claim(member);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        auth.claim(member);
        assertTrue(auth.isMember(member, alice));
        assertFalse(auth.getPending(pid).exists, "pending consumed by claim");
    }

    function testCancelByManager() public {
        vm.prank(alice);
        auth.claim(open);
        vm.prank(bob);
        uint256 pid = auth.delegatedGrant(member, alice);
        vm.prank(bob);
        auth.cancel(pid);
        assertFalse(auth.getPending(pid).exists, "manager cancelled pending");
    }

    function testCancelByExecutor() public {
        vm.prank(alice);
        auth.claim(open);
        vm.prank(bob);
        uint256 pid = auth.delegatedGrant(member, alice);
        auth.cancel(pid); // executor (address(this)) cancels
        assertFalse(auth.getPending(pid).exists, "executor cancelled pending");
    }

    function testGovernanceWriteVoidsPending() public {
        vm.prank(alice);
        auth.claim(open);
        vm.prank(bob);
        uint256 pid = auth.delegatedGrant(member, alice);
        assertTrue(auth.getPending(pid).exists);
        // governance grant on the same (subject,user) voids the pending
        auth.grant(member, alice, true);
        assertFalse(auth.getPending(pid).exists, "governance write voids pending");
    }

    function testDelegatedGrantBlockedByGovernanceBan() public {
        auth.setRule(member, alice, AccessV2Types.RuleKind.Ban, false);
        vm.prank(bob);
        vm.expectRevert(IMembershipAuthority.GrantBlockedByGovernanceBan.selector);
        auth.delegatedGrant(member, alice);
    }

    function testDelegatedRemoveBlockedByStickyGovernance() public {
        // sticky governance grant + accepted member
        vm.prank(alice);
        auth.claim(open);
        auth.grant(member, alice, false); // sticky, alice in-org => member
        assertTrue(auth.isMember(member, alice));
        vm.prank(bob);
        vm.expectRevert(IMembershipAuthority.RemoveBlockedByStickyGovernance.selector);
        auth.delegatedRemove(member, alice, false);
    }

    function testNonManagerCannotDelegate() public {
        vm.prank(carol);
        vm.expectRevert(IMembershipAuthority.NotAuthorizedManager.selector);
        auth.delegatedGrant(member, alice);
    }

    function testSelfManagedCycleGuard() public {
        uint256[] memory roles = new uint256[](1);
        roles[0] = member;
        uint256 grp = auth.createGroup("Grp", bytes32(0), "", roles);
        // manager subject == a group containing `member` -> direct cycle
        vm.expectRevert(IMembershipAuthority.SelfManagedCycle.selector);
        auth.setManagerConfig(member, grp, 3, 0);
    }
}

/*═══════════════════════════════ Perm inverted union fold ═══════════════════════════════*/

contract MembershipAuthorityPermTest is MembershipAuthorityBase {
    function testGlobalOnlyRowContributesAtEveryProjectCtx() public {
        uint256 r = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(r);
        bytes32 pid = bytes32(uint256(1234));
        auth.setPerm(r, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(0x0F, false));
        // no project-specific row exists; global must contribute at ctx=pid
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, pid), 0x0F, "global-only contributes at project ctx");
    }

    function testInheritFalseProjectRowDoesNotPullGlobal() public {
        uint256 r = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(r);
        bytes32 pid = bytes32(uint256(1234));
        auth.setPerm(r, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(0xF0, false)); // global
        auth.setPerm(r, AccessV2PermKeys.TM_PERMS, pid, _word(0x03, false)); // project inherit=false
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, pid), 0x03, "inherit=false => project only");
    }

    function testInheritTrueCombinesGlobalAndProject() public {
        uint256 r = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(r);
        bytes32 pid = bytes32(uint256(1234));
        auth.setPerm(r, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(0xF0, false));
        auth.setPerm(r, AccessV2PermKeys.TM_PERMS, pid, _word(0x03, true)); // inherit=true => OR-combine
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, pid), 0xF3, "inherit=true OR-combines");
    }

    function testOrMaskUnionAcrossSubjects() public {
        uint256 r1 = _defaultAllowRole("R1");
        uint256 r2 = _defaultAllowRole("R2");
        vm.startPrank(alice);
        auth.claim(r1);
        auth.claim(r2);
        vm.stopPrank();
        auth.setPerm(r1, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(0x01, false));
        auth.setPerm(r2, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(0x02, false));
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, bytes32(0)), 0x03, "OR-mask union across subjects");
    }

    function testBoolAnyRequiresMembership() public {
        uint256 r = _role("Titled", 0); // deny default
        auth.setPerm(r, AccessV2PermKeys.DD_VOTE, bytes32(0), _word(1, false));
        // alice not a member => hasPerm returns 0
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.DD_VOTE, bytes32(0)), 0, "non-member gets nothing");
        auth.setRule(r, alice, AccessV2Types.RuleKind.Grant, true);
        auth.grant(r, alice, true); // now accepted+eligible via grant... grant to out-of-org = offer
        vm.prank(alice);
        auth.claim(r);
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.DD_VOTE, bytes32(0)), 1, "member gets the bool-any value");
    }

    function testPermFanoutLimit() public {
        bytes32 ctx = bytes32(0);
        for (uint256 i; i < 16; i++) {
            uint256 r = _role(string(abi.encodePacked("R", vm.toString(i))), 0);
            auth.setPerm(r, AccessV2PermKeys.DD_VOTE, ctx, _word(1, false));
        }
        uint256 r17 = _role("R17", 0);
        vm.expectRevert(IMembershipAuthority.PermFanoutLimit.selector);
        auth.setPerm(r17, AccessV2PermKeys.DD_VOTE, ctx, _word(1, false));
    }
}

/*═══════════════════════════════ activeMemberSince electorate gate ═══════════════════════════════*/

contract MembershipAuthorityActivationTest is MembershipAuthorityBase {
    function testActiveMemberSinceSubjectShaped() public {
        uint256 r = _defaultAllowRole("Open");
        assertEq(auth.activeMemberSince(r, alice), type(uint64).max, "non-member => sentinel");
        vm.warp(1000);
        vm.prank(alice);
        auth.claim(r);
        assertEq(auth.activeMemberSince(r, alice), 1000, "acceptedAt recorded");
    }

    function testActiveMemberSinceKeyFolded() public {
        uint256 r = _defaultAllowRole("Open");
        auth.setPerm(r, AccessV2PermKeys.DD_VOTE, bytes32(0), _word(1, false));
        assertEq(auth.activeMemberSince(alice, AccessV2PermKeys.DD_VOTE, bytes32(0)), type(uint64).max);
        vm.warp(500);
        vm.prank(alice);
        auth.claim(r);
        assertEq(auth.activeMemberSince(alice, AccessV2PermKeys.DD_VOTE, bytes32(0)), 500);
    }

    function testGroupEarliestActivationGoverns() public {
        uint256 r1 = _defaultAllowRole("R1");
        uint256 r2 = _defaultAllowRole("R2");
        uint256[] memory members = new uint256[](2);
        members[0] = r1;
        members[1] = r2;
        uint256 grp = auth.createGroup("Grp", bytes32(0), "", members);
        vm.warp(100);
        vm.prank(alice);
        auth.claim(r1);
        vm.warp(200);
        vm.prank(alice);
        auth.claim(r2);
        assertEq(auth.activeMemberSince(grp, alice), 100, "earliest member-role activation governs");
    }
}

/*═══════════════════════════════ Seeds while paused + pause gating ═══════════════════════════════*/

contract MembershipAuthorityPauseSeedTest is MembershipAuthorityBase {
    function setUp() public override {
        auth = _deployAuthority(ORG_ID); // stays PAUSED (born paused)
    }

    function testSeedsRunWhilePaused() public {
        assertTrue(auth.paused(), "born paused");
        uint256[] memory ids = new uint256[](1);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        names[0] = "Member";
        uint32[] memory mm = new uint32[](1);
        auth.seedSubjects(ids, kinds, names, mm); // executor write while paused -> OK
        uint256 sid = _idOfOnlySubject();
        // seed a rule + membership while paused
        uint256[] memory subs = new uint256[](1);
        subs[0] = sid;
        address[] memory users = new address[](1);
        users[0] = alice;
        AccessV2Types.RuleKind[] memory rk = new AccessV2Types.RuleKind[](1);
        rk[0] = AccessV2Types.RuleKind.Grant;
        bool[] memory dg = new bool[](1);
        dg[0] = true;
        auth.seedRules(subs, users, rk, dg);
        auth.seedMemberships(subs, users);
        assertTrue(auth.isMember(sid, alice), "seeded membership visible while paused (reads live)");
    }

    function testUserWriteRevertsWhilePaused() public {
        uint256 r = auth.createRole("Open", bytes32(0), "", 0); // executor, pause-exempt
        auth.setSubjectDefault(r, true, false);
        vm.prank(alice);
        vm.expectRevert(IMembershipAuthority.Paused.selector);
        auth.claim(r);
        // unpause, now works
        auth.setPaused(false);
        vm.prank(alice);
        auth.claim(r);
        assertTrue(auth.isMember(r, alice));
    }

    function _idOfOnlySubject() internal view returns (uint256) {
        // localSeq-based new id (seedSubjects with id==0 allocates)
        return AccessV2Ids.newSubjectId(address(auth), 1);
    }
}

/*═══════════════════════════════ ConfigLint emission ═══════════════════════════════*/

contract MembershipAuthorityLintTest is MembershipAuthorityBase {
    function testQuorumNoOpLint() public {
        uint256 r = _defaultAllowRole("Open");
        uint256 voucher = _role("V", 0);
        vm.expectEmit(true, false, false, true);
        emit ConfigLint(r, uint8(AccessV2Types.LintCode.QuorumNoOp));
        auth.configureVouchAttestor(r, 1, voucher);
    }

    function testDefaultAllowStrongPermsLint() public {
        uint256 r = _role("Titled", 0);
        auth.setPerm(r, AccessV2PermKeys.DD_VOTE, bytes32(0), _word(1, false));
        vm.expectEmit(true, false, false, true);
        emit ConfigLint(r, uint8(AccessV2Types.LintCode.DefaultAllowStrongPerms));
        auth.setSubjectDefault(r, true, false);
    }

    function testVouchWithMaxMembersLint() public {
        uint256 voucher = _role("V", 0);
        uint256 r = _role("Titled", 0);
        auth.configureVouchAttestor(r, 1, voucher);
        vm.expectEmit(true, false, false, true);
        emit ConfigLint(r, uint8(AccessV2Types.LintCode.VouchWithMaxMembers));
        auth.setMaxMembers(r, 5);
    }

    function testWiringIncompatibleSelfVoucher() public {
        uint256 r = _role("Titled", 0);
        vm.expectRevert(IMembershipAuthority.WiringIncompatible.selector);
        auth.configureVouchAttestor(r, 1, r); // voucherSubject == subject
    }
}

/*═══════════════════════════════ IHats read subset ═══════════════════════════════*/

contract MembershipAuthorityHatsViewTest is MembershipAuthorityBase {
    function testViewHatNineFields() public {
        uint256 r = _role("Titled", 5);
        (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,,
            uint16 lastHatId,
            bool mutable_,
            bool active
        ) = auth.viewHat(r);
        assertEq(details, "Titled");
        assertEq(maxSupply, 5);
        assertEq(supply, 0);
        assertEq(eligibility, address(auth));
        assertEq(toggle, address(auth));
        assertEq(lastHatId, 0);
        assertTrue(mutable_);
        assertTrue(active, "active == !paused");
    }

    function testIsWearerOfHatMatchesIsMember() public {
        uint256 r = _defaultAllowRole("Open");
        vm.prank(alice);
        auth.claim(r);
        assertTrue(auth.isWearerOfHat(alice, r));
        assertTrue(auth.isEligible(alice, r));
        assertEq(auth.balanceOf(alice, r), 1);
    }

    function testCheckHatWearerStatusConstantTrue() public view {
        assertTrue(auth.checkHatWearerStatus(12345, alice));
    }
}
