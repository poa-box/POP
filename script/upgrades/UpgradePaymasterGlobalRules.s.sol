// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {PaymasterHubLens} from "../../src/PaymasterHubLens.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {PaymasterRuleLib} from "../../src/libs/PaymasterRuleLib.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {DefaultGlobalRules} from "../helpers/DefaultGlobalRules.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

// ─────────────────────────────────────────────────────────────────────────────
// UpgradePaymasterGlobalRules (PaymasterHub v20 — type-keyed GLOBAL RULEBOOK)
//
// Upgrades the live PaymasterHub on Gnosis + Arbitrum to the global-rulebook impl:
//   • Sponsorship rules resolve local-first, then (Mirror mode, the default) through a
//     protocol-managed rulebook keyed by (module typeId, selector) — one setGlobalRulesBatch
//     covers every Mirror org, replacing per-org adminBatchAddRules fan-outs and
//     OrgDeployer selector-list redeploys.
//   • Per-org targetTypes map proxy addresses → typeIds; per-org rules mode (Mirror/Static);
//     per-pair block veto; adopt/snapshot helpers for Static orgs.
//   • All rule logic moved to PaymasterRuleLib (new delegatecall library; hub runtime SHRANK
//     to 21,936 B at runs=200 — 2,640 B EIP-170 headroom).
//   • PaymasterHubLens gains effectiveRuleOf + global-aware wouldValidate → must be redeployed.
//
// The live "PaymasterHub" proxies are BeaconProxies — the upgrade goes through
// PoaManager.upgradeBeacon, driven by Satellite.upgradeBeaconDirect (Gnosis, owner = ADMIN_EOA)
// and PoaManagerHub.upgradeBeaconLocal (Arbitrum, owner = ADMIN_EOA). Admin calls that must
// arrive as the hub's poaManager route through Satellite/Hub.adminCall (which forwards via the
// local PoaManager.adminCall).
//
// Version: v20 — two-surface probed FREE (registry getVersionCount=16 + getImplementation
//   exit-code AND cast code at DeterministicDeployer.computeAddress) on BOTH chains, 2026-08-04.
//   Predicted impl (CREATE3, salt-only): 0xC0137F27de9E16875dc309f512D61169E46BDE6f on both.
//
// Live migration data (subgraphs, 2026-08-04): 9 Gnosis orgs + 1 Arbitrum org, each mapped to
// its module typeIds below. All were bootstrap-deployed with autoUpgrade=true, so they stay in
// the default Mirror rules mode (no mode writes needed) and the rulebook covers them the moment
// Step3+Step4 land. UniversalAccountRegistry / OrgRegistry per chain resolved on-chain
// (hub.getOnboardingConfig().accountRegistry / OrgDeployer layout slot+3).
//
// ABI COMPATIBILITY: DeployConfig grew 3 appended fields, changing registerAndConfigureOrg's
// selector (old 0xc6f422d9 → new 0x8eac29d9). The v20 hub keeps a LEGACY overload with the old
// selector, so the LIVE OrgDeployer proxies keep deploying orgs (address-keyed local rules,
// exactly as today) with NO lockstep requirement — Step6 upgrades the OrgDeployer beacon to the
// type-registering deployer whenever convenient. Both sims exercise the legacy selector.
//
// Order per chain: Step1 (impl) → Step2 (beacon upgrade) → Step3 (seed rulebook)
//                  → Step4 (org target types) → Step5 (redeploy Lens) → Step6 (OrgDeployer v20 —
//                  v19 is reserved by UpgradeOrgDeployerZkEmailRules; re-probe both surfaces
//                  before broadcast).
//
// Sims (run BOTH before any broadcast):
//   FOUNDRY_PROFILE=production forge script script/upgrades/UpgradePaymasterGlobalRules.s.sol:SimGnosis \
//     --fork-url gnosis -vvv
//   FOUNDRY_PROFILE=production forge script script/upgrades/UpgradePaymasterGlobalRules.s.sol:SimArbitrum \
//     --fork-url arbitrum -vvv
// ─────────────────────────────────────────────────────────────────────────────

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant ARB_PAYMASTER = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;
address constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // PoaManagerSatellite
address constant ADMIN_EOA = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
string constant VERSION = "v20";
// v19 is reserved by UpgradeOrgDeployerZkEmailRules (the pre-rulebook zk-selector fix);
// the type-registering deployer ships as v20 regardless of whether v19 was broadcast.
string constant ORG_DEPLOYER_VERSION = "v20";

/// @dev Selector of the pre-rulebook registerAndConfigureOrg — the one the LIVE OrgDeployer
///      proxies call. The v20 hub MUST keep answering it (legacy overload).
bytes4 constant LEGACY_REGISTER_AND_CONFIGURE_SELECTOR = 0xc6f422d9;

// Shared registries (target-typed so gasless profile/metadata calls resolve via the rulebook)
address constant GNOSIS_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
address constant GNOSIS_ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
address constant ARB_ACCOUNT_REGISTRY = 0x01A13c92321E9CA2C02577b92A4F8d2FDC4d8513;
address constant ARB_ORG_REGISTRY = 0x7B023B9566b96616D54935AE8De80579c93f62aC;

