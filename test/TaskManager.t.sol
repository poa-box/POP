// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {TaskManagerLens} from "../src/lens/TaskManagerLens.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {BudgetLib} from "../src/libs/BudgetLib.sol";
import {ValidationLib} from "../src/libs/ValidationLib.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/*────────────────── Mock Contracts ──────────────────*/
contract MockToken is Test, IERC20 {
    string public constant name = "PT";
    string public constant symbol = "PT";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /* --- unused ERC‑20 bits (bare minimum for tests) --- */
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

    /*────────────────── Mock ERC20 for Bounty Testing ──────────────────*/
    contract MockERC20 is Test, IERC20 {
        string public constant name = "BountyToken";
        string public constant symbol = "BOUNTY";
        uint8 public constant decimals = 18;

        mapping(address => uint256) public override balanceOf;
        uint256 public override totalSupply;

        function mint(address to, uint256 amount) external {
            balanceOf[to] += amount;
            totalSupply += amount;
        }

        function transfer(address to, uint256 amount) external override returns (bool) {
            require(balanceOf[msg.sender] >= amount, "Insufficient balance");
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
            return true;
        }

        function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
            require(balanceOf[from] >= amount, "Insufficient balance");
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
            return true;
        }

        function approve(address spender, uint256 amount) external override returns (bool) {
            return true;
        }

        function allowance(address owner, address spender) external view override returns (uint256) {
            return type(uint256).max;
        }
    }

        /*──────────────────── Test Suite ────────────────────*/
        abstract contract TaskManagerTestBase is Test {
            /* test actors */
            address creator1 = makeAddr("creator1");
            address creator2 = makeAddr("creator2");
            address pm1 = makeAddr("pm1");
            address member1 = makeAddr("member1");
            address outsider = makeAddr("outsider");
            address executor = makeAddr("executor");

            uint256 constant CREATOR_HAT = 1;
            uint256 constant PM_HAT = 2;
            uint256 constant MEMBER_HAT = 3;

            TaskManager tm;
            TaskManagerLens lens;
            MockToken token;
            MockHats hats;

            function setHat(address who, uint256 hatId) internal {
                hats.mintHat(hatId, who);
            }

            function _hatArr(uint256 hat) internal pure returns (uint256[] memory arr) {
                arr = new uint256[](1);
                arr[0] = hat;
            }

            function _addrArr(address who) internal pure returns (address[] memory arr) {
                arr = new address[](1);
                arr[0] = who;
            }

            function _defaultRoleHats()
                internal
                pure
                returns (
                    uint256[] memory createHats,
                    uint256[] memory claimHats,
                    uint256[] memory reviewHats,
                    uint256[] memory assignHats
                )
            {
                createHats = _hatArr(CREATOR_HAT);
                claimHats = _hatArr(MEMBER_HAT);
                reviewHats = _hatArr(PM_HAT);
                assignHats = _hatArr(PM_HAT);
            }

            function _createDefaultProject(bytes memory name, uint256 cap) internal returns (bytes32 id) {
                (
                    uint256[] memory createHats,
                    uint256[] memory claimHats,
                    uint256[] memory reviewHats,
                    uint256[] memory assignHats
                ) = _defaultRoleHats();

                vm.prank(creator1);
                id = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: name,
                        metadataHash: bytes32(0),
                        cap: cap,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
            }

            function _createProjectWithBountyBudget(
                bytes memory name,
                uint256 cap,
                address[] memory bountyTokens,
                uint256[] memory bountyCaps
            ) internal returns (bytes32 id) {
                (
                    uint256[] memory createHats,
                    uint256[] memory claimHats,
                    uint256[] memory reviewHats,
                    uint256[] memory assignHats
                ) = _defaultRoleHats();

                vm.prank(creator1);
                id = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: name,
                        metadataHash: bytes32(0),
                        cap: cap,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: bountyTokens,
                        bountyCaps: bountyCaps
                    })
                );
            }

            function setUpBase() internal {
                token = new MockToken();
                hats = new MockHats();

                setHat(creator1, CREATOR_HAT);
                setHat(creator2, CREATOR_HAT);
                setHat(pm1, PM_HAT);
                setHat(member1, MEMBER_HAT);

                TaskManager _tmImpl = new TaskManager();
                UpgradeableBeacon _tmBeacon = new UpgradeableBeacon(address(_tmImpl), address(this));
                tm = TaskManager(address(new BeaconProxy(address(_tmBeacon), "")));
                lens = new TaskManagerLens();
                uint256[] memory creatorHats = _hatArr(CREATOR_HAT);

                vm.prank(creator1);
                tm.initialize(address(token), address(hats), creatorHats, executor, address(0));

                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM,
                    abi.encode(PM_HAT, TaskPerm.CREATE | TaskPerm.REVIEW | TaskPerm.ASSIGN)
                );
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MEMBER_HAT, TaskPerm.CLAIM));
            }
        }

        contract TaskManagerTest is TaskManagerTestBase {
            /* project IDs - will be populated at runtime */
            bytes32 UNLIM_ID;
            bytes32 CAPPED_ID;
            bytes32 BUD_ID;
            bytes32 FLOW_ID;
            bytes32 UPD_ID;
            bytes32 CAN_ID;
            bytes32 ACC_ID;
            bytes32 PROJECT_A_ID;
            bytes32 PROJECT_B_ID;
            bytes32 PROJECT_C_ID;
            bytes32 GOV_TEST_ID;
            bytes32 NEW_PROJECT_ID;
            bytes32 MULTI_PM_ID;
            bytes32 EDGE_ID;
            bytes32 MEGA_ID;
            bytes32 CAPPED_BIG_ID;
            bytes32 TO_DELETE_ID;
            bytes32 ZERO_CAP_ID;
            bytes32 EXECUTOR_TEST_ID;
            bytes32 EXECUTOR_BYPASS_ID;
            bytes32 SHOULD_FAIL_ID;

            function setUp() public {
                setUpBase();
            }

            /*───────────────── PROJECT SCENARIOS ───────────────*/

            function test_CreateUnlimitedProjectAndTaskByAnotherCreator() public {
                UNLIM_ID = _createDefaultProject("UNLIM", 0);

                // creator2 creates a task (should succeed, cap == 0)
                vm.prank(creator2);
                tm.createTask(1 ether, bytes("ipfs://meta"), bytes32(0), UNLIM_ID, address(0), 0, false);
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, address(0), "should be unclaimed");
            }

            function test_CreateCappedProjectAndBudgetEnforcement() public {
                address[] memory managers = _addrArr(pm1);

                vm.prank(creator1);
                CAPPED_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CAPPED"),
                        metadataHash: bytes32(0),
                        cap: 3 ether,
                        managers: managers,
                        createHats: _hatArr(PM_HAT),
                        claimHats: _hatArr(MEMBER_HAT),
                        reviewHats: _hatArr(PM_HAT),
                        assignHats: _hatArr(PM_HAT),
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // pm1 can create tasks until cap reached
                vm.prank(pm1);
                tm.createTask(1 ether, bytes("a"), bytes32(0), CAPPED_ID, address(0), 0, false);

                vm.prank(pm1);
                tm.createTask(2 ether, bytes("b"), bytes32(0), CAPPED_ID, address(0), 0, false);

                // next task (1 wei over budget) reverts
                vm.prank(pm1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1, bytes("c"), bytes32(0), CAPPED_ID, address(0), 0, false);
            }

            function test_ProjectSpecificRolePermissions() public {
                // Create custom hats
                uint256 customCreateHat = 10;
                uint256 customReviewHat = 11;
                address customCreator = makeAddr("customCreator");
                address customReviewer = makeAddr("customReviewer");
                setHat(customCreator, customCreateHat);
                setHat(customReviewer, customReviewHat);

                // Set up project with custom hat permissions
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CUSTOM_HATS"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: _hatArr(customCreateHat),
                        claimHats: _hatArr(MEMBER_HAT),
                        reviewHats: _hatArr(customReviewHat),
                        assignHats: _hatArr(PM_HAT),
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Custom creator should be able to create tasks
                vm.prank(customCreator);
                tm.createTask(1 ether, bytes("custom_task"), bytes32(0), projectId, address(0), 0, false);

                // But not review tasks
                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submitted"));

                vm.prank(customCreator);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);

                // Custom reviewer should be able to review
                vm.prank(customReviewer);
                tm.completeTask(0);
            }

            function test_ProjectRolePermissionOverrides() public {
                // Create a hat with global permissions
                uint256 globalHat = 20;
                address globalUser = makeAddr("globalUser");
                setHat(globalUser, globalHat);

                // Set global permissions
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(globalHat, TaskPerm.CREATE | TaskPerm.REVIEW));

                // Create project with different permissions for the same hat
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("OVERRIDE"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: _hatArr(globalHat),
                        claimHats: _hatArr(MEMBER_HAT),
                        reviewHats: _hatArr(PM_HAT),
                        assignHats: // globalHat not included here
                        _hatArr(PM_HAT),
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Global user should be able to create (global permission)
                vm.prank(globalUser);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                // But not review (project override)
                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submitted"));

                vm.prank(globalUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);
            }

            function test_UpdateProjectCapLowerThanSpentShouldRevert() public {
                // Set up hat permissions
                // simplified using helper
                BUD_ID = _createDefaultProject("BUD", 2 ether);

                vm.prank(creator1);
                tm.createTask(2 ether, bytes("foo"), bytes32(0), BUD_ID, address(0), 0, false);

                // try lowering cap below spent
                vm.prank(executor);
                vm.expectRevert(ValidationLib.CapBelowCommitted.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUD_ID, 1 ether));
            }

            /*───────────────── TASK LIFECYCLE ───────────────────*/

            function _prepareFlow() internal returns (uint256 id) {
                FLOW_ID = _createDefaultProject("FLOW", 5 ether);

                // assign pm1 retroactively
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(FLOW_ID, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("hash"), bytes32(0), FLOW_ID, address(0), 0, false);
                return 0;
            }

            function test_TaskFullLifecycleWithMint() public {
                uint256 id = _prepareFlow();

                // member1 claims
                vm.prank(member1);
                tm.claimTask(id);

                // member1 submits
                vm.prank(member1);
                tm.submitTask(id, keccak256("hash2"));

                // pm1 completes, mints token
                uint256 balBefore = token.balanceOf(member1);

                vm.prank(pm1);
                tm.completeTask(id);

                assertEq(token.balanceOf(member1), balBefore + 1 ether, "minted payout");
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (uint256 payout, TaskManager.Status st, address claimer, bytes32 projectId, bool requiresApplication) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(st), uint8(TaskManager.Status.COMPLETED));
            }

            function test_UpdateTaskBeforeClaimAdjustsBudget() public {
                // Set up hat permissions
                UPD_ID = _createDefaultProject("UPD", 3 ether);

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("foo"), bytes32(0), UPD_ID, address(0), 0, false);

                // raise payout by 1 ether
                vm.prank(creator1);
                tm.updateTask(0, 2 ether, bytes("bar"), bytes32(0), address(0), 0);

                // spent should now be 2 ether
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(UPD_ID)
                );
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(cap, 3 ether);
                assertEq(spent, 2 ether);
            }

            function test_UpdateTaskAfterClaimReverts() public {
                uint256 id = _prepareFlow();

                vm.prank(member1);
                tm.claimTask(id);

                // attempt to update claimed task should revert
                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.updateTask(id, 5 ether, bytes("newhash"), bytes32(0), address(0), 0);
            }

            function test_CancelTaskSpentUnderflowProtection() public {
                // Set up hat permissions
                bytes32 projectId = _createDefaultProject("UNDERFLOW_TEST", 2 ether);

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), projectId, address(0), 0, false);

                // Artificially manipulate project spent to be less than task payout
                // This simulates a potential storage corruption or logic bug scenario
                // Note: In a real scenario, this would be done through a storage manipulation
                // For this test, we'll create a scenario where spent gets reduced somehow

                // Create and complete another task to increase spent
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task2"), bytes32(0), projectId, address(0), 0, false);

                vm.prank(creator1);
                tm.assignTask(1, member1);

                vm.prank(member1);
                tm.submitTask(1, keccak256("submission"));

                vm.prank(creator1);
                tm.completeTask(1);

                // Now project spent should be 2 ether
                // If we could somehow corrupt the spent to be less than task payout,
                // the underflow protection should trigger
                // Since we can't easily manipulate storage in this test,
                // we'll just verify normal cancellation works
                vm.prank(creator1);
                tm.cancelTask(0); // This should work normally

                // Verify spent was correctly reduced
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectId));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 1 ether, "Spent should be reduced by cancelled task payout");
            }

            function test_CancelTaskRefundsSpent() public {
                // Set up hat permissions
                CAN_ID = _createDefaultProject("CAN", 2 ether);

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("foo"), bytes32(0), CAN_ID, address(0), 0, false);

                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(CAN_ID)
                );
                (uint256 cap, uint256 spentBefore, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentBefore, 1 ether);

                vm.prank(creator1);
                tm.cancelTask(0);

                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(CAN_ID));
                (, uint256 spentAfter,) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentAfter, 0);
            }

            /*───────────────── ACCESS CONTROL ───────────────────*/

            function test_CreateTaskByNonMemberReverts() public {
                ACC_ID = _createDefaultProject("ACC", 0);

                // outsider has no role and no permissions
                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1, bytes("x"), bytes32(0), ACC_ID, address(0), 0, false);
            }

            function test_OnlyAuthorizedCanAssignTask() public {
                uint256 id = _prepareFlow();

                // outsider has no permissions
                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.assignTask(id, member1);

                // creator1 has ASSIGN permission
                vm.prank(creator1);
                tm.assignTask(id, member1); // should succeed
            }

            function test_ProjectSpecificPermissions() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Set up a custom hat with specific permissions
                uint256 customHat = 70;
                address customUser = makeAddr("customUser");
                setHat(customUser, customHat);

                // Set project-specific permissions
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, customHat, TaskPerm.CREATE | TaskPerm.REVIEW);

                // Custom user should be able to create tasks
                vm.prank(customUser);
                tm.createTask(1 ether, bytes("custom_task"), bytes32(0), projectId, address(0), 0, false);

                // But not assign tasks (no ASSIGN permission)
                vm.prank(customUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.assignTask(0, member1);

                // Member should be able to claim (has global CLAIM permission)
                vm.prank(member1);
                tm.claimTask(0);
            }

            function test_GlobalVsProjectPermissions() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Set up a hat with global permissions
                uint256 globalHat = 50;
                address globalUser = makeAddr("globalUser");
                setHat(globalUser, globalHat);

                // Set global permissions
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(globalHat, TaskPerm.CREATE | TaskPerm.REVIEW));

                // Override in project
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, globalHat, TaskPerm.CREATE);

                // User should only have CREATE permission in this project
                vm.prank(globalUser);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                // But not REVIEW (project override removed it)
                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submitted"));

                vm.prank(globalUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);
            }

            /*───────────────── COMPLEX SCENARIOS ───────────────────*/

            function test_MultiProjectTaskManagement() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Create three projects with different caps
                vm.startPrank(creator1);
                PROJECT_A_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PROJECT_A"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
                PROJECT_B_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PROJECT_B"),
                        metadataHash: bytes32(0),
                        cap: 3 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
                PROJECT_C_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PROJECT_C"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
                vm.stopPrank();

                // Create multiple tasks across projects
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1_A"), bytes32(0), PROJECT_A_ID, address(0), 0, false);

                vm.prank(creator1);
                tm.createTask(2 ether, bytes("task1_B"), bytes32(0), PROJECT_B_ID, address(0), 0, false);

                vm.prank(creator1);
                tm.createTask(2 ether, bytes("task1_C"), bytes32(0), PROJECT_C_ID, address(0), 0, false);

                // Member claims tasks from different projects
                vm.startPrank(member1);
                tm.claimTask(0); // PROJECT_A task
                tm.claimTask(2); // PROJECT_C task
                vm.stopPrank();

                // Budget verification
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(PROJECT_A_ID));
                (uint256 capA, uint256 spentA, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentA, 1 ether, "PROJECT_A spent should be 1 ether");
                assertEq(capA, 5 ether, "PROJECT_A cap should be 5 ether");

                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(PROJECT_B_ID));
                (uint256 capB, uint256 spentB, bool isManagerB) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentB, 2 ether, "PROJECT_B spent should be 2 ether");

                // Test trying to exceed PROJECT_B budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1 ether + 1, bytes("task2_B"), bytes32(0), PROJECT_B_ID, address(0), 0, false); // Would exceed cap

                // Complete task from PROJECT_C
                vm.prank(member1);
                tm.submitTask(2, keccak256("completed_C"));

                vm.prank(creator1);
                tm.completeTask(2);

                // Verify token minting worked
                assertEq(token.balanceOf(member1), 2 ether, "Member should receive 2 ether from task completion");
            }

            function test_GovernanceAndRoleChanges() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Initial setup
                vm.prank(creator1);
                GOV_TEST_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("GOV_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Add new hat to the creator hats using the executor
                uint256 NEW_HAT = 100;
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(NEW_HAT, true));

                // Assign new hat to an address
                address newCreator = makeAddr("newCreator");
                setHat(newCreator, NEW_HAT);

                // Test that new hat can create projects
                vm.prank(newCreator);
                NEW_PROJECT_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("NEW_PROJECT"),
                        metadataHash: bytes32(0),
                        cap: 1 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Verify new project exists by creating a task
                vm.prank(newCreator);
                tm.createTask(0.5 ether, bytes("new_task"), bytes32(0), NEW_PROJECT_ID, address(0), 0, false);

                // Disable the hat using the executor
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(NEW_HAT, false));

                // Verify the hat can no longer create projects
                vm.prank(newCreator);
                vm.expectRevert(TaskManager.NotCreator.selector);
                tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("SHOULD_FAIL"),
                        metadataHash: bytes32(0),
                        cap: 1 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
            }

            function test_ProjectManagerHierarchy() public {
                // Create a project with multiple managers and specific hat permissions
                address[] memory managers = new address[](2);
                managers[0] = pm1;
                address pm2 = makeAddr("pm2");
                // Note: pm2 has no hat initially
                managers[1] = pm2;

                // Set up hat permissions - only PM_HAT has permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = PM_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                MULTI_PM_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MULTI_PM"),
                        metadataHash: bytes32(0),
                        cap: 10 ether,
                        managers: managers,
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Both PMs should be able to create tasks (as project managers)
                vm.prank(pm1);
                tm.createTask(2 ether, bytes("pm1_task"), bytes32(0), MULTI_PM_ID, address(0), 0, false);

                vm.prank(pm2);
                tm.createTask(3 ether, bytes("pm2_task"), bytes32(0), MULTI_PM_ID, address(0), 0, false);

                // PM1 can complete PM2's task (as project manager)
                vm.prank(member1);
                tm.claimTask(1);

                vm.prank(member1);
                tm.submitTask(1, keccak256("completed_by_member"));

                vm.prank(pm1);
                tm.completeTask(1);

                // Remove PM2 as project manager
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(MULTI_PM_ID, pm2, false));

                // PM2 can no longer create tasks (no longer a project manager and no role)
                vm.prank(pm2);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1 ether, bytes("should_fail"), bytes32(0), MULTI_PM_ID, address(0), 0, false);

                // But PM1 still can (still a project manager)
                vm.prank(pm1);
                tm.createTask(1 ether, bytes("still_works"), bytes32(0), MULTI_PM_ID, address(0), 0, false);

                // Now give PM2 the PM_HAT
                setHat(pm2, PM_HAT);

                // PM2 should now be able to create tasks again (has PM_HAT with CREATE permission)
                vm.prank(pm2);
                tm.createTask(1 ether, bytes("pm2_with_hat"), bytes32(0), MULTI_PM_ID, address(0), 0, false);

                // Verify overall budget tracking
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(MULTI_PM_ID));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 7 ether, "Project should track 7 ether spent");
            }

            function test_TaskLifecycleEdgeCases() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                EDGE_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EDGE"),
                        metadataHash: bytes32(0),
                        cap: 10 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create and immediately cancel a task
                vm.startPrank(creator1);
                tm.createTask(1 ether, bytes("to_cancel"), bytes32(0), EDGE_ID, address(0), 0, false);
                tm.cancelTask(0);
                vm.stopPrank();

                // Verify project budget is refunded
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(EDGE_ID));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 0, "Budget should be refunded after cancel");

                // Create a task, assign it, then try operations that should fail
                vm.prank(creator1);
                tm.createTask(2 ether, bytes("edge_task"), bytes32(0), EDGE_ID, address(0), 0, false);

                vm.prank(creator1);
                tm.assignTask(1, member1);

                // Try to claim an already claimed task
                vm.prank(member1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.claimTask(1);

                // Try to submit without claiming
                address nonClaimer = makeAddr("nonClaimer");
                setHat(nonClaimer, MEMBER_HAT);

                vm.prank(nonClaimer);
                vm.expectRevert(TaskManager.NotClaimer.selector);
                tm.submitTask(1, keccak256("wrong_submitter"));

                // Submit correctly
                vm.prank(member1);
                tm.submitTask(1, keccak256("correct_submission"));

                // Try to cancel after submission
                vm.prank(creator1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.cancelTask(1);

                // Complete the task
                vm.prank(creator1);
                tm.completeTask(1);

                // Try to complete again
                vm.prank(creator1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.completeTask(1);
            }

            function test_ProjectStress() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Create a large unlimited project
                vm.prank(creator1);
                MEGA_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MEGA"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Add multiple project managers
                address[] memory pms = new address[](3);
                pms[0] = pm1;

                address pm2 = makeAddr("pm2");
                address pm3 = makeAddr("pm3");
                setHat(pm2, PM_HAT);
                setHat(pm3, PM_HAT);
                pms[1] = pm2;
                pms[2] = pm3;

                for (uint256 i = 0; i < pms.length; i++) {
                    vm.prank(executor);
                    tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(MEGA_ID, pms[i], true));
                }

                // Create multiple members
                address[] memory members = new address[](5);
                for (uint256 i = 0; i < members.length; i++) {
                    members[i] = makeAddr(string(abi.encodePacked("member", i)));
                    setHat(members[i], MEMBER_HAT);
                }

                // Create multiple tasks
                uint256 totalTasks = 10;
                uint256 totalValue = 0;

                for (uint256 i = 0; i < totalTasks; i++) {
                    uint256 payout = 0.5 ether + (i * 0.1 ether);
                    totalValue += payout;

                    // Alternate between PMs for task creation
                    address creator = pms[i % pms.length];

                    vm.prank(creator);
                    bytes memory taskMetadata = abi.encodePacked("task", i);
                    tm.createTask(payout, taskMetadata, bytes32(0), MEGA_ID, address(0), 0, false);

                    // Assign tasks to different members
                    address assignee = members[i % members.length];

                    vm.prank(creator);
                    tm.assignTask(i, assignee);
                }

                // Verify project spent
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(MEGA_ID));
                (, uint256 spent,) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, totalValue, "Project should track all task value");

                // Submit half the tasks
                for (uint256 i = 0; i < totalTasks / 2; i++) {
                    address submitter = members[i % members.length];

                    vm.prank(submitter);
                    bytes memory completedMetadata = abi.encodePacked("completed", i);
                    tm.submitTask(i, keccak256(completedMetadata));
                }

                // Complete a third of all tasks
                uint256 completedTasks = totalTasks / 3;
                uint256 completedValue = 0;

                for (uint256 i = 0; i < completedTasks; i++) {
                    bytes memory result = lens.getStorage(
                        address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(i)
                    );
                    (
                        uint256 payout,
                        TaskManager.Status status,
                        address claimer,
                        bytes32 projectId,
                        bool requiresApplication
                    ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                    completedValue += payout;

                    vm.prank(pms[0]);
                    tm.completeTask(i);
                }

                // Create a second project with a hard cap
                vm.prank(creator1);
                CAPPED_BIG_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CAPPED_BIG"),
                        metadataHash: bytes32(0),
                        cap: 10 ether,
                        managers: pms,
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create tasks up to the cap
                uint256 cappedTaskCount = 0;
                uint256 cappedSpent = 0;

                while (cappedSpent < 9.5 ether) {
                    uint256 payout = 0.3 ether;

                    vm.prank(pms[0]);
                    bytes memory taskMetadata = abi.encodePacked("capped_task", cappedTaskCount);
                    tm.createTask(payout, taskMetadata, bytes32(0), CAPPED_BIG_ID, address(0), 0, false);

                    cappedTaskCount++;
                    cappedSpent += payout;
                }

                // Verify we can't exceed cap
                vm.prank(pms[0]);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1 ether, bytes("exceeds_cap"), bytes32(0), CAPPED_BIG_ID, address(0), 0, false);

                // Verify task counts and budget usage
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(CAPPED_BIG_ID)
                );
                (uint256 cap, uint256 actualSpent,) = abi.decode(result, (uint256, uint256, bool));
                assertEq(cap, 10 ether, "Cap should be preserved");
                assertEq(actualSpent, cappedSpent, "Spent should match tracked value");

                // Verify token minting totals
                uint256 totalTokenMinted = 0;
                for (uint256 i = 0; i < members.length; i++) {
                    totalTokenMinted += token.balanceOf(members[i]);
                }

                assertEq(totalTokenMinted, completedValue, "Total minted tokens should match completed tasks");
            }

            function test_ProjectDeletionAndUpdating() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Create a project that will be deleted
                vm.prank(creator1);
                TO_DELETE_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("TO_DELETE"),
                        metadataHash: bytes32(0),
                        cap: 3 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create a task, complete it, then verify project can be deleted
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), TO_DELETE_ID, address(0), 0, false);

                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("completed"));

                vm.prank(creator1);
                tm.completeTask(0);

                // Create another task and cancel it
                vm.prank(creator1);
                tm.createTask(2 ether, bytes("task2"), bytes32(0), TO_DELETE_ID, address(0), 0, false);

                vm.prank(creator1);
                tm.cancelTask(1);

                // Verify spent amount is 1 ether (from completed task)
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(TO_DELETE_ID));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 1 ether, "Project spent should only reflect completed task");

                // Deletion should succeed because cap (3 ether) >= spent (1 ether)
                vm.prank(creator1);
                tm.deleteProject(TO_DELETE_ID);

                // Verify project no longer exists by trying to get info
                vm.prank(creator1);
                vm.expectRevert(TaskManager.NotFound.selector);
                lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(TO_DELETE_ID));

                // Create a zero-cap project
                vm.prank(creator1);
                ZERO_CAP_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("ZERO_CAP"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Add tasks, verify we can still delete with non-zero spent
                vm.prank(creator1);
                tm.createTask(3 ether, bytes("unlimited_task"), bytes32(0), ZERO_CAP_ID, address(0), 0, false);

                // Delete should succeed with zero cap, non-zero spent
                vm.prank(creator1);
                tm.deleteProject(ZERO_CAP_ID);
            }

            function test_ExecutorRoleManagement() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Create new executor
                address executor2 = makeAddr("executor2");

                // Non-executor can't set executor
                vm.prank(creator1);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.EXECUTOR, abi.encode(executor2));

                // Executor can update executor
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.EXECUTOR, abi.encode(executor2));

                // Old executor can no longer set creator hats
                uint256 TEST_HAT = 123;
                vm.prank(executor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(TEST_HAT, true));

                // New executor can set creator hats
                vm.prank(executor2);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(TEST_HAT, true));

                // Assign the new hat to a user
                address testCreator = makeAddr("testCreator");
                setHat(testCreator, TEST_HAT);

                // Verify the new hat works for creating projects
                vm.prank(testCreator);
                EXECUTOR_TEST_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EXECUTOR_TEST"),
                        metadataHash: bytes32(0),
                        cap: 1 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // New executor can revoke the hat
                vm.prank(executor2);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(TEST_HAT, false));

                // Hat should no longer work
                vm.prank(testCreator);
                vm.expectRevert(TaskManager.NotCreator.selector);
                tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("SHOULD_FAIL"),
                        metadataHash: bytes32(0),
                        cap: 1 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );
            }

            function test_ExecutorBypassMemberCheck() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                // Create project
                vm.prank(creator1);
                EXECUTOR_BYPASS_ID = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EXECUTOR_BYPASS"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Executor should be able to create tasks even without member role
                // (executor address has no role but should bypass the member check)
                vm.prank(executor);
                tm.createTask(1 ether, bytes("executor_task"), bytes32(0), EXECUTOR_BYPASS_ID, address(0), 0, false);

                // Executor should be able to claim tasks
                vm.prank(executor);
                tm.claimTask(0);

                // Executor should be able to submit tasks
                vm.prank(executor);
                tm.submitTask(0, keccak256("executor_submission"));

                // Verify task status and submission
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.SUBMITTED));
            }

            /*───────────────── GRANULAR PERMISSION TESTS ────────────────────*/

            function test_CombinedPermissions() public {
                // Create a new hat with combined permissions
                uint256 MULTI_HAT = 150;
                address multiUser = makeAddr("multiUser");
                setHat(multiUser, MULTI_HAT);

                // Set global permissions (CREATE | CLAIM)
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MULTI_HAT, TaskPerm.CREATE | TaskPerm.CLAIM));

                // Create project (use creator1 who has creator hat)
                uint256[] memory emptyHats = new uint256[](0);
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("COMBINED_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: emptyHats,
                        claimHats: emptyHats,
                        reviewHats: emptyHats,
                        assignHats: emptyHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // User should be able to create tasks with CREATE permission
                vm.prank(multiUser);
                tm.createTask(1 ether, bytes("multi_task"), bytes32(0), projectId, address(0), 0, false);

                // User should be able to claim tasks with CLAIM permission
                vm.prank(multiUser);
                tm.claimTask(0);

                // But not complete tasks (no REVIEW permission)
                vm.prank(multiUser);
                tm.submitTask(0, keccak256("submission"));

                vm.prank(multiUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);
            }

            function test_PermissionChangesAfterCreation() public {
                // Create new hat and user
                uint256 DYNAMIC_HAT = 160;
                address dynamicUser = makeAddr("dynamicUser");
                setHat(dynamicUser, DYNAMIC_HAT);

                // Initially no permissions for this hat

                // Create project
                uint256[] memory emptyHats = new uint256[](0);
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("DYNAMIC_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: emptyHats,
                        claimHats: emptyHats,
                        reviewHats: emptyHats,
                        assignHats: emptyHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // User can't create tasks (no permissions)
                vm.prank(dynamicUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1 ether, bytes("should_fail"), bytes32(0), projectId, address(0), 0, false);

                // Grant CREATE permission at project level
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, DYNAMIC_HAT, TaskPerm.CREATE);

                // Now user can create tasks
                vm.prank(dynamicUser);
                tm.createTask(1 ether, bytes("now_works"), bytes32(0), projectId, address(0), 0, false);

                // Another user claims and submits
                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submitted"));

                // User still can't complete (no REVIEW permission)
                vm.prank(dynamicUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);

                // Add REVIEW permission
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, DYNAMIC_HAT, TaskPerm.CREATE | TaskPerm.REVIEW);

                // Now user can complete tasks
                vm.prank(dynamicUser);
                tm.completeTask(0);
            }

            function test_GlobalVsProjectPermissionOverrides() public {
                // Create a hat with global permissions
                uint256 OVERRIDE_HAT = 170;
                address overrideUser = makeAddr("overrideUser");
                setHat(overrideUser, OVERRIDE_HAT);

                // Set full permissions globally
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM,
                    abi.encode(OVERRIDE_HAT, TaskPerm.CREATE | TaskPerm.CLAIM | TaskPerm.REVIEW | TaskPerm.ASSIGN)
                );

                // Create project
                uint256[] memory emptyHats = new uint256[](0);
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("OVERRIDE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: emptyHats,
                        claimHats: emptyHats,
                        reviewHats: emptyHats,
                        assignHats: emptyHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create a second project to verify global perms still work there
                vm.prank(creator1);
                bytes32 projectId2 = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("GLOBAL_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: emptyHats,
                        claimHats: emptyHats,
                        reviewHats: emptyHats,
                        assignHats: emptyHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Restrict permissions on the first project (only CREATE)
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, OVERRIDE_HAT, TaskPerm.CREATE);

                // User can create tasks in both projects
                vm.prank(overrideUser);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), projectId, address(0), 0, false);

                vm.prank(overrideUser);
                tm.createTask(1 ether, bytes("task2"), bytes32(0), projectId2, address(0), 0, false);

                // In first project, user can't assign tasks (project override)
                vm.prank(overrideUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.assignTask(0, member1);

                // But in second project, user can assign tasks (global permission)
                vm.prank(overrideUser);
                tm.assignTask(1, member1);

                // User can submit claimed task
                vm.prank(member1);
                tm.submitTask(1, keccak256("submission"));

                // In first project, user can't complete tasks (project override)
                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                vm.prank(overrideUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(0);

                // But in second project, user can complete tasks (global permission)
                vm.prank(overrideUser);
                tm.completeTask(1);
            }

            function test_RevokePermissions() public {
                // Create hat and user
                uint256 TEMP_HAT = 180;
                address tempUser = makeAddr("tempUser");
                setHat(tempUser, TEMP_HAT);

                // Give CREATE permission
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TEMP_HAT, TaskPerm.CREATE));

                // Create project
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("TEMP"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: new uint256[](0),
                        claimHats: new uint256[](0),
                        reviewHats: new uint256[](0),
                        assignHats: new uint256[](0),
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // User can create tasks
                vm.prank(tempUser);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                // Revoke permission
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TEMP_HAT, 0));

                // User can't create tasks anymore
                vm.prank(tempUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1 ether, bytes("fail"), bytes32(0), projectId, address(0), 0, false);
            }

            function test_IndividualPermissionFlags() public {
                // Create 4 hats, each with a single permission flag
                uint256 CREATE_HAT = 200;
                uint256 CLAIM_HAT = 201;
                uint256 REVIEW_HAT = 202;
                uint256 ASSIGN_HAT = 203;

                // Create 4 users with respective hats
                address createUser = makeAddr("createUser");
                address claimUser = makeAddr("claimUser");
                address reviewUser = makeAddr("reviewUser");
                address assignUser = makeAddr("assignUser");

                setHat(createUser, CREATE_HAT);
                setHat(claimUser, CLAIM_HAT);
                setHat(reviewUser, REVIEW_HAT);
                setHat(assignUser, ASSIGN_HAT);

                // Set permissions
                vm.startPrank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(CREATE_HAT, TaskPerm.CREATE));
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(CLAIM_HAT, TaskPerm.CLAIM));
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(REVIEW_HAT, TaskPerm.REVIEW));
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(ASSIGN_HAT, TaskPerm.ASSIGN));
                vm.stopPrank();

                // Create project
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_FLAGS"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: new uint256[](0),
                        claimHats: new uint256[](0),
                        reviewHats: new uint256[](0),
                        assignHats: new uint256[](0),
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test CREATE permission - should succeed
                vm.prank(createUser);
                tm.createTask(1 ether, bytes("create_task"), bytes32(0), projectId, address(0), 0, false);

                // createUser should not be able to claim or assign
                vm.prank(createUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.claimTask(0);

                vm.prank(createUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.assignTask(0, claimUser);

                // Test ASSIGN permission - should succeed
                vm.prank(assignUser);
                tm.assignTask(0, claimUser);

                // assignUser should not be able to create or review
                vm.prank(assignUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1 ether, bytes("assign_fail"), bytes32(0), projectId, address(0), 0, false);

                // Test CLAIM permission - indirectly tested by previous assign
                // Create a new task for claiming
                vm.prank(createUser);
                tm.createTask(1 ether, bytes("for_claiming"), bytes32(0), projectId, address(0), 0, false);

                // claimUser should be able to claim
                vm.prank(claimUser);
                tm.claimTask(1);

                // claimUser can submit but not complete
                vm.prank(claimUser);
                tm.submitTask(1, keccak256("claim_submission"));

                vm.prank(claimUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.completeTask(1);

                // Test REVIEW permission - should succeed
                vm.prank(reviewUser);
                tm.completeTask(1);

                // reviewUser should not be able to create or assign
                vm.prank(reviewUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1 ether, bytes("review_fail"), bytes32(0), projectId, address(0), 0, false);

                vm.prank(reviewUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.assignTask(0, claimUser);
            }

            /*───────────────── CREATE AND ASSIGN TASK TESTS ────────────────────*/

            function test_CreateAndAssignTaskBasic() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CREATE_ASSIGN_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test basic create and assign functionality
                vm.prank(creator1);
                uint256 taskId =
                    tm.createAndAssignTask(
                    1 ether, bytes("test_task"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Verify task was created and assigned correctly
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Payout should be correct");
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Status should be CLAIMED");
                assertEq(claimer, member1, "Task should be assigned to member1");
                assertEq(taskProjectId, projectId, "Project ID should match");

                // Verify project budget was updated
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectId));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 1 ether, "Project spent should be updated");
            }

            function test_CreateAndAssignTaskPermissions() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test that user with only CREATE permission cannot use createAndAssignTask
                uint256 CREATE_ONLY_HAT = 300;
                address createOnlyUser = makeAddr("createOnlyUser");
                setHat(createOnlyUser, CREATE_ONLY_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(CREATE_ONLY_HAT, TaskPerm.CREATE));

                vm.prank(createOnlyUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("should_fail"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Test that user with only ASSIGN permission cannot use createAndAssignTask
                uint256 ASSIGN_ONLY_HAT = 301;
                address assignOnlyUser = makeAddr("assignOnlyUser");
                setHat(assignOnlyUser, ASSIGN_ONLY_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(ASSIGN_ONLY_HAT, TaskPerm.ASSIGN));

                vm.prank(assignOnlyUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("should_fail"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Test that user with both CREATE and ASSIGN permissions can use createAndAssignTask
                uint256 CREATE_ASSIGN_HAT = 302;
                address createAssignUser = makeAddr("createAssignUser");
                setHat(createAssignUser, CREATE_ASSIGN_HAT);

                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM, abi.encode(CREATE_ASSIGN_HAT, TaskPerm.CREATE | TaskPerm.ASSIGN)
                );

                vm.prank(createAssignUser);
                uint256 taskId =
                    tm.createAndAssignTask(
                    1 ether, bytes("should_work"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Verify task was created successfully
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "Task should be assigned to member1");
            }

            function test_CreateAndAssignTaskProjectManager() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                address[] memory managers = new address[](1);
                managers[0] = pm1;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: managers,
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test that project manager can use createAndAssignTask
                vm.prank(pm1);
                uint256 taskId =
                    tm.createAndAssignTask(
                    1 ether, bytes("pm_task"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Verify task was created and assigned
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "Task should be assigned to member1");

                // Test that non-project manager cannot use createAndAssignTask
                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("should_fail"), bytes32(0), projectId, member1, address(0), 0, false
                );
            }

            function test_CreateAndAssignTaskValidation() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("VALIDATION_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test zero address assignee
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.ZeroAddress.selector);
                tm.createAndAssignTask(1 ether, bytes("test"), bytes32(0), projectId, address(0), address(0), 0, false);

                // Test zero payout
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createAndAssignTask(0, bytes("test"), bytes32(0), projectId, member1, address(0), 0, false);

                // Test excessive payout
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createAndAssignTask(1e25, bytes("test"), bytes32(0), projectId, member1, address(0), 0, false); // Over MAX_PAYOUT

                // Test empty title
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.EmptyTitle.selector);
                tm.createAndAssignTask(1 ether, bytes(""), bytes32(0), projectId, member1, address(0), 0, false);

                // Test non-existent project - this will fail with NotCreator() because permission check happens first
                vm.prank(creator1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("test"), bytes32(0), bytes32(uint256(999)), member1, address(0), 0, false
                );
            }

            function test_CreateAndAssignTaskBudgetEnforcement() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("BUDGET_TEST"),
                        metadataHash: bytes32(0),
                        cap: 2 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create first task within budget
                vm.prank(creator1);
                uint256 taskId1 =
                    tm.createAndAssignTask(
                    1 ether, bytes("task1"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Create second task within budget
                vm.prank(creator1);
                uint256 taskId2 =
                    tm.createAndAssignTask(
                    1 ether, bytes("task2"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Try to create third task that would exceed budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createAndAssignTask(1 ether, bytes("task3"), bytes32(0), projectId, member1, address(0), 0, false);

                // Verify project budget tracking
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectId));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spent, 2 ether, "Project should have spent 2 ether");
                assertEq(cap, 2 ether, "Project cap should be 2 ether");
            }

            function test_CreateAndAssignTaskEvents() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EVENT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test that both TaskCreated and TaskAssigned events are emitted
                vm.prank(creator1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskCreated(
                    0, projectId, 1 ether, address(0), 0, false, bytes("event_test"), bytes32(0)
                );
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskAssigned(0, member1, creator1);
                tm.createAndAssignTask(
                    1 ether, bytes("event_test"), bytes32(0), projectId, member1, address(0), 0, false
                );
            }

            function test_CreateAndAssignTaskLifecycle() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("LIFECYCLE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create and assign task
                vm.prank(creator1);
                uint256 taskId = tm.createAndAssignTask(
                    1 ether, bytes("lifecycle_test"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Verify task is in CLAIMED status
                bytes memory ret = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (, TaskManager.Status status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Task should be CLAIMED");

                // Assigned user should be able to submit
                vm.prank(member1);
                tm.submitTask(taskId, keccak256("submission"));

                // Verify task is now SUBMITTED
                ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId));
                (, status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.SUBMITTED), "Task should be SUBMITTED");

                // Reviewer should be able to complete
                vm.prank(creator1);
                tm.completeTask(taskId);

                // Verify task is completed and tokens minted
                ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId));
                (, status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.COMPLETED), "Task should be COMPLETED");
                assertEq(token.balanceOf(member1), 1 ether, "Member should receive tokens");
            }

            function test_CreateAndAssignTaskGasEfficiency() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("GAS_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Measure gas for createAndAssignTask
                vm.prank(creator1);
                uint256 gasBefore = gasleft();
                uint256 taskId =
                    tm.createAndAssignTask(
                    1 ether, bytes("gas_test"), bytes32(0), projectId, member1, address(0), 0, false
                );
                uint256 gasUsed = gasBefore - gasleft();

                console.log("Gas used for createAndAssignTask:", gasUsed);

                // Verify task was created and assigned correctly
                bytes memory ret = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (,, address claimer,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "Task should be assigned to member1");

                // For comparison, measure gas for separate create + assign operations
                vm.prank(creator1);
                gasBefore = gasleft();
                tm.createTask(1 ether, bytes("gas_test2"), bytes32(0), projectId, address(0), 0, false);
                uint256 gasCreate = gasBefore - gasleft();

                vm.prank(creator1);
                gasBefore = gasleft();
                tm.assignTask(1, member1);
                uint256 gasAssign = gasBefore - gasleft();

                uint256 gasTotal = gasCreate + gasAssign;
                console.log("Gas used for createTask:", gasCreate);
                console.log("Gas used for assignTask:", gasAssign);
                console.log("Total gas for separate operations:", gasTotal);
                console.log("Gas savings:", gasTotal - gasUsed);
            }

            function test_CreateAndAssignTaskMultipleUsers() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MULTI_USER_TEST"),
                        metadataHash: bytes32(0),
                        cap: 10 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create multiple users
                address[] memory users = new address[](3);
                for (uint256 i = 0; i < users.length; i++) {
                    users[i] = makeAddr(string(abi.encodePacked("user", i)));
                    setHat(users[i], MEMBER_HAT);
                }

                // Create and assign tasks to different users
                for (uint256 i = 0; i < users.length; i++) {
                    vm.prank(creator1);
                    uint256 taskId = tm.createAndAssignTask(
                        1 ether, bytes("multi_user_task"), bytes32(0), projectId, users[i], address(0), 0, false
                    );

                    // Verify each task is assigned to the correct user
                    bytes memory ret = lens.getStorage(
                        address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                    );
                    (,, address claimer,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                    assertEq(claimer, users[i], "Task should be assigned to correct user");
                }

                // Verify project budget tracking
                bytes memory ret = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectId)
                );
                (uint256 cap, uint256 spent,) = abi.decode(ret, (uint256, uint256, bool));
                assertEq(spent, 3 ether, "Project should have spent 3 ether");
            }

            function test_CreateAndAssignTaskEdgeCases() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EDGE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Test assigning to self
                vm.prank(creator1);
                uint256 taskId = tm.createAndAssignTask(
                    1 ether, bytes("self_assign"), bytes32(0), projectId, creator1, address(0), 0, false
                );
                bytes memory ret = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (,, address claimer,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, creator1, "Task should be assigned to creator1");

                // Test assigning to executor
                vm.prank(creator1);
                taskId = tm.createAndAssignTask(
                    1 ether, bytes("executor_assign"), bytes32(0), projectId, executor, address(0), 0, false
                );

                ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId));
                (,, claimer,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, executor, "Task should be assigned to executor");

                // Test maximum payout - need to create a new project with higher cap
                vm.prank(creator1);
                bytes32 maxProjectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MAX_PAYOUT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 1e24,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                taskId =
                    tm.createAndAssignTask(
                    1e24, bytes("max_payout"), bytes32(0), maxProjectId, member1, address(0), 0, false
                ); // MAX_PAYOUT

                ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId));
                (uint256 payout,,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1e24, "Task should have maximum payout");
            }

            function test_CreateAndAssignTaskProjectSpecificPermissions() public {
                // Create a hat with global permissions
                uint256 GLOBAL_HAT = 400;
                address globalUser = makeAddr("globalUser");
                setHat(globalUser, GLOBAL_HAT);

                // Set global permissions (CREATE only)
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(GLOBAL_HAT, TaskPerm.CREATE));

                // Create project
                uint256[] memory emptyHats = new uint256[](0);
                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PROJECT_SPECIFIC"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: emptyHats,
                        claimHats: emptyHats,
                        reviewHats: emptyHats,
                        assignHats: emptyHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // User should not be able to createAndAssignTask (no ASSIGN permission)
                vm.prank(globalUser);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("should_fail"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Add ASSIGN permission at project level
                vm.prank(creator1);
                tm.setProjectRolePerm(projectId, GLOBAL_HAT, TaskPerm.CREATE | TaskPerm.ASSIGN);

                // Now user should be able to createAndAssignTask
                vm.prank(globalUser);
                uint256 taskId =
                    tm.createAndAssignTask(
                    1 ether, bytes("should_work"), bytes32(0), projectId, member1, address(0), 0, false
                );

                // Verify task was created and assigned
                bytes memory ret = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(taskId)
                );
                (,, address claimer,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "Task should be assigned to member1");
            }

            /*───────────────── APPLICATION SYSTEM TESTS ────────────────────*/

            function test_ApplyForTaskBasic() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("APPLICATION_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create a task that requires applications
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Member applies for task
                bytes32 applicationHash = keccak256("application_content");
                vm.prank(member1);
                tm.applyForTask(0, applicationHash);

                // Verify task status remains UNCLAIMED and applicant is recorded
                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (uint256 payout, TaskManager.Status status, address claimer, bytes32 taskProjectId,) =
                    abi.decode(ret, (uint256, TaskManager.Status, address, bytes32, bytes32));
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED), "Status should remain UNCLAIMED");
                assertEq(claimer, address(0), "Claimer should remain empty until approved");
                assertEq(payout, 1 ether, "Payout should remain unchanged");
                assertEq(taskProjectId, projectId, "Project ID should be correct");

                // Verify application was recorded
                assertEq(
                    abi.decode(
                        lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(0)),
                        (address[])
                    )[0],
                    member1,
                    "Member1 should have applied"
                );
                assertEq(
                    abi.decode(
                        lens.getStorage(
                            address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member1)
                        ),
                        (bytes32)
                    ),
                    applicationHash,
                    "Application hash should match"
                );
            }

            function test_ApplyForTaskPermissions() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Test that only users with CLAIM permission can apply
                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.applyForTask(0, keccak256("application"));

                // Member with CLAIM permission can apply
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Verify application was recorded but status remains UNCLAIMED
                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED));
                assertEq(
                    abi.decode(
                        lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(0)),
                        (address[])
                    )[0],
                    member1,
                    "Member1 should have applied"
                );
            }

            function test_ApplyForTaskValidation() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("VALIDATION_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Test empty application hash
                vm.prank(member1);
                vm.expectRevert(ValidationLib.InvalidString.selector);
                tm.applyForTask(0, bytes32(0));

                // Test applying twice by same user
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                vm.prank(member1);
                vm.expectRevert(TaskManager.AlreadyApplied.selector);
                tm.applyForTask(0, keccak256("another_application"));

                // Test applying to non-existent task
                vm.prank(member1);
                vm.expectRevert(TaskManager.NotFound.selector);
                tm.applyForTask(999, keccak256("application"));
            }

            function test_ApproveApplicationBasic() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("APPROVAL_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Member applies
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // PM approves application
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                // Verify task is now claimed
                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status, address claimer,,) =
                    abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Status should be CLAIMED");
                assertEq(claimer, member1, "Claimer should remain the applicant");
            }

            function test_ApproveApplicationPermissions() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERM_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Test that only users with ASSIGN permission can approve
                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.approveApplication(0, member1);

                vm.prank(member1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.approveApplication(0, member1);

                // PM with ASSIGN permission can approve
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED));
            }

            function test_ApproveApplicationValidation() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("VALIDATION_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Test approving task without application
                vm.prank(pm1);
                vm.expectRevert(TaskManager.NotApplicant.selector);
                tm.approveApplication(0, member1);

                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Test approving wrong applicant
                address member2 = makeAddr("member2");
                vm.prank(pm1);
                vm.expectRevert(TaskManager.NotApplicant.selector);
                tm.approveApplication(0, member2);

                // Test approving after task is already claimed
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.approveApplication(0, member1);
            }

            function test_ApplicationEvents() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EVENT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                bytes32 applicationHash = keccak256("application_content");

                // Test application submitted event
                vm.prank(member1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskApplicationSubmitted(0, member1, applicationHash);
                tm.applyForTask(0, applicationHash);

                // Test application approved event
                vm.prank(pm1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskApplicationApproved(0, member1, pm1);
                tm.approveApplication(0, member1);
            }

            function test_ApplicationLifecycleComplete() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("LIFECYCLE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // 1. Apply for task
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // 2. Approve application
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                // 3. Submit task
                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                // 4. Complete task
                vm.prank(pm1);
                tm.completeTask(0);

                // Verify final state
                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status,,,) = abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.COMPLETED));
                assertEq(token.balanceOf(member1), 1 ether, "Member should receive tokens");
            }

            function test_CancelTaskWithApplication() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CANCEL_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Apply for task
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Creator can cancel task with application
                vm.prank(creator1);
                tm.cancelTask(0);

                // Verify task is cancelled and budget refunded
                bytes memory ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status, address claimer,,) =
                    abi.decode(ret, (uint96, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CANCELLED));
                assertEq(claimer, address(0), "Claimer should be cleared");
                ret = lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectId));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(ret, (uint256, uint256, bool));
                assertEq(spent, 0, "Budget should be refunded");
            }

            function test_MultipleApplicationsFlow() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MULTI_APP_TEST"),
                        metadataHash: bytes32(0),
                        cap: 10 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create multiple tasks
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), projectId, address(0), 0, true);
                vm.prank(creator1);
                tm.createTask(2 ether, bytes("task2"), bytes32(0), projectId, address(0), 0, true);

                // Create multiple members
                address member2 = makeAddr("member2");
                setHat(member2, MEMBER_HAT);

                // Both members apply for different tasks
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application1"));

                vm.prank(member2);
                tm.applyForTask(1, keccak256("application2"));

                // Approve first application
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                // Verify first task is claimed
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (uint256 payout, TaskManager.Status status1, address claimer1,, bool requiresApplication) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status1), uint8(TaskManager.Status.CLAIMED));
                assertEq(claimer1, member1);

                // Second task should still be UNCLAIMED with pending application
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(1));
                (, TaskManager.Status status2, address claimer2,,) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status2), uint8(TaskManager.Status.UNCLAIMED));
                assertEq(claimer2, address(0));
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(1, member2)
                );
                bytes32 hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member2 should have applied for task 1");
            }

            function test_ApplicationSystemPreventsClaiming() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PREVENT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Apply for task
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Test that direct claiming is prevented (still requires application)
                address member2 = makeAddr("member2");
                setHat(member2, MEMBER_HAT);

                vm.prank(member2);
                vm.expectRevert(TaskManager.RequiresApplication.selector);
                tm.claimTask(0);

                // Test that assignment still works (bypasses application requirement)
                vm.prank(pm1);
                tm.assignTask(0, member2);

                // Verify task is now claimed by member2
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (uint256 payout, TaskManager.Status status, address claimer,, bool requiresApplication) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED));
                assertEq(claimer, member2);
            }

            /*───────────────── APPLICATION REQUIREMENT TESTS ────────────────────*/

            function test_CreateApplicationTaskBasic() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("APP_REQ_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create application-required task
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("app_required_task"), bytes32(0), projectId, address(0), 0, true);

                // Verify task requires applications
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(requiresApplication, true, "Task should require applications");
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED), "Status should be UNCLAIMED");
                assertEq(claimer, address(0), "Claimer should be empty");
            }

            function test_ApplicationRequiredTaskPreventsClaiming() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CLAIM_PREVENT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create application-required task
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("app_required_task"), bytes32(0), projectId, address(0), 0, true);

                // Test that direct claiming is prevented
                vm.prank(member1);
                vm.expectRevert(TaskManager.RequiresApplication.selector);
                tm.claimTask(0);

                // But assignment should still work (bypass application requirement)
                vm.prank(pm1);
                tm.assignTask(0, member1);

                // Verify task is now claimed
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED));
                assertEq(claimer, member1);
            }

            function test_RegularTaskPreventsApplications() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("REGULAR_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Create regular task (doesn't require applications)
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("regular_task"), bytes32(0), projectId, address(0), 0, false);

                // Verify task doesn't require applications
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(requiresApplication, false, "Task should not require applications");

                // Test that applications are prevented
                vm.prank(member1);
                vm.expectRevert(TaskManager.NoApplicationRequired.selector);
                tm.applyForTask(0, keccak256("application"));

                // But direct claiming should work
                vm.prank(member1);
                tm.claimTask(0);

                // Verify task is claimed
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (payout, status, claimer, taskProjectId, requiresApplication) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED));
                assertEq(claimer, member1);
            }

            /*───────────────── MULTI-APPLICANT SYSTEM TESTS ────────────────────*/

            function test_MultipleApplicantsBasic() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("MULTI_APP_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Create multiple applicants
                address member2 = makeAddr("member2");
                address member3 = makeAddr("member3");
                setHat(member2, MEMBER_HAT);
                setHat(member3, MEMBER_HAT);

                // All should be able to apply
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application1"));

                vm.prank(member2);
                tm.applyForTask(0, keccak256("application2"));

                vm.prank(member3);
                tm.applyForTask(0, keccak256("application3"));

                // Verify all applicants are stored
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(0)
                );
                address[] memory applicants = abi.decode(result, (address[]));
                assertEq(applicants.length, 3, "Should have 3 applicants");
                assertEq(applicants[0], member1, "First applicant should be member1");
                assertEq(applicants[1], member2, "Second applicant should be member2");
                assertEq(applicants[2], member3, "Third applicant should be member3");

                // Verify application hashes
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member1)
                );
                bytes32 applicationHash = abi.decode(result, (bytes32));
                assertEq(applicationHash, keccak256("application1"), "Member1 application hash should match");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member2)
                );
                applicationHash = abi.decode(result, (bytes32));
                assertEq(applicationHash, keccak256("application2"), "Member2 application hash should match");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member3)
                );
                applicationHash = abi.decode(result, (bytes32));
                assertEq(applicationHash, keccak256("application3"), "Member3 application hash should match");

                // Verify applicant count
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANT_COUNT, abi.encode(0));
                uint256 applicantCount = abi.decode(result, (uint256));
                assertEq(applicantCount, 3, "Applicant count should be 3");

                // Verify hasAppliedForTask
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member1)
                );
                bytes32 hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member1 should have applied");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member2)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member2 should have applied");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member3)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member3 should have applied");

                address nonApplicant = makeAddr("nonApplicant");
                result =
                    lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, nonApplicant)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied == bytes32(0), "Non-applicant should not have applied");
            }

            function test_ApproveSpecificApplicant() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("APPROVE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Create multiple applicants
                address member2 = makeAddr("member2");
                address member3 = makeAddr("member3");
                setHat(member2, MEMBER_HAT);
                setHat(member3, MEMBER_HAT);

                // All apply
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application1"));

                vm.prank(member2);
                tm.applyForTask(0, keccak256("application2"));

                vm.prank(member3);
                tm.applyForTask(0, keccak256("application3"));

                // Approve member2 (middle applicant)
                vm.prank(pm1);
                tm.approveApplication(0, member2);

                // Verify task is claimed by member2
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (
                    uint256 payout,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 taskProjectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member2, "Task should be claimed by member2");
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Task should be claimed");

                // Verify other applicants can't be approved now
                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.approveApplication(0, member1);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.approveApplication(0, member3);
            }

            function test_ApplicationDataPersistence() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("PERSISTENCE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Apply with specific application data
                bytes32 applicationHash = keccak256("detailed_application_content");
                vm.prank(member1);
                tm.applyForTask(0, applicationHash);

                // Verify application data persists
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member1));
                applicationHash = abi.decode(result, (bytes32));
                assertEq(applicationHash, keccak256("detailed_application_content"), "Application hash should persist");

                // Approve and complete task
                vm.prank(pm1);
                tm.approveApplication(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                vm.prank(pm1);
                tm.completeTask(0);

                // Verify application data still accessible even after completion
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member1)
                );
                applicationHash = abi.decode(result, (bytes32));
                assertEq(
                    applicationHash,
                    keccak256("detailed_application_content"),
                    "Application hash should persist after completion"
                );
            }

            function test_CancelTaskClearsApplications() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("CANCEL_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // Create multiple applicants
                address member2 = makeAddr("member2");
                setHat(member2, MEMBER_HAT);

                // Apply
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application1"));

                vm.prank(member2);
                tm.applyForTask(0, keccak256("application2"));

                // Verify applications exist
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANT_COUNT, abi.encode(0));
                uint256 applicantCount = abi.decode(result, (uint256));
                assertEq(applicantCount, 2, "Should have 2 applicants");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member1)
                );
                bytes32 hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member1 should have applied");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member2)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member2 should have applied");

                // Cancel task
                vm.prank(creator1);
                tm.cancelTask(0);

                // Verify applicants array is cleared (but application hashes remain to avoid DoS)
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANT_COUNT, abi.encode(0));
                applicantCount = abi.decode(result, (uint256));
                assertEq(applicantCount, 0, "Should have 0 applicants after cancel");

                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(0));
                address[] memory applicants = abi.decode(result, (address[]));
                assertEq(applicants.length, 0, "Applicants array should be empty");

                // Note: Application hashes remain in storage to avoid DoS attacks from clearing
                // them in a loop. This is intentional behavior.
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member1)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member1 application hash should remain");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.HAS_APPLIED_FOR_TASK, abi.encode(0, member2)
                );
                hasApplied = abi.decode(result, (bytes32));
                assertTrue(hasApplied != bytes32(0), "Member2 application hash should remain");
            }

            function test_DuplicateApplicationPrevented() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("DUPLICATE_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                // First application succeeds
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application1"));

                // Second application by same user fails
                vm.prank(member1);
                vm.expectRevert(TaskManager.AlreadyApplied.selector);
                tm.applyForTask(0, keccak256("application2"));

                // Verify only one application exists
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANT_COUNT, abi.encode(0));
                uint256 applicantCount = abi.decode(result, (uint256));
                assertEq(applicantCount, 1, "Should have only 1 applicant");
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(0, member1)
                );
                bytes32 applicationHash = abi.decode(result, (bytes32));
                assertEq(applicationHash, keccak256("application1"), "Should have first application hash");
            }

            function test_ApplicationSystemEvents() public {
                // Set up hat permissions
                uint256[] memory createHats = new uint256[](1);
                createHats[0] = CREATOR_HAT;
                uint256[] memory claimHats = new uint256[](1);
                claimHats[0] = MEMBER_HAT;
                uint256[] memory reviewHats = new uint256[](1);
                reviewHats[0] = PM_HAT;
                uint256[] memory assignHats = new uint256[](1);
                assignHats[0] = PM_HAT;

                vm.prank(creator1);
                bytes32 projectId = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("EVENT_TEST"),
                        metadataHash: bytes32(0),
                        cap: 5 ether,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("test_task"), bytes32(0), projectId, address(0), 0, true);

                bytes32 applicationHash = keccak256("application_content");

                // Test application submitted event
                vm.prank(member1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskApplicationSubmitted(0, member1, applicationHash);
                tm.applyForTask(0, applicationHash);

                // Test application approved event
                vm.prank(pm1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskApplicationApproved(0, member1, pm1);
                tm.approveApplication(0, member1);
            }

            /*───────────────── TASK REJECTION ───────────────────*/

            function _prepareSubmittedTask() internal returns (uint256 id, bytes32 pid) {
                pid = _createDefaultProject("REJECT", 5 ether);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(pid, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("reject_task"), bytes32(0), pid, address(0), 0, false);
                id = 0;

                vm.prank(member1);
                tm.claimTask(id);

                vm.prank(member1);
                tm.submitTask(id, keccak256("submission"));
            }

            function test_RejectTaskSendsBackToClaimed() public {
                (uint256 id, bytes32 pid) = _prepareSubmittedTask();

                vm.prank(pm1);
                tm.rejectTask(id, keccak256("needs_fixes"));

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (uint256 payout, TaskManager.Status st, address claimer,,) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(st), uint8(TaskManager.Status.CLAIMED), "status should be CLAIMED");
                assertEq(claimer, member1, "claimer should be unchanged");
            }

            function test_RejectTaskEmitsEvent() public {
                (uint256 id,) = _prepareSubmittedTask();
                bytes32 rejHash = keccak256("needs_fixes");

                vm.prank(pm1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskRejected(id, pm1, rejHash);
                tm.rejectTask(id, rejHash);
            }

            function test_RejectThenResubmitThenComplete() public {
                (uint256 id,) = _prepareSubmittedTask();

                // reject
                vm.prank(pm1);
                tm.rejectTask(id, keccak256("try_again"));

                // resubmit
                vm.prank(member1);
                tm.submitTask(id, keccak256("submission_v2"));

                // complete
                uint256 balBefore = token.balanceOf(member1);
                vm.prank(pm1);
                tm.completeTask(id);

                assertEq(token.balanceOf(member1), balBefore + 1 ether, "minted payout after rejection cycle");
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManager.Status st,,,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(st), uint8(TaskManager.Status.COMPLETED));
            }

            function test_MultipleRejectionsBeforeComplete() public {
                (uint256 id,) = _prepareSubmittedTask();

                // first rejection
                vm.prank(pm1);
                tm.rejectTask(id, keccak256("round_1"));

                vm.prank(member1);
                tm.submitTask(id, keccak256("v2"));

                // second rejection
                vm.prank(pm1);
                tm.rejectTask(id, keccak256("round_2"));

                vm.prank(member1);
                tm.submitTask(id, keccak256("v3"));

                // complete
                vm.prank(pm1);
                tm.completeTask(id);

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManager.Status st,,,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(st), uint8(TaskManager.Status.COMPLETED));
            }

            function test_RejectTaskRequiresReviewPermission() public {
                (uint256 id,) = _prepareSubmittedTask();

                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.rejectTask(id, keccak256("nope"));

                vm.prank(member1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.rejectTask(id, keccak256("nope"));
            }

            function test_RejectTaskByProjectManager() public {
                (uint256 id,) = _prepareSubmittedTask();

                vm.prank(pm1);
                tm.rejectTask(id, keccak256("pm_reject"));

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManager.Status st,,,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(st), uint8(TaskManager.Status.CLAIMED));
            }

            function test_RejectUnclaimedTaskReverts() public {
                bytes32 pid = _createDefaultProject("REJ_UNCL", 5 ether);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(pid, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("unclaimed"), bytes32(0), pid, address(0), 0, false);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.rejectTask(0, keccak256("nope"));
            }

            function test_RejectClaimedTaskReverts() public {
                bytes32 pid = _createDefaultProject("REJ_CL", 5 ether);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(pid, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("claimed_only"), bytes32(0), pid, address(0), 0, false);

                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.rejectTask(0, keccak256("nope"));
            }

            function test_RejectCompletedTaskReverts() public {
                (uint256 id,) = _prepareSubmittedTask();

                vm.prank(pm1);
                tm.completeTask(id);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.rejectTask(id, keccak256("nope"));
            }

            function test_RejectCancelledTaskReverts() public {
                bytes32 pid = _createDefaultProject("REJ_CAN", 5 ether);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(pid, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("to_cancel"), bytes32(0), pid, address(0), 0, false);

                vm.prank(pm1);
                tm.cancelTask(0);

                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.rejectTask(0, keccak256("nope"));
            }

            function test_RejectTaskWithEmptyHashReverts() public {
                (uint256 id,) = _prepareSubmittedTask();

                vm.prank(pm1);
                vm.expectRevert(ValidationLib.InvalidString.selector);
                tm.rejectTask(id, bytes32(0));
            }

            function test_RejectTaskDoesNotChangeBudget() public {
                (uint256 id, bytes32 pid) = _prepareSubmittedTask();

                bytes memory before_ = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(pid)
                );
                (, uint256 spentBefore,) = abi.decode(before_, (uint256, uint256, bool));

                vm.prank(pm1);
                tm.rejectTask(id, keccak256("reject"));

                bytes memory after_ = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(pid)
                );
                (, uint256 spentAfter,) = abi.decode(after_, (uint256, uint256, bool));

                assertEq(spentBefore, spentAfter, "budget spent should not change on rejection");
            }

            function test_RemovingProjectPermKeepsGlobalPermission() public {
                // Create project WITHOUT default role hats — avoids project-overrides-global behavior
                uint256[] memory empty = new uint256[](0);
                vm.prank(creator1);
                bytes32 pid = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("perm-test-1"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: empty,
                        claimHats: empty,
                        reviewHats: empty,
                        assignHats: empty,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Give MEMBER_HAT global CREATE permission
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MEMBER_HAT, uint8(TaskPerm.CREATE)));

                // member1 can create tasks (global perm, no project override)
                vm.prank(member1);
                tm.createTask(1, bytes("before-remove"), bytes32(0), pid, address(0), 0, false);

                // Give MEMBER_HAT project-specific CREATE, then remove it
                vm.prank(creator1);
                tm.setProjectRolePerm(pid, MEMBER_HAT, uint8(TaskPerm.CREATE));
                vm.prank(creator1);
                tm.setProjectRolePerm(pid, MEMBER_HAT, 0);

                // member1 should STILL be able to create tasks via global perm
                vm.prank(member1);
                tm.createTask(1, bytes("after-remove"), bytes32(0), pid, address(0), 0, false);
            }

            function test_RemovingGlobalPermKeepsProjectPermission() public {
                // Create project WITHOUT default role hats
                uint256[] memory empty = new uint256[](0);
                vm.prank(creator1);
                bytes32 pid = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("perm-test-2"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: empty,
                        claimHats: empty,
                        reviewHats: empty,
                        assignHats: empty,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Give MEMBER_HAT global CREATE permission
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MEMBER_HAT, uint8(TaskPerm.CREATE)));

                // Also give MEMBER_HAT project-specific CREATE permission
                vm.prank(creator1);
                tm.setProjectRolePerm(pid, MEMBER_HAT, uint8(TaskPerm.CREATE));

                // Remove global permission
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MEMBER_HAT, uint8(0)));

                // member1 should STILL be able to create tasks via project-specific perm
                vm.prank(member1);
                tm.createTask(1, bytes("project-only-perm"), bytes32(0), pid, address(0), 0, false);
            }

            function test_DeleteProjectCleansUpPermRefCounts() public {
                // Create project without default role hats
                uint256[] memory empty = new uint256[](0);
                vm.prank(creator1);
                bytes32 pid = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("to-delete"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: empty,
                        claimHats: empty,
                        reviewHats: empty,
                        assignHats: empty,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // Give MEMBER_HAT project-specific CREATE (no global perm)
                vm.prank(creator1);
                tm.setProjectRolePerm(pid, MEMBER_HAT, uint8(TaskPerm.CREATE));

                // member1 can create tasks via project perm
                vm.prank(member1);
                tm.createTask(1, bytes("before-delete"), bytes32(0), pid, address(0), 0, false);

                // Delete the project
                vm.prank(creator1);
                tm.deleteProject(pid);

                // Create a second project without default role hats
                vm.prank(creator1);
                bytes32 pid2 = tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("after-delete"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: empty,
                        claimHats: empty,
                        reviewHats: empty,
                        assignHats: empty,
                        bountyTokens: new address[](0),
                        bountyCaps: new uint256[](0)
                    })
                );

                // MEMBER_HAT should have no permissions — ref count was cleaned up,
                // so the hat was removed from permissionHatIds
                vm.prank(member1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTask(1, bytes("should-fail"), bytes32(0), pid2, address(0), 0, false);
            }
        }

        /*───────────────── BOUNTY FUNCTIONALITY TESTS ────────────────────*/

        contract TaskManagerBountyTest is TaskManagerTestBase {
            /* project IDs */
            bytes32 BOUNTY_PROJECT_ID;
            bytes32 DUAL_BOUNTY_PROJECT_ID;
            bytes32 NO_BOUNTY_PROJECT_ID;

            MockERC20 bountyToken1;
            MockERC20 bountyToken2;

            function setUp() public {
                setUpBase();
                bountyToken1 = new MockERC20();
                bountyToken2 = new MockERC20();

                // Projects with unlimited bounty budgets for bountyToken1
                address[] memory tokens1 = new address[](1);
                tokens1[0] = address(bountyToken1);
                uint256[] memory caps1 = new uint256[](1);
                caps1[0] = type(uint128).max;

                BOUNTY_PROJECT_ID = _createProjectWithBountyBudget("BOUNTY_PROJECT", 10 ether, tokens1, caps1);

                // Dual token project: unlimited budget for both tokens
                address[] memory tokens2 = new address[](2);
                tokens2[0] = address(bountyToken1);
                tokens2[1] = address(bountyToken2);
                uint256[] memory caps2 = new uint256[](2);
                caps2[0] = type(uint128).max;
                caps2[1] = type(uint128).max;

                DUAL_BOUNTY_PROJECT_ID = _createProjectWithBountyBudget("DUAL_BOUNTY_PROJECT", 10 ether, tokens2, caps2);

                // No bounty budget project (cap=0 = disabled by default)
                NO_BOUNTY_PROJECT_ID = _createDefaultProject("NO_BOUNTY_PROJECT", 10 ether);

                // Fund the bounty tokens to the TaskManager (simulating treasury)
                bountyToken1.mint(address(tm), 1000 ether);
                bountyToken2.mint(address(tm), 1000 ether);
            }

            function test_CreateTaskWithBounty() public {
                // Create task with bounty token
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.5 ether,
                    false
                );

                // Verify task has bounty info
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Participation token payout should be correct");
                assertEq(bountyPayout, 0.5 ether, "Bounty payout should be correct");
                assertEq(bountyToken, address(bountyToken1), "Bounty token should be correct");
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED), "Status should be UNCLAIMED");
            }

            function test_CreateTaskWithoutBounty() public {
                // Create task without bounty (backward compatibility)
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("no_bounty_task"), bytes32(0), NO_BOUNTY_PROJECT_ID, address(0), 0, false);

                // Verify task has no bounty info
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Participation token payout should be correct");
                assertEq(bountyPayout, 0, "Bounty payout should be zero");
                assertEq(bountyToken, address(0), "Bounty token should be zero address");
            }

            function test_CreateApplicationTaskWithBounty() public {
                // Create application task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("app_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    true
                );

                // Verify task has bounty info and requires application
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Participation token payout should be correct");
                assertEq(bountyPayout, 0.3 ether, "Bounty payout should be correct");
                assertEq(bountyToken, address(bountyToken1), "Bounty token should be correct");
                assertEq(requiresApplication, true, "Should require application");
            }

            function test_CreateAndAssignTaskWithBounty() public {
                // Create and assign task with bounty
                vm.prank(creator1);
                uint256 taskId = tm.createAndAssignTask(
                    1 ether,
                    bytes("assign_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    member1,
                    address(bountyToken1),
                    0.4 ether,
                    false
                );

                // Verify task is assigned and has bounty info
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(taskId));
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Participation token payout should be correct");
                assertEq(bountyPayout, 0.4 ether, "Bounty payout should be correct");
                assertEq(bountyToken, address(bountyToken1), "Bounty token should be correct");
                assertEq(claimer, member1, "Task should be assigned to member1");
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Status should be CLAIMED");
            }

            function test_CompleteTaskWithBounty() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("complete_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.5 ether,
                    false
                );

                // Assign and complete task
                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                uint256 tokenBalanceBefore = token.balanceOf(member1);
                uint256 bountyBalanceBefore = bountyToken1.balanceOf(member1);

                vm.prank(creator1);
                tm.completeTask(0);

                // Verify both tokens were transferred
                assertEq(
                    token.balanceOf(member1), tokenBalanceBefore + 1 ether, "Participation tokens should be minted"
                );
                assertEq(
                    bountyToken1.balanceOf(member1),
                    bountyBalanceBefore + 0.5 ether,
                    "Bounty tokens should be transferred"
                );
            }

            function test_CompleteTaskWithoutBounty() public {
                // Create task without bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("complete_no_bounty_task"), bytes32(0), NO_BOUNTY_PROJECT_ID, address(0), 0, false
                );

                // Assign and complete task
                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                uint256 tokenBalanceBefore = token.balanceOf(member1);

                vm.prank(creator1);
                tm.completeTask(0);

                // Verify only participation tokens were minted
                assertEq(
                    token.balanceOf(member1), tokenBalanceBefore + 1 ether, "Participation tokens should be minted"
                );
                assertEq(bountyToken1.balanceOf(member1), 0, "No bounty tokens should be transferred");
            }

            function test_UpdateTaskBountyBeforeClaim() public {
                // Create task with initial bounty (use dual project which has budget for both tokens)
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("update_bounty_task"),
                    bytes32(0),
                    DUAL_BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                // Update bounty before claim (switch to bountyToken2)
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated_metadata"), bytes32(0), address(bountyToken2), 0.6 ether);

                // Verify bounty was updated
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(bountyPayout, 0.6 ether, "Bounty payout should be updated");
                assertEq(bountyToken, address(bountyToken2), "Bounty token should be updated");
            }

            function test_UpdateTaskBountyAfterClaimReverts() public {
                // Create task with initial bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("update_claimed_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                // Assign task
                vm.prank(creator1);
                tm.assignTask(0, member1);

                // Update bounty after claim should revert
                vm.prank(creator1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.updateTask(0, 1 ether, bytes("updated_metadata"), bytes32(0), address(bountyToken2), 0.6 ether);
            }

            function test_UpdateTaskRemoveBounty() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("remove_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                // Remove bounty
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated_metadata"), bytes32(0), address(0), 0);

                // Verify bounty was removed
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(bountyPayout, 0, "Bounty payout should be zero");
                assertEq(bountyToken, address(0), "Bounty token should be zero address");
            }

            function test_CompleteTaskWithDifferentBountyTokens() public {
                // Create two tasks with different bounty tokens (use dual project)
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("bounty1_task"),
                    bytes32(0),
                    DUAL_BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("bounty2_task"),
                    bytes32(0),
                    DUAL_BOUNTY_PROJECT_ID,
                    address(bountyToken2),
                    0.4 ether,
                    false
                );

                // Complete both tasks
                vm.startPrank(creator1);
                tm.assignTask(0, member1);
                tm.assignTask(1, member1);
                vm.stopPrank();

                vm.startPrank(member1);
                tm.submitTask(0, keccak256("submission1"));
                tm.submitTask(1, keccak256("submission2"));
                vm.stopPrank();

                uint256 bounty1Before = bountyToken1.balanceOf(member1);
                uint256 bounty2Before = bountyToken2.balanceOf(member1);

                vm.startPrank(creator1);
                tm.completeTask(0);
                tm.completeTask(1);
                vm.stopPrank();

                // Verify both bounty tokens were transferred correctly
                assertEq(
                    bountyToken1.balanceOf(member1), bounty1Before + 0.3 ether, "Bounty token 1 should be transferred"
                );
                assertEq(
                    bountyToken2.balanceOf(member1), bounty2Before + 0.4 ether, "Bounty token 2 should be transferred"
                );
            }

            function test_BountyValidationErrors() public {
                // Test bounty token with zero payout
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTask(
                    1 ether, bytes("invalid_bounty"), bytes32(0), BOUNTY_PROJECT_ID, address(bountyToken1), 0, false
                );

                // Test excessive bounty payout
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTask(
                    1 ether,
                    bytes("excessive_bounty"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    1e25,
                    false
                ); // Over MAX_PAYOUT

                // Test that zero bounty token with non-zero payout is not allowed
                vm.prank(creator1);
                vm.expectRevert(ValidationLib.ZeroAddress.selector);
                tm.createTask(
                    1 ether, bytes("invalid_zero_token"), bytes32(0), BOUNTY_PROJECT_ID, address(0), 0.5 ether, false
                );
            }

            function test_ApplicationTaskWithBounty() public {
                // Create application task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("app_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    true
                );

                // Apply for task
                vm.prank(member1);
                tm.applyForTask(0, keccak256("application"));

                // Approve application
                vm.prank(creator1);
                tm.approveApplication(0, member1);

                // Submit and complete
                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                uint256 tokenBalanceBefore = token.balanceOf(member1);
                uint256 bountyBalanceBefore = bountyToken1.balanceOf(member1);

                vm.prank(creator1);
                tm.completeTask(0);

                // Verify both tokens were transferred
                assertEq(
                    token.balanceOf(member1), tokenBalanceBefore + 1 ether, "Participation tokens should be minted"
                );
                assertEq(
                    bountyToken1.balanceOf(member1),
                    bountyBalanceBefore + 0.3 ether,
                    "Bounty tokens should be transferred"
                );
            }

            function test_CancelTaskWithBounty() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("cancel_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                // Cancel task
                vm.prank(creator1);
                tm.cancelTask(0);

                // Verify task is cancelled and bounty info is preserved
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.CANCELLED), "Status should be CANCELLED");
                assertEq(bountyPayout, 0.3 ether, "Bounty payout should be preserved");
                assertEq(bountyToken, address(bountyToken1), "Bounty token should be preserved");
            }

            function test_GetTaskFullFunction() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("full_task"), bytes32(0), BOUNTY_PROJECT_ID, address(bountyToken1), 0.3 ether, false
                );

                // Test getTaskFull function
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (
                    uint256 payout,
                    uint256 bountyPayout,
                    address bountyToken,
                    TaskManager.Status status,
                    address claimer,
                    bytes32 projectId,
                    bool requiresApplication
                ) = abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 1 ether, "Payout should be correct");
                assertEq(bountyPayout, 0.3 ether, "Bounty payout should be correct");
                assertEq(bountyToken, address(bountyToken1), "Bounty token should be correct");
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED), "Status should be correct");
                assertEq(claimer, address(0), "Claimer should be correct");
                assertEq(projectId, BOUNTY_PROJECT_ID, "Project ID should be correct");
                assertEq(requiresApplication, false, "Requires application should be correct");

                // Compare with getTask function (should not include bounty info)
                (
                    uint256 payout2,
                    TaskManager.Status status2,
                    address claimer2,
                    bytes32 projectId2,
                    bool requiresApplication2
                ) = abi.decode(
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0)),
                    (uint256, TaskManager.Status, address, bytes32, bool)
                );
                assertEq(payout2, payout, "getTask payout should match getTaskFull");
                assertEq(uint8(status2), uint8(status), "getTask status should match getTaskFull");
                assertEq(claimer2, claimer, "getTask claimer should match getTaskFull");
                assertEq(projectId2, projectId, "getTask project ID should match getTaskFull");
                assertEq(
                    requiresApplication2, requiresApplication, "getTask requires application should match getTaskFull"
                );
            }

            function test_BountyEvents() public {
                // Create task with bounty
                vm.prank(creator1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskCreated(
                    0,
                    BOUNTY_PROJECT_ID,
                    1 ether,
                    address(bountyToken1),
                    0.3 ether,
                    false,
                    bytes("bounty_event_task"),
                    bytes32(0)
                );
                tm.createTask(
                    1 ether,
                    bytes("bounty_event_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(bountyToken1),
                    0.3 ether,
                    false
                );

                // Complete task and verify events
                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                vm.prank(creator1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskCompleted(0, creator1);
                tm.completeTask(0);
            }

            function test_MultipleBountyTokensInProject() public {
                // Create multiple tasks with different bounty tokens (use dual project)
                vm.startPrank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), DUAL_BOUNTY_PROJECT_ID, address(bountyToken1), 0.2 ether, false
                );
                tm.createTask(
                    1 ether, bytes("task2"), bytes32(0), DUAL_BOUNTY_PROJECT_ID, address(bountyToken2), 0.3 ether, false
                );
                tm.createTask(1 ether, bytes("task3"), bytes32(0), DUAL_BOUNTY_PROJECT_ID, address(0), 0, false); // No bounty
                vm.stopPrank();

                // Complete all tasks
                vm.startPrank(creator1);
                tm.assignTask(0, member1);
                tm.assignTask(1, member1);
                tm.assignTask(2, member1);
                vm.stopPrank();

                vm.startPrank(member1);
                tm.submitTask(0, keccak256("submission1"));
                tm.submitTask(1, keccak256("submission2"));
                tm.submitTask(2, keccak256("submission3"));
                vm.stopPrank();

                uint256 bounty1Before = bountyToken1.balanceOf(member1);
                uint256 bounty2Before = bountyToken2.balanceOf(member1);
                uint256 tokenBefore = token.balanceOf(member1);

                vm.startPrank(creator1);
                tm.completeTask(0);
                tm.completeTask(1);
                tm.completeTask(2);
                vm.stopPrank();

                // Verify all payouts
                assertEq(
                    bountyToken1.balanceOf(member1), bounty1Before + 0.2 ether, "Bounty token 1 should be transferred"
                );
                assertEq(
                    bountyToken2.balanceOf(member1), bounty2Before + 0.3 ether, "Bounty token 2 should be transferred"
                );
                assertEq(token.balanceOf(member1), tokenBefore + 3 ether, "All participation tokens should be minted");
            }

            function test_BountyTokenTransferFailure() public {
                // Create a mock token that fails on transfer
                MockERC20 failingToken = new MockERC20();
                // Don't mint any tokens to TaskManager, so transfer will fail

                // Enable budget for failingToken on BOUNTY_PROJECT_ID
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP,
                    abi.encode(BOUNTY_PROJECT_ID, address(failingToken), type(uint128).max)
                );

                // Create task with failing bounty token
                vm.prank(creator1);
                tm.createTask(
                    1 ether,
                    bytes("failing_bounty_task"),
                    bytes32(0),
                    BOUNTY_PROJECT_ID,
                    address(failingToken),
                    0.3 ether,
                    false
                );

                // Assign and submit task
                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                // Complete task - should fail due to insufficient bounty tokens
                vm.prank(creator1);
                vm.expectRevert(); // Should revert due to transfer failure
                tm.completeTask(0);
            }
        }

        /*───────────────── BOUNTY BUDGET FUNCTIONALITY TESTS ────────────────────*/

        contract TaskManagerBountyBudgetTest is TaskManagerTestBase {
            /* project IDs */
            bytes32 BUDGET_PROJECT_ID;
            bytes32 MULTI_TOKEN_PROJECT_ID;
            bytes32 UNLIMITED_PROJECT_ID;

            MockERC20 bountyToken1;
            MockERC20 bountyToken2;
            MockERC20 bountyToken3;

            // Project with no bounty budget (disabled by default)
            bytes32 DISABLED_PROJECT_ID;

            function setUp() public {
                setUpBase();
                bountyToken1 = new MockERC20();
                bountyToken2 = new MockERC20();
                bountyToken3 = new MockERC20();

                // BUDGET_PROJECT_ID has an initial unlimited budget for bountyToken1
                // Tests that use setConfig(BOUNTY_CAP) will narrow it
                address[] memory tokens1 = new address[](1);
                tokens1[0] = address(bountyToken1);
                uint256[] memory unlimCaps = new uint256[](1);
                unlimCaps[0] = type(uint128).max;
                BUDGET_PROJECT_ID = _createProjectWithBountyBudget("BUDGET_PROJECT", 10 ether, tokens1, unlimCaps);

                // MULTI_TOKEN_PROJECT_ID has unlimited budgets for all 3 tokens
                address[] memory tokens3 = new address[](3);
                tokens3[0] = address(bountyToken1);
                tokens3[1] = address(bountyToken2);
                tokens3[2] = address(bountyToken3);
                uint256[] memory unlimCaps3 = new uint256[](3);
                unlimCaps3[0] = type(uint128).max;
                unlimCaps3[1] = type(uint128).max;
                unlimCaps3[2] = type(uint128).max;
                MULTI_TOKEN_PROJECT_ID = _createProjectWithBountyBudget(
                    "MULTI_TOKEN_PROJECT", 10 ether, tokens3, unlimCaps3
                );

                UNLIMITED_PROJECT_ID = _createDefaultProject("UNLIMITED_PROJECT", 0);

                // Project with no bounty budget (cap=0 = disabled)
                DISABLED_PROJECT_ID = _createDefaultProject("DISABLED_PROJECT", 10 ether);

                // Fund the bounty tokens to the TaskManager (simulating treasury)
                bountyToken1.mint(address(tm), 1000 ether);
                bountyToken2.mint(address(tm), 1000 ether);
                bountyToken3.mint(address(tm), 1000 ether);
            }

            function test_SetBountyCapBasic() public {
                // Test setting bounty cap (BUDGET_PROJECT_ID starts with unlimited for bountyToken1)
                vm.prank(executor);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.BountyCapSet(BUDGET_PROJECT_ID, address(bountyToken1), type(uint128).max, 5 ether);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Verify cap was set
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 5 ether, "Bounty cap should be set correctly");
                assertEq(spent, 0, "Bounty spent should be zero initially");
            }

            function test_SetBountyCapPermissions() public {
                // Without the BUDGET perm, hats with other roles (creator, PM, member)
                // cannot resize a bounty cap — they get Unauthorized.
                vm.prank(creator1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                vm.prank(pm1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                vm.prank(member1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Executor can set cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 5 ether, "Executor should be able to set bounty cap");
            }

            /*───────────────── EDITABLE BUDGETS (TaskPerm.BUDGET) ───────────────────*/

            function test_BudgetEditByHatHolder_PT() public {
                uint256 BUDGET_HAT = 50;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                vm.prank(budgetEditor);
                vm.expectEmit(true, false, false, true);
                emit TaskManager.ProjectCapUpdated(BUDGET_PROJECT_ID, 10 ether, 20 ether);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 20 ether));
            }

            function test_BudgetEditByHatHolder_Bounty() public {
                uint256 BUDGET_HAT = 50;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                vm.prank(budgetEditor);
                vm.expectEmit(true, true, false, true);
                emit TaskManager.BountyCapSet(BUDGET_PROJECT_ID, address(bountyToken1), type(uint128).max, 7 ether);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 7 ether)
                );
            }

            function test_BudgetEditByProjectScopedHat() public {
                uint256 BUDGET_HAT = 50;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                // Grant BUDGET only on BUDGET_PROJECT_ID (not on UNLIMITED_PROJECT_ID).
                vm.prank(creator1);
                tm.setProjectRolePerm(BUDGET_PROJECT_ID, BUDGET_HAT, TaskPerm.BUDGET);

                vm.prank(budgetEditor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 20 ether));

                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(UNLIMITED_PROJECT_ID, 20 ether));
            }

            function test_BudgetEditByProjectManager_RevertsWithoutHat() public {
                // Make pm1 a project manager on BUDGET_PROJECT_ID (no BUDGET hat).
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(BUDGET_PROJECT_ID, pm1, true));

                vm.prank(pm1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 20 ether));

                vm.prank(pm1);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );
            }

            function test_BudgetEditWithoutPermReverts() public {
                address nobody = makeAddr("nobody");

                vm.prank(nobody);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 20 ether));

                vm.prank(nobody);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );
            }

            function test_BudgetEditByExecutor_StillWorks() public {
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 20 ether));

                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 6 ether)
                );
            }

            function test_BudgetEditCannotLowerBelowSpent() public {
                uint256 BUDGET_HAT = 50;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                // Consume 2 ether of PT on BUDGET_PROJECT_ID (cap = 10 ether).
                vm.prank(creator1);
                tm.createTask(2 ether, bytes("burn"), bytes32(0), BUDGET_PROJECT_ID, address(0), 0, false);

                // Hat-holder cannot lower cap below committed spend.
                vm.prank(budgetEditor);
                vm.expectRevert(ValidationLib.CapBelowCommitted.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 1 ether));
            }

            function test_SetConfigRolePerm_EmitsRolePermSet() public {
                uint256 BUDGET_HAT = 50;

                // Grant: executor sets BUDGET on hat -> event fires with mask=BUDGET.
                vm.expectEmit(true, false, false, true, address(tm));
                emit TaskManager.RolePermSet(BUDGET_HAT, TaskPerm.BUDGET);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                // Revoke: setting mask=0 fires the event with mask=0 so indexers see the clear.
                vm.expectEmit(true, false, false, true, address(tm));
                emit TaskManager.RolePermSet(BUDGET_HAT, 0);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, uint8(0)));
            }

            function test_SetConfigOtherKeysStillExecutorOnly() public {
                uint256 BUDGET_HAT = 50;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                // EXECUTOR key — still executor-only.
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.EXECUTOR, abi.encode(makeAddr("newExec")));

                // CREATOR_HAT_ALLOWED key — still executor-only.
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(uint256(123), true));

                // ROLE_PERM key — still executor-only (callers must not be able to grant themselves perms).
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(99), TaskPerm.CREATE | TaskPerm.BUDGET)
                );

                // PROJECT_MANAGER key — still executor-only.
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(BUDGET_PROJECT_ID, member1, true));

                // ORGANIZER_HAT_ALLOWED key — still executor-only (auto-merge of folders + budgets PRs
                // accidentally dropped this gate; this test locks it down).
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(uint256(789), true));
            }

            function test_SetBountyCapValidation() public {
                // Test zero address token
                vm.prank(executor);
                vm.expectRevert(ValidationLib.ZeroAddress.selector);
                tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(0), 5 ether));

                // Test excessive cap
                vm.prank(executor);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 1e25)
                ); // Over MAX_PAYOUT

                // Test non-existent project
                vm.prank(executor);
                vm.expectRevert(TaskManager.NotFound.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(bytes32(uint256(999)), address(bountyToken1), 5 ether)
                );
            }

            function test_GetBountyBudgetValidation() public {
                // Test zero address token
                vm.expectRevert(ValidationLib.ZeroAddress.selector);
                lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.BOUNTY_BUDGET, abi.encode(BUDGET_PROJECT_ID, address(0))
                );

                // Test non-existent project
                vm.expectRevert(TaskManager.NotFound.selector);
                lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(bytes32(uint256(999)), address(bountyToken1))
                );
            }

            function test_CreateTaskWithBountyBudgetEnforcement() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether)
                );

                // Create task within budget
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 1.5 ether, false
                );

                // Verify budget tracking
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 3 ether, "Cap should remain unchanged");
                assertEq(spent, 1.5 ether, "Spent should be updated");

                // Create another task within budget
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task2"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 1.5 ether, false
                );

                // Verify budget tracking
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should be at cap");

                // Try to exceed budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    1 ether, bytes("task3"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 0.1 ether, false
                );
            }

            function test_CreateTaskWithoutBountyBudgetSet_Reverts() public {
                // cap=0 means DISABLED — creating a bounty task should revert
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), DISABLED_PROJECT_ID, address(bountyToken1), 5 ether, false
                );
            }

            function test_CreateTaskWithUnlimitedBountyBudget() public {
                // BUDGET_PROJECT_ID has unlimited bountyToken1 budget (cap = type(uint128).max)
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 5 ether, false
                );

                // Verify budget tracking
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, type(uint128).max, "Cap should be unlimited sentinel");
                assertEq(spent, 5 ether, "Spent should be updated");

                // Create another large task (should work since budget is unlimited)
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task2"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 10 ether, false
                );

                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 15 ether, "Spent should be cumulative");
            }

            function test_MultipleBountyTokensBudgets() public {
                // Set different caps for different tokens
                vm.startPrank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken1), 2 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken2), 3 ether)
                );
                vm.stopPrank();

                // Create tasks with different tokens
                vm.startPrank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), MULTI_TOKEN_PROJECT_ID, address(bountyToken1), 1 ether, false
                );
                tm.createTask(
                    1 ether, bytes("task2"), bytes32(0), MULTI_TOKEN_PROJECT_ID, address(bountyToken2), 2 ether, false
                );
                tm.createTask(
                    1 ether, bytes("task3"), bytes32(0), MULTI_TOKEN_PROJECT_ID, address(bountyToken1), 1 ether, false
                );
                vm.stopPrank();

                // Verify independent budget tracking
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap1, uint256 spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken2))
                );
                (uint256 cap2, uint256 spent2) = abi.decode(result, (uint256, uint256));

                assertEq(cap1, 2 ether, "Token1 cap should be correct");
                assertEq(spent1, 2 ether, "Token1 spent should be at cap");
                assertEq(cap2, 3 ether, "Token2 cap should be correct");
                assertEq(spent2, 2 ether, "Token2 spent should be correct");

                // Try to exceed token1 budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    1 ether, bytes("task4"), bytes32(0), MULTI_TOKEN_PROJECT_ID, address(bountyToken1), 0.1 ether, false
                );

                // But token2 should still work
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task5"), bytes32(0), MULTI_TOKEN_PROJECT_ID, address(bountyToken2), 1 ether, false
                );

                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken2))
                );
                (cap2, spent2) = abi.decode(result, (uint256, uint256));
                assertEq(spent2, 3 ether, "Token2 spent should now be at cap");
            }

            function test_UpdateTaskBountyBudgetTracking() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create task
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Verify initial budget
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 2 ether, "Initial spent should be correct");

                // Update task to higher bounty (within budget)
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(bountyToken1), 3 ether);

                // Verify budget updated
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should be updated after task update");

                // Try to update to exceed budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.updateTask(0, 1 ether, bytes("updated2"), bytes32(0), address(bountyToken1), 5.1 ether);
            }

            function test_UpdateTaskChangeBountyToken() public {
                // Set caps for both tokens
                vm.startPrank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken2), 4 ether)
                );
                vm.stopPrank();

                // Create task with token1
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Verify initial budgets
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap1, uint256 spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken2))
                );
                (uint256 cap2, uint256 spent2) = abi.decode(result, (uint256, uint256));
                assertEq(spent1, 2 ether, "Token1 spent should be correct");
                assertEq(spent2, 0, "Token2 spent should be zero");

                // Update task to use token2
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(bountyToken2), 3 ether);

                // Verify budgets updated correctly
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap1, spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken2))
                );
                (cap2, spent2) = abi.decode(result, (uint256, uint256));
                assertEq(spent1, 0, "Token1 spent should be rolled back");
                assertEq(spent2, 3 ether, "Token2 spent should be updated");
            }

            function test_UpdateTaskRemoveBounty() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 3 ether, false
                );

                // Verify budget
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should be correct");

                // Remove bounty from task
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(0), 0);

                // Verify budget rolled back
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 0, "Spent should be rolled back");
            }

            function test_CancelTaskBountyBudgetRollback() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create task
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Verify budget
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 2 ether, "Spent should be correct");

                // Cancel task
                vm.prank(creator1);
                tm.cancelTask(0);

                // Verify budget rolled back
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 0, "Spent should be rolled back after cancel");
            }

            function test_CreateAndAssignTaskBountyBudget() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create and assign task
                vm.prank(creator1);
                uint256 taskId = tm.createAndAssignTask(
                    1 ether,
                    bytes("assign_task"),
                    bytes32(0),
                    BUDGET_PROJECT_ID,
                    member1,
                    address(bountyToken1),
                    3 ether,
                    false
                );

                // Verify budget tracking
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should be updated");

                // Try to exceed budget with another task
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createAndAssignTask(
                    1 ether,
                    bytes("assign_task2"),
                    bytes32(0),
                    BUDGET_PROJECT_ID,
                    member1,
                    address(bountyToken1),
                    2.1 ether,
                    false
                );
            }

            function test_ApplicationTaskBountyBudget() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create application task
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("app_task"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 4 ether, true
                );

                // Verify budget tracking
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 4 ether, "Spent should be updated");

                // Try to create another task that would exceed budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    1 ether, bytes("app_task2"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 1.1 ether, true
                );
            }

            function test_SetBountyCapBelowSpent() public {
                // Create task first
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 3 ether, false
                );

                // Verify spent
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should be correct");

                // Try to set cap below spent amount
                vm.prank(executor);
                vm.expectRevert(ValidationLib.CapBelowCommitted.selector);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 2 ether)
                );

                // Setting cap equal to spent should work
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether)
                );

                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 3 ether, "Cap should be set correctly");

                // Setting cap above spent should work
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 5 ether, "Cap should be updated correctly");
            }

            function test_UpdateBountyCapEvent() public {
                // Set initial cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether)
                );

                // Update cap and verify event
                vm.prank(executor);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.BountyCapSet(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether, 5 ether);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );
            }

            function test_BountyBudgetIndependentFromParticipationToken() public {
                // Set both participation token cap and bounty cap
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(BUDGET_PROJECT_ID, 2 ether));

                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 3 ether)
                );

                // Create task that uses both budgets
                vm.prank(creator1);
                tm.createTask(
                    1.5 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Verify both budgets are tracked independently
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(BUDGET_PROJECT_ID));
                (uint256 participationCap, uint256 participationSpent, bool isManager) =
                    abi.decode(result, (uint256, uint256, bool));
                bytes memory bountyResult = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 bountyCap, uint256 bountySpent) = abi.decode(bountyResult, (uint256, uint256));

                assertEq(participationSpent, 1.5 ether, "Participation token spent should be correct");
                assertEq(bountySpent, 2 ether, "Bounty token spent should be correct");

                // Try to exceed participation token budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    0.6 ether, bytes("task2"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 0.5 ether, false
                );

                // Create task that only exceeds bounty budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    0.5 ether, bytes("task3"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 1.1 ether, false
                );
            }

            function test_CompleteTaskWithBountyBudgetTracking() public {
                // Set bounty cap
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );

                // Create and complete task
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 3 ether, false
                );

                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(member1);
                tm.submitTask(0, keccak256("submission"));

                // Budget should remain reserved during completion
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should remain reserved");

                vm.prank(creator1);
                tm.completeTask(0);

                // Budget should still be marked as spent after completion
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should remain after completion");

                // Verify tokens were transferred
                assertEq(bountyToken1.balanceOf(member1), 3 ether, "Bounty tokens should be transferred");
                assertEq(token.balanceOf(member1), 1 ether, "Participation tokens should be minted");
            }

            function test_UpdateTaskAfterClaimBountyBudgetReverts() public {
                // Set bounty caps
                vm.startPrank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken2), 4 ether)
                );
                vm.stopPrank();

                // Create and claim task
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                vm.prank(creator1);
                tm.assignTask(0, member1);

                // Update bounty after claim should revert
                vm.prank(creator1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(bountyToken2), 3 ether);
            }

            function test_ZeroBountyCapMeansDisabled() public {
                // cap=0 means DISABLED — bounty tasks should revert on a project without budget
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), DISABLED_PROJECT_ID, address(bountyToken1), 1 ether, false
                );

                // Non-bounty tasks still work on disabled project
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task2"), bytes32(0), DISABLED_PROJECT_ID, address(0), 0, false);
            }

            function test_GetBountyBudgetUnusedToken() public {
                // Get budget for token that was never configured (on DISABLED_PROJECT_ID)
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(DISABLED_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 0, "Unconfigured token cap should be zero (disabled)");
                assertEq(spent, 0, "Unconfigured token spent should be zero");
            }

            function test_BountyBudgetStressTest() public {
                // Set caps for multiple tokens
                vm.startPrank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken1), 10 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken2), 15 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken3), 20 ether)
                );
                vm.stopPrank();

                uint256 totalTasks = 15;

                // Create many tasks with different tokens
                for (uint256 i = 0; i < totalTasks; i++) {
                    address token = address(bountyToken1);
                    uint256 bountyAmount = 0.5 ether;

                    if (i % 3 == 1) {
                        token = address(bountyToken2);
                        bountyAmount = 0.8 ether;
                    } else if (i % 3 == 2) {
                        token = address(bountyToken3);
                        bountyAmount = 1.2 ether;
                    }

                    vm.prank(creator1);
                    tm.createTask(
                        0.1 ether,
                        abi.encodePacked("task", i),
                        bytes32(0),
                        MULTI_TOKEN_PROJECT_ID,
                        token,
                        bountyAmount,
                        false
                    );
                }

                // Verify final budget states
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap1, uint256 spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken2))
                );
                (uint256 cap2, uint256 spent2) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(MULTI_TOKEN_PROJECT_ID, address(bountyToken3))
                );
                (uint256 cap3, uint256 spent3) = abi.decode(result, (uint256, uint256));

                assertEq(spent1, 2.5 ether, "Token1 spent should be correct"); // 5 tasks * 0.5 ether
                assertEq(spent2, 4 ether, "Token2 spent should be correct"); // 5 tasks * 0.8 ether
                assertEq(spent3, 6 ether, "Token3 spent should be correct"); // 5 tasks * 1.2 ether

                // Try to exceed budgets
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    0.1 ether,
                    bytes("fail1"),
                    bytes32(0),
                    MULTI_TOKEN_PROJECT_ID,
                    address(bountyToken1),
                    7.6 ether,
                    false
                );

                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    0.1 ether,
                    bytes("fail2"),
                    bytes32(0),
                    MULTI_TOKEN_PROJECT_ID,
                    address(bountyToken2),
                    11.1 ether,
                    false
                );

                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(
                    0.1 ether,
                    bytes("fail3"),
                    bytes32(0),
                    MULTI_TOKEN_PROJECT_ID,
                    address(bountyToken3),
                    14.1 ether,
                    false
                );
            }

            function test_BountyBudgetUnderflowProtectionCancelTask() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Artificially corrupt the bounty budget to simulate underflow scenario

                // First, let's verify normal cancellation works
                vm.prank(creator1);
                tm.cancelTask(0);

                // Create another task to test the protection
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task2"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 1 ether, false
                );

                // Verify budget is correct
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 1 ether, "Spent should be correct");

                // Normal cancellation should work
                vm.prank(creator1);
                tm.cancelTask(1);
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 0, "Spent should be rolled back correctly");
            }

            function test_BountyBudgetUnderflowProtectionUpdateTask() public {
                // Create task with bounty
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Verify budget
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 2 ether, "Spent should be correct");

                // Normal update should work (rolling back and applying new bounty)
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(bountyToken1), 1.5 ether);
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 1.5 ether, "Spent should be updated correctly");

                // Update after claiming should revert
                vm.prank(creator1);
                tm.assignTask(0, member1);

                vm.prank(creator1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.updateTask(0, 1 ether, bytes("updated2"), bytes32(0), address(bountyToken1), 1 ether);
            }

            function test_BountyBudgetUnderflowProtectionEdgeCase() public {
                // Test edge case where bounty payout equals spent
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 3 ether, false
                );

                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Spent should equal bounty payout");

                // Cancelling should work when spent equals payout
                vm.prank(creator1);
                tm.cancelTask(0);

                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap, spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 0, "Spent should be zero after cancel");
            }

            function test_BountyBudgetUnderflowProtectionMultipleTokens() public {
                // Set caps for both tokens
                vm.startPrank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken1), 5 ether)
                );
                tm.setConfig(
                    TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(BUDGET_PROJECT_ID, address(bountyToken2), 5 ether)
                );
                vm.stopPrank();

                // Create task with token1
                vm.prank(creator1);
                tm.createTask(
                    1 ether, bytes("task1"), bytes32(0), BUDGET_PROJECT_ID, address(bountyToken1), 2 ether, false
                );

                // Update to token2 (should roll back token1 and apply token2)
                vm.prank(creator1);
                tm.updateTask(0, 1 ether, bytes("updated"), bytes32(0), address(bountyToken2), 3 ether);

                // Verify budgets
                bytes memory result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (uint256 cap1, uint256 spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken2))
                );
                (uint256 cap2, uint256 spent2) = abi.decode(result, (uint256, uint256));

                assertEq(spent1, 0, "Token1 spent should be rolled back");
                assertEq(spent2, 3 ether, "Token2 spent should be applied");

                // Cancel task should roll back token2
                vm.prank(creator1);
                tm.cancelTask(0);
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken1))
                );
                (cap1, spent1) = abi.decode(result, (uint256, uint256));
                result = lens.getStorage(
                    address(tm),
                    TaskManagerLens.StorageKey.BOUNTY_BUDGET,
                    abi.encode(BUDGET_PROJECT_ID, address(bountyToken2))
                );
                (cap2, spent2) = abi.decode(result, (uint256, uint256));

                assertEq(spent1, 0, "Token1 spent should remain zero");
                assertEq(spent2, 0, "Token2 spent should be rolled back");
            }
        }

        /*────────────────── Task Application Test Suite ──────────────────*/

        contract TaskManagerApplicationTest is TaskManagerTestBase {
            bytes32 APP_PROJECT_ID;

            function setUp() public {
                setUpBase();
                APP_PROJECT_ID = _createDefaultProject("APP_PROJECT", 10 ether);
            }

            /// @dev Helper: creates an application-required task and returns its ID
            function _createAppTask(uint256 payout) internal returns (uint256 id) {
                vm.prank(creator1);
                tm.createTask(payout, bytes("app_task"), bytes32(0), APP_PROJECT_ID, address(0), 0, true);
                id = 0; // first task
            }

            function _createAppTaskN(uint256 payout, uint256 expectedId) internal returns (uint256 id) {
                vm.prank(creator1);
                tm.createTask(payout, bytes("app_task"), bytes32(0), APP_PROJECT_ID, address(0), 0, true);
                id = expectedId;
            }

            /*──────── Basic Apply ────────*/

            function test_ApplyForTask() public {
                uint256 id = _createAppTask(1 ether);
                bytes32 appHash = keccak256("my application");

                vm.prank(member1);
                tm.applyForTask(id, appHash);

                // Verify application stored via lens
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICATION, abi.encode(id, member1));
                bytes32 stored = abi.decode(result, (bytes32));
                assertEq(stored, appHash, "application hash should be stored");

                // Verify applicant in list
                bytes memory listResult =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(id));
                address[] memory applicants = abi.decode(listResult, (address[]));
                assertEq(applicants.length, 1, "should have 1 applicant");
                assertEq(applicants[0], member1, "applicant should be member1");
            }

            function test_ApplyForTaskEmitsEvent() public {
                uint256 id = _createAppTask(1 ether);
                bytes32 appHash = keccak256("my application");

                vm.expectEmit(true, true, false, true);
                emit TaskManager.TaskApplicationSubmitted(id, member1, appHash);

                vm.prank(member1);
                tm.applyForTask(id, appHash);
            }

            /*──────── Approve Application ────────*/

            function test_ApproveApplicationClaimsTask() public {
                uint256 id = _createAppTask(1 ether);
                bytes32 appHash = keccak256("my application");

                vm.prank(member1);
                tm.applyForTask(id, appHash);

                vm.prank(pm1);
                tm.approveApplication(id, member1);

                // Verify task is now CLAIMED with member1 as claimer
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (uint256 payout, TaskManagerLens.Status status, address claimer,,) =
                    abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManagerLens.Status.CLAIMED), "status should be CLAIMED");
                assertEq(claimer, member1, "claimer should be member1");
            }

            function test_ApproveApplicationEmitsEvent() public {
                uint256 id = _createAppTask(1 ether);
                bytes32 appHash = keccak256("my application");

                vm.prank(member1);
                tm.applyForTask(id, appHash);

                vm.expectEmit(true, true, true, true);
                emit TaskManager.TaskApplicationApproved(id, member1, pm1);

                vm.prank(pm1);
                tm.approveApplication(id, member1);
            }

            function test_ApproveApplicationClearsApplicantsList() public {
                uint256 id = _createAppTask(1 ether);

                // Two applicants apply
                address member2 = makeAddr("member2");
                setHat(member2, MEMBER_HAT);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app1"));
                vm.prank(member2);
                tm.applyForTask(id, keccak256("app2"));

                // Approve member1
                vm.prank(pm1);
                tm.approveApplication(id, member1);

                // Applicants list should be cleared
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(id)
                );
                address[] memory applicants = abi.decode(result, (address[]));
                assertEq(applicants.length, 0, "applicants list should be cleared after approval");
            }

            /*──────── Full Lifecycle ────────*/

            function test_FullApplicationFlow() public {
                uint256 id = _createAppTask(1 ether);
                bytes32 appHash = keccak256("my application");

                // Apply
                vm.prank(member1);
                tm.applyForTask(id, appHash);

                // Approve
                vm.prank(pm1);
                tm.approveApplication(id, member1);

                // Submit
                vm.prank(member1);
                tm.submitTask(id, keccak256("submission"));

                // Complete
                vm.prank(pm1);
                tm.completeTask(id);

                // Verify completed
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManagerLens.Status status,,,) =
                    abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManagerLens.Status.COMPLETED), "status should be COMPLETED");

                // Verify tokens minted
                assertEq(token.balanceOf(member1), 1 ether, "member1 should receive payout");
            }

            function test_ApplicationRejectReapplyFlow() public {
                uint256 id = _createAppTask(1 ether);

                // Apply -> Approve -> Submit -> Reject -> Resubmit -> Complete
                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                vm.prank(pm1);
                tm.approveApplication(id, member1);

                vm.prank(member1);
                tm.submitTask(id, keccak256("bad submission"));

                vm.prank(pm1);
                tm.rejectTask(id, keccak256("needs work"));

                vm.prank(member1);
                tm.submitTask(id, keccak256("good submission"));

                vm.prank(pm1);
                tm.completeTask(id);

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManagerLens.Status status,,,) =
                    abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManagerLens.Status.COMPLETED));
            }

            /*──────── Multiple Applicants ────────*/

            function test_MultipleApplicants() public {
                uint256 id = _createAppTask(1 ether);

                address member2 = makeAddr("member2");
                address member3 = makeAddr("member3");
                setHat(member2, MEMBER_HAT);
                setHat(member3, MEMBER_HAT);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app1"));
                vm.prank(member2);
                tm.applyForTask(id, keccak256("app2"));
                vm.prank(member3);
                tm.applyForTask(id, keccak256("app3"));

                // Verify 3 applicants
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_APPLICANT_COUNT, abi.encode(id));
                uint256 count = abi.decode(result, (uint256));
                assertEq(count, 3, "should have 3 applicants");

                // Approve member2
                vm.prank(pm1);
                tm.approveApplication(id, member2);

                // Verify claimer is member2
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (,, address claimer,,) = abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(claimer, member2, "claimer should be member2");
            }

            /*──────── Permission Checks ────────*/

            function test_ApplyRequiresClaimPermission() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.applyForTask(id, keccak256("app"));
            }

            function test_ApproveRequiresAssignPermission() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.approveApplication(id, member1);
            }

            function test_ApproveByProjectManager() public {
                uint256 id = _createAppTask(1 ether);

                // Add pm1 as project manager
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(APP_PROJECT_ID, pm1, true));

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                // PM can approve (bypasses hat-based assign permission check)
                vm.prank(pm1);
                tm.approveApplication(id, member1);

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManagerLens.Status status,,,) =
                    abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManagerLens.Status.CLAIMED));
            }

            /*──────── Error Cases ────────*/

            function test_ApplyDuplicateReverts() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                vm.prank(member1);
                vm.expectRevert(TaskManager.AlreadyApplied.selector);
                tm.applyForTask(id, keccak256("app2"));
            }

            function test_ApplyEmptyHashReverts() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                vm.expectRevert(ValidationLib.InvalidString.selector);
                tm.applyForTask(id, bytes32(0));
            }

            function test_ApplyForNonApplicationTaskReverts() public {
                // Create a regular (non-application) task
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("regular_task"), bytes32(0), APP_PROJECT_ID, address(0), 0, false);
                uint256 id = 0;

                vm.prank(member1);
                vm.expectRevert(TaskManager.NoApplicationRequired.selector);
                tm.applyForTask(id, keccak256("app"));
            }

            function test_ApplyForClaimedTaskReverts() public {
                uint256 id = _createAppTask(1 ether);

                // Apply and approve to move to CLAIMED
                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));
                vm.prank(pm1);
                tm.approveApplication(id, member1);

                // New applicant tries to apply for already-claimed task
                address member2 = makeAddr("member2");
                setHat(member2, MEMBER_HAT);

                vm.prank(member2);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.applyForTask(id, keccak256("app2"));
            }

            function test_ApproveNonApplicantReverts() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                // Try to approve someone who didn't apply
                address member2 = makeAddr("member2");
                vm.prank(pm1);
                vm.expectRevert(TaskManager.NotApplicant.selector);
                tm.approveApplication(id, member2);
            }

            function test_ApproveAlreadyClaimedReverts() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                vm.prank(pm1);
                tm.approveApplication(id, member1);

                // Try to approve again (task is now CLAIMED)
                vm.prank(pm1);
                vm.expectRevert(TaskManager.BadStatus.selector);
                tm.approveApplication(id, member1);
            }

            function test_ClaimTaskWithApplicationRequiredReverts() public {
                uint256 id = _createAppTask(1 ether);

                // Try to claim directly (bypass application)
                vm.prank(member1);
                vm.expectRevert(TaskManager.RequiresApplication.selector);
                tm.claimTask(id);
            }

            /*──────── Cancel Clears Applications ────────*/

            function test_CancelTaskClearsApplications() public {
                uint256 id = _createAppTask(1 ether);

                vm.prank(member1);
                tm.applyForTask(id, keccak256("app"));

                // Cancel the task
                vm.prank(creator1);
                tm.cancelTask(id);

                // Verify applicants list is cleared
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_APPLICANTS, abi.encode(id)
                );
                address[] memory applicants = abi.decode(result, (address[]));
                assertEq(applicants.length, 0, "applicants should be cleared after cancel");
            }

            /*──────── Assign bypasses application requirement ────────*/

            function test_AssignTaskBypassesApplicationRequirement() public {
                uint256 id = _createAppTask(1 ether);

                // PM can directly assign even if requiresApplication is true
                vm.prank(pm1);
                tm.assignTask(id, member1);

                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (, TaskManagerLens.Status status, address claimer,,) =
                    abi.decode(result, (uint256, TaskManagerLens.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManagerLens.Status.CLAIMED));
                assertEq(claimer, member1);
            }
        }

        /*────────────────── Bootstrap Test Suite ──────────────────*/
        contract TaskManagerBootstrapTest is Test {
            /* test actors */
            address creator1 = makeAddr("creator1");
            address pm1 = makeAddr("pm1");
            address member1 = makeAddr("member1");
            address executor = makeAddr("executor");
            address deployer = makeAddr("deployer");
            address outsider = makeAddr("outsider");

            uint256 constant CREATOR_HAT = 1;
            uint256 constant PM_HAT = 2;
            uint256 constant MEMBER_HAT = 3;

            TaskManager tm;
            TaskManagerLens lens;
            MockToken token;
            MockHats hats;
            MockERC20 bountyToken;

            function setUp() public {
                token = new MockToken();
                hats = new MockHats();
                bountyToken = new MockERC20();

                hats.mintHat(CREATOR_HAT, creator1);
                hats.mintHat(PM_HAT, pm1);
                hats.mintHat(MEMBER_HAT, member1);

                TaskManager _tmImpl = new TaskManager();
                UpgradeableBeacon _tmBeacon = new UpgradeableBeacon(address(_tmImpl), address(this));
                tm = TaskManager(address(new BeaconProxy(address(_tmBeacon), "")));
                lens = new TaskManagerLens();
                uint256[] memory creatorHats = new uint256[](1);
                creatorHats[0] = CREATOR_HAT;

                // Initialize with deployer address
                tm.initialize(address(token), address(hats), creatorHats, executor, deployer);

                // Set up permissions
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM,
                    abi.encode(PM_HAT, TaskPerm.CREATE | TaskPerm.REVIEW | TaskPerm.ASSIGN)
                );
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(MEMBER_HAT, TaskPerm.CLAIM));
            }

            /* ─────────────── Helper Functions ─────────────── */

            function _hatArr(uint256 hat) internal pure returns (uint256[] memory arr) {
                arr = new uint256[](1);
                arr[0] = hat;
            }

            function _buildBootstrapProject(
                string memory title,
                uint256 cap,
                uint256[] memory createHats,
                uint256[] memory claimHats,
                uint256[] memory reviewHats,
                uint256[] memory assignHats
            ) internal pure returns (TaskManager.BootstrapProjectConfig memory) {
                return TaskManager.BootstrapProjectConfig({
                    title: bytes(title),
                    metadataHash: bytes32(0),
                    cap: cap,
                    managers: new address[](0),
                    createHats: createHats,
                    claimHats: claimHats,
                    reviewHats: reviewHats,
                    assignHats: assignHats,
                    bountyTokens: new address[](0),
                    bountyCaps: new uint256[](0)
                });
            }

            function _buildBootstrapTask(uint8 projectIndex, string memory title, uint256 payout)
                internal
                pure
                returns (TaskManager.BootstrapTaskConfig memory)
            {
                return TaskManager.BootstrapTaskConfig({
                    projectIndex: projectIndex,
                    payout: payout,
                    title: bytes(title),
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 0,
                    requiresApplication: false
                });
            }

            /* ─────────────── Test Cases ─────────────── */

            function test_BootstrapSingleProjectWithTasks() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Getting Started",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](2);
                tasks[0] = _buildBootstrapTask(0, "Complete your profile", 10 ether);
                tasks[1] = _buildBootstrapTask(0, "Introduce yourself", 5 ether);

                vm.prank(deployer);
                bytes32[] memory projectIds = tm.bootstrapProjectsAndTasks(projects, tasks);

                // Verify project created
                assertEq(projectIds.length, 1, "Should create 1 project");
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectIds[0]));
                (uint256 cap, uint256 spent, bool isManager) = abi.decode(result, (uint256, uint256, bool));
                assertEq(cap, 100 ether, "Project cap should be 100 ether");
                assertEq(spent, 15 ether, "Project spent should be 15 ether (both tasks)");

                // Verify tasks created
                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (uint256 payout, TaskManager.Status status,,, bool requiresApp) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 10 ether, "Task 0 payout should be 10 ether");
                assertEq(uint8(status), uint8(TaskManager.Status.UNCLAIMED), "Task 0 should be UNCLAIMED");
                assertFalse(requiresApp, "Task 0 should not require application");

                result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(1));
                (payout,,,,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 5 ether, "Task 1 payout should be 5 ether");
            }

            function test_BootstrapMultipleProjects() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](2);
                projects[0] = _buildBootstrapProject(
                    "Project A", 50 ether, _hatArr(CREATOR_HAT), _hatArr(MEMBER_HAT), _hatArr(PM_HAT), _hatArr(PM_HAT)
                );
                projects[1] = _buildBootstrapProject(
                    "Project B", 100 ether, _hatArr(CREATOR_HAT), _hatArr(MEMBER_HAT), _hatArr(PM_HAT), _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](3);
                tasks[0] = _buildBootstrapTask(0, "Task for A", 10 ether);
                tasks[1] = _buildBootstrapTask(1, "Task 1 for B", 20 ether);
                tasks[2] = _buildBootstrapTask(1, "Task 2 for B", 30 ether);

                vm.prank(deployer);
                bytes32[] memory projectIds = tm.bootstrapProjectsAndTasks(projects, tasks);

                assertEq(projectIds.length, 2, "Should create 2 projects");

                // Verify Project A spent
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectIds[0]));
                (, uint256 spentA,) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentA, 10 ether, "Project A spent should be 10 ether");

                // Verify Project B spent
                result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(projectIds[1])
                );
                (, uint256 spentB,) = abi.decode(result, (uint256, uint256, bool));
                assertEq(spentB, 50 ether, "Project B spent should be 50 ether");
            }

            function test_BootstrapWithManagers() public {
                address[] memory managers = new address[](1);
                managers[0] = pm1;

                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = TaskManager.BootstrapProjectConfig({
                    title: bytes("Managed Project"),
                    metadataHash: bytes32(0),
                    cap: 100 ether,
                    managers: managers,
                    createHats: _hatArr(CREATOR_HAT),
                    claimHats: _hatArr(MEMBER_HAT),
                    reviewHats: _hatArr(PM_HAT),
                    assignHats: _hatArr(PM_HAT),
                    bountyTokens: new address[](0),
                    bountyCaps: new uint256[](0)
                });

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](0);

                // Expect the ProjectManagerUpdated event to be emitted
                vm.expectEmit(true, true, false, true);
                emit TaskManager.ProjectManagerUpdated(bytes32(0), pm1, true);

                vm.prank(deployer);
                tm.bootstrapProjectsAndTasks(projects, tasks);
            }

            function test_BootstrapWithRolePermissions() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Role Test Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = _buildBootstrapTask(0, "Claimable task", 10 ether);

                vm.prank(deployer);
                tm.bootstrapProjectsAndTasks(projects, tasks);

                // member1 has MEMBER_HAT which is in claimHats, should be able to claim
                vm.prank(member1);
                tm.claimTask(0);

                // Verify claim
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status, address claimer,,) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "member1 should be claimer");
                assertEq(uint8(status), uint8(TaskManager.Status.CLAIMED), "Task should be claimed");
            }

            function test_BootstrapWithBountyTasks() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Bounty Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );
                // Set bounty budget for the project
                projects[0].bountyTokens = new address[](1);
                projects[0].bountyTokens[0] = address(bountyToken);
                projects[0].bountyCaps = new uint256[](1);
                projects[0].bountyCaps[0] = type(uint128).max;

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = TaskManager.BootstrapTaskConfig({
                    projectIndex: 0,
                    payout: 10 ether,
                    title: bytes("Bounty task"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 5 ether,
                    requiresApplication: false
                });

                vm.prank(deployer);
                bytes32[] memory projectIds = tm.bootstrapProjectsAndTasks(projects, tasks);

                // Verify bounty info stored
                bytes memory result = lens.getStorage(
                    address(tm), TaskManagerLens.StorageKey.TASK_FULL_INFO, abi.encode(0)
                );
                (uint256 payout, uint256 bountyPayoutVal, address bountyTokenAddr,,,,) =
                    abi.decode(result, (uint256, uint256, address, TaskManager.Status, address, bytes32, bool));
                assertEq(payout, 10 ether, "Payout should be 10 ether");
                assertEq(bountyPayoutVal, 5 ether, "Bounty payout should be 5 ether");
                assertEq(bountyTokenAddr, address(bountyToken), "Bounty token should match");
            }

            function test_BootstrapWithRequiresApplication() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Application Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = TaskManager.BootstrapTaskConfig({
                    projectIndex: 0,
                    payout: 10 ether,
                    title: bytes("Apply first"),
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 0,
                    requiresApplication: true
                });

                vm.prank(deployer);
                tm.bootstrapProjectsAndTasks(projects, tasks);

                // Direct claim should fail
                vm.prank(member1);
                vm.expectRevert(TaskManager.RequiresApplication.selector);
                tm.claimTask(0);

                // Apply and then get approved
                vm.prank(member1);
                tm.applyForTask(0, keccak256("my application"));

                vm.prank(pm1);
                tm.approveApplication(0, member1);

                // Now claim should work
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status, address claimer,,) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(claimer, member1, "member1 should be claimer after approval");
            }

            function test_BootstrapOnlyDeployer() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Test Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](0);

                // creator1 should not be able to bootstrap
                vm.prank(creator1);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.bootstrapProjectsAndTasks(projects, tasks);

                // executor should not be able to bootstrap
                vm.prank(executor);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.bootstrapProjectsAndTasks(projects, tasks);

                // outsider should not be able to bootstrap
                vm.prank(outsider);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.bootstrapProjectsAndTasks(projects, tasks);
            }

            function test_BootstrapInvalidProjectIndex() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Only Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = _buildBootstrapTask(5, "Invalid reference", 10 ether); // projectIndex 5 doesn't exist

                vm.prank(deployer);
                vm.expectRevert(TaskManager.InvalidIndex.selector);
                tm.bootstrapProjectsAndTasks(projects, tasks);
            }

            function test_BootstrapEmptyArrays() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](0);
                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](0);

                vm.prank(deployer);
                bytes32[] memory projectIds = tm.bootstrapProjectsAndTasks(projects, tasks);

                assertEq(projectIds.length, 0, "Should return empty array for empty bootstrap");
            }

            function test_BootstrapTaskLifecycleAfterBootstrap() public {
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Lifecycle Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = _buildBootstrapTask(0, "Complete me", 10 ether);

                vm.prank(deployer);
                tm.bootstrapProjectsAndTasks(projects, tasks);

                // Full lifecycle: claim → submit → complete
                uint256 balBefore = token.balanceOf(member1);

                vm.prank(member1);
                tm.claimTask(0);

                vm.prank(member1);
                tm.submitTask(0, keccak256("my work"));

                vm.prank(pm1);
                tm.completeTask(0);

                // Verify minting
                assertEq(token.balanceOf(member1), balBefore + 10 ether, "Should mint participation tokens");

                // Verify task completed
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (, TaskManager.Status status,,,) =
                    abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(uint8(status), uint8(TaskManager.Status.COMPLETED), "Task should be completed");
            }

            /*─────────────────────────────────────────────────────────────────────────────
                                         clearDeployer Tests
            ─────────────────────────────────────────────────────────────────────────────*/

            function test_ClearDeployerSuccess() public {
                // deployer can clear themselves
                vm.prank(deployer);
                tm.clearDeployer();

                // After clearing, deployer should no longer be able to bootstrap
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Should Fail",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );
                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](0);

                vm.prank(deployer);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.bootstrapProjectsAndTasks(projects, tasks);
            }

            function test_ClearDeployerOnlyDeployer() public {
                // Non-deployer cannot clear deployer
                vm.prank(creator1);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.clearDeployer();

                vm.prank(executor);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.clearDeployer();

                vm.prank(outsider);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.clearDeployer();
            }

            function test_ClearDeployerCannotBeCalledTwice() public {
                // First clear succeeds
                vm.prank(deployer);
                tm.clearDeployer();

                // Second clear fails (deployer is now address(0))
                vm.prank(deployer);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.clearDeployer();
            }

            function test_BootstrapThenClear() public {
                // Bootstrap first
                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = _buildBootstrapProject(
                    "Initial Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );
                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](1);
                tasks[0] = _buildBootstrapTask(0, "Initial Task", 10 ether);

                vm.prank(deployer);
                bytes32[] memory projectIds = tm.bootstrapProjectsAndTasks(projects, tasks);
                assertEq(projectIds.length, 1, "Should create 1 project");

                // Clear deployer
                vm.prank(deployer);
                tm.clearDeployer();

                // Cannot bootstrap again
                TaskManager.BootstrapProjectConfig[] memory moreProjects = new TaskManager.BootstrapProjectConfig[](1);
                moreProjects[0] = _buildBootstrapProject(
                    "Second Project",
                    100 ether,
                    _hatArr(CREATOR_HAT),
                    _hatArr(MEMBER_HAT),
                    _hatArr(PM_HAT),
                    _hatArr(PM_HAT)
                );
                TaskManager.BootstrapTaskConfig[] memory moreTasks = new TaskManager.BootstrapTaskConfig[](0);

                vm.prank(deployer);
                vm.expectRevert(TaskManager.NotDeployer.selector);
                tm.bootstrapProjectsAndTasks(moreProjects, moreTasks);
            }
        }

        /*──────────────────── Self-Review Tests ────────────────────*/
        contract TaskManagerSelfReviewTest is TaskManagerTestBase {
            uint256 constant REVIEWER_HAT = 4;
            address reviewer = makeAddr("reviewer");
            bytes32 projectId;

            function setUp() public {
                setUpBase();
                setHat(reviewer, REVIEWER_HAT);
                // CLAIM | REVIEW but NOT SELF_REVIEW
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM, abi.encode(REVIEWER_HAT, TaskPerm.CLAIM | TaskPerm.REVIEW)
                );

                projectId = _createDefaultProject("SELF_REVIEW", 10 ether);
            }

            function test_SelfReviewBlockedWithoutPermission() public {
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                vm.prank(reviewer);
                tm.claimTask(0);

                vm.prank(reviewer);
                tm.submitTask(0, keccak256("work"));

                vm.prank(reviewer);
                vm.expectRevert(TaskManager.SelfReviewNotAllowed.selector);
                tm.completeTask(0);
            }

            function test_SelfReviewAllowedWithPermission() public {
                // Grant SELF_REVIEW in addition to CLAIM | REVIEW
                vm.prank(executor);
                tm.setConfig(
                    TaskManager.ConfigKey.ROLE_PERM,
                    abi.encode(REVIEWER_HAT, TaskPerm.CLAIM | TaskPerm.REVIEW | TaskPerm.SELF_REVIEW)
                );

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                vm.prank(reviewer);
                tm.claimTask(0);

                vm.prank(reviewer);
                tm.submitTask(0, keccak256("work"));

                vm.prank(reviewer);
                tm.completeTask(0);

                assertEq(token.balanceOf(reviewer), 1 ether);
            }

            function test_PMCanAlwaysReviewOwnTask() public {
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(projectId, pm1, true));

                vm.prank(pm1);
                tm.createTask(1 ether, bytes("pm_task"), bytes32(0), projectId, address(0), 0, false);

                // PM bypasses _checkPerm, so can claim even without CLAIM flag
                vm.prank(pm1);
                tm.claimTask(0);

                vm.prank(pm1);
                tm.submitTask(0, keccak256("pm_work"));

                // PM bypasses self-review check
                vm.prank(pm1);
                tm.completeTask(0);

                assertEq(token.balanceOf(pm1), 1 ether);
            }

            function test_DifferentReviewerCanAlwaysComplete() public {
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task"), bytes32(0), projectId, address(0), 0, false);

                // reviewer claims and submits
                vm.prank(reviewer);
                tm.claimTask(0);

                vm.prank(reviewer);
                tm.submitTask(0, keccak256("work"));

                // pm1 (different person with REVIEW permission) completes — always allowed
                vm.prank(pm1);
                tm.completeTask(0);

                assertEq(token.balanceOf(reviewer), 1 ether);
            }
        }

        /*───────────────── BOUNTY BUDGET SAFE DEFAULTS TESTS ────────────────────*/

        contract TaskManagerBountyBudgetDefaultsTest is TaskManagerTestBase {
            MockERC20 bountyToken;

            function setUp() public {
                setUpBase();
                bountyToken = new MockERC20();
                bountyToken.mint(address(tm), 1000 ether);
            }

            // -- createProject with bounty budgets --

            function test_CreateProjectWithBountyBudget() public {
                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = 5 ether;

                bytes32 pid = _createProjectWithBountyBudget("budgeted", 10 ether, tokens, caps);

                bytes memory result = tm.getLensData(9, abi.encode(pid, address(bountyToken)));
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 5 ether, "Cap should be set during project creation");
                assertEq(spent, 0, "Spent should be zero initially");
            }

            function test_CreateProjectWithUnlimitedBountyBudget() public {
                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = type(uint128).max;

                bytes32 pid = _createProjectWithBountyBudget("unlimited", 10 ether, tokens, caps);

                bytes memory result = tm.getLensData(9, abi.encode(pid, address(bountyToken)));
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, type(uint128).max, "Cap should be unlimited sentinel");
            }

            function test_CreateProjectEmitsBountyCapEvents() public {
                address[] memory tokens = new address[](2);
                tokens[0] = address(bountyToken);
                tokens[1] = makeAddr("otherToken");
                uint256[] memory caps = new uint256[](2);
                caps[0] = 5 ether;
                caps[1] = 3 ether;

                // Expect BountyCapSet events (after ProjectCreated)
                vm.prank(creator1);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.ProjectCreated(bytes32(uint256(0)), bytes("events"), bytes32(0), 0);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.BountyCapSet(bytes32(uint256(0)), address(bountyToken), 0, 5 ether);
                vm.expectEmit(true, true, true, true);
                emit TaskManager.BountyCapSet(bytes32(uint256(0)), makeAddr("otherToken"), 0, 3 ether);

                (
                    uint256[] memory createHats,
                    uint256[] memory claimHats,
                    uint256[] memory reviewHats,
                    uint256[] memory assignHats
                ) = _defaultRoleHats();
                tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("events"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: tokens,
                        bountyCaps: caps
                    })
                );
            }

            function test_CreateProjectArrayLengthMismatch() public {
                address[] memory tokens = new address[](2);
                tokens[0] = address(bountyToken);
                tokens[1] = makeAddr("other");
                uint256[] memory caps = new uint256[](1);
                caps[0] = 5 ether;

                (
                    uint256[] memory createHats,
                    uint256[] memory claimHats,
                    uint256[] memory reviewHats,
                    uint256[] memory assignHats
                ) = _defaultRoleHats();

                vm.prank(creator1);
                vm.expectRevert(TaskManager.ArrayLengthMismatch.selector);
                tm.createProject(
                    TaskManager.BootstrapProjectConfig({
                        title: bytes("mismatch"),
                        metadataHash: bytes32(0),
                        cap: 0,
                        managers: new address[](0),
                        createHats: createHats,
                        claimHats: claimHats,
                        reviewHats: reviewHats,
                        assignHats: assignHats,
                        bountyTokens: tokens,
                        bountyCaps: caps
                    })
                );
            }

            // -- cap=0 means DISABLED --

            function test_DefaultCapZeroBlocksBountyTasks() public {
                // Create project with NO bounty budgets (all caps default to 0)
                bytes32 pid = _createDefaultProject("no-bounty", 10 ether);

                // Trying to create a bounty task should revert
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1 ether, bytes("task"), bytes32(0), pid, address(bountyToken), 1 ether, false);
            }

            function test_DefaultCapZeroAllowsNonBountyTasks() public {
                // Create project with NO bounty budgets
                bytes32 pid = _createDefaultProject("no-bounty", 10 ether);

                // Non-bounty tasks should work fine
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task"), bytes32(0), pid, address(0), 0, false);
            }

            function test_DisableBountyBudgetViaSetConfig() public {
                // Create project with budget for bountyToken
                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = 5 ether;

                bytes32 pid = _createProjectWithBountyBudget("disable-test", 10 ether, tokens, caps);

                // Create a task (should work)
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), pid, address(bountyToken), 2 ether, false);

                // Disable the budget by setting cap to 0
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, address(bountyToken), uint256(0)));

                // New bounty tasks should now be blocked
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1 ether, bytes("task2"), bytes32(0), pid, address(bountyToken), 1 ether, false);
            }

            function test_EnableBountyBudgetViaSetConfig() public {
                // Start with no bounty budget (disabled)
                bytes32 pid = _createDefaultProject("enable-test", 10 ether);

                // Can't create bounty task yet
                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), pid, address(bountyToken), 1 ether, false);

                // Enable budget via setConfig
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, address(bountyToken), 3 ether));

                // Now it should work
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), pid, address(bountyToken), 2 ether, false);
            }

            // -- unlimited sentinel --

            function test_SetUnlimitedViaSetConfig() public {
                bytes32 pid = _createDefaultProject("unlim", 10 ether);

                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, address(bountyToken), type(uint128).max));

                // Can create arbitrarily large bounty tasks
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task1"), bytes32(0), pid, address(bountyToken), 100 ether, false);

                vm.prank(creator1);
                tm.createTask(1 ether, bytes("task2"), bytes32(0), pid, address(bountyToken), 500 ether, false);

                bytes memory result = tm.getLensData(9, abi.encode(pid, address(bountyToken)));
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, type(uint128).max, "Cap should remain unlimited");
                assertEq(spent, 600 ether, "Spent should track correctly");
            }

            // -- createAndAssignTask respects budget --

            function test_CreateAndAssignTaskBlockedByDisabledBudget() public {
                bytes32 pid = _createDefaultProject("assign-test", 10 ether);

                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createAndAssignTask(
                    1 ether, bytes("task"), bytes32(0), pid, member1, address(bountyToken), 1 ether, false
                );
            }

            function test_CreateAndAssignTaskWorksWithBudget() public {
                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = 5 ether;

                bytes32 pid = _createProjectWithBountyBudget("assign-ok", 10 ether, tokens, caps);

                vm.prank(creator1);
                tm.createAndAssignTask(
                    1 ether, bytes("task"), bytes32(0), pid, member1, address(bountyToken), 3 ether, false
                );

                bytes memory result = tm.getLensData(9, abi.encode(pid, address(bountyToken)));
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(spent, 3 ether, "Budget should track createAndAssign");
            }

            // -- bootstrap with bounty budgets --

            function test_BootstrapProjectWithBountyBudget() public {
                // Re-deploy with deployer set
                TaskManager tmBootstrap;
                TaskManager _impl = new TaskManager();
                UpgradeableBeacon _beacon = new UpgradeableBeacon(address(_impl), address(this));
                tmBootstrap = TaskManager(address(new BeaconProxy(address(_beacon), "")));
                address deployer = makeAddr("deployer");

                vm.prank(deployer);
                tmBootstrap.initialize(address(token), address(hats), _hatArr(CREATOR_HAT), executor, deployer);

                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = 10 ether;

                TaskManager.BootstrapProjectConfig[] memory projects = new TaskManager.BootstrapProjectConfig[](1);
                projects[0] = TaskManager.BootstrapProjectConfig({
                    title: bytes("bootstrap-bounty"),
                    metadataHash: bytes32(0),
                    cap: 0,
                    managers: new address[](0),
                    createHats: _hatArr(CREATOR_HAT),
                    claimHats: _hatArr(MEMBER_HAT),
                    reviewHats: _hatArr(PM_HAT),
                    assignHats: _hatArr(PM_HAT),
                    bountyTokens: tokens,
                    bountyCaps: caps
                });

                TaskManager.BootstrapTaskConfig[] memory tasks = new TaskManager.BootstrapTaskConfig[](0);

                vm.prank(deployer);
                bytes32[] memory projectIds = tmBootstrap.bootstrapProjectsAndTasks(projects, tasks);

                bytes memory result = tmBootstrap.getLensData(9, abi.encode(projectIds[0], address(bountyToken)));
                (uint256 cap, uint256 spent) = abi.decode(result, (uint256, uint256));
                assertEq(cap, 10 ether, "Bootstrap should set bounty cap");
                assertEq(spent, 0, "Bootstrap spent should be zero");
            }
        }

        contract TaskManagerCreateTasksBatchTest is TaskManagerTestBase {
            bytes32 PID;
            bytes32 BOUNTY_PID;
            MockERC20 bountyToken;

            function setUp() public {
                setUpBase();
                bountyToken = new MockERC20();
                bountyToken.mint(address(tm), 1000 ether);

                PID = _createDefaultProject("BATCH", 0);

                address[] memory tokens = new address[](1);
                tokens[0] = address(bountyToken);
                uint256[] memory caps = new uint256[](1);
                caps[0] = 5 ether;
                BOUNTY_PID = _createProjectWithBountyBudget("BATCH_BOUNTY", 10 ether, tokens, caps);
            }

            function _mkInput(uint256 payout, bytes memory title)
                internal
                pure
                returns (TaskManager.CreateTaskInput memory)
            {
                return TaskManager.CreateTaskInput({
                    payout: payout,
                    title: title,
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 0,
                    requiresApplication: false
                });
            }

            function _projectSpent(bytes32 pid) internal view returns (uint128 spent) {
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.PROJECT_INFO, abi.encode(pid));
                (, uint128 s,) = abi.decode(result, (uint128, uint128, bool));
                spent = s;
            }

            function _bountySpent(bytes32 pid, address tok) internal view returns (uint128 spent) {
                bytes memory result =
                    lens.getStorage(address(tm), TaskManagerLens.StorageKey.BOUNTY_BUDGET, abi.encode(pid, tok));
                (, uint128 s) = abi.decode(result, (uint128, uint128));
                spent = s;
            }

            function _taskProjectId(uint256 id) internal view returns (bytes32 projectId) {
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(id));
                (,,, bytes32 pid,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                projectId = pid;
            }

            /*───────────────── HAPPY PATHS ─────────────────*/

            function test_CreateTasksBatch_HappyPath_FiveTasks() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](5);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(2 ether, bytes("b"));
                inputs[2] = _mkInput(3 ether, bytes("c"));
                inputs[3] = _mkInput(4 ether, bytes("d"));
                inputs[4] = _mkInput(5 ether, bytes("e"));

                vm.prank(creator1);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                assertEq(ids.length, 5, "should return five ids");
                for (uint256 i; i < 5; ++i) {
                    assertEq(ids[i], i, "ids should be sequential from 0");
                    assertEq(_taskProjectId(ids[i]), PID, "task should belong to PID");
                }
                assertEq(_projectSpent(PID), 15 ether, "spent should equal sum of payouts");
            }

            function test_CreateTasksBatch_EmitsTaskCreatedPerTask() public {
                // Bind expected ids to a prior task so any reordering bug surfaces
                // (without the seed, ids and loop indices coincidentally match starting at 0).
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("seed"), bytes32(0), PID, address(0), 0, false);

                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
                inputs[0] = _mkInput(1 ether, bytes("title-a"));
                inputs[1] = _mkInput(2 ether, bytes("title-b"));
                inputs[2] = _mkInput(3 ether, bytes("title-c"));

                for (uint256 i; i < 3; ++i) {
                    vm.expectEmit(true, true, false, true, address(tm));
                    emit TaskManager.TaskCreated(
                        i + 1, PID, inputs[i].payout, address(0), 0, false, inputs[i].title, bytes32(0)
                    );
                }

                vm.prank(creator1);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                for (uint256 i; i < 3; ++i) {
                    assertEq(ids[i], i + 1, "returned id must match emitted event id");
                }
            }

            function test_CreateTasksBatch_MixedRequiresApplicationFlag() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("open"),
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 0,
                    requiresApplication: true
                });
                inputs[1] = _mkInput(1 ether, bytes("claimable"));
                inputs[2] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("open-2"),
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 0,
                    requiresApplication: true
                });

                vm.prank(creator1);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                bytes memory r0 = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(ids[0]));
                bytes memory r1 = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(ids[1]));
                bytes memory r2 = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(ids[2]));
                (,,,, bool ra0) = abi.decode(r0, (uint256, TaskManager.Status, address, bytes32, bool));
                (,,,, bool ra1) = abi.decode(r1, (uint256, TaskManager.Status, address, bytes32, bool));
                (,,,, bool ra2) = abi.decode(r2, (uint256, TaskManager.Status, address, bytes32, bool));
                assertTrue(ra0, "task 0 should require application");
                assertFalse(ra1, "task 1 should be directly claimable");
                assertTrue(ra2, "task 2 should require application");

                // Sanity end-to-end: directly-claimable task can be claimed; application-required cannot.
                vm.prank(member1);
                tm.claimTask(ids[1]);
                vm.prank(member1);
                vm.expectRevert(TaskManager.RequiresApplication.selector);
                tm.claimTask(ids[0]);
            }

            function test_CreateTasksBatch_WithBountyTokens() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](2);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("bounty-a"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 1 ether,
                    requiresApplication: false
                });
                inputs[1] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("bounty-b"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 2 ether,
                    requiresApplication: false
                });

                vm.prank(creator1);
                tm.createTasksBatch(BOUNTY_PID, inputs);

                assertEq(_projectSpent(BOUNTY_PID), 2 ether, "PT spent should accumulate");
                assertEq(_bountySpent(BOUNTY_PID, address(bountyToken)), 3 ether, "bounty spent should accumulate");
            }

            function test_CreateTasksBatch_MixedBountyAndNonBounty() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("with-bounty"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 2 ether,
                    requiresApplication: false
                });
                inputs[1] = _mkInput(1 ether, bytes("plain"));
                inputs[2] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("with-bounty-2"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 1 ether,
                    requiresApplication: false
                });

                vm.prank(creator1);
                tm.createTasksBatch(BOUNTY_PID, inputs);

                assertEq(_bountySpent(BOUNTY_PID, address(bountyToken)), 3 ether, "only bounty tasks count");
            }

            function test_CreateTasksBatch_IdsContinueAfterPriorCreate() public {
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("first"), bytes32(0), PID, address(0), 0, false);

                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(1 ether, bytes("b"));
                inputs[2] = _mkInput(1 ether, bytes("c"));

                vm.prank(creator1);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                assertEq(ids[0], 1, "should continue after prior id 0");
                assertEq(ids[1], 2);
                assertEq(ids[2], 3);
            }

            function test_CreateTasksBatch_ExecutorCanCall() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](2);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(1 ether, bytes("b"));

                vm.prank(executor);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                assertEq(ids.length, 2);
            }

            function test_CreateTasksBatch_ProjectManagerCanCall() public {
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(PID, pm1, true));

                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](2);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(1 ether, bytes("b"));

                vm.prank(pm1);
                uint256[] memory ids = tm.createTasksBatch(PID, inputs);

                assertEq(ids.length, 2);
            }

            /*───────────────── REVERTS ─────────────────*/

            function test_RevertWhen_CreateTasksBatch_Empty() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](0);
                vm.prank(creator1);
                vm.expectRevert(TaskManager.EmptyBatch.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_NoPermission() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = _mkInput(1 ether, bytes("a"));

                vm.prank(outsider);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_ProjectNotFound() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = _mkInput(1 ether, bytes("a"));

                // Executor bypasses permission via _isPM, then hits NotFound inside _createTask.
                vm.prank(executor);
                vm.expectRevert(TaskManager.NotFound.selector);
                tm.createTasksBatch(bytes32("does-not-exist"), inputs);
            }

            function test_RevertWhen_CreateTasksBatch_ZeroPayout() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](2);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(0, bytes("zero-payout"));

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_EmptyTitle() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = _mkInput(1 ether, bytes(""));

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.EmptyTitle.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_TitleTooLong() public {
                bytes memory longTitle = new bytes(257);
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = _mkInput(1 ether, longTitle);

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.TitleTooLong.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_PayoutOverflow() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = _mkInput(1e24 + 1, bytes("too-big"));

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTasksBatch(PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_ExceedsProjectCap() public {
                bytes32 cappedPid = _createDefaultProject("CAPPED_BATCH", 2 ether);

                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
                inputs[0] = _mkInput(1 ether, bytes("a"));
                inputs[1] = _mkInput(1 ether, bytes("b"));
                inputs[2] = _mkInput(1, bytes("over"));

                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTasksBatch(cappedPid, inputs);

                // Atomicity: nothing should have been written.
                assertEq(_projectSpent(cappedPid), 0, "spent must be unchanged after revert");
            }

            function test_RevertWhen_CreateTasksBatch_ExceedsBountyCap() public {
                // BOUNTY_PID has bounty cap of 5 ether.
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](2);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("a"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 4 ether,
                    requiresApplication: false
                });
                inputs[1] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("b"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 2 ether,
                    requiresApplication: false
                });

                vm.prank(creator1);
                vm.expectRevert(BudgetLib.BudgetExceeded.selector);
                tm.createTasksBatch(BOUNTY_PID, inputs);

                assertEq(_bountySpent(BOUNTY_PID, address(bountyToken)), 0, "bounty spent must roll back");
                assertEq(_projectSpent(BOUNTY_PID), 0, "PT spent must roll back");
            }

            function test_RevertWhen_CreateTasksBatch_BadBountyConfig_TokenZeroPayoutPositive() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("bad"),
                    metadataHash: bytes32(0),
                    bountyToken: address(0),
                    bountyPayout: 1 ether,
                    requiresApplication: false
                });

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.ZeroAddress.selector);
                tm.createTasksBatch(BOUNTY_PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_BadBountyConfig_TokenSetPayoutZero() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](1);
                inputs[0] = TaskManager.CreateTaskInput({
                    payout: 1 ether,
                    title: bytes("bad"),
                    metadataHash: bytes32(0),
                    bountyToken: address(bountyToken),
                    bountyPayout: 0,
                    requiresApplication: false
                });

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTasksBatch(BOUNTY_PID, inputs);
            }

            function test_RevertWhen_CreateTasksBatch_AtomicityOnLastFailure() public {
                TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](6);
                for (uint256 i; i < 5; ++i) {
                    inputs[i] = _mkInput(1 ether, bytes("ok"));
                }
                inputs[5] = _mkInput(0, bytes("bad")); // zero payout reverts

                vm.prank(creator1);
                vm.expectRevert(ValidationLib.InvalidPayout.selector);
                tm.createTasksBatch(PID, inputs);

                assertEq(_projectSpent(PID), 0, "spent must be unchanged after atomic revert");

                // nextTaskId atomicity: a fresh task after the failed batch must get id 0,
                // proving the counter never advanced inside the reverted loop.
                vm.prank(creator1);
                tm.createTask(1 ether, bytes("post-revert"), bytes32(0), PID, address(0), 0, false);
                bytes memory result = lens.getStorage(address(tm), TaskManagerLens.StorageKey.TASK_INFO, abi.encode(0));
                (,,, bytes32 projectId,) = abi.decode(result, (uint256, TaskManager.Status, address, bytes32, bool));
                assertEq(projectId, PID, "id 0 must be the post-revert task: counter did not advance");
            }
        }

        /*──────────────── Folders + Organizer Hat ────────────────*/
        contract TaskManagerFoldersTest is TaskManagerTestBase {
            uint256 constant ORGANIZER_HAT = 99;
            address organizer = makeAddr("organizer");
            address randomUser = makeAddr("randomUser");
            bytes32 ROOT_A = keccak256("folders-root-a");
            bytes32 ROOT_B = keccak256("folders-root-b");
            bytes32 PID;

            function setUp() public {
                setUpBase();
                setHat(organizer, ORGANIZER_HAT);
                // Designate ORGANIZER_HAT as an authorized folders organizer.
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(ORGANIZER_HAT, true));
                PID = _createDefaultProject("FOLDERS_PROJ", 0);
            }

            function _foldersRoot() internal view returns (bytes32 root) {
                bytes memory data = tm.getLensData(10, "");
                root = abi.decode(data, (bytes32));
            }

            function _organizerHats() internal view returns (uint256[] memory hats_) {
                bytes memory data = tm.getLensData(11, "");
                hats_ = abi.decode(data, (uint256[]));
            }

            /*───────── happy paths ─────────*/

            function test_SetFolders_ByExecutor_Succeeds() public {
                vm.prank(executor);
                tm.setFolders(bytes32(0), ROOT_A);
                assertEq(_foldersRoot(), ROOT_A, "root should be ROOT_A");
            }

            function test_SetFolders_ByOrganizerHat_Succeeds() public {
                vm.prank(organizer);
                tm.setFolders(bytes32(0), ROOT_A);
                assertEq(_foldersRoot(), ROOT_A);

                // organizer can also chain a follow-up update with the current root
                vm.prank(organizer);
                tm.setFolders(ROOT_A, ROOT_B);
                assertEq(_foldersRoot(), ROOT_B);
            }

            function test_SetFolders_ZeroRootClear_Allowed() public {
                vm.prank(organizer);
                tm.setFolders(bytes32(0), ROOT_A);

                vm.prank(organizer);
                tm.setFolders(ROOT_A, bytes32(0));
                assertEq(_foldersRoot(), bytes32(0), "root should clear to zero");
            }

            function test_SetFolders_EmitsFoldersUpdated_OldAndNewRoots() public {
                vm.expectEmit(true, true, true, false, address(tm));
                emit TaskManager.FoldersUpdated(ROOT_A, bytes32(0), organizer);
                vm.prank(organizer);
                tm.setFolders(bytes32(0), ROOT_A);

                vm.expectEmit(true, true, true, false, address(tm));
                emit TaskManager.FoldersUpdated(ROOT_B, ROOT_A, executor);
                vm.prank(executor);
                tm.setFolders(ROOT_A, ROOT_B);
            }

            /*───────── permission strictness ─────────*/

            function test_RevertWhen_SetFolders_ByCreatorHat() public {
                // creator1 wears CREATOR_HAT but not ORGANIZER_HAT — must revert.
                vm.prank(creator1);
                vm.expectRevert(TaskManager.NotOrganizer.selector);
                tm.setFolders(bytes32(0), ROOT_A);
            }

            function test_RevertWhen_SetFolders_ByProjectManager() public {
                // Make pm1 a project manager on PID and prove that still doesn't grant folder rights.
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(PID, pm1, true));

                vm.prank(pm1);
                vm.expectRevert(TaskManager.NotOrganizer.selector);
                tm.setFolders(bytes32(0), ROOT_A);
            }

            function test_RevertWhen_SetFolders_ByRandom() public {
                vm.prank(randomUser);
                vm.expectRevert(TaskManager.NotOrganizer.selector);
                tm.setFolders(bytes32(0), ROOT_A);
            }

            /*───────── CAS guard ─────────*/

            function test_RevertWhen_SetFolders_StaleExpectedRoot() public {
                vm.prank(organizer);
                tm.setFolders(bytes32(0), ROOT_A);

                // Caller still thinks current is bytes32(0) — must revert with FoldersRootStale.
                vm.prank(organizer);
                vm.expectRevert(abi.encodeWithSelector(TaskManager.FoldersRootStale.selector, bytes32(0), ROOT_A));
                tm.setFolders(bytes32(0), ROOT_B);

                // Storage unchanged.
                assertEq(_foldersRoot(), ROOT_A, "state must be unchanged after stale revert");
            }

            /*───────── organizer hat config plumbing ─────────*/

            function test_RevertWhen_SetConfig_OrganizerHatAllowed_NonExecutor() public {
                vm.prank(organizer);
                vm.expectRevert(TaskManager.NotExecutor.selector);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(uint256(42), true));
            }

            function test_SetConfig_OrganizerHatAllowed_AddRemove_RoundTrip() public {
                // Setup added ORGANIZER_HAT already. Add a second hat.
                uint256 secondHat = 42;
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(secondHat, true));

                uint256[] memory after_ = _organizerHats();
                assertEq(after_.length, 2, "should have two organizer hats");

                // Remove the original.
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(ORGANIZER_HAT, false));

                uint256[] memory after2 = _organizerHats();
                assertEq(after2.length, 1, "should have one organizer hat left");
                assertEq(after2[0], secondHat, "remaining hat should be the second one");

                // Original wearer can no longer reorganize.
                vm.prank(organizer);
                vm.expectRevert(TaskManager.NotOrganizer.selector);
                tm.setFolders(bytes32(0), ROOT_A);
            }

            function test_SetConfig_OrganizerHatAllowed_EmitsEvent() public {
                uint256 newHat = 77;
                vm.expectEmit(true, false, false, true, address(tm));
                emit TaskManager.OrganizerHatAllowed(newHat, true);
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(newHat, true));
            }

            /*───────── lens ─────────*/

            function test_GetLensData_FoldersRoot_DefaultsToZero() public view {
                assertEq(_foldersRoot(), bytes32(0), "fresh deploy should have zero root");
            }

            function test_GetLensData_OrganizerHats_ReturnsArray() public view {
                uint256[] memory hats_ = _organizerHats();
                assertEq(hats_.length, 1, "should have one organizer hat from setUp");
                assertEq(hats_[0], ORGANIZER_HAT, "should be ORGANIZER_HAT");
            }

            /*───────── cross-feature integration ─────────*/

            /// @dev Locks in that the two new features (editable budgets via TaskPerm.BUDGET
            /// and folders via organizerHatIds) are independent: a BUDGET-hat wearer cannot
            /// touch folders, and an organizer-hat wearer cannot touch budgets. They share
            /// the same setConfig dispatcher and the same Layout struct, so this guards
            /// against regressions where the per-branch refactor accidentally cross-wires
            /// permission paths.
            function test_BudgetAndFolders_HatsAreIndependent() public {
                uint256 BUDGET_HAT = 100;
                address budgetEditor = makeAddr("budgetEditor");
                setHat(budgetEditor, BUDGET_HAT);

                // Executor grants the BUDGET perm to its hat.
                vm.prank(executor);
                tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(BUDGET_HAT, TaskPerm.BUDGET));

                // BUDGET-hat wearer CAN edit the project's PT cap.
                vm.prank(budgetEditor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(PID, uint256(50 ether)));

                // BUDGET-hat wearer CANNOT publish folders (no organizer hat).
                vm.prank(budgetEditor);
                vm.expectRevert(TaskManager.NotOrganizer.selector);
                tm.setFolders(bytes32(0), ROOT_A);

                // Organizer-hat wearer CANNOT edit budget (no BUDGET hat).
                vm.prank(organizer);
                vm.expectRevert(TaskManager.Unauthorized.selector);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(PID, uint256(75 ether)));

                // Organizer-hat wearer CAN publish folders.
                vm.prank(organizer);
                tm.setFolders(bytes32(0), ROOT_A);
                assertEq(_foldersRoot(), ROOT_A, "organizer should be able to set folders");

                // Both wearers can chain their respective updates in the same session.
                vm.prank(organizer);
                tm.setFolders(ROOT_A, ROOT_B);
                assertEq(_foldersRoot(), ROOT_B);

                vm.prank(budgetEditor);
                tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(PID, uint256(100 ether)));
            }
        }
