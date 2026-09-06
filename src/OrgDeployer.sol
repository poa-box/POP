// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import {OrgRegistry} from "./OrgRegistry.sol";
import {IHybridVotingInit} from "./libs/ModuleDeploymentLib.sol";
import {GovernanceFactory} from "./factories/GovernanceFactory.sol";
import {AccessFactory} from "./factories/AccessFactory.sol";
import {ModulesFactory} from "./factories/ModulesFactory.sol";
import {RoleConfigStructs} from "./libs/RoleConfigStructs.sol";
import {OrgAccessSeedLib} from "./libs/OrgAccessSeedLib.sol";
import {AccessV2Types} from "./libs/AccessV2Types.sol";
import {ModuleTypes} from "./libs/ModuleTypes.sol";
import {ITaskManagerBootstrap} from "./interfaces/ITaskManagerBootstrap.sol";

/*────────────────────── Module‑specific hooks ──────────────────────────*/
interface IExecutorAdmin {
    function setCaller(address) external;
    function setHatMinterAuthorization(address minter, bool authorized) external;
    function setMembershipAuthority(address authority) external;
    function configureModule(address target, bytes calldata data) external returns (bytes memory);
    function acceptBeaconOwnership(address beacon) external;
    function configureParticipationToken(address token, address taskManager, address educationHub) external;
}

interface IPaymasterHub {
    struct DeployConfig {
        uint256 operatorHatId;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        address[] ruleTargets;
        bytes4[] ruleSelectors;
        bool[] ruleAllowed;
        uint32[] ruleMaxCallGasHints;
        bytes32[] budgetSubjectKeys;
        uint128[] budgetCapsPerEpoch;
        uint32[] budgetEpochLens;
        // Target module-type registration for global-rulebook resolution (PaymasterRuleLib)
        address[] typeTargets;
        bytes32[] typeIds;
        uint8 rulesMode; // 0 = Mirror (follow global rulebook), 1 = Static (local snapshot)
    }

    function registerOrg(bytes32 orgId, uint256 adminHatId, uint256 operatorHatId) external;
    function registerAndConfigureOrg(bytes32 orgId, uint256 adminHatId, DeployConfig calldata config) external payable;
    function depositForOrg(bytes32 orgId) external payable;
}

/*────────────────────── MembershipAuthority seed hooks ─────────────────*/
/// @dev Executor-gated authority calls made during the deploy window, relayed through
///      {IExecutorAdmin.configureModule} (the OrgDeployer owns the Executor until step 14).
interface IAuthoritySeed {
    function renameSubject(uint256 subjectId, string calldata name, bytes32 metadataCID, string calldata imageURI)
        external;
    function seedRules(
        uint256[] calldata subjects,
        address[] calldata users,
        AccessV2Types.RuleKind[] calldata kinds,
        bool[] calldata delegable
    ) external;
    function seedMemberships(uint256[] calldata subjects, address[] calldata users) external;
    function seedPerms(
        uint256[] calldata subjects,
        bytes32[] calldata permKeys,
        bytes32[] calldata ctxs,
        uint256[] calldata words
    ) external;
    function setPaused(bool paused) external;
}

/**
 * @title OrgDeployer
 * @notice Thin orchestrator for deploying complete organizations using factory pattern
 * @dev Coordinates GovernanceFactory, AccessFactory, and ModulesFactory. Access v2: an org's
 *      membership and permissions live in ONE per-org MembershipAuthority — there is no Hats tree,
 *      no EligibilityModule and no ToggleModule. Every `uint256` role id below is an authority
 *      SUBJECT id; modules are wired to the authority inside the deploy transaction.
 */
