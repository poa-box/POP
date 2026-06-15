// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import "./OrgRegistry.sol";
import {IHybridVotingInit} from "./libs/ModuleDeploymentLib.sol";
import {RoleResolver} from "./libs/RoleResolver.sol";
import {GovernanceFactory, IHatsTreeSetup} from "./factories/GovernanceFactory.sol";
import {AccessFactory} from "./factories/AccessFactory.sol";
import {ModulesFactory} from "./factories/ModulesFactory.sol";
import {RoleConfigStructs} from "./libs/RoleConfigStructs.sol";

/*────────────────────── Module‑specific hooks ──────────────────────────*/
interface IParticipationToken {
    function setTaskManager(address) external;
    function setEducationHub(address) external;
}

interface IExecutorAdmin {
    function setCaller(address) external;
    function setHatMinterAuthorization(address minter, bool authorized) external;
    function acceptBeaconOwnership(address beacon) external;
    function configureVouching(
        address eligibilityModule,
        uint256 hatId,
        uint32 quorum,
        uint256 membershipHatId,
        bool combineWithHierarchy
    ) external;
    function batchConfigureVouching(
        address eligibilityModule,
        uint256[] calldata hatIds,
        uint32[] calldata quorums,
        uint256[] calldata membershipHatIds,
        bool[] calldata combineWithHierarchyFlags
    ) external;
    function setDefaultEligibility(address eligibilityModule, uint256 hatId, bool eligible, bool standing) external;
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
    }

    function registerOrg(bytes32 orgId, uint256 adminHatId, uint256 operatorHatId) external;
    function registerAndConfigureOrg(bytes32 orgId, uint256 adminHatId, DeployConfig calldata config) external payable;
    function depositForOrg(bytes32 orgId) external payable;
}

interface ITaskManagerBootstrap {
    struct BootstrapProjectConfig {
        bytes title;
        bytes32 metadataHash;
        uint256 cap;
        address[] managers;
        uint256[] createHats;
        uint256[] claimHats;
        uint256[] reviewHats;
        uint256[] assignHats;
        address[] bountyTokens;
        uint256[] bountyCaps;
    }

    struct BootstrapTaskConfig {
        uint8 projectIndex;
        uint256 payout;
        bytes title;
        bytes32 metadataHash;
        address bountyToken;
        uint256 bountyPayout;
        bool requiresApplication;
    }

    function bootstrapProjectsAndTasks(BootstrapProjectConfig[] calldata projects, BootstrapTaskConfig[] calldata tasks)
        external
        returns (bytes32[] memory projectIds);

    function bootstrapGlobalPerms(uint256[] calldata hatIds, uint8[] calldata masks) external;

    function clearDeployer() external;
}

/**
 * @title OrgDeployer
 * @notice Thin orchestrator for deploying complete organizations using factory pattern
 * @dev Coordinates GovernanceFactory, AccessFactory, and ModulesFactory
 */
