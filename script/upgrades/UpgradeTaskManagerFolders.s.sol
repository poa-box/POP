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
 * TaskManager Upgrade — folders + editable budgets (v4)
 * ============================================================================
 *
 * Combined upgrade shipping TWO features in a single impl (merged from PRs
 * #159 + #160):
 *
 * 1. **Project folders + organizer hat.** Folder tree (names, parents,
 *    ordering, project assignments) lives off-chain in IPFS as JSON. The
 *    contract stores only the root hash + a designated `organizerHatIds`
 *    array; the executor or any wearer of an organizer hat may publish a
 *    new root via `setFolders(expectedCurrentRoot, newRoot)`. The CAS guard
 *    prevents two organizers editing the tree simultaneously from silently
 *    clobbering each other.
 *
 * 2. **Editable project budgets.** A new `TaskPerm.BUDGET` (bit 5) lets a
 *    configured hat-holder — alongside the Executor / passing vote —
 *    resize a project's PT cap and per-token bounty cap. Permission is
 *    strict: the `_isPM` bypass used by `_checkPerm` is intentionally NOT
 *    granted here; PMs need an explicit hat assignment. Implemented by
 *    moving `setConfig`'s top-of-function `_requireExecutor()` into each
 *    branch and adding a `_requireBudgetEditor(pid)` helper for the budget
 *    keys. Other admin keys (`EXECUTOR`, `CREATOR_HAT_ALLOWED`,
 *    `ROLE_PERM`, `PROJECT_MANAGER`, `ORGANIZER_HAT_ALLOWED`) remain
 *    executor-only.
 *
 * Layout change: two new fields appended at the end of `Layout` — `bytes32
 * foldersRoot` and `uint256[] organizerHatIds`. Append-only; no reordering.
 * Storage slot is unchanged. No new fields for editable budgets (reuses
 * existing `rolePermGlobal` / `rolePermProj` masks).
 *
 * ABI surface:
 *   - New external: `setFolders(bytes32 expectedRoot, bytes32 newRoot)`.
 *   - New ConfigKey: `ORGANIZER_HAT_ALLOWED` (executor-only).
 *   - New events: `FoldersUpdated`, `OrganizerHatAllowed`, `RolePermSet`.
 *     (The `RolePermSet` event now fires from `setConfig(ROLE_PERM, ...)` so
 *     indexers can track global hat-permission grants — previously this
 *     branch emitted nothing, making it impossible for the subgraph to surface
 *     "which hats have `TaskPerm.BUDGET` globally" without RPC fan-out.)
 *   - New errors: `NotOrganizer`, `FoldersRootStale`.
 *   - New lens variants: `t == 10` (foldersRoot), `t == 11` (organizerHatIds).
 *   - New permission bit: `TaskPerm.BUDGET = 1 << 5` (granted via existing
 *     `setConfig(ROLE_PERM, ...)` / `setProjectRolePerm`).
 *
 * Three-step cross-chain upgrade pattern (mirrors v2):
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerFolders.s.sol:<StepContract> \
 *     --rpc-url <chain> --broadcast --slow
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Previous TaskManager impl was registered at "v2" (see
// script/upgrades/UpgradeTaskManagerCreateTasksBatch.s.sol). "v3" is already
// occupied on Gnosis with non-folders bytecode (older experimental deploy);
// the DryRun sim caught this. Use "v4" for a fresh deterministic address with
// setFolders + organizer hat support.
string constant VERSION = "v4";

/**
 * @title Step1_DeployImplOnGnosis
 * @notice Deploy TaskManager v4 implementation on Gnosis via DD.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerFolders.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 */
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v4 impl on Gnosis ===");
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
 *     script/upgrades/UpgradeTaskManagerFolders.s.sol:Step2_UpgradeFromArbitrum \
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
 *   forge script script/upgrades/UpgradeTaskManagerFolders.s.sol:Step3_VerifyGnosis \
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
            console.log("PASS: TaskManager upgraded to v4 on Gnosis");
            console.log("\nNew capability: setFolders(bytes32 expectedCurrentRoot, bytes32 newRoot)");
            console.log("  - Folder tree (names/parents/order/assignments) lives in IPFS JSON");
            console.log("  - On-chain stores only the root hash + organizer hat array");
            console.log("  - CAS guard: pass current root to avoid silent overwrite");
            console.log("  - Permission: executor OR wearer of any ORGANIZER_HAT_ALLOWED hat");
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
 *         beacon, and exercises setFolders against a live, autoUpgrade-tracking
 *         TaskManager proxy. Does not broadcast.
 *
 *         Asserts:
 *           1. DD-predicted address matches deployed address.
 *           2. PoaManager beacon updates to the new impl.
 *           3. New `setFolders` selector exists in impl runtime bytecode.
 *           4. A live TaskManager proxy on Gnosis (org #0 from OrgRegistry):
 *              a. Pre-existing storage is preserved (executor address survives
 *                 the impl swap — proves Layout struct is compatible).
 *              b. The new lens variants `t == 10` (foldersRoot) and `t == 11`
 *                 (organizerHatIds) are reachable through the proxy.
 *              c. A fresh-deploy proxy starts with foldersRoot == bytes32(0)
 *                 and no organizer hats — confirming append-only field
 *                 initialization matches Solidity default-zero semantics.
 *              d. Non-organizer caller is rejected with NotOrganizer.
 *              e. Executor can publish a folders root with CAS-guard zero.
 *              f. CAS guard catches a stale expectedCurrentRoot.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerFolders.s.sol:DryRun_GnosisUpgrade \
 *     --rpc-url gnosis
 */
contract DryRun_GnosisUpgrade is Script {
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v4 upgrade on Gnosis fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(GNOSIS_POA_MANAGER);

        // 1. Pre-state snapshot.
        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        // 2. Step1 simulation: deploy v4 impl via DD.
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
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

        // 4. Selector presence in impl bytecode.
        bytes4 sel = TaskManager.setFolders.selector;
        bytes memory code = deployed.code;
        bool found = false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                found = true;
                break;
            }
        }
        require(found, "DryRun: setFolders selector missing from impl bytecode");
        console.log("setFolders selector present in impl bytecode");

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

        // 5a. Storage preservation: executor address must survive the impl swap.
        bytes memory execData = tm.getLensData(4, "");
        address executor = abi.decode(execData, (address));
        require(executor != address(0), "DryRun: executor unset post-upgrade (storage drift?)");
        console.log("Executor (preserved):", executor);

        // 5b. New lens variants are reachable.
        bytes32 rootInitial = abi.decode(tm.getLensData(10, ""), (bytes32));
        uint256[] memory organizerHats = abi.decode(tm.getLensData(11, ""), (uint256[]));
        console.log("Initial folders root (bytes32):", vm.toString(rootInitial));
        console.log("Initial organizer hats count:", organizerHats.length);

        // 5c. Pre-existing org has never set folders or organizer hats -> defaults.
        require(rootInitial == bytes32(0), "DryRun: folders root should default to zero on fresh upgrade");
        require(organizerHats.length == 0, "DryRun: organizer hats should default to empty on fresh upgrade");

        // 5d. Non-organizer caller is rejected (use the DD owner EOA — definitely
        //     not the org's executor and not wearing any org hat).
        address randomEoa = address(0xBEEF);
        vm.prank(randomEoa);
        (bool okRandom, bytes memory randomRet) =
            proxy.call(abi.encodeCall(TaskManager.setFolders, (bytes32(0), keccak256("anything"))));
        require(!okRandom, "DryRun: non-organizer call must revert");
        require(bytes4(randomRet) == TaskManager.NotOrganizer.selector, "DryRun: wrong revert reason for non-organizer");
        console.log("NotOrganizer revert path OK");

        // 5e. Executor can publish a folders root with CAS-guard zero.
        bytes32 root1 = keccak256("dryrun-root-1");
        vm.prank(executor);
        tm.setFolders(bytes32(0), root1);
        require(abi.decode(tm.getLensData(10, ""), (bytes32)) == root1, "DryRun: root1 did not land");
        console.log("Executor setFolders OK");

        // 5f. CAS guard catches a stale expectedCurrentRoot.
        bytes32 root2 = keccak256("dryrun-root-2");
        vm.prank(executor);
        (bool okStale, bytes memory staleRet) = proxy.call(abi.encodeCall(TaskManager.setFolders, (bytes32(0), root2)));
        require(!okStale, "DryRun: stale-root call must revert");
        require(bytes4(staleRet) == TaskManager.FoldersRootStale.selector, "DryRun: wrong revert for stale root");
        require(abi.decode(tm.getLensData(10, ""), (bytes32)) == root1, "DryRun: stale revert must not mutate state");
        console.log("FoldersRootStale CAS guard OK");

        // 5g. Executor can chain a follow-up update with the correct current root.
        vm.prank(executor);
        tm.setFolders(root1, root2);
        require(abi.decode(tm.getLensData(10, ""), (bytes32)) == root2, "DryRun: chained root did not land");
        console.log("Chained setFolders OK");

        // -------- Editable budgets (merged from PR #159) --------

        // 5h. Create a fresh project (executor bypasses _requireCreator) so we
        //     have a real pid to probe against. The new setConfig branches check
        //     `p.exists` before the permission gate, so a fake pid would mask
        //     Unauthorized behind NotFound.
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("dryrun-editable-budgets"),
            metadataHash: bytes32(0),
            cap: 5 ether,
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
        console.log("Fresh project for budget gate probe:", vm.toString(pid));

        // 5i. Random EOA -> setConfig(PROJECT_CAP, ...) now reverts Unauthorized
        //     (was NotExecutor under v2/v3, the old top-of-function gate).
        address randomBudgetCaller = makeAddr("randomBudgetEOA");
        bytes memory probeCapCall = abi.encodeCall(
            TaskManager.setConfig, (TaskManager.ConfigKey.PROJECT_CAP, abi.encode(pid, uint256(2 ether)))
        );
        vm.prank(randomBudgetCaller);
        (bool okGate, bytes memory gateRet) = proxy.call(probeCapCall);
        require(!okGate, "DryRun: random caller must revert on PROJECT_CAP post-upgrade");
        require(
            bytes4(gateRet) == TaskManager.Unauthorized.selector,
            "DryRun: expected Unauthorized post-upgrade (new behavior)"
        );
        console.log("Budget gate: random EOA -> Unauthorized OK");

        // 5j. Executor can still edit PT cap (governance / vote path regression).
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(pid, uint256(10 ether)));
        (uint256 capPost,,) = abi.decode(tm.getLensData(2, abi.encode(pid)), (uint256, uint256, bool));
        require(capPost == 10 ether, "DryRun: executor PROJECT_CAP edit did not land");
        console.log("Executor PROJECT_CAP edit OK (cap=10 ether)");

        // 5k. Executor can still edit a bounty cap (synthetic token; gate is what we're testing).
        address syntheticBountyToken = address(uint160(uint256(keccak256("dryrun-bounty-token"))));
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, syntheticBountyToken, uint256(7 ether)));
        (uint256 bountyCapPost,) =
            abi.decode(tm.getLensData(9, abi.encode(pid, syntheticBountyToken)), (uint256, uint256));
        require(bountyCapPost == 7 ether, "DryRun: executor BOUNTY_CAP edit did not land");
        console.log("Executor BOUNTY_CAP edit OK (cap=7 ether)");

        // 5l. Executor can grant the new BUDGET permission to a hat (admin path).
        uint256 syntheticHat = uint256(keccak256("dryrun-budget-hat"));
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(syntheticHat, TaskPerm.BUDGET));
        console.log("Executor granted TaskPerm.BUDGET to hat");

        // 5m. ORGANIZER_HAT_ALLOWED is still executor-only — guards against the
        //     subtle auto-merge regression where moving _requireExecutor() per
        //     branch could leave the new key permissionless.
        vm.prank(randomBudgetCaller);
        (bool okOrg, bytes memory orgRet) = proxy.call(
            abi.encodeCall(
                TaskManager.setConfig,
                (TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(uint256(987654321), true))
            )
        );
        require(!okOrg, "DryRun: ORGANIZER_HAT_ALLOWED must reject non-executor");
        require(
            bytes4(orgRet) == TaskManager.NotExecutor.selector, "DryRun: ORGANIZER_HAT_ALLOWED must revert NotExecutor"
        );
        console.log("ORGANIZER_HAT_ALLOWED still executor-only OK");
    }
}
