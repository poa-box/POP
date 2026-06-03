// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

// Shared contract type registry (single source of truth for the 13 application types)
import {DeployHelper} from "../helpers/DeployHelper.s.sol";

// Infrastructure
import {ImplementationRegistry} from "../../src/ImplementationRegistry.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {UniversalAccountRegistry} from "../../src/UniversalAccountRegistry.sol";

// Factories
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {HatsTreeSetup} from "../../src/HatsTreeSetup.sol";

// Cross-chain
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManagerSatellite} from "../../src/crosschain/PoaManagerSatellite.sol";

// Config structs
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";

// ════════════════════════════════════════════════════════════════
//  STEP 1: Deploy Home Chain
// ════════════════════════════════════════════════════════════════

/**
 * @title DeployHomeChain
 * @notice Deploys full protocol infrastructure, governance org, DeterministicDeployer,
 *         and PoaManagerHub on the home chain. Hub ownership stays with deployer
 *         until satellites are registered (see RegisterAndTransfer).
 *
 * Environment Variables:
 *   Required: PRIVATE_KEY, MAILBOX, HUB_DOMAIN
 *     HUB_DOMAIN - Hyperlane domain ID for the home chain
 *       Ethereum=1, Arbitrum=42161, Optimism=10, Gnosis=100
 *   Optional (IPFS metadata):
 *     ORG_METADATA_HASH         - bytes32 IPFS CID sha256 digest for org metadata
 *     MEMBER_ROLE_IMAGE         - IPFS URI for MEMBER role image (e.g. "ipfs://Qm...")
 *     MEMBER_ROLE_METADATA      - bytes32 IPFS CID for MEMBER role metadata
 *     CONTRIBUTOR_ROLE_IMAGE    - IPFS URI for CONTRIBUTOR role image
 *     CONTRIBUTOR_ROLE_METADATA - bytes32 IPFS CID for CONTRIBUTOR role metadata
 *
 * Usage:
 *   PRIVATE_KEY=0x... MAILBOX=0x... HUB_DOMAIN=1 \
 *   ORG_METADATA_HASH=0x... MEMBER_ROLE_IMAGE="ipfs://Qm..." \
 *   forge script script/MainDeploy.s.sol:DeployHomeChain \
 *     --rpc-url $HOME_RPC --broadcast --slow
 */
