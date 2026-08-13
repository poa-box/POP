// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────────── forge-std ───────────*/
import "forge-std/Test.sol";

/*──────────── OpenZeppelin ───────────*/
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*──────────── Local contracts ───────────*/
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {Executor} from "../src/Executor.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import "../src/ImplementationRegistry.sol";
import "../src/PoaManager.sol";
import "../src/OrgRegistry.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../src/OrgDeployer.sol";
import {GovernanceFactory} from "../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../src/factories/AccessFactory.sol";
import {ModulesFactory} from "../src/factories/ModulesFactory.sol";
import {RoleConfigStructs} from "../src/libs/RoleConfigStructs.sol";
import {HatsTreeSetup} from "../src/HatsTreeSetup.sol";
import {ModuleDeploymentLib, IHybridVotingInit} from "../src/libs/ModuleDeploymentLib.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/*──────── Minimal getters for the widened configAdmin setters (W3/W4 surfaces) ───────*/
interface ITMConfig {
    enum ConfigKey {
        EXECUTOR,
        CREATOR_HAT_ALLOWED,
        ROLE_PERM,
        PROJECT_ROLE_PERM,
        BOUNTY_CAP,
        PROJECT_MANAGER,
        PROJECT_CAP,
        ORGANIZER_HAT_ALLOWED
    }

    function setConfig(ConfigKey key, bytes calldata value) external;
}

interface IPTConfig {
    function setMemberHatAllowed(uint256 h, bool ok) external;
}

interface IEduConfig {
    function setCreatorHatAllowed(uint256 h, bool ok) external;
}

interface IQJConfig {
    function updateMemberHatIds(uint256[] calldata memberHatIds_) external;
    function memberHatIds() external view returns (uint256[] memory);
}

interface IConfigAdminView {
    function configAdmin() external view returns (address);
}

interface IEMRoleManagerView {
    function roleManager() external view returns (address);
}