/// @dev Satellite/Hub adminCall forwards through the local PoaManager, so the hub sees
///      msg.sender == poaManager and the poaManager-gated paths (setGlobalRulesBatch,
///      setTargetTypesBatch bypass, unpause, registrar) all pass.
interface IGnosisSatellite {
    function owner() external view returns (address);
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Live-org target-type migration data (generated from the Poa subgraphs 2026-08-04)
// ─────────────────────────────────────────────────────────────────────────────

abstract contract TargetTypesData {
    struct OrgTargets {
        bytes32 orgId;
        address[] targets;
        bytes32[] typeIds;
    }

    /// @dev Standard 8-module org layout (no ZkEmailInvites) + the two shared registries.
    function _org8(
        bytes32 orgId,
        address quickJoin,
        address taskManager,
        address hybridVoting,
        address ddVoting,
        address paymentManager,
        address eligibility,
        address token,
        address educationHub,
        address acctReg,
        address orgReg
    ) internal pure returns (OrgTargets memory o) {
        o.orgId = orgId;
        o.targets = new address[](10);
        o.typeIds = new bytes32[](10);
        o.targets[0] = quickJoin;
        o.typeIds[0] = ModuleTypes.QUICK_JOIN_ID;
        o.targets[1] = taskManager;
        o.typeIds[1] = ModuleTypes.TASK_MANAGER_ID;
        o.targets[2] = hybridVoting;
        o.typeIds[2] = ModuleTypes.HYBRID_VOTING_ID;
        o.targets[3] = ddVoting;
        o.typeIds[3] = ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID;
        o.targets[4] = paymentManager;
        o.typeIds[4] = ModuleTypes.PAYMENT_MANAGER_ID;
        o.targets[5] = eligibility;
        o.typeIds[5] = ModuleTypes.ELIGIBILITY_MODULE_ID;
        o.targets[6] = token;
        o.typeIds[6] = ModuleTypes.PARTICIPATION_TOKEN_ID;
        o.targets[7] = educationHub;
        o.typeIds[7] = ModuleTypes.EDUCATION_HUB_ID;
        o.targets[8] = acctReg;
        o.typeIds[8] = ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID;
        o.targets[9] = orgReg;
        o.typeIds[9] = ModuleTypes.ORG_REGISTRY_ID;
    }

    /// @dev 8-module org + ZkEmailInvites + the two shared registries.
    function _org9(OrgTargets memory base, address zkEmailInvites) internal pure returns (OrgTargets memory o) {
        o.orgId = base.orgId;
        uint256 n = base.targets.length;
        o.targets = new address[](n + 1);
        o.typeIds = new bytes32[](n + 1);
        for (uint256 i = 0; i < n; i++) {
            o.targets[i] = base.targets[i];
            o.typeIds[i] = base.typeIds[i];
        }
        o.targets[n] = zkEmailInvites;
        o.typeIds[n] = ModuleTypes.ZKEMAIL_INVITES_ID;
    }

    function _gnosisOrgs() internal pure returns (OrgTargets[] memory orgs) {
        orgs = new OrgTargets[](9);
        address ar = GNOSIS_ACCOUNT_REGISTRY;
        address orr = GNOSIS_ORG_REGISTRY;
        // Argus
        orgs[0] = _org8(
            0x112de94b6e6cba0ccece7301df866a932711655946942d795f07334e3fd6f46b,
            0xD942D29601aBFbce51a67618938B5cb07Fe4EFBD,
            0xd17D6038eD29aC294cf8cDC4eFC87d30261b77DC,
            0xa9209AfAdF721C2a55eC5875CC4716a9F1C5b0b7,
            0xe675763055700fbb05163c146598Aa6D7DC20827,
            0x409F51250dC5C66BB1D6952f947D841192f1140e,
            0xB37a97C8136F6d300C399162cEfAb5B61c675cAF,
            0x5cafc2FA0653b34BDC51d738D67E70409A4b4806,
            0x5D5a2bbCE6718C38622b900215586222c747Cf7e,
            ar,
            orr
        );
        // Test3
        orgs[1] = _org8(
            0x204558076efb2042ebc9b034aab36d85d672d8ac1fa809288da5b453a4714aae,
            0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8,
            0x8f5BD281Eb4794Fc3eafFD2e558691FB98b815d7,
            0xaB09811a03143C528Bb1C670a52f19F968BEB9c9,
            0x2C2338CBEE744f086C8Fc229b58335e1F0b3d4f5,
            0x7bF9FF6cb7bE5180B383C4F8FaB55ff28c5c4eC6,
            0x2cF31A59e474e697370daffF78Fc5Cf6D23E5F9C,
            0x5f63C2F6cBBbd17267Af39b6375319D3761f2DE4,
            0x8Abe743864DF61055219d77abDfc72e23AD0BccE,
            ar,
            orr
        );
        // Test6 (has ZkEmailInvites)
        orgs[2] = _org9(
            _org8(
                0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b,
                0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d,
                0x3d93f0D090356D25E7a1614F0F8764b103ca99bc,
                0xF642DdE77848dC195c8089F4042A311Ed650d7a6,
                0xd2667117ED47aD259fEf73F54f31a3eF9A5D889F,
                0x10E96701746B567882b74E39a24AEe7267c22Bb5,
                0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B,
                0x6083c52b2F5861F327526bD646EaA754edDD5cCf,
                0x6a29222E29FDc0000AbA55329DfF0a50D9a8e8F9,
                ar,
                orr
            ),
            0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2
        );
        // Decentral Park
        orgs[3] = _org8(
            0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78,
            0xBEba9EF99aa6E0693c22b60d4Ea5ed7C395F26f1,
            0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7,
            0x1B80CA1EF7F274E141658A666fc12277957bF7A1,
            0xF3e3EB13214D9F98e6115e3C2602aE66340CD575,
            0xebC2224Dc7Ee7DdcE889e49685dB095780Be17a1,
            0xe4A02F20B8282A272879e31479Ee070dab07B015,
            0x1A8b31903C98e514332991a70C00566ec2DeE14e,
            0x80a78A0b7E0d491B7cc4cF0bAFe8bce3be9e1454,
            ar,
            orr
        );
        // Test2
        orgs[4] = _org8(
            0x4da432f1ecd4c0ac028ebde3a3f78510a21d54087b161590a63080d33b702b8d,
            0x14Aced4F1B6fB1EF4030E7E7E19A3e6aB0B931a1,
            0xD89c1B5872D7D66d00B4Aa737682DD7660998d34,
            0xFFe27f0C75E9B0C96D9B41A07D3035F61380c89d,
            0x30459389b46391c730534F8118637AF19FD251fC,
            0x2B09C556Be0E8e8C1D43143ffF411062123189Bc,
            0xEd3F68663dC51f1499F4A574B2eDA15efc3a3580,
            0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5,
            0x7d01F85d1B0FAD1fE50efC8111d1579987bC57A4,
            ar,
            orr
        );
        // Test
        orgs[5] = _org8(
            0x9c22ff5f21f0b81b113e63f7db6da94fedef11b2119b4088b89664fb9a3cb658,
            0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41,
            0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a,
            0x150c21831BB8cCf397EB33deA4315E4DC7818abA,
            0xd466Cd1bE97747828a8eE7982021874aa8413ae0,
            0xcCD256221DECFF032f38fBd84E01651a4De6d82F,
            0x76a0225F4Ac5fA105F4D294ba4e9C1D3fb7D6601,
            0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b,
            0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E,
            ar,
            orr
        );
        // Test5
        orgs[6] = _org8(
            0x9e199fafc1079dfb2b375cdac741cefb6c51d5f471f8afffa517442b6160463c,
            0x5378548e0E4523A16a9AdADD7Aa227d9814096a2,
            0x4daA78FAA39ee9011f17c99Bea620fc8478CAce2,
            0x639A22665366c1Ce1D2917e28e31aF3826887128,
            0xB47Ef9562bFf0322d096Ddc183d12aE2eCDb8A49,
            0xb4Bdc5B29BFb69e8FAE0B899E6B5a436B9eDeD6f,
            0xfCCAb58A9222CA5c550981930d5b9C3b3E99a198,
            0xb13ab847458D64fcDd0bd71c70B0bc4622DacfcF,
            0x01C9c2d6cbe47c73Fd3656f7cB78B7C869D18f98,
            ar,
            orr
        );
        // KUBI (has ZkEmailInvites)
        orgs[7] = _org9(
            _org8(
                0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e,
                0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf,
                0xF57024fC77915Fce8f2608afdd027941bCEE3336,
                0x13CBd5eD47bF177968B24D84516a75879c23971E,
                0xe24Cb844C73095569FA146D673D45c252894200f,
                0x4009c825b38Fb0ebB6391d5FABe4FAf90e178dF1,
                0x27114Cb757BeDF77E30EeB0Ca635e3368d8C2914,
                0x23641B4b54E1bf63FD519b242407b9314093B33C,
                0x83C7Aa49C0C5a55E22640AC164abA838E6f1f7ae,
                ar,
                orr
            ),
            0x32cc2D8563e691A3Ca43723A9F558f7AD8dbA9ec
        );
        // tkrjehbcuebc
        orgs[8] = _org8(
            0xf8eb3652e8f049128d4e3c9315875697f42990714f5e3410f15458805cc9073c,
            0x50876A6A46879AA4922a242f6dAA2f220D120996,
            0x5FD3d65Eb46eD4258E5D94902ada696188079E1f,
            0xf5331F8FA5a9946e27beFE1D8dE257A8C99AF919,
            0x53C30146deD3Bd00788F222dF870688feECFCFbb,
            0x851808C371F5Ac05499BfC1B5958AF0B20F76CA7,
            0xf842787abFb3812a6231BAca65fA35FD57828cEb,
            0x504C218d9A8D5706505f8890be6449a5408DEB44,
            0x28dbcC45Df2e9A2e6665570BECBDdc14d0a62D46,
            ar,
            orr
        );
    }

    function _arbOrgs() internal pure returns (OrgTargets[] memory orgs) {
        orgs = new OrgTargets[](1);
        // Poa (governance org)
        orgs[0] = _org8(
            0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069,
            0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a,
            0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0,
            0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5,
            0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8,
            0xAe470B8366AF331F52D9eA26efD7Cb2d276878B3,
            0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b,
            0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E,
            0xe37Db8cCD295C9E4fEbb19a91efe13aCe24ca596,
            ARB_ACCOUNT_REGISTRY,
            ARB_ORG_REGISTRY
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Broadcast steps
// ─────────────────────────────────────────────────────────────────────────────

/// @title Step1_DeployImplGnosis — deploy PaymasterHub v20 impl on Gnosis via DD (CREATE3).
/// Usage: FOUNDRY_PROFILE=production forge script .../UpgradePaymasterGlobalRules.s.sol:Step1_DeployImplGnosis \
///        --rpc-url gnosis --broadcast --slow --optimizer-runs 1
contract Step1_DeployImplGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("PaymasterHub", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted PaymasterHub v20 impl:", predicted);
        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }
        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(PaymasterHub).creationCode);
        vm.stopBroadcast();
        require(deployed == predicted, "Address mismatch");
        require(deployed.code.length <= 24576, "impl exceeds EIP-170 -- lower --optimizer-runs");
        console.log("Deployed:", deployed);
    }
}

/// @title Step1b_DeployImplArbitrum — same, on Arbitrum.
contract Step1b_DeployImplArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("PaymasterHub", VERSION);
        address predicted = dd.computeAddress(salt);
        if (predicted.code.length > 0) {
            console.log("Already deployed. Skipping.");
            return;
        }
        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(PaymasterHub).creationCode);
        vm.stopBroadcast();
        require(deployed == predicted, "Address mismatch");
        require(deployed.code.length <= 24576, "impl exceeds EIP-170 -- lower --optimizer-runs");
        console.log("Deployed:", deployed);
    }
}

