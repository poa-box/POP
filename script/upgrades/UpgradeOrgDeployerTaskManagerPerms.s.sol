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
 * OrgDeployer v13 — TaskManager Bootstrap Permissions
 * ============================================================================
 *
 * Companion to UpgradeTaskManagerEditPerms.s.sol (TaskManager v5). Adds the
 * `taskManagerPerms` field to `OrgDeployer.DeploymentParams` and wires the
 * deployer to call `TaskManager.bootstrapGlobalPerms(hatIds[], masks[])`
 * after impl init and before per-project bootstrap. Lets new orgs deploy with
 * org-wide TaskPerm bits (EDIT_META, EDIT_FULL, BUDGET, SELF_REVIEW, etc.)
 * already granted to chosen role hats — no post-deploy governance vote needed.
 *
 * **MUST BROADCAST AFTER TaskManager v5.** OrgDeployer v13 calls a function
 * that only exists on TaskManager v5+. Broadcasting v13 before TaskManager v5
 * would cause new org deploys with non-empty taskManagerPerms to revert.
 * Empty taskManagerPerms is a no-op so existing deploys continue to work.
 *
 * No Layout struct change. ITaskManagerBootstrap interface extended (purely
 * additive). No new events. No new ConfigKey.
 *
 * Three-step cross-chain upgrade pattern (mirrors UpgradeOrgDeployerEduRules):
 *   1. Step1_DeployOnGnosis             — deploy impl on Gnosis via DD
 *   2. Step2_UpgradeFromArbitrum        — deploy impl on Arb + cross-chain dispatch
 *   3. Step3_Verify                     — verify Gnosis beacon updated
 *
 * VERSION = "v13" — verified FREE on both Gnosis and Arbitrum (probed
 * 2026-05-27). Gnosis: registry count=8, CREATE2 slot empty. Arbitrum: registry
 * count=9, CREATE2 slot empty. Predicted impl address (same on both via CREATE2):
 *   0x02D16118AA9EB485e8cD5Ac51167B2934c462b80
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
// Hudson — owner of PoaManagerHub on Arbitrum and PoaManagerSatellite on Gnosis.
// Hardcoded per CLAUDE.md ("prank as it, don't read Hub.owner() and reuse the result").
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
string constant VERSION = "v13";

/**
 * @title Step1_DeployOnGnosis
 * @notice Deploy OrgDeployer v13 impl on Gnosis via DD.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerTaskManagerPerms.s.sol:Step1_DeployOnGnosis \
 *     --rpc-url gnosis --broadcast --slow
 */
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 1: Deploy OrgDeployer v13 on Gnosis ===");
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

/**
 * @title Step2_UpgradeFromArbitrum
 * @notice Deploy impl on Arbitrum via DD, upgrade beacon locally + dispatch cross-chain.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerTaskManagerPerms.s.sol:Step2_UpgradeFromArbitrum \
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

        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n=== Step 2: Upgrade OrgDeployer from Arbitrum ===");
        console.log("DD impl address:", predicted);

        vm.startBroadcast(deployerKey);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
            require(deployed == predicted, "Address mismatch on Arbitrum");
            console.log("Deployed on Arbitrum");
        } else {
            console.log("Already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", predicted, VERSION);
        console.log("Beacon upgraded locally + dispatched cross-chain");

        vm.stopBroadcast();

        // Verify Arbitrum-side switch landed before declaring ready for Gnosis.
        address pm = address(hub.poaManager());
        address current = PoaManager(pm).getCurrentImplementationById(keccak256("OrgDeployer"));
        require(current == predicted, "Arbitrum impl not upgraded");
        console.log("Arbitrum upgrade: PASS");
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3_Verify on Gnosis.");
    }
}

/**
 * @title Step3_Verify
 * @notice Verify the Gnosis beacon picked up the cross-chain upgrade.
 *
 * Usage:
 *   forge script script/upgrades/UpgradeOrgDeployerTaskManagerPerms.s.sol:Step3_Verify \
 *     --rpc-url gnosis
 */
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address expected = dd.computeAddress(salt);

        address current = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));

        console.log("\n=== Step 3: Verify Gnosis OrgDeployer Upgrade ===");
        console.log("Expected impl:", expected);
        console.log("Current impl: ", current);

        if (current == expected) {
            console.log("PASS: OrgDeployer upgraded to v13 on Gnosis");
            console.log("\nNew capability: DeploymentParams.taskManagerPerms { roleIndices[], masks[] }");
            console.log("  - Wires bootstrapGlobalPerms() during _deployFullOrgInternal");
            console.log("  - New orgs can grant EDIT_META/EDIT_FULL/BUDGET to role hats at deploy");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed.");
        }
    }
}

