// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * TaskManager v4 Integration Sim — hat-wearer paths for BOTH features
 * ============================================================================
 *
 * Complements `UpgradeTaskManagerFolders.s.sol:DryRun_GnosisUpgrade`, which
 * exercises the executor (governance / vote) path. This sim deliberately
 * targets the *hat-wearer* paths that the unit tests cover in MockHats — but
 * here against real production state on a Gnosis fork.
 *
 * Strategy: after the v4 upgrade is applied, we etch a controllable Hats mock
 * over the org's Hats Protocol address. The mock answers `balanceOfBatch`
 * truthfully for one designated test EOA + hat pair, and zero everywhere
 * else. This lets us prove the new hat-gated code paths actually grant access
 * on real, upgraded bytecode — not just under MockHats in unit tests.
 *
 * Scenarios:
 *   1. Executor grants TaskPerm.BUDGET to a chosen hat and adds the same hat
 *      to organizerHatIds. (Realistic config: a single "project lead" hat
 *      gets both powers.)
 *   2. Test EOA wears that hat. Edits PROJECT_CAP — succeeds (budget feature).
 *   3. Test EOA edits BOUNTY_CAP — succeeds (budget feature).
 *   4. Test EOA calls setFolders with CAS guard zero — succeeds (folders feature).
 *   5. Test EOA chains a follow-up setFolders update — succeeds.
 *   6. Test EOA still CANNOT touch admin keys (EXECUTOR / CREATOR_HAT_ALLOWED /
 *      ROLE_PERM / PROJECT_MANAGER / ORGANIZER_HAT_ALLOWED) — reverts NotExecutor.
 *   7. A *different* random EOA (not wearing the hat) — reverts Unauthorized
 *      on budget edit and NotOrganizer on folders edit.
 *
 * Does not broadcast.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/SimTaskManagerV4Integration.s.sol:Sim_HatWearerIntegration \
 *     --fork-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
string constant VERSION = "v4";
address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

interface IOrgRegistry {
    function orgIds(uint256 index) external view returns (bytes32);
    function proxyOf(bytes32 orgId, bytes32 typeId) external view returns (address);
}

/// @dev Minimal Hats stand-in that grants a single (wearer, hatId) pair.
/// Etched over the org's real Hats address for the duration of the sim so
/// that `balanceOfBatch` and `balanceOf` return 1 only for the configured
/// pair and zero everywhere else. The wearer/hat pair is read from storage
/// slots 0 and 1 — set via `vm.store`, not a constructor (we're etching
/// bytecode, not deploying).
contract HatsShim {
    // slot 0: address wearer
    // slot 1: uint256 hatId

    function balanceOf(address user, uint256 hatId) external view returns (uint256) {
        address w;
        uint256 h;
        assembly {
            w := sload(0)
            h := sload(1)
        }
        if (user == w && hatId == h) return 1;
        return 0;
    }

    function balanceOfBatch(address[] calldata users, uint256[] calldata hatIds)
        external
        view
        returns (uint256[] memory bal)
    {
        require(users.length == hatIds.length, "len mismatch");
        address w;
        uint256 h;
        assembly {
            w := sload(0)
            h := sload(1)
        }
        bal = new uint256[](users.length);
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == w && hatIds[i] == h) bal[i] = 1;
        }
    }

    function isWearerOfHat(address user, uint256 hatId) external view returns (bool) {
        return this.balanceOf(user, hatId) > 0;
    }
}

