// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";

// Upgrade PaymasterHub to v16 (adds adminBatchAddRules) then fix vouch-claim
// whitelist rules for Poa + KUBI in one cross-chain admin call.
// adminBatchAddRules skips unregistered orgs, so:
//   - Arbitrum: sets rules for Poa (registered), skips KUBI (not registered)
//   - Gnosis:   sets rules for KUBI (registered), skips Poa (not registered)

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
address constant GNOSIS_PM_PROXY = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
string constant PM_VERSION = "v18"; // v16 burned without protocolAdmin, v17 without setSolidarityFee protocolAdmin

// Orgs
bytes32 constant POA_ORG = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;
address constant POA_QJ = 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a;

bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
address constant KUBI_QJ = 0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf;

// Vouch-claim selectors
bytes4 constant CLAIM_HATS = 0x130906e5;
bytes4 constant REG_CLAIM_PASSKEY = 0xece090ff;
bytes4 constant REG_CLAIM_EOA = 0xd58fb6ee;

/**
 * Step 1: Deploy PaymasterHub v16 on Gnosis.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/UpgradeAndFixVouchRules.s.sol:Step1_DeployOnGnosis \
 *     --rpc-url gnosis --broadcast --slow --optimizer-runs 100 \
 *     --sender 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
 */
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("PaymasterHub", PM_VERSION);
        address predicted = dd.computeAddress(salt);

        console.log("=== Step 1: Deploy PaymasterHub v16 on Gnosis ===");
        console.log("Predicted:", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed.");
            return;
        }

        vm.startBroadcast(key);
        dd.deploy(salt, type(PaymasterHub).creationCode);
        vm.stopBroadcast();

        uint256 size = predicted.code.length;
        console.log("Deployed. Size:", size);
        require(size <= 24576, "OVER EIP-170");
    }
}

/**
 * Step 2: Upgrade beacon cross-chain + fix vouch-claim rules via adminBatchAddRules.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/UpgradeAndFixVouchRules.s.sol:Step2_UpgradeAndFix \
 *     --rpc-url arbitrum --broadcast --slow --optimizer-runs 100 \
 *     --sender 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
 */
contract Step2_UpgradeAndFix is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        require(hub.owner() == vm.addr(key), "Not owner");

        bytes32 salt = dd.computeSalt("PaymasterHub", PM_VERSION);
        address pmAddr = dd.computeAddress(salt);
        console.log("=== Step 2: Upgrade + Fix Vouch-Claim Rules ===");
        console.log("PaymasterHub v16:", pmAddr);

        vm.startBroadcast(key);

        // Deploy on Arbitrum if needed
        if (pmAddr.code.length == 0) {
            dd.deploy(salt, type(PaymasterHub).creationCode);
            console.log("Deployed on Arbitrum. Size:", pmAddr.code.length);
            require(pmAddr.code.length <= 24576, "OVER EIP-170");
        }

        // Upgrade beacon cross-chain
        hub.upgradeBeaconCrossChain{value: 0.005 ether}("PaymasterHub", pmAddr, PM_VERSION);
        console.log("Beacon upgrade dispatched");

        // Fix vouch-claim rules: 3 selectors x 2 orgs = 6 entries
        bytes32[] memory orgIds = new bytes32[](6);
        address[] memory targets = new address[](6);
        bytes4[] memory selectors = new bytes4[](6);

        // Poa governance org entries
        orgIds[0] = POA_ORG;
        targets[0] = POA_QJ;
        selectors[0] = CLAIM_HATS;
        orgIds[1] = POA_ORG;
        targets[1] = POA_QJ;
        selectors[1] = REG_CLAIM_PASSKEY;
        orgIds[2] = POA_ORG;
        targets[2] = POA_QJ;
        selectors[2] = REG_CLAIM_EOA;

        // KUBI entries
        orgIds[3] = KUBI_ORG;
        targets[3] = KUBI_QJ;
        selectors[3] = CLAIM_HATS;
        orgIds[4] = KUBI_ORG;
        targets[4] = KUBI_QJ;
        selectors[4] = REG_CLAIM_PASSKEY;
        orgIds[5] = KUBI_ORG;
        targets[5] = KUBI_QJ;
        selectors[5] = REG_CLAIM_EOA;

        // Build separate rule data for each chain
        // Poa only (Arbitrum)
        bytes32[] memory poaOrgIds = new bytes32[](3);
        address[] memory poaTargets = new address[](3);
        bytes4[] memory poaSels = new bytes4[](3);
        for (uint256 i; i < 3; i++) {
            poaOrgIds[i] = POA_ORG;
            poaTargets[i] = POA_QJ;
        }
        poaSels[0] = CLAIM_HATS;
        poaSels[1] = REG_CLAIM_PASSKEY;
        poaSels[2] = REG_CLAIM_EOA;

        bytes memory poaRuleData =
            abi.encodeWithSignature("adminBatchAddRules(bytes32[],address[],bytes4[])", poaOrgIds, poaTargets, poaSels);

        // KUBI only (Gnosis)
        bytes32[] memory kubiOrgIds = new bytes32[](3);
        address[] memory kubiTargets = new address[](3);
        bytes4[] memory kubiSels = new bytes4[](3);
        for (uint256 i; i < 3; i++) {
            kubiOrgIds[i] = KUBI_ORG;
            kubiTargets[i] = KUBI_QJ;
        }
        kubiSels[0] = CLAIM_HATS;
        kubiSels[1] = REG_CLAIM_PASSKEY;
        kubiSels[2] = REG_CLAIM_EOA;

        bytes memory kubiRuleData = abi.encodeWithSignature(
            "adminBatchAddRules(bytes32[],address[],bytes4[])", kubiOrgIds, kubiTargets, kubiSels
        );

        // Fix Poa on Arbitrum: targets the CORRECT Arbitrum PaymasterHub
        address ARB_PM_PROXY = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;
        hub.adminCall(ARB_PM_PROXY, poaRuleData);
        console.log("Poa rules set on Arbitrum");

        // Fix KUBI on Gnosis: adminCallCrossChain targets Arbitrum PM (0xD665)
        // Home chain: adminBatchAddRules on Arbitrum PM — KUBI not registered, skipped (no-op)
        // Satellite: adminBatchAddRules on 0xD665 on Gnosis — 0xD665 has NO code on Gnosis,
        //            so PoaManager.adminCall(0xD665, data) returns (true, "") — harmless no-op.
        // THIS DOESN'T FIX KUBI. See Step3 below.
        // Instead we use the Gnosis PM address BUT we need v16 on Gnosis first.
        // After the beacon upgrade Hyperlane message lands (~5 min), run Step3.

        vm.stopBroadcast();
        console.log("Poa fixed on Arbitrum.");
        console.log("KUBI on Gnosis: requires adminCallCrossChain but PaymasterHub addresses differ");
        console.log("across chains. adminCallCrossChain cannot target different addresses per chain.");
        console.log("Options: 1) KUBI governance vote  2) Redeploy Hub with adminCallSatelliteOnly");
    }
}

