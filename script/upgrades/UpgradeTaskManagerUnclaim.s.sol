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
 * TaskManager v7 — unclaimTask (release a claimed task back to the pool)
 * ============================================================================
 *
 * ADDITIVE ONLY. New external `unclaimTask(uint256)` (0x6103955a) + new event
 * TaskUnclaimed(uint256 indexed,address indexed,address indexed). No Layout change,
 * no Task field, no Status member, no existing selector touched — v6 callers are
 * unaffected and the frontend/subgraph can ship after this lands.
 *
 * Semantics: CLAIMED -> UNCLAIMED, claimer zeroed, claimDeadline cleared.
 *   - the claimer may always release (no permission check);
 *   - anyone else needs ASSIGN on the project AND an expired claim (assignTask's
 *     takeover gate with no replacement claimer named).
 * SUBMITTED is excluded; budgets and application hashes are untouched.
 *
 *   Live impl: v6 (0x7833c4670C42dbCe1a7aB1BAB7e7Baf0A982ff57, both chains)
 *   This PR:   v7
 *
 * Version selection (CLAUDE.md recipe, both surfaces, both chains, 2026-07-31):
 *   Gnosis   registry count=5; v6 TAKEN (registry+CREATE2); v7 FREE on both.
 *   Arbitrum registry count=5; v6 TAKEN (registry+CREATE2); v7 FREE on both.
 *   Predicted v7 impl (identical on both chains): 0xcfAe1DAdF1A48b363aAD3BbB8f94f67bb3785988
 *
 * Existing orgs also need the paymaster rule for the new selector (separate
 * per-org governance batch); OrgDeployer v18 covers NEW orgs.
 *
 * Sim first (CLAUDE.md requires PASS before broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerUnclaim.s.sol:DryRun_GnosisUpgrade --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerUnclaim.s.sol:DryRun_ArbitrumUpgrade --fork-url arbitrum -vvv
 *
 * Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerUnclaim.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTaskManagerUnclaim.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 *   forge script script/upgrades/UpgradeTaskManagerUnclaim.s.sol:Step3_VerifyGnosis --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant ARBITRUM_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub (Arbitrum), PoaManagerSatellite (Gnosis), DeterministicDeployer.
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
// PoaManagerSatellite on Gnosis — owner of the Gnosis PoaManager; the real caller post-relay.
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
string constant VERSION = "v7";

contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy TaskManager v7 impl on Gnosis ===");
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
        console.log("\n=== Step 2: Upgrade TaskManager to v7 from Arbitrum ===");
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

contract Step3_VerifyGnosis is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address expectedImpl = dd.computeAddress(dd.computeSalt("TaskManager", VERSION));
        address currentImpl = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("TaskManager"));

        console.log("\n=== Step 3: Verify Gnosis TaskManager v7 Upgrade ===");
        console.log("Expected impl:", expectedImpl);
        console.log("Current impl: ", currentImpl);

        if (currentImpl == expectedImpl) {
            console.log("PASS: TaskManager upgraded to v7 on Gnosis");
            console.log("  unclaimTask(uint256) 0x6103955a is live");
            console.log("  NOTE: existing orgs still need the paymaster rule for that selector.");
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
 * @title UnclaimDryRunBase
 * @notice Fork-sim: deploy v7 via DD (prank Hudson), upgrade the chain's beacon, then
 *         exercise unclaimTask against a LIVE TaskManager proxy.
 *
 *         Asserts: DD address match; beacon switch; unclaimTask selector present in the
 *         impl bytecode; storage preserved; then on the live proxy — self-release clears
 *         status/claimer/claimDeadline, budgets unchanged, re-claim works, a live claim
 *         is protected from a third party, an expired one is releasable by ASSIGN, a
 *         SUBMITTED task is never releasable, and cancelTask refunds exactly once.
 */
abstract contract UnclaimDryRunBase is Script {
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function _poaManager() internal pure virtual returns (address);
    function _upgradeBeacon(address newImpl) internal virtual;
    function _chainName() internal pure virtual returns (string memory);
    function _liveProxy() internal view virtual returns (address);

    function run() public {
        console.log("\n=== DRY RUN: TaskManager v7 (unclaimTask) on", _chainName(), "fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(_poaManager());

        address implBefore = pm.getCurrentImplementationById(keccak256("TaskManager"));
        console.log("Impl before:", implBefore);

        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("DD predicted impl:", predicted);
        require(implBefore != predicted, "DryRun: v7 already live (nothing to upgrade)");

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

        _upgradeBeacon(deployed);
        address implAfter = pm.getCurrentImplementationById(keccak256("TaskManager"));
        require(implAfter == deployed, "DryRun: beacon upgrade did not stick");
        console.log("Impl after :", implAfter);

        require(_hasSelector(deployed, TaskManager.unclaimTask.selector), "DryRun: unclaimTask selector missing");
        console.log("unclaimTask selector present in impl bytecode");

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

        // Storage preservation across the impl swap.
        address executor = abi.decode(tm.getLensData(4, ""), (address));
        require(executor != address(0), "DryRun: executor unset post-upgrade (storage drift?)");
        console.log("Executor (preserved):", executor);

        bytes32 pid = _freshProject(tm, executor);
        uint32 window = 3 days;
        address workerA = makeAddr("dryrun-worker-a");

        _checkSelfRelease(tm, proxy, pid, executor, window, workerA);
        _checkThirdPartyRelease(tm, proxy, pid, executor, window, workerA);
        _checkSubmittedNeverReleasable(tm, proxy, pid, executor, window, workerA);
        _checkCancelAfterRelease(tm, proxy, pid, executor, window, workerA);
    }

    function _freshProject(TaskManager tm, address executor) internal returns (bytes32 pid) {
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("dryrun-unclaim"),
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
        pid = tm.createProject(cfg);
        console.log("Test project pid:", vm.toString(pid));
    }

    /// @dev The assignee holds no hat at all, so this also proves the release is identity-gated.
    function _checkSelfRelease(
        TaskManager tm,
        address proxy,
        bytes32 pid,
        address executor,
        uint32 window,
        address worker
    ) internal {
        uint256 id = _nextAvailableTaskId(proxy);
        uint128 spentBefore = _projectSpent(tm, pid);

        vm.prank(executor);
        tm.createTask(1 ether, bytes("self-release"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(id, worker);

        (address claimer,, uint48 cd,,) = _readTask(tm, id);
        require(claimer == worker, "DryRun: assignee wrong");
        require(cd == uint48(vm.getBlockTimestamp()) + window, "DryRun: window not started");

        vm.prank(worker);
        tm.unclaimTask(id);

        (address claimerAfter, TaskManager.Status st, uint48 cdAfter, uint48 abs_, uint32 win_) = _readTask(tm, id);
        require(st == TaskManager.Status.UNCLAIMED, "DryRun: status not UNCLAIMED after release");
        require(claimerAfter == address(0), "DryRun: claimer not cleared");
        require(cdAfter == 0, "DryRun: claimDeadline not cleared");
        require(abs_ == 0 && win_ == window, "DryRun: task deadline config must survive the release");
        require(_projectSpent(tm, pid) == spentBefore + 1 ether, "DryRun: release must not refund the budget");
        console.log("Self-release OK (status/claimer/claimDeadline cleared, budget held)");

        // ...and the task is genuinely back in the pool.
        vm.prank(executor);
        tm.assignTask(id, worker);
        (address reclaimed,, uint48 cdNew,,) = _readTask(tm, id);
        require(reclaimed == worker, "DryRun: released task not re-assignable");
        require(cdNew == uint48(vm.getBlockTimestamp()) + window, "DryRun: re-assign did not restart the window");
        console.log("Re-assignment after release OK (fresh window)");
    }

    function _checkThirdPartyRelease(
        TaskManager tm,
        address proxy,
        bytes32 pid,
        address executor,
        uint32 window,
        address worker
    ) internal {
        uint256 id = _nextAvailableTaskId(proxy);
        vm.prank(executor);
        tm.createTask(1 ether, bytes("third-party"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(id, worker);
        (,, uint48 cd,,) = _readTask(tm, id);

        // Protected right up to and including the deadline second.
        vm.warp(uint256(cd));
        vm.prank(executor); // executor carries the PM bypass, i.e. ASSIGN
        (bool okEarly,) = proxy.call(abi.encodeCall(TaskManager.unclaimTask, (id)));
        require(!okEarly, "DryRun: a live claim must not be releasable by a third party");

        // A stranger is rejected even after expiry.
        vm.warp(uint256(cd) + 1);
        vm.prank(makeAddr("dryrun-stranger"));
        (bool okStranger,) = proxy.call(abi.encodeCall(TaskManager.unclaimTask, (id)));
        require(!okStranger, "DryRun: no-permission caller must not release");

        vm.prank(executor);
        tm.unclaimTask(id);
        (address claimerAfter, TaskManager.Status st,,,) = _readTask(tm, id);
        require(st == TaskManager.Status.UNCLAIMED && claimerAfter == address(0), "DryRun: expired release failed");
        console.log("Third-party release OK (protected while live, ASSIGN-only, works once expired)");
    }

    function _checkSubmittedNeverReleasable(
        TaskManager tm,
        address proxy,
        bytes32 pid,
        address executor,
        uint32 window,
        address worker
    ) internal {
        uint256 id = _nextAvailableTaskId(proxy);
        vm.prank(executor);
        tm.createTask(1 ether, bytes("submitted"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(id, worker);
        vm.prank(worker);
        tm.submitTask(id, keccak256("dryrun-work"));

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(worker);
        (bool okClaimer,) = proxy.call(abi.encodeCall(TaskManager.unclaimTask, (id)));
        require(!okClaimer, "DryRun: SUBMITTED must not be releasable by the claimer");
        vm.prank(executor);
        (bool okExec,) = proxy.call(abi.encodeCall(TaskManager.unclaimTask, (id)));
        require(!okExec, "DryRun: SUBMITTED must not be releasable by an ASSIGN holder");

        // rejectTask is the sanctioned route back to CLAIMED, and then it releases.
        vm.prank(executor);
        tm.rejectTask(id, keccak256("dryrun-redo"));
        vm.prank(worker);
        tm.unclaimTask(id);
        (, TaskManager.Status st,,,) = _readTask(tm, id);
        require(st == TaskManager.Status.UNCLAIMED, "DryRun: reject-then-release failed");
        console.log("SUBMITTED guard OK (blocked, releasable only after rejectTask)");
    }

    function _checkCancelAfterRelease(
        TaskManager tm,
        address proxy,
        bytes32 pid,
        address executor,
        uint32 window,
        address worker
    ) internal {
        uint128 spentBefore = _projectSpent(tm, pid);
        uint256 id = _nextAvailableTaskId(proxy);

        vm.prank(executor);
        tm.createTask(1 ether, bytes("cancel-after"), bytes32(0), pid, address(0), 0, false, 0, window);
        vm.prank(executor);
        tm.assignTask(id, worker);
        vm.prank(worker);
        tm.unclaimTask(id);
        vm.prank(executor);
        tm.cancelTask(id);

        (, TaskManager.Status st,,,) = _readTask(tm, id);
        require(st == TaskManager.Status.CANCELLED, "DryRun: cancel after release failed");
        require(_projectSpent(tm, pid) == spentBefore, "DryRun: cancel must refund exactly once");
        console.log("cancelTask after release OK (reservation refunded exactly once)");
    }

    function _hasSelector(address impl, bytes4 sel) internal view returns (bool) {
        bytes memory code = impl.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    function _projectSpent(TaskManager tm, bytes32 pid) internal view returns (uint128 spent) {
        (, spent,) = abi.decode(tm.getLensData(2, abi.encode(pid)), (uint128, uint128, bool));
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

    function _readTask(TaskManager tm, uint256 id)
        internal
        view
        returns (address claimer, TaskManager.Status status, uint48 claimDeadline, uint48 absDeadline, uint32 window)
    {
        bytes memory data = tm.getLensData(1, abi.encode(id));
        (,, claimer,,, status,, absDeadline, window, claimDeadline) = abi.decode(
            data, (bytes32, uint96, address, uint96, bool, TaskManager.Status, address, uint48, uint32, uint48)
        );
    }
}

/// @notice v7 dry run on a Gnosis fork (beacon upgraded by pranking the Satellite).
contract DryRun_GnosisUpgrade is UnclaimDryRunBase {
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

/// @notice v7 dry run on an Arbitrum fork (beacon upgraded through the Hub exactly like Step2).
contract DryRun_ArbitrumUpgrade is UnclaimDryRunBase {
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
        // Poa's TaskManager on Arbitrum — verified constant (the Arbitrum OrgRegistry
        // instance holds no registrations to resolve from).
        return 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
    }
}