/// @title Step2_UpgradeGnosis — point the Gnosis PaymasterHub beacon at v20 (destination-chain
///        direct path; no Hyperlane fee/wait). Registers (PaymasterHub, v20) in the registry.
contract Step2_UpgradeGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IGnosisSatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address impl = dd.computeAddress(dd.computeSalt("PaymasterHub", VERSION));
        require(impl.code.length > 0, "run Step1 first");
        vm.startBroadcast(deployerKey);
        IGnosisSatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("PaymasterHub", impl, VERSION);
        vm.stopBroadcast();
        console.log("Gnosis PaymasterHub beacon upgraded to v20:", impl);
    }
}

/// @title Step2b_UpgradeArbitrum — same via PoaManagerHub.upgradeBeaconLocal.
contract Step2b_UpgradeArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(PoaManagerHub(payable(HUB)).owner() == vm.addr(deployerKey), "signer must own the Hub");
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address impl = dd.computeAddress(dd.computeSalt("PaymasterHub", VERSION));
        require(impl.code.length > 0, "run Step1b first");
        vm.startBroadcast(deployerKey);
        PoaManagerHub(payable(HUB)).upgradeBeaconLocal("PaymasterHub", impl, VERSION);
        vm.stopBroadcast();
        console.log("Arbitrum PaymasterHub beacon upgraded to v20:", impl);
    }
}