/**
 * @title SimulateOrgDeployerUpgrade
 * @notice Fork-simulates the v13 upgrade end-to-end on the Arbitrum side and asserts:
 *           1. DD-predicted address matches deployed address.
 *           2. PoaManager beacon for "OrgDeployer" advances to the new impl (before vs after).
 *           3. The new impl has non-zero code in the runtime.
 *           4. The new `bootstrapGlobalPerms` selector exists in the new impl's bytecode —
 *              this is the v13 feature; without it the upgrade is meaningless.
 *
 *         Pranks Hudson directly (`HUDSON_ADMIN` constant) per CLAUDE.md, instead of trusting
 *         `Hub.owner()` mid-fork.
 *
 *         Storage-layout drift is enforced separately by CI (`upgrades/baseline` storage-layout
 *         validator) — the sim deliberately does NOT try to read through a live proxy because
 *         locating the OrgDeployer proxy on a mainnet fork is fragile and the CI check is the
 *         authoritative guarantee. (The reference pattern, `UpgradeOrgDeployerEduRules.s.sol`,
 *         also skips the proxy read for the same reason.)
 *
 *         Cross-chain dispatch is not simulated end-to-end (would require Hyperlane relay).
 *         The Hub-side call is exercised; Gnosis-side verification waits for the real relay.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOrgDeployerTaskManagerPerms.s.sol:SimulateOrgDeployerUpgrade \
 *     --fork-url arbitrum -vvv
 */
contract SimulateOrgDeployerUpgrade is Script {
    function run() public {
        console.log("\n========================================");
        console.log("  OrgDeployer v13 Upgrade Simulation");
        console.log("========================================");

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        // 1. Pre-state snapshot.
        bytes32 typeId = keccak256("OrgDeployer");
        address before = PoaManager(pm).getCurrentImplementationById(typeId);
        require(before != address(0), "Sim: no existing OrgDeployer impl");
        console.log("Impl before:", before);

        // 2. Deploy v13 impl via DD (prank DD owner — DD.deploy is onlyOwner).
        bytes32 salt = dd.computeSalt("OrgDeployer", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted impl:", predicted);

        address deployed;
        if (predicted.code.length == 0) {
            address ddOwner = DeterministicDeployer(DD).owner();
            vm.prank(ddOwner);
            deployed = dd.deploy(salt, type(OrgDeployer).creationCode);
        } else {
            console.log("Already deployed at predicted (skipping deploy)");
            deployed = predicted;
        }
        require(deployed == predicted, "Sim: DD address mismatch");
        require(deployed.code.length > 0, "Sim: impl code missing");
        console.log("Deployed impl: ", deployed);

        // 3. Upgrade beacon as Hudson (CLAUDE.md: prank the hardcoded EOA, don't trust
        //    hub.owner() in case ownership changes mid-fork).
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", predicted, VERSION);

        // 4. Verify beacon advanced — read-before-and-after invariant per CLAUDE.md.
        address afterImpl = PoaManager(pm).getCurrentImplementationById(typeId);
        require(afterImpl == predicted, "Sim: beacon upgrade did not stick");
        require(afterImpl != before, "Sim: impl unchanged (before == after)");
        console.log("Impl after:    ", afterImpl);

        // 5. Selector presence in impl bytecode — verifies the new `bootstrapGlobalPerms` call
        //    path will resolve on the upgraded proxy. Without this check the upgrade carries
        //    nothing of v13 substance.
        bytes4 sel = bytes4(keccak256("bootstrapGlobalPerms(uint256[],uint8[])"));
        require(_selectorIn(predicted, sel), "Sim: bootstrapGlobalPerms selector missing in v13 impl");
        console.log("Selector check: bootstrapGlobalPerms(uint256[],uint8[]) present in v13 impl");

        console.log("\n=== ALL SIM CHECKS PASSED ===");
        console.log("Safe to broadcast Step1/Step2/Step3 against mainnet.");
    }

    /// @dev Naive selector scan over a bytecode blob — same defensive check used in
    ///      UpgradeTaskManagerEditPerms.s.sol. Bounded by impl bytecode length (~40KB).
    function _selectorIn(address impl, bytes4 sel) internal view returns (bool) {
        bytes memory code = impl.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}
