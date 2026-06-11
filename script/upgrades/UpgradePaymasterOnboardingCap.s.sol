// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

// ─────────────────────────────────────────────────────────────────────────────
// UpgradePaymasterOnboardingCap  (Audit H4)
//
// Adds a per-account lifetime cap on solidarity-funded onboarding sponsorship to
// PaymasterHub (new `OnboardingConfig.maxOnboardingsPerAccount`, a new
// `poa.paymasterhub.onboarding.counts` storage mapping, enforcement in
// `_validateOnboardingEligibility`, and the new `setOnboardingConfig` arg).
//
// Storage safety: the new struct field is appended (packs into the slot holding
// `accountRegistry`) and the counts mapping lives at a fresh ERC-7201 slot, so the
// upgrade preserves all existing onboarding state. `maxOnboardingsPerAccount == 0`
// means UNLIMITED, so an already-deployed hub (where the appended field reads 0
// post-upgrade) keeps sponsoring onboarding until an admin sets a cap — Step3/Step4
// set the cap to activate the protection.
//
// Validated: Sim_GnosisUpgrade PASSES under FOUNDRY_PROFILE=production via `forge script`
// (scoped compile of this script + its src deps) against a live Gnosis fork — i.e. a real
// production-profile sim, broadcast-representative bytecode. Run it with:
//   FOUNDRY_PROFILE=production forge script \
//     script/upgrades/UpgradePaymasterOnboardingCap.s.sol:Sim_GnosisUpgrade --fork-url gnosis
// Note: a full-project `FOUNDRY_PROFILE=production forge build` currently fails with a
// Stack-too-deep in an unrelated NON-deployable test/script file (all of src/ compiles
// clean under production, and CI gates on the default profile), so it does not affect this
// scoped broadcast — but if you want a clean full production build, that file needs a fix.
//
// Version: v18 (probed free on Gnosis + Arbitrum, both registry and CREATE2, 2026-06-09).
// ─────────────────────────────────────────────────────────────────────────────

// Shared constants (same addresses as UpgradePaymasterGraceFix)
address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant ARB_PAYMASTER = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;
address constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
uint256 constant HYPERLANE_FEE = 0.005 ether;
string constant VERSION = "v18";
uint8 constant MAX_ONBOARDINGS_PER_ACCOUNT = 3; // register + profile + 1 retry

/// @title Step1_DeployImplOnGnosis — deploy PaymasterHub v18 impl on Gnosis via DD.
/// Usage: FOUNDRY_PROFILE=production forge script .../UpgradePaymasterOnboardingCap.s.sol:Step1_DeployImplOnGnosis --rpc-url gnosis --broadcast --slow --optimizer-runs 200
contract Step1_DeployImplOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        bytes32 salt = dd.computeSalt("PaymasterHub", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted PaymasterHub v18 impl:", predicted);
        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }
        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(PaymasterHub).creationCode);
        vm.stopBroadcast();
        require(deployed == predicted, "Address mismatch");
        console.log("Deployed:", deployed);
        console.log("Next: Step2_UpgradeFromArbitrum on Arbitrum");
    }
}

/// @title Step2_UpgradeFromArbitrum — deploy on Arbitrum via DD + upgrade beacon cross-chain.
/// Usage: FOUNDRY_PROFILE=production forge script .../:Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow --optimizer-runs 200
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("PaymasterHub", VERSION);
        address predicted = dd.computeAddress(salt);

        vm.startBroadcast(deployerKey);
        if (predicted.code.length == 0) {
            dd.deploy(salt, type(PaymasterHub).creationCode);
            console.log("Deployed v18 on Arbitrum");
        }
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("PaymasterHub", predicted, VERSION);
        console.log("Beacon upgraded cross-chain to v18");
        vm.stopBroadcast();
        console.log("Wait ~5 min for Hyperlane relay, then run Step3 (Gnosis) and Step4 (Arbitrum) to set the cap.");
    }
}

/// @title Step3_SetCapGnosis — activate the per-account cap on the Gnosis paymaster (preserves other config).
/// Usage: FOUNDRY_PROFILE=production forge script .../:Step3_SetCapGnosis --rpc-url gnosis --broadcast --slow --optimizer-runs 200
contract Step3_SetCapGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PaymasterHub pm = PaymasterHub(payable(GNOSIS_PAYMASTER));
        PaymasterHub.OnboardingConfig memory c = pm.getOnboardingConfig();
        console.log("Gnosis onboarding pre-set: maxOnboardingsPerAccount =", c.maxOnboardingsPerAccount);

        vm.startBroadcast(deployerKey);
        // Re-set onboarding config, preserving all existing values and only adding the cap.
        PoaManager(GNOSIS_POA_MANAGER)
            .adminCall(
                GNOSIS_PAYMASTER,
                abi.encodeWithSignature(
                    "setOnboardingConfig(uint128,uint128,uint8,bool,address)",
                    c.maxGasPerCreation,
                    c.dailyCreationLimit,
                    MAX_ONBOARDINGS_PER_ACCOUNT,
                    c.enabled,
                    c.accountRegistry
                )
            );
        vm.stopBroadcast();
        console.log("Gnosis onboarding cap set to", MAX_ONBOARDINGS_PER_ACCOUNT);
    }
}

