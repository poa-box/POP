// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

/*──────────── forge‑std helpers ───────────*/
import "forge-std/Test.sol";
import "forge-std/console.sol";

/*──────────── OpenZeppelin ───────────*/
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/*──────────── Local contracts ───────────*/
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {Executor} from "../src/Executor.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {TaskManagerLens} from "../src/lens/TaskManagerLens.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {IPaymentManager} from "../src/interfaces/IPaymentManager.sol";

import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import "../src/ImplementationRegistry.sol";
import "../src/PoaManager.sol";
import "../src/OrgRegistry.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../src/OrgDeployer.sol";
import {GovernanceFactory} from "../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../src/factories/AccessFactory.sol";
import {RoleConfigStructs} from "../src/libs/RoleConfigStructs.sol";
import {ModulesFactory} from "../src/factories/ModulesFactory.sol";
import {HatsTreeSetup} from "../src/HatsTreeSetup.sol";
import {ModuleDeploymentLib, IHybridVotingInit} from "../src/libs/ModuleDeploymentLib.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {RoleBundleHatter} from "../src/RoleBundleHatter.sol";
import {IExecutor} from "../src/Executor.sol";
import {SwitchableBeacon} from "../src/SwitchableBeacon.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PackedUserOperation, UserOpLib} from "../src/interfaces/PackedUserOperation.sol";
import {PasskeyAccount} from "../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../src/PasskeyAccountFactory.sol";
import {WebAuthnLib} from "../src/libs/WebAuthnLib.sol";

// Define events for testing
interface IEligibilityModuleEvents {
    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );

    event DefaultEligibilityUpdated(uint256 indexed hatId, bool eligible, bool standing, address indexed admin);

    event SuperAdminTransferred(address indexed oldSuperAdmin, address indexed newSuperAdmin);

    event Vouched(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);

    event VouchRevoked(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);

    event HatClaimed(address indexed wearer, uint256 indexed hatId);

    event VouchConfigSet(
        uint256 indexed hatId, uint32 quorum, uint256 membershipHatId, bool enabled, bool combineWithHierarchy
    );

    event HatCreatedWithEligibility(
        address indexed creator,
        uint256 indexed parentHatId,
        uint256 indexed newHatId,
        bool defaultEligible,
        bool defaultStanding,
        uint256 mintedCount
    );

    event RoleApplicationSubmitted(uint256 indexed hatId, address indexed applicant, bytes32 applicationHash);

    event RoleApplicationWithdrawn(uint256 indexed hatId, address indexed applicant);
}

