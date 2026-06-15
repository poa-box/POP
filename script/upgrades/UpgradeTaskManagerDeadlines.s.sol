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
 * TaskManager Upgrade — Deadlines & Claim Takeover (v6)
 * ============================================================================
 *
 * Adds three Task fields (append-only; pre-v6 tasks read zeros = "no deadlines"):
 *   uint48 absoluteDeadline  — unix cutoff for any claim (0 = none)
 *   uint32 completionWindow  — per-claim submission window in seconds (0 = none)
 *   uint48 claimDeadline     — current claim's deadline, set per claim/assign/approve
 *
 * Lenient enforcement: submitTask is NEVER blocked. An expired claim (claimDeadline
 * or absoluteDeadline strictly passed while CLAIMED) simply loses protection —
 * claimTask / assignTask / approveApplication take the task over directly, emitting
 * TaskClaimExpired before the normal lifecycle event. rejectTask restarts the
 * window. updateTask can adjust both knobs (a PAST absoluteDeadline is allowed
 * there: the admin lever that opens an abandoned CLAIMED task to takeover).
 *
 * SIGNATURE CHANGES (selectors replaced; paymaster + frontend ship in lockstep):
 *   createTask           0x22fa79bc -> 0x4d0265d4 (…,bool,uint48,uint32)
 *   createTasksBatch     0xc18aa1c9 -> 0xf31d148f (CreateTaskInput +2 fields)
 *   createAndAssignTask  0xaf425951 -> 0x98e30e89 (…,bool,uint48,uint32)
 *   updateTask           0x48db6f65 -> 0xb7c288e8 (…,uint256,uint48,uint32)
 * New events (existing event signatures untouched):
 *   TaskDeadlinesSet(uint256 indexed,uint48,uint32)
 *   TaskClaimDeadlineSet(uint256 indexed,uint48)
 *   TaskClaimExpired(uint256 indexed,address indexed,address indexed)
 *
 * No Layout struct change (only the Task mapping value grows, end-append) — no
 * reinitializer needed.
 *
 * Version selection (CLAUDE.md probing recipe, both surfaces, both chains, 2026-06-09):
 *   TaskManager: registry has 4 versions on Gnosis AND Arbitrum; v5 TAKEN
 *   (registry + CREATE2) on both; v6 FREE on both surfaces on both chains
 *   (predicted 0x7833c4670C42dbCe1a7aB1BAB7e7Baf0A982ff57).
 *
 * Three-step cross-chain upgrade pattern (mirrors UpgradeTaskManagerEditPerms):
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis after Hyperlane relay (~5 min)
 *
 * Companion ops (broadcast in the same window — old selectors die at upgrade):
 *   - UpgradeOrgDeployerDeadlineRules (v15): new orgs auto-whitelist v6 selectors
 *   - WhitelistTaskDeadlineRules{Poa,Test6Kubi,DecentralPark}ViaGovernance:
 *     retroactive per-org paymaster rules (4 new allowed, 4 dead disallowed)
 *
 * Usage (sim first — CLAUDE.md requires PASS before broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerDeadlines.s.sol:DryRun_GnosisUpgrade --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerDeadlines.s.sol:DryRun_ArbitrumUpgrade --fork-url arbitrum -vvv
 *
 * Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerDeadlines.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerDeadlines.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 *   forge script script/upgrades/UpgradeTaskManagerDeadlines.s.sol:Step3_VerifyGnosis --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
// PoaManager on Arbitrum (read once via Hub.poaManager(); hardcoded for the DryRun).
address constant ARBITRUM_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub (Arbitrum), PoaManagerSatellite (Gnosis), DeterministicDeployer.
// Hardcoded per CLAUDE.md: prank as it, don't read owner() mid-fork.
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
// PoaManagerSatellite on Gnosis — owner of the Gnosis PoaManager. The DryRun pranks it
// directly; in production it invokes upgradeBeacon when the Hyperlane message relays.
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
// v5 (edit perms) is the latest registered impl on both chains. v6 probed FREE on both
// surfaces (registry + CREATE2) on both chains 2026-06-09.
string constant VERSION = "v6";

/**
 * @title Step1_DeployImplOnGnosis
 * @notice Deploy TaskManager v6 implementation on Gnosis via DD.
 */
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v6 impl on Gnosis ===");
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
            console.log("PASS: TaskManager upgraded to v6 on Gnosis");
            console.log("\nNew capabilities:");
            console.log("  - absoluteDeadline + completionWindow on create/update (new selectors)");
            console.log("  - claimTask/assignTask/approveApplication take over expired claims");
            console.log("  - rejectTask restarts the claim window; submitTask never deadline-blocked");
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
 * @title DeadlineDryRunBase
 * @notice Shared fork-sim: deploys v6 via DD (prank Hudson), upgrades the chain's
 *         beacon, then exercises deadlines + takeover against a live TaskManager proxy.
 *
 *         Asserts:
 *           1. DD-predicted address matches deployed address.
 *           2. PoaManager beacon updates to the new impl.
 *           3. New createTask v6 selector (0x4d0265d4) present in impl bytecode.
 *           4. Live proxy:
 *              a. Storage preserved (executor survives the impl swap).
 *              b. Pre-v6 tasks read zero deadlines via the appended lens fields.
 *              c. Born-expired absoluteDeadline reverts InvalidDeadline at create.
 *              d. Window task: assignment sets claimDeadline = now + window.
 *              e. Expiry boundary: at the deadline second the claim is protected;
 *                 one second later a takeover claim succeeds (claimer switches,
 *                 fresh window).
 *              f. Late submit by the NEW claimer works (lenient), task completes.
 *              g. updateTask window edit preserves the original claim start.
 *              h. Pre-v6-style CLAIMED task (no deadlines) is NOT takeover-able.
 */
abstract contract DeadlineDryRunBase is Script {
    // OrgRegistry CREATE2 address (holds org #0 on Gnosis; the Arbitrum instance has no
    // registrations — the Arbitrum DryRun resolves the Poa proxy from verified constants).
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function _poaManager() internal pure virtual returns (address);
    function _upgradeBeacon(address newImpl) internal virtual;
    function _chainName() internal pure virtual returns (string memory);
    /// @dev Resolve a live TaskManager proxy to exercise on this chain's fork.
    function _liveProxy() internal view virtual returns (address);

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v6 (deadlines) upgrade on", _chainName(), "fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(_poaManager());

        // 1. Pre-state snapshot.
        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        // 2. Step1/Step2 simulation: deploy v6 impl via DD (Hudson owns DD on both chains).
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
            vm.prank(HUDSON_ADMIN);
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            console.log("Already deployed at predicted (skipping deploy)");
            deployed = predicted;
        }
        require(deployed == predicted, "DryRun: DD address mismatch");
        require(deployed.code.length > 0, "DryRun: impl code missing");
        console.log("Deployed impl:", deployed);

        // 3. Beacon upgrade as the chain's real production caller.
        _upgradeBeacon(deployed);
        address implAfter = pm.getCurrentImplementationById(keccak256("TaskManager"));
        require(implAfter == deployed, "DryRun: beacon upgrade did not stick");
        console.log("Impl after :", implAfter);

        // 4. v6 createTask selector present in impl bytecode.
        bytes4 sel = TaskManager.createTask.selector; // 0x4d0265d4 in v6
        bytes memory code = deployed.code;
        bool found = false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                found = true;
                break;
            }
        }
        require(found, "DryRun: v6 createTask selector missing from impl bytecode");
        console.log("v6 createTask selector present in impl bytecode");

        // 5. Live-proxy exercise.
        _exerciseLiveProxy();

        console.log("\n=== ALL DRY-RUN CHECKS PASSED ===");
        console.log("Safe to broadcast Step1/Step2/Step3 against mainnet.");
    }

    function _exerciseLiveProxy() internal {
        address proxy = _liveProxy();
        require(proxy != address(0), "DryRun: no TaskManager proxy to exercise");
        TaskManager tm = TaskManager(proxy);

        console.log("\n--- Live-proxy exercise ---");
        console.log("TaskManager proxy:", proxy);

        // 5a. Storage preservation.
        address executor = abi.decode(tm.getLensData(4, ""), (address));
        require(executor != address(0), "DryRun: executor unset post-upgrade (storage drift?)");
        console.log("Executor (preserved):", executor);

        // 5b. Pre-v6 task zero-state: any pre-existing task must read zero deadlines.
        uint256 preExisting = _nextAvailableTaskId(proxy);
        if (preExisting > 0) {
            (,, uint48 cd0, uint48 abs0, uint32 win0) = _readDeadlines(tm, 0);
            require(abs0 == 0 && win0 == 0 && cd0 == 0, "DryRun: pre-v6 task has nonzero deadlines");
            console.log("Pre-v6 task 0 reads zero deadlines OK");
        } else {
            console.log("(org has no pre-existing tasks; zero-state check vacuous)");
        }

        // 5c. Fresh project for the exercise (executor bypasses _requireCreator).
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("dryrun-deadlines"),
            metadataHash: bytes32(0),
            cap: 0,
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

        // 5d. Born-expired absolute deadline reverts at create.
        vm.prank(executor);
        (bool okBorn,) = proxy.call(
            abi.encodeCall(
                TaskManager.createTask,
                (
                    1 ether,
                    bytes("born-expired"),
                    bytes32(0),
                    pid,
                    address(0),
                    0,
                    false,
                    uint48(vm.getBlockTimestamp()),
                    0
                )
            )
        );
        require(!okBorn, "DryRun: born-expired create must revert InvalidDeadline");
        console.log("Born-expired create reverts OK");

        // 5e. Window task: create + assign, deadline = now + window.
        uint32 window = 3 days;
        uint256 taskId = _nextAvailableTaskId(proxy);
        address claimerA = makeAddr("dryrun-claimer-a");
        vm.prank(executor);
        tm.createTask(2 ether, bytes("windowed"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(taskId, claimerA);

        (address claimer1,, uint48 cd1,, uint32 win1) = _readDeadlines(tm, taskId);
        require(claimer1 == claimerA, "DryRun: assignee wrong");
        require(win1 == window, "DryRun: window not stored");
        require(cd1 == uint48(vm.getBlockTimestamp()) + window, "DryRun: claimDeadline != now + window");
        console.log("Assignment started the claim window OK");

        // 5f. Boundary: protected at the deadline second, takeover-able one second later.
        vm.warp(uint256(cd1));
        vm.prank(executor);
        (bool okEarly,) = proxy.call(abi.encodeCall(TaskManager.claimTask, (taskId)));
        require(!okEarly, "DryRun: claim at the deadline second must stay protected");

        vm.warp(uint256(cd1) + 1);
        vm.prank(executor);
        tm.claimTask(taskId); // executor takes the task over (PM bypass covers CLAIM perm)
        (address claimer2,, uint48 cd2,,) = _readDeadlines(tm, taskId);
        require(claimer2 == executor, "DryRun: takeover did not switch claimer");
        require(cd2 == uint48(vm.getBlockTimestamp()) + window, "DryRun: takeover did not restart window");
        console.log("Expiry boundary + takeover OK (claimer A -> executor, fresh window)");

        // 5g. Lenient: the new claimer submits AFTER its own deadline, then completes.
        vm.warp(uint256(cd2) + 12 hours);
        vm.prank(executor);
        tm.submitTask(taskId, keccak256("late-but-fine"));
        vm.prank(executor);
        tm.completeTask(taskId);
        console.log("Late submit + complete OK (lenient enforcement)");

        // 5h. updateTask window edit preserves the claim start.
        uint256 task2 = _nextAvailableTaskId(proxy);
        vm.prank(executor);
        tm.createTask(1 ether, bytes("arith"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(task2, claimerA);
        uint48 claimStart = uint48(vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint32 newWindow = 10 days;
        vm.prank(executor);
        tm.updateTask(task2, 1 ether, bytes("arith"), bytes32(0), address(0), 0, 0, newWindow);
        (,, uint48 cdAdj,, uint32 winAdj) = _readDeadlines(tm, task2);
        require(winAdj == newWindow, "DryRun: window not updated");
        require(cdAdj == claimStart + newWindow, "DryRun: window edit lost the claim start");
        console.log("updateTask window arithmetic OK (claim start preserved)");

        // 5i. Pre-v6-style CLAIMED task (no deadlines) stays protected forever.
        uint256 task3 = _nextAvailableTaskId(proxy);
        vm.prank(executor);
        tm.createTask(1 ether, bytes("no-deadlines"), bytes32(0), pid, address(0), 0, false, 0, 0);
        vm.prank(executor);
        tm.assignTask(task3, claimerA);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(executor);
        (bool okSteal,) = proxy.call(abi.encodeCall(TaskManager.claimTask, (task3)));
        require(!okSteal, "DryRun: deadline-less claim must never be takeover-able");
        console.log("Deadline-less CLAIMED task stays protected OK");
    }

    /// @dev Finds the next unused task id by probing the lens.
    function _nextAvailableTaskId(address proxy) internal view returns (uint256) {
        for (uint256 i; i < 1_000_000; ++i) {
            (bool ok,) =
                proxy.staticcall(abi.encodeWithSelector(TaskManager.getLensData.selector, uint8(1), abi.encode(i)));
            if (!ok) return i;
        }
        revert("DryRun: nextAvailableTaskId search exhausted");
    }

    function _readDeadlines(TaskManager tm, uint256 id)
        internal
        view
        returns (address claimer, TaskManager.Status status, uint48 claimDeadline, uint48 absDeadline, uint32 window)
    {
        bytes memory data = tm.getLensData(1, abi.encode(id));
        // tuple: (projectId, payout, claimer, bountyPayout, requiresApplication, status,
        //         bountyToken, absoluteDeadline, completionWindow, claimDeadline)
        (,, claimer,,, status,, absDeadline, window, claimDeadline) = abi.decode(
            data, (bytes32, uint96, address, uint96, bool, TaskManager.Status, address, uint48, uint32, uint48)
        );
    }
}

/**
 * @title DryRun_GnosisUpgrade
 * @notice v6 dry run on a Gnosis fork (beacon upgraded by pranking the Satellite —
 *         the real production caller after the Hyperlane relay).
 */
contract DryRun_GnosisUpgrade is DeadlineDryRunBase {
    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _chainName() internal pure override returns (string memory) {
        return "Gnosis";
    }

    function _upgradeBeacon(address newImpl) internal override {
        vm.prank(GNOSIS_SATELLITE);
        PoaManager(GNOSIS_POA_MANAGER).upgradeBeacon("TaskManager", newImpl, VERSION);
    }

    function _liveProxy() internal view override returns (address) {
        IOrgRegistry reg = IOrgRegistry(ORG_REGISTRY);
        return reg.proxyOf(reg.orgIds(0), keccak256("TaskManager"));
    }
}

/**
 * @title DryRun_ArbitrumUpgrade
 * @notice v6 dry run on an Arbitrum fork (beacon upgraded through the Hub exactly
 *         like Step2, pranking Hudson as Hub owner).
 */
contract DryRun_ArbitrumUpgrade is DeadlineDryRunBase {
    function _poaManager() internal pure override returns (address) {
        return ARBITRUM_POA_MANAGER;
    }

    function _chainName() internal pure override returns (string memory) {
        return "Arbitrum";
    }

    function _upgradeBeacon(address newImpl) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}("TaskManager", newImpl, VERSION);
    }

    function _liveProxy() internal pure override returns (address) {
        // Poa's TaskManager on Arbitrum — verified constant (same source as the
        // WhitelistTaskDeadlineRulesPoaViaGovernance script); the Arbitrum OrgRegistry
        // instance holds no registrations to resolve from.
        return 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
    }
}
