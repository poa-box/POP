// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * OrgDeployer v15 — TaskManager v6 deadline selectors in the default whitelist
 * ============================================================================
 *
 * TaskManager v6 REPLACED four selectors (deadline params appended):
 *   createTask           0x22fa79bc -> 0x4d0265d4
 *   createTasksBatch     0xc18aa1c9 -> 0xf31d148f
 *   createAndAssignTask  0xaf425951 -> 0x98e30e89
 *   updateTask           0x48db6f65 -> 0xb7c288e8
 *
 * This upgrade swaps the four signature strings in
 * OrgDeployer._appendTaskManagerRules so NEW orgs auto-whitelist the v6
 * selectors at deploy. Rule counts unchanged (4 replaced, 0 added; base count
 * stays 43).
 *
 * Version selection (CLAUDE.md probing recipe, both surfaces, both chains, 2026-06-09):
 *   v12/v13/v14 TAKEN (registry + CREATE2) on Gnosis AND Arbitrum;
 *   v15 FREE on both surfaces on both chains
 *   (predicted 0xFa5Bc9343631489094e68a6059E93994C33127A3). Live impl is v14.
 *
 * Forward-only: existing orgs keep their current rules — the retroactive
 * per-org governance scripts (WhitelistTaskDeadlineRules*ViaGovernance) flip
 * the 4 new selectors on and the 4 dead ones off for live orgs.
 *
 * Usage (sim first — CLAUDE.md requires PASS before broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerDeadlineRules.s.sol:SimulateOrgDeployerDeadlineRulesUpgrade \
 *     --fork-url arbitrum -vvv
 *
 * Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerDeadlineRules.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerDeadlineRules.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 *   forge script script/upgrades/UpgradeOrgDeployerDeadlineRules.s.sol:Step3_Verify --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub + DeterministicDeployer (pranked in the sim).
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
string constant VERSION = "v15";

// TaskManager v6 selectors now emitted by _appendTaskManagerRules (cast sig verified).
bytes4 constant SEL_CREATE_TASK_V6 = 0x4d0265d4;
bytes4 constant SEL_CREATE_TASKS_BATCH_V6 = 0xf31d148f;
bytes4 constant SEL_CREATE_AND_ASSIGN_V6 = 0x98e30e89;
bytes4 constant SEL_UPDATE_TASK_V6 = 0xb7c288e8;

contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy OrgDeployer v15 on Gnosis ===");
        console.log("Predicted:", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }

        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
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

        console.log("\n=== Step 2: Upgrade OrgDeployer from Arbitrum ===");
        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address impl = dd.computeAddress(salt);
        console.log("OrgDeployer v15 impl:", impl);

        vm.startBroadcast(deployerKey);

        if (impl.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == impl, "Address mismatch on Arbitrum");
            console.log("Deployed on Arbitrum");
        } else {
            console.log("Already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", impl, VERSION);
        console.log("Beacon upgrade dispatched (Arbitrum local + Gnosis cross-chain)");

        vm.stopBroadcast();

        address pm = address(hub.poaManager());
        address current = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        require(current == impl, "Arbitrum impl not upgraded");
        console.log("Arbitrum upgrade: PASS");
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3_Verify on Gnosis");
    }
}

contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address expected = dd.computeAddress(dd.computeSalt("OrgDeployer", VERSION));
        address current = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));

        console.log("\n=== Verify Gnosis OrgDeployer Upgrade ===");
        console.log("Expected:", expected);
        console.log("Current: ", current);
        if (current == expected) {
            console.log("PASS: OrgDeployer v15 live on Gnosis");
            console.log("New orgs now auto-whitelist the TaskManager v6 deadline selectors:");
            console.log("  createTask 0x4d0265d4 / createTasksBatch 0xf31d148f");
            console.log("  createAndAssignTask 0x98e30e89 / updateTask 0xb7c288e8");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

/**
 * @title SimulateOrgDeployerDeadlineRulesUpgrade
 * @notice Fork-simulates the upgrade end-to-end on Arbitrum: deploys v15 via DD
 *         (prank Hudson — no env needed), calls upgradeBeaconCrossChain, and
 *         verifies the Arbitrum beacon impl switched. Gnosis relay isn't
 *         fork-simulatable; Step3 verifies it after broadcast.
 *
 *         Behavior verification (the v6 selectors actually land in the default
 *         rule batch) is covered by test/DeployerTest.t.sol —
 *         testDeployFullOrgWithPaymasterAutoWhitelist asserts
 *         getRule(orgId, taskManager, <v6 selectors>).allowed and the
 *         selector-accuracy asserts pin the signature strings to the real
 *         TaskManager selectors.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerDeadlineRules.s.sol:SimulateOrgDeployerDeadlineRulesUpgrade \
 *     --fork-url arbitrum -vvv
 */
contract SimulateOrgDeployerDeadlineRulesUpgrade is Script {
    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        console.log("\n=== SIM: OrgDeployer v15 upgrade (Arbitrum fork) ===");
        console.log("Selectors swapped to v6: createTask 0x4d0265d4, createTasksBatch 0xf31d148f,");
        console.log("createAndAssignTask 0x98e30e89, updateTask 0xb7c288e8");

        address before = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted v15:", predicted);
        require(before != predicted, "Sim: v15 already live (nothing to upgrade)");

        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.startPrank(HUDSON_ADMIN);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == predicted, "Address mismatch");
            console.log("v15 deployed at:", deployed);
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", predicted, VERSION);

        vm.stopPrank();

        address after_ = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("New impl:", after_);
        require(after_ == predicted, "Upgrade failed");
        require(after_.code.length > 0, "Impl has no code");
        console.log("New impl codesize:", after_.code.length, "bytes");

        console.log("\nArbitrum upgrade simulation: PASS");
        console.log(
            "Behavior verification: DeployerTest.testDeployFullOrgWithPaymasterAutoWhitelist asserts the v6 deadline rules auto-set on deploy."
        );
    }
}