contract DeployHomeChain is DeployHelper {
    /*═══════════════════════════ CONSTANTS ═══════════════════════════*/

    bytes32 public constant DD_SALT = keccak256("POA_DETERMINISTIC_DEPLOYER_V1");

    /*═══════════════════════════ RESULT STRUCTS ═══════════════════════════*/

    struct InfraResult {
        address poaManager;
        address implRegistry;
        address orgRegistry;
        address orgDeployer;
        address paymasterHub;
        address globalAccountRegistry;
        address universalPasskeyFactory;
        address governanceFactory;
        address accessFactory;
        address modulesFactory;
        address hatsTreeSetup;
    }

    /*═══════════════════════════ MAIN ═══════════════════════════*/

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address mailboxAddr = vm.envAddress("MAILBOX");
        uint32 hubDomain = uint32(vm.envUint("HUB_DOMAIN"));
        address deployer = vm.addr(deployerKey);

        console.log("\n=== MainDeploy: Home Chain ===");
        console.log("Deployer:", deployer);
        console.log("Mailbox:", mailboxAddr);
        console.log("Hub domain:", hubDomain);

        vm.startBroadcast(deployerKey);

        // Verify hardcoded external contracts exist on this chain
        require(HATS_PROTOCOL.code.length > 0, "Hats Protocol not deployed on this chain");
        require(ENTRY_POINT_V07.code.length > 0, "EntryPoint v0.7 not deployed on this chain");

        // 1. Deploy DeterministicDeployer
        address dd = _deployDeterministicDeployer(deployer);

        // 2. Deploy full infrastructure
        InfraResult memory infra = _deployInfrastructure(deployer);

        // 3. Deploy PoaManagerHub and transfer PoaManager ownership to it
        PoaManagerHub hub = new PoaManagerHub(infra.poaManager, mailboxAddr);
        PoaManager(infra.poaManager).transferOwnership(address(hub));
        console.log("PoaManagerHub:", address(hub));
        console.log("PoaManager ownership transferred to Hub");

        // 4. Deploy governance org
        OrgDeployer.DeploymentResult memory orgResult = _deployGovernanceOrg(infra, deployer);

        // 5. Fund Executor with ETH for Hyperlane fees
        (bool sent,) = payable(orgResult.executor).call{value: 0.005 ether}("");
        require(sent, "Failed to fund executor");
        console.log("Executor funded with 0.005 ETH for Hyperlane fees");

        // 6. Register deployer username on GlobalAccountRegistry
        string memory deployerUsername = vm.envOr("DEPLOYER_USERNAME", string("hudsonhrh"));
        if (bytes(deployerUsername).length > 0) {
            UniversalAccountRegistry globalReg = UniversalAccountRegistry(infra.globalAccountRegistry);
            if (bytes(globalReg.getUsername(deployer)).length == 0) {
                globalReg.registerAccount(deployerUsername);
                console.log("Deployer registered as:", deployerUsername);
            }
        }

        vm.stopBroadcast();

        // 7. Write state JSON
        _writeState(dd, infra, address(hub), orgResult, hubDomain);

        console.log("\n=== Home Chain Deployment Complete ===");
        console.log("Hub ownership remains with deployer for satellite registration.");
        console.log("Next: Deploy satellites, then run RegisterAndTransfer.");
    }

    /*═══════════════════════════ DETERMINISTIC DEPLOYER ═══════════════════════════*/

    function _deployDeterministicDeployer(address owner) internal returns (address) {
        bytes memory creationCode = abi.encodePacked(type(DeterministicDeployer).creationCode, abi.encode(owner));
        address predicted =
            vm.computeCreate2Address(DD_SALT, keccak256(creationCode), 0x4e59b44847b379578588920cA78FbF26c0B4956C);

        if (predicted.code.length > 0) {
            console.log("DeterministicDeployer already deployed:", predicted);
            return predicted;
        }

        DeterministicDeployer dd = new DeterministicDeployer{salt: DD_SALT}(owner);
        console.log("DeterministicDeployer:", address(dd));
        require(address(dd) == predicted, "DD address mismatch");
        return address(dd);
    }

    /*═══════════════════════════ INFRASTRUCTURE ═══════════════════════════*/

    function _deployInfrastructure(address deployer) internal returns (InfraResult memory infra) {
        // Deploy infrastructure implementations (app types deployed via _deployAndRegisterTypes below)
        address implRegImpl = address(new ImplementationRegistry());
        address orgRegImpl = address(new OrgRegistry());
        address deployerImpl = address(new OrgDeployer());

        // Deploy PoaManager
        infra.poaManager = address(new PoaManager(address(0)));
        console.log("PoaManager:", infra.poaManager);

        // Setup ImplementationRegistry
        PoaManager(infra.poaManager).addContractType("ImplementationRegistry", implRegImpl);
        address implRegBeacon = PoaManager(infra.poaManager).getBeaconById(keccak256("ImplementationRegistry"));
        bytes memory implRegInit = abi.encodeWithSignature("initialize(address)", deployer);
        infra.implRegistry = address(new BeaconProxy(implRegBeacon, implRegInit));
        PoaManager(infra.poaManager).updateImplRegistry(infra.implRegistry);
        ImplementationRegistry(infra.implRegistry)
            .registerImplementation("ImplementationRegistry", "v1", implRegImpl, true);
        ImplementationRegistry(infra.implRegistry).transferOwnership(infra.poaManager);
        console.log("ImplementationRegistry:", infra.implRegistry);

        // Register OrgRegistry and OrgDeployer
        PoaManager(infra.poaManager).addContractType("OrgRegistry", orgRegImpl);
        PoaManager(infra.poaManager).addContractType("OrgDeployer", deployerImpl);

        // Deploy OrgRegistry proxy
        address orgRegBeacon = PoaManager(infra.poaManager).getBeaconById(keccak256("OrgRegistry"));
        bytes memory orgRegInit = abi.encodeWithSignature("initialize(address,address)", deployer, HATS_PROTOCOL);
        infra.orgRegistry = address(new BeaconProxy(orgRegBeacon, orgRegInit));
        console.log("OrgRegistry:", infra.orgRegistry);

        // Deploy factories
        infra.governanceFactory = address(new GovernanceFactory());
        infra.accessFactory = address(new AccessFactory());
        infra.modulesFactory = address(new ModulesFactory());
        infra.hatsTreeSetup = address(new HatsTreeSetup());

        // Deploy PaymasterHub
        address paymasterHubImpl = address(new PaymasterHub());
        PoaManager(infra.poaManager).addContractType("PaymasterHub", paymasterHubImpl);
        address paymasterHubBeacon = PoaManager(infra.poaManager).getBeaconById(keccak256("PaymasterHub"));
        bytes memory paymasterHubInit = abi.encodeWithSignature(
            "initialize(address,address,address)", ENTRY_POINT_V07, HATS_PROTOCOL, infra.poaManager
        );
        infra.paymasterHub = address(new BeaconProxy(paymasterHubBeacon, paymasterHubInit));
        uint256 solidarityFund = vm.envOr("SOLIDARITY_FUND", INITIAL_SOLIDARITY_FUND);
        PaymasterHub(payable(infra.paymasterHub)).donateToSolidarity{value: solidarityFund}();
        console.log("PaymasterHub:", infra.paymasterHub);

        // Unpause solidarity distribution so onboarding can use the fund
        // (initialize() sets distributionPaused=true for collection-only mode)
        PoaManager(infra.poaManager)
            .adminCall(infra.paymasterHub, abi.encodeWithSignature("unpauseSolidarityDistribution()"));
        console.log("Solidarity distribution unpaused for onboarding");

        // Deploy OrgDeployer proxy
        address deployerBeacon = PoaManager(infra.poaManager).getBeaconById(keccak256("OrgDeployer"));
        bytes memory orgDeployerInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address)",
            infra.governanceFactory,
            infra.accessFactory,
            infra.modulesFactory,
            infra.poaManager,
            infra.orgRegistry,
            HATS_PROTOCOL,
            infra.hatsTreeSetup,
            infra.paymasterHub
        );
        infra.orgDeployer = address(new BeaconProxy(deployerBeacon, orgDeployerInit));
        console.log("OrgDeployer:", infra.orgDeployer);

        // Transfer OrgRegistry ownership
        OrgRegistry(infra.orgRegistry).transferOwnership(infra.orgDeployer);

        // Authorize OrgDeployer to register orgs with PaymasterHub
        PoaManager(infra.poaManager)
            .adminCall(infra.paymasterHub, abi.encodeWithSignature("setOrgRegistrar(address)", infra.orgDeployer));
        console.log("OrgDeployer authorized as orgRegistrar on PaymasterHub");

        // Deploy and register all application contract types (single source of truth in DeployHelper)
        PoaManager pm = PoaManager(infra.poaManager);
        _deployAndRegisterTypes(pm);

        // Deploy global account registry
        address accRegBeacon = pm.getBeaconById(keccak256("UniversalAccountRegistry"));
        bytes memory accRegInit = abi.encodeWithSignature("initialize(address)", deployer);
        infra.globalAccountRegistry = address(new BeaconProxy(accRegBeacon, accRegInit));
        console.log("GlobalAccountRegistry:", infra.globalAccountRegistry);

        // Configure onboarding with registry address (must come after registry deployment)
        PoaManager(infra.poaManager)
            .adminCall(
                infra.paymasterHub,
                abi.encodeWithSignature(
                    "setOnboardingConfig(uint128,uint128,bool,address)",
                    uint128(0.01 ether),
                    uint128(1000),
                    true,
                    infra.globalAccountRegistry
                )
            );
        console.log("Onboarding config set: registry:", infra.globalAccountRegistry);

        // Configure org deployment sponsorship (must come after OrgDeployer deployment)
        PoaManager(infra.poaManager)
            .adminCall(
                infra.paymasterHub,
                abi.encodeWithSignature(
                    "setOrgDeployConfig(uint128,uint128,uint8,bool,address)",
                    uint128(0.05 ether),
                    uint128(100),
                    uint8(2),
                    true,
                    infra.orgDeployer
                )
            );
        console.log("Org deploy config set: orgDeployer:", infra.orgDeployer);

        // Deploy universal PasskeyAccountFactory
        address passkeyAccountBeacon = pm.getBeaconById(keccak256("PasskeyAccount"));
        address passkeyFactoryBeaconAddr = pm.getBeaconById(keccak256("PasskeyAccountFactory"));
        bytes memory passkeyFactoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint48)",
            infra.poaManager,
            passkeyAccountBeacon,
            POA_GUARDIAN,
            uint48(7 days)
        );
        infra.universalPasskeyFactory = address(new BeaconProxy(passkeyFactoryBeaconAddr, passkeyFactoryInit));
        PoaManager(infra.poaManager)
            .adminCall(
                infra.orgDeployer,
                abi.encodeWithSignature("setUniversalPasskeyFactory(address)", infra.universalPasskeyFactory)
            );
        // Wire up universal factory to GlobalAccountRegistry (owner = deployer)
        UniversalAccountRegistry(infra.globalAccountRegistry).setPasskeyFactory(infra.universalPasskeyFactory);
        // Transfer ownership to PoaManager so governance can manage via adminCall
        UniversalAccountRegistry(infra.globalAccountRegistry).transferOwnership(infra.poaManager);
        console.log("UniversalPasskeyFactory:", infra.universalPasskeyFactory);
        console.log("GlobalAccountRegistry ownership -> PoaManager");

        // Register infrastructure for subgraph indexing
        pm.registerInfrastructure(
            infra.orgDeployer,
            infra.orgRegistry,
            infra.implRegistry,
            infra.paymasterHub,
            infra.globalAccountRegistry,
            infra.universalPasskeyFactory
        );

        console.log("--- Infrastructure Complete ---");
    }

    /*═══════════════════════════ GOVERNANCE ORG ═══════════════════════════*/

    function _deployGovernanceOrg(InfraResult memory infra, address deployer)
        internal
        returns (OrgDeployer.DeploymentResult memory)
    {
        OrgDeployer.DeploymentParams memory params;

        // Org metadata from env vars (IPFS CID sha256 digests, optional — defaults to bytes32(0))
        bytes32 orgMetadata = vm.envOr("ORG_METADATA_HASH", bytes32(0));
        string memory memberImage = vm.envOr("MEMBER_ROLE_IMAGE", string(""));
        bytes32 memberMetadata = vm.envOr("MEMBER_ROLE_METADATA", bytes32(0));
        string memory contributorImage = vm.envOr("CONTRIBUTOR_ROLE_IMAGE", string(""));
        bytes32 contributorMetadata = vm.envOr("CONTRIBUTOR_ROLE_METADATA", bytes32(0));

        params.orgId = keccak256("poa");
        params.orgName = "Poa";
        params.metadataHash = orgMetadata;
        params.registryAddr = infra.globalAccountRegistry;
        params.deployerAddress = deployer;
        params.deployerUsername = vm.envOr("DEPLOYER_USERNAME", string("hudsonhrh"));
        params.autoUpgrade = true;
        params.hybridThresholdPct = 50;
        params.ddThresholdPct = 50;

        // --- Roles ---
        params.roles = new RoleConfigStructs.RoleConfig[](2);

        // Role 0: MEMBER (can vote, requires 1 vouch from CONTRIBUTOR)
        address[] memory emptyAddrs = new address[](0);
        params.roles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: memberImage,
            metadataCID: memberMetadata,
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true, quorum: 1, voucherRoleIndex: 1, combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: false, additionalWearers: emptyAddrs
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        // Role 1: CONTRIBUTOR (can create tasks/projects/approve, deployer gets this)
        params.roles[1] = RoleConfigStructs.RoleConfig({
            name: "CONTRIBUTOR",
            image: contributorImage,
            metadataCID: contributorMetadata,
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: emptyAddrs
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        // --- Voting Classes ---
        params.hybridClasses = new IHybridVotingInit.ClassConfig[](2);
        uint256[] memory emptyHatIds = new uint256[](0);

        // Class 0: DIRECT participation (60%)
        params.hybridClasses[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 60,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatId: 0
        });

        // Class 1: ERC20_BAL token-weighted (40%, quadratic)
        params.hybridClasses[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: 40,
            quadratic: true,
            minBalance: 0,
            asset: address(0),
            hatId: 0
        });

        // --- Role Assignments ---
        // quickJoinRoles: empty (must be vouched for MEMBER)
        // tokenMemberRoles: [0, 1] → bitmap = 0b11 = 3
        // tokenApproverRoles: [1] → bitmap = 0b10 = 2
        // taskCreatorRoles: [1] → bitmap = 2
        // educationCreatorRoles: [1] → bitmap = 2
        // educationMemberRoles: [0, 1] → bitmap = 3
        // hybridProposalCreatorRoles: [1] → bitmap = 2
        // ddVotingRoles: [0, 1] → bitmap = 3
        // ddCreatorRoles: [1] → bitmap = 2
        params.roleAssignments = OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 0,
            tokenMemberRolesBitmap: 3,
            tokenApproverRolesBitmap: 2,
            taskCreatorRolesBitmap: 2,
            educationCreatorRolesBitmap: 2,
            educationMemberRolesBitmap: 3,
            hybridProposalCreatorRolesBitmap: 2,
            ddVotingRolesBitmap: 3,
            ddCreatorRolesBitmap: 2
        });

        // --- Other Config ---
        params.ddInitialTargets = new address[](0);
        params.metadataAdminRoleIndex = type(uint256).max; // Skip — topHat fallback
        params.educationHubConfig = ModulesFactory.EducationHubConfig({enabled: true});
        params.passkeyEnabled = false;
        // bootstrap is left default (empty)
        params.paymasterConfig.operatorRoleIndex = type(uint256).max; // skip operator, topHat-only

        console.log("\nDeploying governance org: Poa");

        OrgDeployer.DeploymentResult memory result = OrgDeployer(infra.orgDeployer).deployFullOrg(params);

        console.log("Executor:", result.executor);
        console.log("HybridVoting:", result.hybridVoting);
        console.log("DirectDemocracyVoting:", result.directDemocracyVoting);
        console.log("QuickJoin:", result.quickJoin);
        console.log("ParticipationToken:", result.participationToken);
        console.log("TaskManager:", result.taskManager);
        console.log("EducationHub:", result.educationHub);
        console.log("PaymentManager:", result.paymentManager);

        return result;
    }

    /*═══════════════════════════ STATE OUTPUT ═══════════════════════════*/

    function _writeState(
        address dd,
        InfraResult memory infra,
        address hub,
        OrgDeployer.DeploymentResult memory org,
        uint32 hubDomain
    ) internal {
        // Build governance object
        string memory gov = "governance";
        vm.serializeAddress(gov, "executor", org.executor);
        vm.serializeAddress(gov, "hybridVoting", org.hybridVoting);
        vm.serializeAddress(gov, "directDemocracyVoting", org.directDemocracyVoting);
        vm.serializeAddress(gov, "quickJoin", org.quickJoin);
        vm.serializeAddress(gov, "participationToken", org.participationToken);
        vm.serializeAddress(gov, "taskManager", org.taskManager);
        vm.serializeAddress(gov, "educationHub", org.educationHub);
        string memory govJson = vm.serializeAddress(gov, "paymentManager", org.paymentManager);

        // Build homeChain object
        string memory home = "homeChain";
        vm.serializeUint(home, "hubDomain", uint256(hubDomain));
        vm.serializeAddress(home, "poaManager", infra.poaManager);
        vm.serializeAddress(home, "implRegistry", infra.implRegistry);
        vm.serializeAddress(home, "orgRegistry", infra.orgRegistry);
        vm.serializeAddress(home, "orgDeployer", infra.orgDeployer);
        vm.serializeAddress(home, "paymasterHub", infra.paymasterHub);
        vm.serializeAddress(home, "globalAccountRegistry", infra.globalAccountRegistry);
        vm.serializeAddress(home, "universalPasskeyFactory", infra.universalPasskeyFactory);
        vm.serializeAddress(home, "governanceFactory", infra.governanceFactory);
        vm.serializeAddress(home, "accessFactory", infra.accessFactory);
        vm.serializeAddress(home, "modulesFactory", infra.modulesFactory);
        vm.serializeAddress(home, "hatsTreeSetup", infra.hatsTreeSetup);
        vm.serializeAddress(home, "hub", hub);
        string memory homeJson = vm.serializeString(home, "governance", govJson);

        // Build root object
        string memory root = "root";
        vm.serializeAddress(root, "deterministicDeployer", dd);
        string memory rootJson = vm.serializeString(root, "homeChain", homeJson);

        // Write main JSON, then add empty satellites array
        vm.writeJson(rootJson, "script/config/main-deploy-state.json");
        vm.writeJson("[]", "script/config/main-deploy-state.json", ".satellites");
        console.log("\nState written to script/main-deploy-state.json");
    }
}

