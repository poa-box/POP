// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * UpgradeDeployTimeGovConfig — deploy-time governance config (HybridVoting v12, DDV v12,
 * OrgDeployer v17, GovernanceFactory/AccessFactory "v17")
 *
 * WHAT SHIPS
 *   1. HybridVoting v12 + DirectDemocracyVoting v12 — `initialize` gains a `uint32 quorum_`
 *      param (voter-count quorum, 0 = disabled), set + QuorumSet-emitted at genesis. This
 *      restores the deploy-time quorum config lost in #119 (which split threshold/quorum but
 *      only wired the new quorum as a post-deploy executor setter).
 *   2. GovernanceFactory — class hatIds backfill now uses ONLY canVote=true role hats
 *      (`_filterCanVoteHats`), restoring the pre-N-class semantic where RoleConfig.canVote
 *      decides hybrid-voting membership. Degenerate configs (zero canVote roles) fall back
 *      to the historical all-hats backfill.
 *   3. AccessFactory — ParticipationToken name/symbol are deploy params (empty = legacy
 *      "<orgName> Token"/"PT" derivation).
 *   4. OrgDeployer v17 — DeploymentParams appends `hybridQuorum`, `ddQuorum`, `tokenName`,
 *      `tokenSymbol` (all-zero values reproduce v16 behavior exactly; ABI change, so the
 *      frontend deploy flow must re-generate its OrgDeployer ABI).
 *
 * STORAGE SAFETY
 *   HybridVoting/DDV: no Layout changes (quorum field pre-exists from #119) — initialize is
 *   never re-run on live orgs; the beacon upgrade is logic-only. OrgDeployer v17 appends
 *   nothing to Layout. Factories are stateless. Sims assert live-org storage survival.
 *
 * VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-30)
 *   HybridVoting v12 / DirectDemocracyVoting v12 / OrgDeployer v17 /
 *   GovernanceFactory v17 / AccessFactory v17 — registry + CREATE3 slots FREE on both
 *   chains (impl addresses identical cross-chain via CREATE3).
 *
 * RUN ORDER (all FOUNDRY_PROFILE=production)
 *   0. SimGovConfigGnosis   --fork-url gnosis    (must PASS)
 *      SimGovConfigArbitrum --fork-url arbitrum  (must PASS)
 *   1. Step1_UpgradeGnosis   --rpc-url gnosis   --broadcast   (DD deploys + Satellite calls)
 *   2. Step2_UpgradeArbitrum --rpc-url arbitrum --broadcast   (DD deploys + Hub calls)
 *   3. Step3_Verify --fork-url gnosis ; Step3_Verify --fork-url arbitrum
*/
address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // owner = Hudson
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
address constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c; // same both chains (CREATE3)

address constant GNOSIS_ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
address constant GNOSIS_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
address constant GNOSIS_SURVIVAL_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6; // Test6

address constant ARB_ORG_REGISTRY = 0x7B023B9566b96616D54935AE8De80579c93f62aC;
address constant ARB_ACCOUNT_REGISTRY = 0x01A13c92321E9CA2C02577b92A4F8d2FDC4d8513;
address constant ARB_SURVIVAL_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5; // Poa org

string constant HV_VERSION = "v12";
string constant DDV_VERSION = "v12";
string constant OD_VERSION = "v17";
string constant GF_VERSION = "v17";
string constant AF_VERSION = "v17";

// ERC-7201 slot of OrgDeployer.Layout: governanceFactory at +0, accessFactory at +1
bytes32 constant OD_LAYOUT_SLOT = 0x47ab301f3cbd2922b7cb6ae8fac1ed203fd701e0ed4bf49685941be6a4dfb9a4;

