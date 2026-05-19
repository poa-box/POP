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
        uint256[] createHats;
        uint256[] claimHats;
        uint256[] reviewHats;
        uint256[] assignHats;
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
        uint256[] creatorHatIds; // enumeration array for creator hats
        uint48 nextTaskId;
        uint48 nextProjectId;
        address executor; // 20 bytes + 2*6 bytes = 32 bytes (one slot)
        mapping(uint256 => uint8) rolePermGlobal; // hat ID => permission mask
        mapping(bytes32 => mapping(uint256 => uint8)) rolePermProj; // project => hat ID => permission mask
        uint256[] permissionHatIds; // enumeration array for hats with permissions
        mapping(uint256 => address[]) taskApplicants; // task ID => array of applicants
        mapping(uint256 => mapping(address => bytes32)) taskApplications; // task ID => applicant => application hash
        address deployer; // OrgDeployer address for bootstrap operations
        mapping(uint256 => uint256) projectPermHatRefCount; // hat ID => number of projects with non-zero project mask
        // ─── Folders (v3) ───
        // Folder tree (names, parents, ordering, project assignments) lives off-chain in IPFS.
        // Only the root hash is on-chain; reorganization = swap the hash via setFolders.
        bytes32 foldersRoot;
        uint256[] organizerHatIds; // hats authorized to reorganize the folder tree
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
     *         (optional) bootstrap deployer; seeds the creator-hat array.
     * @param tokenAddress    Participation token (must implement `mint`).
     * @param hatsAddress     Hats Protocol contract.
     * @param creatorHats     Initial hat IDs allowed to create projects.
     * @param executorAddress Executor address (DAO execution layer).
     * @param deployerAddress OrgDeployer address for `bootstrapProjectsAndTasks`; may be zero.
     */
    function initialize(
        address tokenAddress,
        address hatsAddress,
        uint256[] calldata creatorHats,
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

        // Initialize creator hat arrays using HatManager
        for (uint256 i; i < creatorHats.length;) {
            HatManager.setHatInArray(l.creatorHatIds, creatorHats[i], true);
            emit HatSet(HatType.CREATOR, creatorHats[i], true);
            unchecked {
                ++i;
            }
        }

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
            p.title,
            p.metadataHash,
            p.cap,
            p.managers,
            p.createHats,
            p.claimHats,
            p.reviewHats,
            p.assignHats,
            _msgSender()
        );
        _initBountyBudgets(projectId, p.bountyTokens, p.bountyCaps);
    }

    function _createProjectCore(
        bytes calldata title,
        bytes32 metadataHash,
        uint256 cap,
        address[] calldata managers,
        uint256[] calldata createHats,
        uint256[] calldata claimHats,
        uint256[] calldata reviewHats,
        uint256[] calldata assignHats,
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

        /* hat-permission matrix */
        _setBatchHatPerm(projectId, createHats, TaskPerm.CREATE);
        _setBatchHatPerm(projectId, claimHats, TaskPerm.CLAIM);
        _setBatchHatPerm(projectId, reviewHats, TaskPerm.REVIEW);
        _setBatchHatPerm(projectId, assignHats, TaskPerm.ASSIGN);
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

        // Decrement ref counts for hats that had project-specific permissions.
        // Iterate a snapshot of permissionHatIds since _syncPermissionHat may modify it.
        uint256 len = l.permissionHatIds.length;
        uint256[] memory snapshot = new uint256[](len);
        for (uint256 i; i < len;) {
            snapshot[i] = l.permissionHatIds[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < len;) {
            uint256 hatId = snapshot[i];
            if (l.rolePermProj[pid][hatId] != 0) {
                _updateProjectPermRefCount(l, hatId, l.rolePermProj[pid][hatId], 0);
                delete l.rolePermProj[pid][hatId];
                _syncPermissionHat(hatId);
            }
            unchecked {
                ++i;
            }
        }

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
                projects[i].createHats,
                projects[i].claimHats,
                projects[i].reviewHats,
                projects[i].assignHats,
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
     * @notice Update an UNCLAIMED task's payout, title, metadata, and bounty fields.
     * @dev Permission: CREATE on the task's project. Reverts BadStatus once the task is claimed.
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
        _requireCanCreate(_layout()._tasks[id].projectId);
        Layout storage l = _layout();
        ValidationLib.requireValidTitle(newTitle);
        ValidationLib.requireValidPayout96(newPayout);
        ValidationLib.requireValidBountyConfig(newBountyToken, newBountyPayout);

        Task storage t = _task(l, id);
        if (t.status != Status.UNCLAIMED) revert BadStatus();

        Project storage p = l._projects[t.projectId];

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
            if (!TaskPerm.has(_permMask(sender, pid), TaskPerm.SELF_REVIEW)) {
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

        // Check permissions - user must have both CREATE and ASSIGN permissions, or be a project manager
        uint8 userPerms = _permMask(sender, pid);
        bool hasCreateAndAssign = TaskPerm.has(userPerms, TaskPerm.CREATE) && TaskPerm.has(userPerms, TaskPerm.ASSIGN);
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
            (uint256 hat, bool allowed) = abi.decode(value, (uint256, bool));
            HatManager.setHatInArray(l.creatorHatIds, hat, allowed);
            emit HatSet(HatType.CREATOR, hat, allowed);
            return;
        }

        if (key == ConfigKey.ROLE_PERM) {
            _requireExecutor();
            (uint256 hatId, uint8 mask) = abi.decode(value, (uint256, uint8));
            l.rolePermGlobal[hatId] = mask;
            _syncPermissionHat(hatId);
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

    /**
     * @notice Replace a hat's permission mask on a specific project (overrides global).
     * @dev Permission: creator hat or executor. Setting `mask` to zero removes the override
     *      and falls back to the hat's global mask (if any).
     * @param pid   Project ID.
     * @param hatId Hat whose mask to set.
     * @param mask  Bitwise OR of `TaskPerm.CREATE|CLAIM|REVIEW|ASSIGN|SELF_REVIEW`.
     */
    function setProjectRolePerm(bytes32 pid, uint256 hatId, uint8 mask) external {
        _requireCreator();
        _requireProjectExists(pid);
        Layout storage l = _layout();
        uint8 oldMask = l.rolePermProj[pid][hatId];
        l.rolePermProj[pid][hatId] = mask;
        _updateProjectPermRefCount(l, hatId, oldMask, mask);

        _syncPermissionHat(hatId);

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

    function _permMask(address user, bytes32 pid) internal view returns (uint8 m) {
        Layout storage l = _layout();
        uint256 len = l.permissionHatIds.length;
        if (len == 0) return 0;

        // one call instead of N
        address[] memory wearers = new address[](len);
        uint256[] memory hats_ = new uint256[](len);
        for (uint256 i; i < len;) {
            wearers[i] = user;
            hats_[i] = l.permissionHatIds[i];
            unchecked {
                ++i;
            }
        }
        uint256[] memory bal = l.hats.balanceOfBatch(wearers, hats_);

        for (uint256 i; i < len;) {
            if (bal[i] == 0) {
                unchecked {
                    ++i;
                }
                continue; // user doesn't wear it
            }
            uint256 h = hats_[i];
            uint8 mask = l.rolePermProj[pid][h];
            m |= mask == 0 ? l.rolePermGlobal[h] : mask; // project overrides global
            unchecked {
                ++i;
            }
        }
    }

    function _isPM(bytes32 pid, address who) internal view returns (bool) {
        Layout storage l = _layout();
        return (who == l.executor) || l._projects[pid].managers[who];
    }

    function _checkPerm(bytes32 pid, uint8 flag) internal view {
        address s = _msgSender();
        if (!TaskPerm.has(_permMask(s, pid), flag) && !_isPM(pid, s)) revert Unauthorized();
    }

    /// @dev Stricter than `_checkPerm`: no project-manager bypass. Only Executor
    /// or a wearer of a hat granted `TaskPerm.BUDGET` (globally via `ROLE_PERM`
    /// or per-project via `setProjectRolePerm`) may resize a project's caps.
    function _requireBudgetEditor(bytes32 pid) internal view {
        address s = _msgSender();
        if (s == _layout().executor) return;
        if (!TaskPerm.has(_permMask(s, pid), TaskPerm.BUDGET)) revert Unauthorized();
    }

    function _setBatchHatPerm(bytes32 pid, uint256[] calldata hatIds, uint8 flag) internal {
        Layout storage l = _layout();
        for (uint256 i; i < hatIds.length;) {
            uint256 hatId = hatIds[i];
            uint8 oldMask = l.rolePermProj[pid][hatId];
            uint8 newMask = l.rolePermProj[pid][hatId] | flag;
            l.rolePermProj[pid][hatId] = newMask;
            _updateProjectPermRefCount(l, hatId, oldMask, newMask);

            _syncPermissionHat(hatId);

            emit ProjectRolePermSet(pid, hatId, newMask);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Keep `permissionHatIds` consistent with effective permissions.
     * A hat should remain tracked if it has any non-zero global or project mask.
     */
    function _syncPermissionHat(uint256 hatId) internal {
        Layout storage l = _layout();
        bool hasGlobalPerm = l.rolePermGlobal[hatId] != 0;
        bool hasProjectPerm = l.projectPermHatRefCount[hatId] != 0;

        // Upgrade-safe fallback: if refcount wasn't initialized for existing data,
        // rebuild it lazily only when we would otherwise remove the hat.
        if (!hasProjectPerm && _hasAnyProjectPermissionLegacy(l, hatId)) {
            l.projectPermHatRefCount[hatId] = _rebuildProjectPermRefCount(l, hatId);
            hasProjectPerm = l.projectPermHatRefCount[hatId] != 0;
        }

        HatManager.setHatInArray(l.permissionHatIds, hatId, hasGlobalPerm || hasProjectPerm);
    }

    function _updateProjectPermRefCount(Layout storage l, uint256 hatId, uint8 oldMask, uint8 newMask) internal {
        if (oldMask == 0 && newMask != 0) {
            l.projectPermHatRefCount[hatId]++;
        } else if (oldMask != 0 && newMask == 0) {
            uint256 count = l.projectPermHatRefCount[hatId];
            if (count > 0) {
                l.projectPermHatRefCount[hatId] = count - 1;
            }
        }
    }

    function _hasAnyProjectPermissionLegacy(Layout storage l, uint256 hatId) internal view returns (bool) {
        uint48 nextProjectId = l.nextProjectId;
        for (uint48 i; i < nextProjectId;) {
            bytes32 pid = bytes32(uint256(i));
            if (l._projects[pid].exists && l.rolePermProj[pid][hatId] != 0) {
                return true;
            }
            unchecked {
                ++i;
            }
        }

        return false;
    }

    function _rebuildProjectPermRefCount(Layout storage l, uint256 hatId) internal view returns (uint256 count) {
        uint48 nextProjectId = l.nextProjectId;
        for (uint48 i; i < nextProjectId;) {
            bytes32 pid = bytes32(uint256(i));
            if (l._projects[pid].exists && l.rolePermProj[pid][hatId] != 0) {
                count++;
            }
            unchecked {
                ++i;
            }
        }
    }

    /*──────── Internal Helper Functions ─────────── */
    /// @dev Returns true if `user` wears *any* creator hat.
    function _hasCreatorHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        return HatManager.hasAnyHat(l.hats, l.creatorHatIds, user);
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
            // CreatorHats
            return abi.encode(HatManager.getHatArray(l.creatorHatIds));
        } else if (t == 6) {
            // PermissionHats
            return abi.encode(HatManager.getHatArray(l.permissionHatIds));
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
        }
        revert NotFound();
    }
}