/*────────────── Test contract ───────────*/
contract DeployerTest is Test, IEligibilityModuleEvents {
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

    ImplementationRegistry implRegistry;
    PoaManager poaManager;
    OrgRegistry orgRegistry;
    OrgDeployer deployer;
    GovernanceFactory governanceFactory;
    AccessFactory accessFactory;
    ModulesFactory modulesFactory;
    PaymasterHub paymasterHub;
    PasskeyAccountFactory universalPasskeyFactory;

    /*–––– addresses ––––*/
    address public constant poaAdmin = address(1);
    address public constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant orgOwner = address(2);
    address public constant POA_GUARDIAN = address(0x600D);
    address public constant voter1 = address(3);
    address public constant voter2 = address(4);
    address public constant SEPOLIA_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    /*–––– ids ––––*/
    bytes32 public constant ORG_ID = keccak256("AUTO-UPGRADE-ORG");
    bytes32 public constant GLOBAL_REG_ID = keccak256("POA-GLOBAL-ACCOUNT-REGISTRY");

    /*–––– deployed proxies ––––*/
    address quickJoinProxy;
    address pTokenProxy;
    address payable executorProxy;
    address hybridProxy;
    address taskMgrProxy;
    address eduHubProxy;
    address accountRegProxy;

    /*–––– Test Helper Structs ––––*/
    struct TestOrgSetup {
        address hybrid;
        address exec;
        address qj;
        address token;
        address tm;
        address hub;
        address eligibilityModule;
        uint256 defaultRoleHat;
        uint256 executiveRoleHat;
        uint256 memberRoleHat;
    }

    struct EligibilityStatus {
        bool eligible;
        bool standing;
    }

    function _deployFullOrg()
        internal
        returns (address hybrid, address exec, address qj, address token, address tm, address hub, address pm)
    {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0); // Empty for now

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Hybrid DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();
        return (
            result.hybridVoting,
            result.executor,
            result.quickJoin,
            result.participationToken,
            result.taskManager,
            result.educationHub,
            result.paymentManager
        );
    }

    /*–––– Test Helper Functions ––––*/

    /// @dev Helper to build role configs from simple arrays with sensible defaults
    /// @param names Role names
    /// @param images Role images
    /// @param canVote Whether each role can vote
    /// @return Role configs with default settings (no vouching, all eligible, linear hierarchy)
    function _buildSimpleRoleConfigs(string[] memory names, string[] memory images, bool[] memory canVote)
        internal
        pure
        returns (RoleConfigStructs.RoleConfig[] memory)
    {
        RoleConfigStructs.RoleConfig[] memory roles = new RoleConfigStructs.RoleConfig[](names.length);

        for (uint256 i = 0; i < names.length; i++) {
            // Last role (highest index) is top of hierarchy, minted to deployer
            bool isTopRole = (i == names.length - 1);

            roles[i] = RoleConfigStructs.RoleConfig({
                name: names[i],
                image: images[i],
                metadataCID: bytes32(0),
                canVote: canVote[i],
                vouching: RoleConfigStructs.RoleVouchingConfig({
                    enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
                }),
                defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
                hierarchy: RoleConfigStructs.RoleHierarchyConfig({
                    adminRoleIndex: isTopRole ? type(uint256).max : i + 1
                }),
                distribution: RoleConfigStructs.RoleDistributionConfig({
                    mintToDeployer: isTopRole && canVote[i], additionalWearers: new address[](0)
                }),
                hatConfig: RoleConfigStructs.HatConfig({
                    maxSupply: type(uint32).max, // Default: unlimited
                    mutableHat: true // Default: mutable
                })
            });
        }

        return roles;
    }

    /// @dev Helper to build default role assignments (index 0 = members, index 1 = executives)
    function _buildDefaultRoleAssignments() internal pure returns (OrgDeployer.RoleAssignments memory) {
        // Bitmap encoding: bit 0 = role 0, bit 1 = role 1
        // 1 = 0b001 (role 0 only)
        // 2 = 0b010 (role 1 only)

        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 1, // Role 0: new members
            tokenMemberRolesBitmap: 1, // Role 0: can hold tokens
            tokenApproverRolesBitmap: 2, // Role 1: can approve transfers
            taskCreatorRolesBitmap: 2, // Role 1: can create tasks
            educationCreatorRolesBitmap: 2, // Role 1: can create education
            educationMemberRolesBitmap: 1, // Role 0: can access education
            hybridProposalCreatorRolesBitmap: 2, // Role 1: can create proposals
            ddVotingRolesBitmap: 1, // Role 0: can vote in polls
            ddCreatorRolesBitmap: 2 // Role 1: can create polls
        });
    }

    /// @dev Helper to build empty bootstrap config
    function _defaultPaymasterConfig() internal pure returns (OrgDeployer.PaymasterConfig memory) {
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
        ITaskManagerBootstrap.BootstrapProjectConfig[] memory projects =
            new ITaskManagerBootstrap.BootstrapProjectConfig[](0);
        ITaskManagerBootstrap.BootstrapTaskConfig[] memory tasks = new ITaskManagerBootstrap.BootstrapTaskConfig[](0);
        return OrgDeployer.BootstrapConfig({projects: projects, tasks: tasks});
    }

    function _emptyTaskManagerPerms() internal pure returns (OrgDeployer.TaskManagerPermConfig memory) {
        return OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)});
    }

    /// @dev Helper to build bootstrap config with one project and two tasks
    function _buildBootstrapWithTasks() internal pure returns (OrgDeployer.BootstrapConfig memory) {
        ITaskManagerBootstrap.BootstrapProjectConfig[] memory projects =
            new ITaskManagerBootstrap.BootstrapProjectConfig[](1);

        uint256[] memory createRoles = new uint256[](1);
        createRoles[0] = 1; // EXECUTIVE role index
        uint256[] memory claimRoles = new uint256[](2);
        claimRoles[0] = 0; // DEFAULT role index
        claimRoles[1] = 1; // EXECUTIVE role index
        uint256[] memory reviewRoles = new uint256[](1);
        reviewRoles[0] = 1; // EXECUTIVE role index
        uint256[] memory assignRoles = new uint256[](1);
        assignRoles[0] = 1; // EXECUTIVE role index
        address[] memory managers = new address[](0);

        projects[0] = ITaskManagerBootstrap.BootstrapProjectConfig({
            title: bytes("Getting Started"),
            metadataHash: bytes32(0),
            cap: 1000 ether,
            managers: managers,
            // Sentinel `type(uint256).max` = no project override (use global cap hat).
            createHat: createRoles.length > 0 ? createRoles[0] : type(uint256).max,
            claimHat: claimRoles.length > 0 ? claimRoles[0] : type(uint256).max,
            reviewHat: reviewRoles.length > 0 ? reviewRoles[0] : type(uint256).max,
            assignHat: assignRoles.length > 0 ? assignRoles[0] : type(uint256).max,
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });

        ITaskManagerBootstrap.BootstrapTaskConfig[] memory tasks = new ITaskManagerBootstrap.BootstrapTaskConfig[](2);
        tasks[0] = ITaskManagerBootstrap.BootstrapTaskConfig({
            projectIndex: 0,
            payout: 10 ether,
            title: bytes("Complete your profile"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });
        tasks[1] = ITaskManagerBootstrap.BootstrapTaskConfig({
            projectIndex: 0,
            payout: 5 ether,
            title: bytes("Introduce yourself"),
            metadataHash: bytes32(0),
            bountyToken: address(0),
            bountyPayout: 0,
            requiresApplication: false
        });

        return OrgDeployer.BootstrapConfig({projects: projects, tasks: tasks});
    }

    /// @dev Helper to build legacy-style voting classes
    function _buildLegacyClasses(uint8 ddSplit, uint8 ptSplit, bool quadratic, uint256 minBal)
        internal
        pure
        returns (IHybridVotingInit.ClassConfig[] memory)
    {
        // Build classes with empty hat arrays - they'll be filled in during deployment
        uint256[] memory emptyHats = new uint256[](0);

        IHybridVotingInit.ClassConfig[] memory classes;

        if (ddSplit == 100) {
            // Pure Direct Democracy
            classes = new IHybridVotingInit.ClassConfig[](1);
            classes[0] = IHybridVotingInit.ClassConfig({
                strategy: IHybridVotingInit.ClassStrategy.DIRECT,
                slicePct: 100,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatId: 0
            });
        } else if (ddSplit == 0) {
            // Pure Token Voting
            classes = new IHybridVotingInit.ClassConfig[](1);
            classes[0] = IHybridVotingInit.ClassConfig({
                strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
                slicePct: 100,
                quadratic: quadratic,
                minBalance: minBal,
                asset: address(0), // Will be set during deployment
                hatId: 0
            });
        } else {
            // Hybrid (two classes)
            classes = new IHybridVotingInit.ClassConfig[](2);

            // Class 0: Direct Democracy
            classes[0] = IHybridVotingInit.ClassConfig({
                strategy: IHybridVotingInit.ClassStrategy.DIRECT,
                slicePct: ddSplit,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatId: 0
            });

            // Class 1: Participation Token
            classes[1] = IHybridVotingInit.ClassConfig({
                strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
                slicePct: ptSplit,
                quadratic: quadratic,
                minBalance: minBal,
                asset: address(0), // Will be set during deployment
                hatId: 0
            });
        }

        return classes;
    }

    /// @dev Creates a standardized test organization with 3 roles: DEFAULT, EXECUTIVE, MEMBER
    function _createTestOrg(string memory orgName) internal returns (TestOrgSetup memory setup) {
        vm.startPrank(orgOwner);

        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";

        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://member-role-image";

        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: orgName,
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        setup.hybrid = result.hybridVoting;
        setup.exec = result.executor;
        setup.qj = result.quickJoin;
        setup.token = result.participationToken;
        setup.tm = result.taskManager;
        setup.hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module and role hat IDs
        setup.eligibilityModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);
        setup.defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        setup.executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        setup.memberRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);
    }

    /// @dev Creates a test organization with 2 roles (for backward compatibility)
    function _createSimpleTestOrg(string memory orgName) internal returns (TestOrgSetup memory setup) {
        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";

        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";

        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: orgName,
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        setup.hybrid = result.hybridVoting;
        setup.exec = result.executor;
        setup.qj = result.quickJoin;
        setup.token = result.participationToken;
        setup.tm = result.taskManager;
        setup.hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module and role hat IDs
        setup.eligibilityModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);
        setup.defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        setup.executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        setup.memberRoleHat = 0; // Not applicable for 2-role setup
    }

    /// @dev Configures vouching for a hat and optionally sets default eligibility to false
    function _configureVouching(
        address eligibilityModule,
        address executor,
        uint256 targetHat,
        uint32 quorum,
        uint256 membershipHat,
        bool combineWithHierarchy,
        bool setDefaultToFalse
    ) internal {
        vm.prank(executor);
        EligibilityModule(eligibilityModule).configureVouching(targetHat, quorum, membershipHat, combineWithHierarchy);

        if (setDefaultToFalse) {
            vm.prank(executor);
            EligibilityModule(eligibilityModule).setDefaultEligibility(targetHat, false, false);
        }
    }

    /// @dev Mints a hat to a user
    function _mintHat(address executor, uint256 hatId, address user) internal {
        vm.prank(executor);
        IHats(SEPOLIA_HATS).mintHat(hatId, user);
    }

    /// @dev Mints a hat to a user and sets up vouching join time
    function _mintAdminHat(address executor, address eligibilityModule, uint256 hatId, address user) internal {
        // Mint the hat to the user
        vm.prank(executor);
        IHats(SEPOLIA_HATS).mintHat(hatId, user);

        // Set user join time for vouching tests
        vm.prank(executor);
        EligibilityModule(eligibilityModule).setUserJoinTime(user, block.timestamp - 3 days);
    }

    /// @dev Checks eligibility status for a user and hat
    function _getEligibilityStatus(address eligibilityModule, address user, uint256 hatId)
        internal
        view
        returns (EligibilityStatus memory status)
    {
        (status.eligible, status.standing) = EligibilityModule(eligibilityModule).getWearerStatus(user, hatId);
    }

    /// @dev Asserts eligibility status
    function _assertEligibilityStatus(
        address eligibilityModule,
        address user,
        uint256 hatId,
        bool expectedEligible,
        bool expectedStanding,
        string memory message
    ) internal {
        EligibilityStatus memory status = _getEligibilityStatus(eligibilityModule, user, hatId);
        if (expectedEligible) {
            assertTrue(status.eligible, string(abi.encodePacked(message, " - should be eligible")));
        } else {
            assertFalse(status.eligible, string(abi.encodePacked(message, " - should not be eligible")));
        }
        if (expectedStanding) {
            assertTrue(status.standing, string(abi.encodePacked(message, " - should have good standing")));
        } else {
            assertFalse(status.standing, string(abi.encodePacked(message, " - should not have good standing")));
        }
    }

    /// @dev Sets up user for vouching by setting their join time
    function _setupUserForVouching(address eligibilityModule, address executor, address user) internal {
        vm.prank(executor);
        EligibilityModule(eligibilityModule).setUserJoinTime(user, block.timestamp - 3 days);
    }

    /// @dev Performs a vouch and returns the new count
    function _vouchFor(address voucher, address eligibilityModule, address wearer, uint256 hatId)
        internal
        returns (uint32 newCount)
    {
        vm.prank(voucher);
        EligibilityModule(eligibilityModule).vouchFor(wearer, hatId);
        newCount = EligibilityModule(eligibilityModule).currentVouchCount(hatId, wearer);
    }

    /// @dev Revokes a vouch and returns the new count
    function _revokeVouch(address voucher, address eligibilityModule, address wearer, uint256 hatId)
        internal
        returns (uint32 newCount)
    {
        vm.prank(voucher);
        EligibilityModule(eligibilityModule).revokeVouch(wearer, hatId);
        newCount = EligibilityModule(eligibilityModule).currentVouchCount(hatId, wearer);
    }

    /// @dev Asserts vouch count and approval status
    function _assertVouchStatus(
        address eligibilityModule,
        address wearer,
        uint256 hatId,
        uint32 expectedCount,
        bool expectedApproval,
        string memory message
    ) internal {
        uint32 actualCount = EligibilityModule(eligibilityModule).currentVouchCount(hatId, wearer);
        // Calculate approval status based on quorum
        EligibilityModule.VouchConfig memory config = EligibilityModule(eligibilityModule).getVouchConfig(hatId);
        bool actualApproval = actualCount >= config.quorum;

        assertEq(actualCount, expectedCount, string(abi.encodePacked(message, " - vouch count")));
        if (expectedApproval) {
            assertTrue(actualApproval, string(abi.encodePacked(message, " - should be approved")));
        } else {
            assertFalse(actualApproval, string(abi.encodePacked(message, " - should not be approved")));
        }
    }

    /// @dev Asserts that a user is wearing a hat
    function _assertWearingHat(address user, uint256 hatId, bool shouldBeWearing, string memory message) internal {
        bool isWearing = IHats(SEPOLIA_HATS).isWearerOfHat(user, hatId);
        if (shouldBeWearing) {
            assertTrue(isWearing, string(abi.encodePacked(message, " - should be wearing hat")));
        } else {
            assertFalse(isWearing, string(abi.encodePacked(message, " - should not be wearing hat")));
        }
    }

    /// @dev Gets vouch configuration for a hat
    function _getVouchConfig(address eligibilityModule, uint256 hatId)
        internal
        view
        returns (EligibilityModule.VouchConfig memory)
    {
        return EligibilityModule(eligibilityModule).getVouchConfig(hatId);
    }

    /*══════════════════════════════════════════ SET‑UP ══════════════════════════════════════════*/
    function setUp() public {
        // Fork Sepolia using the RPC URL from foundry.toml
        vm.createSelectFork("hoodi");

        /*–– deploy bare implementations ––*/
        hybridImpl = new HybridVoting();
        ddVotingImpl = new DirectDemocracyVoting();
        execImpl = new Executor();
        accountRegImpl = new UniversalAccountRegistry();
        quickJoinImpl = new QuickJoin();
        pTokenImpl = new ParticipationToken();
        taskMgrImpl = new TaskManager();
        eduHubImpl = new EducationHub();
        paymentManagerImpl = new PaymentManager();

        // Deploy the implementation contract for ImplementationRegistry
        ImplementationRegistry implRegistryImpl = new ImplementationRegistry();

        // Deploy EligibilityModule implementation
        EligibilityModule eligibilityModuleImpl = new EligibilityModule();

        // Deploy ToggleModule implementation
        ToggleModule toggleModuleImpl = new ToggleModule();

        // Deploy RoleBundleHatter implementation
        RoleBundleHatter roleBundleHatterImpl = new RoleBundleHatter();

        vm.startPrank(poaAdmin);
        console.log("Current msg.sender:", msg.sender);

        /*–– infra ––*/
        // Deploy PoaManager first without the actual registry address
        // We'll update it later after we create the proxy
        poaManager = new PoaManager(address(0)); // Temporary zero address

        // Deploy implementations for OrgRegistry and OrgDeployer
        OrgRegistry orgRegistryImpl = new OrgRegistry();
        OrgDeployer deployerImpl = new OrgDeployer();

        // Register ImplementationRegistry implementation with PoaManager first
        poaManager.addContractType("ImplementationRegistry", address(implRegistryImpl));

        // Get the beacon for ImplementationRegistry
        bytes32 implRegTypeId = keccak256("ImplementationRegistry");
        address implRegBeacon = poaManager.getBeaconById(implRegTypeId);

        // Create ImplementationRegistry proxy and initialize it with poaAdmin as owner
        bytes memory implRegistryInit = abi.encodeWithSignature("initialize(address)", poaAdmin);
        implRegistry = ImplementationRegistry(address(new BeaconProxy(implRegBeacon, implRegistryInit)));

        // Now update the PoaManager to use the correct ImplementationRegistry proxy
        poaManager.updateImplRegistry(address(implRegistry));

        // Register the implRegistryImpl in the registry now that it's connected
        implRegistry.registerImplementation("ImplementationRegistry", "v1", address(implRegistryImpl), true);

        // Transfer implRegistry ownership to poaManager
        implRegistry.transferOwnership(address(poaManager));

        // Register implementations for OrgRegistry and OrgDeployer
        poaManager.addContractType("OrgRegistry", address(orgRegistryImpl));
        poaManager.addContractType("OrgDeployer", address(deployerImpl));

        // Get beacons created by PoaManager
        address orgRegBeacon = poaManager.getBeaconById(keccak256("OrgRegistry"));
        address deployerBeacon = poaManager.getBeaconById(keccak256("OrgDeployer"));

        // Create OrgRegistry proxy - initialize with poaAdmin as owner and hats address
        bytes memory orgRegistryInit = abi.encodeWithSignature("initialize(address,address)", poaAdmin, SEPOLIA_HATS);
        orgRegistry = OrgRegistry(address(new BeaconProxy(orgRegBeacon, orgRegistryInit)));

        // Debug to verify OrgRegistry owner
        console.log("OrgRegistry owner after init:", orgRegistry.owner());

        // Deploy HatsTreeSetup helper contract
        HatsTreeSetup hatsTreeSetup = new HatsTreeSetup();

        // Mock EntryPoint address for PaymasterHub (not actually used in tests, but required for initialization)
        address mockEntryPoint = address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789); // ERC-4337 EntryPoint v0.6

        // Deploy factory contracts
        governanceFactory = new GovernanceFactory();
        accessFactory = new AccessFactory();
        modulesFactory = new ModulesFactory();

        // Deploy PaymasterHub as beacon proxy
        PaymasterHub paymasterHubImpl = new PaymasterHub();
        poaManager.addContractType("PaymasterHub", address(paymasterHubImpl));
        address paymasterHubBeacon = poaManager.getBeaconById(keccak256("PaymasterHub"));
        bytes memory paymasterHubInit = abi.encodeWithSignature(
            "initialize(address,address,address)", ENTRY_POINT_V07, SEPOLIA_HATS, address(poaManager)
        );
        paymasterHub = PaymasterHub(payable(address(new BeaconProxy(paymasterHubBeacon, paymasterHubInit))));

        // Create OrgDeployer proxy - initialize with factory addresses
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

        // Authorize OrgDeployer to register orgs on PaymasterHub
        vm.stopPrank();
        vm.prank(address(poaManager));
        paymasterHub.setOrgRegistrar(address(deployer));
        vm.startPrank(poaAdmin);

        // Debug to verify Deployer initialization
        console.log("deployer address:", address(deployer));

        // Now transfer orgRegistry ownership to deployer after both are initialized
        // This is critical to get the ownership chain right
        orgRegistry.transferOwnership(address(deployer));
        console.log("OrgRegistry owner after transfer:", orgRegistry.owner());

        /*–– register implementation types ––*/
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
        poaManager.addContractType("RoleBundleHatter", address(roleBundleHatterImpl));
        poaManager.addContractType("PaymentManager", address(paymentManagerImpl));

        /*–– global account registry instance ––*/
        // Get the beacon created by PoaManager for account registry
        address accRegBeacon = poaManager.getBeaconById(keccak256("UniversalAccountRegistry"));

        // Create a proxy using the beacon with proper initialization data
        bytes memory accRegInit = abi.encodeWithSignature("initialize(address)", poaAdmin);
        accountRegProxy = address(new BeaconProxy(accRegBeacon, accRegInit));

        /*–– passkey infrastructure (mirrors DeployInfrastructure.s.sol) ––*/
        PasskeyAccount passkeyAccountImpl = new PasskeyAccount();
        PasskeyAccountFactory passkeyFactoryImpl = new PasskeyAccountFactory();
        poaManager.addContractType("PasskeyAccount", address(passkeyAccountImpl));
        poaManager.addContractType("PasskeyAccountFactory", address(passkeyFactoryImpl));

        address passkeyAccountBeacon = poaManager.getBeaconById(keccak256("PasskeyAccount"));
        address passkeyFactoryBeacon = poaManager.getBeaconById(keccak256("PasskeyAccountFactory"));
        bytes memory passkeyFactoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint48)",
            address(poaManager),
            passkeyAccountBeacon,
            POA_GUARDIAN,
            uint48(7 days)
        );
        universalPasskeyFactory =
            PasskeyAccountFactory(address(new BeaconProxy(passkeyFactoryBeacon, passkeyFactoryInit)));

        // Wire factory to OrgDeployer (requires msg.sender == poaManager)
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setUniversalPasskeyFactory(address)", address(universalPasskeyFactory))
        );

        // Wire factory to GlobalAccountRegistry (owner = poaAdmin)
        UniversalAccountRegistry(accountRegProxy).setPasskeyFactory(address(universalPasskeyFactory));

        vm.stopPrank();
    }

    /*══════════════════════════════════════════ TESTS ══════════════════════════════════════════*/
    function testFullOrgDeployment() public {
        /*–––– deploy a full org via the new flow ––––*/
        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Hybrid DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        vm.stopPrank();

        /* store for later checks */
        hybridProxy = result.hybridVoting;
        executorProxy = payable(result.executor);
        quickJoinProxy = result.quickJoin;
        pTokenProxy = result.participationToken;
        taskMgrProxy = result.taskManager;
        eduHubProxy = result.educationHub;

        /* basic invariants */
        // Version getters removed - contracts are upgradeable via beacon pattern

        /*—————————————————— quick smoke test: join + vote —————————————————*/
        vm.prank(executorProxy);
        QuickJoin(quickJoinProxy).quickJoinNoUserMasterDeploy(voter1);
        vm.prank(executorProxy);
        QuickJoin(quickJoinProxy).quickJoinNoUserMasterDeploy(voter2);

        // Give voter1 the EXECUTIVE role hat for creating proposals
        // (voter1 already has DEFAULT hat from QuickJoin, but needs EXECUTIVE for creating)
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1); // EXECUTIVE role hat
        vm.prank(executorProxy);
        IHats(SEPOLIA_HATS).mintHat(executiveRoleHat, voter1);

        // voter2 already has DEFAULT hat from QuickJoin, which is sufficient for voting

        /* create proposal */
        uint8 optNumber = 2;

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);

        vm.prank(voter1);
        uint256[] memory hatIds = new uint256[](0);
        HybridVoting(hybridProxy).createProposal(bytes("ipfs://test"), bytes32(0), 60, optNumber, batches, hatIds);

        /* vote YES */
        uint8[] memory idxList = new uint8[](1);
        idxList[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;

        vm.prank(voter1);
        HybridVoting(hybridProxy).vote(0, idxList, w);

        /* fast‑forward and finalise */
        vm.warp(block.timestamp + 61 minutes);
        (uint256 winner, bool valid) = HybridVoting(hybridProxy).announceWinner(0);

        assertTrue(valid, "threshold not reached");
        assertEq(winner, 0, "YES should win");
    }

    function testFullOrgDeploymentRegistersContracts() public {
        (address hybrid, address exec, address qj, address token, address tm, address hub, address pm) =
            _deployFullOrg();

        (address executorAddr, uint32 count, bool boot, bool exists) = orgRegistry.orgOf(ORG_ID);
        assertEq(executorAddr, exec); // Should be the Executor contract address, not orgOwner
        assertEq(count, 11); // Updated to 11: prior 10 plus the per-org RoleBundleHatter
        assertFalse(boot);
        assertTrue(exists);

        bytes32 typeId = keccak256("QuickJoin");
        bytes32 contractId = keccak256(abi.encodePacked(ORG_ID, typeId));
        (address proxy, address beacon, bool autoUp, address owner) = orgRegistry.contractOf(contractId);
        assertEq(proxy, qj);
        assertTrue(autoUp);
        assertEq(owner, exec);

        address impl = IBeacon(beacon).implementation();
        assertEq(impl, poaManager.getCurrentImplementationById(ModuleTypes.QUICK_JOIN_ID));

        // Verify PaymentManager is deployed and registered
        bytes32 pmTypeId = keccak256("PaymentManager");
        bytes32 pmContractId = keccak256(abi.encodePacked(ORG_ID, pmTypeId));
        (address pmProxy, address pmBeacon, bool pmAutoUp, address pmOwner) = orgRegistry.contractOf(pmContractId);
        assertEq(pmProxy, pm, "PaymentManager proxy should match");
        assertTrue(pmAutoUp, "PaymentManager should have auto-upgrade enabled");
        assertEq(pmOwner, exec, "PaymentManager owner should be executor");

        // Verify PaymentManager is properly initialized
        PaymentManager paymentManager = PaymentManager(payable(pm));
        assertEq(paymentManager.revenueShareToken(), token, "Revenue share token should be the participation token");
        assertEq(paymentManager.owner(), exec, "PaymentManager owner should be executor");
    }

    function testFullOrgDeploymentWithBootstrapAndClearDeployer() public {
        /*–––– deploy a full org with bootstrap config ––––*/
        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Bootstrap DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _buildBootstrapWithTasks(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        vm.stopPrank();

        // Verify TaskManager was deployed
        assertTrue(result.taskManager != address(0), "TaskManager should be deployed");

        // After deployment, deployer address should be cleared
        // Attempting to call bootstrap again should fail with NotDeployer
        ITaskManagerBootstrap.BootstrapProjectConfig[] memory moreProjects =
            new ITaskManagerBootstrap.BootstrapProjectConfig[](1);

        uint256[] memory createRoles = new uint256[](1);
        createRoles[0] = 1;
        uint256[] memory claimRoles = new uint256[](1);
        claimRoles[0] = 0;
        address[] memory managers = new address[](0);

        moreProjects[0] = ITaskManagerBootstrap.BootstrapProjectConfig({
            title: bytes("Second Project"),
            metadataHash: bytes32(0),
            cap: 100 ether,
            managers: managers,
            // Sentinel `type(uint256).max` = no project override (use global cap hat).
            createHat: createRoles.length > 0 ? createRoles[0] : type(uint256).max,
            claimHat: claimRoles.length > 0 ? claimRoles[0] : type(uint256).max,
            reviewHat: createRoles.length > 0 ? createRoles[0] : type(uint256).max,
            assignHat: createRoles.length > 0 ? createRoles[0] : type(uint256).max,
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });

        ITaskManagerBootstrap.BootstrapTaskConfig[] memory moreTasks =
            new ITaskManagerBootstrap.BootstrapTaskConfig[](0);

        // OrgDeployer should no longer be able to bootstrap (deployer was cleared)
        vm.prank(address(deployer));
        vm.expectRevert(TaskManager.NotDeployer.selector);
        ITaskManagerBootstrap(result.taskManager).bootstrapProjectsAndTasks(moreProjects, moreTasks);

        // clearDeployer should also fail since deployer is already cleared
        vm.prank(address(deployer));
        vm.expectRevert(TaskManager.NotDeployer.selector);
        ITaskManagerBootstrap(result.taskManager).clearDeployer();
    }

    /*━━━━━━━━━━━━━━━━━━━━ taskManagerPerms bootstrap (v5) ━━━━━━━━━━━━━━━━━━━━*/

    /// @dev Common builder for a deploy that grants `mask` to the role at `roleIndex` globally.
    function _buildParamsWithTaskPerm(uint256 roleIndex, uint8 mask)
        internal
        view
        returns (OrgDeployer.DeploymentParams memory params)
    {
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://executive";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        uint256[] memory roleIndices = new uint256[](1);
        roleIndices[0] = roleIndex;
        uint8[] memory masks = new uint8[](1);
        masks[0] = mask;

        params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "v5-bootstrap-perms",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _buildBootstrapWithTasks(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: roleIndices, masks: masks})
        });
    }

    /// @dev Create a fresh project + task post-deploy with no per-project mask for the editor hat
    ///      (so the global ROLE_PERM grant isn't shadowed). Uses the executor as creator/PM to
    ///      avoid leaking per-project perms to any role we care about, and to give the test a
    ///      caller that bypasses createTask's permission gate. The claimer is then a hat wearer
    ///      whose hat IS in claimHats. Returns the fresh pid and the claimed task id.
    function _createFreshProjectAndClaim(
        TaskManager tm,
        address executorAddr,
        uint256 claimerHatId,
        address claimerAddr
    ) internal returns (bytes32 pid, uint256 taskId) {
        // Executor creates the project — bypasses createProject's creator-hat gate. We
        // deliberately leave createHat unset so no role gets a per-project CREATE hat that
        // could shadow a global grant we want to test.
        vm.prank(executorAddr);
        pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("fresh"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: new address[](0),
                createHat: 0,
                claimHat: claimerHatId,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Compute the next task id BEFORE pranking, otherwise the staticcall inside _nextTaskId
        // consumes the vm.prank and createTask runs as the test contract.
        taskId = _nextTaskId(tm);
        vm.prank(executorAddr);
        tm.createTask(2 ether, bytes("fresh-task"), bytes32(0), pid, address(0), 0, false);

        vm.prank(claimerAddr);
        tm.claimTask(taskId);
    }

    /// @dev Probe the next available task id without relying on internal storage.
    function _nextTaskId(TaskManager tm) internal view returns (uint256 id) {
        for (uint256 i; i < 1_000_000; ++i) {
            (bool ok,) = address(tm)
                .staticcall(abi.encodeWithSelector(TaskManager.getLensData.selector, uint8(1), abi.encode(i)));
            if (!ok) return i;
        }
        revert("no available task id");
    }

    function testBootstrapTaskManagerPerms_GrantsEditFullAtDeployTime() public {
        // Grant EDIT_FULL to EXECUTIVE (role 1) at deploy time. orgOwner wears EXECUTIVE.
        vm.startPrank(orgOwner);
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(1, TaskPerm.EDIT_FULL);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        TaskManager tm = TaskManager(result.taskManager);

        // Pre-flight: orgOwner must wear EXECUTIVE for the rest of this test to mean anything.
        uint256 executiveHat = orgRegistry.getRoleHat(ORG_ID, 1);
        require(IHats(SEPOLIA_HATS).isWearerOfHat(orgOwner, executiveHat), "orgOwner must wear EXECUTIVE");

        // QuickJoin a member who'll claim the fresh task.
        address member = makeAddr("v5-member");
        vm.prank(result.executor);
        QuickJoin(result.quickJoin).quickJoinNoUserMasterDeploy(member);

        // Create a fresh project with no per-project perms for any role — global EDIT_FULL
        // grant for EXECUTIVE applies via _permMask's fallback path.
        uint256 defaultHat = orgRegistry.getRoleHat(ORG_ID, 0);
        (, uint256 taskId) = _createFreshProjectAndClaim(tm, result.executor, defaultHat, member);

        // orgOwner wears EXECUTIVE → has global EDIT_FULL → can edit the CLAIMED task on the
        // fresh project (no per-project mask shadowing the global grant).
        vm.prank(orgOwner);
        tm.updateTask(taskId, 25 ether, bytes("edited-at-deploy"), bytes32(0), address(0), 0);

        // And updateTaskMetadata is also available to EDIT_FULL holders.
        vm.prank(orgOwner);
        tm.updateTaskMetadata(taskId, bytes("meta-edit"), bytes32(uint256(0xfeed)));
    }

    function testBootstrapTaskManagerPerms_GrantsEditMetaOnlyAtDeployTime() public {
        // Grant EDIT_META (not EDIT_FULL) to EXECUTIVE.
        vm.startPrank(orgOwner);
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(1, TaskPerm.EDIT_META);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        TaskManager tm = TaskManager(result.taskManager);

        address member = makeAddr("v5-member-meta");
        vm.prank(result.executor);
        QuickJoin(result.quickJoin).quickJoinNoUserMasterDeploy(member);

        uint256 defaultHat = orgRegistry.getRoleHat(ORG_ID, 0);
        (, uint256 taskId) = _createFreshProjectAndClaim(tm, result.executor, defaultHat, member);

        // EDIT_META only — metadata edit succeeds, full edit reverts.
        vm.prank(orgOwner);
        tm.updateTaskMetadata(taskId, bytes("meta-only"), bytes32(uint256(0xab)));

        vm.prank(orgOwner);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.updateTask(taskId, 50 ether, bytes("nope"), bytes32(0), address(0), 0);
    }

    function testBootstrapTaskManagerPerms_GlobalGrantNotShadowedByProjectOverride() public {
        // Capability-hat model: gates are INDEPENDENT. The bootstrap project sets per-project
        // CREATE/CLAIM/REVIEW/ASSIGN hats, but it does NOT touch the EDIT_FULL gate — so
        // _capHat(pid, EDIT_FULL) falls back to the global grant. Unlike the old bitmask model
        // (where a non-zero per-project mask replaced the global mask), the global EDIT_FULL grant
        // is NOT shadowed: the EXECUTIVE-hat wearer can still edit a claimed bootstrap task.
        vm.startPrank(orgOwner);
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(1, TaskPerm.EDIT_FULL);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        TaskManager tm = TaskManager(result.taskManager);

        address member = makeAddr("v5-shadow-member");
        vm.prank(result.executor);
        QuickJoin(result.quickJoin).quickJoinNoUserMasterDeploy(member);
        vm.prank(member);
        tm.claimTask(0);

        // orgOwner wears the EXECUTIVE hat (top role minted to deployer) = the global EDIT_FULL gate.
        vm.prank(orgOwner);
        tm.updateTask(0, 25 ether, bytes("not-shadowed"), bytes32(0), address(0), 0);
    }

    function testBootstrapTaskManagerPerms_EmptyRoleIndicesWithMasksRevertsAtomic() public {
        // Regression: an earlier draft only entered the bootstrapGlobalPerms branch when
        // roleIndices.length > 0, which silently dropped a malformed config that had empty
        // roleIndices + non-empty masks. The deploy must revert atomically so the misconfig
        // surfaces immediately.
        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://executive";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        // Empty roleIndices + non-empty masks — the malformed-config case.
        uint256[] memory roleIndices = new uint256[](0);
        uint8[] memory masks = new uint8[](1);
        masks[0] = TaskPerm.EDIT_FULL;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "v5-empty-roles-masks",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: roleIndices, masks: masks})
        });

        vm.expectRevert(TaskManager.ArrayLengthMismatch.selector);
        deployer.deployFullOrg(params);
        vm.stopPrank();
    }

    function testBootstrapTaskManagerPerms_LengthMismatchRevertsAtomicDeploy() public {
        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://executive";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        uint256[] memory roleIndices = new uint256[](2);
        roleIndices[0] = 0;
        roleIndices[1] = 1;
        uint8[] memory masks = new uint8[](1); // mismatched length
        masks[0] = TaskPerm.EDIT_FULL;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "v5-bad-perms",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: roleIndices, masks: masks})
        });

        // The whole deploy reverts atomically — no partial state.
        vm.expectRevert(TaskManager.ArrayLengthMismatch.selector);
        deployer.deployFullOrg(params);
        vm.stopPrank();
    }

    function testBootstrapTaskManagerPerms_InvalidRoleIndexReverts() public {
        vm.startPrank(orgOwner);

        // Role index 99 is out of bounds (only 2 roles defined).
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(99, TaskPerm.EDIT_FULL);

        vm.expectRevert(bytes("Invalid role index in bootstrap config"));
        deployer.deployFullOrg(params);
        vm.stopPrank();
    }

    function testBootstrapTaskManagerPerms_WiresGlobalEditFullGate() public {
        // Capability-hat model: the deploy-time grant wires the global EDIT_FULL gate to the
        // granted (EXECUTIVE) hat. Read the extended gate-hat triple via lens variant 12:
        // [budgetHat, editMetaHat, editFullHat].
        vm.startPrank(orgOwner);
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(1, TaskPerm.EDIT_FULL);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        TaskManager tm = TaskManager(result.taskManager);
        uint256 executiveHatId = orgRegistry.getRoleHat(ORG_ID, 1);

        uint256[] memory gateHats = abi.decode(tm.getLensData(12, ""), (uint256[]));
        assertEq(gateHats.length, 3, "gate-hat triple");
        assertEq(gateHats[2], executiveHatId, "EXECUTIVE hat wired as global EDIT_FULL gate");
    }

    function testBootstrapTaskManagerPerms_EmptyArraysSkipsTheCall() public {
        // Backwards-compat: empty taskManagerPerms = no grants, no revert (existing deploys work).
        vm.startPrank(orgOwner);
        OrgDeployer.DeploymentParams memory params = _buildParamsWithTaskPerm(0, 0); // overwritten below
        params.taskManagerPerms = _emptyTaskManagerPerms();
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        // Deploy succeeded. Without any global EDIT_FULL grant, post-claim edits revert.
        TaskManager tm = TaskManager(result.taskManager);

        address member = makeAddr("v5-empty-member");
        vm.prank(result.executor);
        QuickJoin(result.quickJoin).quickJoinNoUserMasterDeploy(member);
        vm.prank(member);
        tm.claimTask(0);

        vm.prank(orgOwner);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.updateTask(0, 50 ether, bytes("nope"), bytes32(0), address(0), 0);
    }

    function testDeployFullOrgMismatchExecutorReverts() public {
        _deployFullOrg();
        address other = address(99);
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSignature("OrgExistsMismatch()"));
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Hybrid DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params);
        vm.stopPrank();
    }

    function testHatsTreeDeployment() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Hybrid DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        // Verify Hats tree registration
        uint256 topHatId = orgRegistry.getTopHat(ORG_ID);
        assertTrue(topHatId != 0, "Top hat should be registered");

        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        assertTrue(defaultRoleHat != 0, "Default role hat should be registered");
        assertTrue(executiveRoleHat != 0, "Executive role hat should be registered");

        // Test creating a new role as executor
        vm.stopPrank();
        vm.startPrank(exec); // Switch to executor

        // Create a new role hat
        uint256 newRoleHatId = IHats(SEPOLIA_HATS)
            .createHat(
                topHatId, // admin = parent Top Hat
                "NEW_ROLE", // details
                type(uint32).max, // unlimited supply
                orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID), // eligibility module
                orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID), // toggle module
                true, // mutable
                "NEW_ROLE" // data blob
            );

        // Configure the new role hat for the executor
        EligibilityModule(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID))
            .setWearerEligibility(exec, newRoleHatId, true, true);
        ToggleModule(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID)).setHatStatus(newRoleHatId, true);

        // Mint the new role hat to the executor
        IHats(SEPOLIA_HATS).mintHat(newRoleHatId, exec);

        // Verify the new role hat was created and minted
        assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(exec, newRoleHatId), "Executor should wear the new role hat");

        vm.stopPrank();
    }

    function testEligibilityModuleAdminHatSystem() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Hybrid DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address directly
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Verify executor is the super admin
        assertEq(EligibilityModule(eligibilityModuleAddr).superAdmin(), exec, "Executor should be the super admin");

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);

        // In the new system, admin permissions are handled natively by the Hats tree structure
        // The eligibility admin hat (created by deployer) is the admin of all role hats

        // Test admin relationships via Hats contract
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(exec, defaultRoleHat), "Executor should be admin of default role hat"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(exec, executiveRoleHat), "Executor should be admin of executive role hat"
        );

        // Test that someone wearing the executive role hat can change eligibility
        // First, mint the executive role hat to voter1
        _mintAdminHat(exec, eligibilityModuleAddr, executiveRoleHat, voter1);

        // Verify voter1 is wearing the executive role hat
        assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(voter1, executiveRoleHat), "voter1 should wear executive role hat");

        // Verify admin hierarchy: voter1 wearing executive hat should be admin of default hat
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(voter1, defaultRoleHat),
            "voter1 wearing executive hat should be admin of default hat"
        );

        // Now the executor (super admin) can change eligibility for voter2's default role hat
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, false, false);

        // Verify the eligibility was changed for voter2
        (bool eligible, bool standing) =
            EligibilityModule(eligibilityModuleAddr).getWearerStatus(voter2, defaultRoleHat);
        assertFalse(
            IHats(SEPOLIA_HATS).isEligible(voter2, defaultRoleHat), "voter2's default role hat should be ineligible"
        );
        assertFalse(
            IHats(SEPOLIA_HATS).isInGoodStanding(voter2, defaultRoleHat),
            "voter2's default role hat should have bad standing"
        );

        // voter1's eligibility should be unaffected since it's per-wearer (should still have default eligibility)
        // Check eligibility via Hats contract for voter1 and defaultRoleHat
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(voter1, defaultRoleHat),
            "voter1's default role hat should still be default (eligible)"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(voter1, defaultRoleHat),
            "voter1's default role hat should still be default (good standing)"
        );

        // Change voter2 back to eligible
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, true, true);

        // Verify the eligibility was changed back for voter2
        // Check eligibility via Hats contract for voter2 and defaultRoleHat
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(voter2, defaultRoleHat), "voter2's default role hat should be eligible"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(voter2, defaultRoleHat),
            "voter2's default role hat should have good standing"
        );

        // Test that someone other than the super admin cannot change eligibility
        // (Even voter1 wearing the executive hat is no longer a hat-admin — only superAdmin can write.)
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, false, false);

        vm.prank(voter2);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, false, false);

        // Test full flow: Executor makes someone ineligible and verifies mint reverts
        // First, make voter2 ineligible for the default role hat
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, false, false);

        // Verify voter2 cannot mint the default role hat when ineligible
        vm.prank(exec);
        vm.expectRevert();
        IHats(SEPOLIA_HATS).mintHat(defaultRoleHat, voter2);

        // Executor makes voter2 eligible for the default role hat
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, true, true);

        // Now exec should be able to mint the default role hat for voter2
        vm.prank(exec);
        bool success = IHats(SEPOLIA_HATS).mintHat(defaultRoleHat, voter2);
        assertTrue(success, "Should successfully mint hat when eligible");

        // Verify voter2 is now wearing the default role hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(voter2, defaultRoleHat), "voter2 should be wearing the default role hat"
        );

        // Verify voter2 is eligible and in good standing
        (bool eligible2, bool standing2) =
            EligibilityModule(eligibilityModuleAddr).getWearerStatus(voter2, defaultRoleHat);
        assertTrue(eligible2, "voter2 should be eligible for default role hat");
        assertTrue(standing2, "voter2 should have good standing for default role hat");

        // Test revoking eligibility while wearing the hat
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter2, defaultRoleHat, false, false);

        // Verify voter2 is now ineligible (and thus no longer wearing the hat)
        // The Hats protocol integrates eligibility checking into isWearerOfHat
        assertFalse(
            IHats(SEPOLIA_HATS).isWearerOfHat(voter2, defaultRoleHat),
            "voter2 should no longer be wearing the hat when ineligible"
        );

        // Verify voter2 is now ineligible
        (bool eligible3, bool standing3) =
            EligibilityModule(eligibilityModuleAddr).getWearerStatus(voter2, defaultRoleHat);
        assertFalse(eligible3, "voter2 should now be ineligible for default role hat");
        assertFalse(standing3, "voter2 should now have bad standing for default role hat");
    }

    // The old testMultipleAdminHatsWithRoleManagement test has been removed
    // since the new system relies on native Hats admin hierarchy instead of custom ACL

    function testExecutiveGivesHatsToTwoPeopleThenTurnsOffOne() public {
        TestOrgSetup memory setup = _createSimpleTestOrg("Executive Hat Test DAO");
        address person1 = address(0x100);
        address person2 = address(0x101);

        // First, mint the executive role hat to voter1 so they can act as an executive
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, voter1);
        _assertWearingHat(voter1, setup.executiveRoleHat, true, "voter1 executive hat");

        // Executor (super admin) makes both people eligible for the DEFAULT role hat
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person1, setup.defaultRoleHat, true, true);
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person2, setup.defaultRoleHat, true, true);

        // Verify both people are eligible for the DEFAULT role hat
        _assertEligibilityStatus(setup.eligibilityModule, person1, setup.defaultRoleHat, true, true, "person1 initial");
        _assertEligibilityStatus(setup.eligibilityModule, person2, setup.defaultRoleHat, true, true, "person2 initial");

        // The executor mints the DEFAULT role hat to both people
        vm.prank(setup.exec);
        bool success1 = IHats(SEPOLIA_HATS).mintHat(setup.defaultRoleHat, person1);
        assertTrue(success1, "Should successfully mint DEFAULT hat to person1");

        vm.prank(setup.exec);
        bool success2 = IHats(SEPOLIA_HATS).mintHat(setup.defaultRoleHat, person2);
        assertTrue(success2, "Should successfully mint DEFAULT hat to person2");

        // Verify both people are wearing the DEFAULT role hat
        _assertWearingHat(person1, setup.defaultRoleHat, true, "person1 after minting");
        _assertWearingHat(person2, setup.defaultRoleHat, true, "person2 after minting");

        // Executor turns off person1's hat but leaves person2's hat on
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person1, setup.defaultRoleHat, false, false);

        // Verify person1 is no longer eligible and not wearing the hat
        _assertEligibilityStatus(
            setup.eligibilityModule, person1, setup.defaultRoleHat, false, false, "person1 after revocation"
        );
        _assertWearingHat(person1, setup.defaultRoleHat, false, "person1 after revocation");

        // Verify person2 is still eligible and wearing the hat
        _assertEligibilityStatus(
            setup.eligibilityModule, person2, setup.defaultRoleHat, true, true, "person2 still eligible"
        );
        _assertWearingHat(person2, setup.defaultRoleHat, true, "person2 still wearing");

        // Executor can turn person1's hat back on
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person1, setup.defaultRoleHat, true, true);

        // Verify person1 is eligible again
        _assertEligibilityStatus(setup.eligibilityModule, person1, setup.defaultRoleHat, true, true, "person1 restored");
        _assertWearingHat(person1, setup.defaultRoleHat, true, "person1 restored");

        // Executor can also turn off person2's hat
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person2, setup.defaultRoleHat, false, false);

        // Verify person2 is no longer eligible and not wearing the hat
        _assertEligibilityStatus(
            setup.eligibilityModule, person2, setup.defaultRoleHat, false, false, "person2 revoked"
        );
        _assertWearingHat(person2, setup.defaultRoleHat, false, "person2 revoked");

        // Test that only the super admin can control these hats - even voter1 wearing the executive hat fails
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person2, setup.defaultRoleHat, true, true);

        vm.prank(person1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person2, setup.defaultRoleHat, true, true);

        // Test that the super admin (executor) can still control all hats
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person1, setup.defaultRoleHat, false, false);
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(person2, setup.defaultRoleHat, true, true);

        // Verify the super admin changes took effect
        _assertEligibilityStatus(
            setup.eligibilityModule, person1, setup.defaultRoleHat, false, false, "person1 super admin control"
        );
        _assertEligibilityStatus(
            setup.eligibilityModule, person2, setup.defaultRoleHat, true, true, "person2 super admin control"
        );

        // Final check: person1 should not be wearing the hat, person2 should be wearing it
        _assertWearingHat(person1, setup.defaultRoleHat, false, "person1 final");
        _assertWearingHat(person2, setup.defaultRoleHat, true, "person2 final");
    }

    function testEligibilityModuleEvents() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Events Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);

        // Test that events are emitted when setting wearer eligibility
        vm.expectEmit(true, true, false, true);
        emit WearerEligibilityUpdated(voter1, defaultRoleHat, true, true, exec);

        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(voter1, defaultRoleHat, true, true);

        // Test that events are emitted when setting default eligibility
        vm.expectEmit(true, false, false, true);
        emit DefaultEligibilityUpdated(defaultRoleHat, false, false, exec);

        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(defaultRoleHat, false, false);

        // The old ACL events are no longer supported since admin permissions
        // are now handled natively by the Hats tree structure

        // Test that events are emitted when transferring super admin
        vm.expectEmit(true, true, false, false);
        emit SuperAdminTransferred(exec, voter1);

        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).transferSuperAdmin(voter1);
    }

    function testVouchingSystemBasic() public {
        TestOrgSetup memory setup = _createTestOrg("Vouch Test DAO");
        address candidate = address(0x200);

        // Set up users for vouching (need join times set)
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Configure vouching for DEFAULT hat: require 2 vouches from MEMBER hat wearers
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Verify vouching configuration
        EligibilityModule.VouchConfig memory config = _getVouchConfig(setup.eligibilityModule, setup.defaultRoleHat);
        assertEq(config.quorum, 2, "Quorum should be 2");
        assertEq(config.membershipHatId, setup.memberRoleHat, "Membership hat should be MEMBER");
        assertTrue(
            EligibilityModule(setup.eligibilityModule).isVouchingEnabled(setup.defaultRoleHat),
            "Vouching should be enabled"
        );
        assertFalse(
            EligibilityModule(setup.eligibilityModule).combinesWithHierarchy(setup.defaultRoleHat),
            "Should not combine with hierarchy"
        );

        // Mint MEMBER hats to vouchers
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter2);

        // Initially, candidate should not be eligible
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, false, false, "Initial state"
        );

        // First vouch from voter1
        uint32 count1 = _vouchFor(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        assertEq(count1, 1, "Vouch count should be 1");
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasVouched(setup.defaultRoleHat, candidate, voter1),
            "voter1 should have vouched"
        );
        _assertVouchStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, 1, false, "After first vouch");
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, false, false, "After first vouch"
        );

        // Second vouch from voter2
        uint32 count2 = _vouchFor(voter2, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        assertEq(count2, 2, "Vouch count should be 2");
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasVouched(setup.defaultRoleHat, candidate, voter2),
            "voter2 should have vouched"
        );
        _assertVouchStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, 2, true, "After second vouch");
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, true, true, "After reaching quorum"
        );

        // Test that candidate must explicitly claim the hat after reaching quorum
        _assertWearingHat(candidate, setup.defaultRoleHat, false, "Candidate before claiming");

        // Candidate claims the hat
        vm.prank(candidate);
        EligibilityModule(setup.eligibilityModule).claimVouchedHat(setup.defaultRoleHat);

        _assertWearingHat(candidate, setup.defaultRoleHat, true, "Candidate after claiming");
    }

    function testVouchingSystemHybridMode() public {
        TestOrgSetup memory setup = _createTestOrg("Hybrid Vouch Test DAO");
        address candidate1 = address(0x201);
        address candidate2 = address(0x202);
        address voucher2 = address(0x203);

        // Set up users for vouching (need join times set)
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voucher2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate2);

        // Configure vouching for DEFAULT hat: require 2 vouches from MEMBER hat wearers, BUT also allow hierarchy
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, true, true
        );

        // Mint EXECUTIVE hat to voter1 so they can use admin powers
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, voter1);
        // Mint MEMBER hats for vouching
        _mintHat(setup.exec, setup.memberRoleHat, voter2);
        _mintHat(setup.exec, setup.memberRoleHat, voucher2);

        // Test 1: Super admin (executor) can directly make someone eligible
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(candidate1, setup.defaultRoleHat, true, true);
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate1, setup.defaultRoleHat, true, true, "Candidate1 via super admin"
        );

        // Test 2: Someone else can become eligible via vouching path
        _vouchFor(voter2, setup.eligibilityModule, candidate2, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate2, setup.defaultRoleHat, false, false, "Candidate2 with 1 vouch"
        );

        // Second vouch
        _vouchFor(voucher2, setup.eligibilityModule, candidate2, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate2, setup.defaultRoleHat, true, true, "Candidate2 via vouching"
        );

        // Test 3: Super admin attempts to revoke per-wearer eligibility, but vouching still keeps candidate eligible
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(candidate2, setup.defaultRoleHat, false, false);
        _assertEligibilityStatus(
            setup.eligibilityModule,
            candidate2,
            setup.defaultRoleHat,
            true,
            true,
            "Candidate2 after super-admin revocation"
        );

        // Test 4: If vouching is revoked, the per-wearer setting takes over
        _revokeVouch(voter2, setup.eligibilityModule, candidate2, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate2, setup.defaultRoleHat, false, false, "Candidate2 after vouch revocation"
        );
    }

    function testVouchingErrors() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";
        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://member-role-image";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Vouch Error Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        uint256 memberRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);

        address candidate = address(0x300);

        // Set up users for vouching (need join times set)
        _setupUserForVouching(eligibilityModuleAddr, exec, voter1);
        _setupUserForVouching(eligibilityModuleAddr, exec, voter2);
        _setupUserForVouching(eligibilityModuleAddr, exec, candidate);

        // Test 1: Vouching without configuration should fail
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.VouchingNotEnabled.selector));
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);

        // Configure vouching
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).configureVouching(defaultRoleHat, 2, memberRoleHat, false);

        // Set default eligibility to false to test vouching behavior properly
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(defaultRoleHat, false, false);

        // Test 2: Vouching without proper hat should fail
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotAuthorizedToVouch.selector));
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);

        // Give voter1 the member hat
        vm.prank(exec);
        IHats(SEPOLIA_HATS).mintHat(memberRoleHat, voter1);

        // Test 3: Vouching should work now
        vm.prank(voter1);
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);

        // Test 4: Double vouching should fail
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.AlreadyVouched.selector));
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);

        // Test 5: Revoking non-existent vouch should fail
        vm.prank(voter2);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.HasNotVouched.selector));
        EligibilityModule(eligibilityModuleAddr).revokeVouch(candidate, defaultRoleHat);

        // Test 6: Only super admin can configure vouching
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(eligibilityModuleAddr).configureVouching(defaultRoleHat, 3, memberRoleHat, true);
    }

    function testVouchingRevocation() public {
        TestOrgSetup memory setup = _createTestOrg("Vouch Revocation Test DAO");
        address candidate = address(0x400);

        // Set up users for vouching (need join times set)
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Configure vouching for DEFAULT hat
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Mint MEMBER hats to vouchers
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter2);

        // Get both vouches
        _vouchFor(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        _vouchFor(voter2, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Verify candidate is approved
        _assertVouchStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, 2, true, "After 2 vouches");
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, true, true, "After 2 vouches"
        );

        // Revoke one vouch
        _revokeVouch(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Verify counts and approval status
        _assertVouchStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, 1, false, "After revocation");
        assertFalse(
            EligibilityModule(setup.eligibilityModule).hasVouched(setup.defaultRoleHat, candidate, voter1),
            "voter1 should not have vouched"
        );
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasVouched(setup.defaultRoleHat, candidate, voter2),
            "voter2 should still have vouched"
        );
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, false, false, "After revocation"
        );

        // Add the vouch back
        _vouchFor(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Verify candidate is eligible again
        _assertVouchStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, 2, true, "After re-vouching");
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, true, true, "After re-vouching"
        );
    }

    function testClearWearerVouches_invalidatesOnlyTargetWearer() public {
        TestOrgSetup memory setup = _createTestOrg("Clear Wearer Vouches Test DAO");
        address loser = address(0x5C0E1);
        address bystander = address(0x5C0E2);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, loser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, bystander);

        // Vouching: quorum=1, combineWithHierarchy=false (so vouch alone gates eligibility)
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, false, true
        );
        _mintHat(setup.exec, setup.memberRoleHat, voter1);

        // voter1 vouches for both candidates → both eligible.
        _vouchFor(voter1, setup.eligibilityModule, loser, setup.defaultRoleHat);
        _vouchFor(voter1, setup.eligibilityModule, bystander, setup.defaultRoleHat);
        _assertVouchStatus(setup.eligibilityModule, loser, setup.defaultRoleHat, 1, true, "loser vouched");
        _assertVouchStatus(setup.eligibilityModule, bystander, setup.defaultRoleHat, 1, true, "bystander vouched");
        _assertEligibilityStatus(setup.eligibilityModule, loser, setup.defaultRoleHat, true, true, "loser pre-clear");

        // Surgical clear for loser only.
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).clearWearerVouches(loser, setup.defaultRoleHat);

        // Loser: effective vouch count is 0 → ineligible.
        _assertEligibilityStatus(setup.eligibilityModule, loser, setup.defaultRoleHat, false, false, "loser post-clear");

        // Bystander: untouched, still vouched, still eligible.
        _assertVouchStatus(setup.eligibilityModule, bystander, setup.defaultRoleHat, 1, true, "bystander preserved");
        _assertEligibilityStatus(
            setup.eligibilityModule, bystander, setup.defaultRoleHat, true, true, "bystander still eligible"
        );

        // Org-wide vouching is still ENABLED — new vouches still work.
        _setupUserForVouching(setup.eligibilityModule, setup.exec, address(0x5C0E3));
        _vouchFor(voter1, setup.eligibilityModule, address(0x5C0E3), setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, address(0x5C0E3), setup.defaultRoleHat, true, true, "vouching still works"
        );

        // The loser CAN be re-vouched in by a DIFFERENT voucher (or after the
        // org bumps the vouch config epoch). Bonus check: voter2 (different
        // voucher than voter1 who already vouched in the prior epoch) can
        // vouch the loser back to eligible. Demonstrates the clear isn't a
        // permanent ban.
        _mintHat(setup.exec, setup.memberRoleHat, voter2);
        _vouchFor(voter2, setup.eligibilityModule, loser, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, loser, setup.defaultRoleHat, true, true, "loser re-vouchable by different voucher"
        );
    }

    function testClearWearerVouches_onlySuperAdmin() public {
        TestOrgSetup memory setup = _createTestOrg("ClearWearerVouches Auth Test");
        vm.prank(address(0xBEEF));
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).clearWearerVouches(address(0x123), setup.defaultRoleHat);
    }

    function testClearWearerVouches_zeroAddressReverts() public {
        TestOrgSetup memory setup = _createTestOrg("ClearWearerVouches Zero Test");
        vm.prank(setup.exec);
        vm.expectRevert(EligibilityModule.ZeroAddress.selector);
        EligibilityModule(setup.eligibilityModule).clearWearerVouches(address(0), setup.defaultRoleHat);
    }

    function testClearWearerVouches_emitsEvent() public {
        TestOrgSetup memory setup = _createTestOrg("ClearWearerVouches Event Test");
        address target = address(0xC1EA1);
        vm.prank(setup.exec);
        vm.expectEmit(true, true, true, false);
        emit EligibilityModule.WearerVouchesCleared(target, setup.defaultRoleHat, setup.exec);
        EligibilityModule(setup.eligibilityModule).clearWearerVouches(target, setup.defaultRoleHat);
    }

    function testVouchingEvents() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";
        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://member-role-image";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Vouch Events Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        uint256 memberRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);

        address candidate = address(0x500);

        // Set up users for vouching (need join times set)
        _setupUserForVouching(eligibilityModuleAddr, exec, voter1);
        _setupUserForVouching(eligibilityModuleAddr, exec, candidate);

        // Test VouchConfigSet event
        vm.expectEmit(true, false, false, true);
        emit VouchConfigSet(defaultRoleHat, 2, memberRoleHat, true, false);

        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).configureVouching(defaultRoleHat, 2, memberRoleHat, false);

        // Set default eligibility to false to test vouching behavior properly
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(defaultRoleHat, false, false);

        // Mint MEMBER hat to voter1
        vm.prank(exec);
        IHats(SEPOLIA_HATS).mintHat(memberRoleHat, voter1);

        // Test Vouched event
        vm.expectEmit(true, true, true, true);
        emit Vouched(voter1, candidate, defaultRoleHat, 1);

        vm.prank(voter1);
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);

        // Test VouchRevoked event
        vm.expectEmit(true, true, true, true);
        emit VouchRevoked(voter1, candidate, defaultRoleHat, 0);

        vm.prank(voter1);
        EligibilityModule(eligibilityModuleAddr).revokeVouch(candidate, defaultRoleHat);
    }

    function testVouchingWithClaim() public {
        TestOrgSetup memory setup = _createTestOrg("Claim Test DAO");
        address candidate = address(0x300);

        // Set up users for vouching
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Configure vouching for DEFAULT hat: require 2 vouches
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Mint MEMBER hats to vouchers
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter2);

        // Vouch twice to reach quorum
        _vouchFor(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        _vouchFor(voter2, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Verify eligible but not wearing hat yet
        _assertEligibilityStatus(setup.eligibilityModule, candidate, setup.defaultRoleHat, true, true, "After vouching");
        _assertWearingHat(candidate, setup.defaultRoleHat, false, "Before claiming");

        // Test HatClaimed event
        vm.expectEmit(true, true, false, false);
        emit HatClaimed(candidate, setup.defaultRoleHat);

        // Claim the hat
        vm.prank(candidate);
        EligibilityModule(setup.eligibilityModule).claimVouchedHat(setup.defaultRoleHat);

        // Verify now wearing the hat
        _assertWearingHat(candidate, setup.defaultRoleHat, true, "After claiming");
    }

    function testClaimWithoutVouch() public {
        TestOrgSetup memory setup = _createTestOrg("Claim Error Test DAO");
        address candidate = address(0x301);

        // Set up user
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Configure vouching for DEFAULT hat: require 2 vouches
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Try to claim without being vouched - should fail
        vm.prank(candidate);
        vm.expectRevert("Not eligible to claim hat");
        EligibilityModule(setup.eligibilityModule).claimVouchedHat(setup.defaultRoleHat);
    }

    function testRoleConfigValidation() public {
        vm.startPrank(orgOwner);

        // Test 1: Empty roles array should revert
        RoleConfigStructs.RoleConfig[] memory emptyRoles = new RoleConfigStructs.RoleConfig[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Invalid Org",
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
            hybridClasses: new IHybridVotingInit.ClassConfig[](0),
            ddInitialTargets: new address[](0),
            roles: emptyRoles,
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);

        // Test 2: Invalid voucher role index
        RoleConfigStructs.RoleConfig[] memory invalidVoucherRoles = new RoleConfigStructs.RoleConfig[](2);
        invalidVoucherRoles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "ipfs://member",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true,
                quorum: 1,
                voucherRoleIndex: 5, // Invalid: out of bounds
                combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: false, additionalWearers: new address[](0)
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });
        invalidVoucherRoles[1] = RoleConfigStructs.RoleConfig({
            name: "ADMIN",
            image: "ipfs://admin",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: new address[](0)
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        params.roles = invalidVoucherRoles;
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);

        // Test 3: Zero quorum with vouching enabled
        RoleConfigStructs.RoleConfig[] memory zeroQuorumRoles = new RoleConfigStructs.RoleConfig[](1);
        zeroQuorumRoles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "ipfs://member",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true,
                quorum: 0, // Invalid: must be > 0 if enabled
                voucherRoleIndex: 0,
                combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: new address[](0)
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        params.roles = zeroQuorumRoles;
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);

        // Test 4: Self-referential hierarchy
        RoleConfigStructs.RoleConfig[] memory selfRefRoles = new RoleConfigStructs.RoleConfig[](1);
        selfRefRoles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "ipfs://member",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 0}), // Self-reference
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: new address[](0)
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        params.roles = selfRefRoles;
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);

        vm.stopPrank();
    }

    //     function skip_testComplexHierarchy() public {
    //         vm.startPrank(orgOwner);
    //
    //         // Test non-linear hierarchy: ELIGIBILITY_ADMIN -> ADMIN -> [MANAGER, COORDINATOR] -> MEMBER
    //         // This creates a tree structure rather than linear chain
    //         RoleConfigStructs.RoleConfig[] memory complexRoles = new RoleConfigStructs.RoleConfig[](4);
    //
    //         // MEMBER (index 0) - child of MANAGER (index 1)
    //         complexRoles[0] = RoleConfigStructs.RoleConfig({
    //             name: "MEMBER",
    //             image: "ipfs://member",
    //             canVote: true,
    //             vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false}),
    //             defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
    //             hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 1}), // Parent is MANAGER
    //             distribution: RoleConfigStructs.RoleDistributionConfig({mintToDeployer: false, mintToExecutor: true, additionalWearers: new address[](0)})
    //         });
    //
    //         // MANAGER (index 1) - child of ADMIN (index 3)
    //         complexRoles[1] = RoleConfigStructs.RoleConfig({
    //             name: "MANAGER",
    //             image: "ipfs://manager",
    //             canVote: true,
    //             vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false}),
    //             defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
    //             hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 3}), // Parent is ADMIN
    //             distribution: RoleConfigStructs.RoleDistributionConfig({mintToDeployer: false, mintToExecutor: true, additionalWearers: new address[](0)})
    //         });
    //
    //         // COORDINATOR (index 2) - also child of ADMIN (index 3), sibling to MANAGER
    //         complexRoles[2] = RoleConfigStructs.RoleConfig({
    //             name: "COORDINATOR",
    //             image: "ipfs://coordinator",
    //             canVote: true,
    //             vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false}),
    //             defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
    //             hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 3}), // Parent is ADMIN
    //             distribution: RoleConfigStructs.RoleDistributionConfig({mintToDeployer: false, mintToExecutor: true, additionalWearers: new address[](0)})
    //         });
    //
    //         // ADMIN (index 3) - top level
    //         complexRoles[3] = RoleConfigStructs.RoleConfig({
    //             name: "ADMIN",
    //             image: "ipfs://admin",
    //             canVote: true,
    //             vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false}),
    //             defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
    //             hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}), // Top level
    //             distribution: RoleConfigStructs.RoleDistributionConfig({mintToDeployer: true, mintToExecutor: false, additionalWearers: new address[](0)})
    //         });
    //
    //         IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
    //         address[] memory ddTargets = new address[](0);
    //
    //         OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
    //             orgId: ORG_ID,
    //             orgName: "Complex Hierarchy DAO",
    //             registryAddr: accountRegProxy,
    //             deployerAddress: orgOwner,
    //             deployerUsername: "",
    //             autoUpgrade: true,
    //             hybridThresholdPct: 50,
    //             ddThresholdPct: 50,
    //             hybridClasses: classes,
    //             ddInitialTargets: ddTargets,
    //             roles: complexRoles,
    //             roleAssignments: _buildDefaultRoleAssignments()
    //         });
    //
    //         OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
    //
    //         // Verify all hats were created
    //         uint256[] memory roleHats = orgRegistry.getRoleHats(ORG_ID);
    //         assertEq(roleHats.length, 4, "Should have 4 role hats");
    //
    //         // Verify hierarchy: check that MEMBER's admin is MANAGER, etc.
    //         uint256 memberHat = roleHats[0];
    //         uint256 managerHat = roleHats[1];
    //         uint256 coordinatorHat = roleHats[2];
    //         uint256 adminHat = roleHats[3];
    //
    //         // Admin should be wearer of admin hat
    //         assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(orgOwner, adminHat), "Deployer should have ADMIN hat");
    //
    //         vm.stopPrank();
    //     }

    //     function skip_testMultipleInitialWearers() public {
    //         vm.startPrank(orgOwner);
    //
    //         address founder1 = address(0x1111);
    //         address founder2 = address(0x2222);
    //         address[] memory additionalWearers = new address[](2);
    //         additionalWearers[0] = founder1;
    //         additionalWearers[1] = founder2;
    //
    //         RoleConfigStructs.RoleConfig[] memory multiWearerRoles = new RoleConfigStructs.RoleConfig[](1);
    //         multiWearerRoles[0] = RoleConfigStructs.RoleConfig({
    //             name: "FOUNDER",
    //             image: "ipfs://founder",
    //             canVote: true,
    //             vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false}),
    //             defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true}),
    //             hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
    //             distribution: RoleConfigStructs.RoleDistributionConfig({
    //                 mintToDeployer: true,
    //                 mintToExecutor: false,
    //                 additionalWearers: additionalWearers
    //             })
    //         });
    //
    //         IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(100, 0, false, 0);
    //         address[] memory ddTargets = new address[](0);
    //
    //         OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
    //             orgId: ORG_ID,
    //             orgName: "Multi-Founder DAO",
    //             registryAddr: accountRegProxy,
    //             deployerAddress: orgOwner,
    //             deployerUsername: "",
    //             autoUpgrade: true,
    //             hybridThresholdPct: 50,
    //             ddThresholdPct: 50,
    //             hybridClasses: classes,
    //             ddInitialTargets: ddTargets,
    //             roles: multiWearerRoles,
    //             roleAssignments: _buildDefaultRoleAssignments()
    //         });
    //
    //         OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
    //
    //         // Verify all three founders have the hat
    //         uint256[] memory roleHats = orgRegistry.getRoleHats(ORG_ID);
    //         uint256 founderHat = roleHats[0];
    //
    //         assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(orgOwner, founderHat), "Deployer should have FOUNDER hat");
    //         assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(founder1, founderHat), "Founder1 should have FOUNDER hat");
    //         assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(founder2, founderHat), "Founder2 should have FOUNDER hat");
    //
    //         vm.stopPrank();
    //     }

    function testVouchingDisabling() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";
        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://member-role-image";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Vouch Disable Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        uint256 memberRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);

        // Enable vouching
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).configureVouching(defaultRoleHat, 2, memberRoleHat, false);

        // Set default eligibility to false initially to test vouching behavior properly
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(defaultRoleHat, false, false);

        // Verify vouching is enabled
        EligibilityModule.VouchConfig memory config =
            EligibilityModule(eligibilityModuleAddr).getVouchConfig(defaultRoleHat);
        assertTrue(
            EligibilityModule(eligibilityModuleAddr).isVouchingEnabled(defaultRoleHat), "Vouching should be enabled"
        );

        // Disable vouching by setting quorum to 0
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).configureVouching(defaultRoleHat, 0, memberRoleHat, false);

        // Verify vouching is disabled
        config = EligibilityModule(eligibilityModuleAddr).getVouchConfig(defaultRoleHat);
        assertFalse(
            EligibilityModule(eligibilityModuleAddr).isVouchingEnabled(defaultRoleHat), "Vouching should be disabled"
        );
        assertEq(config.quorum, 0, "Quorum should be 0");

        // Set default eligibility to test hierarchy-only mode
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(defaultRoleHat, true, true);

        address candidate = address(0x600);

        // Should now work via hierarchy (default eligibility)
        assertTrue(IHats(SEPOLIA_HATS).isEligible(candidate, defaultRoleHat), "Should be eligible via hierarchy");
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(candidate, defaultRoleHat), "Should have good standing via hierarchy"
        );

        // Vouching should fail when disabled
        vm.prank(exec);
        IHats(SEPOLIA_HATS).mintHat(memberRoleHat, voter1);

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.VouchingNotEnabled.selector));
        EligibilityModule(eligibilityModuleAddr).vouchFor(candidate, defaultRoleHat);
    }

    /*══════════════════════════════════════════════════════════════════════
                    MAX DAILY VOUCHES CONFIGURABLE LIMIT
    ══════════════════════════════════════════════════════════════════════*/

    function testMaxDailyVouches_DefaultIs20() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        assertEq(EligibilityModule(setup.eligibilityModule).getMaxDailyVouches(), 20, "Default should be 20");
    }

    function testMaxDailyVouches_SetBySuperAdmin() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        vm.prank(setup.exec);
        em.setMaxDailyVouches(50);

        assertEq(em.getMaxDailyVouches(), 50, "Should be updated to 50");
    }

    function testMaxDailyVouches_ZeroReverts() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        vm.prank(setup.exec);
        vm.expectRevert(EligibilityModule.InvalidMaxDailyVouches.selector);
        em.setMaxDailyVouches(0);
    }

    function testMaxDailyVouches_NonAdminReverts() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        vm.prank(address(0xDEAD));
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        em.setMaxDailyVouches(10);
    }

    function testMaxDailyVouches_EnforcedDuringVouching() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        // Set limit to 2 for easy testing
        vm.prank(setup.exec);
        em.setMaxDailyVouches(2);

        // Set up voucher
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter1);

        // Configure vouching: require 1 vouch from MEMBER hat
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, false, true
        );

        // Vouch 1 — should succeed
        address candidate1 = address(0x301);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate1);
        vm.prank(voter1);
        em.vouchFor(candidate1, setup.defaultRoleHat);

        // Vouch 2 — should succeed (at limit)
        address candidate2 = address(0x302);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate2);
        vm.prank(voter1);
        em.vouchFor(candidate2, setup.defaultRoleHat);

        // Vouch 3 — should revert (over limit of 2)
        address candidate3 = address(0x303);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate3);
        vm.prank(voter1);
        vm.expectRevert(EligibilityModule.VouchingRateLimitExceeded.selector);
        em.vouchFor(candidate3, setup.defaultRoleHat);

        // canUserVouch should return false
        assertFalse(em.canUserVouch(voter1), "canUserVouch should return false at limit");
    }

    function testMaxDailyVouches_CanIncreaseToUnblock() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        // Set limit to 1
        vm.prank(setup.exec);
        em.setMaxDailyVouches(1);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, false, true
        );

        // Use up the 1 vouch
        address candidate1 = address(0x401);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate1);
        vm.prank(voter1);
        em.vouchFor(candidate1, setup.defaultRoleHat);

        // Blocked
        assertFalse(em.canUserVouch(voter1), "Should be blocked");

        // Admin increases limit
        vm.prank(setup.exec);
        em.setMaxDailyVouches(5);

        // Now unblocked
        assertTrue(em.canUserVouch(voter1), "Should be unblocked after limit increase");

        // Can vouch again
        address candidate2 = address(0x402);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate2);
        vm.prank(voter1);
        em.vouchFor(candidate2, setup.defaultRoleHat);
    }

    function testMaxDailyVouches_ResetsNextDay() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        // Set limit to 1
        vm.prank(setup.exec);
        em.setMaxDailyVouches(1);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, false, true
        );

        // Use up today's vouch
        address candidate1 = address(0x501);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate1);
        vm.prank(voter1);
        em.vouchFor(candidate1, setup.defaultRoleHat);

        assertFalse(em.canUserVouch(voter1), "Should be blocked today");

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        assertTrue(em.canUserVouch(voter1), "Should be unblocked next day");
    }

    function testMaxDailyVouches_EmitsEvent() public {
        TestOrgSetup memory setup = _createTestOrg("VouchLimit DAO");
        EligibilityModule em = EligibilityModule(setup.eligibilityModule);

        vm.prank(setup.exec);
        vm.expectEmit(false, false, false, true);
        emit EligibilityModule.MaxDailyVouchesSet(42);
        em.setMaxDailyVouches(42);
    }

    function testVouchEpochInvalidatesStaleDataAfterReset() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";
        string[] memory images = new string[](3);
        images[0] = "ipfs://default";
        images[1] = "ipfs://executive";
        images[2] = "ipfs://member";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Epoch Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address exec = result.executor;
        vm.stopPrank();

        address eligAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);
        EligibilityModule elig = EligibilityModule(eligAddr);
        uint256 defaultHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 memberHat = orgRegistry.getRoleHat(ORG_ID, 2);

        // 1. Configure vouching with quorum=2
        vm.prank(exec);
        elig.configureVouching(defaultHat, 2, memberHat, false);

        // Give voter1 and voter2 membership hats so they can vouch
        vm.prank(exec);
        IHats(SEPOLIA_HATS).mintHat(memberHat, voter1);
        vm.prank(exec);
        IHats(SEPOLIA_HATS).mintHat(memberHat, voter2);

        address candidate = address(0x700);

        // 2. voter1 vouches for candidate (epoch 1)
        vm.prank(voter1);
        elig.vouchFor(candidate, defaultHat);
        assertEq(elig.currentVouchCount(defaultHat, candidate), 1);

        // 3. Reset vouching, then reconfigure with quorum=1
        vm.prank(exec);
        elig.resetVouches(defaultHat);
        vm.prank(exec);
        elig.configureVouching(defaultHat, 1, memberHat, false);

        // 4. Stale vouch count should be 0 (epoch changed)
        assertEq(elig.currentVouchCount(defaultHat, candidate), 0, "Stale vouch count should be 0 after epoch change");

        // 5. voter1 should be able to vouch again (stale AlreadyVouched record is ignored)
        vm.prank(voter1);
        elig.vouchFor(candidate, defaultHat);
        assertEq(elig.currentVouchCount(defaultHat, candidate), 1, "Fresh vouch should count");

        // 6. voter1 should NOT be able to vouch again in same epoch
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.AlreadyVouched.selector));
        elig.vouchFor(candidate, defaultHat);
    }

    function testCanUserVouchMatchesEnforcement() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "MEMBER";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://member";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "canUserVouch Test",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params);
        vm.stopPrank();

        address eligAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);
        EligibilityModule elig = EligibilityModule(eligAddr);

        // User with joinTime=0 should be allowed to vouch (matches _checkVouchingRateLimit)
        address newUser = address(0x800);
        assertTrue(elig.canUserVouch(newUser), "User with joinTime=0 should be able to vouch");
    }

    function testSuperAdminFullControl() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "MEMBER";
        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://member-role-image";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "SuperAdmin Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        uint256 memberRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);

        // Verify executor is the super admin
        assertEq(EligibilityModule(eligibilityModuleAddr).superAdmin(), exec, "Executor should be the super admin");

        // Test that super admin can control ANY hat without needing admin permissions
        address testUser = address(0x700);

        // Super admin can control DEFAULT hat (already has admin permissions)
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(testUser, defaultRoleHat, true, true);

        // Super admin can control EXECUTIVE hat (even though no admin permissions set)
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(testUser, executiveRoleHat, true, true);

        // Super admin can control MEMBER hat (even though no admin permissions set)
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(testUser, memberRoleHat, true, true);

        // Verify all settings took effect - check via Hats contract
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(testUser, defaultRoleHat), "Should be eligible for DEFAULT via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(testUser, defaultRoleHat),
            "Should have good standing for DEFAULT via Hats contract"
        );

        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(testUser, executiveRoleHat),
            "Should be eligible for EXECUTIVE via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(testUser, executiveRoleHat),
            "Should have good standing for EXECUTIVE via Hats contract"
        );

        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(testUser, memberRoleHat), "Should be eligible for MEMBER via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(testUser, memberRoleHat),
            "Should have good standing for MEMBER via Hats contract"
        );

        // Test that super admin can configure vouching
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).configureVouching(memberRoleHat, 3, defaultRoleHat, true);

        // Test that super admin can reset vouches
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).resetVouches(memberRoleHat);

        // Test that users can be eligible for hats when properly set up
        vm.prank(exec);
        bool mintSuccess = IHats(SEPOLIA_HATS).mintHat(defaultRoleHat, testUser);
        assertTrue(mintSuccess, "Should be able to mint hat to eligible user");

        // Verify the user is wearing the hat via Hats contract
        assertTrue(IHats(SEPOLIA_HATS).isWearerOfHat(testUser, defaultRoleHat), "User should be wearing the hat");

        // Test that eligibility is checked via Hats contract when minting
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(testUser, defaultRoleHat),
            "User should be eligible according to Hats contract"
        );

        // Test admin relationships via Hats contract
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(exec, defaultRoleHat),
            "Executor should be admin of DEFAULT hat via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(exec, executiveRoleHat),
            "Executor should be admin of EXECUTIVE hat via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isAdminOfHat(exec, memberRoleHat),
            "Executor should be admin of MEMBER hat via Hats contract"
        );

        // Test that super admin can transfer super admin
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).transferSuperAdmin(voter1);

        // Verify the transfer worked
        assertEq(EligibilityModule(eligibilityModuleAddr).superAdmin(), voter1, "Super admin should be transferred");

        // Test that the new super admin now has full control
        vm.prank(voter1);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(testUser, defaultRoleHat, false, false);

        // Check via Hats contract
        assertFalse(
            IHats(SEPOLIA_HATS).isEligible(testUser, defaultRoleHat),
            "Should not be eligible after new super admin revokes"
        );
        assertFalse(
            IHats(SEPOLIA_HATS).isInGoodStanding(testUser, defaultRoleHat),
            "Should not have good standing after new super admin revokes"
        );

        // Also verify that the user is no longer wearing the hat
        assertFalse(
            IHats(SEPOLIA_HATS).isWearerOfHat(testUser, defaultRoleHat),
            "Should not be wearing hat after eligibility revoked"
        );
    }

    function testUnrestrictedHat() public {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](3);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        names[2] = "OPEN"; // This will be our unrestricted hat
        string[] memory images = new string[](3);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        images[2] = "ipfs://open-role-image";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: ORG_ID,
            orgName: "Unrestricted Hat Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        address hybrid = result.hybridVoting;
        address exec = result.executor;
        address qj = result.quickJoin;
        address token = result.participationToken;
        address tm = result.taskManager;
        address hub = result.educationHub;

        vm.stopPrank();

        // Get the eligibility module address
        address eligibilityModuleAddr = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID);

        // Get role hat IDs
        uint256 defaultRoleHat = orgRegistry.getRoleHat(ORG_ID, 0);
        uint256 executiveRoleHat = orgRegistry.getRoleHat(ORG_ID, 1);
        uint256 openRoleHat = orgRegistry.getRoleHat(ORG_ID, 2);

        // The open hat should already have default eligibility set to true, true
        // by the deployer, but let's verify and ensure it's unrestricted:

        // 1. Make sure vouching is NOT enabled (default state)
        EligibilityModule.VouchConfig memory config =
            EligibilityModule(eligibilityModuleAddr).getVouchConfig(openRoleHat);
        assertFalse(
            EligibilityModule(eligibilityModuleAddr).isVouchingEnabled(openRoleHat),
            "Vouching should be disabled by default"
        );

        // 2. Make sure default eligibility is true (should be set by deployer)
        address randomUser1 = address(0x800);
        address randomUser2 = address(0x801);
        address randomUser3 = address(0x802);

        // Check that anyone can be eligible for the open hat via Hats contract
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(randomUser1, openRoleHat),
            "Random user 1 should be eligible for open hat via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser1, openRoleHat),
            "Random user 1 should have good standing for open hat via Hats contract"
        );

        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(randomUser2, openRoleHat),
            "Random user 2 should be eligible for open hat via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser2, openRoleHat),
            "Random user 2 should have good standing for open hat via Hats contract"
        );

        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(randomUser3, openRoleHat),
            "Random user 3 should be eligible for open hat via Hats contract"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser3, openRoleHat),
            "Random user 3 should have good standing for open hat via Hats contract"
        );

        // 3. Test that the executor can mint the open hat to anyone
        vm.prank(exec);
        bool success1 = IHats(SEPOLIA_HATS).mintHat(openRoleHat, randomUser1);
        assertTrue(success1, "Should successfully mint open hat to random user 1");

        vm.prank(exec);
        bool success2 = IHats(SEPOLIA_HATS).mintHat(openRoleHat, randomUser2);
        assertTrue(success2, "Should successfully mint open hat to random user 2");

        vm.prank(exec);
        bool success3 = IHats(SEPOLIA_HATS).mintHat(openRoleHat, randomUser3);
        assertTrue(success3, "Should successfully mint open hat to random user 3");

        // Verify all users are wearing the open hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(randomUser1, openRoleHat), "Random user 1 should be wearing open hat"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(randomUser2, openRoleHat), "Random user 2 should be wearing open hat"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(randomUser3, openRoleHat), "Random user 3 should be wearing open hat"
        );

        // 4. Test that the super admin can still control the open hat if needed
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(randomUser1, openRoleHat, false, false);

        // randomUser1 should now be ineligible
        assertFalse(
            IHats(SEPOLIA_HATS).isEligible(randomUser1, openRoleHat),
            "Random user 1 should now be ineligible after specific rule"
        );
        assertFalse(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser1, openRoleHat),
            "Random user 1 should have bad standing after specific rule"
        );

        // But randomUser2 and randomUser3 should still be eligible (using default rules)
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(randomUser2, openRoleHat),
            "Random user 2 should still be eligible via default rules"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser2, openRoleHat),
            "Random user 2 should still have good standing via default rules"
        );

        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(randomUser3, openRoleHat),
            "Random user 3 should still be eligible via default rules"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser3, openRoleHat),
            "Random user 3 should still have good standing via default rules"
        );

        // 5. Test that the super admin can make it even more open by removing the specific restriction
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setWearerEligibility(randomUser1, openRoleHat, true, true);

        // Now randomUser1 should be eligible again
        assertTrue(IHats(SEPOLIA_HATS).isEligible(randomUser1, openRoleHat), "Random user 1 should be eligible again");
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser1, openRoleHat),
            "Random user 1 should have good standing again"
        );

        // 6. Demonstrate that we can create a hat that's completely unrestricted
        // by ensuring default eligibility is true and no specific rules or vouching
        vm.prank(exec);
        EligibilityModule(eligibilityModuleAddr).setDefaultEligibility(openRoleHat, true, true);

        // Any address should be eligible
        address veryRandomUser = address(0x999);
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(veryRandomUser, openRoleHat),
            "Any random user should be eligible for unrestricted hat"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(veryRandomUser, openRoleHat),
            "Any random user should have good standing for unrestricted hat"
        );
    }

    function testCreateHatWithEligibilityAndBatchMinting() public {
        // Create a test organization with marketing executive
        TestOrgSetup memory setup = _createTestOrg("Marketing DAO");

        // Marketing executive is voter1
        address marketingExecutive = voter1;
        address marketingMember1 = voter2;
        address marketingMember2 = address(0x5);
        address marketingMember3 = address(0x6);

        // Set up users for vouching
        _setupUserForVouching(setup.eligibilityModule, setup.exec, marketingExecutive);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, marketingMember1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, marketingMember2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, marketingMember3);

        // First, mint the executive role hat to the marketing executive
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, marketingExecutive);

        // Verify the marketing executive is wearing the executive role hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingExecutive, setup.executiveRoleHat),
            "Marketing executive should wear executive role hat"
        );

        // Marketing executive creates a new marketing hat for their team
        // (Executive role wearers are admins of the default role, so they can create child hats under it)
        vm.prank(setup.exec);
        uint256 marketingHatId = EligibilityModule(setup.eligibilityModule)
            .createHatWithEligibility(
                EligibilityModule.CreateHatParams({
                parentHatId: setup.defaultRoleHat,
                details: "Marketing Team",
                maxSupply: 10,
                _mutable: true,
                imageURI: "ipfs://marketing-hat-image",
                defaultEligible: true,
                defaultStanding: true,
                mintToAddresses: new address[](0),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
            );

        // Verify the marketing hat was created
        assertTrue(marketingHatId > 0, "Marketing hat should be created");

        // Test that the marketing hat has the correct default eligibility
        assertTrue(
            IHats(SEPOLIA_HATS).isEligible(marketingMember1, marketingHatId),
            "Marketing members should be eligible by default"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(marketingMember1, marketingHatId),
            "Marketing members should have good standing by default"
        );

        // Test single eligibility setting and minting separately
        address[] memory singleMember = new address[](1);
        singleMember[0] = marketingMember1;
        bool[] memory singleEligible = new bool[](1);
        singleEligible[0] = true;
        bool[] memory singleStanding = new bool[](1);
        singleStanding[0] = true;

        // First set eligibility
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .batchSetWearerEligibility(marketingHatId, singleMember, singleEligible, singleStanding);

        // Then mint the hat directly (executor mints since marketing executive no longer has admin rights)
        vm.prank(setup.exec);
        bool success = IHats(SEPOLIA_HATS).mintHat(marketingHatId, marketingMember1);
        assertTrue(success, "Hat minting should succeed");

        // Verify member1 is wearing the marketing hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember1, marketingHatId),
            "Marketing member 1 should be wearing marketing hat"
        );

        // Test batch minting multiple members with different eligibility settings
        address[] memory multipleMembers = new address[](2);
        multipleMembers[0] = marketingMember2;
        multipleMembers[1] = marketingMember3;

        bool[] memory multipleEligible = new bool[](2);
        multipleEligible[0] = true; // Member2 is eligible
        multipleEligible[1] = false; // Member3 is not eligible (maybe new hire)

        bool[] memory multipleStanding = new bool[](2);
        multipleStanding[0] = true; // Member2 has good standing
        multipleStanding[1] = false; // Member3 has poor standing

        // First set eligibility for multiple members
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .batchSetWearerEligibility(marketingHatId, multipleMembers, multipleEligible, multipleStanding);

        // Then mint hats individually (only for eligible members)
        vm.prank(setup.exec);
        bool success2 = IHats(SEPOLIA_HATS).mintHat(marketingHatId, marketingMember2);
        assertTrue(success2, "Hat minting should succeed for eligible member");

        // Try to mint for ineligible member3 - should fail
        vm.prank(setup.exec);
        vm.expectRevert(); // Should revert because member3 is not eligible
        IHats(SEPOLIA_HATS).mintHat(marketingHatId, marketingMember3);

        // Verify member2 is wearing the marketing hat (eligible and good standing)
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember2, marketingHatId),
            "Marketing member 2 should be wearing marketing hat"
        );

        // Verify member3 is NOT wearing the marketing hat (ineligible)
        assertFalse(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember3, marketingHatId),
            "Marketing member 3 should NOT be wearing marketing hat (ineligible)"
        );

        // Test creating another hat with initial batch minting
        address[] memory initialMembers = new address[](2);
        initialMembers[0] = marketingMember1;
        initialMembers[1] = marketingMember2;

        bool[] memory initialEligible = new bool[](2);
        initialEligible[0] = true;
        initialEligible[1] = true;

        bool[] memory initialStanding = new bool[](2);
        initialStanding[0] = true;
        initialStanding[1] = true;

        vm.prank(setup.exec);
        uint256 campaignHatId = EligibilityModule(setup.eligibilityModule)
            .createHatWithEligibility(
                EligibilityModule.CreateHatParams({
                parentHatId: setup.defaultRoleHat,
                details: "Campaign Team",
                maxSupply: 5,
                _mutable: true,
                imageURI: "ipfs://campaign-hat-image",
                defaultEligible: false,
                defaultStanding: true,
                mintToAddresses: initialMembers,
                wearerEligibleFlags: initialEligible,
                wearerStandingFlags: initialStanding
            })
            );

        // Verify the campaign hat was created
        assertTrue(campaignHatId > 0, "Campaign hat should be created");

        // Verify both initial members are wearing the campaign hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember1, campaignHatId),
            "Marketing member 1 should be wearing campaign hat"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember2, campaignHatId),
            "Marketing member 2 should be wearing campaign hat"
        );

        // Verify member3 is NOT eligible for the campaign hat (default eligibility is false)
        (bool eligible3, bool standing3) =
            EligibilityModule(setup.eligibilityModule).getWearerStatus(marketingMember3, campaignHatId);
        assertFalse(eligible3, "Member 3 should not be eligible for campaign hat by default");
        assertTrue(standing3, "Member 3 should have good standing by default");

        // Test that only the super admin can create hats — even the marketing executive fails now
        vm.prank(marketingExecutive);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(setup.eligibilityModule)
            .createHatWithEligibility(
                EligibilityModule.CreateHatParams({
                parentHatId: setup.defaultRoleHat,
                details: "Unauthorized Hat",
                maxSupply: 1,
                _mutable: true,
                imageURI: "",
                defaultEligible: true,
                defaultStanding: true,
                mintToAddresses: new address[](0),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
            );

        // Test that the executor (super admin) can manage eligibility of created hats
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(marketingMember3, campaignHatId, true, true);

        // Verify member3 is now eligible for the campaign hat
        (bool eligible3Updated, bool standing3Updated) =
            EligibilityModule(setup.eligibilityModule).getWearerStatus(marketingMember3, campaignHatId);
        assertTrue(eligible3Updated, "Member 3 should now be eligible for campaign hat");
        assertTrue(standing3Updated, "Member 3 should have good standing for campaign hat");

        // Now marketing executive can set eligibility and mint the campaign hat to member3
        address[] memory member3Array = new address[](1);
        member3Array[0] = marketingMember3;
        bool[] memory member3Eligible = new bool[](1);
        member3Eligible[0] = true;
        bool[] memory member3Standing = new bool[](1);
        member3Standing[0] = true;

        // Set eligibility first
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .batchSetWearerEligibility(campaignHatId, member3Array, member3Eligible, member3Standing);

        // Then mint the hat
        vm.prank(marketingExecutive);
        bool success3 = IHats(SEPOLIA_HATS).mintHat(campaignHatId, marketingMember3);
        assertTrue(success3, "Hat minting should succeed for member3");

        // Verify member3 is now wearing the campaign hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(marketingMember3, campaignHatId),
            "Marketing member 3 should now be wearing campaign hat"
        );
    }

    // Test Option 1: Single transaction with initial minting
    function testOption1SingleTransactionCreateAndMint() public {
        TestOrgSetup memory setup = _createTestOrg("Option1 DAO");
        address executive = voter1;
        address member1 = voter2;
        address member2 = address(0x7);

        // Setup executive
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        // Option 1: Create hat and mint to members in ONE transaction
        address[] memory initialMembers = new address[](2);
        initialMembers[0] = member1;
        initialMembers[1] = member2;

        bool[] memory initialEligible = new bool[](2);
        initialEligible[0] = true;
        initialEligible[1] = true;

        bool[] memory initialStanding = new bool[](2);
        initialStanding[0] = true;
        initialStanding[1] = true;

        vm.prank(setup.exec);
        uint256 teamHatId = EligibilityModule(setup.eligibilityModule)
            .createHatWithEligibility(
                EligibilityModule.CreateHatParams({
                parentHatId: setup.defaultRoleHat,
                details: "Team Hat",
                maxSupply: 10,
                _mutable: true,
                imageURI: "ipfs://team-image",
                defaultEligible: false,
                defaultStanding: true,
                mintToAddresses: initialMembers,
                wearerEligibleFlags: initialEligible,
                wearerStandingFlags: initialStanding
            })
            );

        // Verify both members are immediately wearing the hat
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(member1, teamHatId),
            "Member1 should be wearing hat after single transaction"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isWearerOfHat(member2, teamHatId),
            "Member2 should be wearing hat after single transaction"
        );

        // Verify default eligibility is false for others
        address randomUser = address(0x999);
        assertFalse(
            IHats(SEPOLIA_HATS).isEligible(randomUser, teamHatId), "Random user should not be eligible by default"
        );
        assertTrue(
            IHats(SEPOLIA_HATS).isInGoodStanding(randomUser, teamHatId),
            "Random user should have good standing by default"
        );
    }

    function testPaymentManagerFunctionality() public {
        // Deploy a full org
        (address hybrid, address exec, address qj, address token, address tm, address hub, address pm) =
            _deployFullOrg();

        PaymentManager paymentManager = PaymentManager(payable(pm));
        ParticipationToken participationToken = ParticipationToken(token);

        // Setup test users with participation tokens
        address holder1 = voter1;
        address holder2 = voter2;
        address holder3 = address(0x5);
        address nonHolder = address(0x999);

        // Give the executor permission to mint tokens (it should already have this as owner)
        vm.startPrank(exec);

        // Mint participation tokens to holders
        participationToken.mint(holder1, 100 ether);
        participationToken.mint(holder2, 200 ether);
        participationToken.mint(holder3, 300 ether);

        vm.stopPrank();

        // Test 1: ETH payment reception via receive function
        uint256 paymentAmount = 6 ether;
        vm.deal(address(this), paymentAmount);
        (bool success,) = payable(pm).call{value: paymentAmount}("");
        assertTrue(success, "ETH payment should succeed");
        assertEq(pm.balance, paymentAmount, "PaymentManager should have received ETH");

        // Test 2: ETH payment reception via pay function
        uint256 additionalPayment = 3 ether;
        address payer = address(0x6);
        vm.deal(payer, additionalPayment);
        vm.prank(payer);
        paymentManager.pay{value: additionalPayment}();
        assertEq(pm.balance, paymentAmount + additionalPayment, "PaymentManager should have all ETH");

        // Test 3: E2E merkle distribution with deployed org
        // Take checkpoint of current token balances
        uint256 checkpointBlock = block.number;

        // Calculate distribution amounts based on token holdings
        // Total supply: 600 ether, Distribution: 6 ether
        // holder1 (100/600 = 1/6) -> 1 ether
        // holder2 (200/600 = 2/6) -> 2 ether
        // holder3 (300/600 = 3/6) -> 3 ether
        uint256 holder1Amount = 1 ether;
        uint256 holder2Amount = 2 ether;
        uint256 holder3Amount = 3 ether;
        uint256 distributionAmount = 6 ether;

        // Build merkle tree (same logic as in PaymentManagerMerkle.t.sol)
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(holder1, holder1Amount))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(holder2, holder2Amount))));
        bytes32 leaf3 = keccak256(bytes.concat(keccak256(abi.encode(holder3, holder3Amount))));

        bytes32 node1 = _hashPair(leaf1, leaf2);
        bytes32 merkleRoot = _hashPair(node1, leaf3);

        // Advance block so checkpoint is in the past
        vm.roll(block.number + 1);

        // Create distribution (only executor can do this)
        vm.prank(exec);
        uint256 distributionId = paymentManager.createDistribution(
            address(0), // ETH
            distributionAmount,
            merkleRoot,
            checkpointBlock
        );

        assertEq(distributionId, 1, "First distribution should have ID 1");

        // Holders claim their shares
        // holder1 claims
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf2;
        proof1[1] = leaf3;

        uint256 holder1BalBefore = holder1.balance;
        vm.prank(holder1);
        paymentManager.claimDistribution(distributionId, holder1Amount, proof1);
        assertEq(holder1.balance - holder1BalBefore, holder1Amount, "holder1 should receive 1 ETH");

        // holder2 claims
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = leaf1;
        proof2[1] = leaf3;

        uint256 holder2BalBefore = holder2.balance;
        vm.prank(holder2);
        paymentManager.claimDistribution(distributionId, holder2Amount, proof2);
        assertEq(holder2.balance - holder2BalBefore, holder2Amount, "holder2 should receive 2 ETH");

        // holder3 claims
        bytes32[] memory proof3 = new bytes32[](1);
        proof3[0] = node1;

        uint256 holder3BalBefore = holder3.balance;
        vm.prank(holder3);
        paymentManager.claimDistribution(distributionId, holder3Amount, proof3);
        assertEq(holder3.balance - holder3BalBefore, holder3Amount, "holder3 should receive 3 ETH");

        // Verify all claimed
        assertTrue(paymentManager.hasClaimed(distributionId, holder1), "holder1 should have claimed");
        assertTrue(paymentManager.hasClaimed(distributionId, holder2), "holder2 should have claimed");
        assertTrue(paymentManager.hasClaimed(distributionId, holder3), "holder3 should have claimed");

        // Test 4: ERC20 payment and distribution
        MockERC20 paymentToken = new MockERC20("Payment Token", "PAY");
        paymentToken.mint(address(this), 1000 ether);

        // Approve and pay with ERC20
        uint256 erc20Payment = 120 ether;
        paymentToken.approve(pm, erc20Payment);
        paymentManager.payERC20(address(paymentToken), erc20Payment);
        assertEq(paymentToken.balanceOf(pm), erc20Payment, "PaymentManager should have received ERC20");

        // ERC20 distribution (covered in test/PaymentManagerMerkle.t.sol)

        // Test 5: Opt-out functionality
        vm.prank(address(0x123)); // Use arbitrary address
        paymentManager.optOut(true);
        assertTrue(paymentManager.isOptedOut(address(0x123)), "Address should be opted out");

        // Distribution with opt-out (covered in test/PaymentManagerMerkle.t.sol::test_RevertClaimDistribution_OptedOut)

        // Test 6: Opt back in
        vm.prank(address(0x123));
        paymentManager.optOut(false);
        assertFalse(paymentManager.isOptedOut(address(0x123)), "Address should be opted back in");

        // Test 7: Only owner can distribute (covered in test/PaymentManagerMerkle.t.sol::test_RevertCreateDistribution_OnlyOwner)
        // Test 8: Incomplete holders vulnerability fix (covered in test/PaymentManagerMerkle.t.sol::test_VulnerabilityFix_MintAfterCheckpoint)

        // Test 9: Revenue share token is correctly set
        assertEq(paymentManager.revenueShareToken(), token, "Revenue share token should be the participation token");
    }

    /// @notice Comprehensive test for hierarchy-based vouching authorization
    /// @dev This test ensures admins can vouch when combineWithHierarchy is enabled
    function testVouchingWithHierarchyAuthorization() public {
        TestOrgSetup memory setup = _createTestOrg("Hierarchy Vouch Test DAO");
        address adminUser = address(0x300);
        address memberUser = address(0x301);
        address candidateUser = address(0x302);
        address unauthorizedUser = address(0x303);

        // Set up users for vouching
        _setupUserForVouching(setup.eligibilityModule, setup.exec, adminUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, memberUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidateUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, unauthorizedUser);

        // Configure vouching WITH hierarchy: admins should be able to vouch
        _configureVouching(
            setup.eligibilityModule,
            setup.exec,
            setup.defaultRoleHat, // target hat
            1, // quorum
            setup.memberRoleHat, // membership hat
            true, // combineWithHierarchy = TRUE
            true
        );

        // Verify configuration
        assertTrue(
            EligibilityModule(setup.eligibilityModule).combinesWithHierarchy(setup.defaultRoleHat),
            "Should combine with hierarchy"
        );

        // Mint EXECUTIVE hat to adminUser (executive is admin of both default and member)
        _mintHat(setup.exec, setup.executiveRoleHat, adminUser);

        // Mint MEMBER hat to memberUser
        _mintHat(setup.exec, setup.memberRoleHat, memberUser);

        // TEST 1: Admin (EXECUTIVE hat wearer) should be able to vouch
        vm.prank(adminUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Admin vouch should be counted"
        );

        // Reset vouch count for next test
        vm.prank(adminUser);
        EligibilityModule(setup.eligibilityModule).revokeVouch(candidateUser, setup.defaultRoleHat);

        // TEST 2: Member should still be able to vouch
        vm.prank(memberUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Member vouch should be counted"
        );

        // Reset again
        vm.prank(memberUser);
        EligibilityModule(setup.eligibilityModule).revokeVouch(candidateUser, setup.defaultRoleHat);

        // TEST 3: Unauthorized user (no hat) should NOT be able to vouch
        vm.prank(unauthorizedUser);
        vm.expectRevert(EligibilityModule.NotAuthorizedToVouch.selector);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
    }

    /// @notice Test that admins CANNOT vouch when combineWithHierarchy is disabled
    /// @dev This ensures the flag properly controls vouching authorization
    function testVouchingWithoutHierarchyAuthorization() public {
        TestOrgSetup memory setup = _createTestOrg("No Hierarchy Vouch Test DAO");
        address adminUser = address(0x400);
        address memberUser = address(0x401);
        address candidateUser = address(0x402);

        // Set up users
        _setupUserForVouching(setup.eligibilityModule, setup.exec, adminUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, memberUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidateUser);

        // Configure vouching WITHOUT hierarchy: only members can vouch
        _configureVouching(
            setup.eligibilityModule,
            setup.exec,
            setup.defaultRoleHat, // target hat
            1, // quorum
            setup.memberRoleHat, // membership hat
            false, // combineWithHierarchy = FALSE
            true
        );

        // Verify configuration
        assertFalse(
            EligibilityModule(setup.eligibilityModule).combinesWithHierarchy(setup.defaultRoleHat),
            "Should NOT combine with hierarchy"
        );

        // Mint EXECUTIVE hat to adminUser
        _mintHat(setup.exec, setup.executiveRoleHat, adminUser);

        // Mint MEMBER hat to memberUser
        _mintHat(setup.exec, setup.memberRoleHat, memberUser);

        // TEST 1: Admin should NOT be able to vouch (no combineWithHierarchy)
        vm.prank(adminUser);
        vm.expectRevert(EligibilityModule.NotAuthorizedToVouch.selector);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);

        // TEST 2: Member should still be able to vouch
        vm.prank(memberUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Member vouch should be counted"
        );
    }

    /// @notice Test complex hierarchy where multiple admin levels can vouch
    /// @dev Ensures hierarchy checking works at multiple levels
    /// @dev Hierarchy: MEMBER (top) -> EXECUTIVE -> DEFAULT
    function testVouchingMultiLevelHierarchy() public {
        TestOrgSetup memory setup = _createTestOrg("Multi-Level Hierarchy Test DAO");
        address executiveUser = address(0x500);
        address defaultUser = address(0x501);
        address candidateUser = address(0x502);

        // Set up users
        _setupUserForVouching(setup.eligibilityModule, setup.exec, executiveUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, defaultUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidateUser);

        // Configure vouching with hierarchy on DEFAULT hat
        // Hierarchy: DEFAULT's admin is EXECUTIVE
        _configureVouching(
            setup.eligibilityModule,
            setup.exec,
            setup.defaultRoleHat, // target hat (DEFAULT)
            1, // quorum
            setup.defaultRoleHat, // membership hat (DEFAULT role holders can vouch)
            true, // combineWithHierarchy = true (so EXECUTIVE can also vouch)
            true
        );

        // Set users as eligible for their hats before minting
        vm.startPrank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .setWearerEligibility(executiveUser, setup.executiveRoleHat, true, true);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(defaultUser, setup.defaultRoleHat, true, true);
        vm.stopPrank();

        // Give users hats
        _mintHat(setup.exec, setup.executiveRoleHat, executiveUser); // Admin of DEFAULT
        _mintHat(setup.exec, setup.defaultRoleHat, defaultUser); // Has membership hat

        // TEST 1: EXECUTIVE (admin of DEFAULT) should be able to vouch with combineWithHierarchy
        vm.prank(executiveUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Admin vouch should work with combineWithHierarchy"
        );

        // Reset
        vm.prank(executiveUser);
        EligibilityModule(setup.eligibilityModule).revokeVouch(candidateUser, setup.defaultRoleHat);

        // TEST 2: DEFAULT role holder should be able to vouch (has membership hat)
        vm.prank(defaultUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Membership hat holder vouch should work"
        );
    }

    /// @notice Test edge case: user with both member and admin hat
    /// @dev Ensures vouching works correctly when user has multiple hats
    function testVouchingWithMultipleHats() public {
        TestOrgSetup memory setup = _createTestOrg("Multi-Hat Test DAO");
        address dualHatUser = address(0x600);
        address candidateUser = address(0x601);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, dualHatUser);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidateUser);

        // Configure vouching with hierarchy
        _configureVouching(
            setup.eligibilityModule,
            setup.exec,
            setup.defaultRoleHat,
            1,
            setup.memberRoleHat,
            true, // combineWithHierarchy
            true
        );

        // Give user both MEMBER and EXECUTIVE hats
        _mintHat(setup.exec, setup.memberRoleHat, dualHatUser);
        _mintHat(setup.exec, setup.executiveRoleHat, dualHatUser);

        // User should be able to vouch (has member hat)
        vm.prank(dualHatUser);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidateUser, setup.defaultRoleHat);
        assertEq(
            EligibilityModule(setup.eligibilityModule).currentVouchCount(setup.defaultRoleHat, candidateUser),
            1,
            "Dual hat user should be able to vouch"
        );
    }

    // Helper function for merkle tree construction
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /*═══════════════════════════════════ REGISTER HAT CREATION TESTS ═══════════════════════════════════════*/

    // Test that registerHatCreation emits the correct HatCreatedWithEligibility event
    function testRegisterHatCreationEvents() public {
        TestOrgSetup memory setup = _createTestOrg("Register Hat Test DAO");
        address executive = voter1;

        // Get toggle module address from org registry (uses ORG_ID constant)
        address toggleModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID);

        // Mint executive hat to voter1
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        // Create a new hat using createHat directly (simulating external hat creation)
        vm.prank(executive);
        uint256 newHatId = IHats(SEPOLIA_HATS)
            .createHat(
                setup.defaultRoleHat, // parent
                "Test Hat",
                100, // maxSupply
                setup.eligibilityModule,
                toggleModule,
                true, // mutable
                "ipfs://test-hat"
            );

        // Now register this hat creation - should emit HatCreatedWithEligibility event
        vm.expectEmit(true, true, true, true);
        emit HatCreatedWithEligibility(
            setup.exec, // creator (super admin)
            setup.defaultRoleHat, // parentHatId
            newHatId, // newHatId
            true, // defaultEligible
            true, // defaultStanding
            0 // mintedCount (registerHatCreation doesn't mint)
        );

        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).registerHatCreation(newHatId, setup.defaultRoleHat, true, true);
    }

    // Test that registerHatCreation emits DefaultEligibilityUpdated event
    function testRegisterHatCreationEmitsDefaultEligibilityUpdated() public {
        TestOrgSetup memory setup = _createTestOrg("Register Hat Eligibility Test DAO");
        address executive = voter1;

        address toggleModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID);

        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        vm.prank(executive);
        uint256 newHatId = IHats(SEPOLIA_HATS)
            .createHat(
                setup.defaultRoleHat,
                "Test Hat 2",
                100,
                setup.eligibilityModule,
                toggleModule,
                true,
                "ipfs://test-hat-2"
            );

        // Expect DefaultEligibilityUpdated event
        vm.expectEmit(true, false, false, true);
        emit DefaultEligibilityUpdated(newHatId, false, true, setup.exec);

        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .registerHatCreation(
                newHatId,
                setup.defaultRoleHat,
                false, // not eligible by default
                true // good standing by default
            );
    }

    // Test authorization - only superAdmin can call registerHatCreation
    function testRegisterHatCreationAuthorization() public {
        TestOrgSetup memory setup = _createTestOrg("Auth Test DAO");
        address executive = voter1;
        address unauthorized = address(0x999);

        address toggleModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID);

        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        // Create a hat that we'll try to register
        vm.prank(executive);
        uint256 newHatId = IHats(SEPOLIA_HATS)
            .createHat(
                setup.defaultRoleHat,
                "Auth Test Hat",
                100,
                setup.eligibilityModule,
                toggleModule,
                true,
                "ipfs://auth-test"
            );

        // Unauthorized user should not be able to register
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(setup.eligibilityModule).registerHatCreation(newHatId, setup.defaultRoleHat, true, true);

        // Hat admin (executive) is no longer authorized — only the super admin (executor) can
        vm.prank(executive);
        vm.expectRevert(abi.encodeWithSelector(EligibilityModule.NotSuperAdmin.selector));
        EligibilityModule(setup.eligibilityModule).registerHatCreation(newHatId, setup.defaultRoleHat, true, true);

        // Super admin should be able to register
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).registerHatCreation(newHatId, setup.defaultRoleHat, true, true);
    }

    // Test that registerHatCreation sets default eligibility correctly
    function testRegisterHatCreationSetsDefaultEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Default Eligibility Test DAO");
        address executive = voter1;
        address testWearer = address(0x888);

        address toggleModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID);

        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        vm.prank(executive);
        uint256 newHatId = IHats(SEPOLIA_HATS)
            .createHat(
                setup.defaultRoleHat,
                "Eligibility Test Hat",
                100,
                setup.eligibilityModule,
                toggleModule,
                true,
                "ipfs://eligibility-test"
            );

        // Register with specific eligibility settings (not eligible, good standing)
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule)
            .registerHatCreation(
                newHatId,
                setup.defaultRoleHat,
                false, // not eligible by default
                true // good standing by default
            );

        // Check that the default eligibility was set correctly
        (bool eligible, bool standing) =
            EligibilityModule(setup.eligibilityModule).getWearerStatus(testWearer, newHatId);
        assertFalse(eligible, "Wearer should not be eligible by default");
        assertTrue(standing, "Wearer should have good standing by default");
    }

    // Test that HatsTreeSetup correctly emits events during org deployment
    function testHatsTreeSetupEmitsRegisterHatCreationEvents() public {
        // This test verifies that HatsTreeSetup calls registerHatCreation
        // by checking that HatCreatedWithEligibility events are emitted during deployment

        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);
        RoleConfigStructs.RoleConfig[] memory roles = _buildSimpleRoleConfigs(names, images, voting);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: keccak256("EVENTS_TEST_ORG"),
            orgName: "Events Test DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: roles,
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        // Record logs to verify HatCreatedWithEligibility events were emitted
        vm.recordLogs();

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        // Count HatCreatedWithEligibility events
        // Event signature: HatCreatedWithEligibility(address,uint256,uint256,bool,bool,uint256)
        bytes32 eventSig = keccak256("HatCreatedWithEligibility(address,uint256,uint256,bool,bool,uint256)");
        uint256 hatCreatedEventCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                hatCreatedEventCount++;
            }
        }

        // Should have at least 3 events: 1 for eligibility admin hat + 2 for role hats (DEFAULT, EXECUTIVE)
        assertGe(hatCreatedEventCount, 3, "Should emit HatCreatedWithEligibility events for all created hats");
    }

    // Test that superAdmin can call registerHatCreation
    function testRegisterHatCreationBySuperAdmin() public {
        TestOrgSetup memory setup = _createTestOrg("SuperAdmin Test DAO");
        address executive = voter1;

        address toggleModule = orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID);

        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, executive);

        // Create a hat
        vm.prank(executive);
        uint256 newHatId = IHats(SEPOLIA_HATS)
            .createHat(
                setup.defaultRoleHat,
                "SuperAdmin Test Hat",
                100,
                setup.eligibilityModule,
                toggleModule,
                true,
                "ipfs://superadmin-test"
            );

        // SuperAdmin (executor) should be able to register even without being hat admin
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).registerHatCreation(newHatId, setup.defaultRoleHat, true, true);

        // Verify eligibility was set
        (bool eligible, bool standing) =
            EligibilityModule(setup.eligibilityModule).getWearerStatus(address(0x777), newHatId);
        assertTrue(eligible, "Wearer should be eligible by default after registration");
        assertTrue(standing, "Wearer should have good standing by default after registration");
    }

    /*═══════════════════════════════════════════════════════════════════════════════════
                  SUPER-ADMIN GATING — POST-HIERARCHY-LOCKDOWN TESTS

        Verifies the invariant introduced when `onlyHatAdmin` was replaced by
        `onlySuperAdmin` on all EligibilityModule write paths: only the org's
        Executor (the superAdmin) may mutate eligibility, hat configuration, or
        metadata. Hats-protocol hierarchical admins may still vouch (when
        `combineWithHierarchy` is enabled) but cannot directly write — and the
        eligibility check now blocks the previously-implicit "admin mints hat"
        bypass.
    ═══════════════════════════════════════════════════════════════════════════════════*/

    /// @dev Returns voter1 wearing the executive role hat — a Hats hierarchical admin
    ///      of the default and member role hats, but NOT the EligibilityModule's superAdmin.
    function _hierarchyAdmin(TestOrgSetup memory setup) internal returns (address hierarchyAdmin) {
        hierarchyAdmin = voter1;
        _mintAdminHat(setup.exec, setup.eligibilityModule, setup.executiveRoleHat, hierarchyAdmin);
    }

    function testHierarchyAdminCannotSetWearerEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: setWearer");
        address hierarchyAdmin = _hierarchyAdmin(setup);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(address(0x55), setup.defaultRoleHat, true, true);
    }

    function testHierarchyAdminCannotSetDefaultEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: setDefault");
        address hierarchyAdmin = _hierarchyAdmin(setup);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setDefaultEligibility(setup.defaultRoleHat, false, false);
    }

    function testHierarchyAdminCannotClearWearerEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: clear");
        address hierarchyAdmin = _hierarchyAdmin(setup);

        // Executor first grants per-wearer eligibility so there's something to clear.
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(address(0x55), setup.defaultRoleHat, true, true);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).clearWearerEligibility(address(0x55), setup.defaultRoleHat);
    }

    function testHierarchyAdminCannotSetBulkWearerEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: setBulk");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address[] memory wearers = new address[](1);
        wearers[0] = address(0x55);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setBulkWearerEligibility(wearers, setup.defaultRoleHat, true, true);
    }

    function testHierarchyAdminCannotBatchSetWearerEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: batchSet");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address[] memory wearers = new address[](1);
        wearers[0] = address(0x55);
        bool[] memory eligibles = new bool[](1);
        eligibles[0] = true;
        bool[] memory standings = new bool[](1);
        standings[0] = true;

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule)
            .batchSetWearerEligibility(setup.defaultRoleHat, wearers, eligibles, standings);
    }

    function testHierarchyAdminCannotCreateHatWithEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: createHat");
        address hierarchyAdmin = _hierarchyAdmin(setup);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule)
            .createHatWithEligibility(
                EligibilityModule.CreateHatParams({
                parentHatId: setup.defaultRoleHat,
                details: "Forbidden Child Hat",
                maxSupply: 1,
                _mutable: true,
                imageURI: "",
                defaultEligible: true,
                defaultStanding: true,
                mintToAddresses: new address[](0),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
            );
    }

    function testHierarchyAdminCannotUpdateHatMetadata() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: updateMeta");
        address hierarchyAdmin = _hierarchyAdmin(setup);

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).updateHatMetadata(setup.defaultRoleHat, "Renamed", bytes32(0));
    }

    /// @dev The critical end-to-end test: with vouching configured + default eligibility false,
    ///      a Hats-hierarchical admin cannot mint a wearer into the hat by ANY path. The only
    ///      way for a new wearer to join is through the vouching mechanism.
    function testHierarchyAdminCannotBypassVouchingViaDirectMint() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: bypass vouching");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address candidate = address(0xC4);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Vouching configured: 1 vouch from an executiveRoleHat wearer (the membership hat) suffices.
        // Default eligibility is set to false so vouching is the only entry path.
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.executiveRoleHat, false, true
        );

        // Path 1 (eligibility write) — blocked: hierarchy admin is not the superAdmin.
        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(candidate, setup.defaultRoleHat, true, true);

        // Path 2 (direct Hats mint) — blocked: candidate is ineligible by default, Hats reverts.
        vm.prank(hierarchyAdmin);
        vm.expectRevert();
        IHats(SEPOLIA_HATS).mintHat(setup.defaultRoleHat, candidate);
        _assertWearingHat(candidate, setup.defaultRoleHat, false, "candidate after blocked direct-mint");

        // Path 3 (vouching) — the documented entry path succeeds. hierarchyAdmin wears the
        // executive role hat, which is the configured membership hat for this vouch.
        _vouchFor(hierarchyAdmin, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, true, true, "candidate after vouch"
        );

        vm.prank(candidate);
        EligibilityModule(setup.eligibilityModule).claimVouchedHat(setup.defaultRoleHat);
        _assertWearingHat(candidate, setup.defaultRoleHat, true, "candidate after claim");
    }

    /// @dev A hierarchy admin cannot force-revoke an existing wearer either — the only
    ///      revocation paths are the executor's setWearerEligibility(false) or
    ///      claim-time vouch revocation.
    function testHierarchyAdminCannotForceRevokeWearer() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: force revoke");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address member = address(0xBE);

        // Executor mints the hat to member.
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(member, setup.defaultRoleHat, true, true);
        _mintHat(setup.exec, setup.defaultRoleHat, member);
        _assertWearingHat(member, setup.defaultRoleHat, true, "member wearing hat pre-attack");

        // Hierarchy admin's attempt to revoke is rejected.
        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(member, setup.defaultRoleHat, false, false);

        _assertWearingHat(member, setup.defaultRoleHat, true, "member still wearing hat after blocked revoke");
    }

    /// @dev Positive case: `combineWithHierarchy` still lets a Hats-hierarchical admin
    ///      participate as a voucher even when they do not wear the configured
    ///      membership hat directly. This is the one residual power hierarchy retains.
    function testHierarchyAdminCanStillVouchWhenCombineEnabled() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: hierarchy vouches");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address candidate = address(0xC5);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Membership hat = memberRoleHat (which hierarchyAdmin does NOT wear).
        // combineWithHierarchy = true means Hats-hierarchical admins of defaultRoleHat may also vouch.
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, true, true
        );

        // hierarchyAdmin wears the executive role hat → admin of defaultRoleHat in Hats →
        // qualifies as a voucher through the hierarchy branch of the auth check.
        _vouchFor(hierarchyAdmin, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        _assertEligibilityStatus(
            setup.eligibilityModule,
            candidate,
            setup.defaultRoleHat,
            true,
            true,
            "candidate eligible via hierarchy-vouch path"
        );
    }

    /// @dev Negative twin of the above: with `combineWithHierarchy = false`, a hierarchical
    ///      admin who does not wear the membership hat is rejected as a voucher.
    function testHierarchyAdminCannotVouchWhenCombineDisabled() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: hierarchy denied");
        address hierarchyAdmin = _hierarchyAdmin(setup);
        address candidate = address(0xC6);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        // Membership hat = memberRoleHat (not worn by hierarchyAdmin), combineWithHierarchy = false.
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 1, setup.memberRoleHat, false, true
        );

        vm.prank(hierarchyAdmin);
        vm.expectRevert(EligibilityModule.NotAuthorizedToVouch.selector);
        EligibilityModule(setup.eligibilityModule).vouchFor(candidate, setup.defaultRoleHat);
    }

    /// @dev A non-superAdmin who has no hat affiliation at all is still rejected. Covers
    ///      the trivial case alongside the hierarchy-aware cases above so that any future
    ///      regression that re-introduces a wildcard auth branch fails clearly.
    function testUnaffiliatedAddressCannotMutateEligibility() public {
        TestOrgSetup memory setup = _createTestOrg("Auth: stranger");
        address stranger = address(0xDEAD);

        vm.prank(stranger);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setWearerEligibility(stranger, setup.defaultRoleHat, true, true);

        vm.prank(stranger);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).setDefaultEligibility(setup.defaultRoleHat, true, true);

        vm.prank(stranger);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        EligibilityModule(setup.eligibilityModule).updateHatMetadata(setup.defaultRoleHat, "X", bytes32(0));
    }

    /*══════════════════════════════════════════════════════════════════════════════
                           OPTIONAL EDUCATIONHUB TESTS
    ══════════════════════════════════════════════════════════════════════════════*/

    // Test: Deploy org without EducationHub
    function testDeployOrgWithoutEducationHub() public {
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "ADMIN";

        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://admin";

        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 0);
        address[] memory ddTargets = new address[](0);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        bytes32 orgIdNoEdu = keccak256("no-education-hub-org");

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgIdNoEdu,
            orgName: "No EducationHub Org",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: address(this),
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        // Verify educationHub is address(0)
        assertEq(result.educationHub, address(0), "EducationHub should be address(0) when disabled");

        // Verify other contracts are still deployed
        assertTrue(result.executor != address(0), "Executor should be deployed");
        assertTrue(result.taskManager != address(0), "TaskManager should be deployed");
        assertTrue(result.paymentManager != address(0), "PaymentManager should be deployed");
        assertTrue(result.participationToken != address(0), "ParticipationToken should be deployed");
        assertTrue(result.hybridVoting != address(0), "HybridVoting should be deployed");
        assertTrue(result.quickJoin != address(0), "QuickJoin should be deployed");

        // Verify ParticipationToken.educationHub() returns address(0)
        assertEq(
            ParticipationToken(result.participationToken).educationHub(),
            address(0),
            "ParticipationToken.educationHub() should return address(0)"
        );
    }

    // Test: TaskManager can still mint tokens when EducationHub is disabled
    function testMintingWorksWithoutEducationHub() public {
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "ADMIN";

        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://admin";

        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 0);
        address[] memory ddTargets = new address[](0);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        bytes32 orgIdMint = keccak256("mint-without-edu-org");

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgIdMint,
            orgName: "Mint Without Edu Org",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: address(this),
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        // Verify TaskManager can still mint tokens
        ParticipationToken token = ParticipationToken(result.participationToken);
        TaskManager tm = TaskManager(result.taskManager);

        // Create a project and task to test minting
        address[] memory managers = new address[](0);
        uint256[] memory emptyHats = new uint256[](0);

        vm.prank(result.executor);
        bytes32 projectId = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: abi.encode("Test Project"),
                metadataHash: bytes32(0),
                cap: 1000 ether,
                managers: managers,
                createHat: 0,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        // Mint directly via executor (which is allowed)
        address recipient = address(0x123);
        vm.prank(result.executor);
        token.mint(recipient, 100 ether);

        assertEq(token.balanceOf(recipient), 100 ether, "Executor should be able to mint tokens");
    }

    // Test: EducationHub can be set later via governance
    function testEducationHubCanBeSetLater() public {
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "ADMIN";

        string[] memory images = new string[](2);
        images[0] = "ipfs://default";
        images[1] = "ipfs://admin";

        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 0);
        address[] memory ddTargets = new address[](0);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();

        bytes32 orgIdSetLater = keccak256("set-edu-later-org");

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgIdSetLater,
            orgName: "Set Edu Later Org",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: address(this),
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        // Verify educationHub is initially address(0)
        ParticipationToken token = ParticipationToken(result.participationToken);
        assertEq(token.educationHub(), address(0), "EducationHub should initially be address(0)");

        // Set EducationHub later (first setter can set it)
        address newEducationHub = address(0x456);
        token.setEducationHub(newEducationHub);

        assertEq(token.educationHub(), newEducationHub, "EducationHub should be set to new address");
    }

    // Test: Executor can clear EducationHub by setting to address(0)
    function testExecutorCanClearEducationHub() public {
        TestOrgSetup memory setup = _createTestOrg("Clear EducationHub Test");

        ParticipationToken token = ParticipationToken(setup.token);

        // Verify educationHub is initially set
        assertTrue(token.educationHub() != address(0), "EducationHub should initially be set");

        // Executor clears the educationHub
        vm.prank(setup.exec);
        token.setEducationHub(address(0));

        assertEq(token.educationHub(), address(0), "EducationHub should be cleared to address(0)");
    }

    /*───────────────── ROLE APPLICATION TESTS ───────────────────*/

    function testRoleApplicationBasic() public {
        TestOrgSetup memory setup = _createTestOrg("App Basic DAO");
        address applicant = address(0x400);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant);

        // Configure vouching on DEFAULT hat
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        bytes32 appHash = keccak256("my-application-ipfs-hash");

        // Apply
        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, appHash);

        // Verify storage
        assertEq(
            EligibilityModule(setup.eligibilityModule).getRoleApplication(setup.defaultRoleHat, applicant),
            appHash,
            "Application hash should be stored"
        );
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant),
            "Should have active application"
        );
        address[] memory applicants = EligibilityModule(setup.eligibilityModule).getRoleApplicants(setup.defaultRoleHat);
        assertEq(applicants.length, 1, "Should have 1 applicant");
        assertEq(applicants[0], applicant, "Applicant address should match");
    }

    function testRoleApplicationEmitsEvent() public {
        TestOrgSetup memory setup = _createTestOrg("App Event DAO");
        address applicant = address(0x401);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        bytes32 appHash = keccak256("app-hash");

        vm.prank(applicant);
        vm.expectEmit(true, true, false, true);
        emit RoleApplicationSubmitted(setup.defaultRoleHat, applicant, appHash);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, appHash);
    }

    function testRoleApplicationWithdraw() public {
        TestOrgSetup memory setup = _createTestOrg("App Withdraw DAO");
        address applicant = address(0x402);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        bytes32 appHash = keccak256("app-hash");

        // Apply
        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, appHash);

        // Withdraw
        vm.prank(applicant);
        vm.expectEmit(true, true, false, false);
        emit RoleApplicationWithdrawn(setup.defaultRoleHat, applicant);
        EligibilityModule(setup.eligibilityModule).withdrawApplication(setup.defaultRoleHat);

        assertFalse(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant),
            "Application should be cleared"
        );

        // Can reapply after withdrawal
        bytes32 newHash = keccak256("updated-app");
        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, newHash);

        assertEq(
            EligibilityModule(setup.eligibilityModule).getRoleApplication(setup.defaultRoleHat, applicant),
            newHash,
            "New application should be stored"
        );
    }

    function testRoleApplicationInvalidHash() public {
        TestOrgSetup memory setup = _createTestOrg("App Invalid DAO");
        address applicant = address(0x403);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        vm.prank(applicant);
        vm.expectRevert(EligibilityModule.InvalidApplicationHash.selector);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, bytes32(0));
    }

    function testRoleApplicationVouchingNotEnabled() public {
        TestOrgSetup memory setup = _createTestOrg("App NoVouch DAO");
        address applicant = address(0x404);

        // Don't configure vouching — default hat has no vouching
        vm.prank(applicant);
        vm.expectRevert(EligibilityModule.VouchingNotEnabled.selector);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("app"));
    }

    function testRoleApplicationDuplicate() public {
        TestOrgSetup memory setup = _createTestOrg("App Dup DAO");
        address applicant = address(0x405);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("first"));

        vm.prank(applicant);
        vm.expectRevert(EligibilityModule.ApplicationAlreadyExists.selector);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("second"));
    }

    function testRoleApplicationAlreadyWearing() public {
        TestOrgSetup memory setup = _createTestOrg("App Wearing DAO");

        // Mint MEMBER hat to voter1 (default eligibility is true)
        _mintHat(setup.exec, setup.memberRoleHat, voter1);

        // Configure vouching with combineWithHierarchy=true so hierarchy eligibility preserves wearer status
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.memberRoleHat, 2, setup.defaultRoleHat, true, false
        );

        // voter1 already wears memberRoleHat, so applying should revert
        vm.prank(voter1);
        vm.expectRevert("Already wearing hat");
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.memberRoleHat, keccak256("app"));
    }

    function testRoleApplicationFullFlow() public {
        TestOrgSetup memory setup = _createTestOrg("App Full DAO");
        address applicant = address(0x406);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant);

        // Configure vouching: 2 vouches from MEMBER hat
        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Mint MEMBER hats to vouchers
        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter2);

        // 1. Applicant applies
        bytes32 appHash = keccak256("my-application");
        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, appHash);

        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant),
            "Should have active application"
        );

        // 2. Vouchers vouch
        _vouchFor(voter1, setup.eligibilityModule, applicant, setup.defaultRoleHat);
        _vouchFor(voter2, setup.eligibilityModule, applicant, setup.defaultRoleHat);

        // 3. Applicant claims hat
        vm.prank(applicant);
        EligibilityModule(setup.eligibilityModule).claimVouchedHat(setup.defaultRoleHat);

        // Verify: wearing hat
        _assertWearingHat(applicant, setup.defaultRoleHat, true, "After claim");

        // Verify: application auto-cleaned
        assertFalse(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant),
            "Application should be cleared after claim"
        );
    }

    function testRoleApplicationMultipleApplicants() public {
        TestOrgSetup memory setup = _createTestOrg("App Multi DAO");
        address applicant1 = address(0x407);
        address applicant2 = address(0x408);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, applicant2);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        vm.prank(applicant1);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("app1"));

        vm.prank(applicant2);
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("app2"));

        // Both should have active applications
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant1),
            "Applicant1 should have application"
        );
        assertTrue(
            EligibilityModule(setup.eligibilityModule).hasActiveApplication(setup.defaultRoleHat, applicant2),
            "Applicant2 should have application"
        );

        // Applications should be independent
        assertEq(
            EligibilityModule(setup.eligibilityModule).getRoleApplication(setup.defaultRoleHat, applicant1),
            keccak256("app1"),
            "Applicant1 hash should match"
        );
        assertEq(
            EligibilityModule(setup.eligibilityModule).getRoleApplication(setup.defaultRoleHat, applicant2),
            keccak256("app2"),
            "Applicant2 hash should match"
        );

        address[] memory applicants = EligibilityModule(setup.eligibilityModule).getRoleApplicants(setup.defaultRoleHat);
        assertEq(applicants.length, 2, "Should have 2 applicants");
    }

    function testRoleApplicationWhilePaused() public {
        TestOrgSetup memory setup = _createTestOrg("App Paused DAO");
        address applicant = address(0x409);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        // Pause the module
        vm.prank(setup.exec);
        EligibilityModule(setup.eligibilityModule).pause();

        // Apply should revert
        vm.prank(applicant);
        vm.expectRevert("Contract is paused");
        EligibilityModule(setup.eligibilityModule).applyForRole(setup.defaultRoleHat, keccak256("app"));

        // Withdraw should also revert (even though there's nothing to withdraw, pause check comes first)
        vm.prank(applicant);
        vm.expectRevert("Contract is paused");
        EligibilityModule(setup.eligibilityModule).withdrawApplication(setup.defaultRoleHat);
    }

    function testWithdrawApplicationNoActiveReverts() public {
        TestOrgSetup memory setup = _createTestOrg("App NoActive DAO");
        address applicant = address(0x410);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        vm.prank(applicant);
        vm.expectRevert(EligibilityModule.NoActiveApplication.selector);
        EligibilityModule(setup.eligibilityModule).withdrawApplication(setup.defaultRoleHat);
    }

    /* ═══════════════════════════════════════════════════════════════════
       Beacon Ownership Tests (Fix 1 — all module beacons owned by executor)
       ═══════════════════════════════════════════════════════════════════ */

    function _getBeaconForType(bytes32 typeId) internal view returns (address) {
        bytes32 contractId = keccak256(abi.encodePacked(ORG_ID, typeId));
        return orgRegistry.getContractBeacon(contractId);
    }

    function testExecutorBeaconOwnedByExecutor() public {
        TestOrgSetup memory setup = _createTestOrg("Beacon Owner DAO");
        address beacon = _getBeaconForType(ModuleTypes.EXECUTOR_ID);
        assertEq(SwitchableBeacon(beacon).owner(), setup.exec, "Executor beacon should be owned by executor");
    }

    function testEligibilityBeaconOwnedByExecutor() public {
        TestOrgSetup memory setup = _createTestOrg("Beacon Owner DAO");
        address beacon = _getBeaconForType(ModuleTypes.ELIGIBILITY_MODULE_ID);
        assertEq(SwitchableBeacon(beacon).owner(), setup.exec, "Eligibility beacon should be owned by executor");
    }

    function testToggleBeaconOwnedByExecutor() public {
        TestOrgSetup memory setup = _createTestOrg("Beacon Owner DAO");
        address beacon = _getBeaconForType(ModuleTypes.TOGGLE_MODULE_ID);
        assertEq(SwitchableBeacon(beacon).owner(), setup.exec, "Toggle beacon should be owned by executor");
    }

    function testVouchRevocationCrossDay() public {
        TestOrgSetup memory setup = _createTestOrg("Cross-Day Revoke DAO");
        address candidate = address(0x500);

        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter1);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, voter2);
        _setupUserForVouching(setup.eligibilityModule, setup.exec, candidate);

        _configureVouching(
            setup.eligibilityModule, setup.exec, setup.defaultRoleHat, 2, setup.memberRoleHat, false, true
        );

        _mintHat(setup.exec, setup.memberRoleHat, voter1);
        _mintHat(setup.exec, setup.memberRoleHat, voter2);

        // Vouch on day 1
        _vouchFor(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);
        _vouchFor(voter2, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Warp to a different day (previously caused underflow in dailyVouchCount decrement)
        vm.warp(block.timestamp + 2 days);

        // Revoke on day 3 — should succeed without underflow
        _revokeVouch(voter1, setup.eligibilityModule, candidate, setup.defaultRoleHat);

        // Verify the revocation worked correctly
        _assertVouchStatus(
            setup.eligibilityModule, candidate, setup.defaultRoleHat, 1, false, "After cross-day revocation"
        );
    }

    /*════════════════════════════════════════════════════════════════════
     *  DEPLOYER USERNAME REGISTRATION TESTS
     *════════════════════════════════════════════════════════════════════*/

    // EIP-712 constants matching UniversalAccountRegistry
    bytes32 private constant _REG_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _REG_NAME_HASH = keccak256("UniversalAccountRegistry");
    bytes32 private constant _REG_VERSION_HASH = keccak256("1");
    bytes32 private constant _REG_REGISTER_TYPEHASH =
        keccak256("RegisterAccount(address user,string username,uint256 nonce,uint256 deadline)");

    uint256 private constant DEPLOYER_PK = 0xA11CE;

    function _signRegistration(
        uint256 privateKey,
        address account,
        string memory username,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(_REG_REGISTER_TYPEHASH, account, keccak256(bytes(username)), nonce, deadline)
        );
        bytes32 domainSep = keccak256(
            abi.encode(_REG_DOMAIN_TYPEHASH, _REG_NAME_HASH, _REG_VERSION_HASH, block.chainid, accountRegProxy)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testDeployerUsernameRegistration() public {
        address deployerSigner = vm.addr(DEPLOYER_PK);
        bytes32 orgId = keccak256("USERNAME-REG-ORG");
        string memory username = "deployer-user";
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 0;

        bytes memory sig = _signRegistration(DEPLOYER_PK, deployerSigner, username, nonce, deadline);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Username Test DAO",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: deployerSigner,
            deployerUsername: username,
            regDeadline: deadline,
            regNonce: nonce,
            regSignature: sig,
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(deployerSigner);
        deployer.deployFullOrg(params);

        // Verify the deployer's username was registered
        string memory registered = UniversalAccountRegistry(accountRegProxy).getUsername(deployerSigner);
        assertEq(registered, username, "Deployer username should be registered during org deploy");
    }

    function testDeployerUsernameSkippedWhenEmpty() public {
        // This verifies the common case: empty username + zero sig fields = no revert
        bytes32 orgId = keccak256("EMPTY-USERNAME-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "No Username DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        deployer.deployFullOrg(params); // Should not revert

        // No username should be registered
        string memory registered = UniversalAccountRegistry(accountRegProxy).getUsername(orgOwner);
        assertEq(bytes(registered).length, 0, "No username should be registered when deployerUsername is empty");
    }

    function testDeployerUsernameSkippedWhenAlreadyRegistered() public {
        address deployerSigner = vm.addr(DEPLOYER_PK);
        string memory username = "already-registered";

        // Pre-register the deployer directly
        vm.prank(deployerSigner);
        UniversalAccountRegistry(accountRegProxy).registerAccount(username);

        // Now deploy org with a different username — should skip registration (not revert)
        bytes32 orgId = keccak256("ALREADY-REG-ORG");
        string memory newUsername = "new-name";
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 0;
        bytes memory sig = _signRegistration(DEPLOYER_PK, deployerSigner, newUsername, nonce, deadline);

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Already Registered DAO",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: deployerSigner,
            deployerUsername: newUsername,
            regDeadline: deadline,
            regNonce: nonce,
            regSignature: sig,
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(deployerSigner);
        deployer.deployFullOrg(params); // Should not revert

        // Original username should be preserved, not overwritten
        string memory registered = UniversalAccountRegistry(accountRegProxy).getUsername(deployerSigner);
        assertEq(registered, username, "Original username should be preserved when deployer is already registered");
    }

    /*──────────────────────────────────────────────────────────────────────────
     *  Metadata Admin Role Index Tests
     *────────────────────────────────────────────────────────────────────────*/

    /// @dev Deploy with metadataAdminRoleIndex pointing to role 0 →
    ///      role 0's hat becomes the metadata admin hat.
    function testMetadataAdminExplicitRole0() public {
        bytes32 orgId = keccak256("META-ADMIN-ROLE0-ORG");

        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "MEMBER";
        names[1] = "ADMIN";
        string[] memory images = new string[](2);
        images[0] = "ipfs://member";
        images[1] = "ipfs://admin";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "MetaAdminRole0 DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: 0, // Explicitly set role 0
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params);
        vm.stopPrank();

        // Verify role 0's hat was set as metadata admin
        uint256 role0Hat = orgRegistry.getRoleHat(orgId, 0);
        uint256 metaAdminHat = orgRegistry.getOrgMetadataAdminHat(orgId);
        assertEq(metaAdminHat, role0Hat, "Metadata admin hat should be role 0's hat");
        assertTrue(metaAdminHat != 0, "Metadata admin hat should be non-zero");
    }

    /// @dev Deploy with metadataAdminRoleIndex pointing to role 1 →
    ///      role 1's hat becomes the metadata admin hat.
    function testMetadataAdminExplicitRole1() public {
        bytes32 orgId = keccak256("META-ADMIN-ROLE1-ORG");

        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "MEMBER";
        names[1] = "ADMIN";
        string[] memory images = new string[](2);
        images[0] = "ipfs://member";
        images[1] = "ipfs://admin";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "MetaAdminRole1 DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: 1, // Explicitly set role 1
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params);
        vm.stopPrank();

        // Verify role 1's hat was set as metadata admin
        uint256 role1Hat = orgRegistry.getRoleHat(orgId, 1);
        uint256 metaAdminHat = orgRegistry.getOrgMetadataAdminHat(orgId);
        assertEq(metaAdminHat, role1Hat, "Metadata admin hat should be role 1's hat");
        assertTrue(metaAdminHat != 0, "Metadata admin hat should be non-zero");

        // Also verify it's NOT role 0's hat (they should differ)
        uint256 role0Hat = orgRegistry.getRoleHat(orgId, 0);
        assertTrue(metaAdminHat != role0Hat, "Metadata admin hat should differ from role 0's hat");
    }

    /// @dev Deploy with metadataAdminRoleIndex = type(uint256).max (skip) →
    ///      no metadata admin hat set, topHat fallback applies.
    function testMetadataAdminSkipped() public {
        bytes32 orgId = keccak256("META-ADMIN-SKIP-ORG");

        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "MEMBER";
        names[1] = "ADMIN";
        string[] memory images = new string[](2);
        images[0] = "ipfs://member";
        images[1] = "ipfs://admin";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "MetaAdminSkip DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max, // Skip
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params);
        vm.stopPrank();

        // metadataAdminHatOf should be 0 (not set) → topHat fallback in OrgRegistry
        uint256 metaAdminHat = orgRegistry.getOrgMetadataAdminHat(orgId);
        assertEq(metaAdminHat, 0, "Metadata admin hat should be zero when skipped (topHat fallback)");
    }

    /// @dev Deploy with out-of-bounds metadataAdminRoleIndex (not max, but still >= roles.length) →
    ///      silently skipped, same as max.
    function testMetadataAdminOutOfBoundsIndex() public {
        bytes32 orgId = keccak256("META-ADMIN-OOB-ORG");

        vm.startPrank(orgOwner);

        string[] memory names = new string[](2);
        names[0] = "MEMBER";
        names[1] = "ADMIN";
        string[] memory images = new string[](2);
        images[0] = "ipfs://member";
        images[1] = "ipfs://admin";
        bool[] memory canVote = new bool[](2);
        canVote[0] = true;
        canVote[1] = true;

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "MetaAdminOOB DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, canVote),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: 999, // Out of bounds but not max
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        deployer.deployFullOrg(params); // Should NOT revert
        vm.stopPrank();

        // Same behavior as skip — no metadata admin hat set
        uint256 metaAdminHat = orgRegistry.getOrgMetadataAdminHat(orgId);
        assertEq(metaAdminHat, 0, "Metadata admin hat should be zero for out-of-bounds index");
    }

    /*════════════════  PAYMASTER FUNDING & CONFIG TESTS  ════════════════*/

    function testDeployFullOrgWithPaymasterFunding() public {
        bytes32 orgId = keccak256("PAYMASTER-FUNDED-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Funded DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        deployer.deployFullOrg{value: 0.1 ether}(params);

        // Verify org was registered with PaymasterHub
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.adminHatId != 0, "Org should be registered with PaymasterHub");

        // Verify deposit was credited
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0.1 ether, "Org should have 0.1 ETH deposited");
    }

    function testDeployFullOrgWithPaymasterAutoWhitelist() public {
        bytes32 orgId = keccak256("WHITELIST-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 1, // EXECUTIVE role
            autoWhitelistContracts: true,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Whitelist DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg{value: 0.05 ether}(params);

        // Verify operator hat was set (role 1 = EXECUTIVE)
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.operatorHatId != 0, "Operator hat should be set");

        // Verify auto-whitelisted rules exist for deployed contracts
        PaymasterHub.Rule memory rule;

        // Check QuickJoin quickJoinWithUser() is whitelisted
        rule = paymasterHub.getRule(orgId, result.quickJoin, bytes4(keccak256("quickJoinWithUser()")));
        assertTrue(rule.allowed, "QuickJoin quickJoinWithUser should be whitelisted");

        // Check TaskManager claimTask(uint256) is whitelisted
        rule = paymasterHub.getRule(orgId, result.taskManager, bytes4(keccak256("claimTask(uint256)")));
        assertTrue(rule.allowed, "TaskManager claimTask should be whitelisted");

        // Check TaskManager setFolders is whitelisted (v4 bootstrap)
        rule = paymasterHub.getRule(orgId, result.taskManager, bytes4(keccak256("setFolders(bytes32,bytes32)")));
        assertTrue(rule.allowed, "TaskManager setFolders should be whitelisted (v4 bootstrap)");

        // Check HybridVoting vote is whitelisted
        bytes4 voteSel = bytes4(keccak256("vote(uint256,uint8[],uint8[])"));
        rule = paymasterHub.getRule(orgId, result.hybridVoting, voteSel);
        assertTrue(rule.allowed, "HybridVoting vote should be whitelisted");

        // Check DDVoting vote is whitelisted
        rule = paymasterHub.getRule(orgId, result.directDemocracyVoting, voteSel);
        assertTrue(rule.allowed, "DDVoting vote should be whitelisted");

        // Check PaymentManager optOut is whitelisted
        rule = paymasterHub.getRule(orgId, result.paymentManager, bytes4(keccak256("optOut(bool)")));
        assertTrue(rule.allowed, "PaymentManager optOut should be whitelisted");

        // Check EducationHub completeModule is whitelisted
        rule = paymasterHub.getRule(orgId, result.educationHub, bytes4(keccak256("completeModule(uint256,uint8)")));
        assertTrue(rule.allowed, "EducationHub completeModule should be whitelisted");

        // Verify deposit was also credited
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0.05 ether, "Org should have 0.05 ETH deposited");
    }

    function testDeployFullOrgWithPaymasterFeeCaps() public {
        bytes32 orgId = keccak256("FEECAPS-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max, // skip, topHat only
            autoWhitelistContracts: false,
            maxFeePerGas: 100 gwei,
            maxPriorityFeePerGas: 2 gwei,
            maxCallGas: 500_000,
            maxVerificationGas: 200_000,
            maxPreVerificationGas: 100_000,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "FeeCaps DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        deployer.deployFullOrg(params);

        // Verify fee caps were set
        PaymasterHub.FeeCaps memory feeCaps = paymasterHub.getFeeCaps(orgId);
        assertEq(feeCaps.maxFeePerGas, 100 gwei, "maxFeePerGas should be 100 gwei");
        assertEq(feeCaps.maxPriorityFeePerGas, 2 gwei, "maxPriorityFeePerGas should be 2 gwei");
        assertEq(feeCaps.maxCallGas, 500_000, "maxCallGas should be 500k");
        assertEq(feeCaps.maxVerificationGas, 200_000, "maxVerificationGas should be 200k");
        assertEq(feeCaps.maxPreVerificationGas, 100_000, "maxPreVerificationGas should be 100k");
    }

    function testDeployFullOrgPaymasterBackwardsCompat() public {
        // Default config (all zeros) with no msg.value should work identically to before
        bytes32 orgId = keccak256("COMPAT-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Compat DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        deployer.deployFullOrg(params); // No msg.value, should use simple registerOrg path

        // Verify org is registered
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.adminHatId != 0, "Org should be registered with PaymasterHub");

        // Verify no deposits
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0, "No deposit should be recorded");

        // Verify operator hat is 0 (skipped)
        assertEq(orgConfig.operatorHatId, 0, "Operator hat should be 0 when skipped");
    }

    function testDeployFullOrgPaymasterOperatorOnly() public {
        // Setting operator role without other config should use simple registerOrg path
        bytes32 orgId = keccak256("OPERATOR-ONLY-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        // Only set operator role, nothing else
        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 1, // EXECUTIVE
            autoWhitelistContracts: false,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Operator Only DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        deployer.deployFullOrg(params); // No ETH, no fee caps, no whitelist → registerOrg path

        // Verify operator hat is set via the simple registerOrg path
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.adminHatId != 0, "Org should be registered");
        assertTrue(orgConfig.operatorHatId != 0, "Operator hat should be set even via registerOrg path");

        // Verify no fee caps (should be default zeros)
        PaymasterHub.FeeCaps memory feeCaps = paymasterHub.getFeeCaps(orgId);
        assertEq(feeCaps.maxFeePerGas, 0, "No fee caps should be set");
    }

    function testDeployFullOrgAutoWhitelistNoEducation() public {
        // Auto-whitelist with education disabled should produce 23 rules (not 24)
        bytes32 orgId = keccak256("NO-EDU-WHITELIST-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: true,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "No Edu Whitelist DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        // Core contract rules should still be set
        PaymasterHub.Rule memory rule;

        rule = paymasterHub.getRule(orgId, result.quickJoin, bytes4(keccak256("quickJoinWithUser()")));
        assertTrue(rule.allowed, "QuickJoin should be whitelisted");

        rule = paymasterHub.getRule(orgId, result.taskManager, bytes4(keccak256("claimTask(uint256)")));
        assertTrue(rule.allowed, "TaskManager should be whitelisted");

        rule = paymasterHub.getRule(orgId, result.hybridVoting, bytes4(keccak256("vote(uint256,uint8[],uint8[])")));
        assertTrue(rule.allowed, "HybridVoting should be whitelisted");

        // EducationHub should NOT be whitelisted (disabled)
        // educationHub address is zero when disabled, so checking rule on address(0) is meaningless
        // Instead, verify the org was registered successfully
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.adminHatId != 0, "Org should be registered");
    }

    function testDeployFullOrgPaymasterFullConfig() public {
        // All paymaster options together: funding + fee caps + auto-whitelist + operator hat
        bytes32 orgId = keccak256("FULL-CONFIG-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 1, // EXECUTIVE
            autoWhitelistContracts: true,
            maxFeePerGas: 50 gwei,
            maxPriorityFeePerGas: 1 gwei,
            maxCallGas: 300_000,
            maxVerificationGas: 150_000,
            maxPreVerificationGas: 50_000,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Full Config DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg{value: 0.2 ether}(params);

        // 1. Verify operator hat
        PaymasterHub.OrgConfig memory orgConfig = paymasterHub.getOrgConfig(orgId);
        assertTrue(orgConfig.operatorHatId != 0, "Operator hat should be set");

        // 2. Verify fee caps
        PaymasterHub.FeeCaps memory feeCaps = paymasterHub.getFeeCaps(orgId);
        assertEq(feeCaps.maxFeePerGas, 50 gwei);
        assertEq(feeCaps.maxPriorityFeePerGas, 1 gwei);
        assertEq(feeCaps.maxCallGas, 300_000);

        // 3. Verify auto-whitelist (spot check)
        PaymasterHub.Rule memory rule =
            paymasterHub.getRule(orgId, result.quickJoin, bytes4(keccak256("quickJoinWithUser()")));
        assertTrue(rule.allowed, "QuickJoin should be whitelisted");

        rule = paymasterHub.getRule(orgId, result.taskManager, bytes4(keccak256("submitTask(uint256,bytes32)")));
        assertTrue(rule.allowed, "TaskManager submitTask should be whitelisted");

        // 4. Verify deposit
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0.2 ether, "Deposit should be 0.2 ETH");
    }

    function testPaymasterSelectorAccuracy() public {
        // Verify ALL computed selectors match actual contract function selectors
        // This catches selector string typos in _buildDefaultPaymasterRules

        // ── QuickJoin (3) ──
        assertEq(
            bytes4(keccak256("quickJoinWithUser()")),
            QuickJoin.quickJoinWithUser.selector,
            "quickJoinWithUser selector mismatch"
        );
        assertEq(
            bytes4(keccak256("registerAndQuickJoin(address,string,uint256,uint256,bytes)")),
            QuickJoin.registerAndQuickJoin.selector,
            "registerAndQuickJoin selector mismatch"
        );
        assertEq(
            bytes4(
                keccak256(
                    "registerAndQuickJoinWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32))"
                )
            ),
            QuickJoin.registerAndQuickJoinWithPasskey.selector,
            "registerAndQuickJoinWithPasskey selector mismatch"
        );

        // ── TaskManager (10) ──
        assertEq(
            bytes4(keccak256("createTask(uint256,bytes,bytes32,bytes32,address,uint256,bool)")),
            TaskManager.createTask.selector,
            "createTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("createTasksBatch(bytes32,(uint256,bytes,bytes32,address,uint256,bool)[])")),
            TaskManager.createTasksBatch.selector,
            "createTasksBatch selector mismatch"
        );
        assertEq(bytes4(keccak256("claimTask(uint256)")), TaskManager.claimTask.selector, "claimTask selector mismatch");
        assertEq(
            bytes4(keccak256("submitTask(uint256,bytes32)")),
            TaskManager.submitTask.selector,
            "submitTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("completeTask(uint256)")),
            TaskManager.completeTask.selector,
            "completeTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("applyForTask(uint256,bytes32)")),
            TaskManager.applyForTask.selector,
            "applyForTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("approveApplication(uint256,address)")),
            TaskManager.approveApplication.selector,
            "approveApplication selector mismatch"
        );
        assertEq(
            bytes4(keccak256("assignTask(uint256,address)")),
            TaskManager.assignTask.selector,
            "assignTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("rejectTask(uint256,bytes32)")),
            TaskManager.rejectTask.selector,
            "rejectTask selector mismatch"
        );
        assertEq(
            bytes4(keccak256("cancelTask(uint256)")), TaskManager.cancelTask.selector, "cancelTask selector mismatch"
        );

        // ── HybridVoting (3) ──
        assertEq(
            bytes4(keccak256("vote(uint256,uint8[],uint8[])")),
            HybridVoting.vote.selector,
            "HybridVoting vote selector mismatch"
        );
        assertEq(
            bytes4(keccak256("announceWinner(uint256)")),
            HybridVoting.announceWinner.selector,
            "HybridVoting announceWinner selector mismatch"
        );
        assertEq(
            bytes4(keccak256("createProposal(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[])")),
            HybridVoting.createProposal.selector,
            "HybridVoting createProposal selector mismatch"
        );

        // ── DirectDemocracyVoting (3) ──
        assertEq(
            bytes4(keccak256("vote(uint256,uint8[],uint8[])")),
            DirectDemocracyVoting.vote.selector,
            "DDVoting vote selector mismatch"
        );
        assertEq(
            bytes4(keccak256("announceWinner(uint256)")),
            DirectDemocracyVoting.announceWinner.selector,
            "DDVoting announceWinner selector mismatch"
        );
        assertEq(
            bytes4(keccak256("createProposal(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[])")),
            DirectDemocracyVoting.createProposal.selector,
            "DDVoting createProposal selector mismatch"
        );

        // ── PaymentManager (3) ──
        assertEq(
            bytes4(keccak256("claimDistribution(uint256,uint256,bytes32[])")),
            PaymentManager.claimDistribution.selector,
            "claimDistribution selector mismatch"
        );
        assertEq(
            bytes4(keccak256("claimMultiple(uint256[],uint256[],bytes32[][])")),
            PaymentManager.claimMultiple.selector,
            "claimMultiple selector mismatch"
        );
        assertEq(bytes4(keccak256("optOut(bool)")), PaymentManager.optOut.selector, "optOut selector mismatch");

        // ── EducationHub (1) ──
        assertEq(
            bytes4(keccak256("completeModule(uint256,uint8)")),
            EducationHub.completeModule.selector,
            "completeModule selector mismatch"
        );
    }

    function testDeployFullOrgWithBudgets() public {
        bytes32 orgId = keccak256("BUDGET-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 1,
            autoWhitelistContracts: false,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0.1 ether,
            defaultBudgetEpochLen: 1 days
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Budget DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        deployer.deployFullOrg{value: 0.05 ether}(params);

        // Verify budget set for each role hat (2 roles)
        for (uint256 i = 0; i < 2; i++) {
            uint256 hatId = orgRegistry.getRoleHat(orgId, i);
            bytes32 subjectKey = keccak256(abi.encodePacked(uint8(0x01), bytes32(hatId)));
            PaymasterHub.Budget memory budget = paymasterHub.getBudget(orgId, subjectKey);
            assertEq(budget.capPerEpoch, 0.1 ether, "Budget cap should match");
            assertEq(budget.epochLen, 1 days, "Epoch length should match");
            assertTrue(budget.epochStart > 0, "Epoch start should be initialized");
        }

        // Verify deposit was also credited
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0.05 ether, "Org should have 0.05 ETH deposited");
    }

    function testDeployFullOrgBudgetsWithFullConfig() public {
        bytes32 orgId = keccak256("BUDGET-FULL-ORG");

        string[] memory names = new string[](3);
        names[0] = "MEMBER";
        names[1] = "MODERATOR";
        names[2] = "ADMIN";
        string[] memory images = new string[](3);
        images[0] = "";
        images[1] = "";
        images[2] = "";
        bool[] memory voting = new bool[](3);
        voting[0] = true;
        voting[1] = true;
        voting[2] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 2, // ADMIN role
            autoWhitelistContracts: true,
            maxFeePerGas: 100 gwei,
            maxPriorityFeePerGas: 2 gwei,
            maxCallGas: 500_000,
            maxVerificationGas: 200_000,
            maxPreVerificationGas: 100_000,
            defaultBudgetCapPerEpoch: 0.5 ether,
            defaultBudgetEpochLen: 7 days
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Budget Full DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg{value: 0.1 ether}(params);

        // Verify budgets for all 3 role hats
        for (uint256 i = 0; i < 3; i++) {
            uint256 hatId = orgRegistry.getRoleHat(orgId, i);
            bytes32 subjectKey = keccak256(abi.encodePacked(uint8(0x01), bytes32(hatId)));
            PaymasterHub.Budget memory budget = paymasterHub.getBudget(orgId, subjectKey);
            assertEq(budget.capPerEpoch, 0.5 ether, "Budget cap should match for each role");
            assertEq(budget.epochLen, 7 days, "Epoch length should be 7 days for each role");
        }

        // Verify fee caps also set
        PaymasterHub.FeeCaps memory feeCaps = paymasterHub.getFeeCaps(orgId);
        assertEq(feeCaps.maxFeePerGas, 100 gwei, "maxFeePerGas should be set");

        // Verify whitelist rules also set
        PaymasterHub.Rule memory rule =
            paymasterHub.getRule(orgId, result.quickJoin, bytes4(keccak256("quickJoinWithUser()")));
        assertTrue(rule.allowed, "QuickJoin should be whitelisted");

        // Verify deposit
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0.1 ether, "Should have 0.1 ETH deposited");
    }

    function testDeployFullOrgNoBudgetsBackwardsCompat() public {
        // Ensure zero budget config doesn't create any budgets
        bytes32 orgId = keccak256("NO-BUDGET-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "No Budget DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.prank(orgOwner);
        deployer.deployFullOrg(params);

        // Verify no budgets set (2 roles)
        for (uint256 i = 0; i < 2; i++) {
            uint256 hatId = orgRegistry.getRoleHat(orgId, i);
            bytes32 subjectKey = keccak256(abi.encodePacked(uint8(0x01), bytes32(hatId)));
            PaymasterHub.Budget memory budget = paymasterHub.getBudget(orgId, subjectKey);
            assertEq(budget.capPerEpoch, 0, "Budget cap should be 0");
            assertEq(budget.epochLen, 0, "Epoch length should be 0");
        }
    }

    function testDeployFullOrgBudgetOnlyConfig() public {
        // Budget is the ONLY config — no fee caps, no whitelist, no ETH
        // This tests the hasBudgets-alone path triggering registerAndConfigureOrg
        bytes32 orgId = keccak256("BUDGET-ONLY-ORG");

        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        OrgDeployer.RoleAssignments memory roleAssignments = _buildDefaultRoleAssignments();
        address[] memory ddTargets = new address[](0);

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: false,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0.05 ether,
            defaultBudgetEpochLen: 12 hours
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Budget Only DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: roleAssignments,
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        // No ETH sent — budgets are the only config
        vm.prank(orgOwner);
        deployer.deployFullOrg(params);

        // Verify budgets set for each role hat
        for (uint256 i = 0; i < 2; i++) {
            uint256 hatId = orgRegistry.getRoleHat(orgId, i);
            bytes32 subjectKey = keccak256(abi.encodePacked(uint8(0x01), bytes32(hatId)));
            PaymasterHub.Budget memory budget = paymasterHub.getBudget(orgId, subjectKey);
            assertEq(budget.capPerEpoch, 0.05 ether, "Budget cap should match");
            assertEq(budget.epochLen, 12 hours, "Epoch length should be 12 hours");
            assertTrue(budget.epochStart > 0, "Epoch start should be initialized");
        }

        // Verify no deposit
        PaymasterHub.OrgFinancials memory financials = paymasterHub.getOrgFinancials(orgId);
        assertEq(financials.deposited, 0, "Should have no deposit");

        // Verify no whitelist rules
        PaymasterHub.Rule memory rule =
            paymasterHub.getRule(orgId, address(1), bytes4(keccak256("quickJoinWithUser()")));
        assertFalse(rule.allowed, "No rules should be set");
    }

    function testRegisterAndConfigureOrgBudgetEpochTooLong() public {
        // Epoch > MAX_EPOCH_LENGTH (365 days) should revert
        bytes32 orgId = keccak256("BUDGET-LONG-EPOCH-ORG");

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256(abi.encodePacked(uint8(0x01), bytes32(uint256(123))));
        uint128[] memory caps = new uint128[](1);
        caps[0] = 0.1 ether;
        uint32[] memory epochLens = new uint32[](1);
        epochLens[0] = 366 days; // Above MAX_EPOCH_LENGTH (365 days)

        PaymasterHub.DeployConfig memory config = PaymasterHub.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: new address[](0),
            ruleSelectors: new bytes4[](0),
            ruleAllowed: new bool[](0),
            ruleMaxCallGasHints: new uint32[](0),
            budgetSubjectKeys: keys,
            budgetCapsPerEpoch: caps,
            budgetEpochLens: epochLens
        });

        vm.prank(address(poaManager));
        vm.expectRevert(abi.encodeWithSignature("InvalidEpochLength()"));
        paymasterHub.registerAndConfigureOrg(orgId, 1, config);
    }

    function testRegisterAndConfigureOrgBudgetArrayMismatch() public {
        // Mismatched budget array lengths should revert
        bytes32 orgId = keccak256("BUDGET-MISMATCH-ORG");

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keccak256(abi.encodePacked(uint8(0x01), bytes32(uint256(123))));
        keys[1] = keccak256(abi.encodePacked(uint8(0x01), bytes32(uint256(456))));
        uint128[] memory caps = new uint128[](1); // Length mismatch!
        caps[0] = 0.1 ether;
        uint32[] memory epochLens = new uint32[](2);
        epochLens[0] = 1 days;
        epochLens[1] = 1 days;

        PaymasterHub.DeployConfig memory config = PaymasterHub.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: new address[](0),
            ruleSelectors: new bytes4[](0),
            ruleAllowed: new bool[](0),
            ruleMaxCallGasHints: new uint32[](0),
            budgetSubjectKeys: keys,
            budgetCapsPerEpoch: caps,
            budgetEpochLens: epochLens
        });

        vm.prank(address(poaManager));
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        paymasterHub.registerAndConfigureOrg(orgId, 1, config);
    }

    function testRegisterAndConfigureOrgBudgetInvalidEpoch() public {
        // Invalid epoch length should revert
        bytes32 orgId = keccak256("BUDGET-EPOCH-ORG");

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256(abi.encodePacked(uint8(0x01), bytes32(uint256(123))));
        uint128[] memory caps = new uint128[](1);
        caps[0] = 0.1 ether;
        uint32[] memory epochLens = new uint32[](1);
        epochLens[0] = 30 minutes; // Below MIN_EPOCH_LENGTH (1 hour)

        PaymasterHub.DeployConfig memory config = PaymasterHub.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: new address[](0),
            ruleSelectors: new bytes4[](0),
            ruleAllowed: new bool[](0),
            ruleMaxCallGasHints: new uint32[](0),
            budgetSubjectKeys: keys,
            budgetCapsPerEpoch: caps,
            budgetEpochLens: epochLens
        });

        vm.prank(address(poaManager));
        vm.expectRevert(abi.encodeWithSignature("InvalidEpochLength()"));
        paymasterHub.registerAndConfigureOrg(orgId, 1, config);
    }

    function testRegisterAndConfigureOrgUnauthorized() public {
        // Non-registrar cannot call registerAndConfigureOrg directly
        bytes32 orgId = keccak256("UNAUTH-ORG");

        PaymasterHub.DeployConfig memory config = PaymasterHub.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: new address[](0),
            ruleSelectors: new bytes4[](0),
            ruleAllowed: new bool[](0),
            ruleMaxCallGasHints: new uint32[](0),
            budgetSubjectKeys: new bytes32[](0),
            budgetCapsPerEpoch: new uint128[](0),
            budgetEpochLens: new uint32[](0)
        });

        // Random address should be rejected
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("NotPoaManager()"));
        paymasterHub.registerAndConfigureOrg(orgId, 1, config);
    }

    function testRegisterAndConfigureOrgRuleArrayMismatch() public {
        // Mismatched rule array lengths should revert
        bytes32 orgId = keccak256("MISMATCH-ORG");

        address[] memory targets = new address[](2);
        targets[0] = address(1);
        targets[1] = address(2);
        bytes4[] memory sels = new bytes4[](1); // Length mismatch!
        sels[0] = bytes4(0x12345678);

        PaymasterHub.DeployConfig memory config = PaymasterHub.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: targets,
            ruleSelectors: sels,
            ruleAllowed: new bool[](2),
            ruleMaxCallGasHints: new uint32[](2),
            budgetSubjectKeys: new bytes32[](0),
            budgetCapsPerEpoch: new uint128[](0),
            budgetEpochLens: new uint32[](0)
        });

        // Call as poaManager (authorized)
        vm.prank(address(poaManager));
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        paymasterHub.registerAndConfigureOrg(orgId, 1, config);
    }

    /*══════════════════════════════════════════════════════════════════════════
     *  INTEGRATION: Full passkey-enabled org deployment + onboarding
     *  Tests the complete real-world flow:
     *   1. Deploy org with passkeyEnabled=true (mirrors frontend)
     *   2. Verify factory wiring on QuickJoin + AccountRegistry
     *   3. Call registerAndQuickJoinWithPasskey and verify it gets past
     *      PasskeyFactoryNotSet (fails later on signature, which is expected)
     *   4. Validate paymaster batch UserOp with the onboarding call
     *══════════════════════════════════════════════════════════════════════════*/

    function _deployPasskeyOrg() internal returns (OrgDeployer.DeploymentResult memory result, bytes32 orgId) {
        orgId = keccak256("PASSKEY-INTEGRATION-ORG");

        string[] memory names = new string[](2);
        names[0] = "MEMBER";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "";
        images[1] = "";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        OrgDeployer.PaymasterConfig memory pmConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: 1,
            autoWhitelistContracts: true,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 1 ether,
            defaultBudgetEpochLen: 1 days
        });

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "Passkey Integration DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: true,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmConfig,
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        vm.deal(orgOwner, 1 ether);
        vm.prank(orgOwner);
        result = deployer.deployFullOrg{value: 0.5 ether}(params);
    }

    /// @notice Deploying an org with passkeyEnabled=true must succeed and wire factories
    function testPasskeyOrgDeployment_FactoriesWired() public {
        (OrgDeployer.DeploymentResult memory result,) = _deployPasskeyOrg();

        // QuickJoin must have universalFactory set
        address qjFactory = address(QuickJoin(result.quickJoin).universalFactory());
        assertTrue(qjFactory != address(0), "QuickJoin.universalFactory should be set");
        assertEq(qjFactory, address(universalPasskeyFactory), "QuickJoin factory should match deployed factory");

        // GlobalAccountRegistry must have passkeyFactory set
        address regFactory = UniversalAccountRegistry(accountRegProxy).passkeyFactory();
        assertTrue(regFactory != address(0), "Registry.passkeyFactory should be set");
        assertEq(regFactory, address(universalPasskeyFactory), "Registry factory should match deployed factory");
    }

    /// @notice registerAndQuickJoinWithPasskey must NOT revert with PasskeyFactoryNotSet
    function testPasskeyOnboarding_NoPasskeyFactoryNotSet() public {
        (OrgDeployer.DeploymentResult memory result,) = _deployPasskeyOrg();

        // Build a registerAndQuickJoinWithPasskey call with dummy passkey data.
        // It will revert (bad signature), but must NOT revert with PasskeyFactoryNotSet.
        QuickJoin.PasskeyEnrollment memory passkey = QuickJoin.PasskeyEnrollment({
            credentialId: keccak256("test-credential"),
            publicKeyX: bytes32(uint256(0x1234)),
            publicKeyY: bytes32(uint256(0x5678)),
            salt: 0
        });

        WebAuthnLib.WebAuthnAuth memory auth = WebAuthnLib.WebAuthnAuth({
            authenticatorData: hex"00",
            clientDataJSON: hex"00",
            challengeIndex: 0,
            typeIndex: 0,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        // The call should fail — but with InvalidSigner or InvalidNonce, NOT PasskeyFactoryNotSet
        bytes memory callData = abi.encodeWithSelector(
            QuickJoin.registerAndQuickJoinWithPasskey.selector,
            passkey,
            "testuser",
            block.timestamp + 1 hours, // valid deadline
            uint256(0), // nonce
            auth
        );

        // Call QuickJoin and capture the revert
        (bool success, bytes memory returnData) = result.quickJoin.call(callData);
        assertFalse(success, "Should revert (bad signature)");

        // Extract the error selector from the revert data
        bytes4 errorSelector;
        if (returnData.length >= 4) {
            errorSelector = bytes4(returnData);
        }

        // Must NOT be PasskeyFactoryNotSet (0xc832858d)
        assertTrue(
            errorSelector != QuickJoin.PasskeyFactoryNotSet.selector,
            "Must not revert with PasskeyFactoryNotSet - factory wiring is broken"
        );
        assertTrue(
            errorSelector != UniversalAccountRegistry.PasskeyFactoryNotSet.selector,
            "Must not revert with PasskeyFactoryNotSet from registry - passkeyFactory not set"
        );
    }

    /// @notice Paymaster validates batch UserOp with passkey onboarding + claimVouchedHat
    function testPasskeyOnboarding_PaymasterBatchValidation() public {
        (OrgDeployer.DeploymentResult memory result, bytes32 orgId) = _deployPasskeyOrg();

        uint256 memberHatId = orgRegistry.getRoleHat(orgId, 0);
        assertTrue(memberHatId != 0, "member hat should exist");

        // Verify autowhitelist rules
        bytes4 rqjpSel = bytes4(
            keccak256(
                "registerAndQuickJoinWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32))"
            )
        );
        PaymasterHub.Rule memory rule = paymasterHub.getRule(orgId, result.quickJoin, rqjpSel);
        assertTrue(rule.allowed, "registerAndQuickJoinWithPasskey should be whitelisted");

        bytes4 cvhSel = bytes4(keccak256("claimVouchedHat(uint256)"));
        rule = paymasterHub.getRule(orgId, result.eligibilityModule, cvhSel);
        assertTrue(rule.allowed, "claimVouchedHat should be whitelisted");

        // Build executeBatch callData
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);

        targets[0] = result.quickJoin;
        values[0] = 0;
        datas[0] = abi.encodeWithSelector(
            rqjpSel,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            uint256(0),
            "alice",
            uint256(0),
            uint256(0),
            "",
            "",
            uint256(0),
            uint256(0),
            bytes32(0),
            bytes32(0)
        );

        targets[1] = result.eligibilityModule;
        values[1] = 0;
        datas[1] = abi.encodeWithSelector(cvhSel, memberHatId);

        bytes memory batchCallData = abi.encodeWithSelector(bytes4(0x47e1da2a), targets, values, datas);

        // Build paymasterAndData (SUBJECT_TYPE_HAT)
        bytes memory paymasterAndData = abi.encodePacked(
            address(paymasterHub),
            uint128(200_000),
            uint128(100_000),
            uint8(1), // version
            orgId,
            uint8(0x01), // SUBJECT_TYPE_HAT
            bytes32(memberHatId),
            uint32(0), // ruleIdGeneric
            uint64(0) // mailboxCommit8
        );

        // Build PackedUserOperation
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(0xBEEF1234),
            nonce: 0,
            initCode: hex"01",
            callData: batchCallData,
            accountGasLimits: UserOpLib.packAccountGasLimits(500_000, 500_000),
            preVerificationGas: 100_000,
            gasFees: UserOpLib.packGasFees(1, 1),
            paymasterAndData: paymasterAndData,
            signature: ""
        });

        // Validate paymaster
        vm.prank(ENTRY_POINT_V07);
        (bytes memory context, uint256 validationData) =
            paymasterHub.validatePaymasterUserOp(userOp, keccak256("test-op-hash"), 100_000);

        assertEq(validationData, 0, "validation should succeed");
        assertTrue(context.length > 0, "context should be populated");
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VOUCHING BOOTSTRAP: defaults.eligible=false + combineWithHierarchy=true
    //  Tests the recommended 2-tier org config that solves the chicken-and-egg
    //  problem without governance votes:
    //    - Deployer gets roles automatically (per-address eligibility set by HatsTreeSetup)
    //    - Everyone else MUST be vouched (defaults.eligible=false enforces this)
    //    - Attackers who call QuickJoin directly get hat minted but can't wear it
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Full E2E test: deploy org with vouching, verify deployer bootstrap, verify
    ///         non-vouched users are blocked, verify vouch flow enables membership.
    function testVouchingBootstrapWithDefaultsEligibleFalse() public {
        // ─── 1. Build org config with vouching enabled at deploy time ───
        vm.startPrank(orgOwner);

        // Two tiers: MEMBER (index 0) and ADMIN (index 1)
        RoleConfigStructs.RoleConfig[] memory roles = new RoleConfigStructs.RoleConfig[](2);
        address[] memory noWearers = new address[](0);

        // Role 0: MEMBER — needs 1 vouch from another MEMBER, defaults NOT eligible
        roles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "ipfs://member",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true,
                quorum: 1,
                voucherRoleIndex: 0, // MEMBER vouches for MEMBER
                combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 1}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, // Deployer gets MEMBER
                additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        // Role 1: ADMIN — needs 1 vouch from another ADMIN, defaults NOT eligible
        roles[1] = RoleConfigStructs.RoleConfig({
            name: "ADMIN",
            image: "ipfs://admin",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true,
                quorum: 1,
                voucherRoleIndex: 1, // ADMIN vouches for ADMIN
                combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, // Deployer gets ADMIN
                additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);
        address[] memory ddTargets = new address[](0);

        bytes32 vouchOrgId = keccak256("VOUCH-BOOTSTRAP-ORG");

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: vouchOrgId,
            orgName: "Vouch Bootstrap DAO",
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
            hybridClasses: classes,
            ddInitialTargets: ddTargets,
            roles: roles,
            roleAssignments: OrgDeployer.RoleAssignments({
                quickJoinRolesBitmap: 1, // Only MEMBER via QuickJoin
                tokenMemberRolesBitmap: 3,
                tokenApproverRolesBitmap: 2,
                taskCreatorRolesBitmap: 2,
                educationCreatorRolesBitmap: 2,
                educationMemberRolesBitmap: 1,
                hybridProposalCreatorRolesBitmap: 2,
                ddVotingRolesBitmap: 1,
                ddCreatorRolesBitmap: 2
            }),
            metadataAdminRoleIndex: 1, // ADMIN manages metadata
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        // Get module addresses and hat IDs
        address eligMod = orgRegistry.getOrgContract(vouchOrgId, ModuleTypes.ELIGIBILITY_MODULE_ID);
        uint256 memberHat = orgRegistry.getRoleHat(vouchOrgId, 0);
        uint256 adminHat = orgRegistry.getRoleHat(vouchOrgId, 1);
        address exec = result.executor;

        // ─── 2. Verify deployer is eligible and wears both hats ───

        // Deployer has specific wearer rules set by HatsTreeSetup
        _assertEligibilityStatus(eligMod, orgOwner, memberHat, true, true, "Deployer MEMBER eligibility");
        _assertEligibilityStatus(eligMod, orgOwner, adminHat, true, true, "Deployer ADMIN eligibility");

        // Deployer actually wears the hats
        _assertWearingHat(orgOwner, memberHat, true, "Deployer wears MEMBER");
        _assertWearingHat(orgOwner, adminHat, true, "Deployer wears ADMIN");

        // ─── 3. Verify vouching is correctly configured ───

        assertTrue(EligibilityModule(eligMod).isVouchingEnabled(memberHat), "MEMBER vouching should be enabled");
        assertTrue(EligibilityModule(eligMod).combinesWithHierarchy(memberHat), "MEMBER should combine with hierarchy");
        assertTrue(EligibilityModule(eligMod).isVouchingEnabled(adminHat), "ADMIN vouching should be enabled");
        assertTrue(EligibilityModule(eligMod).combinesWithHierarchy(adminHat), "ADMIN should combine with hierarchy");

        // ─── 4. Verify non-vouched user is NOT eligible (defaults.eligible=false) ───

        address attacker = address(0xA7AC);
        _assertEligibilityStatus(eligMod, attacker, memberHat, false, true, "Attacker NOT eligible before QuickJoin");

        // Attacker registers a username so QuickJoin doesn't revert on username check
        vm.prank(attacker);
        UniversalAccountRegistry(accountRegProxy).registerAccount("attacker");

        // Attacker calls QuickJoin directly (bypassing frontend vouch check)
        // Hats Protocol checks eligibility during mintHat and REVERTS — attacker can't even get the hat
        vm.prank(attacker);
        vm.expectRevert(); // NotEligible() from Hats Protocol
        QuickJoin(result.quickJoin).quickJoinWithUser();

        // Attacker still not eligible and does not wear the hat
        _assertEligibilityStatus(
            eligMod, attacker, memberHat, false, true, "Attacker NOT eligible after QuickJoin attempt"
        );
        _assertWearingHat(attacker, memberHat, false, "Attacker does NOT wear MEMBER");

        // ─── 5. Verify legitimate vouch flow works ───

        address newMember = address(0xBEE);

        // Set up join times for vouching (3+ days ago)
        _setupUserForVouching(eligMod, exec, orgOwner);
        _setupUserForVouching(eligMod, exec, newMember);

        // newMember is NOT eligible initially
        _assertEligibilityStatus(eligMod, newMember, memberHat, false, true, "New member NOT eligible initially");

        // Deployer (who wears MEMBER hat) vouches for newMember
        _vouchFor(orgOwner, eligMod, newMember, memberHat);

        // Now newMember IS eligible (quorum=1, got 1 vouch)
        _assertEligibilityStatus(eligMod, newMember, memberHat, true, true, "New member eligible after vouch");

        // newMember claims the hat
        vm.prank(newMember);
        EligibilityModule(eligMod).claimVouchedHat(memberHat);
        _assertWearingHat(newMember, memberHat, true, "New member wears MEMBER after claim");

        // ─── 6. Verify the vouched member can vouch for others (chain of trust) ───

        address secondMember = address(0xCEE);
        _setupUserForVouching(eligMod, exec, secondMember);

        // newMember vouches for secondMember
        _vouchFor(newMember, eligMod, secondMember, memberHat);
        _assertEligibilityStatus(eligMod, secondMember, memberHat, true, true, "Second member eligible via chain");

        // ─── 7. Verify ADMIN tier vouch works separately ───

        address newAdmin = address(0xADD);
        _setupUserForVouching(eligMod, exec, newAdmin);

        // newAdmin is NOT eligible for ADMIN role
        _assertEligibilityStatus(eligMod, newAdmin, adminHat, false, true, "New admin NOT eligible initially");

        // Deployer (wears ADMIN) vouches for newAdmin on ADMIN hat
        _vouchFor(orgOwner, eligMod, newAdmin, adminHat);
        _assertEligibilityStatus(eligMod, newAdmin, adminHat, true, true, "New admin eligible after vouch");

        // Verify a MEMBER cannot vouch for ADMIN (wrong hat)
        address fakeAdmin = address(0xFAD);
        _setupUserForVouching(eligMod, exec, fakeAdmin);
        vm.expectRevert();
        vm.prank(newMember);
        EligibilityModule(eligMod).vouchFor(fakeAdmin, adminHat);

        // ─── 8. Verify deployer can actually DO admin actions (the real test) ───
        // This is what breaks when eligibility is wrong — hat appears assigned but
        // isWearerOfHat returns false, so createProject/createProposal revert.

        // 8a. Deployer creates a project on TaskManager (requires taskCreator hat = ADMIN)
        TaskManager tm = TaskManager(result.taskManager);
        address[] memory managers = new address[](0);
        uint256[] memory emptyHats = new uint256[](0);

        // This call will revert with NotCreator() if deployer isn't a real hat wearer
        vm.prank(orgOwner);
        tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: abi.encode("Bootstrap Project"),
                metadataHash: bytes32(0),
                cap: 100 ether,
                managers: managers,
                createHat: 0,
                claimHat: 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );
        // If we reach here, deployer successfully created a project (hat is functional)

        // 8b. Deployer creates a governance proposal (requires hybridProposalCreator hat = ADMIN)
        HybridVoting hybrid = HybridVoting(result.hybridVoting);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);
        uint256[] memory hatIds = new uint256[](0);

        vm.prank(orgOwner);
        hybrid.createProposal(
            abi.encode("Test Proposal"),
            bytes32(0),
            60, // 60 minutes
            2, // 2 options (for/against)
            batches,
            hatIds
        );
        // If we get here without reverting, the deployer successfully exercised admin powers
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VOUCH-CLAIM: claimHatsWithUser mints specific hats for vouched users
    // ════════════════════════════════════════════════════════════════════════

    function testClaimHatsWithVouching() public {
        // Deploy org with vouching: defaults.eligible=false, combineWithHierarchy=true
        vm.startPrank(orgOwner);

        RoleConfigStructs.RoleConfig[] memory roles = new RoleConfigStructs.RoleConfig[](2);
        address[] memory noWearers = new address[](0);

        // Role 0: MEMBER
        roles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true, quorum: 1, voucherRoleIndex: 1, combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 1}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        // Role 1: EXECUTIVE — vouched by other executives
        roles[1] = RoleConfigStructs.RoleConfig({
            name: "EXECUTIVE",
            image: "",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true, quorum: 1, voucherRoleIndex: 1, combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true})
        });

        bytes32 claimOrgId = keccak256("CLAIM-HATS-ORG");

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: claimOrgId,
            orgName: "Claim Hats DAO",
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: roles,
            roleAssignments: OrgDeployer.RoleAssignments({
                quickJoinRolesBitmap: 1,
                tokenMemberRolesBitmap: 3,
                tokenApproverRolesBitmap: 2,
                taskCreatorRolesBitmap: 2,
                educationCreatorRolesBitmap: 2,
                educationMemberRolesBitmap: 1,
                hybridProposalCreatorRolesBitmap: 2,
                ddVotingRolesBitmap: 1,
                ddCreatorRolesBitmap: 2
            }),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            capabilityHats: new RoleConfigStructs.CapabilityHatConfig[](0),
            roleBundles: new RoleConfigStructs.RoleBundleConfig[](0),
            taskManagerPerms: _emptyTaskManagerPerms()
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();

        address eligMod = orgRegistry.getOrgContract(claimOrgId, ModuleTypes.ELIGIBILITY_MODULE_ID);
        uint256 memberHat = orgRegistry.getRoleHat(claimOrgId, 0);
        uint256 execHat = orgRegistry.getRoleHat(claimOrgId, 1);
        address exec = result.executor;
        address qj = result.quickJoin;

        // Deployer wears both hats (bootstrap via HatsTreeSetup)
        _assertWearingHat(orgOwner, execHat, true, "Deployer wears EXECUTIVE");

        // ─── Test 1: Vouched user claims Executive hat via claimHatsWithUser ───

        address candidate = address(0xCAFE);
        _setupUserForVouching(eligMod, exec, orgOwner);
        _setupUserForVouching(eligMod, exec, candidate);

        // Register candidate username (required by claimHatsWithUser)
        vm.prank(candidate);
        UniversalAccountRegistry(accountRegProxy).registerAccount("candidate");

        // Deployer vouches for candidate on Executive hat
        _vouchFor(orgOwner, eligMod, candidate, execHat);

        // Candidate is now eligible but doesn't wear the hat
        _assertEligibilityStatus(eligMod, candidate, execHat, true, true, "Candidate eligible after vouch");
        _assertWearingHat(candidate, execHat, false, "Candidate doesn't wear hat yet");

        // Candidate calls claimHatsWithUser with the Executive hat
        uint256[] memory claimIds = new uint256[](1);
        claimIds[0] = execHat;
        vm.prank(candidate);
        QuickJoin(qj).claimHatsWithUser(claimIds);

        // Candidate now wears Executive hat
        _assertWearingHat(candidate, execHat, true, "Candidate wears EXECUTIVE after claim");

        // ─── Test 2: Non-vouched user gets NotEligible ───

        address attacker = address(0xBAD1);
        vm.prank(attacker);
        UniversalAccountRegistry(accountRegProxy).registerAccount("attacker");

        uint256[] memory attackIds = new uint256[](1);
        attackIds[0] = execHat;
        vm.prank(attacker);
        vm.expectRevert();
        QuickJoin(qj).claimHatsWithUser(attackIds);

        // ─── Test 3: Empty claimHatIds succeeds (no-op) ───

        address emptyUser = address(0xE001);
        vm.prank(emptyUser);
        UniversalAccountRegistry(accountRegProxy).registerAccount("emptyuser");

        uint256[] memory emptyIds = new uint256[](0);
        vm.prank(emptyUser);
        QuickJoin(qj).claimHatsWithUser(emptyIds);

        // ─── Test 4: Vouched user claims multiple hats at once ───

        address multiUser = address(0xABC1);
        _setupUserForVouching(eligMod, exec, multiUser);
        vm.prank(multiUser);
        UniversalAccountRegistry(accountRegProxy).registerAccount("multiuser");

        // Vouch for both Member and Executive
        _vouchFor(orgOwner, eligMod, multiUser, memberHat);
        _vouchFor(orgOwner, eligMod, multiUser, execHat);

        uint256[] memory multiIds = new uint256[](2);
        multiIds[0] = memberHat;
        multiIds[1] = execHat;
        vm.prank(multiUser);
        QuickJoin(qj).claimHatsWithUser(multiIds);

        _assertWearingHat(multiUser, memberHat, true, "Multi-user wears MEMBER");
        _assertWearingHat(multiUser, execHat, true, "Multi-user wears EXECUTIVE");
    }
}