// ════════════════════════════════════════════════════════════════
//  STEP 2: Deploy Satellite
// ════════════════════════════════════════════════════════════════

/**
 * @title DeploySatellite
 * @notice Deploys satellite infrastructure on a remote chain with deterministic
 *         implementation addresses and a PoaManagerSatellite.
 *
 * Environment Variables:
 *   Required: PRIVATE_KEY, MAILBOX, SATELLITE_DOMAIN
 *     SATELLITE_DOMAIN - Hyperlane domain ID for the satellite chain
 *       Ethereum=1, Arbitrum=42161, Optimism=10, Gnosis=100
 *
 * Usage:
 *   PRIVATE_KEY=0x... MAILBOX=0x... SATELLITE_DOMAIN=42161 \
 *   forge script script/MainDeploy.s.sol:DeploySatellite \
 *     --rpc-url $SATELLITE_RPC --broadcast --slow
 */
contract DeploySatellite is DeployHelper {
    bytes32 public constant DD_SALT = keccak256("POA_DETERMINISTIC_DEPLOYER_V1");

    struct SatelliteInfraResult {
        address orgRegistry;
        address orgDeployer;
        address paymasterHub;
        address globalAccountRegistry;
        address universalPasskeyFactory;
        address governanceFactory;
        address accessFactory;
        address modulesFactory;
        address hatsTreeSetup;
    }

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address mailboxAddr = vm.envAddress("MAILBOX");
        address deployer = vm.addr(deployerKey);

        // Read hub address and domain from state file
        string memory state = vm.readFile("script/config/main-deploy-state.json");
        address hubAddress = vm.parseJsonAddress(state, ".homeChain.hub");
        uint32 hubDomain = uint32(vm.parseJsonUint(state, ".homeChain.hubDomain"));

        console.log("\n=== MainDeploy: Satellite Chain ===");
        console.log("Deployer:", deployer);
        console.log("Hub domain:", hubDomain);
        console.log("Hub address:", hubAddress);
        console.log("Mailbox:", mailboxAddr);

        vm.startBroadcast(deployerKey);

        // Verify external contracts exist on this chain
        require(HATS_PROTOCOL.code.length > 0, "Hats Protocol not deployed on this chain");
        require(ENTRY_POINT_V07.code.length > 0, "EntryPoint v0.7 not deployed on this chain");

        // 1. Deploy DeterministicDeployer if needed
        address ddAddr = _deployDeterministicDeployer(deployer);
        DeterministicDeployer dd = DeterministicDeployer(ddAddr);

        // 2. Deploy local PoaManager + ImplementationRegistry
        PoaManager pm = new PoaManager(address(0));

        ImplementationRegistry regImpl = new ImplementationRegistry();
        pm.addContractType("ImplementationRegistry", address(regImpl));
        address regBeacon = pm.getBeaconById(keccak256("ImplementationRegistry"));
        bytes memory regInit = abi.encodeWithSignature("initialize(address)", deployer);
        ImplementationRegistry reg = ImplementationRegistry(address(new BeaconProxy(regBeacon, regInit)));
        pm.updateImplRegistry(address(reg));
        reg.registerImplementation("ImplementationRegistry", "v1", address(regImpl), true);
        reg.transferOwnership(address(pm));
        console.log("ImplementationRegistry:", address(reg));

        // 3. Deploy infrastructure types via DD and register on PoaManager
        _deployAndRegisterInfraTypesDD(pm, dd);

        // 4. Deploy application types via DD and register
        _deployAndRegisterTypesDD(pm, dd);

        // 5. Deploy full infrastructure
        SatelliteInfraResult memory infra = _deploySatelliteInfrastructure(pm, deployer);

        // 6. Register infrastructure for subgraph indexing
        pm.registerInfrastructure(
            infra.orgDeployer,
            infra.orgRegistry,
            address(reg),
            infra.paymasterHub,
            infra.globalAccountRegistry,
            infra.universalPasskeyFactory
        );
        console.log("Infrastructure registered for subgraph indexing");

        // 7. Deploy PoaManagerSatellite (AFTER all wiring)
        PoaManagerSatellite satellite = new PoaManagerSatellite(address(pm), mailboxAddr, hubDomain, hubAddress);
        console.log("PoaManagerSatellite:", address(satellite));

        // 8. Transfer PoaManager ownership to Satellite (MUST BE LAST)
        pm.transferOwnership(address(satellite));
        console.log("PoaManager ownership transferred to Satellite");

        vm.stopBroadcast();

        // Write state
        _writeSatelliteState(pm, reg, satellite, infra);

        console.log("\n=== Satellite Deployment Complete ===");
    }

    function _deploySatelliteInfrastructure(PoaManager pm, address deployer)
        internal
        returns (SatelliteInfraResult memory infra)
    {
        // --- Deploy stateless factories ---
        infra.governanceFactory = address(new GovernanceFactory());
        infra.accessFactory = address(new AccessFactory());
        infra.modulesFactory = address(new ModulesFactory());
        infra.hatsTreeSetup = address(new HatsTreeSetup());
        console.log("Factories deployed");

        // --- OrgRegistry proxy ---
        address orgRegBeacon = pm.getBeaconById(keccak256("OrgRegistry"));
        bytes memory orgRegInit = abi.encodeWithSignature("initialize(address,address)", deployer, HATS_PROTOCOL);
        infra.orgRegistry = address(new BeaconProxy(orgRegBeacon, orgRegInit));
        console.log("OrgRegistry:", infra.orgRegistry);

        // --- PaymasterHub proxy ---
        address paymasterHubBeacon = pm.getBeaconById(keccak256("PaymasterHub"));
        bytes memory paymasterHubInit =
            abi.encodeWithSignature("initialize(address,address,address)", ENTRY_POINT_V07, HATS_PROTOCOL, address(pm));
        infra.paymasterHub = address(new BeaconProxy(paymasterHubBeacon, paymasterHubInit));
        uint256 solidarityFund = vm.envOr("SOLIDARITY_FUND", INITIAL_SOLIDARITY_FUND);
        PaymasterHub(payable(infra.paymasterHub)).donateToSolidarity{value: solidarityFund}();
        console.log("PaymasterHub:", infra.paymasterHub);

        // Unpause solidarity distribution so onboarding can use the fund
        // (initialize() sets distributionPaused=true for collection-only mode)
        pm.adminCall(infra.paymasterHub, abi.encodeWithSignature("unpauseSolidarityDistribution()"));
        console.log("Solidarity distribution unpaused for onboarding");

        // --- OrgDeployer proxy ---
        address deployerBeacon = pm.getBeaconById(keccak256("OrgDeployer"));
        bytes memory orgDeployerInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address)",
            infra.governanceFactory,
            infra.accessFactory,
            infra.modulesFactory,
            address(pm),
            infra.orgRegistry,
            HATS_PROTOCOL,
            infra.hatsTreeSetup,
            infra.paymasterHub
        );
        infra.orgDeployer = address(new BeaconProxy(deployerBeacon, orgDeployerInit));
        console.log("OrgDeployer:", infra.orgDeployer);

        // --- Wire OrgRegistry ownership to OrgDeployer ---
        OrgRegistry(infra.orgRegistry).transferOwnership(infra.orgDeployer);

        // --- Authorize OrgDeployer as org registrar on PaymasterHub ---
        pm.adminCall(infra.paymasterHub, abi.encodeWithSignature("setOrgRegistrar(address)", infra.orgDeployer));
        console.log("OrgDeployer authorized as orgRegistrar on PaymasterHub");

        // --- Deploy GlobalAccountRegistry ---
        address accRegBeacon = pm.getBeaconById(keccak256("UniversalAccountRegistry"));
        bytes memory accRegInit = abi.encodeWithSignature("initialize(address)", deployer);
        infra.globalAccountRegistry = address(new BeaconProxy(accRegBeacon, accRegInit));
        console.log("GlobalAccountRegistry:", infra.globalAccountRegistry);

        // Configure onboarding with registry address (must come after registry deployment)
        pm.adminCall(
            infra.paymasterHub,
            abi.encodeWithSignature(
                "setOnboardingConfig(uint128,uint128,bool,address)",
                uint128(0.01 ether),
                uint128(1000),
                true,
                infra.globalAccountRegistry
            )
        );
        console.log("Onboarding config set: registry:", infra.globalAccountRegistry);

        // Configure org deployment sponsorship (must come after OrgDeployer deployment)
        pm.adminCall(
            infra.paymasterHub,
            abi.encodeWithSignature(
                "setOrgDeployConfig(uint128,uint128,uint8,bool,address)",
                uint128(0.05 ether),
                uint128(100),
                uint8(2),
                true,
                infra.orgDeployer
            )
        );
        console.log("Org deploy config set: orgDeployer:", infra.orgDeployer);

        // --- Deploy UniversalPasskeyFactory ---
        address passkeyAccountBeacon = pm.getBeaconById(keccak256("PasskeyAccount"));
        address passkeyFactoryBeacon = pm.getBeaconById(keccak256("PasskeyAccountFactory"));
        bytes memory passkeyFactoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint48)",
            address(pm),
            passkeyAccountBeacon,
            POA_GUARDIAN,
            uint48(7 days)
        );
        infra.universalPasskeyFactory = address(new BeaconProxy(passkeyFactoryBeacon, passkeyFactoryInit));
        console.log("UniversalPasskeyFactory:", infra.universalPasskeyFactory);

        // --- Wire passkey factory to OrgDeployer ---
        pm.adminCall(
            infra.orgDeployer,
            abi.encodeWithSignature("setUniversalPasskeyFactory(address)", infra.universalPasskeyFactory)
        );

        // --- Wire passkey factory to GlobalAccountRegistry ---
        UniversalAccountRegistry(infra.globalAccountRegistry).setPasskeyFactory(infra.universalPasskeyFactory);
        // Transfer ownership to PoaManager so home chain governance can manage via adminCall
        UniversalAccountRegistry(infra.globalAccountRegistry).transferOwnership(address(pm));
        console.log("GlobalAccountRegistry ownership -> PoaManager");

        console.log("--- Satellite Infrastructure Complete ---");
    }

    function _writeSatelliteState(
        PoaManager pm,
        ImplementationRegistry reg,
        PoaManagerSatellite satellite,
        SatelliteInfraResult memory infra
    ) internal {
        uint32 satDomain = uint32(vm.envUint("SATELLITE_DOMAIN"));

        string memory satObj = "satellite_state";
        vm.serializeUint(satObj, "domain", uint256(satDomain));
        vm.serializeAddress(satObj, "satellite", address(satellite));
        vm.serializeAddress(satObj, "poaManager", address(pm));
        vm.serializeAddress(satObj, "implRegistry", address(reg));
        vm.serializeAddress(satObj, "orgRegistry", infra.orgRegistry);
        vm.serializeAddress(satObj, "orgDeployer", infra.orgDeployer);
        vm.serializeAddress(satObj, "paymasterHub", infra.paymasterHub);
        vm.serializeAddress(satObj, "globalAccountRegistry", infra.globalAccountRegistry);
        vm.serializeAddress(satObj, "universalPasskeyFactory", infra.universalPasskeyFactory);
        vm.serializeAddress(satObj, "governanceFactory", infra.governanceFactory);
        vm.serializeAddress(satObj, "accessFactory", infra.accessFactory);
        vm.serializeAddress(satObj, "modulesFactory", infra.modulesFactory);
        string memory satJson = vm.serializeAddress(satObj, "hatsTreeSetup", infra.hatsTreeSetup);

        string memory filename =
            string.concat("script/config/satellite-state-", vm.toString(uint256(satDomain)), ".json");
        vm.writeJson(satJson, filename);
        console.log("Satellite state written to", filename);
    }

    function _deployDeterministicDeployer(address owner) internal returns (address) {
        bytes memory creationCode = abi.encodePacked(type(DeterministicDeployer).creationCode, abi.encode(owner));
        address predicted =
            vm.computeCreate2Address(DD_SALT, keccak256(creationCode), 0x4e59b44847b379578588920cA78FbF26c0B4956C);

        if (predicted.code.length > 0) {
            console.log("DeterministicDeployer already deployed:", predicted);
            return predicted;
        }

        DeterministicDeployer dd = new DeterministicDeployer{salt: DD_SALT}(owner);
        console.log("DeterministicDeployer:", address(dd));
        require(address(dd) == predicted, "DD address mismatch");
        return address(dd);
    }
}