// DryRun: Full E2E simulation on Gnosis fork.
// Tests: upgrade beacon → setProtocolAdmin (poaManager-gated) → adminBatchAddRules as deployer → verify rules.
//
// Usage:
//   FOUNDRY_PROFILE=production forge script \
//     script/UpgradeAndFixVouchRules.s.sol:DryRun \
//     --fork-url https://rpc.gnosischain.com --optimizer-runs 70
contract DryRun is Script {
    function run() public {
        address gnosisPM = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
        address gnosisPaymaster = GNOSIS_PM_PROXY;
        address pmOwner = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
        address deployer = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

        console.log("=== DRY RUN: Gnosis E2E ===");

        // 1. Deploy new impl
        PaymasterHub newImpl = new PaymasterHub();
        console.log("v16 size:", address(newImpl).code.length);
        require(address(newImpl).code.length <= 24576, "OVER EIP-170");

        // 2. Upgrade beacon
        vm.prank(pmOwner);
        (bool ok,) = gnosisPM.call(
            abi.encodeWithSignature("upgradeBeacon(string,address,string)", "PaymasterHub", address(newImpl), "v16-dry")
        );
        require(ok, "Beacon upgrade failed");
        console.log("Beacon upgraded");

        // 3. Set protocolAdmin via the poaManager-gated setter (M-10: the old unauthenticated
        //    reinitializeProtocolAdmin is gone). On Gnosis the paymaster's poaManager is the
        //    Satellite (pmOwner), so it is the authorized caller.
        PaymasterHub pm = PaymasterHub(payable(gnosisPaymaster));
        vm.prank(pmOwner);
        pm.setProtocolAdmin(deployer);
        console.log("protocolAdmin set to deployer");

        // 4. Check KUBI rules BEFORE
        console.log("BEFORE KUBI regClaimPasskey:", pm.getRule(KUBI_ORG, KUBI_QJ, REG_CLAIM_PASSKEY).allowed);

        // 5. Call adminBatchAddRules DIRECTLY as deployer (protocolAdmin)
        bytes32[] memory orgIds = new bytes32[](3);
        address[] memory targets = new address[](3);
        bytes4[] memory sels = new bytes4[](3);
        for (uint256 i; i < 3; i++) {
            orgIds[i] = KUBI_ORG;
            targets[i] = KUBI_QJ;
        }
        sels[0] = CLAIM_HATS;
        sels[1] = REG_CLAIM_PASSKEY;
        sels[2] = REG_CLAIM_EOA;

        vm.prank(deployer);
        pm.adminBatchAddRules(orgIds, targets, sels);
        console.log("adminBatchAddRules called as protocolAdmin");

        // 6. Check KUBI rules AFTER
        bool a1 = pm.getRule(KUBI_ORG, KUBI_QJ, CLAIM_HATS).allowed;
        bool a2 = pm.getRule(KUBI_ORG, KUBI_QJ, REG_CLAIM_PASSKEY).allowed;
        bool a3 = pm.getRule(KUBI_ORG, KUBI_QJ, REG_CLAIM_EOA).allowed;
        console.log("AFTER KUBI claimHatsWithUser:", a1);
        console.log("AFTER KUBI regClaimPasskey:", a2);
        console.log("AFTER KUBI regClaimEOA:", a3);
        require(a1 && a2 && a3, "KUBI rules not set!");

        // 7. Verify Poa SKIPPED on Gnosis
        bool poaAfter = pm.getRule(POA_ORG, POA_QJ, REG_CLAIM_PASSKEY).allowed;
        console.log("Poa on Gnosis (should be false):", poaAfter);
        require(!poaAfter, "Poa should be skipped on Gnosis");

        // 8. Verify random address can't call adminBatchAddRules
        vm.prank(address(0xBAD));
        try pm.adminBatchAddRules(orgIds, targets, sels) {
            revert("Should have reverted for unauthorized caller");
        } catch {
            console.log("Unauthorized caller correctly rejected");
        }

        // 9. Verify setProtocolAdmin is gated: a non-poaManager caller cannot seize it (M-10).
        vm.prank(address(0x123));
        try pm.setProtocolAdmin(address(0x123)) {
            revert("Should have reverted - not poaManager");
        } catch {
            console.log("Unauthorized setProtocolAdmin correctly rejected");
        }

        console.log("=== ALL CHECKS PASSED ===");
    }
}