interface ISatelliteGC {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

interface IHubGC {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
}

abstract contract GovConfigBase is Script {
    struct Impls {
        address hv;
        address ddv;
        address od;
        address gf;
        address af;
    }

    function _predicted(DeterministicDeployer dd) internal view returns (Impls memory p) {
        p.hv = dd.computeAddress(dd.computeSalt("HybridVoting", HV_VERSION));
        p.ddv = dd.computeAddress(dd.computeSalt("DirectDemocracyVoting", DDV_VERSION));
        p.od = dd.computeAddress(dd.computeSalt("OrgDeployer", OD_VERSION));
        p.gf = dd.computeAddress(dd.computeSalt("GovernanceFactory", GF_VERSION));
        p.af = dd.computeAddress(dd.computeSalt("AccessFactory", AF_VERSION));
    }

    /// @dev Idempotent CREATE3 deploy: skips slots that already hold code, but only after
    ///      the two-surface probe confirmed these slots are FREE — a takeover between probe
    ///      and broadcast would surface in Step3_Verify's bytecode-independent beacon check.
    function _deployAll(DeterministicDeployer dd) internal returns (Impls memory p) {
        p = _predicted(dd);
        _deployOne(dd, "HybridVoting", HV_VERSION, type(HybridVoting).creationCode, p.hv);
        _deployOne(dd, "DirectDemocracyVoting", DDV_VERSION, type(DirectDemocracyVoting).creationCode, p.ddv);
        _deployOne(dd, "OrgDeployer", OD_VERSION, type(OrgDeployer).creationCode, p.od);
        _deployOne(dd, "GovernanceFactory", GF_VERSION, type(GovernanceFactory).creationCode, p.gf);
        _deployOne(dd, "AccessFactory", AF_VERSION, type(AccessFactory).creationCode, p.af);
    }

    function _deployOne(
        DeterministicDeployer dd,
        string memory typeName,
        string memory version,
        bytes memory code,
        address predicted
    ) private {
        if (predicted.code.length > 0) {
            console.log(typeName, version, "already deployed:", predicted);
            return;
        }
        address deployed = dd.deploy(dd.computeSalt(typeName, version), code);
        require(deployed == predicted, "DD address mismatch");
        console.log(typeName, version, "deployed:", deployed);
    }

    /* ── test-org fixture: 2 roles (VOTER canVote, BOT !canVote), quorum 2, custom token ── */

    function _fixtureParams(address accountRegistry) internal pure returns (OrgDeployer.DeploymentParams memory) {
        return OrgDeployer.DeploymentParams({
            orgId: keccak256("govcfg-rollout-fixture"),
            orgName: "GovCfg Fixture",
            metadataHash: bytes32(0),
            registryAddr: accountRegistry,
            deployerAddress: HUDSON,
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: _fixtureClasses(),
            ddInitialTargets: new address[](0),
            roles: _fixtureRoles(),
            roleAssignments: _fixtureAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: OrgDeployer.BootstrapConfig({
                projects: new ITaskManagerBootstrap.BootstrapProjectConfig[](0),
                tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)
            }),
            paymasterConfig: OrgDeployer.PaymasterConfig({
                operatorRoleIndex: type(uint256).max,
                autoWhitelistContracts: false,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                maxCallGas: 0,
                maxVerificationGas: 0,
                maxPreVerificationGas: 0,
                defaultBudgetCapPerEpoch: 0,
                defaultBudgetEpochLen: 0
            }),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)}),
            hybridQuorum: 2,
            ddQuorum: 2,
            tokenName: "GovCfg Shares",
            tokenSymbol: "GCFG"
        });
    }

    function _fixtureRoles() private pure returns (RoleConfigStructs.RoleConfig[] memory roles) {
        roles = new RoleConfigStructs.RoleConfig[](2);
        string[2] memory names = ["VOTER", "BOT"];
        for (uint256 i; i < 2; i++) {
            roles[i] = RoleConfigStructs.RoleConfig({
                name: names[i],
                image: "",
                metadataCID: bytes32(0),
                canVote: i == 0, // BOT (role 1) cannot vote -> excluded from voting classes
                vouching: RoleConfigStructs.RoleVouchingConfig({
                    enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
                }),
                defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
                hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
                distribution: RoleConfigStructs.RoleDistributionConfig({
                    mintToDeployer: i == 0, additionalWearers: new address[](0)
                }),
                hatConfig: RoleConfigStructs.HatConfig({maxSupply: 0, mutableHat: true})
            });
        }
    }

    function _fixtureAssignments() private pure returns (OrgDeployer.RoleAssignments memory) {
        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 0x1,
            tokenMemberRolesBitmap: 0x1,
            tokenApproverRolesBitmap: 0x1,
            taskCreatorRolesBitmap: 0x1,
            educationCreatorRolesBitmap: 0x1,
            educationMemberRolesBitmap: 0x1,
            hybridProposalCreatorRolesBitmap: 0x1,
            ddVotingRolesBitmap: 0x1,
            ddCreatorRolesBitmap: 0x1
        });
    }

    function _fixtureClasses() private pure returns (IHybridVotingInit.ClassConfig[] memory classes) {
        classes = new IHybridVotingInit.ClassConfig[](2);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 80,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: new uint256[](0) // backfilled with canVote hats only (v17)
        });
        classes[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: 20,
            quadratic: false,
            minBalance: 0,
            asset: address(0), // backfilled with the org's soulbound PT
            hatIds: new uint256[](0)
        });
    }

    /// @dev Deploys the fixture org and asserts every new deploy-time knob took effect.
    function _assertFixtureOrg(address orgRegistry) internal {
        vm.prank(HUDSON);
        OrgDeployer.DeploymentResult memory r =
            OrgDeployer(ORG_DEPLOYER).deployFullOrg(_fixtureParams(_fixtureAccountRegistry()));

        require(HybridVoting(payable(r.hybridVoting)).quorum() == 2, "hybrid quorum not set at deploy");
        require(DirectDemocracyVoting(r.directDemocracyVoting).quorum() == 2, "dd quorum not set at deploy");
        require(
            keccak256(bytes(ParticipationToken(r.participationToken).name())) == keccak256("GovCfg Shares"),
            "token name not applied"
        );
        require(
            keccak256(bytes(ParticipationToken(r.participationToken).symbol())) == keccak256("GCFG"),
            "token symbol not applied"
        );

        uint256 botHat = OrgRegistry(orgRegistry).getRoleHat(keccak256("govcfg-rollout-fixture"), 1);
        require(botHat != 0, "bot hat missing");
        HybridVoting.ClassConfig[] memory cls = HybridVoting(payable(r.hybridVoting)).getClasses();
        require(cls.length == 2, "class count");
        for (uint256 i; i < cls.length; i++) {
            require(cls[i].hatIds.length == 1, "class should hold only the canVote role hat");
            require(cls[i].hatIds[0] != botHat, "canVote=false hat leaked into voting class");
        }
        require(cls[1].asset == r.participationToken, "class 1 asset should be PT");
        console.log("fixture org verified: quorum=2 (hv+dd), canVote filter, custom token identity");
    }

    function _fixtureAccountRegistry() internal view returns (address) {
        return block.chainid == 100 ? GNOSIS_ACCOUNT_REGISTRY : ARB_ACCOUNT_REGISTRY;
    }

    /* ── storage survival on a live org's HybridVoting ── */

    struct Survival {
        uint32 quorum;
        uint256 classCount;
        uint256 proposalsCount;
    }

    function _snapshot(address hv) internal view returns (Survival memory s) {
        s.quorum = HybridVoting(payable(hv)).quorum();
        s.classCount = HybridVoting(payable(hv)).getClasses().length;
        s.proposalsCount = HybridVoting(payable(hv)).proposalsCount();
    }

    function _requireSurvival(address hv, Survival memory pre) internal view {
        Survival memory post = _snapshot(hv);
        require(post.quorum == pre.quorum, "survival: quorum drifted");
        require(post.classCount == pre.classCount, "survival: classes drifted");
        require(post.proposalsCount == pre.proposalsCount, "survival: proposals drifted");
    }

    function _requireFactoryWiring(Impls memory p) internal view {
        address gf = address(uint160(uint256(vm.load(ORG_DEPLOYER, OD_LAYOUT_SLOT))));
        address af = address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_LAYOUT_SLOT) + 1)))));
        require(gf == p.gf, "governanceFactory not re-pointed");
        require(af == p.af, "accessFactory not re-pointed");
    }
}