// ════════════════════════════════════════════════════════════════
//  STEP 3: Register Satellites & Transfer Hub Ownership
// ════════════════════════════════════════════════════════════════

/**
 * @title RegisterAndTransfer
 * @notice Registers satellites on the Hub and transfers Hub ownership to the
 *         governance org's Executor. Run on the home chain after all satellites
 *         are deployed.
 *
 *         Reads satellite info from the JSON state files written by DeploySatellite
 *         (satellite-state-{domain}.json). Provide satellite domains via numbered
 *         env vars.
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   NUM_SATELLITES=2 \
 *   SATELLITE_DOMAIN_0=84532 \
 *   SATELLITE_DOMAIN_1=421614 \
 *   forge script script/MainDeploy.s.sol:RegisterAndTransfer \
 *     --rpc-url $HOME_RPC --broadcast
 */
contract RegisterAndTransfer is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 numSatellites = vm.envUint("NUM_SATELLITES");

        // Read state
        string memory state = vm.readFile("script/config/main-deploy-state.json");
        address hubAddr = vm.parseJsonAddress(state, ".homeChain.hub");
        address executorAddr = vm.parseJsonAddress(state, ".homeChain.governance.executor");

        console.log("\n=== MainDeploy: Register Satellites & Transfer Ownership ===");
        console.log("Hub:", hubAddr);
        console.log("Executor:", executorAddr);
        console.log("Satellites to register:", numSatellites);

        vm.startBroadcast(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(hubAddr));

        // Build set of already-registered active domains (for idempotent re-runs)
        uint256 existingCount = hub.satelliteCount();

        // Register each satellite by reading its state file
        for (uint256 i = 0; i < numSatellites; i++) {
            // Read domain from numbered env var (SATELLITE_DOMAIN_0, SATELLITE_DOMAIN_1, ...)
            string memory envKey = string.concat("SATELLITE_DOMAIN_", vm.toString(i));
            uint32 domain = uint32(vm.envUint(envKey));

            // Skip if this domain is already actively registered
            bool alreadyRegistered = false;
            for (uint256 j = 0; j < existingCount; j++) {
                (uint32 existingDomain,, bool active) = hub.satellites(j);
                if (existingDomain == domain && active) {
                    alreadyRegistered = true;
                    break;
                }
            }
            if (alreadyRegistered) {
                console.log("Satellite already registered, skipping domain:", domain);
                continue;
            }

            // Read satellite address from its state file
            string memory filename =
                string.concat("script/config/satellite-state-", vm.toString(uint256(domain)), ".json");
            string memory satState = vm.readFile(filename);
            address satAddr = vm.parseJsonAddress(satState, ".satellite");

            hub.registerSatellite(domain, satAddr);
            console.log("Registered satellite domain:", domain, "at", satAddr);
        }

        // Transfer Hub ownership to Executor (governance now controls upgrades)
        hub.transferOwnership(executorAddr);
        console.log("\nHub ownership transferred to Executor:", executorAddr);

        vm.stopBroadcast();

        console.log("\n=== Registration & Transfer Complete ===");
        console.log("Governance chain is now fully wired:");
        console.log("  HybridVoting -> Executor -> Hub -> PoaManager");
    }
}