/// @title OrgDeployRoleManager — W5 new-org deploy path for the RoleManager orchestrator.
/// @notice Full org deploy with RoleManager opt-in: registration/init ordering, scoped-authority
///         wiring on all six sibling modules, disabled-config parity, and beacon-unregistered skip.
///         Also covers the HatsTreeSetup canVote→minting decouple.
contract OrgDeployRoleManagerTest is Test {
    /*–––– implementations ––––*/
    HybridVoting hybridImpl;
    DirectDemocracyVoting ddVotingImpl;
    Executor execImpl;
    UniversalAccountRegistry accountRegImpl;
    QuickJoin quickJoinImpl;
    ParticipationToken pTokenImpl;
    TaskManager taskMgrImpl;
    EducationHub eduHubImpl;
    PaymentManager paymentManagerImpl;
    EligibilityModule eligibilityModuleImpl;
    ToggleModule toggleModuleImpl;
    RoleManager roleManagerImpl;

    /*–––– infra ––––*/
    ImplementationRegistry implRegistry;
    PoaManager poaManager;
    OrgRegistry orgRegistry;
    OrgDeployer deployer;
    GovernanceFactory governanceFactory;
    AccessFactory accessFactory;
    ModulesFactory modulesFactory;
    PaymasterHub paymasterHub;
    address accountRegProxy;

    /*–––– addresses ––––*/
    address public constant poaAdmin = address(1);
    address public constant orgOwner = address(2);
    address public constant SEPOLIA_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address public constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant rando = address(0xBAD);

    /*–––– event topics (for log-order assertions) ––––*/
    bytes32 constant CONTRACT_REGISTERED_TOPIC =
        keccak256("ContractRegistered(bytes32,bytes32,bytes32,address,address,bool,address)");
    bytes32 constant ROLE_MANAGER_INITIALIZED_TOPIC = keccak256("RoleManagerInitialized(address,bytes32,address)");

    function setUp() public {
        vm.createSelectFork("hoodi");

        hybridImpl = new HybridVoting();
        ddVotingImpl = new DirectDemocracyVoting();
        execImpl = new Executor();
        accountRegImpl = new UniversalAccountRegistry();
        quickJoinImpl = new QuickJoin();
        pTokenImpl = new ParticipationToken();
        taskMgrImpl = new TaskManager();
        eduHubImpl = new EducationHub();
        paymentManagerImpl = new PaymentManager();
        eligibilityModuleImpl = new EligibilityModule();
        toggleModuleImpl = new ToggleModule();
        roleManagerImpl = new RoleManager();

        ImplementationRegistry implRegistryImpl = new ImplementationRegistry();

        vm.startPrank(poaAdmin);

        poaManager = new PoaManager(address(0));

        OrgRegistry orgRegistryImpl = new OrgRegistry();
        OrgDeployer deployerImpl = new OrgDeployer();

        poaManager.addContractType("ImplementationRegistry", address(implRegistryImpl));
        address implRegBeacon = poaManager.getBeaconById(keccak256("ImplementationRegistry"));
        bytes memory implRegistryInit = abi.encodeWithSignature("initialize(address)", poaAdmin);
        implRegistry = ImplementationRegistry(address(new BeaconProxy(implRegBeacon, implRegistryInit)));
        poaManager.updateImplRegistry(address(implRegistry));
        implRegistry.registerImplementation("ImplementationRegistry", "v1", address(implRegistryImpl), true);
        implRegistry.transferOwnership(address(poaManager));

        poaManager.addContractType("OrgRegistry", address(orgRegistryImpl));
        poaManager.addContractType("OrgDeployer", address(deployerImpl));
        address orgRegBeacon = poaManager.getBeaconById(keccak256("OrgRegistry"));
        address deployerBeacon = poaManager.getBeaconById(keccak256("OrgDeployer"));

        bytes memory orgRegistryInit = abi.encodeWithSignature("initialize(address,address)", poaAdmin, SEPOLIA_HATS);
        orgRegistry = OrgRegistry(address(new BeaconProxy(orgRegBeacon, orgRegistryInit)));

        HatsTreeSetup hatsTreeSetup = new HatsTreeSetup();

        governanceFactory = new GovernanceFactory();
        accessFactory = new AccessFactory();
        modulesFactory = new ModulesFactory();

        PaymasterHub paymasterHubImpl = new PaymasterHub();
        poaManager.addContractType("PaymasterHub", address(paymasterHubImpl));
        address paymasterHubBeacon = poaManager.getBeaconById(keccak256("PaymasterHub"));
        bytes memory paymasterHubInit = abi.encodeWithSignature(
            "initialize(address,address,address)", ENTRY_POINT_V07, SEPOLIA_HATS, address(poaManager)
        );
        paymasterHub = PaymasterHub(payable(address(new BeaconProxy(paymasterHubBeacon, paymasterHubInit))));

        bytes memory deployerInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address)",
            address(governanceFactory),
            address(accessFactory),
            address(modulesFactory),
            address(poaManager),
            address(orgRegistry),
            SEPOLIA_HATS,
            address(hatsTreeSetup),
            address(paymasterHub)
        );
        deployer = OrgDeployer(address(new BeaconProxy(deployerBeacon, deployerInit)));

        vm.stopPrank();
        vm.prank(address(poaManager));
        paymasterHub.setOrgRegistrar(address(deployer));
        vm.startPrank(poaAdmin);

        orgRegistry.transferOwnership(address(deployer));

        poaManager.addContractType("HybridVoting", address(hybridImpl));
        poaManager.addContractType("DirectDemocracyVoting", address(ddVotingImpl));
        poaManager.addContractType("Executor", address(execImpl));
        poaManager.addContractType("QuickJoin", address(quickJoinImpl));
        poaManager.addContractType("ParticipationToken", address(pTokenImpl));
        poaManager.addContractType("TaskManager", address(taskMgrImpl));
        poaManager.addContractType("EducationHub", address(eduHubImpl));
        poaManager.addContractType("UniversalAccountRegistry", address(accountRegImpl));
        poaManager.addContractType("EligibilityModule", address(eligibilityModuleImpl));
        poaManager.addContractType("ToggleModule", address(toggleModuleImpl));
        poaManager.addContractType("PaymentManager", address(paymentManagerImpl));
        // NOTE: RoleManager is intentionally NOT registered here — tests opt in via
        // `_registerRoleManagerType()`; the "beacon unregistered" test leaves it out.

        address accRegBeacon = poaManager.getBeaconById(keccak256("UniversalAccountRegistry"));
        accountRegProxy =
            address(new BeaconProxy(accRegBeacon, abi.encodeWithSignature("initialize(address)", poaAdmin)));

        vm.stopPrank();
    }

    /*════════════════  HELPERS  ════════════════*/

    /// @dev Register the protocol-level RoleManager beacon so opted-in deploys can create the module.
    function _registerRoleManagerType() internal {
        vm.prank(poaAdmin);
        poaManager.addContractType("RoleManager", address(roleManagerImpl));
    }

    function _rmEnabled() internal pure returns (ModulesFactory.RoleManagerConfig memory) {
        return ModulesFactory.RoleManagerConfig({enabled: true});
    }

    /// @dev Two-role config (DEFAULT idx0, EXECUTIVE idx1). Optionally make DEFAULT a non-voting role
    ///      that still mints to the deployer (exercises the HatsTreeSetup canVote decouple).
    function _roles(bool defaultCanVote, bool defaultMintToDeployer)
        internal
        pure
        returns (RoleConfigStructs.RoleConfig[] memory roles)
    {
        roles = new RoleConfigStructs.RoleConfig[](2);
        // DEFAULT (idx 0) sits under EXECUTIVE (idx 1); EXECUTIVE is the top role.
        roles[0] = _role("DEFAULT", 1, defaultCanVote, defaultMintToDeployer);
        roles[1] = _role("EXECUTIVE", type(uint256).max, true, true);
    }

    function _role(string memory name, uint256 adminRoleIndex, bool canVote, bool mintToDeployer)
        internal
        pure
        returns (RoleConfigStructs.RoleConfig memory)
    {
        return RoleConfigStructs.RoleConfig({
            name: name,
            image: "ipfs://img",
            metadataCID: bytes32(0),
            canVote: canVote,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: adminRoleIndex}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: mintToDeployer, additionalWearers: new address[](0)
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });
    }

    function _roleAssignments() internal pure returns (OrgDeployer.RoleAssignments memory) {
        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 1,
            tokenMemberRolesBitmap: 1,
            tokenApproverRolesBitmap: 2,
            taskCreatorRolesBitmap: 2,
            educationCreatorRolesBitmap: 2,
            educationMemberRolesBitmap: 1,
            hybridProposalCreatorRolesBitmap: 2,
            ddVotingRolesBitmap: 1,
            ddCreatorRolesBitmap: 2
        });
    }

    function _classes() internal pure returns (IHybridVotingInit.ClassConfig[] memory classes) {
        classes = new IHybridVotingInit.ClassConfig[](1);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: new uint256[](0)
        });
    }

    function _paymasterConfig() internal pure returns (OrgDeployer.PaymasterConfig memory) {
        return OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: false,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });
    }

    function _emptyBootstrap() internal pure returns (OrgDeployer.BootstrapConfig memory) {
        return OrgDeployer.BootstrapConfig({
            projects: new ITaskManagerBootstrap.BootstrapProjectConfig[](0),
            tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)
        });
    }

    function _params(bytes32 orgId, RoleConfigStructs.RoleConfig[] memory roles, bool eduEnabled)
        internal
        view
        returns (OrgDeployer.DeploymentParams memory params)
    {
        params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "RM DAO",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: orgOwner,
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: _classes(),
            ddInitialTargets: new address[](0),
            roles: roles,
            roleAssignments: _roleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: eduEnabled}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _paymasterConfig(),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)}),
            hybridQuorum: 0,
            ddQuorum: 0,
            tokenName: "",
            tokenSymbol: ""
        });
    }

    function _deployWithRoleManager(bytes32 orgId, bool eduEnabled)
        internal
        returns (OrgDeployer.DeploymentResult memory result)
    {
        vm.prank(orgOwner);
        result = deployer.deployFullOrgWithRoleManager(_params(orgId, _roles(true, true), eduEnabled), _rmEnabled());
    }

    /*════════════════  TESTS  ════════════════*/

    /// @notice RoleManager proxy is registered under ROLE_MANAGER_ID and initialized with seeded roles.
    function testRoleManagerDeployedRegisteredAndInitialized() public {
        _registerRoleManagerType();
        bytes32 orgId = keccak256("RM-ORG-1");
        OrgDeployer.DeploymentResult memory result = _deployWithRoleManager(orgId, true);

        assertTrue(result.roleManager != address(0), "roleManager not deployed");

        // Registered under the correct type id.
        address registered = orgRegistry.getOrgContract(orgId, ModuleTypes.ROLE_MANAGER_ID);
        assertEq(registered, result.roleManager, "not registered under ROLE_MANAGER_ID");

        // Initialized: seeded org hats == the two role hats, in order, with names.
        RoleManager rm = RoleManager(result.roleManager);
        uint256[] memory orgHats = rm.orgHats();
        assertEq(orgHats.length, 2, "expected 2 seeded org hats");
        assertEq(rm.roleCount(), 2, "expected 2 seeded roles");

        IRoleManager.RoleInfo memory r0 = rm.getRole(1);
        IRoleManager.RoleInfo memory r1 = rm.getRole(2);
        assertEq(r0.name, "DEFAULT");
        assertEq(r1.name, "EXECUTIVE");
        assertEq(orgHats[0], r0.hatId);
        assertEq(orgHats[1], r1.hatId);
        assertEq(rm.roleIdOfHat(r0.hatId), 1);

        // Re-initialization is impossible.
        vm.expectRevert();
        rm.initialize(_dummyInitConfig());
    }

    /// @notice EligibilityModule.roleManager points at the deployed RoleManager after wiring.
    function testEligibilityModuleRoleManagerWired() public {
        _registerRoleManagerType();
        OrgDeployer.DeploymentResult memory result = _deployWithRoleManager(keccak256("RM-ORG-2"), true);
        assertEq(
            IEMRoleManagerView(result.eligibilityModule).roleManager(), result.roleManager, "EM.roleManager not wired"
        );
    }

    /// @notice configAdmin is set to the RoleManager on all six sibling modules.
    function testConfigAdminSetOnAllSixModules() public {
        _registerRoleManagerType();
        OrgDeployer.DeploymentResult memory result = _deployWithRoleManager(keccak256("RM-ORG-3"), true);
        address rm = result.roleManager;

        // DD + HV expose a public configAdmin() getter.
        assertEq(IConfigAdminView(result.directDemocracyVoting).configAdmin(), rm, "DD configAdmin");
        assertEq(IConfigAdminView(result.hybridVoting).configAdmin(), rm, "HV configAdmin");

        // TM / PT / Edu / QJ have no getter — assert behaviorally: the RoleManager (as configAdmin)
        // can now reach each widened setter, and a rando cannot.
        uint256 someHat = RoleManager(rm).getRole(2).hatId;

        vm.prank(rm);
        ITMConfig(result.taskManager).setConfig(ITMConfig.ConfigKey.ROLE_PERM, abi.encode(someHat, uint8(1)));
        vm.prank(rando);
        vm.expectRevert();
        ITMConfig(result.taskManager).setConfig(ITMConfig.ConfigKey.ROLE_PERM, abi.encode(someHat, uint8(1)));

        vm.prank(rm);
        IPTConfig(result.participationToken).setMemberHatAllowed(someHat, true);
        vm.prank(rando);
        vm.expectRevert();
        IPTConfig(result.participationToken).setMemberHatAllowed(someHat, true);

        vm.prank(rm);
        IEduConfig(result.educationHub).setCreatorHatAllowed(someHat, true);
        vm.prank(rando);
        vm.expectRevert();
        IEduConfig(result.educationHub).setCreatorHatAllowed(someHat, true);

        uint256[] memory ids = IQJConfig(result.quickJoin).memberHatIds();
        vm.prank(rm);
        IQJConfig(result.quickJoin).updateMemberHatIds(ids);
        vm.prank(rando);
        vm.expectRevert();
        IQJConfig(result.quickJoin).updateMemberHatIds(ids);
    }

    /// @notice Register-before-initialize: the ROLE_MANAGER_ID ContractRegistered log precedes the
    ///         RoleManagerInitialized log within the same deploy tx.
    function testRegisterBeforeInitializeOrdering() public {
        _registerRoleManagerType();
        vm.recordLogs();
        vm.prank(orgOwner);
        deployer.deployFullOrgWithRoleManager(_params(keccak256("RM-ORG-4"), _roles(true, true), true), _rmEnabled());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 registeredIdx = -1;
        int256 initializedIdx = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 4 && logs[i].topics[0] == CONTRACT_REGISTERED_TOPIC
                    && logs[i].topics[3] == ModuleTypes.ROLE_MANAGER_ID
            ) {
                if (registeredIdx == -1) registeredIdx = int256(i);
            }
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == ROLE_MANAGER_INITIALIZED_TOPIC) {
                if (initializedIdx == -1) initializedIdx = int256(i);
            }
        }

        assertTrue(registeredIdx >= 0, "no ContractRegistered(ROLE_MANAGER_ID) log");
        assertTrue(initializedIdx >= 0, "no RoleManagerInitialized log");
        assertLt(registeredIdx, initializedIdx, "initialize must follow registration");
    }

    /// @notice A disabled RoleManager config leaves the org deploy byte-for-byte unchanged (no module).
    function testDisabledConfigDeploysUnchanged() public {
        _registerRoleManagerType(); // beacon available, but the config opts OUT
        bytes32 orgId = keccak256("RM-ORG-5");

        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrgWithRoleManager(
            _params(orgId, _roles(true, true), true), ModulesFactory.RoleManagerConfig({enabled: false})
        );

        assertEq(result.roleManager, address(0), "roleManager should be skipped when disabled");
        // Core org still fully deployed.
        assertTrue(result.executor != address(0) && result.hybridVoting != address(0));
        // Nothing registered under ROLE_MANAGER_ID.
        vm.expectRevert();
        orgRegistry.getOrgContract(orgId, ModuleTypes.ROLE_MANAGER_ID);
        // EM.roleManager untouched.
        assertEq(IEMRoleManagerView(result.eligibilityModule).roleManager(), address(0));
    }

    /// @notice legacy deployFullOrg is unaffected (RoleManager never deployed).
    function testLegacyEntrypointHasNoRoleManager() public {
        _registerRoleManagerType();
        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result =
            deployer.deployFullOrg(_params(keccak256("RM-ORG-6"), _roles(true, true), true));
        assertEq(result.roleManager, address(0), "legacy path must not deploy RoleManager");
    }

    /// @notice On a chain where the RoleManager beacon was never registered, an opted-in deploy skips
    ///         the module cleanly (org deploys fine, roleManager == 0), never reverting TypeUnknown.
    function testBeaconUnregisteredSkipsCleanly() public {
        // NOTE: no _registerRoleManagerType() call — the protocol beacon is absent.
        bytes32 orgId = keccak256("RM-ORG-7");
        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result =
            deployer.deployFullOrgWithRoleManager(_params(orgId, _roles(true, true), true), _rmEnabled());

        assertEq(result.roleManager, address(0), "should skip when beacon unregistered");
        assertTrue(result.executor != address(0), "core org must still deploy");
        vm.expectRevert();
        orgRegistry.getOrgContract(orgId, ModuleTypes.ROLE_MANAGER_ID);
    }

    /// @notice EducationHub disabled: the RoleManager wiring skips the (nonexistent) EduHub and the
    ///         other five modules are still wired.
    function testRoleManagerWithEducationHubDisabled() public {
        _registerRoleManagerType();
        OrgDeployer.DeploymentResult memory result = _deployWithRoleManager(keccak256("RM-ORG-8"), false);

        assertEq(result.educationHub, address(0), "eduHub should be disabled");
        assertTrue(result.roleManager != address(0), "roleManager still deploys");
        assertEq(IConfigAdminView(result.hybridVoting).configAdmin(), result.roleManager, "HV still wired");
        assertEq(IEMRoleManagerView(result.eligibilityModule).roleManager(), result.roleManager, "EM still wired");
    }

    /// @notice HatsTreeSetup decouple: a canVote=false role with mintToDeployer=true now mints the hat
    ///         to the deployer at deploy time (previously silently skipped).
    function testCanVoteFalseRoleStillMints() public {
        bytes32 orgId = keccak256("RM-ORG-9");
        // DEFAULT: canVote=false BUT mintToDeployer=true. EXECUTIVE stays voting/minting (top role).
        RoleConfigStructs.RoleConfig[] memory roles = _roles(false, true);

        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(_params(orgId, roles, true));

        // Recover the DEFAULT role hat (index 0) from OrgRegistry's hats-tree registration.
        uint256 defaultHat = orgRegistry.getRoleHat(orgId, 0);
        uint256 executiveHat = orgRegistry.getRoleHat(orgId, 1);
        assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(orgOwner, defaultHat), "non-voting role must still mint");
        // Sanity: also wears the voting EXECUTIVE hat.
        assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(orgOwner, executiveHat), "voting role mints");
        assertTrue(result.executor != address(0));
    }

    /*──────── internal utils ────────*/

    function _dummyInitConfig() internal view returns (IRoleManager.InitConfig memory cfg) {
        cfg.executor = address(this);
        cfg.eligibilityModule = address(this);
        cfg.hats = SEPOLIA_HATS;
        cfg.orgId = bytes32("x");
        cfg.existingOrgHats = new uint256[](0);
        cfg.existingOrgHatNames = new string[](0);
    }
}
