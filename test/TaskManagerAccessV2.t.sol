// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ValidationLib} from "../src/libs/ValidationLib.sol";
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

/// @dev Exposes TaskManager's internal permission-fold sites so authority permission folding
///      can be asserted at the exact `_permMask` boundary, not only via gated externals.
contract TaskManagerHarness is TaskManager {
    function permMask(address user, bytes32 pid) external view returns (uint8) {
        return _permMask(user, pid);
    }

    function hasCreatorHat(address user) external view returns (bool) {
        return _hasCreatorHat(user);
    }
}

/// @title TaskManagerAccessV2Test
/// @notice Authority global/project/inherit masks, creator/organizer subjects and rejected rollback.
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
            abi.encodeCall(TaskManager.initialize, (address(token), creatorHats, executor, address(0)));
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
        // Freeze amendment W4: TaskManager's authority arm queries ctx = projectId + 1 (project
        // ids start at 0 and would collide with the global ctx 0), so project rows are WRITTEN at
        // the offset ctx too. Global rows (ctx 0) pass through unshifted.
        bytes32 effectiveCtx = ctx == bytes32(0) ? ctx : bytes32(uint256(ctx) + 1);
        auth.setPerm(subject, AccessV2PermKeys.TM_PERMS, effectiveCtx, _word(value, inherit));
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

    /*──────────────────── creator / organizer routing ────────────────────*/

    function test_creator_dualPath() public {
        // Authority creator subject, adopted as a TM creator hat id.
        uint256 sCreator = _role("Creators");
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(sCreator, true));
        _makeMember(sCreator, carol);

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        assertTrue(tm.hasCreatorHat(carol), "authority: carol is creator via membership");
        assertFalse(tm.hasCreatorHat(outsider), "authority: outsider not creator");

        vm.prank(executor);
        vm.expectRevert(ValidationLib.ZeroAddress.selector);
        tm.setMembershipAuthority(address(0));
        assertTrue(tm.hasCreatorHat(carol), "authority remains active");
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
