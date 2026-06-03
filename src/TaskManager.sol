// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────── OpenZeppelin Upgradeables ────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*────────── Internal Libraries ──────────*/
import {TaskPerm} from "./libs/TaskPerm.sol";
import {BudgetLib} from "./libs/BudgetLib.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";

/*────────── External Hats interface ──────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";

/*────────── External Interfaces ──────────*/
interface IParticipationToken is IERC20 {
    function mint(address, uint256) external;
}

/*────────────────────── Contract ───────────────────────*/
contract TaskManager is Initializable, ContextUpgradeable {
    using SafeERC20 for IERC20;
    using BudgetLib for BudgetLib.Budget;
    using ValidationLib for address;
    using ValidationLib for bytes;

    /*──────── Errors ───────*/
    /// @notice Project or task ID does not exist (or task id beyond `nextTaskId`).
    error NotFound();
    /// @notice Task status forbids this transition (e.g. completing an unclaimed task).
    error BadStatus();
    /// @notice Caller does not wear any creator hat and is not the executor.
    error NotCreator();
    /// @notice Caller is not the task's current claimer.
    error NotClaimer();
    /// @notice Caller is not the configured executor.
    error NotExecutor();
    /// @notice Caller is not the bootstrap deployer (or bootstrap phase is over).
    error NotDeployer();
    /// @notice Caller lacks the hat-derived permission and is not a project manager.
    error Unauthorized();
    /// @notice Address has not applied to this task.
    error NotApplicant();
    /// @notice Applicant has already submitted an application for this task.
    error AlreadyApplied();
    /// @notice Task is application-only; caller used the direct-claim path.
    error RequiresApplication();
    /// @notice Task does not accept applications; caller used the application path.
    error NoApplicationRequired();
    /// @notice Bootstrap task referenced a project index outside the project array.
    error InvalidIndex();
    /// @notice Claimer attempted to complete their own task without SELF_REVIEW permission.
    error SelfReviewNotAllowed();
    /// @notice Parallel calldata arrays have mismatched lengths.
    error ArrayLengthMismatch();
    /// @notice Batch input array is empty.
    error EmptyBatch();
    /// @notice A capability mask passed to a perm setter was not exactly one TaskPerm flag.
    error InvalidCapMask();
    /// @notice Caller is neither the executor nor a wearer of any organizer hat.
    error NotOrganizer();
    /// @notice CAS guard: caller-supplied current folders root does not match storage.
    /// @param expected Root the caller believed was current.
    /// @param actual   Root that is actually current on-chain.
    error FoldersRootStale(bytes32 expected, bytes32 actual);

    /*──────── Constants ─────*/
    bytes4 public constant MODULE_ID = 0x54534b32; // "TSK2"

    /*──────── Enums ─────*/
    enum HatType {
        CREATOR
    }

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

    /*──────── Data Types ────*/
    enum Status {
        UNCLAIMED,
        CLAIMED,
        SUBMITTED,
        COMPLETED,
        CANCELLED
    }

    struct Task {
        bytes32 projectId; // slot 1: full 32 bytes
        uint96 payout; // slot 2: 12 bytes (supports up to 7e28, well over 1e24 cap), voting token payout
        address claimer; // slot 2: 20 bytes (total 32 bytes in slot 2)
        uint96 bountyPayout; // slot 3: 12 bytes, additional payout in bounty currency
        bool requiresApplication; // slot 3: 1 byte
        Status status; // slot 3: 1 byte (enum fits in 1 byte)
        address bountyToken; // slot 4: 20 bytes (optimized packing: small fields grouped together)
    }

    struct Project {
        mapping(address => bool) managers; // slot 0: mapping (full slot)
        uint128 cap; // slot 1: 16 bytes — PT cap (0 = unlimited, minted tokens)
        uint128 spent; // slot 1: 16 bytes — PT committed spend
        bool exists; // slot 2: 1 byte (separate slot for cleaner access)
        // Bounty budgets use BudgetLib semantics: cap 0 = DISABLED, UNLIMITED = no limit
        mapping(address => BudgetLib.Budget) bountyBudgets; // per-token ERC-20 budget
    }

    /*──────── Bootstrap Config Structs ───────*/
    struct BootstrapProjectConfig {
        bytes title;
        bytes32 metadataHash;
        uint256 cap;
        address[] managers;
        // Per-project capability hat overrides. A value of 0 means "use the global capability hat".
        // The Hats-native model is one capability hat per gate (CREATE/CLAIM/REVIEW/ASSIGN); a project
        // can override the global hat for any of these by setting a non-zero hat ID here.
        uint256 createHat;
        uint256 claimHat;
        uint256 reviewHat;
        uint256 assignHat;
        address[] bountyTokens;
        uint256[] bountyCaps;
    }

    struct BootstrapTaskConfig {
        uint8 projectIndex; // References project in same batch (0 for first project)
        uint256 payout;
        bytes title;
        bytes32 metadataHash;
        address bountyToken;
        uint256 bountyPayout;
        bool requiresApplication;
    }

    struct CreateTaskInput {
        uint256 payout;
        bytes title;
        bytes32 metadataHash;
        address bountyToken;
        uint256 bountyPayout;
        bool requiresApplication;
    }

    /*──────── Storage (ERC-7201) ───────*/
    struct Layout {
        mapping(bytes32 => Project) _projects;
        mapping(uint256 => Task) _tasks;
        IHats hats;
        IParticipationToken token;
        uint256[] creatorHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        uint48 nextTaskId;
        uint48 nextProjectId;
        address executor; // 20 bytes + 2*6 bytes = 32 bytes (one slot)
        mapping(uint256 => uint8) rolePermGlobal; // DEPRECATED: dead state (old bitmask model)
        mapping(bytes32 => mapping(uint256 => uint8)) rolePermProj; // DEPRECATED: dead state
        uint256[] permissionHatIds; // DEPRECATED: dead state
        mapping(uint256 => address[]) taskApplicants; // task ID => array of applicants
        mapping(uint256 => mapping(address => bytes32)) taskApplications; // task ID => applicant => application hash
        address deployer; // OrgDeployer address for bootstrap operations
        mapping(uint256 => uint256) projectPermHatRefCount; // DEPRECATED: dead state (old bitmask model)
        // ─── Folders (v4, retained from main — slots preserved for live-org upgrade safety) ───
        // Folder tree (names, parents, ordering, project assignments) lives off-chain in IPFS.
        // Only the root hash is on-chain; reorganization = swap the hash via setFolders.
        // Folders are orthogonal to the capability-hat permission model; `organizerHatIds`
        // remains a HatManager array gate (coarse folder-admin authority, not a task capability).
        bytes32 foldersRoot;
        uint256[] organizerHatIds; // hats authorized to reorganize the folder tree
        // ─── Hats-native capability hats (one per gate) — appended after main's folder slots ───
        uint256 projectCreatorHat; // capability hat gating createProject / updateTask / cancelTask
        uint256 createHat; // global capability hat gating createTask
        uint256 claimHat; // global capability hat gating claimTask / applyForTask
        uint256 reviewHat; // global capability hat gating completeTask / rejectTask
        uint256 assignHat; // global capability hat gating assignTask / approveApplication
        uint256 selfReviewHat; // capability hat allowing a claimer to complete their own task
        uint256 budgetHat; // global capability hat gating budget edits (BOUNTY_CAP / PROJECT_CAP)
        uint256 editMetaHat; // global capability hat gating post-claim title/metadata edits
        uint256 editFullHat; // global capability hat gating post-claim payout/bounty edits
        // Per-project capability overrides: 0 means "use the global capability hat"
        mapping(bytes32 => mapping(uint8 => uint256)) projectCapHat; // pid => TaskPerm flag => hatId
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.taskmanager.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*──────── Events ───────*/
    /// @notice A role hat of `hatType` was added or removed from its enumeration array.
    event HatSet(HatType hatType, uint256 hat, bool allowed);
    /// @notice A project was created. `metadataHash` is an IPFS CID — not stored on-chain.
    event ProjectCreated(bytes32 indexed id, bytes title, bytes32 metadataHash, uint256 cap);
    /// @notice The participation-token cap on a project changed.
    event ProjectCapUpdated(bytes32 indexed id, uint256 oldCap, uint256 newCap);
    /// @notice A project manager was added or removed.
    event ProjectManagerUpdated(bytes32 indexed id, address indexed manager, bool isManager);
    /// @notice A project and all of its hat-permission overrides were deleted.
    event ProjectDeleted(bytes32 indexed id);
    /// @notice A hat's project-specific permission mask was updated.
    event ProjectRolePermSet(bytes32 indexed id, uint256 indexed hatId, uint8 mask);
    /// @notice A hat's GLOBAL permission mask changed via `setConfig(ROLE_PERM, ...)`.
    /// @dev Mirrors `ProjectRolePermSet` minus the project id. Indexers track which
    ///      hats have which `TaskPerm` bits at the org level; `setProjectRolePerm`
    ///      handles the per-project override.
    event RolePermSet(uint256 indexed hatId, uint8 mask);
    /// @notice A per-project bounty-token cap changed.
    event BountyCapSet(bytes32 indexed projectId, address indexed token, uint256 oldCap, uint256 newCap);
    /// @notice The IPFS root for this org's folder tree changed.
    /// @dev Subgraph consumers resolve the JSON off-chain at `newRoot`. `oldRoot` lets indexers chain revisions.
    event FoldersUpdated(bytes32 indexed newRoot, bytes32 indexed oldRoot, address indexed sender);
    /// @notice A hat was added to or removed from the organizer-hat array.
    event OrganizerHatAllowed(uint256 indexed hatId, bool allowed);

    /// @notice A new task was created under `project`.
    event TaskCreated(
        uint256 indexed id,
        bytes32 indexed project,
        uint256 payout,
        address bountyToken,
        uint256 bountyPayout,
        bool requiresApplication,
        bytes title,
        bytes32 metadataHash
    );
    /// @notice An unclaimed task's mutable fields were updated.
    event TaskUpdated(
        uint256 indexed id, uint256 payout, address bountyToken, uint256 bountyPayout, bytes title, bytes32 metadataHash
    );
    /// @notice A claimer submitted work for review.
    event TaskSubmitted(uint256 indexed id, bytes32 submissionHash);
    /// @notice A task was claimed by `claimer`.
    event TaskClaimed(uint256 indexed id, address indexed claimer);
    /// @notice A task was assigned to `assignee` by `assigner` (bypasses claim flow).
    event TaskAssigned(uint256 indexed id, address indexed assignee, address indexed assigner);
    /// @notice A task was marked completed and payouts/bounties were dispatched.
    event TaskCompleted(uint256 indexed id, address indexed completer);
    /// @notice A task was cancelled and its budget reservations rolled back.
    event TaskCancelled(uint256 indexed id, address indexed canceller);
    /// @notice A submitted task was rejected and reverted to CLAIMED for resubmission.
    event TaskRejected(uint256 indexed id, address indexed rejector, bytes32 rejectionHash);
    /// @notice An applicant submitted an application for a task that requires one.
    event TaskApplicationSubmitted(uint256 indexed id, address indexed applicant, bytes32 applicationHash);
    /// @notice An application was approved and the task moved to CLAIMED for `applicant`.
    event TaskApplicationApproved(uint256 indexed id, address indexed applicant, address indexed approver);
    /// @notice The executor address was set or changed.
    event ExecutorUpdated(address newExecutor);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*──────── Initialiser ───────*/
    /**
     * @notice One-time proxy initializer. Wires the org's PT, Hats, executor, and
     *         (optional) bootstrap deployer; seeds the project-creator capability hat.
     * @param tokenAddress       Participation token (must implement `mint`).
     * @param hatsAddress        Hats Protocol contract.
     * @param projectCreatorHat_ Capability hat gating createProject (0 = unset).
     * @param executorAddress    Executor address (DAO execution layer).
     * @param deployerAddress    OrgDeployer address for `bootstrapProjectsAndTasks`; may be zero.
     */
    function initialize(
        address tokenAddress,
        address hatsAddress,
        uint256 projectCreatorHat_,
        address executorAddress,
        address deployerAddress
    ) external initializer {
        tokenAddress.requireNonZeroAddress();
        hatsAddress.requireNonZeroAddress();
        executorAddress.requireNonZeroAddress();

        __Context_init();

        Layout storage l = _layout();
        l.token = IParticipationToken(tokenAddress);
        l.hats = IHats(hatsAddress);
        l.executor = executorAddress;
        l.deployer = deployerAddress; // Can be address(0) if bootstrap not needed
        l.projectCreatorHat = projectCreatorHat_;

        emit HatSet(HatType.CREATOR, projectCreatorHat_, true);
        emit ExecutorUpdated(executorAddress);
    }

    /*──────── Internal Check Functions ─────*/
    /// @dev Caller must wear a creator hat or be the executor; reverts NotCreator otherwise.
    function _requireCreator() internal view {
        Layout storage l = _layout();
        address s = _msgSender();
        if (!_hasCreatorHat(s) && s != l.executor) revert NotCreator();
    }

    /// @dev Reverts NotFound if the project does not exist.
    function _requireProjectExists(bytes32 pid) internal view {
        if (!_layout()._projects[pid].exists) revert NotFound();
    }

    /// @dev Reverts NotExecutor if the caller is not the configured executor.
    function _requireExecutor() internal view {
        if (_msgSender() != _layout().executor) revert NotExecutor();
    }

    /// @dev Caller must be the executor or wear any hat in `organizerHatIds`; reverts NotOrganizer otherwise.
    function _requireOrganizer() internal view {
        Layout storage l = _layout();
        address s = _msgSender();
        if (s == l.executor) return;
        if (!HatManager.hasAnyHat(l.hats, l.organizerHatIds, s)) revert NotOrganizer();
    }

    /// @dev Caller must hold CREATE permission on `pid` (or be a project manager / executor).
    function _requireCanCreate(bytes32 pid) internal view {
        _checkPerm(pid, TaskPerm.CREATE);
    }

    /// @dev Caller must hold CLAIM permission on the task's project.
    function _requireCanClaim(uint256 tid) internal view {
        _checkPerm(_layout()._tasks[tid].projectId, TaskPerm.CLAIM);
    }

    /// @dev Caller must hold ASSIGN permission on `pid`.
    function _requireCanAssign(bytes32 pid) internal view {
        _checkPerm(pid, TaskPerm.ASSIGN);
    }

    /*──────── Project Logic ─────*/

    /**
     * @notice Create a new project
     * @dev Uses BootstrapProjectConfig struct to avoid stack-too-deep with 10+ calldata arrays.
     *      The caller (msg.sender) is automatically added as a project manager.
     * @param p  Project configuration (title, metadataHash, cap, managers, hat arrays, bounty budgets)
     */
    function createProject(BootstrapProjectConfig calldata p) external returns (bytes32 projectId) {
        _requireCreator();
        projectId = _createProjectCore(
            p.title, p.metadataHash, p.cap, p.managers, p.createHat, p.claimHat, p.reviewHat, p.assignHat, _msgSender()
        );
        _initBountyBudgets(projectId, p.bountyTokens, p.bountyCaps);
    }

    function _createProjectCore(
        bytes calldata title,
        bytes32 metadataHash,
        uint256 cap,
        address[] calldata managers,
        uint256 createHat_,
        uint256 claimHat_,
        uint256 reviewHat_,
        uint256 assignHat_,
        address defaultManager
    ) internal returns (bytes32 projectId) {
        ValidationLib.requireValidTitle(title);
        ValidationLib.requireValidCapAmount(cap);

        Layout storage l = _layout();
        projectId = bytes32(uint256(l.nextProjectId++));
        Project storage p = l._projects[projectId];
        p.cap = uint128(cap);
        p.exists = true;

        emit ProjectCreated(projectId, title, metadataHash, cap);

        /* managers */
        if (defaultManager != address(0)) {
            p.managers[defaultManager] = true;
            emit ProjectManagerUpdated(projectId, defaultManager, true);
        }
        for (uint256 i; i < managers.length;) {
            managers[i].requireNonZeroAddress();
            p.managers[managers[i]] = true;
            emit ProjectManagerUpdated(projectId, managers[i], true);
            unchecked {
                ++i;
            }
        }

        /* per-project capability hat overrides (0 = use global) */
        if (createHat_ != 0) {
            l.projectCapHat[projectId][TaskPerm.CREATE] = createHat_;
            emit ProjectRolePermSet(projectId, createHat_, TaskPerm.CREATE);
        }
        if (claimHat_ != 0) {
            l.projectCapHat[projectId][TaskPerm.CLAIM] = claimHat_;
            emit ProjectRolePermSet(projectId, claimHat_, TaskPerm.CLAIM);
        }
        if (reviewHat_ != 0) {
            l.projectCapHat[projectId][TaskPerm.REVIEW] = reviewHat_;
            emit ProjectRolePermSet(projectId, reviewHat_, TaskPerm.REVIEW);
        }
        if (assignHat_ != 0) {
            l.projectCapHat[projectId][TaskPerm.ASSIGN] = assignHat_;
            emit ProjectRolePermSet(projectId, assignHat_, TaskPerm.ASSIGN);
        }
    }

    function _initBountyBudgets(bytes32 projectId, address[] calldata bountyTokens, uint256[] calldata bountyCaps)
        internal
    {
        if (bountyTokens.length != bountyCaps.length) revert ArrayLengthMismatch();
        if (bountyTokens.length == 0) return;

        Project storage p = _layout()._projects[projectId];
        for (uint256 i; i < bountyTokens.length;) {
            bountyTokens[i].requireNonZeroAddress();
            ValidationLib.requireValidCapAmount(bountyCaps[i]);
            p.bountyBudgets[bountyTokens[i]].cap = uint128(bountyCaps[i]);
            emit BountyCapSet(projectId, bountyTokens[i], 0, bountyCaps[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Delete a project and clear every hat's project-specific permission entries.
     * @dev Permission: creator hat or executor. Does not reclaim spent participation tokens
     *      already minted by completed tasks; only erases project state and per-hat overrides.
     * @param pid Project ID to delete.
     */
    function deleteProject(bytes32 pid) external {
        _requireCreator();
        Layout storage l = _layout();
        Project storage p = l._projects[pid];
        if (!p.exists) revert NotFound();

        // Clear per-project capability hat overrides
        delete l.projectCapHat[pid][TaskPerm.CREATE];
        delete l.projectCapHat[pid][TaskPerm.CLAIM];
        delete l.projectCapHat[pid][TaskPerm.REVIEW];
        delete l.projectCapHat[pid][TaskPerm.ASSIGN];
        delete l.projectCapHat[pid][TaskPerm.SELF_REVIEW];

        delete l._projects[pid];
        emit ProjectDeleted(pid);
    }

    /**
     * @notice Bootstrap initial projects and tasks during org deployment
     * @dev Only callable by deployer (OrgDeployer) during bootstrap phase
     * @param projects Array of project configurations to create
     * @param tasks Array of task configurations (reference projects by index)
     * @return projectIds Array of created project IDs
     */
    function bootstrapProjectsAndTasks(BootstrapProjectConfig[] calldata projects, BootstrapTaskConfig[] calldata tasks)
        external
        returns (bytes32[] memory projectIds)
    {
        Layout storage l = _layout();
        if (_msgSender() != l.deployer) revert NotDeployer();

        projectIds = new bytes32[](projects.length);

        // Create all projects (executor is not auto-added as manager, use managers array)
        for (uint256 i; i < projects.length;) {
            projectIds[i] = _createProjectCore(
                projects[i].title,
                projects[i].metadataHash,
                projects[i].cap,
                projects[i].managers,
                projects[i].createHat,
                projects[i].claimHat,
                projects[i].reviewHat,
                projects[i].assignHat,
                address(0) // No default manager - use explicit managers array
            );
            _initBountyBudgets(projectIds[i], projects[i].bountyTokens, projects[i].bountyCaps);
            unchecked {
                ++i;
            }
        }

        // Create all tasks referencing projects by index
        for (uint256 i; i < tasks.length;) {
            if (tasks[i].projectIndex >= projects.length) revert InvalidIndex();
            bytes32 pid = projectIds[tasks[i].projectIndex];
            _createTask(
                tasks[i].payout,
                tasks[i].title,
                tasks[i].metadataHash,
                pid,
                tasks[i].requiresApplication,
                tasks[i].bountyToken,
                tasks[i].bountyPayout
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Clear the deployer address after bootstrap phase is complete
     * @dev Only callable by deployer. Prevents future bootstrap calls for defense-in-depth.
     *      Should be called by OrgDeployer at the end of org deployment.
     */
    function clearDeployer() external {
        Layout storage l = _layout();
        if (_msgSender() != l.deployer) revert NotDeployer();
        l.deployer = address(0);
    }

    /**
     * @notice Bulk-assign org-wide GLOBAL capability hats during the bootstrap window.
     * @dev Deployer-only escape hatch, identical access pattern to {bootstrapProjectsAndTasks}.
     *      Reverts {NotDeployer} once {clearDeployer} has been called.
     *
     *      Capability-hat model: each `mask` is expanded into its individual {TaskPerm} flags,
     *      and `hatId` is assigned as the GLOBAL capability hat for every gate whose flag is set
     *      (a single hat can therefore back multiple gates). This is the deployer-time bulk form
     *      of `setConfig(ROLE_PERM, abi.encode(hatId, flag))`. Pass `hatId == 0` to clear a gate.
     *      Last write wins when multiple pairs target the same gate.
     *
     *      Emits one single-flag {RolePermSet}(hatId, flag) per set bit — the same event shape the
     *      runtime `setConfig(ROLE_PERM, ...)` path emits, so subgraph consumers index deploy-time
     *      and runtime global grants identically (one event == one gate→hat assignment). Empty
     *      `hatIds` (or a zero mask) is a no-op (does not revert).
     * @param hatIds Capability hat IDs to assign to gates.
     * @param masks  TaskPerm flags (bitwise-OR of {TaskPerm} constants). Length must match `hatIds`.
     */
    function bootstrapGlobalPerms(uint256[] calldata hatIds, uint8[] calldata masks) external {
        Layout storage l = _layout();
        if (_msgSender() != l.deployer) revert NotDeployer();
        if (hatIds.length != masks.length) revert ArrayLengthMismatch();

        for (uint256 i; i < hatIds.length;) {
            uint256 hatId = hatIds[i];
            uint8 mask = masks[i];
            // Expand the mask into individual gate assignments. Each set bit emits its OWN
            // single-flag RolePermSet — identical event shape to the runtime setConfig(ROLE_PERM)
            // path, so indexers handle deploy-time and runtime grants uniformly (one event == one
            // gate→hat assignment). A mask with no bits set is a no-op (emits nothing).
            if (TaskPerm.has(mask, TaskPerm.CREATE)) {
                l.createHat = hatId;
                emit RolePermSet(hatId, TaskPerm.CREATE);
            }
            if (TaskPerm.has(mask, TaskPerm.CLAIM)) {
                l.claimHat = hatId;
                emit RolePermSet(hatId, TaskPerm.CLAIM);
            }
            if (TaskPerm.has(mask, TaskPerm.REVIEW)) {
                l.reviewHat = hatId;
                emit RolePermSet(hatId, TaskPerm.REVIEW);
            }
            if (TaskPerm.has(mask, TaskPerm.ASSIGN)) {
                l.assignHat = hatId;
                emit RolePermSet(hatId, TaskPerm.ASSIGN);
            }
            if (TaskPerm.has(mask, TaskPerm.SELF_REVIEW)) {
                l.selfReviewHat = hatId;
                emit RolePermSet(hatId, TaskPerm.SELF_REVIEW);
            }
            if (TaskPerm.has(mask, TaskPerm.BUDGET)) {
                l.budgetHat = hatId;
                emit RolePermSet(hatId, TaskPerm.BUDGET);
            }
            if (TaskPerm.has(mask, TaskPerm.EDIT_META)) {
                l.editMetaHat = hatId;
                emit RolePermSet(hatId, TaskPerm.EDIT_META);
            }
            if (TaskPerm.has(mask, TaskPerm.EDIT_FULL)) {
                l.editFullHat = hatId;
                emit RolePermSet(hatId, TaskPerm.EDIT_FULL);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*──────── Task Logic ───────*/
    /**
     * @notice Create a task under `pid` with the given payout and optional bounty.
     * @dev Permission: CREATE on `pid` (hat-derived) or project manager / executor.
     * @param payout              Participation-token payout amount.
     * @param title               Raw UTF-8 title (validated for length).
     * @param metadataHash        IPFS CID; emitted in `TaskCreated`, not stored.
     * @param pid                 Project ID this task belongs to.
     * @param bountyToken         ERC-20 bounty token; `address(0)` for no bounty.
     * @param bountyPayout        Bounty amount in `bountyToken` units.
     * @param requiresApplication If true, claimants must submit an application first.
     */
    function createTask(
        uint256 payout,
        bytes calldata title,
        bytes32 metadataHash,
        bytes32 pid,
        address bountyToken,
        uint256 bountyPayout,
        bool requiresApplication
    ) external {
        _requireCanCreate(pid);
        _createTask(payout, title, metadataHash, pid, requiresApplication, bountyToken, bountyPayout);
    }

    /**
     * @notice Create multiple tasks in a single project in one transaction.
     * @dev Permission is checked once for the whole batch; project existence and
     *      per-task validation still run inside `_createTask`. All-or-nothing:
     *      any failure reverts the entire call.
     * @param pid    Project ID all tasks will be created under.
     * @param tasks  Array of task configurations, in the order they should be created.
     * @return taskIds IDs of the newly-created tasks, in the same order as `tasks`.
     */
    function createTasksBatch(bytes32 pid, CreateTaskInput[] calldata tasks)
        external
        returns (uint256[] memory taskIds)
    {
        if (tasks.length == 0) revert EmptyBatch();
        _requireCanCreate(pid);

        uint256 len = tasks.length;
        taskIds = new uint256[](len);

        for (uint256 i; i < len;) {
            CreateTaskInput calldata t = tasks[i];
            taskIds[i] = _createTask(
                t.payout, t.title, t.metadataHash, pid, t.requiresApplication, t.bountyToken, t.bountyPayout
            );
            unchecked {
                ++i;
            }
        }
    }

    function _createTask(
        uint256 payout,
        bytes calldata title,
        bytes32 metadataHash,
        bytes32 pid,
        bool requiresApplication,
        address bountyToken,
        uint256 bountyPayout
    ) internal returns (uint48 id) {
        Layout storage l = _layout();
        ValidationLib.requireValidTitle(title);
        ValidationLib.requireValidPayout96(payout);
        ValidationLib.requireValidBountyConfig(bountyToken, bountyPayout);

        Project storage p = l._projects[pid];
        if (!p.exists) revert NotFound();

        // Update participation token budget (PT cap: 0 = unlimited, since PT is minted)
        uint256 newSpent = p.spent + payout;
        if (newSpent > type(uint128).max) revert BudgetLib.BudgetExceeded();
        if (p.cap != 0 && newSpent > p.cap) revert BudgetLib.BudgetExceeded();
        p.spent = uint128(newSpent);

        // Check bounty budget (BudgetLib: cap 0 = DISABLED, must be explicitly enabled)
        if (bountyToken != address(0) && bountyPayout > 0) {
            BudgetLib.Budget storage bb = p.bountyBudgets[bountyToken];
            bb.addSpent(bountyPayout);
        }

        id = l.nextTaskId++;
        l._tasks[id] = Task(
            pid, uint96(payout), address(0), uint96(bountyPayout), requiresApplication, Status.UNCLAIMED, bountyToken
        );
        emit TaskCreated(id, pid, payout, bountyToken, bountyPayout, requiresApplication, title, metadataHash);
    }

    /**
     * @notice Update a task's payout, title, metadata, and bounty fields.
     * @dev Status gate: COMPLETED / CANCELLED always revert `BadStatus` — terminal states are
     *      immutable to avoid accounting drift (payouts have already been minted or refunded).
     *
     *      Permission gate (any non-terminal status):
     *      - Executor or project manager: always allowed.
     *      - Hat with `TaskPerm.EDIT_FULL`: allowed in any non-terminal status.
     *      - Hat with `TaskPerm.CREATE`: allowed only while the task is `UNCLAIMED`
     *        (preserves the original pre-claim editing path).
     *
     *      Post-claim edits silently change the claimer's payout / bounty expectation —
     *      the subgraph picks up the new values via the existing `TaskUpdated` event.
     *      Swapping `newBountyToken` to a token whose `bountyBudgets[token].cap` is zero
     *      (DISABLED) reverts via `BudgetLib.addSpent`; enable the new token's budget first
     *      with `setConfig(BOUNTY_CAP, ...)`.
     *
     *      Re-runs validation on the new values and adjusts both PT and bounty budgets.
     * @param id               Task ID.
     * @param newPayout        New participation-token payout.
     * @param newTitle         New title.
     * @param newMetadataHash  New IPFS CID (emitted; not stored).
     * @param newBountyToken   New bounty token (or `address(0)` to clear).
     * @param newBountyPayout  New bounty amount.
     */
    function updateTask(
        uint256 id,
        uint256 newPayout,
        bytes calldata newTitle,
        bytes32 newMetadataHash,
        address newBountyToken,
        uint256 newBountyPayout
    ) external {
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status == Status.COMPLETED || t.status == Status.CANCELLED) revert BadStatus();

        bytes32 pid = t.projectId;
        address s = _msgSender();
        if (s != l.executor && !_isPM(pid, s)) {
            bool canEditFull = _hasCap(s, pid, TaskPerm.EDIT_FULL);
            bool canEditUnclaimed = t.status == Status.UNCLAIMED && _hasCap(s, pid, TaskPerm.CREATE);
            if (!canEditFull && !canEditUnclaimed) revert Unauthorized();
        }

        ValidationLib.requireValidTitle(newTitle);
        ValidationLib.requireValidPayout96(newPayout);
        ValidationLib.requireValidBountyConfig(newBountyToken, newBountyPayout);

        Project storage p = l._projects[pid];

        // Update participation token budget
        // PT cap: 0 = unlimited (minted tokens)
        uint256 tentative = p.spent - t.payout + newPayout;
        if (p.cap != 0 && tentative > p.cap) revert BudgetLib.BudgetExceeded();
        p.spent = uint128(tentative);

        // Update bounty budgets
        if (t.bountyToken != address(0) && t.bountyPayout > 0) {
            BudgetLib.Budget storage oldB = p.bountyBudgets[t.bountyToken];
            oldB.subtractSpent(t.bountyPayout);
        }

        if (newBountyToken != address(0) && newBountyPayout > 0) {
            BudgetLib.Budget storage newB = p.bountyBudgets[newBountyToken];
            newB.addSpent(newBountyPayout);
        }

        // Update task
        t.payout = uint96(newPayout);
        t.bountyToken = newBountyToken;
        t.bountyPayout = uint96(newBountyPayout);

        emit TaskUpdated(id, newPayout, newBountyToken, newBountyPayout, newTitle, newMetadataHash);
    }

    /**
     * @notice Update only a non-terminal task's title and metadata hash; payout and bounty fields
     *         are preserved verbatim.
     * @dev Status gate matches {updateTask}: COMPLETED / CANCELLED revert `BadStatus`.
     *
     *      Permission gate (any non-terminal status):
     *      - Executor or project manager: always allowed.
     *      - Hat with `TaskPerm.EDIT_META` or `TaskPerm.EDIT_FULL`: allowed in any non-terminal status.
     *      - Hat with `TaskPerm.CREATE`: allowed only while the task is `UNCLAIMED`
     *        (parity with the pre-claim editing path on {updateTask}).
     *
     *      No budget side effects — the on-chain payout / bountyToken / bountyPayout fields are
     *      re-emitted unchanged so subgraph consumers can index the metadata update via the
     *      existing `TaskUpdated` event.
     * @param id              Task ID.
     * @param newTitle        New title.
     * @param newMetadataHash New IPFS CID (emitted; not stored).
     */
    function updateTaskMetadata(uint256 id, bytes calldata newTitle, bytes32 newMetadataHash) external {
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status == Status.COMPLETED || t.status == Status.CANCELLED) revert BadStatus();

        bytes32 pid = t.projectId;
        address s = _msgSender();
        if (s != l.executor && !_isPM(pid, s)) {
            bool canEditMeta = _hasCap(s, pid, TaskPerm.EDIT_META) || _hasCap(s, pid, TaskPerm.EDIT_FULL);
            bool canEditUnclaimed = t.status == Status.UNCLAIMED && _hasCap(s, pid, TaskPerm.CREATE);
            if (!canEditMeta && !canEditUnclaimed) revert Unauthorized();
        }

        ValidationLib.requireValidTitle(newTitle);
        emit TaskUpdated(id, t.payout, t.bountyToken, t.bountyPayout, newTitle, newMetadataHash);
    }

    /**
     * @notice Claim an UNCLAIMED task that does not require an application.
     * @dev Permission: CLAIM on the task's project. Reverts RequiresApplication for
     *      application-only tasks (use `applyForTask`).
     * @param id Task ID.
     */
    function claimTask(uint256 id) external {
        _requireCanClaim(id);
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();
        if (t.requiresApplication) revert RequiresApplication();

        t.status = Status.CLAIMED;
        t.claimer = _msgSender();
        emit TaskClaimed(id, _msgSender());
    }

    /**
     * @notice Force-assign an UNCLAIMED task to `assignee`, bypassing the claim flow.
     * @dev Permission: ASSIGN on the task's project. Task must be UNCLAIMED.
     * @param id       Task ID.
     * @param assignee Address to record as the claimer.
     */
    function assignTask(uint256 id, address assignee) external {
        _requireCanAssign(_layout()._tasks[id].projectId);
        assignee.requireNonZeroAddress();
        Layout storage l = _layout();

        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();

        t.status = Status.CLAIMED;
        t.claimer = assignee;
        emit TaskAssigned(id, assignee, _msgSender());
    }

    /**
     * @notice Claimer submits their finished work for review.
     * @dev Caller must be the task's current claimer; task must be CLAIMED.
     *      `submissionHash` must be non-zero (typically an IPFS CID).
     * @param id              Task ID.
     * @param submissionHash  IPFS CID of the submission payload.
     */
    function submitTask(uint256 id, bytes32 submissionHash) external {
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status != Status.CLAIMED) revert BadStatus();
        if (t.claimer != _msgSender()) revert NotClaimer();
        if (submissionHash == bytes32(0)) revert ValidationLib.InvalidString();

        t.status = Status.SUBMITTED;
        emit TaskSubmitted(id, submissionHash);
    }

    /**
     * @notice Approve a SUBMITTED task: mint participation tokens to the claimer and
     *         transfer the bounty (if any).
     * @dev Permission: REVIEW on the project. If the caller is the claimer themself,
     *      they additionally need SELF_REVIEW unless they are a project manager / executor.
     * @param id Task ID.
     */
    function completeTask(uint256 id) external {
        Layout storage l = _layout();
        bytes32 pid = l._tasks[id].projectId;
        _checkPerm(pid, TaskPerm.REVIEW);
        Task storage t = _task(l, id);
        if (t.status != Status.SUBMITTED) revert BadStatus();

        // Self-review: if caller is the claimer, require SELF_REVIEW permission or PM/executor
        address sender = _msgSender();
        if (t.claimer == sender && !_isPM(pid, sender)) {
            if (!_hasCap(sender, pid, TaskPerm.SELF_REVIEW)) {
                revert SelfReviewNotAllowed();
            }
        }

        t.status = Status.COMPLETED;
        l.token.mint(t.claimer, uint256(t.payout));

        // Transfer bounty token if set
        if (t.bountyToken != address(0) && t.bountyPayout > 0) {
            IERC20(t.bountyToken).safeTransfer(t.claimer, uint256(t.bountyPayout));
        }

        emit TaskCompleted(id, _msgSender());
    }

    /**
     * @notice Reject a SUBMITTED task. Task reverts to CLAIMED so the claimer can resubmit.
     * @dev Permission: REVIEW on the project. `rejectionHash` must be non-zero (IPFS CID of feedback).
     * @param id             Task ID.
     * @param rejectionHash  IPFS CID of the rejection reasoning.
     */
    function rejectTask(uint256 id, bytes32 rejectionHash) external {
        Layout storage l = _layout();
        _checkPerm(l._tasks[id].projectId, TaskPerm.REVIEW);
        Task storage t = _task(l, id);
        if (t.status != Status.SUBMITTED) revert BadStatus();
        if (rejectionHash == bytes32(0)) revert ValidationLib.InvalidString();

        t.status = Status.CLAIMED;
        emit TaskRejected(id, _msgSender(), rejectionHash);
    }

    /**
     * @notice Cancel an UNCLAIMED task and roll back its PT/bounty budget reservations.
     * @dev Permission: CREATE on the task's project. Pending applications are cleared.
     * @param id Task ID.
     */
    function cancelTask(uint256 id) external {
        _requireCanCreate(_layout()._tasks[id].projectId);
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();

        Project storage p = l._projects[t.projectId];
        if (p.spent < t.payout) revert BudgetLib.SpentUnderflow();
        unchecked {
            p.spent -= t.payout;
        }

        // Roll back bounty budget if applicable
        if (t.bountyToken != address(0) && t.bountyPayout > 0) {
            BudgetLib.Budget storage bb = p.bountyBudgets[t.bountyToken];
            bb.subtractSpent(t.bountyPayout);
        }

        t.status = Status.CANCELLED;
        t.claimer = address(0);

        // Clear all applications - zero out the mapping and delete applicants array
        delete l.taskApplicants[id];

        emit TaskCancelled(id, _msgSender());
    }

    /*──────── Application System ─────*/
    /**
     * @notice Apply to claim a task that requires applications.
     * @dev Permission: CLAIM on the task's project. Reverts AlreadyApplied if the
     *      caller already submitted an application for this task.
     * @param id              Task ID to apply for.
     * @param applicationHash IPFS CID of the application/submission payload.
     */
    function applyForTask(uint256 id, bytes32 applicationHash) external {
        _requireCanClaim(id);
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();
        ValidationLib.requireValidApplicationHash(applicationHash);
        if (!t.requiresApplication) revert NoApplicationRequired();

        address applicant = _msgSender();

        // Check if user has already applied
        if (l.taskApplications[id][applicant] != bytes32(0)) revert AlreadyApplied();

        // Add applicant to the list
        l.taskApplicants[id].push(applicant);
        l.taskApplications[id][applicant] = applicationHash;

        emit TaskApplicationSubmitted(id, applicant, applicationHash);
    }

    /**
     * @notice Approve a pending application: the task moves to CLAIMED for `applicant`
     *         and the remaining applicants are dropped.
     * @dev Permission: ASSIGN on the task's project.
     * @param id        Task ID.
     * @param applicant Address of the applicant to approve.
     */
    function approveApplication(uint256 id, address applicant) external {
        _requireCanAssign(_layout()._tasks[id].projectId);
        Layout storage l = _layout();
        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();
        if (l.taskApplications[id][applicant] == bytes32(0)) revert NotApplicant();

        t.status = Status.CLAIMED;
        t.claimer = applicant;
        delete l.taskApplicants[id];
        emit TaskApplicationApproved(id, applicant, _msgSender());
    }

    /**
     * @notice Create a task and assign it to `assignee` in a single transaction.
     * @dev Permission: caller must hold both CREATE and ASSIGN on `pid`, or be a project
     *      manager / executor. The task is created in CLAIMED state with the assignee as claimer.
     * @param payout              Participation-token payout.
     * @param title               Raw UTF-8 task title.
     * @param metadataHash        IPFS CID; emitted, not stored.
     * @param pid                 Project ID.
     * @param assignee            Address to assign the task to.
     * @param bountyToken         ERC-20 bounty token (or `address(0)` for none).
     * @param bountyPayout        Bounty amount in `bountyToken` units.
     * @param requiresApplication Recorded on the task even though it's already claimed.
     * @return taskId             ID of the created task.
     */
    function createAndAssignTask(
        uint256 payout,
        bytes calldata title,
        bytes32 metadataHash,
        bytes32 pid,
        address assignee,
        address bountyToken,
        uint256 bountyPayout,
        bool requiresApplication
    ) external returns (uint256 taskId) {
        return _createAndAssignTask(
            payout, title, metadataHash, pid, assignee, requiresApplication, bountyToken, bountyPayout
        );
    }

    function _createAndAssignTask(
        uint256 payout,
        bytes calldata title,
        bytes32 metadataHash,
        bytes32 pid,
        address assignee,
        bool requiresApplication,
        address bountyToken,
        uint256 bountyPayout
    ) internal returns (uint256 taskId) {
        assignee.requireNonZeroAddress();

        Layout storage l = _layout();
        address sender = _msgSender();

        // Check permissions - user must have both CREATE and ASSIGN capability hats, or be a project manager
        bool hasCreateAndAssign = _hasCap(sender, pid, TaskPerm.CREATE) && _hasCap(sender, pid, TaskPerm.ASSIGN);
        if (!hasCreateAndAssign && !_isPM(pid, sender)) {
            revert Unauthorized();
        }

        // Validation
        ValidationLib.requireValidTitle(title);
        ValidationLib.requireValidPayout96(payout);
        ValidationLib.requireValidBountyConfig(bountyToken, bountyPayout);

        Project storage p = l._projects[pid];
        if (!p.exists) revert NotFound();

        // PT cap: 0 = unlimited (minted tokens)
        uint256 newSpent = p.spent + payout;
        if (p.cap != 0 && newSpent > p.cap) revert BudgetLib.BudgetExceeded();
        p.spent = uint128(newSpent);

        // Check bounty budget (BudgetLib: cap 0 = DISABLED, must be explicitly enabled)
        if (bountyToken != address(0) && bountyPayout > 0) {
            BudgetLib.Budget storage bb = p.bountyBudgets[bountyToken];
            bb.addSpent(bountyPayout);
        }

        // Create and assign task in one go
        taskId = l.nextTaskId++;
        l._tasks[taskId] =
            Task(pid, uint96(payout), assignee, uint96(bountyPayout), requiresApplication, Status.CLAIMED, bountyToken);

        // Emit events
        emit TaskCreated(taskId, pid, payout, bountyToken, bountyPayout, requiresApplication, title, metadataHash);
        emit TaskAssigned(taskId, assignee, sender);
    }

    /*──────── Config Setter (Optimized) ─────── */
    /**
     * @notice Per-key setter for every mutable, non-project-creation parameter.
     * @dev Single entry point with per-branch permission gating. The `key` selects
     *      the operation and `value` is its ABI-encoded payload. Permission column
     *      lists who may call each variant:
     *      - `EXECUTOR` (executor): `abi.encode(address newExecutor)` — rotate the executor.
     *      - `CREATOR_HAT_ALLOWED` (executor): `abi.encode(uint256 hatId, bool allowed)` — add/remove creator hat.
     *      - `ROLE_PERM` (executor): `abi.encode(uint256 hatId, uint8 mask)` — set global permission mask.
     *      - `ORGANIZER_HAT_ALLOWED` (executor): `abi.encode(uint256 hatId, bool allowed)` — add/remove folder organizer hat.
     *      - `BOUNTY_CAP` (executor OR `TaskPerm.BUDGET` hat): `abi.encode(bytes32 pid, address token, uint256 newCap)` — set per-project bounty cap.
     *      - `PROJECT_MANAGER` (executor): `abi.encode(bytes32 pid, address mgr, bool isManager)` — toggle PM.
     *      - `PROJECT_CAP` (executor OR `TaskPerm.BUDGET` hat): `abi.encode(bytes32 pid, uint256 newCap)` — change PT cap.
     *      `PROJECT_ROLE_PERM` is intentionally not handled here; use {setProjectRolePerm}.
     * @param key   Which configuration field to mutate.
     * @param value ABI-encoded payload matching the variant above.
     */
    function setConfig(ConfigKey key, bytes calldata value) external {
        Layout storage l = _layout();

        if (key == ConfigKey.EXECUTOR) {
            _requireExecutor();
            address newExecutor = abi.decode(value, (address));
            newExecutor.requireNonZeroAddress();
            l.executor = newExecutor;
            emit ExecutorUpdated(newExecutor);
            return;
        }

        if (key == ConfigKey.CREATOR_HAT_ALLOWED) {
            _requireExecutor();
            // Repurposed for the capability-hat model: sets the single projectCreatorHat.
            // `allowed` is ignored — pass hat=0 to clear.
            (uint256 hat,) = abi.decode(value, (uint256, bool));
            l.projectCreatorHat = hat;
            emit HatSet(HatType.CREATOR, hat, true);
            return;
        }

        if (key == ConfigKey.ROLE_PERM) {
            _requireExecutor();
            // Repurposed for the capability-hat model: ROLE_PERM sets a GLOBAL capability hat.
            // `mask` selects which gate (a single TaskPerm flag); `hatId` is the capability hat
            // for that gate. Pass hatId=0 to clear. Multi-bit masks revert InvalidCapMask — use
            // one call per gate (or bootstrapGlobalPerms for a deployer-time bulk expand).
            (uint256 hatId, uint8 mask) = abi.decode(value, (uint256, uint8));
            _setGlobalCapHat(l, mask, hatId);
            emit RolePermSet(hatId, mask);
            return;
        }

        if (key == ConfigKey.ORGANIZER_HAT_ALLOWED) {
            _requireExecutor();
            (uint256 hat, bool allowed) = abi.decode(value, (uint256, bool));
            HatManager.setHatInArray(l.organizerHatIds, hat, allowed);
            emit OrganizerHatAllowed(hat, allowed);
            return;
        }

        // Project-related configs - consolidate common logic
        bytes32 pid;
        if (key == ConfigKey.BOUNTY_CAP || key == ConfigKey.PROJECT_MANAGER || key == ConfigKey.PROJECT_CAP) {
            pid = abi.decode(value, (bytes32));
            Project storage p = l._projects[pid];
            if (!p.exists) revert NotFound();

            if (key == ConfigKey.BOUNTY_CAP) {
                _requireBudgetEditor(pid);
                (, address token, uint256 newCap) = abi.decode(value, (bytes32, address, uint256));
                token.requireNonZeroAddress();
                ValidationLib.requireValidCapAmount(newCap);
                BudgetLib.Budget storage b = p.bountyBudgets[token];
                ValidationLib.requireValidCap(newCap, b.spent);
                uint256 oldCap = b.cap;
                b.cap = uint128(newCap);
                emit BountyCapSet(pid, token, oldCap, newCap);
            } else if (key == ConfigKey.PROJECT_MANAGER) {
                _requireExecutor();
                (, address mgr, bool isManager) = abi.decode(value, (bytes32, address, bool));
                mgr.requireNonZeroAddress();
                p.managers[mgr] = isManager;
                emit ProjectManagerUpdated(pid, mgr, isManager);
            } else if (key == ConfigKey.PROJECT_CAP) {
                _requireBudgetEditor(pid);
                (, uint256 newCap) = abi.decode(value, (bytes32, uint256));
                ValidationLib.requireValidCapAmount(newCap);
                ValidationLib.requireValidCap(newCap, p.spent);
                uint256 old = p.cap;
                p.cap = uint128(newCap);
                emit ProjectCapUpdated(pid, old, newCap);
            }
        }
    }

    /// @notice Override a project's capability hat for a specific TaskPerm flag.
    ///         Pass hatId=0 to clear and fall back to the global capability hat.
    /// @dev `mask` MUST be exactly one of the single-bit TaskPerm constants
    ///      (CREATE, CLAIM, REVIEW, ASSIGN, SELF_REVIEW, BUDGET, EDIT_META, EDIT_FULL).
    ///      OR-combined masks revert InvalidCapMask — `_capHat` only queries by single-flag
    ///      keys, so a combined key would write to an unread slot and silently no-op.
    /// @param pid   Project ID.
    /// @param hatId Capability hat for this gate on this project (0 = clear).
    /// @param mask  Exactly one TaskPerm flag selecting which gate to override.
    function setProjectRolePerm(bytes32 pid, uint256 hatId, uint8 mask) external {
        _requireCreator();
        _requireProjectExists(pid);
        if (!_isSingleCapFlag(mask)) revert InvalidCapMask();
        _layout().projectCapHat[pid][mask] = hatId;
        emit ProjectRolePermSet(pid, hatId, mask);
    }

    /*──────── Folders ─────────*/
    /**
     * @notice Update the IPFS root pointing to this org's folder tree.
     * @dev Folder structure (names, parents, ordering, project assignments) lives
     *      off-chain in IPFS as JSON. Only the root hash is on-chain. Callers must
     *      pass the current root they observed off-chain; if the on-chain root has
     *      moved on (another organizer published first), the call reverts. The UI
     *      should then re-pin and retry against the new root.
     *
     *      Permission: executor OR any wearer of an `organizerHatIds` hat.
     *      Creator hats deliberately do NOT inherit this power — creators are
     *      widely distributed and silent reparenting of the folder tree is a
     *      footgun. To grant a creator reorganize rights, add the creator's hat
     *      to `organizerHatIds` via `setConfig(ORGANIZER_HAT_ALLOWED, ...)`.
     *
     * @param expectedCurrentRoot The root the caller believes is current (CAS guard).
     * @param newRoot             The new IPFS root hash to publish (bytes32(0) clears).
     */
    function setFolders(bytes32 expectedCurrentRoot, bytes32 newRoot) external {
        _requireOrganizer();
        Layout storage l = _layout();
        bytes32 current = l.foldersRoot;
        if (current != expectedCurrentRoot) revert FoldersRootStale(expectedCurrentRoot, current);
        l.foldersRoot = newRoot;
        emit FoldersUpdated(newRoot, current, _msgSender());
    }

    /*──────── Internal Perm helpers ─────*/

    /// @dev Looks up the effective capability hat for `(pid, cap)`: project override if set,
    ///      otherwise the global capability hat.
    function _capHat(bytes32 pid, uint8 cap) internal view returns (uint256) {
        Layout storage l = _layout();
        uint256 hat = l.projectCapHat[pid][cap];
        if (hat != 0) return hat;
        if (cap == TaskPerm.CREATE) return l.createHat;
        if (cap == TaskPerm.CLAIM) return l.claimHat;
        if (cap == TaskPerm.REVIEW) return l.reviewHat;
        if (cap == TaskPerm.ASSIGN) return l.assignHat;
        if (cap == TaskPerm.SELF_REVIEW) return l.selfReviewHat;
        if (cap == TaskPerm.BUDGET) return l.budgetHat;
        if (cap == TaskPerm.EDIT_META) return l.editMetaHat;
        if (cap == TaskPerm.EDIT_FULL) return l.editFullHat;
        return 0;
    }

    function _hasCap(address user, bytes32 pid, uint8 cap) internal view returns (bool) {
        uint256 hat = _capHat(pid, cap);
        if (hat == 0) return false;
        return _layout().hats.isWearerOfHat(user, hat);
    }

    function _isPM(bytes32 pid, address who) internal view returns (bool) {
        Layout storage l = _layout();
        return (who == l.executor) || l._projects[pid].managers[who];
    }

    function _checkPerm(bytes32 pid, uint8 flag) internal view {
        address s = _msgSender();
        if (!_hasCap(s, pid, flag) && !_isPM(pid, s)) revert Unauthorized();
    }

    /// @dev Stricter than `_checkPerm`: no project-manager bypass. Only the executor
    ///      or a wearer of the BUDGET capability hat (global via `ROLE_PERM`, or per-project
    ///      via `setProjectRolePerm`) may resize a project's caps.
    function _requireBudgetEditor(bytes32 pid) internal view {
        address s = _msgSender();
        if (s == _layout().executor) return;
        if (!_hasCap(s, pid, TaskPerm.BUDGET)) revert Unauthorized();
    }

    /// @dev Maps a single TaskPerm flag to its GLOBAL capability-hat storage field and sets it.
    ///      Reverts InvalidCapMask unless `flag` is exactly one recognised TaskPerm bit. Shared
    ///      by `setConfig(ROLE_PERM, ...)` and `bootstrapGlobalPerms`.
    function _setGlobalCapHat(Layout storage l, uint8 flag, uint256 hatId) internal {
        if (flag == TaskPerm.CREATE) {
            l.createHat = hatId;
        } else if (flag == TaskPerm.CLAIM) {
            l.claimHat = hatId;
        } else if (flag == TaskPerm.REVIEW) {
            l.reviewHat = hatId;
        } else if (flag == TaskPerm.ASSIGN) {
            l.assignHat = hatId;
        } else if (flag == TaskPerm.SELF_REVIEW) {
            l.selfReviewHat = hatId;
        } else if (flag == TaskPerm.BUDGET) {
            l.budgetHat = hatId;
        } else if (flag == TaskPerm.EDIT_META) {
            l.editMetaHat = hatId;
        } else if (flag == TaskPerm.EDIT_FULL) {
            l.editFullHat = hatId;
        } else {
            revert InvalidCapMask();
        }
    }

    /// @dev True iff `mask` is exactly one recognised single-bit TaskPerm flag.
    function _isSingleCapFlag(uint8 mask) internal pure returns (bool) {
        return mask == TaskPerm.CREATE || mask == TaskPerm.CLAIM || mask == TaskPerm.REVIEW || mask == TaskPerm.ASSIGN
            || mask == TaskPerm.SELF_REVIEW || mask == TaskPerm.BUDGET || mask == TaskPerm.EDIT_META
            || mask == TaskPerm.EDIT_FULL;
    }

    /*──────── Internal Helper Functions ─────────── */
    /// @dev Returns true if `user` wears the project-creator capability hat.
    function _hasCreatorHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        uint256 hat = l.projectCreatorHat;
        if (hat == 0) return false;
        return l.hats.isWearerOfHat(user, hat);
    }

    /*──────── Utils / View ────*/
    function _task(Layout storage l, uint256 id) private view returns (Task storage t) {
        if (id >= l.nextTaskId) revert NotFound();
        t = l._tasks[id];
    }

    /*──────── Minimal External Getters for Lens ─────── */
    /**
     * @notice Read-only dispatcher used by `TaskManagerLens` to surface storage fields
     *         without bloating the proxy ABI.
     * @dev Variants:
     *      - `1` → Task: `d = abi.encode(uint256 id)` → `(bytes32 projectId, uint96 payout, address claimer, uint96 bountyPayout, bool requiresApplication, Status status, address bountyToken)`.
     *      - `2` → Project: `d = abi.encode(bytes32 pid)` → `(uint128 cap, uint128 spent, bool exists)`.
     *      - `3` → Hats contract: `d = ""` → `(address hats)`.
     *      - `4` → Executor: `d = ""` → `(address executor)`.
     *      - `5` → Creator hats: `d = ""` → `(uint256[] hatIds)`.
     *      - `6` → Permission hats enumeration: `d = ""` → `(uint256[] hatIds)`.
     *      - `7` → Task applicants: `d = abi.encode(uint256 id)` → `(address[] applicants)`.
     *      - `8` → One applicant's hash: `d = abi.encode(uint256 id, address applicant)` → `(bytes32 hash)`.
     *      - `9` → Bounty budget: `d = abi.encode(bytes32 pid, address token)` → `(uint128 cap, uint128 spent)`.
     *      - `10` → Folders root: `d = ""` → `(bytes32 foldersRoot)`.
     *      - `11` → Organizer hats: `d = ""` → `(uint256[] hatIds)`.
     *      - `12` → Extended global gate hats: `d = ""` → `(uint256[3] [budgetHat, editMetaHat, editFullHat])`.
     * @param t Variant selector.
     * @param d ABI-encoded variant payload (see above).
     * @return ABI-encoded result whose shape depends on `t`.
     */
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory) {
        Layout storage l = _layout();
        if (t == 1) {
            // Task
            uint256 id = abi.decode(d, (uint256));
            if (id >= l.nextTaskId) revert NotFound();
            Task storage task = l._tasks[id];
            return abi.encode(
                task.projectId,
                task.payout,
                task.claimer,
                task.bountyPayout,
                task.requiresApplication,
                task.status,
                task.bountyToken
            );
        } else if (t == 2) {
            // Project
            bytes32 pid = abi.decode(d, (bytes32));
            Project storage p = l._projects[pid];
            if (!p.exists) revert NotFound();
            return abi.encode(p.cap, p.spent, p.exists);
        } else if (t == 3) {
            // Hats
            return abi.encode(address(l.hats));
        } else if (t == 4) {
            // Executor
            return abi.encode(l.executor);
        } else if (t == 5) {
            // CreatorHats — single capability hat (returned as single-element array for compat)
            uint256[] memory arr = new uint256[](1);
            arr[0] = l.projectCreatorHat;
            return abi.encode(arr);
        } else if (t == 6) {
            // PermissionHats — global capability hats per gate (returned as 5-element array)
            uint256[] memory arr = new uint256[](5);
            arr[0] = l.createHat;
            arr[1] = l.claimHat;
            arr[2] = l.reviewHat;
            arr[3] = l.assignHat;
            arr[4] = l.selfReviewHat;
            return abi.encode(arr);
        } else if (t == 7) {
            // TaskApplicants
            uint256 id = abi.decode(d, (uint256));
            return abi.encode(l.taskApplicants[id]);
        } else if (t == 8) {
            // TaskApplication
            (uint256 id, address applicant) = abi.decode(d, (uint256, address));
            return abi.encode(l.taskApplications[id][applicant]);
        } else if (t == 9) {
            // BountyBudget
            (bytes32 pid, address token) = abi.decode(d, (bytes32, address));
            Project storage p = l._projects[pid];
            if (!p.exists) revert NotFound();
            BudgetLib.Budget storage b = p.bountyBudgets[token];
            return abi.encode(b.cap, b.spent);
        } else if (t == 10) {
            // FoldersRoot
            return abi.encode(l.foldersRoot);
        } else if (t == 11) {
            // OrganizerHats
            return abi.encode(HatManager.getHatArray(l.organizerHatIds));
        } else if (t == 12) {
            // Extended global gate hats (v4/v5): [budget, editMeta, editFull]
            uint256[] memory arr = new uint256[](3);
            arr[0] = l.budgetHat;
            arr[1] = l.editMetaHat;
            arr[2] = l.editFullHat;
            return abi.encode(arr);
        }
        revert NotFound();
    }
}