/// @title Step3_SeedRulebookGnosis — seed the global rulebook with the canonical default set.
/// @dev Routed through Satellite.adminCall → PoaManager.adminCall so the hub sees poaManager
///      (independent of protocolAdmin state). Idempotent: entries are pure upserts.
contract Step3_SeedRulebookGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IGnosisSatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) =
            DefaultGlobalRules.defaults();
        vm.startBroadcast(deployerKey);
        IGnosisSatellite(GNOSIS_SATELLITE)
            .adminCall(
                GNOSIS_PAYMASTER, abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
            );
        vm.stopBroadcast();
        uint256 count = PaymasterHub(payable(GNOSIS_PAYMASTER)).getGlobalRuleCount();
        console.log("Gnosis global rulebook seeded. Entries:", count);
        require(count >= typeIds.length, "rulebook count below seed size");
    }
}

/// @title Step3b_SeedRulebookArbitrum — same via PoaManagerHub.adminCall.
contract Step3b_SeedRulebookArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(PoaManagerHub(payable(HUB)).owner() == vm.addr(deployerKey), "signer must own the Hub");
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) =
            DefaultGlobalRules.defaults();
        vm.startBroadcast(deployerKey);
        PoaManagerHub(payable(HUB))
            .adminCall(
                ARB_PAYMASTER, abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
            );
        vm.stopBroadcast();
        uint256 count = PaymasterHub(payable(ARB_PAYMASTER)).getGlobalRuleCount();
        console.log("Arbitrum global rulebook seeded. Entries:", count);
        require(count >= typeIds.length, "rulebook count below seed size");
    }
}

/// @title Step4_RegisterTargetTypesGnosis — map every live Gnosis org's modules to typeIds.
/// @dev One adminCall per org (poaManager bypass on setTargetTypesBatch). All live orgs are
///      Mirror-mode by default, so this is the switch that turns the rulebook ON for them.
contract Step4_RegisterTargetTypesGnosis is Script, TargetTypesData {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IGnosisSatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        OrgTargets[] memory orgs = _gnosisOrgs();
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < orgs.length; i++) {
            IGnosisSatellite(GNOSIS_SATELLITE)
                .adminCall(
                    GNOSIS_PAYMASTER,
                    abi.encodeCall(PaymasterHub.setTargetTypesBatch, (orgs[i].orgId, orgs[i].targets, orgs[i].typeIds))
                );
        }
        vm.stopBroadcast();
        console.log("Gnosis target types registered for", orgs.length, "orgs");
    }
}