// ════════════════════════════════════════════════════════════════
//  STEP 4: Verify Deployment
// ════════════════════════════════════════════════════════════════

/**
 * @title VerifyDeployment
 * @notice Read-only verification of the full deployment. Checks ownership chain
 *         and satellite registration on home chain.
 *
 * Usage:
 *   forge script script/MainDeploy.s.sol:VerifyDeployment \
 *     --rpc-url $HOME_RPC
 */
contract VerifyDeployment is Script {
    function _staticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        require(ok, "staticcall failed");
        return ret;
    }

    function run() public view {
        string memory state = vm.readFile("script/config/main-deploy-state.json");
        address hubAddr = vm.parseJsonAddress(state, ".homeChain.hub");
        address executorAddr = vm.parseJsonAddress(state, ".homeChain.governance.executor");
        address pmAddr = vm.parseJsonAddress(state, ".homeChain.poaManager");
        address orgDeployerAddr = vm.parseJsonAddress(state, ".homeChain.orgDeployer");

        console.log("\n=== Deployment Verification (Home Chain) ===");

        uint256 checks;
        uint256 passed;

        // Check Hub owner
        address hubOwner = PoaManagerHub(payable(hubAddr)).owner();
        console.log("\nHub owner:", hubOwner);
        console.log("Expected (Executor):", executorAddr);
        bool hubCheck = hubOwner == executorAddr;
        console.log("Hub ownership:", hubCheck ? "PASS" : "FAIL");
        checks++;
        if (hubCheck) passed++;

        // Check PoaManager owner
        address pmOwner = PoaManager(pmAddr).owner();
        console.log("\nPoaManager owner:", pmOwner);
        console.log("Expected (Hub):", hubAddr);
        bool pmCheck = pmOwner == hubAddr;
        console.log("PoaManager ownership:", pmCheck ? "PASS" : "FAIL");
        checks++;
        if (pmCheck) passed++;

        // Check satellite count
        uint256 satCount = PoaManagerHub(payable(hubAddr)).satelliteCount();
        console.log("\nRegistered satellites:", satCount);
        bool satCheck = satCount > 0;
        console.log("Has satellites:", satCheck ? "PASS" : "WARNING - none registered");
        checks++;
        if (satCheck) passed++;

        // Check Executor ETH balance
        uint256 execBal = executorAddr.balance;
        console.log("Executor ETH balance:", execBal);
        bool execCheck = execBal > 0;
        console.log("Has Hyperlane funds:", execCheck ? "PASS" : "WARNING - no ETH");
        checks++;
        if (execCheck) passed++;

        // Check OrgDeployer is set as orgRegistrar on PaymasterHub
        address paymasterAddr = vm.parseJsonAddress(state, ".homeChain.paymasterHub");
        // Note: We can't directly read orgRegistrar from PaymasterHub (it's in private storage),
        // but we verify OrgDeployer exists
        bool deployerCheck = orgDeployerAddr.code.length > 0;
        console.log("\nOrgDeployer has code:", deployerCheck ? "PASS" : "FAIL");
        checks++;
        if (deployerCheck) passed++;

        // Check PaymasterHub onboarding config
        address registryAddr = vm.parseJsonAddress(state, ".homeChain.globalAccountRegistry");
        (uint128 maxGas, uint128 dailyLimit,, bool onboardingEnabled, address accountRegistry) = abi.decode(
            _staticCall(paymasterAddr, abi.encodeWithSignature("getOnboardingConfig()")),
            (uint128, uint128, uint128, bool, address)
        );
        console.log("\nOnboarding enabled:", onboardingEnabled ? "true" : "false");
        bool onboardingCheck = onboardingEnabled && accountRegistry == registryAddr && accountRegistry != address(0);
        console.log("Onboarding registry:", accountRegistry);
        console.log("Expected registry:", registryAddr);
        console.log("Onboarding config:", onboardingCheck ? "PASS" : "FAIL");
        checks++;
        if (onboardingCheck) passed++;

        // Check solidarity distribution is unpaused
        (uint256 solBalance,,, bool distPaused) = abi.decode(
            _staticCall(paymasterAddr, abi.encodeWithSignature("getSolidarityFund()")),
            (uint256, uint256, uint256, bool)
        );
        console.log("\nSolidarity balance:", solBalance);
        bool solidarityCheck = solBalance > 0 && !distPaused;
        console.log("Distribution paused:", distPaused ? "true" : "false");
        console.log("Solidarity fund:", solidarityCheck ? "PASS" : "FAIL");
        checks++;
        if (solidarityCheck) passed++;

        // Summary
        console.log("\n=== Verification Summary ===");
        console.log("Passed:", passed, "/", checks);
        if (passed == checks) {
            console.log("All checks PASSED");
        } else {
            console.log("SOME CHECKS FAILED or WARNINGS - review above");
        }
    }
}