contract OrgDeployer is Initializable {
    /// @notice Contract version for tracking deployments
    string public constant VERSION = "2.0.0";

    /// @notice Caps mirroring the authority's own limits (PermFanoutLimit = 16 subjects per
    ///         permission key, GroupsPerRoleLimit = 8, GroupSizeLimit = 16 member roles).
    uint256 private constant MAX_ROLES = 16;
    uint256 private constant MAX_GROUPS = 8;
    uint256 private constant MAX_GROUP_MEMBERS = 16;

    /*────────────────────────────  Errors  ───────────────────────────────*/
    error InvalidAddress();
    error OrgExistsMismatch();
    error Reentrant();
    error InvalidRoleConfiguration();
    /// @notice `quickJoinRolesBitmap` addresses a role that is not default-ALLOW, which would make
    ///         every QuickJoin call revert at runtime.
    error QuickJoinRoleNotOpen(uint256 roleIndex);
    /// @notice A group lists the same role twice — the authority rejects the second add.
    error DuplicateGroupMemberRole(uint256 groupIndex, uint256 roleIndex);
    /// @notice A role's `maxMembers` cap is smaller than the wearers its genesis seed would mint.
    error RoleCapacityBelowGenesisSeed(uint256 roleIndex, uint256 maxMembers, uint256 seededWearers);
    /// @notice A factory tried to register after the org left bootstrap mode.
    error DeploymentComplete();

    /*────────────────────────────  Events  ───────────────────────────────*/
    event OrgDeployed(
        bytes32 indexed orgId,
        address indexed executor,
        address hybridVoting,
        address directDemocracyVoting,
        address quickJoin,
        address participationToken,
        address taskManager,
        address educationHub,
        address paymentManager,
        address membershipAuthority,
        uint256 adminSubjectId,
        uint256[] roleSubjectIds
    );

    event RolesCreated(
        bytes32 indexed orgId,
        uint256[] subjectIds,
        string[] names,
        string[] images,
        bytes32[] metadataCIDs,
        bool[] canVote
    );

    /// @notice Group subjects created at genesis, with the role subjects each one derives from.
    event GroupsCreated(bytes32 indexed orgId, uint256[] subjectIds, string[] names, uint256[][] memberSubjectIds);

    /// @notice Emitted after OrgDeployed to provide initial wearer assignments for subgraph indexing
    event InitialWearersAssigned(
        bytes32 indexed orgId, address indexed membershipAuthority, address[] wearers, uint256[] subjectIds
    );

    /*───────────── ERC-7201 Storage ───────────*/
    /// @custom:storage-location erc7201:poa.orgdeployer.storage
    struct Layout {
        GovernanceFactory governanceFactory;
        AccessFactory accessFactory;
        ModulesFactory modulesFactory;
        OrgRegistry orgRegistry;
        address poaManager;
        address hatsTreeSetup; // DEAD (Access v2 has no Hats tree); slot retained for upgrade safety
        address paymasterHub; // Shared PaymasterHub for all orgs
        address universalPasskeyFactory; // Universal PasskeyAccountFactory for all orgs
        uint256 _status; // manual reentrancy guard
        IHats hatsV2; // upgrade-safe hats reference (inside ERC-7201 namespace)
        // ZK Email protocol infra (set once per chain via PoaManager). If unset, ZkEmailInvites
        // module deployment is skipped per-org and the feature is gracefully unavailable.
        address zkEmailDomainVerifier; // 3-signal PopRoleClaim verifier (domain claims)
        address zkEmailEmailVerifier; // 4-signal PopRoleClaimV2 verifier (specific-address claims)
        address zkEmailDkimRegistry;
    }

    /// @dev Legacy slot-0 hats variable. Kept for ABI compatibility with existing proxies.
    ///      New deployments write to Layout.hatsV2. Reads use _getHats() which checks both.
    IHats public hats;

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.orgdeployer.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @dev Returns the Hats instance, preferring the ERC-7201 slot (hatsV2) with
    ///      fallback to the legacy slot-0 variable for pre-migration proxies. Hats itself is no
    ///      longer an access source for new orgs; the address is still written to the Executor as
    ///      its `l.hats` seed value and rollback target.
    function _getHats() internal view returns (IHats) {
        IHats h = _layout().hatsV2;
        if (address(h) != address(0)) return h;
        return hats; // legacy slot-0 fallback
    }

    /*════════════════  INITIALIZATION  ════════════════*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governanceFactory,
        address _accessFactory,
        address _modulesFactory,
        address _poaManager,
        address _orgRegistry,
        address _hats,
        address _paymasterHub
    ) public initializer {
        if (
            _governanceFactory == address(0) || _accessFactory == address(0) || _modulesFactory == address(0)
                || _poaManager == address(0) || _orgRegistry == address(0) || _hats == address(0)
                || _paymasterHub == address(0)
        ) {
            revert InvalidAddress();
        }

        Layout storage l = _layout();
        l.governanceFactory = GovernanceFactory(_governanceFactory);
        emit GovernanceFactoryUpdated(_governanceFactory);
        l.accessFactory = AccessFactory(_accessFactory);
        emit AccessFactoryUpdated(_accessFactory);
        l.modulesFactory = ModulesFactory(_modulesFactory);
        emit ModulesFactoryUpdated(_modulesFactory);
        l.orgRegistry = OrgRegistry(_orgRegistry);
        l.poaManager = _poaManager;
        l.paymasterHub = _paymasterHub;
        l._status = 1; // Initialize manual reentrancy guard
        l.hatsV2 = IHats(_hats); // ERC-7201 namespace (upgrade-safe)
        hats = IHats(_hats); // Legacy slot-0 (ABI compatibility for public getter)
    }

    /**
     * @notice Set the universal passkey factory address
     * @dev Only callable by PoaManager
     */
    function setUniversalPasskeyFactory(address _universalFactory) external {
        Layout storage l = _layout();
        if (msg.sender != l.poaManager) revert InvalidAddress();
        if (_universalFactory == address(0)) revert InvalidAddress();
        l.universalPasskeyFactory = _universalFactory;
    }

    /// @notice Wire the per-chain ZK Email protocol infra. Once all are non-zero, every new
    ///         org gets a ZkEmailInvites proxy alongside its other modules.
    /// @dev Only callable by PoaManager. Passing address(0) for any field is a no-op for that field;
    ///      pass all non-zero to enable the feature. Two verifiers are wired: a 3-signal domain verifier
    ///      (PopRoleClaim) and a 4-signal specific-address verifier (PopRoleClaimV2, exposes emailHash).
    function setZkEmailInfrastructure(address domainVerifier, address emailVerifier, address dkimRegistry) external {
        Layout storage l = _layout();
        if (msg.sender != l.poaManager) revert InvalidAddress();
        if (domainVerifier != address(0)) l.zkEmailDomainVerifier = domainVerifier;
        if (emailVerifier != address(0)) l.zkEmailEmailVerifier = emailVerifier;
        if (dkimRegistry != address(0)) l.zkEmailDkimRegistry = dkimRegistry;
    }

    /// @notice Re-point the deployer at a freshly-deployed ModulesFactory.
    /// @dev ModulesFactory is a plain (non-proxy) contract referenced by address, so a beacon
    ///      upgrade of this OrgDeployer keeps the OLD factory in storage. After deploying a new
    ///      ModulesFactory, call this to switch. Only callable by PoaManager (via Hub/Satellite adminCall).
    event ModulesFactoryUpdated(address indexed factory);
    event GovernanceFactoryUpdated(address indexed factory);
    event AccessFactoryUpdated(address indexed factory);

    /// @notice Current deployment factories, for upgrade verification and integrations.
    function factories() external view returns (address governance, address access, address modules) {
        Layout storage l = _layout();
        return (address(l.governanceFactory), address(l.accessFactory), address(l.modulesFactory));
    }

    function setModulesFactory(address _modulesFactory) external {
        Layout storage l = _layout();
        if (msg.sender != l.poaManager) revert InvalidAddress();
        if (_modulesFactory == address(0)) revert InvalidAddress();
        l.modulesFactory = ModulesFactory(_modulesFactory);
        emit ModulesFactoryUpdated(_modulesFactory);
    }

    /// @notice Re-point the deployer at freshly-deployed Governance/Access factories.
    /// @dev Same rationale as setModulesFactory. Only callable by PoaManager.
    function setGovernanceFactory(address _governanceFactory) external {
        Layout storage l = _layout();
        if (msg.sender != l.poaManager) revert InvalidAddress();
        if (_governanceFactory == address(0)) revert InvalidAddress();
        l.governanceFactory = GovernanceFactory(_governanceFactory);
        emit GovernanceFactoryUpdated(_governanceFactory);
    }

    function setAccessFactory(address _accessFactory) external {
        Layout storage l = _layout();
        if (msg.sender != l.poaManager) revert InvalidAddress();
        if (_accessFactory == address(0)) revert InvalidAddress();
        l.accessFactory = AccessFactory(_accessFactory);
        emit AccessFactoryUpdated(_accessFactory);
    }

    /*════════════════  DEPLOYMENT STRUCTS  ════════════════*/

    struct DeploymentResult {
        address hybridVoting;
        address directDemocracyVoting;
        address executor;
        address quickJoin;
        address participationToken;
        address taskManager;
        address educationHub;
        address paymentManager;
        address membershipAuthority;
        // address(0) on chains where ZK Email protocol infra (verifier + DKIM registry)
        // has not been wired into the OrgDeployer yet — the module is skipped.
        address zkEmailInvites;
    }

    struct RoleAssignments {
        uint256 quickJoinRolesBitmap; // Bit N set = Role N auto-joins (QJ_AUTOJOIN + default-ALLOW)
        uint256 tokenMemberRolesBitmap; // Bit N set = Role N can hold tokens (PT_MEMBER)
        uint256 tokenApproverRolesBitmap; // Bit N set = Role N can approve transfers (PT_APPROVE)
        uint256 taskCreatorRolesBitmap; // Bit N set = Role N is a TaskManager organizer
        uint256 educationCreatorRolesBitmap; // Bit N set = Role N can create education (EDU_CREATE)
        uint256 educationMemberRolesBitmap; // Bit N set = Role N can access education (EDU_MEMBER)
        uint256 hybridProposalCreatorRolesBitmap; // Bit N set = Role N can create proposals (HV_CREATE)
        uint256 ddVotingRolesBitmap; // Bit N set = Role N can vote in polls (DD_VOTE)
        uint256 ddCreatorRolesBitmap; // Bit N set = Role N can create polls (DD_CREATE)
    }

    struct BootstrapConfig {
        ITaskManagerBootstrap.BootstrapProjectConfig[] projects;
        ITaskManagerBootstrap.BootstrapTaskConfig[] tasks;
    }

    /// @notice Org-wide TaskManager permission grants, seeded as TM_PERMS rows at the global context.
    /// @dev Each `roleIndices[i]` is resolved against `params.roles[]` and given `masks[i]` (an OR of
    ///      `TaskPerm` bits). Empty arrays = skip. Duplicate role indices: last write wins.
    ///      Bootstrap projects add per-project rows that INHERIT this global row (the authority ORs
    ///      the two), so a global grant is never silently shadowed by a project grant.
    struct TaskManagerPermConfig {
        uint256[] roleIndices;
        uint8[] masks;
    }

    struct PaymasterConfig {
        uint256 operatorRoleIndex; // Role index for the paymaster operator subject; >= roles.length = skip
        bool autoWhitelistContracts; // If true, map deployed org contracts to their module typeIds
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        // Budget config (all zeros = skip)
        uint128 defaultBudgetCapPerEpoch; // Default spending cap per epoch for each role subject (0 = no budget)
        uint32 defaultBudgetEpochLen; // Default epoch length in seconds for each role subject (0 = no budget)
    }

    struct DeploymentParams {
        bytes32 orgId;
        string orgName;
        bytes32 metadataHash; // IPFS CID sha256 digest (optional, bytes32(0) is valid)
        address registryAddr;
        address deployerAddress; // Founder address (seeded into every mintToDeployer role)
        string deployerUsername; // Optional username for deployer (empty string = skip registration)
        uint256 regDeadline; // EIP-712 signature deadline (0 = skip registration)
        uint256 regNonce; // User's current nonce on the registry
        bytes regSignature; // User's EIP-712 ECDSA signature for username registration
        bool autoUpgrade;
        uint8 hybridThresholdPct;
        uint8 ddThresholdPct;
        IHybridVotingInit.ClassConfig[] hybridClasses;
        address[] ddInitialTargets;
        RoleConfigStructs.RoleConfig[] roles; // ROLE subjects
        RoleConfigStructs.GroupConfig[] groups; // GROUP subjects (derived membership over roles)
        RoleAssignments roleAssignments;
        uint256 metadataAdminRoleIndex; // Role index granted SUBJECT_RENAME; >= roles.length = skip
        bool passkeyEnabled; // Whether passkey support is enabled (uses universal factory)
        ModulesFactory.EducationHubConfig educationHubConfig; // EducationHub deployment configuration
        BootstrapConfig bootstrap; // Optional: initial projects and tasks to create
        PaymasterConfig paymasterConfig; // Optional: paymaster configuration (funding via msg.value)
        TaskManagerPermConfig taskManagerPerms; // Optional: org-wide TaskManager TM_PERMS grants
        uint32 hybridQuorum; // Min voter count for HybridVoting proposals (0 = disabled)
        uint32 ddQuorum; // Min voter count for DirectDemocracyVoting polls (0 = disabled)
        string tokenName; // ParticipationToken name (empty = "<orgName> Token")
        string tokenSymbol; // ParticipationToken symbol (empty = "PT")
    }

    /*════════════════  VALIDATION  ════════════════*/

    /// @notice Validates the org's role/group shape against the authority's structural limits.
    function _validateRoleConfigs(DeploymentParams calldata params) internal pure {
        uint256 len = params.roles.length;
        if (len == 0 || len > MAX_ROLES) revert InvalidRoleConfiguration();

        uint256 quickJoinBitmap = params.roleAssignments.quickJoinRolesBitmap;
        for (uint256 i = 0; i < len; i++) {
            RoleConfigStructs.RoleConfig calldata role = params.roles[i];
            if (bytes(role.name).length == 0) revert InvalidRoleConfiguration();
            if (role.vouching.enabled) {
                if (role.vouching.quorum == 0) revert InvalidRoleConfiguration();
                if (role.vouching.voucherRoleIndex >= len) revert InvalidRoleConfiguration();
            }
            // QJ_AUTOJOIN is only reachable for a default-ALLOW (open) role: QuickJoin enumerates the
            // subjects carrying the perm without any eligibility filter, and the authority rejects a
            // non-eligible stranger — so a closed role in the bitmap bricks EVERY join at runtime.
            if (!role.open && quickJoinBitmap & (1 << i) != 0) revert QuickJoinRoleNotOpen(i);
            // The genesis seed flips each wearer on one by one; over-cap would revert deep inside the
            // authority's constructor (SubjectFull) as an opaque deploy failure.
            uint256 seeded = role.distribution.additionalWearers.length + (role.distribution.mintToDeployer ? 1 : 0);
            if (role.maxMembers != 0 && seeded > role.maxMembers) {
                revert RoleCapacityBelowGenesisSeed(i, role.maxMembers, seeded);
            }
        }

        uint256 groupCount = params.groups.length;
        if (groupCount > MAX_GROUPS) revert InvalidRoleConfiguration();
        for (uint256 j = 0; j < groupCount; j++) {
            RoleConfigStructs.GroupConfig calldata group = params.groups[j];
            if (bytes(group.name).length == 0) revert InvalidRoleConfiguration();
            uint256 m = group.memberRoleIndices.length;
            if (m == 0 || m > MAX_GROUP_MEMBERS) revert InvalidRoleConfiguration();
            // `len <= MAX_ROLES (16)`, so a uint256 bitmap covers every valid member index.
            uint256 seenRoles;
            for (uint256 x = 0; x < m; x++) {
                uint256 roleIndex = group.memberRoleIndices[x];
                if (roleIndex >= len) revert InvalidRoleConfiguration();
                // A repeat would revert SubjectExists inside the authority's constructor.
                if (seenRoles & (1 << roleIndex) != 0) revert DuplicateGroupMemberRole(j, roleIndex);
                seenRoles |= 1 << roleIndex;
            }
        }

        // Every role bitmap addresses ROLE indices only — a bit past the role count would produce a
        // permission row with no subject behind it.
        uint256 mask = len == 256 ? type(uint256).max : (1 << len) - 1;
        RoleAssignments calldata ra = params.roleAssignments;
        uint256 union = ra.quickJoinRolesBitmap | ra.tokenMemberRolesBitmap | ra.tokenApproverRolesBitmap
            | ra.taskCreatorRolesBitmap | ra.educationCreatorRolesBitmap | ra.educationMemberRolesBitmap
            | ra.hybridProposalCreatorRolesBitmap | ra.ddVotingRolesBitmap | ra.ddCreatorRolesBitmap;
        if (union & ~mask != 0) revert InvalidRoleConfiguration();

        if (params.taskManagerPerms.roleIndices.length != params.taskManagerPerms.masks.length) {
            revert InvalidRoleConfiguration();
        }
        for (uint256 i = 0; i < params.taskManagerPerms.roleIndices.length; i++) {
            if (params.taskManagerPerms.roleIndices[i] >= len) revert InvalidRoleConfiguration();
        }
    }

    /*════════════════  MAIN DEPLOYMENT FUNCTION  ════════════════*/

    /// @notice Deploy a full org without ZK Email invites.
    function deployFullOrg(DeploymentParams calldata params) external payable returns (DeploymentResult memory result) {
        ModulesFactory.ZkEmailConfig memory emptyZk; // disabled — the module is skipped
        result = _deployFullOrgGuarded(params, emptyZk);
    }

    /// @notice Deploy a full org and opt into ZK Email role invitations with an initial allowlist.
    /// @dev The ZkEmailInvites module deploys only if `zkConfig.enabled` AND the chain has the ZK
    ///      Email infra wired (verifier + DKIM registry via setZkEmailInfrastructure) AND the
    ///      ZkEmailInvites beacon is registered. Domain/email rules use role-index bitmaps,
    ///      resolved to subject ids at deploy. Rules are applied atomically before ownership renounce.
    function deployFullOrgWithZkEmail(DeploymentParams calldata params, ModulesFactory.ZkEmailConfig calldata zkConfig)
        external
        payable
        returns (DeploymentResult memory result)
    {
        result = _deployFullOrgGuarded(params, zkConfig);
    }

    function _deployFullOrgGuarded(DeploymentParams calldata params, ModulesFactory.ZkEmailConfig memory zkConfig)
        internal
        returns (DeploymentResult memory result)
    {
        // Manual reentrancy guard
        Layout storage l = _layout();
        if (l._status == 2) revert Reentrant();
        l._status = 2;

        result = _deployFullOrgInternal(params, zkConfig);

        // Reset reentrancy guard
        l._status = 1;

        return result;
    }

    /*════════════════  INTERNAL ORCHESTRATION  ════════════════*/

    function _deployFullOrgInternal(DeploymentParams calldata params, ModulesFactory.ZkEmailConfig memory zkConfig)
        internal
        returns (DeploymentResult memory result)
    {
        Layout storage l = _layout();

        /* 1. Validate configuration */
        _validateRoleConfigs(params);
        if (params.deployerAddress == address(0)) revert InvalidAddress();

        /* 2. Create Org in bootstrap mode */
        if (_orgExists(params.orgId)) revert OrgExistsMismatch();
        l.orgRegistry.createOrgBootstrap(params.orgId, bytes(params.orgName), params.metadataHash);

        /* 3. Deploy the Executor and take ownership of its beacon */
        GovernanceFactory.GovernanceResult memory gov = _deployGovernanceInfrastructure(params);
        result.executor = gov.executor;
        IExecutorAdmin(result.executor).acceptBeaconOwnership(gov.execBeacon);
        l.orgRegistry.setOrgExecutor(params.orgId, result.executor);

        /* 4. Deploy the MembershipAuthority (born initialized + paused) and publish its subject ids */
        AccessFactory.AuthorityResult memory auth = _deployAuthority(l, params, result.executor);
        result.membershipAuthority = auth.authority;
        l.orgRegistry
            .registerHatsTree(params.orgId, auth.adminSubjectId, _concat(auth.roleSubjectIds, auth.groupSubjectIds));
        if (params.metadataAdminRoleIndex < params.roles.length) {
            l.orgRegistry.setOrgMetadataAdminHat(params.orgId, auth.roleSubjectIds[params.metadataAdminRoleIndex]);
        }

        /* 5. Deploy Access Infrastructure (QuickJoin, Token) */
        _deployAccess(l, params, result, auth.roleSubjectIds);

        /* 6. Deploy Functional Modules (TaskManager, Education, Payment, ZkEmailInvites) */
        _deployModules(l, params, result, auth.roleSubjectIds, zkConfig);

        /* 7. Deploy Voting Mechanisms (HybridVoting, DirectDemocracyVoting) */
        (result.hybridVoting, result.directDemocracyVoting) =
            _deployVotingMechanisms(params, result.executor, result.participationToken, auth.roleSubjectIds);

        /* 8. Register and configure the org with PaymasterHub (after all modules exist) */
        _configurePaymaster(l, params, result, auth.adminSubjectId, auth.roleSubjectIds);

        /* 9. Wire cross-module connections. The token's setTaskManager/setEducationHub are
              executor-only, so the wiring is relayed through the Executor (owned by this deployer
              until step 14). educationHub == 0 when disabled → skipped inside the helper. */
        IExecutorAdmin(result.executor)
            .configureParticipationToken(
                result.participationToken,
                result.taskManager,
                params.educationHubConfig.enabled ? result.educationHub : address(0)
            );

        /* 10. Bootstrap initial projects and tasks, mirroring their role permissions into the
               authority's per-project TM_PERMS rows (the module reads permissions there). */
        if (params.bootstrap.projects.length > 0) {
            bytes32[] memory projectIds = ITaskManagerBootstrap(result.taskManager)
                .bootstrapProjectsAndTasks(
                    _resolveBootstrapRoles(params.bootstrap.projects, auth.roleSubjectIds), params.bootstrap.tasks
                );
            _seedProjectPerms(result, auth.roleSubjectIds, params.bootstrap.projects, projectIds);
        }

        /* 10b. Clear deployer address to prevent future bootstrap calls (defense-in-depth) */
        ITaskManagerBootstrap(result.taskManager).clearDeployer();

        /* 11. Authorize the hat-minting modules (they mint through Executor.mintHatsForUser, which
               resolves against the authority once step 12 repoints it) */
        IExecutorAdmin(result.executor).setHatMinterAuthorization(result.quickJoin, true);
        if (result.zkEmailInvites != address(0)) {
            IExecutorAdmin(result.executor).setHatMinterAuthorization(result.zkEmailInvites, true);
        }

        /* 12. Point every module at the authority, seed the genesis memberships, unpause */
        _activateAuthority(params, result, auth);

        /* 13. Link executor to governor */
        IExecutorAdmin(result.executor).setCaller(result.hybridVoting);

        /* 14. Renounce executor ownership - now only governed by voting */
        OwnableUpgradeable(result.executor).renounceOwnership();

        /* 15. Emit events for subgraph indexing */
        _emitDeploymentEvents(params, result, auth);

        return result;
    }

    /*══════════════  UTILITIES  ═════════════=*/

    function _orgExists(bytes32 id) internal view returns (bool) {
        (,,, bool exists) = _layout().orgRegistry.orgOf(id);
        return exists;
    }

    function _concat(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 j; j < b.length; ++j) {
            out[a.length + j] = b[j];
        }
    }

    /// @dev Deploys QuickJoin + ParticipationToken. Split out of the orchestration body so the
    ///      params struct does not have to live on the stack alongside it (production via-IR).
    function _deployAccess(
        Layout storage l,
        DeploymentParams calldata params,
        DeploymentResult memory result,
        uint256[] memory roleSubjectIds
    ) internal {
        AccessFactory.AccessParams memory p;
        p.orgId = params.orgId;
        p.orgName = params.orgName;
        p.poaManager = l.poaManager;
        p.orgRegistry = address(l.orgRegistry);
        p.hats = address(_getHats());
        p.executor = result.executor;
        p.deployer = address(this); // For registration callbacks
        p.registryAddr = params.registryAddr;
        p.roleSubjectIds = roleSubjectIds;
        p.autoUpgrade = params.autoUpgrade;
        p.roleAssignments = AccessFactory.RoleAssignments({
            quickJoinRolesBitmap: params.roleAssignments.quickJoinRolesBitmap,
            tokenMemberRolesBitmap: params.roleAssignments.tokenMemberRolesBitmap,
            tokenApproverRolesBitmap: params.roleAssignments.tokenApproverRolesBitmap
        });
        p.passkeyConfig = AccessFactory.PasskeyConfig({
            enabled: params.passkeyEnabled,
            universalFactory: params.passkeyEnabled ? l.universalPasskeyFactory : address(0)
        });
        p.tokenName = params.tokenName;
        p.tokenSymbol = params.tokenSymbol;

        AccessFactory.AccessResult memory access = l.accessFactory.deployAccess(p);
        result.quickJoin = access.quickJoin;
        result.participationToken = access.participationToken;
    }

    /// @dev Deploys TaskManager, EducationHub, PaymentManager and (optionally) ZkEmailInvites.
    function _deployModules(
        Layout storage l,
        DeploymentParams calldata params,
        DeploymentResult memory result,
        uint256[] memory roleSubjectIds,
        ModulesFactory.ZkEmailConfig memory zkConfig
    ) internal {
        ModulesFactory.ModulesParams memory p;
        p.orgId = params.orgId;
        p.orgName = params.orgName;
        p.poaManager = l.poaManager;
        p.orgRegistry = address(l.orgRegistry);
        p.hats = address(_getHats());
        p.executor = result.executor;
        p.deployer = address(this); // For registration callbacks
        p.participationToken = result.participationToken;
        p.roleSubjectIds = roleSubjectIds;
        p.autoUpgrade = params.autoUpgrade;
        p.roleAssignments = ModulesFactory.RoleAssignments({
            taskCreatorRolesBitmap: params.roleAssignments.taskCreatorRolesBitmap,
            educationCreatorRolesBitmap: params.roleAssignments.educationCreatorRolesBitmap,
            educationMemberRolesBitmap: params.roleAssignments.educationMemberRolesBitmap
        });
        p.educationHubConfig = params.educationHubConfig;
        p.zkEmailDomainVerifier = l.zkEmailDomainVerifier;
        p.zkEmailEmailVerifier = l.zkEmailEmailVerifier;
        p.zkEmailDkimRegistry = l.zkEmailDkimRegistry;
        p.accountRegistry = params.registryAddr;
        p.universalFactory = l.universalPasskeyFactory;
        p.zkEmailConfig = zkConfig;

        ModulesFactory.ModulesResult memory modules = l.modulesFactory.deployModules(p);
        result.taskManager = modules.taskManager;
        result.educationHub = modules.educationHub;
        result.paymentManager = modules.paymentManager;
        result.zkEmailInvites = modules.zkEmailInvites;
    }

    /// @notice Deploy the org's MembershipAuthority with its genesis seed.
    function _deployAuthority(Layout storage l, DeploymentParams calldata params, address executor)
        internal
        returns (AccessFactory.AuthorityResult memory)
    {
        AccessFactory.AuthorityParams memory p;
        p.orgId = params.orgId;
        p.poaManager = l.poaManager;
        p.executor = executor;
        p.deployer = address(this);
        p.paymasterHub = l.paymasterHub;
        p.autoUpgrade = params.autoUpgrade;
        p.roles = params.roles;
        p.groups = params.groups;
        p.perms = OrgAccessSeedLib.PermConfig({
            quickJoinRolesBitmap: params.roleAssignments.quickJoinRolesBitmap,
            tokenMemberRolesBitmap: params.roleAssignments.tokenMemberRolesBitmap,
            tokenApproverRolesBitmap: params.roleAssignments.tokenApproverRolesBitmap,
            educationCreatorRolesBitmap: params.roleAssignments.educationCreatorRolesBitmap,
            educationMemberRolesBitmap: params.roleAssignments.educationMemberRolesBitmap,
            hybridProposalCreatorRolesBitmap: params.roleAssignments.hybridProposalCreatorRolesBitmap,
            ddVotingRolesBitmap: params.roleAssignments.ddVotingRolesBitmap,
            ddCreatorRolesBitmap: params.roleAssignments.ddCreatorRolesBitmap,
            tmRoleIndices: params.taskManagerPerms.roleIndices,
            tmMasks: _widen(params.taskManagerPerms.masks),
            metadataAdminRoleIndex: params.metadataAdminRoleIndex
        });
        return l.accessFactory.deployAuthority(p);
    }

    function _widen(uint8[] calldata masks) internal pure returns (uint256[] memory out) {
        out = new uint256[](masks.length);
        for (uint256 i; i < masks.length; ++i) {
            out[i] = masks[i];
        }
    }

    /**
     * @notice Repoint every module at the authority, seed genesis memberships, and unpause it.
     * @dev The authority is born paused (writes disabled, reads live). Seeding runs while paused so
     *      genesis members carry `acceptedAt = 1` — in-flight proposals do not exist yet, and the
     *      anti-packing activation gate stays meaningful for everyone who joins afterwards. Each
     *      seeded membership is paired with a delegable governance GRANT so it carries an
     *      eligibility source; open (default-ALLOW) roles get one too, which is what lets governance
     *      or a delegate later revoke a seat on an otherwise open role.
     */
    function _activateAuthority(
        DeploymentParams calldata params,
        DeploymentResult memory result,
        AccessFactory.AuthorityResult memory auth
    ) internal {
        IExecutorAdmin exec = IExecutorAdmin(result.executor);
        bytes memory setAuth = abi.encodeCall(IExecutorAdmin.setMembershipAuthority, (auth.authority));

        exec.configureModule(result.quickJoin, setAuth);
        exec.configureModule(result.participationToken, setAuth);
        exec.configureModule(result.taskManager, setAuth);
        exec.configureModule(result.directDemocracyVoting, setAuth);
        exec.configureModule(result.hybridVoting, setAuth);
        if (result.educationHub != address(0)) {
            exec.configureModule(result.educationHub, setAuth);
        }
        // On the Executor the setter repoints `l.hats` itself, so every hats() consumer
        // (mintHatsForUser, ZkEmailInvites) follows automatically.
        exec.setMembershipAuthority(auth.authority);

        // OrgAccessSeedLib deliberately keeps the deployed initialize/seedSubjects ABI stable, and
        // that seed shape carries names/caps but not CID/image metadata. Persist the remaining role
        // metadata through the authority's existing executor path while it is still paused. This also
        // emits SubjectRenamed, so authority storage and the RolesCreated summary event cannot diverge.
        for (uint256 i; i < params.roles.length; ++i) {
            RoleConfigStructs.RoleConfig calldata role = params.roles[i];
            if (role.metadataCID == bytes32(0) && bytes(role.image).length == 0) continue;
            exec.configureModule(
                auth.authority,
                abi.encodeCall(
                    IAuthoritySeed.renameSubject, (auth.roleSubjectIds[i], role.name, role.metadataCID, role.image)
                )
            );
        }

        (uint256[] memory subjects, address[] memory users) = _genesisMemberships(params, result.executor, auth);
        if (subjects.length > 0) {
            AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](subjects.length);
            bool[] memory delegable = new bool[](subjects.length);
            for (uint256 i; i < subjects.length; ++i) {
                kinds[i] = AccessV2Types.RuleKind.Grant;
                delegable[i] = true;
            }
            exec.configureModule(
                auth.authority, abi.encodeCall(IAuthoritySeed.seedRules, (subjects, users, kinds, delegable))
            );
            exec.configureModule(auth.authority, abi.encodeCall(IAuthoritySeed.seedMemberships, (subjects, users)));
        }

        exec.configureModule(auth.authority, abi.encodeCall(IAuthoritySeed.setPaused, (false)));
    }

    /// @dev Genesis membership set (Executor on ADMIN + every seeded role wearer). Built in
    ///      AccessFactory to keep OrgDeployer under the EIP-170 limit.
    function _genesisMemberships(
        DeploymentParams calldata params,
        address executor,
        AccessFactory.AuthorityResult memory auth
    ) internal view returns (uint256[] memory, address[] memory) {
        return _layout().accessFactory
            .buildGenesisMemberships(
                params.roles, params.deployerAddress, executor, auth.adminSubjectId, auth.roleSubjectIds
            );
    }

    /**
     * @notice Internal helper to deploy governance infrastructure
     * @dev Extracted to reduce stack depth in main deployment function
     */
    function _deployGovernanceInfrastructure(DeploymentParams calldata params)
        internal
        returns (GovernanceFactory.GovernanceResult memory)
    {
        Layout storage l = _layout();

        GovernanceFactory.GovernanceParams memory govParams;
        govParams.orgId = params.orgId;
        govParams.orgName = params.orgName;
        govParams.poaManager = l.poaManager;
        govParams.orgRegistry = address(l.orgRegistry);
        govParams.hats = address(_getHats());
        govParams.deployer = address(this);
        govParams.deployerAddress = params.deployerAddress;
        govParams.accountRegistry = params.registryAddr; // UniversalAccountRegistry for username registration
        govParams.participationToken = address(0);
        govParams.deployerUsername = params.deployerUsername; // Optional username (empty = skip)
        govParams.regDeadline = params.regDeadline;
        govParams.regNonce = params.regNonce;
        govParams.regSignature = params.regSignature;
        govParams.autoUpgrade = params.autoUpgrade;

        return l.governanceFactory.deployInfrastructure(govParams);
    }

    /**
     * @notice Internal helper to deploy voting mechanisms after token is available
     * @dev Extracted to reduce stack depth in main deployment function
     */
    function _deployVotingMechanisms(
        DeploymentParams calldata params,
        address executor,
        address participationToken,
        uint256[] memory roleSubjectIds
    ) internal returns (address hybridVoting, address directDemocracyVoting) {
        Layout storage l = _layout();

        GovernanceFactory.GovernanceParams memory votingParams;
        votingParams.orgId = params.orgId;
        votingParams.orgName = params.orgName;
        votingParams.poaManager = l.poaManager;
        votingParams.orgRegistry = address(l.orgRegistry);
        votingParams.hats = address(_getHats());
        votingParams.deployer = address(this);
        votingParams.deployerAddress = params.deployerAddress;
        votingParams.participationToken = participationToken;
        votingParams.autoUpgrade = params.autoUpgrade;
        votingParams.hybridThresholdPct = params.hybridThresholdPct;
        votingParams.ddThresholdPct = params.ddThresholdPct;
        votingParams.hybridClasses = params.hybridClasses;
        votingParams.hybridProposalCreatorRolesBitmap = params.roleAssignments.hybridProposalCreatorRolesBitmap;
        votingParams.ddVotingRolesBitmap = params.roleAssignments.ddVotingRolesBitmap;
        votingParams.ddCreatorRolesBitmap = params.roleAssignments.ddCreatorRolesBitmap;
        votingParams.ddInitialTargets = params.ddInitialTargets;
        votingParams.roles = params.roles;
        votingParams.hybridQuorum = params.hybridQuorum;
        votingParams.ddQuorum = params.ddQuorum;

        return l.governanceFactory.deployVoting(votingParams, executor, roleSubjectIds);
    }

    /**
     * @notice Batch register multiple contracts from factories
     * @dev Only callable by approved factory contracts. Reduces gas overhead by batching registrations.
     * @param orgId The organization identifier
     * @param registrations Array of contracts to register
     * @param autoUpgrade Whether contracts auto-upgrade with their beacons
     */
    function batchRegisterContracts(
        bytes32 orgId,
        OrgRegistry.ContractRegistration[] calldata registrations,
        bool autoUpgrade,
        bool lastRegister
    ) external {
        Layout storage l = _layout();

        // Only allow factory contracts to call this
        if (
            msg.sender != address(l.governanceFactory) && msg.sender != address(l.accessFactory)
                && msg.sender != address(l.modulesFactory)
        ) {
            revert InvalidAddress();
        }

        // Only allow during bootstrap (deployment phase)
        (,, bool bootstrap,) = l.orgRegistry.orgOf(orgId);
        if (!bootstrap) revert DeploymentComplete();

        // Forward batch registration to OrgRegistry (we are the owner)
        l.orgRegistry.batchRegisterOrgContracts(orgId, registrations, autoUpgrade, lastRegister);
    }

    /**
     * @notice Resolve role indices to subject ids in bootstrap project configs
     */
    function _resolveBootstrapRoles(
        ITaskManagerBootstrap.BootstrapProjectConfig[] calldata projects,
        uint256[] memory roleSubjectIds
    ) internal pure returns (ITaskManagerBootstrap.BootstrapProjectConfig[] memory resolved) {
        resolved = new ITaskManagerBootstrap.BootstrapProjectConfig[](projects.length);

        for (uint256 i = 0; i < projects.length; i++) {
            resolved[i] = ITaskManagerBootstrap.BootstrapProjectConfig({
                title: projects[i].title,
                metadataHash: projects[i].metadataHash,
                cap: projects[i].cap,
                managers: projects[i].managers,
                createHats: _resolveRoleIndices(projects[i].createHats, roleSubjectIds),
                claimHats: _resolveRoleIndices(projects[i].claimHats, roleSubjectIds),
                reviewHats: _resolveRoleIndices(projects[i].reviewHats, roleSubjectIds),
                assignHats: _resolveRoleIndices(projects[i].assignHats, roleSubjectIds),
                bountyTokens: projects[i].bountyTokens,
                bountyCaps: projects[i].bountyCaps
            });
        }

        return resolved;
    }

    /**
     * @notice Convert an array of role indices to authority subject ids
     */
    function _resolveRoleIndices(uint256[] calldata roleIndices, uint256[] memory roleSubjectIds)
        internal
        pure
        returns (uint256[] memory subjectIds)
    {
        subjectIds = new uint256[](roleIndices.length);
        for (uint256 i = 0; i < roleIndices.length; i++) {
            if (roleIndices[i] >= roleSubjectIds.length) revert InvalidRoleConfiguration();
            subjectIds[i] = roleSubjectIds[roleIndices[i]];
        }
        return subjectIds;
    }

    /// @dev Mirror each bootstrap project's role lists into the authority's per-project TM_PERMS
    ///      rows (AccessFactory builds them; see `buildProjectPermRows` for the inherit semantics).
    function _seedProjectPerms(
        DeploymentResult memory result,
        uint256[] memory roleSubjectIds,
        ITaskManagerBootstrap.BootstrapProjectConfig[] calldata projects,
        bytes32[] memory projectIds
    ) internal {
        AccessFactory factory = _layout().accessFactory;
        for (uint256 p = 0; p < projects.length; p++) {
            (uint256[] memory subjects, bytes32[] memory keys, bytes32[] memory ctxs, uint256[] memory words) =
                factory.buildProjectPermRows(projects[p], roleSubjectIds, projectIds[p]);
            if (subjects.length == 0) continue;
            IExecutorAdmin(result.executor)
                .configureModule(
                    result.membershipAuthority, abi.encodeCall(IAuthoritySeed.seedPerms, (subjects, keys, ctxs, words))
                );
        }
    }

    /*══════════════  SUBGRAPH EVENTS  ═════════════=*/

    function _emitDeploymentEvents(
        DeploymentParams calldata params,
        DeploymentResult memory result,
        AccessFactory.AuthorityResult memory auth
    ) internal {
        emit OrgDeployed(
            params.orgId,
            result.executor,
            result.hybridVoting,
            result.directDemocracyVoting,
            result.quickJoin,
            result.participationToken,
            result.taskManager,
            result.educationHub,
            result.paymentManager,
            auth.authority,
            auth.adminSubjectId,
            auth.roleSubjectIds
        );

        {
            uint256 roleCount = params.roles.length;
            string[] memory names = new string[](roleCount);
            string[] memory images = new string[](roleCount);
            bytes32[] memory metadataCIDs = new bytes32[](roleCount);
            bool[] memory canVoteFlags = new bool[](roleCount);
            for (uint256 i = 0; i < roleCount; i++) {
                names[i] = params.roles[i].name;
                images[i] = params.roles[i].image;
                metadataCIDs[i] = params.roles[i].metadataCID;
                canVoteFlags[i] = params.roles[i].canVote;
            }
            emit RolesCreated(params.orgId, auth.roleSubjectIds, names, images, metadataCIDs, canVoteFlags);
        }

        if (params.groups.length > 0) {
            uint256 groupCount = params.groups.length;
            string[] memory names = new string[](groupCount);
            uint256[][] memory members = new uint256[][](groupCount);
            for (uint256 j = 0; j < groupCount; j++) {
                names[j] = params.groups[j].name;
                uint256 m = params.groups[j].memberRoleIndices.length;
                uint256[] memory ids = new uint256[](m);
                for (uint256 x = 0; x < m; x++) {
                    ids[x] = auth.roleSubjectIds[params.groups[j].memberRoleIndices[x]];
                }
                members[j] = ids;
            }
            emit GroupsCreated(params.orgId, auth.groupSubjectIds, names, members);
        }

        {
            (uint256[] memory subjects, address[] memory users) = _genesisMemberships(params, result.executor, auth);
            emit InitialWearersAssigned(params.orgId, auth.authority, users, subjects);
        }
    }

    /*══════════════  PAYMASTER CONFIGURATION  ═════════════=*/

    /**
     * @notice Register and optionally configure the org's PaymasterHub entry
     * @dev Runs after all modules are deployed so their addresses can be type-mapped. The org's
     *      admin/operator "hat" ids are authority SUBJECT ids, which the hub resolves through the
     *      protocol AuthorityRouter (new-style ids self-route to their owning authority).
     */
    function _configurePaymaster(
        Layout storage l,
        DeploymentParams calldata params,
        DeploymentResult memory result,
        uint256 adminSubjectId,
        uint256[] memory roleSubjectIds
    ) internal {
        PaymasterConfig calldata pmCfg = params.paymasterConfig;

        uint256 operatorSubjectId = 0;
        if (pmCfg.operatorRoleIndex < params.roles.length) {
            operatorSubjectId = roleSubjectIds[pmCfg.operatorRoleIndex];
        }

        bool hasFeeCaps = pmCfg.maxFeePerGas != 0 || pmCfg.maxPriorityFeePerGas != 0 || pmCfg.maxCallGas != 0
            || pmCfg.maxVerificationGas != 0 || pmCfg.maxPreVerificationGas != 0;
        bool hasBudgets = pmCfg.defaultBudgetCapPerEpoch != 0 && pmCfg.defaultBudgetEpochLen != 0;
        bool hasConfig = hasFeeCaps || pmCfg.autoWhitelistContracts || hasBudgets || msg.value > 0;

        if (hasConfig) {
            // Map deployed org contracts (+ shared registries) to module typeIds so the org's
            // sponsorship rules resolve through the PaymasterHub's type-keyed GLOBAL RULEBOOK
            // (script/helpers/DefaultGlobalRules.sol is the canonical selector list).
            (address[] memory typeTargets, bytes32[] memory typeIds) = pmCfg.autoWhitelistContracts
                ? _buildTargetTypes(result, params.registryAddr, address(l.orgRegistry))
                : (new address[](0), new bytes32[](0));

            // Per-role-subject budgets if configured (+ the zk-email CLAIM budget when the module deploys)
            (bytes32[] memory budgetKeys, uint128[] memory budgetCaps, uint32[] memory budgetEpochLens) = hasBudgets
                ? _buildDefaultBudgets(
                    roleSubjectIds, result.zkEmailInvites, pmCfg.defaultBudgetCapPerEpoch, pmCfg.defaultBudgetEpochLen
                )
                : (new bytes32[](0), new uint128[](0), new uint32[](0));

            IPaymasterHub.DeployConfig memory config;
            config.operatorHatId = operatorSubjectId;
            config.maxFeePerGas = pmCfg.maxFeePerGas;
            config.maxPriorityFeePerGas = pmCfg.maxPriorityFeePerGas;
            config.maxCallGas = pmCfg.maxCallGas;
            config.maxVerificationGas = pmCfg.maxVerificationGas;
            config.maxPreVerificationGas = pmCfg.maxPreVerificationGas;
            config.budgetSubjectKeys = budgetKeys;
            config.budgetCapsPerEpoch = budgetCaps;
            config.budgetEpochLens = budgetEpochLens;
            config.typeTargets = typeTargets;
            config.typeIds = typeIds;
            // autoUpgrade orgs mirror the global rulebook; pinned orgs get a Static local snapshot of
            // it and vote changes in afterwards (bootstrap currently requires autoUpgrade=true, so
            // Static-at-deploy is future-proofing). Per-selector local rules stay empty.
            config.rulesMode = params.autoUpgrade ? 0 : 1;

            IPaymasterHub(l.paymasterHub).registerAndConfigureOrg{value: msg.value}(
                params.orgId, adminSubjectId, config
            );
        } else {
            // Simple registration only
            IPaymasterHub(l.paymasterHub).registerOrg(params.orgId, adminSubjectId, operatorSubjectId);
        }
    }

    /**
     * @notice Map the org's deployed contracts (and the shared registries) to module typeIds
     * @dev Sponsored selectors per typeId live in the PaymasterHub's global rulebook, managed by
     *      Poa (setGlobalRulesBatch) — see script/helpers/DefaultGlobalRules.sol for the seed set.
     *      `registryAddr` is the UniversalAccountRegistry (holds `setProfileMetadata`),
     *      `orgRegistryAddr` is the OrgRegistry (holds `updateOrgMetaAsAdmin`) — two distinct
     *      contracts (L-53).
     */
    function _buildTargetTypes(DeploymentResult memory result, address registryAddr, address orgRegistryAddr)
        internal
        pure
        returns (address[] memory typeTargets, bytes32[] memory typeIds)
    {
        bool educationEnabled = result.educationHub != address(0);
        bool zkEmailEnabled = result.zkEmailInvites != address(0);

        uint256 count = 9;
        if (educationEnabled) count += 1;
        if (zkEmailEnabled) count += 1;

        typeTargets = new address[](count);
        typeIds = new bytes32[](count);

        typeTargets[0] = result.quickJoin;
        typeIds[0] = ModuleTypes.QUICK_JOIN_ID;
        typeTargets[1] = result.taskManager;
        typeIds[1] = ModuleTypes.TASK_MANAGER_ID;
        typeTargets[2] = result.hybridVoting;
        typeIds[2] = ModuleTypes.HYBRID_VOTING_ID;
        typeTargets[3] = result.directDemocracyVoting;
        typeIds[3] = ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID;
        typeTargets[4] = result.paymentManager;
        typeIds[4] = ModuleTypes.PAYMENT_MANAGER_ID;
        // The authority carries the user-facing access selectors (claim/renounce/vouch + the
        // manager-delegate verbs) — the v2 successor of the EligibilityModule row.
        typeTargets[5] = result.membershipAuthority;
        typeIds[5] = ModuleTypes.MEMBERSHIP_AUTHORITY_ID;
        typeTargets[6] = result.participationToken;
        typeIds[6] = ModuleTypes.PARTICIPATION_TOKEN_ID;
        typeTargets[7] = registryAddr;
        typeIds[7] = ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID;
        typeTargets[8] = orgRegistryAddr;
        typeIds[8] = ModuleTypes.ORG_REGISTRY_ID;

        uint256 i = 9;
        if (educationEnabled) {
            typeTargets[i] = result.educationHub;
            typeIds[i] = ModuleTypes.EDUCATION_HUB_ID;
            i++;
        }
        if (zkEmailEnabled) {
            typeTargets[i] = result.zkEmailInvites;
            typeIds[i] = ModuleTypes.ZKEMAIL_INVITES_ID;
        }
    }

    /**
     * @notice Build default per-role-subject budget entries (+ the zk-email CLAIM budget when enabled)
     * @dev Creates a budget for each role subject using SUBJECT_TYPE_HAT (0x01). When the org deploys with
     *      ZkEmailInvites, also appends a SUBJECT_TYPE_CLAIM (0x05) budget keyed to the module address —
     *      without it, gasless self-service email claims revert BudgetExceeded (the CLAIM subject has no
     *      eligibility pre-check, so the budget is the org's spend backstop and MUST exist).
     * @param roleSubjectIds Authority subject id for each role
     * @param zkEmailInvites The org's ZkEmailInvites proxy (0 = module not enabled, no claim budget)
     * @param capPerEpoch Default spending cap per epoch for each subject
     * @param epochLen Default epoch length in seconds
     */
    function _buildDefaultBudgets(
        uint256[] memory roleSubjectIds,
        address zkEmailInvites,
        uint128 capPerEpoch,
        uint32 epochLen
    ) internal pure returns (bytes32[] memory subjectKeys, uint128[] memory caps, uint32[] memory epochLens) {
        bool hasClaimBudget = zkEmailInvites != address(0);
        uint256 count = roleSubjectIds.length + (hasClaimBudget ? 1 : 0);
        subjectKeys = new bytes32[](count);
        caps = new uint128[](count);
        epochLens = new uint32[](count);

        for (uint256 i = 0; i < roleSubjectIds.length; i++) {
            // SUBJECT_TYPE_HAT = 0x01, subjectId = bytes32(subject id)
            subjectKeys[i] = keccak256(abi.encodePacked(uint8(0x01), bytes32(roleSubjectIds[i])));
            caps[i] = capPerEpoch;
            epochLens[i] = epochLen;
        }
        if (hasClaimBudget) {
            // SUBJECT_TYPE_CLAIM = 0x05, subjectId = bytes32(module address)
            subjectKeys[count - 1] = keccak256(abi.encodePacked(uint8(0x05), bytes32(uint256(uint160(zkEmailInvites)))));
            caps[count - 1] = capPerEpoch;
            epochLens[count - 1] = epochLen;
        }
    }
}