/// @title Step4b_RegisterTargetTypesArbitrum — same for the Arbitrum org(s).
contract Step4b_RegisterTargetTypesArbitrum is Script, TargetTypesData {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(PoaManagerHub(payable(HUB)).owner() == vm.addr(deployerKey), "signer must own the Hub");
        OrgTargets[] memory orgs = _arbOrgs();
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < orgs.length; i++) {
            PoaManagerHub(payable(HUB))
                .adminCall(
                    ARB_PAYMASTER,
                    abi.encodeCall(PaymasterHub.setTargetTypesBatch, (orgs[i].orgId, orgs[i].targets, orgs[i].typeIds))
                );
        }
        vm.stopBroadcast();
        console.log("Arbitrum target types registered for", orgs.length, "orgs");
    }
}

/// @title Step5_RedeployLensGnosis / Step5b_RedeployLensArbitrum — redeploy PaymasterHubLens.
/// @dev wouldValidate/isAllowed now resolve through the global rulebook and effectiveRuleOf is
///      new. Update the Lens address in the frontend/bundler preflight config after broadcast.
contract Step5_RedeployLensGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vm.startBroadcast(deployerKey);
        PaymasterHubLens lens = new PaymasterHubLens(GNOSIS_PAYMASTER);
        vm.stopBroadcast();
        console.log("New Gnosis PaymasterHubLens:", address(lens));
        console.log("ACTION: update the Lens address in the frontend/bundler preflight config.");
    }
}

contract Step5b_RedeployLensArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vm.startBroadcast(deployerKey);
        PaymasterHubLens lens = new PaymasterHubLens(ARB_PAYMASTER);
        vm.stopBroadcast();
        console.log("New Arbitrum PaymasterHubLens:", address(lens));
        console.log("ACTION: update the Lens address in the frontend/bundler preflight config.");
    }
}

/// @title Step6_UpgradeOrgDeployerGnosis — deploy the type-registering OrgDeployer + upgrade
///        its beacon. NOT time-critical: until this lands, the old deployer keeps working via
///        the hub's legacy registerAndConfigureOrg overload (orgs get address-keyed local rules
///        as today); after it, new orgs get target types + Mirror resolution instead.
contract Step6_UpgradeOrgDeployerGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IGnosisSatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("OrgDeployer", ORG_DEPLOYER_VERSION);
        address predicted = dd.computeAddress(salt);
        vm.startBroadcast(deployerKey);
        if (predicted.code.length == 0) {
            dd.deploy(salt, type(OrgDeployer).creationCode);
        }
        require(predicted.code.length <= 24576, "impl exceeds EIP-170 -- lower --optimizer-runs");
        IGnosisSatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", predicted, ORG_DEPLOYER_VERSION);
        vm.stopBroadcast();
        console.log("Gnosis OrgDeployer beacon upgraded:", predicted);
    }
}

