// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TaskManager} from "../src/TaskManager.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

/// @dev Minimal ParticipationToken stand-in — TaskManager only needs a non-zero address at init and
///      calls `mint` on completion, which none of these permission-focused tests exercise.
contract MockPToken {
    function mint(address, uint256) external {}
}

/// @dev Exposes TaskManager's internal permission-fold sites so the dual-path equality obligation
///      (§5.2 #8) can be asserted at the exact `_permMask` boundary, not only via gated externals.
contract TaskManagerHarness is TaskManager {
    function permMask(address user, bytes32 pid) external view returns (uint8) {
        return _permMask(user, pid);
    }

    function hasCreatorHat(address user) external view returns (bool) {
        return _hasCreatorHat(user);
    }
}

/// @title TaskManagerAccessV2Test
/// @notice Dual-path (Access v2) coverage for TaskManager: legacy Hats regression, authority-path
///         mask parity, the §5.2 TM effective-mask equality obligation across global/project/inherit
///         shapes, creator/organizer routing, setter auth, and rollback-to-zero.
contract TaskManagerAccessV2Test is Test {
    TaskManagerHarness internal tm;
    MockHats internal hats;
    MockPToken internal token;
    MembershipAuthority internal auth;

    address internal executor = makeAddr("executor");
    address internal paymasterHub = address(0xBEEF);
    bytes32 internal constant ORG_ID = keccak256("org.tm.accessv2");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal outsider = makeAddr("outsider");

    // Legacy hats.
    uint256 internal constant HAT_A = 101;
    uint256 internal constant HAT_B = 102;
    uint256 internal constant CREATOR_HAT = 200;

    event MembershipAuthoritySet(address indexed authority);

    function setUp() public {
        token = new MockPToken();
        hats = new MockHats();

        TaskManagerHarness impl = new TaskManagerHarness();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = CREATOR_HAT;
        bytes memory initCall =
            abi.encodeCall(TaskManager.initialize, (address(token), address(hats), creatorHats, executor, address(0)));
        tm = TaskManagerHarness(address(new BeaconProxy(address(beacon), initCall)));

        auth = _deployAuthority();
    }

    /*──────────────────── Authority deploy + state helpers ────────────────────*/

    function _deployAuthority() internal returns (MembershipAuthority a) {
        MembershipAuthority implA = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: executor, paymasterHub: paymasterHub, orgId: ORG_ID, seed: _emptySeed()
        });
        ERC1967Proxy proxy = new ERC1967Proxy(address(implA), abi.encodeCall(MembershipAuthority.initialize, (cfg)));
        a = MembershipAuthority(address(proxy));
        vm.prank(executor);
        a.setPaused(false);
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

    function _role(string memory name) internal returns (uint256 id) {
        vm.prank(executor);
        id = auth.createRole(name, bytes32(0), "", 0);
    }

    /// @dev Make `user` a member (accepted && eligible) of `subject`: governance Grant rule for
    ///      eligibility + executor seedMembership for acceptance (both pause-exempt).
    function _makeMember(uint256 subject, address user) internal {
        vm.prank(executor);
        auth.setRule(subject, user, AccessV2Types.RuleKind.Grant, false);
        uint256[] memory subs = new uint256[](1);
        address[] memory users = new address[](1);
        subs[0] = subject;
        users[0] = user;
        vm.prank(executor);
        auth.seedMemberships(subs, users);
        assertTrue(auth.isMember(subject, user), "member setup failed");
    }

    function _word(uint256 value, bool inherit) internal pure returns (uint256 w) {
        w = value | AccessV2PermKeys.EXISTS_BIT;
        if (inherit) w |= AccessV2PermKeys.INHERIT_GLOBAL_BIT;
    }

    function _setPerm(uint256 subject, bytes32 ctx, uint256 value, bool inherit) internal {
        vm.prank(executor);
        auth.setPerm(subject, AccessV2PermKeys.TM_PERMS, ctx, _word(value, inherit));
    }

    /// @dev Create a real project (legacy creator path) so project-scoped setters have a live pid.
    function _mkProject(bytes memory title) internal returns (bytes32 pid) {
        address creator = makeAddr(string(abi.encodePacked("creator:", title)));
        hats.mintHat(CREATOR_HAT, creator);
        vm.prank(creator);
        pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: title,
                metadataHash: bytes32(0),
                cap: 0,
                managers: new address[](0),
                createHats: new uint256[](0),
                claimHats: new uint256[](0),
                reviewHats: new uint256[](0),
                assignHats: new uint256[](0),
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );
    }

    /*──────────────────── Setter auth + rollback ────────────────────*/

    function test_setMembershipAuthority_onlyExecutor() public {
        vm.prank(outsider);
        vm.expectRevert(TaskManager.NotExecutor.selector);
        tm.setMembershipAuthority(address(auth));
    }

    function test_setMembershipAuthority_setsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(tm));
        emit MembershipAuthoritySet(address(auth));
        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        // Lens variant 12 reflects the pointer.
        bytes memory raw = tm.getLensData(12, "");
        assertEq(abi.decode(raw, (address)), address(auth), "lens pointer mismatch");
    }

    function test_rollbackToZero_restoresLegacy() public {
        // Legacy state: alice wears HAT_A with global CREATE.
        hats.mintHat(HAT_A, alice);
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(HAT_A, TaskPerm.CREATE));
        assertEq(tm.permMask(alice, bytes32("p1")), TaskPerm.CREATE, "legacy baseline");

        // Route to an authority where alice has NO perms.
        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        assertEq(tm.permMask(alice, bytes32("p1")), 0, "authority arm should override legacy");

        // Roll back to zero — legacy answer returns byte-identically.
        vm.prank(executor);
        tm.setMembershipAuthority(address(0));
        assertEq(tm.permMask(alice, bytes32("p1")), TaskPerm.CREATE, "rollback must restore legacy");
    }

    /*──────────────────── Legacy path regression ────────────────────*/

    function test_legacyPath_projectOverridesGlobal() public {
        hats.mintHat(HAT_A, alice);
        vm.startPrank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(HAT_A, TaskPerm.CREATE | TaskPerm.CLAIM));
        vm.stopPrank();
        _mkProject("id0"); // burn project id 0 (== authority GLOBAL ctx sentinel)
        bytes32 pid = _mkProject("proj");
        // No project override → global applies.
        assertEq(tm.permMask(alice, pid), TaskPerm.CREATE | TaskPerm.CLAIM, "global fold");

        // Project override REPLACES global (v1 shadow rule).
        vm.prank(executor);
        tm.setProjectRolePerm(pid, HAT_A, TaskPerm.REVIEW);
        assertEq(tm.permMask(alice, pid), TaskPerm.REVIEW, "project replaces global (legacy)");
    }

    /*──────────────────── Authority path parity ────────────────────*/

    function test_authorityPath_globalOnly() public {
        uint256 sA = _role("A");
        _makeMember(sA, alice);
        _setPerm(sA, bytes32(0), TaskPerm.CREATE | TaskPerm.REVIEW, false);

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        // Global-only row contributes at EVERY project ctx (§3 union).
        assertEq(tm.permMask(alice, bytes32("anyProject")), TaskPerm.CREATE | TaskPerm.REVIEW, "global union");
        assertEq(tm.permMask(alice, bytes32("other")), TaskPerm.CREATE | TaskPerm.REVIEW, "global union 2");
        // Non-member sees nothing.
        assertEq(tm.permMask(bob, bytes32("anyProject")), 0, "non-member");
    }

    function test_authorityPath_projectReplace_inheritFalse() public {
        uint256 sA = _role("A");
        _makeMember(sA, alice);
        bytes32 pid = bytes32("proj");
        _setPerm(sA, bytes32(0), TaskPerm.CREATE, false); // global
        _setPerm(sA, pid, TaskPerm.REVIEW, false); // project, inherit=false → REPLACE

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        assertEq(tm.permMask(alice, pid), TaskPerm.REVIEW, "inherit=false replaces global");
        // A different project (no row) still sees the global.
        assertEq(tm.permMask(alice, bytes32("elsewhere")), TaskPerm.CREATE, "global elsewhere");
    }

    function test_authorityPath_projectInherit_inheritTrue() public {
        uint256 sA = _role("A");
        _makeMember(sA, alice);
        bytes32 pid = bytes32("proj");
        _setPerm(sA, bytes32(0), TaskPerm.CREATE, false); // global
        _setPerm(sA, pid, TaskPerm.REVIEW, true); // project, inherit=true → COMBINE

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        assertEq(tm.permMask(alice, pid), TaskPerm.CREATE | TaskPerm.REVIEW, "inherit=true OR-combines");
    }

    /*──────────────────── §5.2 #8 effective-mask equality obligation ────────────────────*/

    /// @notice Same org state expressed legacy (hats+masks) vs authority (subjects+perm rows via the
    ///         freeze migration mapping) yields byte-identical `_permMask` for every (project, user).
    ///         Migration mapping: global mask → global row; NONZERO project mask → inherit=false
    ///         project row (reproduces v1 REPLACE); zero project mask → no row (falls to global).
    function test_equalityDifferential_legacyVsAuthority() public {
        // ── Legacy state ──
        // alice wears HAT_A + HAT_B; bob wears HAT_B only.
        hats.mintHat(HAT_A, alice);
        hats.mintHat(HAT_B, alice);
        hats.mintHat(HAT_B, bob);

        uint8 gA = TaskPerm.CREATE | TaskPerm.CLAIM;
        uint8 gB = TaskPerm.REVIEW;
        vm.startPrank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(HAT_A, gA));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(HAT_B, gB));
        vm.stopPrank();

        _mkProject("id0"); // burn project id 0 (== authority GLOBAL ctx sentinel) so p1/p2 are nonzero
        bytes32 p1 = _mkProject("p1");
        bytes32 p2 = _mkProject("p2");
        // p1: HAT_A gets a nonzero project override (ASSIGN); HAT_B no override.
        // p2: HAT_B gets a nonzero override (BUDGET); HAT_A no override.
        uint8 pA1 = TaskPerm.ASSIGN;
        uint8 pB2 = TaskPerm.BUDGET;
        vm.startPrank(executor);
        tm.setProjectRolePerm(p1, HAT_A, pA1);
        tm.setProjectRolePerm(p2, HAT_B, pB2);
        vm.stopPrank();

        // Capture legacy answers.
        uint8 la_p1 = tm.permMask(alice, p1);
        uint8 la_p2 = tm.permMask(alice, p2);
        uint8 lb_p1 = tm.permMask(bob, p1);
        uint8 lb_p2 = tm.permMask(bob, p2);

        // ── Authority state (mapped 1:1) ──
        uint256 sA = _role("A");
        uint256 sB = _role("B");
        _makeMember(sA, alice);
        _makeMember(sB, alice);
        _makeMember(sB, bob);
        // Globals.
        _setPerm(sA, bytes32(0), gA, false);
        _setPerm(sB, bytes32(0), gB, false);
        // Nonzero project overrides → inherit=false (REPLACE), matching v1.
        _setPerm(sA, p1, pA1, false);
        _setPerm(sB, p2, pB2, false);

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        // Exhaustive (user, project) equality.
        assertEq(tm.permMask(alice, p1), la_p1, "alice p1 parity");
        assertEq(tm.permMask(alice, p2), la_p2, "alice p2 parity");
        assertEq(tm.permMask(bob, p1), lb_p1, "bob p1 parity");
        assertEq(tm.permMask(bob, p2), lb_p2, "bob p2 parity");

        // Spot-check the concrete expected values so the test is not tautological.
        // alice p1: HAT_A→ASSIGN (project replace) OR HAT_B→gB (no p1 override, uses global REVIEW).
        assertEq(la_p1, pA1 | gB, "alice p1 = ASSIGN|REVIEW");
        // alice p2: HAT_A→gA (no p2 override) OR HAT_B→BUDGET (project replace).
        assertEq(la_p2, gA | pB2, "alice p2 = gA|BUDGET");
        // bob p1: HAT_B global only.
        assertEq(lb_p1, gB, "bob p1 = REVIEW");
        // bob p2: HAT_B project replace.
        assertEq(lb_p2, pB2, "bob p2 = BUDGET");
    }

    /*──────────────────── creator / organizer routing ────────────────────*/

    function test_creator_dualPath() public {
        // Authority creator subject, adopted as a TM creator hat id.
        uint256 sCreator = _role("Creators");
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(sCreator, true));
        _makeMember(sCreator, carol);

        // Legacy: carol wears no legacy creator hat → not a creator yet.
        assertFalse(tm.hasCreatorHat(carol), "legacy: carol not creator");

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        assertTrue(tm.hasCreatorHat(carol), "authority: carol is creator via membership");
        assertFalse(tm.hasCreatorHat(outsider), "authority: outsider not creator");

        // Rollback restores legacy (carol wears the id as a hat? no) → not creator.
        vm.prank(executor);
        tm.setMembershipAuthority(address(0));
        assertFalse(tm.hasCreatorHat(carol), "rollback: legacy answer");
    }

    function test_organizer_dualPath() public {
        uint256 sOrg = _role("Organizers");
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(sOrg, true));
        _makeMember(sOrg, carol);

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        // Organizer-gated setFolders: carol (member) passes, outsider reverts.
        vm.prank(carol);
        tm.setFolders(bytes32(0), bytes32("newRoot"));

        vm.prank(outsider);
        vm.expectRevert(TaskManager.NotOrganizer.selector);
        tm.setFolders(bytes32("newRoot"), bytes32("root2"));
    }

    /*──────────────────── behavioral parity: createTask gated by CREATE ────────────────────*/

    function test_createTask_gatedByAuthorityMask() public {
        // Set up a project via a legacy creator so we have a project id.
        uint256 sCreator = _role("Creators");
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(sCreator, true));
        _makeMember(sCreator, carol);

        uint256 sTaskers = _role("Taskers");
        _makeMember(sTaskers, alice);

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        // carol (creator) creates a project.
        vm.prank(carol);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("P"),
                metadataHash: bytes32(0),
                cap: 0,
                managers: new address[](0),
                createHats: new uint256[](0),
                claimHats: new uint256[](0),
                reviewHats: new uint256[](0),
                assignHats: new uint256[](0),
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // alice lacks CREATE → cannot create a task.
        vm.prank(alice);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("m"), bytes32(0), pid, address(0), 0, false, 0, 0);

        // Grant TaskPerm.CREATE to the Taskers subject globally → alice can create.
        _setPerm(sTaskers, bytes32(0), TaskPerm.CREATE, false);
        vm.prank(alice);
        tm.createTask(1 ether, bytes("m"), bytes32(0), pid, address(0), 0, false, 0, 0);
    }
}
