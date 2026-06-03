// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RoleBundleHatter} from "../src/RoleBundleHatter.sol";
import {Executor, IExecutor} from "../src/Executor.sol";
import {TaskManager, IParticipationToken} from "../src/TaskManager.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

import {MockHats} from "./mocks/MockHats.sol";

/// @notice Minimal ParticipationToken mock for integration tests
contract MockPToken {
    mapping(address => uint256) public balances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }
}

/**
 * @notice End-to-end integration tests for the Hats-native role refactor.
 *
 * Exercises the full path: setBundle → mintRole → Executor.mintHatsForUser → hats.mintHat
 * → user can perform gated action because they now wear the capability hat from the bundle.
 *
 * Without this test the audit flagged that the wiring between RoleBundleHatter, Executor,
 * and the downstream gated contracts (TaskManager etc.) was never proven end-to-end with
 * non-mock executors.
 */
contract RoleBundleHatterIntegrationTest is Test {
    MockHats hats;
    MockPToken token;
    Executor executor;
    RoleBundleHatter rbh;
    TaskManager tm;

    address constant GOV = address(0x6017); // governance contract / allowed caller
    address constant ADMIN = address(0xA011); // grants roles via mintRole
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint256 constant VP_HAT = 5001; // role hat
    uint256 constant TASK_CREATE_HAT = 6001; // capability hat
    uint256 constant TASK_CLAIM_HAT = 6002;
    uint256 constant TASK_REVIEW_HAT = 6003;
    uint256 constant TASK_ASSIGN_HAT = 6004;
    uint256 constant PROJECT_CREATOR_HAT = 5002;

    function setUp() public {
        hats = new MockHats();
        token = new MockPToken();

        // Deploy Executor via proxy
        Executor execImpl = new Executor();
        bytes memory execInit = abi.encodeCall(Executor.initialize, (address(this), address(hats)));
        ERC1967Proxy execProxy = new ERC1967Proxy(address(execImpl), execInit);
        executor = Executor(payable(address(execProxy)));

        // Wire executor's allowedCaller to a stand-in governance address
        executor.setCaller(GOV);

        // Deploy RoleBundleHatter via proxy
        RoleBundleHatter rbhImpl = new RoleBundleHatter();
        bytes memory rbhInit = abi.encodeCall(RoleBundleHatter.initialize, (address(hats), address(executor), ADMIN));
        ERC1967Proxy rbhProxy = new ERC1967Proxy(address(rbhImpl), rbhInit);
        rbh = RoleBundleHatter(address(rbhProxy));

        // Authorize RoleBundleHatter as a hat minter on the Executor
        // (the owner — this test contract — can call setHatMinterAuthorization)
        executor.setHatMinterAuthorization(address(rbh), true);

        // Authorize ADMIN as a minter on RoleBundleHatter
        vm.prank(ADMIN);
        rbh.setAuthorizedMinter(ADMIN, true);

        // Configure VP role bundle: VP → [task.create, task.claim, task.review, task.assign]
        uint256[] memory vpBundle = new uint256[](4);
        vpBundle[0] = TASK_CREATE_HAT;
        vpBundle[1] = TASK_CLAIM_HAT;
        vpBundle[2] = TASK_REVIEW_HAT;
        vpBundle[3] = TASK_ASSIGN_HAT;
        vm.prank(ADMIN);
        rbh.setBundle(VP_HAT, vpBundle);

        // Deploy TaskManager (proxy via ERC1967), initialize with PROJECT_CREATOR_HAT
        TaskManager tmImpl = new TaskManager();
        bytes memory tmInit = abi.encodeCall(
            TaskManager.initialize, (address(token), address(hats), PROJECT_CREATOR_HAT, address(executor), address(0))
        );
        ERC1967Proxy tmProxy = new ERC1967Proxy(address(tmImpl), tmInit);
        tm = TaskManager(address(tmProxy));

        // Set TaskManager's global capability hats via executor governance
        vm.startPrank(address(executor));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TASK_CREATE_HAT, TaskPerm.CREATE));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TASK_CLAIM_HAT, TaskPerm.CLAIM));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TASK_REVIEW_HAT, TaskPerm.REVIEW));
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(TASK_ASSIGN_HAT, TaskPerm.ASSIGN));
        vm.stopPrank();
    }

    /* ═══════════════════ Core integration test ═══════════════════ */

    function testMintRoleGrantsAllCapabilityHatsInBundle() public {
        // Sanity: alice wears nothing
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, TASK_REVIEW_HAT));

        // Grant VP role to alice via mintRole
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);

        // She now wears VP role hat + every capability hat in VP's bundle
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT), "VP role hat");
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT), "create cap");
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CLAIM_HAT), "claim cap");
        assertTrue(hats.isWearerOfHat(ALICE, TASK_REVIEW_HAT), "review cap");
        assertTrue(hats.isWearerOfHat(ALICE, TASK_ASSIGN_HAT), "assign cap");
    }

    function testCapabilityHatsActuallyGateTaskManagerActions() public {
        // Alice gets VP role (which includes task capabilities)
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);

        // Alice can create a task in any project — but first we need a project
        // Bob doesn't wear PROJECT_CREATOR_HAT, but executor can create it
        hats.mintHat(PROJECT_CREATOR_HAT, BOB);
        vm.prank(BOB);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("p"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: 0,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Alice (with TASK_CREATE_HAT from her VP bundle) can create a task
        vm.prank(ALICE);
        tm.createTask(1 ether, bytes("alice's task"), bytes32(0), pid, address(0), 0, false);

        // Alice can also claim it (has TASK_CLAIM_HAT)
        vm.prank(ALICE);
        tm.claimTask(0);

        // ...and submit
        vm.prank(ALICE);
        tm.submitTask(0, keccak256("work"));

        // A third party (Charlie) with no hats AND not a project manager cannot create a task
        // Note: Bob is the project manager (PM bypasses capability checks by design)
        address charlie = address(0xC0C);
        vm.prank(charlie);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("charlie's task"), bytes32(0), pid, address(0), 0, false);
    }

    function testRevokingOneCapabilityHatLeavesOthersIntact() public {
        // Alice gets VP role with full bundle
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CLAIM_HAT));

        // Executor revokes ONE capability hat from alice via setHatWearerStatus
        vm.prank(address(executor));
        hats.setHatWearerStatus(TASK_CREATE_HAT, ALICE, false, false);

        // Alice now wears VP and other capability hats but NOT create
        assertFalse(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT), "create revoked");
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CLAIM_HAT), "claim still worn");
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT), "VP still worn");

        // Create a project so we can test the gate
        hats.mintHat(PROJECT_CREATOR_HAT, BOB);
        vm.prank(BOB);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("p"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: 0,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Alice can no longer create (TASK_CREATE_HAT revoked)
        vm.prank(ALICE);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1 ether, bytes("t"), bytes32(0), pid, address(0), 0, false);
    }

    function testMintRoleIsIdempotentEndToEnd() public {
        // First grant
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));

        // Second grant — should be a no-op (no revert, no double-mint side effects)
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);

        // Still wears all hats, no errors
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT));
    }

    function testMintRoleUnauthorizedMinterReverts() public {
        // BOB is not in authorizedMinters
        vm.prank(BOB);
        vm.expectRevert(RoleBundleHatter.NotAuthorizedMinter.selector);
        rbh.mintRole(VP_HAT, ALICE);
    }

    function testExecutorCanCallMintRole() public {
        // Executor (authorized for governance) should be able to call mintRole
        // First, ADMIN authorizes the executor as a minter
        vm.prank(ADMIN);
        rbh.setAuthorizedMinter(address(executor), true);

        vm.prank(address(executor));
        rbh.mintRole(VP_HAT, ALICE);

        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, TASK_CREATE_HAT));
    }

    function testRBHCannotMintWithoutExecutorAuthorization() public {
        // Revoke RBH's authorization on Executor
        executor.setHatMinterAuthorization(address(rbh), false);

        // Attempting mintRole now reverts because Executor rejects the call
        vm.prank(ADMIN);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        rbh.mintRole(VP_HAT, ALICE);
    }

    /* ═══════════════════ Bundle reconfiguration ═══════════════════ */

    function testBundleEditViaAddRemove() public {
        // Add a new capability to VP bundle
        uint256 newCap = 7777;
        vm.prank(ADMIN);
        rbh.addToBundle(VP_HAT, newCap);
        assertEq(rbh.bundleSize(VP_HAT), 5);
        assertTrue(rbh.isInBundle(VP_HAT, newCap));

        // Mint VP — alice should get the new capability too
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, newCap));

        // Remove a capability from the bundle
        vm.prank(ADMIN);
        rbh.removeFromBundle(VP_HAT, TASK_REVIEW_HAT);
        assertEq(rbh.bundleSize(VP_HAT), 4);
        assertFalse(rbh.isInBundle(VP_HAT, TASK_REVIEW_HAT));

        // Existing alice still wears review (removeFromBundle doesn't revoke wearer-side state)
        assertTrue(hats.isWearerOfHat(ALICE, TASK_REVIEW_HAT), "removeFromBundle is bundle-only, not wearer-revoke");

        // BUT a fresh wearer (bob) won't get review hat anymore
        vm.prank(ADMIN);
        rbh.mintRole(VP_HAT, BOB);
        assertFalse(hats.isWearerOfHat(BOB, TASK_REVIEW_HAT), "bob misses review since bundle no longer includes it");
        assertTrue(hats.isWearerOfHat(BOB, VP_HAT));
        assertTrue(hats.isWearerOfHat(BOB, TASK_CREATE_HAT));
    }
}