/// @title Step6b_UpgradeOrgDeployerArbitrum — same via PoaManagerHub.upgradeBeaconLocal.
contract Step6b_UpgradeOrgDeployerArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(PoaManagerHub(payable(HUB)).owner() == vm.addr(deployerKey), "signer must own the Hub");
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("OrgDeployer", ORG_DEPLOYER_VERSION);
        address predicted = dd.computeAddress(salt);
        vm.startBroadcast(deployerKey);
        if (predicted.code.length == 0) {
            dd.deploy(salt, type(OrgDeployer).creationCode);
        }
        require(predicted.code.length <= 24576, "impl exceeds EIP-170 -- lower --optimizer-runs");
        PoaManagerHub(payable(HUB)).upgradeBeaconLocal("OrgDeployer", predicted, ORG_DEPLOYER_VERSION);
        vm.stopBroadcast();
        console.log("Arbitrum OrgDeployer beacon upgraded:", predicted);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Simulations — run under FOUNDRY_PROFILE=production against live forks.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract SimBase is Script, TargetTypesData {
    uint8 constant SUBJECT_TYPE_ACCOUNT = 0x00;

    /// @dev The LIVE OrgDeployer must keep working across the hub upgrade: replicate its exact
    ///      call — the OLD 13-field registerAndConfigureOrg selector — and prove the legacy
    ///      overload registers the org and applies address-keyed local rules as before.
    function _simLegacyRegisterAndConfigure(PaymasterHub pm, address poaMgr) internal {
        // The legacy overload's selector must be byte-identical to what the deployed
        // OrgDeployer bytecode emits (0xc6f422d9).
        bytes4 computed = bytes4(
            keccak256(
                "registerAndConfigureOrg(bytes32,uint256,(uint256,uint256,uint256,uint32,uint32,uint32,address[],bytes4[],bool[],uint32[],bytes32[],uint128[],uint32[]))"
            )
        );
        require(computed == LEGACY_REGISTER_AND_CONFIGURE_SELECTOR, "SIM: legacy selector drifted");

        bytes32 org = keccak256(abi.encodePacked("legacy-abi-sim", vm.getBlockTimestamp()));
        address legacyTarget = address(0x1E6ACC);
        bytes4 legacySel = bytes4(keccak256("doLegacyThing()"));

        PaymasterRuleLib.LegacyDeployConfig memory cfg;
        cfg.ruleTargets = new address[](1);
        cfg.ruleTargets[0] = legacyTarget;
        cfg.ruleSelectors = new bytes4[](1);
        cfg.ruleSelectors[0] = legacySel;
        cfg.ruleAllowed = new bool[](1);
        cfg.ruleAllowed[0] = true;
        cfg.ruleMaxCallGasHints = new uint32[](1);

        vm.prank(poaMgr);
        (bool ok,) =
            address(pm).call(abi.encodeWithSelector(LEGACY_REGISTER_AND_CONFIGURE_SELECTOR, org, uint256(1), cfg));
        require(ok, "SIM: legacy registerAndConfigureOrg reverted -- live OrgDeployer would brick");
        require(pm.getOrgConfig(org).adminHatId == 1, "SIM: legacy path did not register org");
        require(pm.getRule(org, legacyTarget, legacySel).allowed, "SIM: legacy path did not seed local rule");
        require(pm.getRulesMode(org) == 0 && pm.getTargetType(org, legacyTarget) == bytes32(0), "SIM: legacy defaults");
        console.log("SIM: legacy 13-field registerAndConfigureOrg selector still served (no deployer lockstep).");
    }

    /// @dev End-to-end proof on live state: register a throwaway Mirror org whose ONLY rule
    ///      coverage is the freshly seeded global rulebook, fund it, and validate a userOp
    ///      calling TaskManager.claimTask through the type mapping. Then prove Static mode and
    ///      the per-pair block both deny.
    function _simEndToEnd(PaymasterHub pm, address poaMgr) internal {
        bytes32 org = keccak256(abi.encodePacked("global-rules-sim", vm.getBlockTimestamp()));
        address fakeTaskManager = address(0x7A5C7A5C);
        address sender = address(0xD00D);
        bytes4 claimSel = bytes4(keccak256("claimTask(uint256)"));

        // Register with target types + Mirror mode via the registrar (poaManager) path.
        PaymasterRuleLib.DeployConfig memory cfg;
        cfg.typeTargets = new address[](1);
        cfg.typeTargets[0] = fakeTaskManager;
        cfg.typeIds = new bytes32[](1);
        cfg.typeIds[0] = ModuleTypes.TASK_MANAGER_ID;
        vm.prank(poaMgr);
        pm.registerAndConfigureOrg(org, 1, cfg);
        require(pm.getRulesMode(org) == 0, "SIM: fresh org not in Mirror mode");
        require(pm.getTargetType(org, fakeTaskManager) == ModuleTypes.TASK_MANAGER_ID, "SIM: target type not set");

        // Budget for the account subject + org deposit so rules are the binding constraint.
        bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(sender)))));
        vm.prank(poaMgr);
        pm.setBudget(org, subjectKey, type(uint128).max, 7 days);
        address funder = address(0xF00D11);
        vm.deal(funder, 2 ether);
        vm.prank(funder);
        pm.depositForOrg{value: 1 ether}(org);

        // No local rule exists — validation must resolve through the GLOBAL rulebook.
        require(!pm.getRule(org, fakeTaskManager, claimSel).allowed, "SIM: unexpected local rule");
        PackedUserOperation memory op = _op(address(pm), org, sender, fakeTaskManager, claimSel);
        address ep = pm.ENTRY_POINT();
        vm.prank(ep);
        (, uint256 vd) = pm.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
        require(vd == 0, "SIM: global-rule validation failed");
        console.log("SIM: userOp validated via global rulebook (no local rules).");

        // Static mode denies the global fallback...
        vm.prank(poaMgr);
        pm.setRulesMode(org, 1);
        vm.prank(ep);
        (bool okStatic,) =
            address(pm).call(abi.encodeCall(PaymasterHub.validatePaymasterUserOp, (op, bytes32(0), 0.001 ether)));
        require(!okStatic, "SIM: Static mode failed to deny global rule");
        vm.prank(poaMgr);
        pm.setRulesMode(org, 0);

        // ...and so does a per-pair block, without leaving Mirror mode.
        vm.prank(poaMgr);
        pm.setGlobalRuleBlock(org, fakeTaskManager, claimSel, true);
        vm.prank(ep);
        (bool okBlocked,) =
            address(pm).call(abi.encodeCall(PaymasterHub.validatePaymasterUserOp, (op, bytes32(0), 0.001 ether)));
        require(!okBlocked, "SIM: block veto failed to deny global rule");
        console.log("SIM: Static mode + block veto both deny as designed.");
    }

    function _op(address pm, bytes32 orgId, address sender, address target, bytes4 selector)
        internal
        pure
        returns (PackedUserOperation memory op)
    {
        bytes memory innerCall = abi.encodeWithSelector(selector, uint256(1));
        op.sender = sender;
        op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", target, 0, innerCall);
        op.accountGasLimits = bytes32(uint256(100_000) << 128 | uint256(100_000));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        bytes memory pmData = abi.encodePacked(
            uint8(1), orgId, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(sender))), uint32(0), uint64(0)
        );
        op.paymasterAndData = abi.encodePacked(pm, uint128(200_000), uint128(100_000), pmData);
    }

    /// @dev The registered orgs' target types must match the migration data, and effective
    ///      resolution must allow TaskManager.unclaimTask — the v7 selector that today requires
    ///      a per-org vote — purely via the rulebook.
    function _assertOrgCoverage(PaymasterHub pm, OrgTargets[] memory orgs) internal {
        PaymasterHubLens lens = new PaymasterHubLens(address(pm));
        bytes4 unclaimSel = bytes4(keccak256("unclaimTask(uint256)"));
        for (uint256 i = 0; i < orgs.length; i++) {
            // Skip orgs that never registered with the paymaster (defensive).
            if (pm.getOrgConfig(orgs[i].orgId).adminHatId == 0) {
                console.log("SIM: org not registered with hub, skipped:");
                console.logBytes32(orgs[i].orgId);
                continue;
            }
            address taskManager;
            for (uint256 j = 0; j < orgs[i].targets.length; j++) {
                require(
                    pm.getTargetType(orgs[i].orgId, orgs[i].targets[j]) == orgs[i].typeIds[j],
                    "SIM: target type mismatch"
                );
                if (orgs[i].typeIds[j] == ModuleTypes.TASK_MANAGER_ID) taskManager = orgs[i].targets[j];
            }
            (bool allowed,, uint8 source) = lens.effectiveRuleOf(orgs[i].orgId, taskManager, unclaimSel);
            require(allowed, "SIM: unclaimTask not covered by rulebook for live org");
            require(source == 2 || pm.getRule(orgs[i].orgId, taskManager, unclaimSel).allowed, "SIM: bad source");
        }
        console.log("SIM: all registered orgs resolve unclaimTask via the rulebook.");
    }

    function _seedViaAdminCall(PaymasterHub pm, function(address, bytes memory) internal returns (bytes memory) call)
        internal
    {
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) =
            DefaultGlobalRules.defaults();
        call(address(pm), abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints)));
        require(pm.getGlobalRuleCount() == typeIds.length, "SIM: rulebook count mismatch");
        // Spot checks: TaskManager claim + the zk-email hint.
        require(
            pm.getGlobalRule(ModuleTypes.TASK_MANAGER_ID, bytes4(keccak256("claimTask(uint256)"))).allowed,
            "SIM: claimTask missing from rulebook"
        );
        bytes4 zkSel = ZkEmailInvites.claimRoleByDomain.selector;
        require(
            pm.getGlobalRule(ModuleTypes.ZKEMAIL_INVITES_ID, zkSel).maxCallGasHint == 800_000,
            "SIM: zk-email gas hint wrong"
        );
        console.log("SIM: rulebook seeded + spot checks OK. Entries:", pm.getGlobalRuleCount());
    }
}

