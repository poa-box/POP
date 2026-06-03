// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {TaskManager, IParticipationToken} from "../src/TaskManager.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/// @notice Minimal ParticipationToken mock for TaskManager-only tests
contract MockPToken {
    mapping(address => uint256) public balances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }
}

/// @notice Focused test suite for the Hats-native capability-hat model in TaskManager.
///         Covers paths that the audit identified as untested in the new model after
///         the obsolete uint8 bitmask tests were skipped.
contract TaskManagerCapabilityHatsTest is Test {
    TaskManager tm;
    MockHats hats;
    MockPToken token;

    address constant EXECUTOR = address(0xE0E);
    address constant PROJECT_CREATOR = address(0xCAFE);
    address constant TASK_CREATOR = address(0xBEEF);
    address constant CLAIMER = address(0xC1A);
    address constant REVIEWER = address(0xDEAD);
    address constant ASSIGNER = address(0xA551);
    address constant SELF_REVIEWER = address(0x5E1F);
    address constant OUTSIDER = address(0xBAD);
    address constant PM = address(0xB055);

    // Global capability hats
    uint256 constant PROJECT_CREATOR_HAT = 1001;
    uint256 constant CREATE_HAT = 1002;
    uint256 constant CLAIM_HAT = 1003;
    uint256 constant REVIEW_HAT = 1004;
    uint256 constant ASSIGN_HAT = 1005;
    uint256 constant SELF_REVIEW_HAT = 1006;

    // Project-specific override hats
    uint256 constant PROJ_CREATE_HAT = 2001;
    uint256 constant PROJ_CLAIM_HAT = 2002;
    uint256 constant PROJ_REVIEW_HAT = 2003;
    uint256 constant PROJ_ASSIGN_HAT = 2004;
    uint256 constant PROJ_SELF_REVIEW_HAT = 2005;

    address constant PROJ_CREATE_USER = address(0x3001);
    address constant PROJ_REVIEW_USER = address(0x3003);

    function setUp() public {
        hats = new MockHats();
        token = new MockPToken();

        // Mint hats to actors
        hats.mintHat(PROJECT_CREATOR_HAT, PROJECT_CREATOR);
        hats.mintHat(CREATE_HAT, TASK_CREATOR);
        hats.mintHat(CLAIM_HAT, CLAIMER);
        hats.mintHat(REVIEW_HAT, REVIEWER);
        hats.mintHat(ASSIGN_HAT, ASSIGNER);
        hats.mintHat(SELF_REVIEW_HAT, SELF_REVIEWER);

        // SelfReviewer also wears CLAIM and REVIEW hats so they can claim and submit
        hats.mintHat(CLAIM_HAT, SELF_REVIEWER);
        hats.mintHat(REVIEW_HAT, SELF_REVIEWER);

        // Per-project override wearers
        hats.mintHat(PROJ_CREATE_HAT, PROJ_CREATE_USER);
        hats.mintHat(PROJ_REVIEW_HAT, PROJ_REVIEW_USER);

        TaskManager impl = new TaskManager();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        tm = TaskManager(address(new BeaconProxy(address(beacon), "")));
        tm.initialize(address(token), address(hats), PROJECT_CREATOR_HAT, EXECUTOR, address(0));

        // Configure global capability hats for each TaskPerm slot
        vm.startPrank(EXECUTOR);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(CREATE_HAT, TaskPerm.CREATE));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(CLAIM_HAT, TaskPerm.CLAIM));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(REVIEW_HAT, TaskPerm.REVIEW));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(ASSIGN_HAT, TaskPerm.ASSIGN));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(SELF_REVIEW_HAT, TaskPerm.SELF_REVIEW));
        vm.stopPrank();
    }

    function _createDefaultProject() internal returns (bytes32 pid) {
        vm.prank(PROJECT_CREATOR);
        pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("test"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: 0, // use global
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );
    }

    /* ═══════════════════ Global capability-hat per slot ═══════════════════ */

    function testGlobalRolePermSetsEachSlotIndependently() public {
        // Each ROLE_PERM call wrote to a distinct slot. Read back via the
        // backwards-compat lens getter (returns [create, claim, review, assign, selfReview]).
        bytes memory encoded = tm.getLensData(6, "");
        uint256[] memory hatsArr = abi.decode(encoded, (uint256[]));
        assertEq(hatsArr.length, 5, "lens getter should return 5-element array");
        assertEq(hatsArr[0], CREATE_HAT);
        assertEq(hatsArr[1], CLAIM_HAT);
        assertEq(hatsArr[2], REVIEW_HAT);
        assertEq(hatsArr[3], ASSIGN_HAT);
        assertEq(hatsArr[4], SELF_REVIEW_HAT);
    }

    function testCreatorHatsLensReturnsSingleElement() public {
        bytes memory encoded = tm.getLensData(5, "");
        uint256[] memory creatorArr = abi.decode(encoded, (uint256[]));
        assertEq(creatorArr.length, 1);
        assertEq(creatorArr[0], PROJECT_CREATOR_HAT);
    }

    function testUnknownRolePermFlagReverts() public {
        vm.prank(EXECUTOR);
        vm.expectRevert(TaskManager.InvalidCapMask.selector);
        // mask 0 selects no gate — rejected (every defined bit maps to a gate).
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(123), uint8(0)));
    }

    function testOrCombinedMaskRevertsGlobal() public {
        // A caller migrating from the old bitmask API might OR flags together.
        // ROLE_PERM only supports single-bit masks since each cap has its own storage slot.
        vm.prank(EXECUTOR);
        vm.expectRevert(TaskManager.InvalidCapMask.selector);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(123), TaskPerm.CREATE | TaskPerm.CLAIM));
    }

    function testRevokeGlobalCapHatBlocksWearer() public {
        bytes32 pid = _createDefaultProject();
        // Sanity: TASK_CREATOR can create
        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("t1"), bytes32(0), pid, address(0), 0, false);

        // Zero out the global CREATE hat
        vm.prank(EXECUTOR);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(0), TaskPerm.CREATE));

        vm.prank(TASK_CREATOR);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("t2"), bytes32(0), pid, address(0), 0, false);
    }

    /* ═══════════════════ Self-review path (NEW MODEL — critical) ═══════════════════ */

    function testSelfReviewGloballyAllowed() public {
        bytes32 pid = _createDefaultProject();

        // SELF_REVIEWER creates → claims → submits → completes own task
        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("self"), bytes32(0), pid, address(0), 0, false);

        vm.prank(SELF_REVIEWER);
        tm.claimTask(0);

        vm.prank(SELF_REVIEWER);
        tm.submitTask(0, keccak256("work"));

        // SELF_REVIEWER wears SELF_REVIEW_HAT → can complete their own task
        vm.prank(SELF_REVIEWER);
        tm.completeTask(0);
    }

    function testSelfReviewBlockedWhenSelfReviewHatNotWorn() public {
        // CLAIMER wears CLAIM but not REVIEW or SELF_REVIEW
        bytes32 pid = _createDefaultProject();

        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("task"), bytes32(0), pid, address(0), 0, false);

        // CLAIMER claims and submits
        vm.prank(CLAIMER);
        tm.claimTask(0);
        vm.prank(CLAIMER);
        tm.submitTask(0, keccak256("work"));

        // Try self-completion: blocked by REVIEW gate first (CLAIMER doesn't have REVIEW)
        vm.prank(CLAIMER);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.completeTask(0);
    }

    function testSelfReviewBlockedWhenClaimerWearsReviewButNotSelfReview() public {
        // Special case: REVIEWER wears REVIEW + CLAIM but NOT SELF_REVIEW
        address reviewerNoSelf = address(0xB000);
        hats.mintHat(REVIEW_HAT, reviewerNoSelf);
        hats.mintHat(CLAIM_HAT, reviewerNoSelf);

        bytes32 pid = _createDefaultProject();

        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("task"), bytes32(0), pid, address(0), 0, false);

        vm.prank(reviewerNoSelf);
        tm.claimTask(0);
        vm.prank(reviewerNoSelf);
        tm.submitTask(0, keccak256("work"));

        // Even though reviewerNoSelf wears REVIEW hat, the SELF_REVIEW branch fires
        // because they are the claimer. Without SELF_REVIEW hat, this reverts.
        vm.prank(reviewerNoSelf);
        vm.expectRevert(TaskManager.SelfReviewNotAllowed.selector);
        tm.completeTask(0);
    }

    function testDifferentReviewerCompletesWithoutSelfReviewHat() public {
        // REVIEWER doesn't have SELF_REVIEW. They're completing someone else's task → OK.
        bytes32 pid = _createDefaultProject();

        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("task"), bytes32(0), pid, address(0), 0, false);

        vm.prank(CLAIMER);
        tm.claimTask(0);
        vm.prank(CLAIMER);
        tm.submitTask(0, keccak256("work"));

        // REVIEWER (not the claimer) completes — no SELF_REVIEW check
        vm.prank(REVIEWER);
        tm.completeTask(0);
    }

    /* ═══════════════════ createAndAssign requires both CREATE + ASSIGN ═══════════════════ */

    function testCreateAndAssignRequiresBothCapabilityHats() public {
        bytes32 pid = _createDefaultProject();

        // TASK_CREATOR wears only CREATE — should fail
        vm.prank(TASK_CREATOR);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createAndAssignTask(1 ether, bytes("ca"), bytes32(0), pid, ASSIGNER, address(0), 0, false);

        // ASSIGNER wears only ASSIGN — should fail
        vm.prank(ASSIGNER);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createAndAssignTask(1 ether, bytes("ca"), bytes32(0), pid, ASSIGNER, address(0), 0, false);

        // dualUser wears both
        address dualUser = address(0xD); // hats 1, 2 — give CREATE + ASSIGN
        hats.mintHat(CREATE_HAT, dualUser);
        hats.mintHat(ASSIGN_HAT, dualUser);
        vm.prank(dualUser);
        tm.createAndAssignTask(1 ether, bytes("ca"), bytes32(0), pid, CLAIMER, address(0), 0, false);
    }

    /* ═══════════════════ Per-project capability hat overrides ═══════════════════ */

    function testProjectCapHatOverridesGlobalCapHat() public {
        // Create a project where CREATE is overridden to PROJ_CREATE_HAT
        vm.prank(PROJECT_CREATOR);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("override"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: PROJ_CREATE_HAT, // project-specific
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // PROJ_CREATE_USER wears PROJ_CREATE_HAT (not global CREATE_HAT) → succeeds
        vm.prank(PROJ_CREATE_USER);
        tm.createTask(1 ether, bytes("ok"), bytes32(0), pid, address(0), 0, false);

        // TASK_CREATOR wears global CREATE_HAT — overridden, fails for this project
        vm.prank(TASK_CREATOR);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("blocked"), bytes32(0), pid, address(0), 0, false);
    }

    function testClearProjectCapHatFallsBackToGlobal() public {
        // Set up project with override
        vm.prank(PROJECT_CREATOR);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("override"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: PROJ_CREATE_HAT,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Initially TASK_CREATOR is blocked (override is active)
        vm.prank(TASK_CREATOR);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("blocked"), bytes32(0), pid, address(0), 0, false);

        // Clear the project override
        vm.prank(PROJECT_CREATOR);
        tm.setProjectRolePerm(pid, 0, TaskPerm.CREATE);

        // Now TASK_CREATOR can create (falls back to global CREATE_HAT)
        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("ok"), bytes32(0), pid, address(0), 0, false);
    }

    function testSetProjectRolePermZeroMaskReverts() public {
        bytes32 pid = _createDefaultProject();
        vm.prank(PROJECT_CREATOR);
        vm.expectRevert(TaskManager.InvalidCapMask.selector);
        tm.setProjectRolePerm(pid, 999, 0); // mask=0 is invalid
    }

    function testSetProjectRolePermOrCombinedMaskReverts() public {
        // Regression guard for finding #5: OR-combined masks would previously be silently
        // stored at projectCapHat[pid][3] (etc.) where `_capHat` never reads. Now they revert.
        bytes32 pid = _createDefaultProject();
        vm.prank(PROJECT_CREATOR);
        vm.expectRevert(TaskManager.InvalidCapMask.selector);
        tm.setProjectRolePerm(pid, 999, TaskPerm.CREATE | TaskPerm.CLAIM);
    }

    function testSetProjectRolePermArbitraryNonSingleBitMaskReverts() public {
        bytes32 pid = _createDefaultProject();
        vm.prank(PROJECT_CREATOR);
        vm.expectRevert(TaskManager.InvalidCapMask.selector);
        // OR-combined (multi-bit) mask is not a single TaskPerm flag — rejected.
        tm.setProjectRolePerm(pid, 999, uint8(TaskPerm.CREATE | TaskPerm.CLAIM));
    }

    /// @notice Sanity: each of the five valid single-bit masks is accepted.
    function testSetProjectRolePermAcceptsAllSingleBitFlags() public {
        bytes32 pid = _createDefaultProject();
        vm.startPrank(PROJECT_CREATOR);
        tm.setProjectRolePerm(pid, 100, TaskPerm.CREATE);
        tm.setProjectRolePerm(pid, 101, TaskPerm.CLAIM);
        tm.setProjectRolePerm(pid, 102, TaskPerm.REVIEW);
        tm.setProjectRolePerm(pid, 103, TaskPerm.ASSIGN);
        tm.setProjectRolePerm(pid, 104, TaskPerm.SELF_REVIEW);
        vm.stopPrank();
    }

    function testDynamicProjectCapHatGrant() public {
        // Project starts with NO REVIEW override
        bytes32 pid = _createDefaultProject();

        vm.prank(TASK_CREATOR);
        tm.createTask(1 ether, bytes("t"), bytes32(0), pid, address(0), 0, false);

        vm.prank(CLAIMER);
        tm.claimTask(0);
        vm.prank(CLAIMER);
        tm.submitTask(0, keccak256("w"));

        // PROJ_REVIEW_USER wears PROJ_REVIEW_HAT (not REVIEW_HAT) — should fail initially
        vm.prank(PROJ_REVIEW_USER);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.completeTask(0);

        // Grant project override for REVIEW to PROJ_REVIEW_HAT
        vm.prank(PROJECT_CREATOR);
        tm.setProjectRolePerm(pid, PROJ_REVIEW_HAT, TaskPerm.REVIEW);

        // Now PROJ_REVIEW_USER can complete
        vm.prank(PROJ_REVIEW_USER);
        tm.completeTask(0);
    }

    /* ═══════════════════ deleteProject cleanup ═══════════════════ */

    function testDeleteProjectClearsAllFiveCapOverrides() public {
        // Create a project with overrides for ALL 4 init capabilities, then add SELF_REVIEW
        vm.prank(PROJECT_CREATOR);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("p"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: PROJ_CREATE_HAT,
                claimHat: PROJ_CLAIM_HAT,
                reviewHat: PROJ_REVIEW_HAT,
                assignHat: PROJ_ASSIGN_HAT,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Add SELF_REVIEW override
        vm.prank(PROJECT_CREATOR);
        tm.setProjectRolePerm(pid, PROJ_SELF_REVIEW_HAT, TaskPerm.SELF_REVIEW);

        // Delete the project
        vm.prank(PROJECT_CREATOR);
        tm.deleteProject(pid);

        // Verify project doesn't exist — createTask on the deleted pid reverts
        vm.prank(TASK_CREATOR);
        vm.expectRevert(TaskManager.NotFound.selector);
        tm.createTask(1 ether, bytes("t"), bytes32(0), pid, address(0), 0, false);
    }

    /* ═══════════════════ Backwards-compat creator-hat path ═══════════════════ */

    function testProjectCreatorHatGatesCreateProject() public {
        // OUTSIDER doesn't wear the projectCreatorHat → can't create project
        vm.prank(OUTSIDER);
        vm.expectRevert(TaskManager.NotCreator.selector);
        tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("x"),
                metadataHash: bytes32(0),
                cap: 1 ether,
                managers: new address[](0),
                createHat: 0,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );
    }

    function testExecutorBypassesAllCapHats() public {
        bytes32 pid = _createDefaultProject();

        // Executor can create even without CREATE hat
        vm.prank(EXECUTOR);
        tm.createTask(1 ether, bytes("exec"), bytes32(0), pid, address(0), 0, false);

        // Executor can claim even without CLAIM hat
        vm.prank(EXECUTOR);
        tm.claimTask(0);

        // Executor can submit (claimer-only path, but executor IS the claimer here)
        vm.prank(EXECUTOR);
        tm.submitTask(0, keccak256("work"));

        // Executor can complete even without REVIEW hat (PM bypass via _isPM check)
        vm.prank(EXECUTOR);
        tm.completeTask(0);
    }
}
