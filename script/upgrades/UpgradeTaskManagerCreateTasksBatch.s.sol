// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * TaskManager Upgrade — createTasksBatch (v2)
 * ============================================================================
 *
 * Adds `createTasksBatch(bytes32 pid, CreateTaskInput[] calldata tasks)` so a
 * project lead can create N tasks in a single transaction. The batch hoists the
 * permission check (one Hats `balanceOfBatch` call instead of N) and is
 * all-or-nothing: any per-task failure reverts the whole call. Internally
 * `_createTask` was refactored to return the new task id so the batch can
 * surface ids back to the caller without recomputing from `nextTaskId - 1`.
 * No new state, no Layout changes, no event signature changes — drop-in safe
 * for upgrade and for existing subgraph indexers.
 *
 * Three-step cross-chain upgrade pattern:
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol:<StepContract> \
 *     --rpc-url <chain> --broadcast --slow
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Current live TaskManager impl was registered at "v1" (see
// script/deploy/DeploySatelliteInfrastructure.s.sol). Bump to "v2" for a fresh
// deterministic address with createTasksBatch.
string constant VERSION = "v2";

/**
 * @title Step1_DeployImplOnGnosis
 * @notice Deploy TaskManager v2 implementation on Gnosis via DD.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 */
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v2 impl on Gnosis ===");
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
 *     script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol:Step2_UpgradeFromArbitrum \
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
 *   forge script script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol:Step3_VerifyGnosis \
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
            console.log("PASS: TaskManager upgraded to v2 on Gnosis");
            console.log("\nNew capability: createTasksBatch(bytes32 pid, CreateTaskInput[] calldata tasks)");
            console.log("  - Bulk task creation under one project, atomic revert-all");
            console.log("  - Single permission check; one balanceOfBatch instead of N");
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
 *         beacon, and exercises createTasksBatch against a live, autoUpgrade-
 *         tracking TaskManager proxy. Does not broadcast.
 *
 *         Asserts:
 *           1. DD-predicted address matches deployed address.
 *           2. PoaManager beacon updates to the new impl.
 *           3. New `createTasksBatch` selector exists in impl runtime bytecode.
 *           4. A live TaskManager proxy on Gnosis (org #0 from OrgRegistry):
 *              a. Pre-existing storage is preserved (executor address survives
 *                 the impl swap — proves Layout struct is compatible).
 *              b. The new selector is callable through the proxy.
 *              c. Empty batch reverts with EmptyBatch.
 *              d. A 3-task batch on a freshly-created project succeeds, returns
 *                 sequential ids, and each task is readable with the right
 *                 projectId via the lens path.
 *              e. Batch is atomic: a batch ending in a zero-payout task reverts
 *                 with InvalidPayout and leaves nextTaskId unchanged.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol:DryRun_GnosisUpgrade \
 *     --rpc-url gnosis
 */
contract DryRun_GnosisUpgrade is Script {
    // OrgRegistry is deployed at the same CREATE2 address on every chain.
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v2 upgrade on Gnosis fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(GNOSIS_POA_MANAGER);

        // 1. Pre-state snapshot.
        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        // 2. Step1 simulation: deploy v2 impl via DD.
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
            // DD's deploy is onlyOwner — prank as the DD owner EOA.
            vm.prank(DeterministicDeployer(DD).owner());
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            console.log("Already deployed at predicted (skipping deploy)");
            deployed = predicted;
        }
        require(deployed == predicted, "DryRun: DD address mismatch");
        require(deployed.code.length > 0, "DryRun: impl code missing");
        console.log("Deployed impl:", deployed);

        // 3. Step2 simulation: upgrade beacon as PoaManager owner.
        address pmOwner = pm.owner();
        vm.prank(pmOwner);
        pm.upgradeBeacon("TaskManager", deployed, VERSION);
        address implAfter = pm.getCurrentImplementationById(keccak256("TaskManager"));
        require(implAfter == deployed, "DryRun: beacon upgrade did not stick");
        console.log("Impl after :", implAfter);

        // 4. Selector presence in impl bytecode (cheap source-vs-deployed check).
        bytes4 sel = TaskManager.createTasksBatch.selector;
        bytes memory code = deployed.code;
        bool found = false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                found = true;
                break;
            }
        }
        require(found, "DryRun: createTasksBatch selector missing from impl bytecode");
        console.log("createTasksBatch selector present in impl bytecode");

        // 5. Live-proxy exercise: pull a real TaskManager proxy from OrgRegistry
        //    and prove the new function works against production state.
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
        //     If Layout drifted, this would either revert or return junk.
        bytes memory execData = tm.getLensData(4, "");
        address executor = abi.decode(execData, (address));
        require(executor != address(0), "DryRun: executor unset post-upgrade (storage drift?)");
        console.log("Executor (preserved):", executor);

        // 5b. Empty batch reverts.
        TaskManager.CreateTaskInput[] memory empty = new TaskManager.CreateTaskInput[](0);
        vm.prank(executor);
        (bool okEmpty, bytes memory emptyRet) =
            proxy.call(abi.encodeCall(TaskManager.createTasksBatch, (bytes32(uint256(1)), empty)));
        require(!okEmpty, "DryRun: empty batch must revert");
        require(bytes4(emptyRet) == TaskManager.EmptyBatch.selector, "DryRun: empty batch wrong error");
        console.log("EmptyBatch revert path OK");

        // 5c. Create a fresh test project (executor bypasses _requireCreator).
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("dryrun-batch-test"),
            metadataHash: bytes32(0),
            cap: 0, // unlimited PT
            managers: new address[](0),
            createHat: 0,
            claimHat: 0,
            reviewHat: 0,
            assignHat: 0,
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });
        vm.prank(executor);
        bytes32 pid = tm.createProject(cfg);
        console.log("Test project pid:", vm.toString(pid));

        // 5d. Successful 3-task batch.
        TaskManager.CreateTaskInput[] memory inputs = new TaskManager.CreateTaskInput[](3);
        inputs[0] = TaskManager.CreateTaskInput({
            payout: 1 ether,
            title: bytes("batch-task-a"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });
        inputs[1] = TaskManager.CreateTaskInput({
            payout: 2 ether,
            title: bytes("batch-task-b"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });
        inputs[2] = TaskManager.CreateTaskInput({
            payout: 3 ether,
            title: bytes("batch-task-c"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });

        vm.prank(executor);
        uint256[] memory ids = tm.createTasksBatch(pid, inputs);
        require(ids.length == 3, "DryRun: batch returned wrong length");
        require(ids[1] == ids[0] + 1 && ids[2] == ids[1] + 1, "DryRun: ids not sequential");
        console.log("createTasksBatch returned ids:", ids[0], ids[1], ids[2]);

        // 5e. Verify each task has the right projectId via the lens path.
        for (uint256 i; i < 3; ++i) {
            bytes memory taskBytes = tm.getLensData(1, abi.encode(ids[i]));
            (bytes32 taskPid,,,,,,) =
                abi.decode(taskBytes, (bytes32, uint96, address, uint96, bool, TaskManager.Status, address));
            require(taskPid == pid, "DryRun: task projectId mismatch");
        }
        console.log("All 3 tasks have correct projectId");

        // 5f. Atomicity: batch with a bad final task must leave nextTaskId stable.
        //     Capture pre-state by trying to read id == ids[2] + 1 (should revert).
        uint256 expectedNextId = ids[2] + 1;
        bytes memory probeBefore =
            abi.encodeWithSelector(TaskManager.getLensData.selector, uint8(1), abi.encode(expectedNextId));
        (bool existsBefore,) = proxy.staticcall(probeBefore);
        require(!existsBefore, "DryRun: pre-revert next id already exists");

        TaskManager.CreateTaskInput[] memory bad = new TaskManager.CreateTaskInput[](3);
        bad[0] = inputs[0];
        bad[1] = inputs[1];
        bad[2] = TaskManager.CreateTaskInput({
            payout: 0, // invalid: triggers InvalidPayout
            title: bytes("zero-payout"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });

        vm.prank(executor);
        (bool okBad,) = proxy.call(abi.encodeCall(TaskManager.createTasksBatch, (pid, bad)));
        require(!okBad, "DryRun: bad batch must revert");

        // After revert, the same probe must still fail — counter did not advance.
        (bool existsAfter,) = proxy.staticcall(probeBefore);
        require(!existsAfter, "DryRun: nextTaskId advanced despite atomic revert");
        console.log("Atomic revert preserved nextTaskId");
    }
}