/**
 * @title SimGnosis
 * @notice Fork-sim of the FULL v20 rollout against LIVE Gnosis state:
 *   (1) beacon upgrade via Satellite.upgradeBeaconDirect (pranked ADMIN_EOA);
 *   (2) pre/post storage survival on a live org's financials + an existing local rule;
 *   (3) rulebook seed via Satellite.adminCall (poaManager path) + spot checks;
 *   (4) target-type registration for all 9 live orgs + effective unclaimTask coverage;
 *   (5) end-to-end validatePaymasterUserOp for a throwaway Mirror org with ZERO local rules;
 *   (6) Static-mode + block-veto denials; (7) stranger cannot touch the rulebook.
 *
 * FOUNDRY_PROFILE=production forge script script/upgrades/UpgradePaymasterGlobalRules.s.sol:SimGnosis \
 *   --fork-url gnosis -vvv
 */
contract SimGnosis is SimBase {
    // Test6's live zk-email rule (set on-chain) — used as the storage-survival witness.
    bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address constant TEST6_ZK = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2;
    bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;

    function run() public {
        PaymasterHub pm = PaymasterHub(payable(GNOSIS_PAYMASTER));
        bytes4 zkSel = ZkEmailInvites.claimRoleByDomain.selector;

        // Pre-upgrade witnesses.
        PaymasterHub.OrgFinancials memory preFin = pm.getOrgFinancials(KUBI_ORG);
        bool preZkRule = pm.getRule(TEST6_ORG, TEST6_ZK, zkSel).allowed;

        // 1. Deploy new impl (libs auto-deployed in-fork) + upgrade the beacon as ADMIN_EOA.
        address newImpl = address(new PaymasterHub());
        require(newImpl.code.length <= 24576, "SIM: impl exceeds EIP-170");
        console.log("SIM Gnosis impl size:", newImpl.code.length);
        vm.prank(ADMIN_EOA);
        IGnosisSatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("PaymasterHub", newImpl, VERSION);
        require(
            PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("PaymasterHub")) == newImpl,
            "SIM: beacon not upgraded"
        );

        // 2. Storage survived; new namespaces start empty; live orgs default to Mirror.
        PaymasterHub.OrgFinancials memory postFin = pm.getOrgFinancials(KUBI_ORG);
        require(preFin.deposited == postFin.deposited && preFin.spent == postFin.spent, "SIM: financials drifted");
        require(pm.getRule(TEST6_ORG, TEST6_ZK, zkSel).allowed == preZkRule, "SIM: local rule drifted");
        require(pm.getGlobalRuleCount() == 0, "SIM: rulebook should start empty");
        require(pm.getRulesMode(TEST6_ORG) == 0, "SIM: live org should default to Mirror");
        console.log("SIM Gnosis: storage survived upgrade; rulebook empty; Mirror default.");

        // 3. Stranger cannot write the rulebook.
        bytes32[] memory t1 = new bytes32[](1);
        t1[0] = ModuleTypes.TASK_MANAGER_ID;
        bytes4[] memory s1 = new bytes4[](1);
        bool[] memory a1 = new bool[](1);
        a1[0] = true;
        uint32[] memory h1 = new uint32[](1);
        vm.prank(address(0xBADBAD));
        (bool okBad,) = GNOSIS_PAYMASTER.call(abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (t1, s1, a1, h1)));
        require(!okBad, "SIM: stranger seeded the rulebook");

        // 4. Seed via the Satellite adminCall (poaManager path) + spot checks.
        _seedViaAdminCall(pm, _satelliteAdminCall);

        // 5. Register target types for all live orgs + assert unclaimTask coverage.
        OrgTargets[] memory orgs = _gnosisOrgs();
        for (uint256 i = 0; i < orgs.length; i++) {
            _satelliteAdminCall(
                GNOSIS_PAYMASTER,
                abi.encodeCall(PaymasterHub.setTargetTypesBatch, (orgs[i].orgId, orgs[i].targets, orgs[i].typeIds))
            );
        }
        _assertOrgCoverage(pm, orgs);

        // 6. The LIVE OrgDeployer's legacy ABI keeps working (no bricking window).
        _simLegacyRegisterAndConfigure(pm, GNOSIS_POA_MANAGER);

        // 7. Full end-to-end validation on a throwaway Mirror org.
        _simEndToEnd(pm, GNOSIS_POA_MANAGER);

        // 8. Step6 mechanics: OrgDeployer v19 beacon upgrade path works.
        address newDeployerImpl = address(new OrgDeployer());
        vm.prank(ADMIN_EOA);
        IGnosisSatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", newDeployerImpl, ORG_DEPLOYER_VERSION);
        require(
            PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer")) == newDeployerImpl,
            "SIM: OrgDeployer beacon not upgraded"
        );
        console.log("SIM: OrgDeployer beacon upgrade OK.");

        console.log("PASS: SimGnosis - v20 global rulebook validated against live Gnosis state.");
    }

    function _satelliteAdminCall(address target, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(ADMIN_EOA);
        ret = IGnosisSatellite(GNOSIS_SATELLITE).adminCall(target, data);
    }
}

