// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @title DeployerTest — authority-native new-org deployment
/// @notice Exercises the full OrgDeployer path end to end: Executor → MembershipAuthority (born
///         initialized + paused, seeded from the deploy params) → QuickJoin/ParticipationToken →
///         functional modules → voting → paymaster registration → module repoint + genesis
///         memberships + unpause.
/// @dev No fork: Access v2 orgs never read Hats Protocol, so a MockHats pointer is all the Executor
///      and the shared registries need. Doubles as the shared infra base for ZkEmailOrgFlow.

import "forge-std/Test.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {PoaManager} from "../src/PoaManager.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../src/OrgDeployer.sol";
import {GovernanceFactory} from "../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../src/factories/AccessFactory.sol";
import {ModulesFactory} from "../src/factories/ModulesFactory.sol";
import {Executor, IExecutor} from "../src/Executor.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PasskeyAccount} from "../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../src/PasskeyAccountFactory.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2Ids} from "../src/libs/AccessV2Ids.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import {RoleConfigStructs} from "../src/libs/RoleConfigStructs.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {IHybridVotingInit} from "../src/libs/ModuleDeploymentLib.sol";
import {DefaultGlobalRules} from "../script/helpers/DefaultGlobalRules.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract DeployerTest is Test {
    /*–––– infra ––––*/
    ImplementationRegistry implRegistry;
    PoaManager poaManager;
    OrgRegistry orgRegistry;
    OrgDeployer deployer;
    GovernanceFactory governanceFactory;
    AccessFactory accessFactory;
    ModulesFactory modulesFactory;
    PaymasterHub paymasterHub;
    PasskeyAccountFactory universalPasskeyFactory;
    MockHats mockHats;

    /*–––– addresses ––––*/
    address public constant poaAdmin = address(1);
    address public constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant orgOwner = address(2);
    address public constant POA_GUARDIAN = address(0x600D);
    address public constant voter1 = address(3);
    address public constant voter2 = address(4);

    /*–––– ids ––––*/
    bytes32 public constant ORG_ID = keccak256("AUTO-UPGRADE-ORG");

    address accountRegProxy;

    /// @dev Role indices used by the default two-role fixture.
    uint256 internal constant ROLE_DEFAULT = 0;
    uint256 internal constant ROLE_EXECUTIVE = 1;

    /*══════════════════════════════════════════ SET-UP ══════════════════════════════════════════*/

    function setUp() public virtual {
        mockHats = new MockHats();
        // PaymasterHub.initialize requires the EntryPoint to have code; nothing here calls into it.
        vm.etch(ENTRY_POINT_V07, hex"fe");

        ImplementationRegistry implRegistryImpl = new ImplementationRegistry();

        vm.startPrank(poaAdmin);

        poaManager = new PoaManager(address(0));

        OrgRegistry orgRegistryImpl = new OrgRegistry();
        OrgDeployer deployerImpl = new OrgDeployer();

        poaManager.addContractType("ImplementationRegistry", address(implRegistryImpl));
        address implRegBeacon = poaManager.getBeaconById(keccak256("ImplementationRegistry"));
        implRegistry = ImplementationRegistry(
            address(new BeaconProxy(implRegBeacon, abi.encodeWithSignature("initialize(address)", poaAdmin)))
        );
        poaManager.updateImplRegistry(address(implRegistry));
        implRegistry.registerImplementation("ImplementationRegistry", "v1", address(implRegistryImpl), true);
        implRegistry.transferOwnership(address(poaManager));

        poaManager.addContractType("OrgRegistry", address(orgRegistryImpl));
        poaManager.addContractType("OrgDeployer", address(deployerImpl));

        address orgRegBeacon = poaManager.getBeaconById(keccak256("OrgRegistry"));
        address deployerBeacon = poaManager.getBeaconById(keccak256("OrgDeployer"));

        orgRegistry = OrgRegistry(
            address(
                new BeaconProxy(
                    orgRegBeacon, abi.encodeWithSignature("initialize(address,address)", poaAdmin, address(mockHats))
                )
            )
        );

        governanceFactory = new GovernanceFactory();
        accessFactory = new AccessFactory();
        modulesFactory = new ModulesFactory();

        PaymasterHub paymasterHubImpl = new PaymasterHub();
        poaManager.addContractType("PaymasterHub", address(paymasterHubImpl));
        address paymasterHubBeacon = poaManager.getBeaconById(keccak256("PaymasterHub"));
        paymasterHub = PaymasterHub(
            payable(address(
                    new BeaconProxy(
                        paymasterHubBeacon,
                        abi.encodeWithSignature(
                            "initialize(address,address,address)",
                            ENTRY_POINT_V07,
                            address(mockHats),
                            address(poaManager)
                        )
                    )
                ))
        );

        deployer = OrgDeployer(
            address(
                new BeaconProxy(
                    deployerBeacon,
                    abi.encodeWithSignature(
                        "initialize(address,address,address,address,address,address,address)",
                        address(governanceFactory),
                        address(accessFactory),
                        address(modulesFactory),
                        address(poaManager),
                        address(orgRegistry),
                        address(mockHats),
                        address(paymasterHub)
                    )
                )
            )
        );

        vm.stopPrank();
        vm.prank(address(poaManager));
        paymasterHub.setOrgRegistrar(address(deployer));
        vm.startPrank(poaAdmin);

        orgRegistry.transferOwnership(address(deployer));

        /*–– register per-org module implementations ––*/
        poaManager.addContractType("Executor", address(new Executor()));
        poaManager.addContractType("MembershipAuthority", address(new MembershipAuthority()));
        poaManager.addContractType("HybridVoting", address(new HybridVoting()));
        poaManager.addContractType("DirectDemocracyVoting", address(new DirectDemocracyVoting()));
        poaManager.addContractType("QuickJoin", address(new QuickJoin()));
        poaManager.addContractType("ParticipationToken", address(new ParticipationToken()));
        poaManager.addContractType("TaskManager", address(new TaskManager()));
        poaManager.addContractType("EducationHub", address(new EducationHub()));
        poaManager.addContractType("PaymentManager", address(new PaymentManager()));
        poaManager.addContractType("UniversalAccountRegistry", address(new UniversalAccountRegistry()));

        address accRegBeacon = poaManager.getBeaconById(keccak256("UniversalAccountRegistry"));
        accountRegProxy =
            address(new BeaconProxy(accRegBeacon, abi.encodeWithSignature("initialize(address)", poaAdmin)));

        /*–– passkey infrastructure (mirrors DeployInfrastructure.s.sol) ––*/
        poaManager.addContractType("PasskeyAccount", address(new PasskeyAccount()));
        poaManager.addContractType("PasskeyAccountFactory", address(new PasskeyAccountFactory()));
        universalPasskeyFactory = PasskeyAccountFactory(
            address(
                new BeaconProxy(
                    poaManager.getBeaconById(keccak256("PasskeyAccountFactory")),
                    abi.encodeWithSignature(
                        "initialize(address,address,address,uint48)",
                        address(poaManager),
                        poaManager.getBeaconById(keccak256("PasskeyAccount")),
                        POA_GUARDIAN,
                        uint48(7 days)
                    )
                )
            )
        );
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setUniversalPasskeyFactory(address)", address(universalPasskeyFactory))
        );
        UniversalAccountRegistry(accountRegProxy).setPasskeyFactory(address(universalPasskeyFactory));

        vm.stopPrank();
    }

    /*══════════════════════════════════════════ TESTS ══════════════════════════════════════════*/

    function testFullOrgDeployment_registersEveryModule() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);

        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.EXECUTOR_ID), r.executor, "executor");
        assertEq(
            orgRegistry.getOrgContract(ORG_ID, ModuleTypes.MEMBERSHIP_AUTHORITY_ID),
            r.membershipAuthority,
            "authority registered in its deploy tx"
        );
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.QUICK_JOIN_ID), r.quickJoin, "quickJoin");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.PARTICIPATION_TOKEN_ID), r.participationToken, "token");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.TASK_MANAGER_ID), r.taskManager, "taskManager");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.EDUCATION_HUB_ID), r.educationHub, "educationHub");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.PAYMENT_MANAGER_ID), r.paymentManager, "paymentManager");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.HYBRID_VOTING_ID), r.hybridVoting, "hybridVoting");
        assertEq(orgRegistry.getOrgContract(ORG_ID, ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID), r.directDemocracyVoting);

        // No Hats tree is created: nothing registers an EligibilityModule or a ToggleModule.
        // `proxyOf` is the non-reverting probe — `getOrgContract` reverts ContractUnknown on a miss.
        assertEq(orgRegistry.proxyOf(ORG_ID, ModuleTypes.ELIGIBILITY_MODULE_ID), address(0), "no EM");
        assertEq(orgRegistry.proxyOf(ORG_ID, ModuleTypes.TOGGLE_MODULE_ID), address(0), "no toggle");
    }

    /// @notice Subject ids are derivable from the authority address alone — the deployer never reads
    ///         them back, so a drift between allocation order and derivation must fail loudly here.
    function testSubjectIds_derivedFromAuthorityAddress() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        address a = r.membershipAuthority;

        assertEq(orgRegistry.getTopHat(ORG_ID), AccessV2Ids.newSubjectId(a, 1), "admin subject is index 0");
        assertEq(orgRegistry.getRoleHat(ORG_ID, ROLE_DEFAULT), AccessV2Ids.newSubjectId(a, 2), "role 0");
        assertEq(orgRegistry.getRoleHat(ORG_ID, ROLE_EXECUTIVE), AccessV2Ids.newSubjectId(a, 3), "role 1");
        // Groups follow the roles, so the Executives group is the third allocated subject.
        assertEq(orgRegistry.getRoleHat(ORG_ID, 2), AccessV2Ids.newSubjectId(a, 4), "group 0");

        // Every new-style id is below the Hats namespace floor and self-routes to this authority.
        assertLt(AccessV2Ids.newSubjectId(a, 2), AccessV2Ids.HATS_NAMESPACE_FLOOR);
        assertEq(AccessV2Ids.embeddedAuthority(AccessV2Ids.newSubjectId(a, 2)), a);
    }

    function testGenesisSeed_subjectShape() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        IMembershipAuthority auth = IMembershipAuthority(r.membershipAuthority);

        assertEq(auth.subjectCount(), 4, "admin + 2 roles + 1 group");

        IMembershipAuthority.SubjectInfo memory admin = auth.getSubject(_adminSubject());
        assertEq(admin.name, "ADMIN");
        assertEq(uint8(admin.kind), uint8(AccessV2Types.SubjectKind.Role));

        address stranger = address(0xDEAD);
        IMembershipAuthority.SubjectInfo memory open = auth.getSubject(_roleSubject(ROLE_DEFAULT));
        assertEq(open.name, "DEFAULT");
        assertTrue(auth.eligible(_roleSubject(ROLE_DEFAULT), stranger), "the QuickJoin role is default-ALLOW");

        IMembershipAuthority.SubjectInfo memory titled = auth.getSubject(_roleSubject(ROLE_EXECUTIVE));
        assertEq(titled.name, "EXECUTIVE");
        assertFalse(auth.eligible(_roleSubject(ROLE_EXECUTIVE), stranger), "titled roles are deny-by-default");
        assertEq(titled.maxMembers, 5, "cap carried from the deploy params");

        IMembershipAuthority.SubjectInfo memory group = auth.getSubject(_groupSubject(0));
        assertEq(group.name, "Executives");
        assertEq(uint8(group.kind), uint8(AccessV2Types.SubjectKind.Group));
        uint256[] memory members = auth.groupMemberRoles(_groupSubject(0));
        assertEq(members.length, 1);
        assertEq(members[0], _roleSubject(ROLE_EXECUTIVE));
    }

    function testGenesisSeed_permRowsMatchRoleAssignments() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        IMembershipAuthority auth = IMembershipAuthority(r.membershipAuthority);

        uint256 openRole = _roleSubject(ROLE_DEFAULT);
        uint256 execRole = _roleSubject(ROLE_EXECUTIVE);

        _assertPerm(auth, openRole, AccessV2PermKeys.QJ_AUTOJOIN, true);
        _assertPerm(auth, openRole, AccessV2PermKeys.PT_MEMBER, true);
        _assertPerm(auth, openRole, AccessV2PermKeys.EDU_MEMBER, true);
        _assertPerm(auth, openRole, AccessV2PermKeys.DD_VOTE, true);
        _assertPerm(auth, openRole, AccessV2PermKeys.DD_CREATE, false);

        _assertPerm(auth, execRole, AccessV2PermKeys.PT_APPROVE, true);
        _assertPerm(auth, execRole, AccessV2PermKeys.EDU_CREATE, true);
        _assertPerm(auth, execRole, AccessV2PermKeys.HV_CREATE, true);
        _assertPerm(auth, execRole, AccessV2PermKeys.DD_CREATE, true);
        _assertPerm(auth, execRole, AccessV2PermKeys.QJ_AUTOJOIN, false);

        // metadataAdminRoleIndex == EXECUTIVE in the fixture.
        _assertPerm(auth, execRole, AccessV2PermKeys.SUBJECT_RENAME, true);
    }

    function testGenesisMemberships_andUnpause() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        IMembershipAuthority auth = IMembershipAuthority(r.membershipAuthority);

        assertFalse(auth.paused(), "unpaused at the end of the deploy");
        assertTrue(auth.isMember(_adminSubject(), r.executor), "Executor holds the ADMIN subject");
        assertTrue(auth.isMember(_roleSubject(ROLE_DEFAULT), orgOwner), "founder in the open role");
        assertTrue(auth.isMember(_roleSubject(ROLE_EXECUTIVE), orgOwner), "founder in the titled role");
        // Membership on a deny-default subject only holds because the seed wrote an eligibility source.
        assertEq(uint8(auth.getRule(_roleSubject(ROLE_EXECUTIVE), orgOwner).kind), uint8(AccessV2Types.RuleKind.Grant));
        assertTrue(auth.getRule(_roleSubject(ROLE_EXECUTIVE), orgOwner).delegable, "seeded grants are delegable");
        // Group membership is derived, never seeded.
        assertTrue(auth.isMember(_groupSubject(0), orgOwner), "founder derives the Executives group");
    }

    function testModulesRepointedToAuthority() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        address a = r.membershipAuthority;

        assertEq(QuickJoin(r.quickJoin).membershipAuthority(), a, "quickJoin");
        assertEq(ParticipationToken(r.participationToken).membershipAuthority(), a, "token");
        // TaskManager exposes its pointer through the generic config getter (key 12).
        assertEq(abi.decode(TaskManager(r.taskManager).getLensData(12, ""), (address)), a, "taskManager");
        assertEq(EducationHub(r.educationHub).membershipAuthority(), a, "educationHub");
        assertEq(DirectDemocracyVoting(r.directDemocracyVoting).membershipAuthority(), a, "dd");
        assertEq(HybridVoting(r.hybridVoting).membershipAuthority(), a, "hv");
        // On the Executor the setter repoints `hats` itself.
        assertEq(address(Executor(payable(r.executor)).hats()), a, "executor hats repointed");
    }

    /// @notice A fresh user self-serves into the open role through QuickJoin, which resolves its
    ///         auto-join set from the QJ_AUTOJOIN perm rows rather than a stored hat list.
    function testQuickJoin_autoJoinsThroughAuthority() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        IMembershipAuthority auth = IMembershipAuthority(r.membershipAuthority);

        _join(r, voter1, "voter-one");

        assertTrue(auth.isMember(_roleSubject(ROLE_DEFAULT), voter1), "joined the open role");
        assertFalse(auth.isMember(_roleSubject(ROLE_EXECUTIVE), voter1), "not the titled role");
        assertEq(auth.balanceOf(voter1, _roleSubject(ROLE_DEFAULT)), 1, "ERC-1155 view mirrors membership");
    }

    /// @notice The DD electorate resolves through hasPerm(DD_VOTE) and the activation gate, so a
    ///         member who joined before the poll can vote and one who joined after cannot.
    function testDirectDemocracy_voteThroughAuthority() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        DirectDemocracyVoting dd = DirectDemocracyVoting(r.directDemocracyVoting);

        _join(r, voter1, "early");
        vm.warp(block.timestamp + 1);

        vm.prank(orgOwner); // EXECUTIVE holds DD_CREATE
        dd.createProposal(bytes("poll"), bytes32(0), 60, 2, new IExecutor.Call[][](2), new uint256[](0));

        vm.warp(block.timestamp + 1);
        _join(r, voter2, "late");

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;

        vm.prank(voter1);
        dd.vote(0, idxs, weights);

        vm.prank(voter2);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.vote(0, idxs, weights);
    }

    /// @notice HybridVoting classes are seeded with subject ids, so the authority arm resolves class
    ///         membership straight from `classesSnapshot` — no `setClassSubject` proposal is needed
    ///         for a new org, and the activation gate still excludes a post-proposal joiner.
    function testHybridVoting_voteThroughAuthority() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        HybridVoting hv = HybridVoting(payable(r.hybridVoting));

        _join(r, voter1, "hv-early");
        vm.warp(block.timestamp + 1);

        vm.prank(orgOwner); // EXECUTIVE holds HV_CREATE
        hv.createProposal(bytes("budget"), bytes32(0), 60, 2, new IExecutor.Call[][](2), new uint256[](0));

        vm.warp(block.timestamp + 1);
        _join(r, voter2, "hv-late");

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;

        vm.prank(voter1);
        hv.vote(0, idxs, weights);

        // voter2's DEFAULT membership activated after creation, so it carries no class power.
        vm.prank(voter2);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.vote(0, idxs, weights);
    }

    function testPaymaster_registeredAgainstAdminSubject() public {
        OrgDeployer.DeploymentResult memory r = _deployDefaultOrg(ORG_ID);
        PaymasterHub.OrgConfig memory cfg = paymasterHub.getOrgConfig(ORG_ID);
        assertEq(cfg.adminHatId, _adminSubject(), "hub org admin is the ADMIN subject");
        assertEq(cfg.operatorHatId, _roleSubject(ROLE_EXECUTIVE), "operator subject from the role index");
        assertEq(
            paymasterHub.getTargetType(ORG_ID, r.membershipAuthority),
            ModuleTypes.MEMBERSHIP_AUTHORITY_ID,
            "the authority is type-mapped so its user selectors resolve via the rulebook"
        );
    }

    /// @notice Bootstrap projects mirror their role lists into per-project TM_PERMS rows, and those
    ///         rows inherit (OR with) the org-wide grant instead of shadowing it.
    function testBootstrapProject_seedsPerProjectPermsThatInheritGlobal() public {
        OrgDeployer.DeploymentParams memory params = _defaultParams(ORG_ID);
        params.bootstrap = _bootstrapWithProject();
        params.taskManagerPerms = _globalTaskPerms(ROLE_EXECUTIVE, TaskPerm.EDIT_FULL);

        vm.prank(orgOwner);
        OrgDeployer.DeploymentResult memory r = deployer.deployFullOrg(params);
        IMembershipAuthority auth = IMembershipAuthority(r.membershipAuthority);

        bytes32 ctx = bytes32(uint256(1)); // first bootstrap project id is 0; ctx = projectId + 1

        uint256 execMask = auth.hasPerm(orgOwner, AccessV2PermKeys.TM_PERMS, ctx);
        assertEq(
            execMask,
            uint256(TaskPerm.CREATE | TaskPerm.CLAIM | TaskPerm.REVIEW | TaskPerm.ASSIGN | TaskPerm.EDIT_FULL),
            "project row ORs with the global grant"
        );
        assertEq(
            auth.hasPerm(orgOwner, AccessV2PermKeys.TM_PERMS, bytes32(0)),
            uint256(TaskPerm.EDIT_FULL),
            "the global row itself is unchanged"
        );
    }

    /*──────── validation ────────*/

    function testDeploy_rejectsBitmapAddressingAMissingRole() public {
        OrgDeployer.DeploymentParams memory params = _defaultParams(ORG_ID);
        params.roleAssignments.ddVotingRolesBitmap = 1 << 5; // no role 5 exists
        vm.prank(orgOwner);
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);
    }

    function testDeploy_rejectsGroupReferencingAMissingRole() public {
        OrgDeployer.DeploymentParams memory params = _defaultParams(ORG_ID);
        params.groups[0].memberRoleIndices[0] = 9;
        vm.prank(orgOwner);
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);
    }

    function testDeploy_rejectsMoreRolesThanThePermFanoutCap() public {
        OrgDeployer.DeploymentParams memory params = _defaultParams(ORG_ID);
        params.roles = new RoleConfigStructs.RoleConfig[](17);
        for (uint256 i; i < 17; ++i) {
            params.roles[i] = _role("R", false, false, 0);
        }
        params.groups = new RoleConfigStructs.GroupConfig[](0);
        params.roleAssignments = _emptyRoleAssignments();
        params.metadataAdminRoleIndex = type(uint256).max;
        vm.prank(orgOwner);
        vm.expectRevert(OrgDeployer.InvalidRoleConfiguration.selector);
        deployer.deployFullOrg(params);
    }

    function testDeploy_rejectsDuplicateOrgId() public {
        _deployDefaultOrg(ORG_ID);
        OrgDeployer.DeploymentParams memory params = _defaultParams(ORG_ID);
        vm.prank(orgOwner);
        vm.expectRevert(OrgDeployer.OrgExistsMismatch.selector);
        deployer.deployFullOrg(params);
    }

    /*══════════════════════════════════════ HELPERS ══════════════════════════════════════*/

    function _adminSubject() internal view returns (uint256) {
        return orgRegistry.getTopHat(ORG_ID);
    }

    function _roleSubject(uint256 roleIndex) internal view returns (uint256) {
        return orgRegistry.getRoleHat(ORG_ID, roleIndex);
    }

    /// @dev Groups are registered after the roles in the same OrgRegistry list.
    function _groupSubject(uint256 groupIndex) internal view returns (uint256) {
        return orgRegistry.getRoleHat(ORG_ID, 2 + groupIndex);
    }

    function _assertPerm(IMembershipAuthority auth, uint256 subject, bytes32 key, bool expected) internal view {
        bool present = auth.getPerm(subject, key, bytes32(0)) & AccessV2PermKeys.EXISTS_BIT != 0;
        assertEq(present, expected, "perm row presence");
    }

    function _deployDefaultOrg(bytes32 orgId) internal returns (OrgDeployer.DeploymentResult memory) {
        vm.prank(orgOwner);
        return deployer.deployFullOrg(_defaultParams(orgId));
    }

    /// @dev The default fixture is the shape a legacy deploy produced, on v2 rails: an open Member
    ///      role (default-ALLOW, auto-joined by QuickJoin) and a titled Executive role, plus an
    ///      Executives group for restricted polls and manager delegation.
    function _defaultParams(bytes32 orgId) internal view returns (OrgDeployer.DeploymentParams memory params) {
        RoleConfigStructs.RoleConfig[] memory roles = new RoleConfigStructs.RoleConfig[](2);
        roles[0] = _role("DEFAULT", true, true, 0);
        roles[0].distribution.mintToDeployer = true;
        roles[1] = _role("EXECUTIVE", true, false, 5);
        roles[1].distribution.mintToDeployer = true;

        RoleConfigStructs.GroupConfig[] memory groups = new RoleConfigStructs.GroupConfig[](1);
        uint256[] memory execMembers = new uint256[](1);
        execMembers[0] = ROLE_EXECUTIVE;
        groups[0] = RoleConfigStructs.GroupConfig({name: "Executives", memberRoleIndices: execMembers});

        params = OrgDeployer.DeploymentParams({
            orgId: orgId,
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
            hybridClasses: _buildLegacyClasses(50, 50, false, 4 ether),
            ddInitialTargets: new address[](0),
            roles: roles,
            groups: groups,
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: ROLE_EXECUTIVE,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: _defaultPaymasterConfig(),
            taskManagerPerms: _emptyTaskManagerPerms(),
            hybridQuorum: 0,
            ddQuorum: 0,
            tokenName: "",
            tokenSymbol: ""
        });
    }

    function _role(string memory name, bool canVote, bool open, uint32 maxMembers)
        internal
        pure
        returns (RoleConfigStructs.RoleConfig memory)
    {
        return RoleConfigStructs.RoleConfig({
            name: name,
            image: "ipfs://role-image",
            metadataCID: bytes32(0),
            canVote: canVote,
            open: open,
            maxMembers: maxMembers,
            vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: false, additionalWearers: new address[](0)
            })
        });
    }

    /// @dev Bitmap encoding: bit 0 = role 0 (DEFAULT), bit 1 = role 1 (EXECUTIVE).
    function _buildDefaultRoleAssignments() internal pure returns (OrgDeployer.RoleAssignments memory) {
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

    function _emptyRoleAssignments() internal pure returns (OrgDeployer.RoleAssignments memory ra) {}

    function _defaultPaymasterConfig() internal pure returns (OrgDeployer.PaymasterConfig memory) {
        return OrgDeployer.PaymasterConfig({
            operatorRoleIndex: ROLE_EXECUTIVE,
            autoWhitelistContracts: true,
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

    function _emptyTaskManagerPerms() internal pure returns (OrgDeployer.TaskManagerPermConfig memory) {
        return OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)});
    }

    function _globalTaskPerms(uint256 roleIndex, uint8 mask)
        internal
        pure
        returns (OrgDeployer.TaskManagerPermConfig memory cfg)
    {
        cfg.roleIndices = new uint256[](1);
        cfg.masks = new uint8[](1);
        cfg.roleIndices[0] = roleIndex;
        cfg.masks[0] = mask;
    }

    function _bootstrapWithProject() internal pure returns (OrgDeployer.BootstrapConfig memory) {
        ITaskManagerBootstrap.BootstrapProjectConfig[] memory projects =
            new ITaskManagerBootstrap.BootstrapProjectConfig[](1);

        uint256[] memory execOnly = new uint256[](1);
        execOnly[0] = ROLE_EXECUTIVE;
        uint256[] memory both = new uint256[](2);
        both[0] = ROLE_DEFAULT;
        both[1] = ROLE_EXECUTIVE;

        projects[0] = ITaskManagerBootstrap.BootstrapProjectConfig({
            title: bytes("Getting Started"),
            metadataHash: bytes32(0),
            cap: 1000 ether,
            managers: new address[](0),
            createHats: execOnly,
            claimHats: both,
            reviewHats: execOnly,
            assignHats: execOnly,
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });

        return
            OrgDeployer.BootstrapConfig({projects: projects, tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)});
    }

    function _buildLegacyClasses(uint8 ddSplit, uint8 ptSplit, bool quadratic, uint256 minBal)
        internal
        pure
        returns (IHybridVotingInit.ClassConfig[] memory classes)
    {
        uint256[] memory emptyHats = new uint256[](0);
        classes = new IHybridVotingInit.ClassConfig[](2);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: ddSplit,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: emptyHats
        });
        classes[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: ptSplit,
            quadratic: quadratic,
            minBalance: minBal,
            asset: address(0), // backfilled with the soulbound participation token
            hatIds: emptyHats
        });
    }

    /// @dev Seeds the PaymasterHub global rulebook so Mirror-mode orgs resolve sponsored selectors.
    function _seedGlobalRulebook() internal {
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowedFlags, uint32[] memory hints) =
            DefaultGlobalRules.defaults();
        vm.prank(address(poaManager));
        paymasterHub.setGlobalRulesBatch(typeIds, selectors, allowedFlags, hints);
    }

    /// @dev Registers a username then quick-joins, the ordinary self-service onboarding path.
    function _join(OrgDeployer.DeploymentResult memory r, address user, string memory username) internal {
        vm.prank(user);
        UniversalAccountRegistry(accountRegProxy).registerAccount(username);
        vm.prank(user);
        QuickJoin(r.quickJoin).quickJoinWithUser();
    }
}
