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
 * OrgDeployer v14 — TaskManager v5 edit-task selectors in default whitelist
 * ============================================================================
 *
 * TaskManager v5 added two post-claim edit functions:
 *   updateTask(uint256,uint256,bytes,bytes32,address,uint256)  -> 0x48db6f65
 *   updateTaskMetadata(uint256,bytes,bytes32)                  -> 0x26fa4e70
 * gated on the EDIT_META / EDIT_FULL TaskPerm bits. They were NOT in the
 * default paymaster ruleset emitted by deployFullOrg, so every newly deployed
 * org's passkey/smart accounts could not call them with gas sponsorship
 * (exactly the gap Decentral Park hit; see AddTaskEditSelectorRules retroactive
 * fix for live orgs).
 *
 * This upgrade adds both selectors to OrgDeployer._appendTaskManagerRules so
 * NEW orgs auto-whitelist them at deploy. The TaskManager rule count bumped
 * 14 -> 16 and the _buildDefaultPaymasterRules base count 41 -> 43.
 *
 *   Live impl: v13
 *   This PR:   v14 (edit-task selectors, in addition to setFolders + createTasksBatch)
 *
 * Version selection (CLAUDE.md probing recipe, both surfaces both chains, this branch):
 *   v11/v12/v13 are TAKEN (registry + CREATE2) on Gnosis AND Arbitrum;
 *   v14 is FREE on both surfaces on both chains (predicted 0xd0224cD4F2C3a22F02626bd346895bf28f929A03).
 *   (Live impl is v13 at 0x02D16118AA9EB485e8cD5Ac51167B2934c462b80; no committed v13 script — probed on-chain.)
 *
 * Forward-only: existing orgs are unaffected by an OrgDeployer upgrade — they
 * already have their paymaster rules. This only changes what NEW orgs get
 * bootstrapped with. Live orgs missing the edit-task rules need the separate
 * retroactive fix (Hub/Satellite adminCall -> setRulesBatch per org).
 *
 * Three-step cross-chain upgrade pattern (mirrors UpgradeOrgDeployerFolders):
 *   1. Deploy impl on Gnosis via DeterministicDeployer
 *   2. Deploy on Arbitrum + upgradeBeaconCrossChain
 *   3. Verify on Gnosis after Hyperlane relay (~5 min)
 *
 * Usage (sim first — CLAUDE.md requires PASS before broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerEditTaskRules.s.sol:SimulateOrgDeployerEditTaskUpgrade \
 *     --fork-url arbitrum -vvv
 *
 * Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerEditTaskRules.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerEditTaskRules.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 *
 *   forge script script/upgrades/UpgradeOrgDeployerEditTaskRules.s.sol:Step3_Verify \
 *     --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
string constant VERSION = "v14";

// keccak256(...)[:4] of the two TaskManager v5 edit functions added to the whitelist.
bytes4 constant SEL_UPDATE_TASK = 0x48db6f65; // updateTask(uint256,uint256,bytes,bytes32,address,uint256)
bytes4 constant SEL_UPDATE_TASK_META = 0x26fa4e70; // updateTaskMetadata(uint256,bytes,bytes32)

contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy OrgDeployer v14 on Gnosis ===");
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
        console.log("OrgDeployer v14 impl:", impl);

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
            console.log("PASS: OrgDeployer v14 live on Gnosis");
            console.log("New orgs now auto-whitelist updateTask (0x48db6f65) + updateTaskMetadata (0x26fa4e70)");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

/**
 * @title SimulateOrgDeployerEditTaskUpgrade
 * @notice Fork-simulates the upgrade end-to-end on Arbitrum: deploys v14 via DD,
 *         calls upgradeBeaconCrossChain, and verifies the Arbitrum beacon impl
 *         switched to the new bytecode. Does NOT verify Gnosis (cross-chain
 *         relay isn't fork-simulatable).
 *
 *         Behavior verification (the new selectors actually land in the default
 *         rule batch) is covered by test/DeployerTest.t.sol:
 *         testDeployFullOrgWithPaymasterAutoWhitelist, which asserts
 *         getRule(orgId, taskManager, updateTask/updateTaskMetadata).allowed.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerEditTaskRules.s.sol:SimulateOrgDeployerEditTaskUpgrade \
 *     --fork-url arbitrum -vvv
 */
contract SimulateOrgDeployerEditTaskUpgrade is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        console.log("\n=== SIM: OrgDeployer v14 upgrade (Arbitrum fork) ===");
        console.log("Deployer:", deployer);
        console.log("Selectors added: updateTask 0x48db6f65, updateTaskMetadata 0x26fa4e70");

        address before = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted v14:", predicted);
        require(before != predicted, "Sim: v14 already live (nothing to upgrade)");

        vm.deal(deployer, 1 ether);
        vm.startPrank(deployer);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == predicted, "Address mismatch");
            console.log("v14 deployed at:", deployed);
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
            "Behavior verification: DeployerTest.testDeployFullOrgWithPaymasterAutoWhitelist asserts the edit-task rules auto-set on deploy."
        );
    }
}