/*═══════════════════════════ SIMS (must PASS before broadcast) ═══════════════════════════*/

contract SimGovConfigGnosis is GovConfigBase {
    function run() external {
        require(block.chainid == 100, "fork gnosis");
        Survival memory pre = _snapshot(GNOSIS_SURVIVAL_HV);

        vm.startPrank(HUDSON);
        Impls memory p = _deployAll(DeterministicDeployer(DD));
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("HybridVoting", p.hv, HV_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("DirectDemocracyVoting", p.ddv, DDV_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", p.od, OD_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE)
            .adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setGovernanceFactory(address)", p.gf));
        ISatelliteGC(GNOSIS_SATELLITE)
            .adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setAccessFactory(address)", p.af));
        vm.stopPrank();

        _requireSurvival(GNOSIS_SURVIVAL_HV, pre);
        _requireFactoryWiring(p);
        _assertFixtureOrg(GNOSIS_ORG_REGISTRY);
        console.log("\n=== PASS: SimGovConfigGnosis (upgrade + survival + fixture org) ===");
    }
}

contract SimGovConfigArbitrum is GovConfigBase {
    function run() external {
        require(block.chainid == 42161, "fork arbitrum");
        Survival memory pre = _snapshot(ARB_SURVIVAL_HV);

        vm.startPrank(HUDSON);
        Impls memory p = _deployAll(DeterministicDeployer(DD));
        IHubGC(HUB).upgradeBeaconLocal("HybridVoting", p.hv, HV_VERSION);
        IHubGC(HUB).upgradeBeaconLocal("DirectDemocracyVoting", p.ddv, DDV_VERSION);
        IHubGC(HUB).upgradeBeaconLocal("OrgDeployer", p.od, OD_VERSION);
        IHubGC(HUB).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setGovernanceFactory(address)", p.gf));
        IHubGC(HUB).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setAccessFactory(address)", p.af));
        vm.stopPrank();

        _requireSurvival(ARB_SURVIVAL_HV, pre);
        _requireFactoryWiring(p);
        _assertFixtureOrg(ARB_ORG_REGISTRY);
        console.log("\n=== PASS: SimGovConfigArbitrum (upgrade + survival + fixture org) ===");
    }
}

/*═══════════════════════════════════ BROADCASTS ═══════════════════════════════════*/

contract Step1_UpgradeGnosis is GovConfigBase {
    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1: Gnosis - deploy impls + upgrade beacons + re-point factories ===");
        vm.startBroadcast(key);
        Impls memory p = _deployAll(DeterministicDeployer(DD));
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("HybridVoting", p.hv, HV_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("DirectDemocracyVoting", p.ddv, DDV_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", p.od, OD_VERSION);
        ISatelliteGC(GNOSIS_SATELLITE)
            .adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setGovernanceFactory(address)", p.gf));
        ISatelliteGC(GNOSIS_SATELLITE)
            .adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setAccessFactory(address)", p.af));
        vm.stopBroadcast();
        console.log("\nNext: Step2_UpgradeArbitrum");
    }
}

contract Step2_UpgradeArbitrum is GovConfigBase {
    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IHubGC(HUB).owner() == vm.addr(key), "signer must own Hub");
        console.log("\n=== Step 2: Arbitrum - deploy impls + upgrade beacons + re-point factories ===");
        vm.startBroadcast(key);
        Impls memory p = _deployAll(DeterministicDeployer(DD));
        IHubGC(HUB).upgradeBeaconLocal("HybridVoting", p.hv, HV_VERSION);
        IHubGC(HUB).upgradeBeaconLocal("DirectDemocracyVoting", p.ddv, DDV_VERSION);
        IHubGC(HUB).upgradeBeaconLocal("OrgDeployer", p.od, OD_VERSION);
        IHubGC(HUB).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setGovernanceFactory(address)", p.gf));
        IHubGC(HUB).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setAccessFactory(address)", p.af));
        vm.stopBroadcast();
        console.log("\nNext: Step3_Verify on both chains");
    }
}

/// @notice Read-only: run with --fork-url <chain> (no broadcast) after each chain's step.
contract Step3_Verify is GovConfigBase {
    function run() external view {
        Impls memory p = _predicted(DeterministicDeployer(DD));
        require(p.hv.code.length > 0 && p.ddv.code.length > 0 && p.od.code.length > 0, "impls missing");
        require(p.gf.code.length > 0 && p.af.code.length > 0, "factories missing");
        _requireFactoryWiring(p);
        console.log("chainid:", block.chainid);
        console.log("HybridVoting v12:        ", p.hv);
        console.log("DirectDemocracyVoting v12:", p.ddv);
        console.log("OrgDeployer v17:         ", p.od);
        console.log("GovernanceFactory v17:   ", p.gf);
        console.log("AccessFactory v17:       ", p.af);
        console.log("factory wiring: OK");
    }
}