/// @title Step4_SetCapArbitrum — activate the per-account cap on the Arbitrum paymaster (preserves other config).
/// Usage: FOUNDRY_PROFILE=production forge script .../:Step4_SetCapArbitrum --rpc-url arbitrum --broadcast --slow --optimizer-runs 200
contract Step4_SetCapArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PaymasterHub pm = PaymasterHub(payable(ARB_PAYMASTER));
        PaymasterHub.OnboardingConfig memory c = pm.getOnboardingConfig();

        vm.startBroadcast(deployerKey);
        PoaManagerHub(payable(HUB))
            .adminCall(
                ARB_PAYMASTER,
                abi.encodeWithSignature(
                    "setOnboardingConfig(uint128,uint128,uint8,bool,address)",
                    c.maxGasPerCreation,
                    c.dailyCreationLimit,
                    MAX_ONBOARDINGS_PER_ACCOUNT,
                    c.enabled,
                    c.accountRegistry
                )
            );
        vm.stopBroadcast();
        console.log("Arbitrum onboarding cap set to", MAX_ONBOARDINGS_PER_ACCOUNT);
    }
}

/**
 * @title Sim_GnosisUpgrade
 * @notice Fork-simulates the v18 upgrade + cap activation against LIVE Gnosis state and asserts:
 *           1. The beacon upgrade preserves existing onboarding storage (maxGasPerCreation / dailyCreationLimit
 *              / accountRegistry unchanged), and the appended field reads 0 (= unlimited) so onboarding is NOT
 *              bricked by the upgrade alone.
 *           2. After the admin sets the cap, getOnboardingConfig().maxOnboardingsPerAccount == 3.
 *         Validated PASS under FOUNDRY_PROFILE=production (broadcast-representative bytecode); also runs under
 *         the default profile. This is the real production-profile sim required before broadcast.
 *
 * Usage: forge script script/upgrades/UpgradePaymasterOnboardingCap.s.sol:Sim_GnosisUpgrade --fork-url gnosis -vvv
 */
contract Sim_GnosisUpgrade is Script {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(GNOSIS_PAYMASTER));
        PoaManager poa = PoaManager(GNOSIS_POA_MANAGER);
        address owner = poa.owner();
        console.log("Gnosis PoaManager owner:", owner);

        // Capture live pre-upgrade onboarding config via low-level call decoding the OLD 6-field struct
        // (the live impl predates the appended field, so the new ABI getter cannot decode its return).
        (bool ok, bytes memory raw) = GNOSIS_PAYMASTER.staticcall(abi.encodeWithSignature("getOnboardingConfig()"));
        require(ok, "Sim: pre-upgrade getOnboardingConfig() failed");
        (
            uint128 preMaxGas,
            uint128 preDailyLimit,, // attemptsToday
            , // currentDay
            bool preEnabled,
            address preRegistry
        ) = abi.decode(raw, (uint128, uint128, uint128, uint32, bool, address));
        console.log("PRE  maxGasPerCreation:", preMaxGas);
        console.log("PRE  dailyCreationLimit:", preDailyLimit);
        console.log("PRE  enabled:", preEnabled);

        // 1. Deploy the new impl and upgrade the Gnosis beacon (as the PoaManager owner would).
        address newImpl = address(new PaymasterHub());
        vm.prank(owner);
        poa.upgradeBeacon("PaymasterHub", newImpl, VERSION);
        require(poa.getCurrentImplementationById(keccak256("PaymasterHub")) == newImpl, "Sim: beacon not upgraded");

        // 2. Storage preserved + appended field reads 0 (= unlimited; onboarding not bricked by the upgrade).
        PaymasterHub.OnboardingConfig memory mid = pm.getOnboardingConfig();
        require(mid.maxGasPerCreation == preMaxGas, "Sim: maxGasPerCreation drifted");
        require(mid.dailyCreationLimit == preDailyLimit, "Sim: dailyCreationLimit drifted");
        require(mid.accountRegistry == preRegistry, "Sim: accountRegistry drifted");
        require(mid.enabled == preEnabled, "Sim: enabled drifted");
        require(mid.maxOnboardingsPerAccount == 0, "Sim: appended field should read 0 (unlimited) pre-config");
        console.log("OK: upgrade preserved onboarding storage; cap defaults to 0 (unlimited).");

        // 3. Activate the cap via the PoaManager admin path and assert it took effect.
        vm.prank(owner);
        poa.adminCall(
            GNOSIS_PAYMASTER,
            abi.encodeWithSignature(
                "setOnboardingConfig(uint128,uint128,uint8,bool,address)",
                mid.maxGasPerCreation,
                mid.dailyCreationLimit,
                MAX_ONBOARDINGS_PER_ACCOUNT,
                mid.enabled,
                mid.accountRegistry
            )
        );
        PaymasterHub.OnboardingConfig memory post = pm.getOnboardingConfig();
        require(post.maxOnboardingsPerAccount == MAX_ONBOARDINGS_PER_ACCOUNT, "Sim: cap not applied");
        require(post.maxGasPerCreation == preMaxGas, "Sim: config clobbered while setting cap");
        require(post.dailyCreationLimit == preDailyLimit, "Sim: config clobbered while setting cap");

        console.log("PASS: v18 upgrade + cap activation validated against live Gnosis state.");
        console.log("POST maxOnboardingsPerAccount:", post.maxOnboardingsPerAccount);
    }
}