contract Sim_HatWearerIntegration is Script {
    function run() public {
        console.log("\n=== INTEGRATION SIM: TaskManager v4 hat-wearer paths on Gnosis fork ===\n");

        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManager pm = PoaManager(GNOSIS_POA_MANAGER);

        IOrgRegistry reg = IOrgRegistry(ORG_REGISTRY);
        bytes32 orgId = reg.orgIds(0);
        address proxy = reg.proxyOf(orgId, keccak256("TaskManager"));
        require(proxy != address(0), "Sim: no TaskManager proxy for org 0");
        TaskManager tm = TaskManager(proxy);

        console.log("orgId:", vm.toString(orgId));
        console.log("TaskManager proxy:", proxy);

        // ─── Apply the v4 upgrade ─────────────────────────────────────────────
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);
        address deployed;
        if (predicted.code.length == 0) {
            vm.prank(DeterministicDeployer(DD).owner());
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            deployed = predicted;
        }
        require(deployed == predicted, "Sim: DD address mismatch");

        vm.prank(pm.owner());
        pm.upgradeBeacon("TaskManager", deployed, VERSION);
        require(
            pm.getCurrentImplementationById(keccak256("TaskManager")) == deployed, "Sim: beacon upgrade did not stick"
        );
        console.log("v4 impl deployed and beacon swapped:", deployed);

        // ─── Read org state ────────────────────────────────────────────────────
        address executor = abi.decode(tm.getLensData(4, ""), (address));
        address hatsAddr = abi.decode(tm.getLensData(3, ""), (address));
        console.log("Executor:", executor);
        console.log("Hats:", hatsAddr);

        // ─── Etch the HatsShim over the real Hats address ─────────────────────
        // We do this AFTER the upgrade so the upgrade itself runs against real
        // Hats. Once we're testing user paths, the shim is sufficient.
        address testEoa = makeAddr("hatWearerEoa");
        uint256 testHat = uint256(keccak256("sim-v4-shared-hat"));
        HatsShim shimImpl = new HatsShim();
        vm.etch(hatsAddr, address(shimImpl).code);
        vm.store(hatsAddr, bytes32(uint256(0)), bytes32(uint256(uint160(testEoa))));
        vm.store(hatsAddr, bytes32(uint256(1)), bytes32(testHat));
        console.log("HatsShim etched at", hatsAddr);
        console.log("Test EOA wears hat:", testEoa, "hat:", testHat);

        // ─── Executor grants the hat both powers ──────────────────────────────
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(testHat, TaskPerm.BUDGET));
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(testHat, true));
        console.log("Executor granted TaskPerm.BUDGET + organizer status to test hat");

        // ─── Create a fresh project for the test EOA to mutate ────────────────
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("sim-v4-integration"),
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
        console.log("Fresh project pid:", vm.toString(pid));

        // ─── Scenario 2: hat-wearer edits PROJECT_CAP ─────────────────────────
        vm.prank(testEoa);
        tm.setConfig(TaskManager.ConfigKey.PROJECT_CAP, abi.encode(pid, uint256(20 ether)));
        (uint256 capAfter,,) = abi.decode(tm.getLensData(2, abi.encode(pid)), (uint256, uint256, bool));
        require(capAfter == 20 ether, "Sim 2: hat-wearer PROJECT_CAP edit did not land");
        console.log("2. Hat-wearer PROJECT_CAP edit OK (cap=20 ether)");

        // ─── Scenario 3: hat-wearer edits BOUNTY_CAP ──────────────────────────
        address syntheticBountyToken = address(uint160(uint256(keccak256("sim-bounty-token"))));
        vm.prank(testEoa);
        tm.setConfig(TaskManager.ConfigKey.BOUNTY_CAP, abi.encode(pid, syntheticBountyToken, uint256(3 ether)));
        (uint256 bountyCap,) = abi.decode(tm.getLensData(9, abi.encode(pid, syntheticBountyToken)), (uint256, uint256));
        require(bountyCap == 3 ether, "Sim 3: hat-wearer BOUNTY_CAP edit did not land");
        console.log("3. Hat-wearer BOUNTY_CAP edit OK (cap=3 ether)");

        // ─── Scenario 4: hat-wearer publishes folders root ────────────────────
        bytes32 rootInitial = abi.decode(tm.getLensData(10, ""), (bytes32));
        bytes32 newRoot = keccak256("sim-folders-root-1");
        vm.prank(testEoa);
        tm.setFolders(rootInitial, newRoot);
        require(abi.decode(tm.getLensData(10, ""), (bytes32)) == newRoot, "Sim 4: setFolders did not land");
        console.log("4. Hat-wearer setFolders OK (CAS-guarded against current root)");

        // ─── Scenario 5: hat-wearer chains a follow-up update ─────────────────
        bytes32 chainedRoot = keccak256("sim-folders-root-2");
        vm.prank(testEoa);
        tm.setFolders(newRoot, chainedRoot);
        require(abi.decode(tm.getLensData(10, ""), (bytes32)) == chainedRoot, "Sim 5: chained setFolders did not land");
        console.log("5. Hat-wearer chained setFolders OK");

        // ─── Scenario 6: hat-wearer cannot touch admin keys ───────────────────
        _scenario6_adminKeysBlocked(proxy, testEoa, pid);

        // ─── Scenario 7: a DIFFERENT EOA (no hat) is rejected on both ─────────
        address randomEoa = makeAddr("randomNoHatEoa");

        vm.prank(randomEoa);
        (bool okBudget, bytes memory budgetRet) = proxy.call(
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.PROJECT_CAP, abi.encode(pid, uint256(99 ether)))
            )
        );
        require(!okBudget, "Sim 7a: random EOA must revert on PROJECT_CAP");
        require(bytes4(budgetRet) == TaskManager.Unauthorized.selector, "Sim 7a: expected Unauthorized");
        console.log("7a. Random EOA -> Unauthorized on PROJECT_CAP OK");

        vm.prank(randomEoa);
        (bool okFolders, bytes memory foldersRet) =
            proxy.call(abi.encodeCall(TaskManager.setFolders, (chainedRoot, keccak256("evil"))));
        require(!okFolders, "Sim 7b: random EOA must revert on setFolders");
        require(bytes4(foldersRet) == TaskManager.NotOrganizer.selector, "Sim 7b: expected NotOrganizer");
        console.log("7b. Random EOA -> NotOrganizer on setFolders OK");

        console.log("\n=== ALL HAT-WEARER INTEGRATION CHECKS PASSED ===");
        console.log("v4 hat-paths verified end-to-end against real Gnosis state.");
    }

    function _scenario6_adminKeysBlocked(address proxy, address testEoa, bytes32 pid) internal {
        bytes[5] memory calls = [
            abi.encodeCall(TaskManager.setConfig, (TaskManager.ConfigKey.EXECUTOR, abi.encode(makeAddr("ignored")))),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(uint256(0xdead), true))
            ),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(0xbeef), uint8(0xFF)))
            ),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.PROJECT_MANAGER, abi.encode(pid, testEoa, true))
            ),
            abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(uint256(0xcafe), true))
            )
        ];
        string[5] memory labels =
            ["EXECUTOR", "CREATOR_HAT_ALLOWED", "ROLE_PERM", "PROJECT_MANAGER", "ORGANIZER_HAT_ALLOWED"];

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(testEoa);
            (bool ok, bytes memory ret) = proxy.call(calls[i]);
            require(!ok, "Sim 6: admin key did not revert for hat-wearer");
            require(
                bytes4(ret) == TaskManager.NotExecutor.selector,
                "Sim 6: admin key gave wrong revert (must still be NotExecutor)"
            );
            console.log("6.", labels[i], "blocked for hat-wearer with NotExecutor OK");
        }
    }
}