contract OrgDeployer is Initializable {
    /// @notice Contract version for tracking deployments
    string public constant VERSION = "1.0.1";

    /*────────────────────────────  Errors  ───────────────────────────────*/
    error InvalidAddress();
    error OrgExistsMismatch();
    error Reentrant();
    error InvalidRoleConfiguration();

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
        address eligibilityModule,
        address toggleModule,
        uint256 topHatId,
        uint256[] roleHatIds
    );

    event RolesCreated(
        bytes32 indexed orgId, uint256[] hatIds, string[] names, string[] images, bytes32[] metadataCIDs, bool[] canVote
    );

    /// @notice Emitted after OrgDeployed to provide initial wearer assignments for subgraph indexing
    event InitialWearersAssigned(
        bytes32 indexed orgId, address indexed eligibilityModule, address[] wearers, uint256[] hatIds
    );

    /*───────────── ERC-7201 Storage ───────────*/
    /// @custom:storage-location erc7201:poa.orgdeployer.storage
    struct Layout {
        GovernanceFactory governanceFactory;
        AccessFactory accessFactory;
        ModulesFactory modulesFactory;
        OrgRegistry orgRegistry;
        address poaManager;
        address hatsTreeSetup;
        address paymasterHub; // Shared PaymasterHub for all orgs
        address universalPasskeyFactory; // Universal PasskeyAccountFactory for all orgs
        uint256 _status; // manual reentrancy guard
        IHats hatsV2; // upgrade-safe hats reference (inside ERC-7201 namespace)
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
    ///      fallback to the legacy slot-0 variable for pre-migration proxies.
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
        address _hatsTreeSetup,
        address _paymasterHub
    ) public initializer {
        if (
            _governanceFactory == address(0) || _accessFactory == address(0) || _modulesFactory == address(0)
                || _poaManager == address(0) || _orgRegistry == address(0) || _hats == address(0)
                || _hatsTreeSetup == address(0) || _paymasterHub == address(0)
        ) {
            revert InvalidAddress();
        }

        Layout storage l = _layout();
        l.governanceFactory = GovernanceFactory(_governanceFactory);
        l.accessFactory = AccessFactory(_accessFactory);
        l.modulesFactory = ModulesFactory(_modulesFactory);
        l.orgRegistry = OrgRegistry(_orgRegistry);
        l.poaManager = _poaManager;
        l.hatsTreeSetup = _hatsTreeSetup;
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
        address eligibilityModule;
    }

    struct RoleAssignments {
        uint256 quickJoinRolesBitmap; // Bit N set = Role N assigned on join
        uint256 tokenMemberRolesBitmap; // Bit N set = Role N can hold tokens
        uint256 tokenApproverRolesBitmap; // Bit N set = Role N can approve transfers
        uint256 taskCreatorRolesBitmap; // Bit N set = Role N can create tasks
        uint256 educationCreatorRolesBitmap; // Bit N set = Role N can create education
        uint256 educationMemberRolesBitmap; // Bit N set = Role N can access education
        uint256 hybridProposalCreatorRolesBitmap; // Bit N set = Role N can create proposals
        uint256 ddVotingRolesBitmap; // Bit N set = Role N can vote in polls
        uint256 ddCreatorRolesBitmap; // Bit N set = Role N can create polls
    }

    struct BootstrapConfig {
        ITaskManagerBootstrap.BootstrapProjectConfig[] projects;
        ITaskManagerBootstrap.BootstrapTaskConfig[] tasks;
    }

    /// @notice Optional org-wide TaskManager role-permission grants applied during bootstrap.
    /// @dev    Each `roleIndices[i]` is resolved against `params.roles[]` to a hat ID and assigned
    ///         the corresponding `masks[i]` (a bitwise OR of `TaskPerm` bits). Equivalent to the
    ///         executor calling `setConfig(ROLE_PERM, abi.encode(hatId, mask))` post-deployment,
    ///         but baked into the atomic deploy. Empty arrays = skip (no grants). `roleIndices.length`
    ///         must equal `masks.length`. Duplicate role indices: last write wins.
    ///         Use this for org-wide grants of `TaskPerm.EDIT_META`, `EDIT_FULL`, `BUDGET`,
    ///         `SELF_REVIEW`, or any future TaskPerm bit. Per-project grants still go through
    ///         `BootstrapProjectConfig.{create,claim,review,assign}Hats`.
    ///
    ///         CAVEAT — per-project overrides shadow global grants. `TaskManager._permMask` returns
    ///         the per-project mask for a hat IF non-zero, otherwise the global mask. If a bootstrap
    ///         project sets per-project perms for the same hat (e.g. `createHats: [executiveRole]`),
    ///         the global mask granted here is silently ignored on that project. To grant EDIT_FULL
    ///         on a bootstrap project, either (a) call `setProjectRolePerm(pid, hat, existing | EDIT_FULL)`
    ///         post-deploy via governance, or (b) create the project post-deploy without per-project
    ///         perms for that hat. Fresh post-deploy projects inherit the global grant correctly.
    struct TaskManagerPermConfig {
        uint256[] roleIndices;
        uint8[] masks;
    }

    struct PaymasterConfig {
        uint256 operatorRoleIndex; // Role index for paymaster operator hat; type(uint256).max = skip (topHat-only)
        bool autoWhitelistContracts; // If true, auto-whitelist deployed org contracts
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        // Budget config (all zeros = skip)
        uint128 defaultBudgetCapPerEpoch; // Default spending cap per epoch for each role hat (0 = no budget)
        uint32 defaultBudgetEpochLen; // Default epoch length in seconds for each role hat (0 = no budget)
    }

    struct DeploymentParams {
        bytes32 orgId;
        string orgName;
        bytes32 metadataHash; // IPFS CID sha256 digest (optional, bytes32(0) is valid)
        address registryAddr;
        address deployerAddress; // Address to receive ADMIN hat
        string deployerUsername; // Optional username for deployer (empty string = skip registration)
        uint256 regDeadline; // EIP-712 signature deadline (0 = skip registration)
        uint256 regNonce; // User's current nonce on the registry
        bytes regSignature; // User's EIP-712 ECDSA signature for username registration
        bool autoUpgrade;
        uint8 hybridThresholdPct;
        uint8 ddThresholdPct;
        IHybridVotingInit.ClassConfig[] hybridClasses;
        address[] ddInitialTargets;
        RoleConfigStructs.RoleConfig[] roles; // Complete role configuration (replaces roleNames, roleImages, roleCanVote)
        RoleAssignments roleAssignments;
        uint256 metadataAdminRoleIndex; // Explicit role index whose hat gets metadata-admin; type(uint256).max = skip (topHat fallback)
        bool passkeyEnabled; // Whether passkey support is enabled (uses universal factory)
        ModulesFactory.EducationHubConfig educationHubConfig; // EducationHub deployment configuration
        BootstrapConfig bootstrap; // Optional: initial projects and tasks to create
        PaymasterConfig paymasterConfig; // Optional: paymaster configuration (funding via msg.value)
        TaskManagerPermConfig taskManagerPerms; // Optional: org-wide TaskManager ROLE_PERM grants
    }

    /*════════════════  VALIDATION  ════════════════*/

    /// @notice Validates role configurations for correctness
    /// @dev Checks indices, prevents cycles, validates vouching configs
    /// @param roles Array of role configurations to validate
    function _validateRoleConfigs(RoleConfigStructs.RoleConfig[] calldata roles) internal pure {
        uint256 len = roles.length;

        // Must have at least one role
        if (len == 0) revert InvalidRoleConfiguration();

        // Practical limit to prevent gas issues
        if (len > 32) revert InvalidRoleConfiguration();

        for (uint256 i = 0; i < len; i++) {
            RoleConfigStructs.RoleConfig calldata role = roles[i];

            // Validate vouching configuration
            if (role.vouching.enabled) {
                // Quorum must be positive
                if (role.vouching.quorum == 0) revert InvalidRoleConfiguration();

                // Voucher role index must be valid
                if (role.vouching.voucherRoleIndex >= len) {
                    revert InvalidRoleConfiguration();
                }
            }

            // Validate hierarchy configuration
            if (role.hierarchy.adminRoleIndex != type(uint256).max) {
                // Admin role index must be valid
                if (role.hierarchy.adminRoleIndex >= len) {
                    revert InvalidRoleConfiguration();
                }

                // Prevent simple self-referential cycles
                if (role.hierarchy.adminRoleIndex == i) {
                    revert InvalidRoleConfiguration();
                }
            }

            // Validate name is not empty
            if (bytes(role.name).length == 0) revert InvalidRoleConfiguration();
        }

        // Note: Full cycle detection would require graph traversal
        // The Hats contract itself will revert if actual cycles exist during tree creation
    }

    /*════════════════  MAIN DEPLOYMENT FUNCTION  ════════════════*/

    function deployFullOrg(DeploymentParams calldata params) external payable returns (DeploymentResult memory result) {
        // Manual reentrancy guard
        Layout storage l = _layout();
        if (l._status == 2) revert Reentrant();
        l._status = 2;

        result = _deployFullOrgInternal(params);

        // Reset reentrancy guard
        l._status = 1;

        return result;
    }

    /*════════════════  INTERNAL ORCHESTRATION  ════════════════*/

    function _deployFullOrgInternal(DeploymentParams calldata params)
        internal
        returns (DeploymentResult memory result)
    {
        Layout storage l = _layout();

        /* 1. Validate role configurations */
        _validateRoleConfigs(params.roles);

        /* 2. Validate deployer address */
        if (params.deployerAddress == address(0)) {
            revert InvalidAddress();
        }

        /* 3. Create Org in bootstrap mode */
        if (!_orgExists(params.orgId)) {
            l.orgRegistry.createOrgBootstrap(params.orgId, bytes(params.orgName), params.metadataHash);
        } else {
            revert OrgExistsMismatch();
        }

        /* 2. Deploy Governance Infrastructure (Executor, Hats modules, Hats tree) */
        GovernanceFactory.GovernanceResult memory gov = _deployGovernanceInfrastructure(params);
        result.executor = gov.executor;
        result.eligibilityModule = gov.eligibilityModule;

        /* 2b. Accept executor beacon ownership (two-step transfer initiated by GovernanceFactory) */
        IExecutorAdmin(result.executor).acceptBeaconOwnership(gov.execBeacon);

        /* 3. Set the executor for the org */
        l.orgRegistry.setOrgExecutor(params.orgId, result.executor);

        /* 4. Register Hats tree in OrgRegistry */
        l.orgRegistry.registerHatsTree(params.orgId, gov.topHatId, gov.roleHatIds);

        /* 4b. Set metadata admin hat (explicit role index; type(uint256).max = skip → topHat fallback) */
        if (params.metadataAdminRoleIndex < params.roles.length) {
            l.orgRegistry.setOrgMetadataAdminHat(params.orgId, gov.roleHatIds[params.metadataAdminRoleIndex]);
        }

        /* 5. Deploy Access Infrastructure (QuickJoin, Token) */
        AccessFactory.AccessResult memory access;
        {
            AccessFactory.RoleAssignments memory accessRoles = AccessFactory.RoleAssignments({
                quickJoinRolesBitmap: params.roleAssignments.quickJoinRolesBitmap,
                tokenMemberRolesBitmap: params.roleAssignments.tokenMemberRolesBitmap,
                tokenApproverRolesBitmap: params.roleAssignments.tokenApproverRolesBitmap
            });

            // Use universal factory if passkey is enabled
            AccessFactory.PasskeyConfig memory passkeyConfig = AccessFactory.PasskeyConfig({
                enabled: params.passkeyEnabled,
                universalFactory: params.passkeyEnabled ? l.universalPasskeyFactory : address(0)
            });

            AccessFactory.AccessParams memory accessParams = AccessFactory.AccessParams({
                orgId: params.orgId,
                orgName: params.orgName,
                poaManager: l.poaManager,
                orgRegistry: address(l.orgRegistry),
                hats: address(_getHats()),
                executor: result.executor,
                deployer: address(this), // For registration callbacks
                registryAddr: params.registryAddr,
                roleHatIds: gov.roleHatIds,
                autoUpgrade: params.autoUpgrade,
                roleAssignments: accessRoles,
                passkeyConfig: passkeyConfig
            });

            access = l.accessFactory.deployAccess(accessParams);
            result.quickJoin = access.quickJoin;
            result.participationToken = access.participationToken;
        }

        /* 6. Deploy Functional Modules (TaskManager, Education, Payment) */
        ModulesFactory.ModulesResult memory modules;
        {
            ModulesFactory.RoleAssignments memory moduleRoles = ModulesFactory.RoleAssignments({
                taskCreatorRolesBitmap: params.roleAssignments.taskCreatorRolesBitmap,
                educationCreatorRolesBitmap: params.roleAssignments.educationCreatorRolesBitmap,
                educationMemberRolesBitmap: params.roleAssignments.educationMemberRolesBitmap
            });

            ModulesFactory.ModulesParams memory moduleParams = ModulesFactory.ModulesParams({
                orgId: params.orgId,
                orgName: params.orgName,
                poaManager: l.poaManager,
                orgRegistry: address(l.orgRegistry),
                hats: address(_getHats()),
                executor: result.executor,
                deployer: address(this), // For registration callbacks
                participationToken: result.participationToken,
                roleHatIds: gov.roleHatIds,
                autoUpgrade: params.autoUpgrade,
                roleAssignments: moduleRoles,
                educationHubConfig: params.educationHubConfig
            });

            modules = l.modulesFactory.deployModules(moduleParams);
            result.taskManager = modules.taskManager;
            result.educationHub = modules.educationHub;
            result.paymentManager = modules.paymentManager;
        }

        /* 7. Deploy Voting Mechanisms (HybridVoting, DirectDemocracyVoting) */
        (result.hybridVoting, result.directDemocracyVoting) =
            _deployVotingMechanisms(params, result.executor, result.participationToken, gov.roleHatIds);

        /* 7b. Register and configure org with PaymasterHub (after all modules deployed) */
        _configurePaymaster(l, params, result, gov.topHatId, gov.roleHatIds);

        /* 8. Wire up cross-module connections */
        IParticipationToken(result.participationToken).setTaskManager(result.taskManager);
        if (params.educationHubConfig.enabled) {
            IParticipationToken(result.participationToken).setEducationHub(result.educationHub);
        }

        /* 8.5a. Bootstrap org-wide TaskManager ROLE_PERM grants (EDIT_META/EDIT_FULL/BUDGET/etc).
                 Runs BEFORE project bootstrap so per-project hat masks can override the global
                 mask (project mask != 0 takes precedence in _permMask).
                 Enter the block whenever EITHER array is non-empty so the length-mismatch check
                 inside `bootstrapGlobalPerms` fires for malformed configs (e.g. empty roleIndices
                 + non-empty masks would otherwise be silently dropped). */
        if (params.taskManagerPerms.roleIndices.length > 0 || params.taskManagerPerms.masks.length > 0) {
            uint256[] memory permHatIds =
                _resolveRoleIndicesToHatIds(params.taskManagerPerms.roleIndices, gov.roleHatIds);
            ITaskManagerBootstrap(result.taskManager).bootstrapGlobalPerms(permHatIds, params.taskManagerPerms.masks);
        }

        /* 8.5. Bootstrap initial projects and tasks if configured */
        if (params.bootstrap.projects.length > 0) {
            // Resolve role indices to hat IDs in bootstrap config
            ITaskManagerBootstrap.BootstrapProjectConfig[] memory resolvedProjects =
                _resolveBootstrapRoles(params.bootstrap.projects, gov.roleHatIds);
            ITaskManagerBootstrap(result.taskManager)
                .bootstrapProjectsAndTasks(resolvedProjects, params.bootstrap.tasks);
        }

        /* 8.6. Clear deployer address to prevent future bootstrap calls (defense-in-depth) */
        ITaskManagerBootstrap(result.taskManager).clearDeployer();

        /* 9. Authorize QuickJoin to mint hats */
        IExecutorAdmin(result.executor).setHatMinterAuthorization(result.quickJoin, true);

        /* 10. Link executor to governor */
        IExecutorAdmin(result.executor).setCaller(result.hybridVoting);

        /* 10.5. Configure vouching system from role configurations (batch optimized) */
        {
            // Count roles with vouching enabled
            uint256 vouchCount = 0;
            for (uint256 i = 0; i < params.roles.length; i++) {
                if (params.roles[i].vouching.enabled) vouchCount++;
            }

            if (vouchCount > 0) {
                uint256[] memory hatIds = new uint256[](vouchCount);
                uint32[] memory quorums = new uint32[](vouchCount);
                uint256[] memory membershipHatIds = new uint256[](vouchCount);
                bool[] memory combineFlags = new bool[](vouchCount);
                uint256 vouchIndex = 0;

                for (uint256 i = 0; i < params.roles.length; i++) {
                    RoleConfigStructs.RoleConfig calldata role = params.roles[i];
                    if (role.vouching.enabled) {
                        hatIds[vouchIndex] = gov.roleHatIds[i];
                        quorums[vouchIndex] = role.vouching.quorum;
                        membershipHatIds[vouchIndex] = gov.roleHatIds[role.vouching.voucherRoleIndex];
                        combineFlags[vouchIndex] = role.vouching.combineWithHierarchy;
                        vouchIndex++;
                    }
                }

                IExecutorAdmin(result.executor)
                    .batchConfigureVouching(gov.eligibilityModule, hatIds, quorums, membershipHatIds, combineFlags);
            }
        }

        /* 11. Renounce executor ownership - now only governed by voting */
        OwnableUpgradeable(result.executor).renounceOwnership();

        /* 12. Emit event for subgraph indexing */
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
            gov.eligibilityModule,
            gov.toggleModule,
            gov.topHatId,
            gov.roleHatIds
        );

        /* 12b. Emit initial wearer assignments for subgraph User creation */
        {
            (address[] memory wearers, uint256[] memory hatIds) =
                _collectInitialWearers(params.roles, gov.roleHatIds, params.deployerAddress);

            if (wearers.length > 0) {
                emit InitialWearersAssigned(params.orgId, gov.eligibilityModule, wearers, hatIds);
            }
        }

        /* 13. Emit role metadata for subgraph indexing */
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

            emit RolesCreated(params.orgId, gov.roleHatIds, names, images, metadataCIDs, canVoteFlags);
        }

        return result;
    }

    /*══════════════  UTILITIES  ═════════════=*/

    function _orgExists(bytes32 id) internal view returns (bool) {
        (,,, bool exists) = _layout().orgRegistry.orgOf(id);
        return exists;
    }

    /**
     * @notice Collects all initial wearers from role configurations
     * @dev Used to emit InitialWearersAssigned event for subgraph indexing
     */
    function _collectInitialWearers(
        RoleConfigStructs.RoleConfig[] calldata roles,
        uint256[] memory roleHatIds,
        address deployerAddress
    ) internal pure returns (address[] memory wearers, uint256[] memory hatIds) {
        // First pass: count total wearers
        uint256 totalCount = 0;
        for (uint256 i = 0; i < roles.length; i++) {
            if (!roles[i].canVote) continue;
            if (roles[i].distribution.mintToDeployer) totalCount++;
            totalCount += roles[i].distribution.additionalWearers.length;
        }

        // Second pass: populate arrays
        wearers = new address[](totalCount);
        hatIds = new uint256[](totalCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < roles.length; i++) {
            if (!roles[i].canVote) continue;
            uint256 hatId = roleHatIds[i];

            if (roles[i].distribution.mintToDeployer) {
                wearers[idx] = deployerAddress;
                hatIds[idx] = hatId;
                idx++;
            }
            for (uint256 j = 0; j < roles[i].distribution.additionalWearers.length; j++) {
                wearers[idx] = roles[i].distribution.additionalWearers[j];
                hatIds[idx] = hatId;
                idx++;
            }
        }
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
        govParams.hatsTreeSetup = l.hatsTreeSetup;
        govParams.deployer = address(this);
        govParams.deployerAddress = params.deployerAddress; // Pass deployer address for ADMIN hat
        govParams.accountRegistry = params.registryAddr; // UniversalAccountRegistry for username registration
        govParams.participationToken = address(0);
        govParams.deployerUsername = params.deployerUsername; // Optional username (empty = skip)
        govParams.regDeadline = params.regDeadline;
        govParams.regNonce = params.regNonce;
        govParams.regSignature = params.regSignature;
        govParams.autoUpgrade = params.autoUpgrade;
        govParams.hybridThresholdPct = params.hybridThresholdPct;
        govParams.ddThresholdPct = params.ddThresholdPct;
        govParams.hybridClasses = params.hybridClasses;
        govParams.hybridProposalCreatorRolesBitmap = params.roleAssignments.hybridProposalCreatorRolesBitmap;
        govParams.ddVotingRolesBitmap = params.roleAssignments.ddVotingRolesBitmap;
        govParams.ddCreatorRolesBitmap = params.roleAssignments.ddCreatorRolesBitmap;
        govParams.ddInitialTargets = params.ddInitialTargets;
        govParams.roles = params.roles;

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
        uint256[] memory roleHatIds
    ) internal returns (address hybridVoting, address directDemocracyVoting) {
        Layout storage l = _layout();

        GovernanceFactory.GovernanceParams memory votingParams;
        votingParams.orgId = params.orgId;
        votingParams.orgName = params.orgName;
        votingParams.poaManager = l.poaManager;
        votingParams.orgRegistry = address(l.orgRegistry);
        votingParams.hats = address(_getHats());
        votingParams.hatsTreeSetup = l.hatsTreeSetup;
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

        return l.governanceFactory.deployVoting(votingParams, executor, roleHatIds);
    }

    /**
     * @notice Allows factories to register contracts via OrgDeployer's ownership
     * @dev Only callable by approved factory contracts during deployment
     */
    function registerContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUpgrade,
        address moduleOwner,
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
        if (!bootstrap) revert("Deployment complete");

        // Forward registration to OrgRegistry (we are the owner)
        l.orgRegistry.registerOrgContract(orgId, typeId, proxy, beacon, autoUpgrade, moduleOwner, lastRegister);
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
        if (!bootstrap) revert("Deployment complete");

        // Forward batch registration to OrgRegistry (we are the owner)
        l.orgRegistry.batchRegisterOrgContracts(orgId, registrations, autoUpgrade, lastRegister);
    }

    /**
     * @notice Resolve role indices to hat IDs in bootstrap project configs
     * @dev Role indices in config are converted to actual hat IDs using roleHatIds array
     */
    function _resolveBootstrapRoles(
        ITaskManagerBootstrap.BootstrapProjectConfig[] calldata projects,
        uint256[] memory roleHatIds
    ) internal pure returns (ITaskManagerBootstrap.BootstrapProjectConfig[] memory resolved) {
        resolved = new ITaskManagerBootstrap.BootstrapProjectConfig[](projects.length);

        for (uint256 i = 0; i < projects.length; i++) {
            resolved[i] = ITaskManagerBootstrap.BootstrapProjectConfig({
                title: projects[i].title,
                metadataHash: projects[i].metadataHash,
                cap: projects[i].cap,
                managers: projects[i].managers,
                createHats: _resolveRoleIndicesToHatIds(projects[i].createHats, roleHatIds),
                claimHats: _resolveRoleIndicesToHatIds(projects[i].claimHats, roleHatIds),
                reviewHats: _resolveRoleIndicesToHatIds(projects[i].reviewHats, roleHatIds),
                assignHats: _resolveRoleIndicesToHatIds(projects[i].assignHats, roleHatIds),
                bountyTokens: projects[i].bountyTokens,
                bountyCaps: projects[i].bountyCaps
            });
        }

        return resolved;
    }

    /**
     * @notice Convert array of role indices to array of hat IDs
     */
    function _resolveRoleIndicesToHatIds(uint256[] calldata roleIndices, uint256[] memory roleHatIds)
        internal
        pure
        returns (uint256[] memory hatIds)
    {
        hatIds = new uint256[](roleIndices.length);
        for (uint256 i = 0; i < roleIndices.length; i++) {
            require(roleIndices[i] < roleHatIds.length, "Invalid role index in bootstrap config");
            hatIds[i] = roleHatIds[roleIndices[i]];
        }
        return hatIds;
    }

    /*══════════════  PAYMASTER CONFIGURATION  ═════════════=*/

    /**
     * @notice Register and optionally configure the org's PaymasterHub entry
     * @dev Moved after all modules deployed so we know contract addresses for auto-whitelisting
     */
    function _configurePaymaster(
        Layout storage l,
        DeploymentParams calldata params,
        DeploymentResult memory result,
        uint256 topHatId,
        uint256[] memory roleHatIds
    ) internal {
        PaymasterConfig calldata pmCfg = params.paymasterConfig;

        // Resolve operator hat from role index (type(uint256).max = skip → operatorHatId stays 0)
        uint256 operatorHatId = 0;
        if (pmCfg.operatorRoleIndex < params.roles.length) {
            operatorHatId = roleHatIds[pmCfg.operatorRoleIndex];
        }

        bool hasFeeCaps = pmCfg.maxFeePerGas != 0 || pmCfg.maxPriorityFeePerGas != 0 || pmCfg.maxCallGas != 0
            || pmCfg.maxVerificationGas != 0 || pmCfg.maxPreVerificationGas != 0;
        bool hasBudgets = pmCfg.defaultBudgetCapPerEpoch != 0 && pmCfg.defaultBudgetEpochLen != 0;
        bool hasConfig = hasFeeCaps || pmCfg.autoWhitelistContracts || hasBudgets || msg.value > 0;

        if (hasConfig) {
            // Build rules for auto-whitelisting deployed contracts
            (address[] memory targets, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory gasHints) = pmCfg.autoWhitelistContracts
                ? _buildDefaultPaymasterRules(result, params.educationHubConfig.enabled, params.registryAddr)
                : (new address[](0), new bytes4[](0), new bool[](0), new uint32[](0));

            // Build per-role-hat budgets if configured
            (bytes32[] memory budgetKeys, uint128[] memory budgetCaps, uint32[] memory budgetEpochLens) = hasBudgets
                ? _buildDefaultBudgets(roleHatIds, pmCfg.defaultBudgetCapPerEpoch, pmCfg.defaultBudgetEpochLen)
                : (new bytes32[](0), new uint128[](0), new uint32[](0));

            IPaymasterHub.DeployConfig memory config = IPaymasterHub.DeployConfig({
                operatorHatId: operatorHatId,
                maxFeePerGas: pmCfg.maxFeePerGas,
                maxPriorityFeePerGas: pmCfg.maxPriorityFeePerGas,
                maxCallGas: pmCfg.maxCallGas,
                maxVerificationGas: pmCfg.maxVerificationGas,
                maxPreVerificationGas: pmCfg.maxPreVerificationGas,
                ruleTargets: targets,
                ruleSelectors: selectors,
                ruleAllowed: allowed,
                ruleMaxCallGasHints: gasHints,
                budgetSubjectKeys: budgetKeys,
                budgetCapsPerEpoch: budgetCaps,
                budgetEpochLens: budgetEpochLens
            });

            IPaymasterHub(l.paymasterHub).registerAndConfigureOrg{value: msg.value}(params.orgId, topHatId, config);
        } else {
            // Simple registration only (backwards compatible)
            IPaymasterHub(l.paymasterHub).registerOrg(params.orgId, topHatId, operatorHatId);
        }
    }

    /**
     * @notice Build default paymaster whitelist rules for deployed org contracts
     * @dev Whitelists common user-facing functions on QuickJoin, TaskManager, Voting, etc.
     *      Split into per-contract helpers to stay under stack-depth limits with via_ir.
     */
    function _buildDefaultPaymasterRules(DeploymentResult memory result, bool educationEnabled, address registryAddr)
        internal
        pure
        returns (address[] memory targets, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory gasHints)
    {
        // Count: QuickJoin(6) + TaskManager(16) + HybridVoting(3) + DDVoting(3) + PaymentManager(5) + EligibilityModule(5) + ParticipationToken(3) + Registry(2) + EducationHub(0 or 4)
        uint256 count = 43;
        if (educationEnabled) count += 4;

        targets = new address[](count);
        selectors = new bytes4[](count);
        allowed = new bool[](count);
        gasHints = new uint32[](count);

        uint256 i = 0;
        i = _appendQuickJoinRules(targets, selectors, result.quickJoin, i);
        i = _appendTaskManagerRules(targets, selectors, result.taskManager, i);
        i = _appendVotingRules(targets, selectors, result.hybridVoting, result.directDemocracyVoting, i);
        i = _appendPaymentManagerRules(targets, selectors, result.paymentManager, i);
        i = _appendEligibilityRules(targets, selectors, result.eligibilityModule, i);
        i = _appendParticipationTokenRules(targets, selectors, result.participationToken, i);

        targets[i] = registryAddr;
        selectors[i] = bytes4(keccak256("setProfileMetadata(bytes32)"));
        i++;
        targets[i] = registryAddr;
        selectors[i] = bytes4(keccak256("updateOrgMetaAsAdmin(bytes32,bytes,bytes32)"));
        i++;

        if (educationEnabled) {
            _appendEducationHubRules(targets, selectors, result.educationHub, i);
            i += 4;
        }

        // Set all rules to allowed with 0 gas hint (use default)
        for (uint256 j = 0; j < count; j++) {
            allowed[j] = true;
        }
    }

    function _appendQuickJoinRules(address[] memory targets, bytes4[] memory selectors, address qj, uint256 i)
        private
        pure
        returns (uint256)
    {
        targets[i] = qj;
        selectors[i] = bytes4(keccak256("quickJoinWithUser()"));
        i++;
        targets[i] = qj;
        selectors[i] = bytes4(keccak256("registerAndQuickJoin(address,string,uint256,uint256,bytes)"));
        i++;
        targets[i] = qj;
        selectors[i] = bytes4(
            keccak256(
                "registerAndQuickJoinWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32))"
            )
        );
        i++;
        targets[i] = qj;
        selectors[i] = bytes4(keccak256("claimHatsWithUser(uint256[])"));
        i++;
        targets[i] = qj;
        selectors[i] = bytes4(keccak256("registerAndClaimHats(address,string,uint256,uint256,bytes,uint256[])"));
        i++;
        targets[i] = qj;
        selectors[i] = bytes4(
            keccak256(
                "registerAndClaimHatsWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),uint256[])"
            )
        );
        i++;
        return i;
    }

    function _appendTaskManagerRules(address[] memory targets, bytes4[] memory selectors, address tm, uint256 i)
        private
        pure
        returns (uint256)
    {
        // TaskManager v6: create/update selectors carry deadline params (uint48 absoluteDeadline,
        // uint32 completionWindow appended).
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("createTask(uint256,bytes,bytes32,bytes32,address,uint256,bool,uint48,uint32)"));
        i++;
        targets[i] = tm;
        selectors[i] =
            bytes4(keccak256("createTasksBatch(bytes32,(uint256,bytes,bytes32,address,uint256,bool,uint48,uint32)[])"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("claimTask(uint256)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("submitTask(uint256,bytes32)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("completeTask(uint256)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("applyForTask(uint256,bytes32)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("approveApplication(uint256,address)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("assignTask(uint256,address)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("rejectTask(uint256,bytes32)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("cancelTask(uint256)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(
            keccak256("createAndAssignTask(uint256,bytes,bytes32,bytes32,address,address,uint256,bool,uint48,uint32)")
        );
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(
            keccak256(
                "createProject((bytes,bytes32,uint256,address[],uint256[],uint256[],uint256[],uint256[],address[],uint256[]))"
            )
        );
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("deleteProject(bytes32)"));
        i++;
        // TaskManager v4: setFolders is gated on executor OR organizerHatIds wearer;
        // whitelist for gasless 4337/passkey calls by organizer-hat holders.
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("setFolders(bytes32,bytes32)"));
        i++;
        // TaskManager v5: post-claim edit functions, gated on EDIT_META / EDIT_FULL perms.
        // Whitelist for gasless 4337/passkey calls by edit-permitted hat holders.
        // (updateTask signature is the v6 variant with deadline params.)
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("updateTask(uint256,uint256,bytes,bytes32,address,uint256,uint48,uint32)"));
        i++;
        targets[i] = tm;
        selectors[i] = bytes4(keccak256("updateTaskMetadata(uint256,bytes,bytes32)"));
        i++;
        return i;
    }

    function _appendVotingRules(address[] memory targets, bytes4[] memory selectors, address hv, address ddv, uint256 i)
        private
        pure
        returns (uint256)
    {
        bytes4 voteSel = bytes4(keccak256("vote(uint256,uint8[],uint8[])"));
        bytes4 announceSel = bytes4(keccak256("announceWinner(uint256)"));
        bytes4 proposalSel =
            bytes4(keccak256("createProposal(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[])"));

        targets[i] = hv;
        selectors[i] = voteSel;
        i++;
        targets[i] = hv;
        selectors[i] = announceSel;
        i++;
        targets[i] = hv;
        selectors[i] = proposalSel;
        i++;
        targets[i] = ddv;
        selectors[i] = voteSel;
        i++;
        targets[i] = ddv;
        selectors[i] = announceSel;
        i++;
        targets[i] = ddv;
        selectors[i] = proposalSel;
        i++;
        return i;
    }

    function _appendPaymentManagerRules(address[] memory targets, bytes4[] memory selectors, address pm, uint256 i)
        private
        pure
        returns (uint256)
    {
        targets[i] = pm;
        selectors[i] = bytes4(keccak256("claimDistribution(uint256,uint256,bytes32[])"));
        i++;
        targets[i] = pm;
        selectors[i] = bytes4(keccak256("claimMultiple(uint256[],uint256[],bytes32[][])"));
        i++;
        targets[i] = pm;
        selectors[i] = bytes4(keccak256("optOut(bool)"));
        i++;
        targets[i] = pm;
        selectors[i] = bytes4(keccak256("createDistribution(address,uint256,bytes32,uint256)"));
        i++;
        targets[i] = pm;
        selectors[i] = bytes4(keccak256("finalizeDistribution(uint256,uint256)"));
        i++;
        return i;
    }

    function _appendEligibilityRules(address[] memory targets, bytes4[] memory selectors, address em, uint256 i)
        private
        pure
        returns (uint256)
    {
        targets[i] = em;
        selectors[i] = bytes4(keccak256("claimVouchedHat(uint256)"));
        i++;
        targets[i] = em;
        selectors[i] = bytes4(keccak256("vouchFor(address,uint256)"));
        i++;
        targets[i] = em;
        selectors[i] = bytes4(keccak256("revokeVouch(address,uint256)"));
        i++;
        targets[i] = em;
        selectors[i] = bytes4(keccak256("applyForRole(uint256,bytes32)"));
        i++;
        targets[i] = em;
        selectors[i] = bytes4(keccak256("withdrawApplication(uint256)"));
        i++;
        return i;
    }

    function _appendParticipationTokenRules(address[] memory targets, bytes4[] memory selectors, address pt, uint256 i)
        private
        pure
        returns (uint256)
    {
        targets[i] = pt;
        selectors[i] = bytes4(keccak256("requestTokens(uint96,string)"));
        i++;
        targets[i] = pt;
        selectors[i] = bytes4(keccak256("approveRequest(uint256)"));
        i++;
        targets[i] = pt;
        selectors[i] = bytes4(keccak256("cancelRequest(uint256)"));
        i++;
        return i;
    }

    function _appendEducationHubRules(
        address[] memory targets,
        bytes4[] memory selectors,
        address educationHub,
        uint256 startIdx
    ) private pure {
        targets[startIdx] = educationHub;
        selectors[startIdx] = bytes4(keccak256("completeModule(uint256,uint8)"));
        targets[startIdx + 1] = educationHub;
        selectors[startIdx + 1] = bytes4(keccak256("createModule(bytes,bytes32,uint256,uint8)"));
        targets[startIdx + 2] = educationHub;
        selectors[startIdx + 2] = bytes4(keccak256("updateModule(uint256,bytes,bytes32,uint256)"));
        targets[startIdx + 3] = educationHub;
        selectors[startIdx + 3] = bytes4(keccak256("removeModule(uint256)"));
    }

    /**
     * @notice Build default per-role-hat budget entries
     * @dev Creates a budget for each role hat using SUBJECT_TYPE_HAT (0x01)
     * @param roleHatIds Array of hat IDs for each role
     * @param capPerEpoch Default spending cap per epoch for each hat
     * @param epochLen Default epoch length in seconds
     */
    function _buildDefaultBudgets(uint256[] memory roleHatIds, uint128 capPerEpoch, uint32 epochLen)
        internal
        pure
        returns (bytes32[] memory subjectKeys, uint128[] memory caps, uint32[] memory epochLens)
    {
        uint256 count = roleHatIds.length;
        subjectKeys = new bytes32[](count);
        caps = new uint128[](count);
        epochLens = new uint32[](count);

        for (uint256 i = 0; i < count; i++) {
            // SUBJECT_TYPE_HAT = 0x01, subjectId = bytes32(hatId)
            subjectKeys[i] = keccak256(abi.encodePacked(uint8(0x01), bytes32(roleHatIds[i])));
            caps[i] = capPerEpoch;
            epochLens[i] = epochLen;
        }
    }
}