/**
 * @title SimArbitrum
 * @notice Same rollout sim against LIVE Arbitrum state (Hub.upgradeBeaconLocal + Hub.adminCall).
 *
 * FOUNDRY_PROFILE=production forge script script/upgrades/UpgradePaymasterGlobalRules.s.sol:SimArbitrum \
 *   --fork-url arbitrum -vvv
 */
contract SimArbitrum is SimBase {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(ARB_PAYMASTER));

        // 1. Deploy new impl + upgrade the beacon as ADMIN_EOA (local, no Hyperlane).
        address newImpl = address(new PaymasterHub());
        require(newImpl.code.length <= 24576, "SIM: impl exceeds EIP-170");
        console.log("SIM Arbitrum impl size:", newImpl.code.length);
        vm.prank(ADMIN_EOA);
        PoaManagerHub(payable(HUB)).upgradeBeaconLocal("PaymasterHub", newImpl, VERSION);
        require(
            PoaManager(ARB_POA_MANAGER).getCurrentImplementationById(keccak256("PaymasterHub")) == newImpl,
            "SIM: beacon not upgraded"
        );
        require(pm.getGlobalRuleCount() == 0, "SIM: rulebook should start empty");

        // 2. Seed via Hub.adminCall (poaManager path) + spot checks.
        _seedViaAdminCall(pm, _hubAdminCall);

        // 3. Register target types for the live org(s) + assert unclaimTask coverage.
        OrgTargets[] memory orgs = _arbOrgs();
        for (uint256 i = 0; i < orgs.length; i++) {
            _hubAdminCall(
                ARB_PAYMASTER,
                abi.encodeCall(PaymasterHub.setTargetTypesBatch, (orgs[i].orgId, orgs[i].targets, orgs[i].typeIds))
            );
        }
        _assertOrgCoverage(pm, orgs);

        // 4. The LIVE OrgDeployer's legacy ABI keeps working (no bricking window).
        _simLegacyRegisterAndConfigure(pm, ARB_POA_MANAGER);

        // 5. Full end-to-end validation on a throwaway Mirror org.
        _simEndToEnd(pm, ARB_POA_MANAGER);

        // 6. Step6b mechanics: OrgDeployer v19 beacon upgrade path works.
        address newDeployerImpl = address(new OrgDeployer());
        vm.prank(ADMIN_EOA);
        PoaManagerHub(payable(HUB)).upgradeBeaconLocal("OrgDeployer", newDeployerImpl, ORG_DEPLOYER_VERSION);
        require(
            PoaManager(ARB_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer")) == newDeployerImpl,
            "SIM: OrgDeployer beacon not upgraded"
        );
        console.log("SIM: OrgDeployer beacon upgrade OK.");

        console.log("PASS: SimArbitrum - v20 global rulebook validated against live Arbitrum state.");
    }

    function _hubAdminCall(address target, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(ADMIN_EOA);
        ret = PoaManagerHub(payable(HUB)).adminCall(target, data);
    }
}
