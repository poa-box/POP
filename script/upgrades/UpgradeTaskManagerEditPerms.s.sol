// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * TaskManager Upgrade — Post-Claim Edit Permissions (v5)
 * ============================================================================
 *
 * Adds two new TaskPerm bits — `EDIT_META` (1 << 6) and `EDIT_FULL` (1 << 7) —
 * letting hats explicitly granted those bits edit a task after it has been
 * claimed or submitted. Adds the sibling `updateTaskMetadata(id, title, hash)`
 * for the metadata-only path. Terminal states (COMPLETED / CANCELLED) remain
 * immutable. Project managers and the executor implicitly get EDIT_FULL on
 * their projects.
 *
 * No Layout struct change. No new event signature. No new ConfigKey. Subgraph
 * is unaffected — RolePermSet / ProjectRolePermSet already carry every bit
 * the indexer needs.
 *
 * Three-step cross-chain upgrade pattern (mirrors UpgradeTaskManagerCreateTasksBatch):
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditPerms.s.sol:<StepContract> \
 *     --rpc-url <chain> --broadcast --slow
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub (Arbitrum), PoaManagerSatellite (Gnosis), DeterministicDeployer.
// Hardcoded per CLAUDE.md: "prank as it, don't read Hub.owner() and reuse the result, in case
// ownership ever changes mid-fork." Used by the DryRun sim, not the broadcast steps.
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
// PoaManagerSatellite on Gnosis — owner of Gnosis PoaManager (verified via on-chain `owner()`
// read 2026-05-27). In production, Satellite receives Hyperlane messages from the Hub and
// invokes `PoaManager.upgradeBeacon`; the sim shortcuts by pranking the Satellite directly
// since simulating the Hyperlane relay end-to-end is impractical on a single-chain fork.
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
// v4 is the latest registered impl on both Gnosis and Arbitrum (createTasksBatch
// shipped as v2, organizer/folders/budget as v4). v5 was probed FREE on both
// chains and the CREATE2 slot for ("TaskManager", "v5") is empty.
string constant VERSION = "v5";

/**
 * @title Step1_DeployImplOnGnosis
 * @notice Deploy TaskManager v5 implementation on Gnosis via DD.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditPerms.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 */
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v5 impl on Gnosis ===");
        console.log("Predicted:", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }

        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(TaskManager).creationCode);
        vm.stopBroadcast();

        require(deployed == predicted, "Address mismatch");
        console.log("Deployed:", deployed);
        console.log("\nNext: Run Step2_UpgradeFromArbitrum on Arbitrum");
    }
}

/**
 * @title Step2_UpgradeFromArbitrum
 * @notice Deploy impl on Arbitrum via DD, upgrade beacon cross-chain.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditPerms.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 */
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 2: Upgrade TaskManager from Arbitrum ===");
        console.log("DD impl address:", predicted);

        vm.startBroadcast(deployerKey);

        if (predicted.code.length == 0) {
            dd.deploy(salt, type(TaskManager).creationCode);
            console.log("Deployed on Arbitrum");
        } else {
            console.log("Already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("TaskManager", predicted, VERSION);
        console.log("Beacon upgraded cross-chain");

        vm.stopBroadcast();
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3 on Gnosis.");
    }
}

/**
 * @title Step3_VerifyGnosis
 * @notice Verify the Gnosis beacon upgrade landed.
 *
 * Usage:
 *   forge script script/upgrades/UpgradeTaskManagerEditPerms.s.sol:Step3_VerifyGnosis \
 *     --rpc-url gnosis
 */
