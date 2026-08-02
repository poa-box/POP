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
 * OrgDeployer v18 — unclaimTask in the default paymaster whitelist
 * ============================================================================
 *
 * TaskManager v7 adds unclaimTask(uint256) = 0x6103955a. It was not in the default
 * ruleset deployFullOrg emits, so a new org's passkey/smart accounts could not call
 * it with gas sponsorship. This adds it to _appendTaskManagerRules (TaskManager rule
 * count 16 -> 17, base count 43 -> 44).
 *
 *   Live impl: v17 (0xab8124C986Cf056dA23184913FA73352c8695615, both chains)
 *   This PR:   v18
 *
 * Version selection (CLAUDE.md recipe, both surfaces, both chains, 2026-07-31):
 *   Gnosis   registry count=15; v16/v17 TAKEN (registry+CREATE2); v18 FREE on both.
 *   Arbitrum registry count=16; v17 TAKEN (registry+CREATE2); v18 FREE on both.
 *   Predicted v18 impl (identical on both chains): 0xE328c6093e53cBafea8d4461e9bd4345786decC9
 *
 * Forward-only: existing orgs already have their rules and are unaffected by an
 * OrgDeployer upgrade. They need the separate per-org governance batch to add the
 * new selector. Sequence this AFTER TaskManager v7 so a new org never gets a rule
 * pointing at a selector its impl does not implement.
 *
 * Sim first (CLAUDE.md requires PASS before broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerUnclaimRule.s.sol:SimulateOrgDeployerUnclaimRuleUpgrade \
 *     --fork-url arbitrum -vvv
 *
 * Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerUnclaimRule.s.sol:Step1_DeployImplOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerUnclaimRule.s.sol:Step2_UpgradeFromArbitrum \
 *     --rpc-url arbitrum --broadcast --slow
 *   forge script script/upgrades/UpgradeOrgDeployerUnclaimRule.s.sol:Step3_Verify --rpc-url gnosis
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub + DeterministicDeployer (pranked in the sim).
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
string constant VERSION = "v18";

// The selector this upgrade adds (cast sig "unclaimTask(uint256)"); documented for the
// per-org governance batches that back-fill it on already-deployed orgs.
bytes4 constant SEL_UNCLAIM_TASK = 0x6103955a;

contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy OrgDeployer v18 on Gnosis ===");
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

        console.log("\n=== Step 2: Upgrade OrgDeployer to v18 from Arbitrum ===");
        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address impl = dd.computeAddress(salt);
        console.log("OrgDeployer v18 impl:", impl);

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
            console.log("PASS: OrgDeployer v18 live on Gnosis");
            console.log("New orgs now auto-whitelist unclaimTask(uint256) 0x6103955a");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

/**
 * @title SimulateOrgDeployerUnclaimRuleUpgrade
 * @notice Fork-sims the upgrade end-to-end on Arbitrum: deploys v18 via DD (prank
 *         Hudson — no env needed), calls upgradeBeaconCrossChain, and verifies the
 *         Arbitrum beacon impl switched to bytecode identical to this branch's build.
 *         Gnosis relay isn't fork-simulatable; Step3 verifies it after broadcast.
 *
 *         Behavior verification (the rule really lands in the default batch) is
 *         covered by test/DeployerTest.t.sol — testDeployFullOrgWithPaymasterAutoWhitelist
 *         and testDeployFullOrgAutoWhitelistNoEducation both assert
 *         getRule(orgId, taskManager, unclaimTask).allowed (education on and off, since
 *         educationEnabled changes the rule-array sizing), and testPaymasterSelectorAccuracy
 *         pins the signature string to the real selector.
 */
contract SimulateOrgDeployerUnclaimRuleUpgrade is Script {
    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        console.log("\n=== SIM: OrgDeployer v18 upgrade (Arbitrum fork) ===");
        console.log("Adds TaskManager unclaimTask(uint256) 0x6103955a to the default rule batch");

        address before = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted v18:", predicted);
        require(before != predicted, "Sim: v18 already live (nothing to upgrade)");

        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.startPrank(HUDSON_ADMIN);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == predicted, "Address mismatch");
            console.log("v18 deployed at:", deployed);
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", predicted, VERSION);

        vm.stopPrank();

        address after_ = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("New impl:", after_);
        require(after_ == predicted, "Upgrade failed");
        require(after_.code.length > 0, "Impl has no code");
        console.log("New impl codesize:", after_.code.length, "bytes");

        // The impl on the fork must be byte-identical to this branch's build — that is what
        // ties the deploy to the code DeployerTest verified behaviorally.
        //
        // Do NOT "improve" this into a grep for SEL_UNCLAIM_TASK in the bytecode: the rule
        // selectors are keccak-of-string-literal constants that the optimizer folds and then
        // materializes arithmetically, so most of them (including this one) never appear as a
        // literal 4-byte sequence. Verified on this build: 9 of the 12 TaskManager rule
        // selectors are absent from the runtime code even though every rule is emitted.
        // (The grep IS valid on TaskManager itself, where selectors are dispatch-table entries.)
        require(keccak256(after_.code) == keccak256(type(OrgDeployer).runtimeCode), "Sim: impl != this branch's build");
        console.log("Impl bytecode matches this branch's OrgDeployer build");

        console.log("\nArbitrum upgrade simulation: PASS");
        console.log(
            "Behavior: DeployerTest.testDeployFullOrgWithPaymasterAutoWhitelist (+NoEducation) assert the rule auto-sets."
        );
    }
}