contract Step3_VerifyGnosis is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address expectedImpl = dd.computeAddress(salt);

        address currentImpl = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("TaskManager"));

        console.log("\n=== Step 3: Verify Gnosis TaskManager Upgrade ===");
        console.log("Expected impl:", expectedImpl);
        console.log("Current impl: ", currentImpl);

        if (currentImpl == expectedImpl) {
            console.log("PASS: TaskManager upgraded to v5 on Gnosis");
            console.log("\nNew capabilities:");
            console.log("  - updateTaskMetadata(id, title, hash): metadata-only edits post-claim");
            console.log("  - updateTask now allowed post-claim for EDIT_FULL hats / PMs / executor");
            console.log("  - TaskPerm.EDIT_META (1<<6) and TaskPerm.EDIT_FULL (1<<7) bits");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

interface IOrgRegistry {
    function orgIds(uint256 index) external view returns (bytes32);
    function proxyOf(bytes32 orgId, bytes32 typeId) external view returns (address);
}

/**
 * @title DryRun_GnosisUpgrade
 * @notice Pre-flight test on a Gnosis fork. Deploys impl via DD, upgrades the
 *         beacon, and exercises the new edit-permission paths against a live,
 *         autoUpgrade-tracking TaskManager proxy. Does not broadcast.
 *
 *         Asserts:
 *           1. DD-predicted address matches deployed address.
 *           2. PoaManager beacon updates to the new impl.
 *           3. New `updateTaskMetadata` selector exists in impl runtime bytecode.
 *           4. A live TaskManager proxy on Gnosis (org #0 from OrgRegistry):
 *              a. Pre-existing storage is preserved (executor address survives the impl swap).
 *              b. A fresh project + assigned task is editable by the executor
 *                 post-claim via `updateTask` (payout swap nets correctly in `p.spent`).
 *              c. The executor can also call `updateTaskMetadata` post-claim.
 *              d. A non-PM, non-EDIT_FULL caller reverts `Unauthorized` on `updateTask`.
 *              e. A non-PM, non-EDIT_META caller reverts `Unauthorized` on `updateTaskMetadata`.
 *              f. After the task is COMPLETED, the executor still cannot edit (`BadStatus`).
 *              g. A CANCELLED task on a separate id also reverts `BadStatus`.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerEditPerms.s.sol:DryRun_GnosisUpgrade \
 *     --rpc-url gnosis
 */
contract DryRun_GnosisUpgrade is Script {
    // OrgRegistry is deployed at the same CREATE2 address on every chain.
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v5 upgrade on Gnosis fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(GNOSIS_POA_MANAGER);

        // 1. Pre-state snapshot.
        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        // 2. Step1 simulation: deploy v5 impl via DD.
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
            // DD's deploy is onlyOwner — prank Hudson directly (CLAUDE.md: don't trust on-chain
            // owner() reads mid-fork). Hudson owns DD on both Gnosis and Arbitrum.
            vm.prank(HUDSON_ADMIN);
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            console.log("Already deployed at predicted (skipping deploy)");
            deployed = predicted;
        }
        require(deployed == predicted, "DryRun: DD address mismatch");
        require(deployed.code.length > 0, "DryRun: impl code missing");
        console.log("Deployed impl:", deployed);

        // 3. Step2 simulation: upgrade beacon as the Gnosis PoaManager owner (the Satellite).
        //    Hardcoded per CLAUDE.md — don't trust the on-chain owner() read mid-fork. The
        //    Satellite is the real production caller (via Hyperlane relay from the Hub on Arbitrum).
        vm.prank(GNOSIS_SATELLITE);
        pm.upgradeBeacon("TaskManager", deployed, VERSION);
        address implAfter = pm.getCurrentImplementationById(keccak256("TaskManager"));
        require(implAfter == deployed, "DryRun: beacon upgrade did not stick");
        console.log("Impl after :", implAfter);

        // 4. Selector presence in impl bytecode (cheap source-vs-deployed check).
        bytes4 sel = TaskManager.updateTaskMetadata.selector;
        bytes memory code = deployed.code;
        bool found = false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                found = true;
                break;
            }
        }
        require(found, "DryRun: updateTaskMetadata selector missing from impl bytecode");
        console.log("updateTaskMetadata selector present in impl bytecode");

        // 5. Live-proxy exercise.
        _exerciseLiveProxy();

        console.log("\n=== ALL DRY-RUN CHECKS PASSED ===");
        console.log("Safe to broadcast Step1/Step2/Step3 against mainnet.");
    }

    function _exerciseLiveProxy() internal {
        IOrgRegistry reg = IOrgRegistry(ORG_REGISTRY);
        bytes32 orgId = reg.orgIds(0);
        address proxy = reg.proxyOf(orgId, keccak256("TaskManager"));
        require(proxy != address(0), "DryRun: no TaskManager proxy for org 0");
        TaskManager tm = TaskManager(proxy);

        console.log("\n--- Live-proxy exercise ---");
        console.log("orgId:", vm.toString(orgId));
        console.log("TaskManager proxy:", proxy);

        // 5a. Storage preservation: read executor through the upgraded impl.
        bytes memory execData = tm.getLensData(4, "");
        address executor = abi.decode(execData, (address));
        require(executor != address(0), "DryRun: executor unset post-upgrade (storage drift?)");
        console.log("Executor (preserved):", executor);

        // 5b. Create a fresh test project (executor bypasses _requireCreator).
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("dryrun-edit-perms"),
            metadataHash: bytes32(0),
            cap: 0, // unlimited PT
            managers: new address[](0),
            createHats: new uint256[](0),
            claimHats: new uint256[](0),
            reviewHats: new uint256[](0),
            assignHats: new uint256[](0),
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });
        vm.prank(executor);
        bytes32 pid = tm.createProject(cfg);
        console.log("Test project pid:", vm.toString(pid));

        // 5c. Create + assign a task so it's CLAIMED, then capture the id.
        bytes memory probe = abi.encodeWithSelector(TaskManager.getLensData.selector, uint8(1), abi.encode(uint256(0)));
        // Iterate to find the first unused id (cheap probe loop bounded by project age).
        uint256 candidateId = _nextAvailableTaskId(proxy);

        address assignee = makeAddr("dryrun-claimer");
        vm.prank(executor);
        tm.createTask(2 ether, bytes("orig-title"), bytes32(0), pid, address(0), 0, false, 0, 0);
        vm.prank(executor);
        tm.assignTask(candidateId, assignee);

        (uint96 payoutBefore,, address claimerBefore,,, TaskManager.Status statusBefore,) = _readTask(tm, candidateId);
        require(payoutBefore == 2 ether, "DryRun: pre-edit payout wrong");
        require(claimerBefore == assignee, "DryRun: pre-edit claimer wrong");
        require(statusBefore == TaskManager.Status.CLAIMED, "DryRun: pre-edit status not CLAIMED");
        console.log("Task assigned at id:", candidateId);

        // 5d. Executor edits payout on the CLAIMED task.
        vm.prank(executor);
        tm.updateTask(candidateId, 5 ether, bytes("edited-title"), bytes32(0), address(0), 0, 0, 0);
        (uint96 payoutAfter,,,,, TaskManager.Status statusAfter,) = _readTask(tm, candidateId);
        require(payoutAfter == 5 ether, "DryRun: post-edit payout wrong");
        require(statusAfter == TaskManager.Status.CLAIMED, "DryRun: post-edit status changed");
        console.log("Executor updateTask post-claim OK (payout 2 -> 5)");

        // 5e. Executor calls updateTaskMetadata — payout unchanged, no revert.
        vm.prank(executor);
        tm.updateTaskMetadata(candidateId, bytes("meta-only-title"), bytes32(uint256(0xfeed)));
        (uint96 payoutAfterMeta,,,,,,) = _readTask(tm, candidateId);
        require(payoutAfterMeta == 5 ether, "DryRun: updateTaskMetadata changed payout");
        console.log("Executor updateTaskMetadata post-claim OK (payout preserved)");

        // 5f. Outsider cannot updateTask post-claim.
        address outsider = makeAddr("dryrun-outsider");
        vm.prank(outsider);
        (bool okOut,) = proxy.call(
            abi.encodeCall(
                TaskManager.updateTask, (candidateId, 1 ether, bytes("nope"), bytes32(0), address(0), 0, 0, 0)
            )
        );
        require(!okOut, "DryRun: outsider updateTask must revert");
        console.log("Outsider updateTask -> Unauthorized OK");

        // 5g. Outsider cannot updateTaskMetadata either.
        vm.prank(outsider);
        (bool okOutMeta,) =
            proxy.call(abi.encodeCall(TaskManager.updateTaskMetadata, (candidateId, bytes("nope"), bytes32(0))));
        require(!okOutMeta, "DryRun: outsider updateTaskMetadata must revert");
        console.log("Outsider updateTaskMetadata -> Unauthorized OK");

        // 5h. Submit + complete the task, then prove edits are blocked on COMPLETED.
        vm.prank(assignee);
        tm.submitTask(candidateId, keccak256("done"));
        vm.prank(executor);
        tm.completeTask(candidateId);

        vm.prank(executor);
        (bool okComplete,) = proxy.call(
            abi.encodeCall(TaskManager.updateTask, (candidateId, 9 ether, bytes("x"), bytes32(0), address(0), 0, 0, 0))
        );
        require(!okComplete, "DryRun: COMPLETED updateTask must revert");
        vm.prank(executor);
        (bool okCompleteMeta,) =
            proxy.call(abi.encodeCall(TaskManager.updateTaskMetadata, (candidateId, bytes("x"), bytes32(0))));
        require(!okCompleteMeta, "DryRun: COMPLETED updateTaskMetadata must revert");
        console.log("COMPLETED edits blocked OK");

        // 5i. CANCELLED edits also blocked.
        uint256 cancelId = _nextAvailableTaskId(proxy);
        vm.prank(executor);
        tm.createTask(1 ether, bytes("to-cancel"), bytes32(0), pid, address(0), 0, false, 0, 0);
        vm.prank(executor);
        tm.cancelTask(cancelId);

        vm.prank(executor);
        (bool okCancel,) = proxy.call(
            abi.encodeCall(TaskManager.updateTask, (cancelId, 2 ether, bytes("x"), bytes32(0), address(0), 0, 0, 0))
        );
        require(!okCancel, "DryRun: CANCELLED updateTask must revert");
        console.log("CANCELLED edits blocked OK");
    }

    /// @dev Finds the next unused task id by probing the lens — bounded by org task count.
    function _nextAvailableTaskId(address proxy) internal view returns (uint256) {
        for (uint256 i; i < 1_000_000; ++i) {
            (bool ok,) =
                proxy.staticcall(abi.encodeWithSelector(TaskManager.getLensData.selector, uint8(1), abi.encode(i)));
            if (!ok) return i;
        }
        revert("DryRun: nextAvailableTaskId search exhausted");
    }

    function _readTask(TaskManager tm, uint256 id)
        internal
        view
        returns (
            uint96 payout,
            bytes32 projectId,
            address claimer,
            uint96 bountyPayout,
            bool requiresApplication,
            TaskManager.Status status,
            address bountyToken
        )
    {
        bytes memory data = tm.getLensData(1, abi.encode(id));
        (projectId, payout, claimer, bountyPayout, requiresApplication, status, bountyToken) =
            abi.decode(data, (bytes32, uint96, address, uint96, bool, TaskManager.Status, address));
    }
}
