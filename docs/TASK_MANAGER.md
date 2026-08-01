# TaskManager Documentation

**Version:** 1.0
**Author:** POA Engineering Team
**License:** MIT

---

## Table of Contents

1. [What is TaskManager?](#what-is-taskmanager)
2. [Why Worker Ownership Matters](#why-worker-ownership-matters)
3. [Core Concepts](#core-concepts)
   - [Projects](#projects)
   - [Tasks](#tasks)
   - [Applications](#applications)
   - [Participation Tokens](#participation-tokens)
   - [Bounties](#bounties)
4. [Permission System](#permission-system)
   - [Hats Protocol Integration](#hats-protocol-integration)
   - [Permission Types](#permission-types)
   - [Project Managers](#project-managers)
5. [Task Lifecycle](#task-lifecycle)
6. [How It Works (With Examples)](#how-it-works-with-examples)
7. [Technical Reference](#technical-reference)
8. [Code Walkthrough](#code-walkthrough)

---

## What is TaskManager?

**TaskManager is the heartbeat of worker-owned organizations on-chain.** It transforms how communities coordinate labor by making work visible, accountable, and fairly compensated through transparent smart contracts.

### The Problem with Traditional Work Coordination

Traditional organizations suffer from:
- **Opaque reward systems:** Workers don't know how compensation is determined
- **Centralized control:** A few managers control who works on what
- **No ownership stake:** Labor doesn't translate into organizational ownership
- **Trust dependencies:** Reliance on middlemen to verify and pay for completed work

### The Solution

TaskManager enables **trustless, transparent work coordination**:
- **Immutable task records:** Every task, its requirements, and payout are recorded on-chain
- **Role-based permissions:** Community decides who can create, claim, and review work through Hats Protocol
- **Automatic compensation:** Completed work triggers immediate token minting and bounty payouts
- **Democratic ownership:** Participation tokens earned through work represent real organizational stake

### What It Does

1. **Organizes work into projects** with budgets and dedicated managers
2. **Creates tasks** with defined payouts in participation tokens and optional bounty rewards
3. **Manages applications** for tasks requiring competitive selection
4. **Tracks task lifecycle** from creation through completion
5. **Mints participation tokens** directly to workers upon task completion
6. **Transfers bounty payments** in any ERC-20 token for external rewards

---

## Why Worker Ownership Matters

TaskManager isn't just a project management tool - it's infrastructure for **worker cooperatives and community-owned organizations**.

### The Cooperative Principle

In traditional companies, workers trade labor for wages while shareholders capture the value. TaskManager inverts this:

```
Traditional Model:
  Worker → Labor → Company → Profit → Shareholders

POA Model:
  Worker → Labor → TaskManager → Participation Tokens → Worker becomes Owner
```

Every completed task mints participation tokens directly to the worker, building their stake in the organization over time.

### Real-World Example: Coffee Cooperative

Imagine a worker-owned coffee roastery using TaskManager:

**Week 1:** Maria creates a task "Source organic beans from Guatemala"
```solidity
createTask(
    payout: 100e18,           // 100 participation tokens
    title: "Source Guatemalan beans",
    metadataHash: 0x...,      // IPFS link to full spec
    projectId: procurementProjectId,
    bountyToken: USDC,
    bountyPayout: 50e6,       // $50 USDC for expenses
    requiresApplication: true
);
```

**Week 2:** Carlos applies with a proposal
```solidity
applyForTask(
    taskId: 42,
    applicationHash: 0x...    // IPFS link to proposal
);
```

**Week 3:** The procurement team approves Carlos
```solidity
approveApplication(42, carlos);
```

**Week 4:** Carlos completes the work and submits proof
```solidity
submitTask(42, submissionHash);  // Link to delivery docs
```

**Week 5:** A reviewer marks the task complete
```solidity
completeTask(42);
// Carlos receives:
//   - 100 participation tokens (minted automatically)
//   - $50 USDC (transferred from contract)
```

**Result:** Carlos now owns a larger stake in the cooperative through his participation tokens, and got reimbursed for expenses in USDC.

---

## Core Concepts

### Projects

Projects are **organizational containers** for related tasks with shared budgets and management.

```solidity
struct Project {
    mapping(address => bool) managers;        // Who can manage this project
    uint128 cap;                              // Max participation tokens for all tasks
    uint128 spent;                            // Tokens already committed
    bool exists;                              // Project validity flag
    mapping(address => BudgetLib.Budget) bountyBudgets;  // Per-token bounty caps
}
```

**Key Properties:**

| Property | Description | Example |
|----------|-------------|---------|
| `managers` | Addresses with full project control | Treasurer, team lead |
| `cap` | Maximum participation token budget (0 = unlimited) | 10,000 tokens/quarter |
| `spent` | Tokens committed to existing tasks | 3,500 already allocated |
| `bountyBudgets` | Separate caps per bounty token | 500 USDC cap, 2 ETH cap |

**Creating a Project:**

```solidity
bytes32 projectId = createProject(
    title: "Q1 Engineering",
    metadataHash: ipfsHash,
    cap: 50000e18,                    // 50,000 token budget
    managers: [alice, bob],           // Additional managers
    createHats: [devHat],             // Hats that can create tasks
    claimHats: [contributorHat],      // Hats that can claim tasks
    reviewHats: [reviewerHat],        // Hats that can approve work
    assignHats: [leadHat]             // Hats that can assign tasks
);
```

The caller is automatically added as a manager.

### Tasks

Tasks are **atomic units of work** with defined payouts and lifecycle states.

```solidity
struct Task {
    bytes32 projectId;           // Parent project
    uint96 payout;               // Participation tokens to mint on completion
    address claimer;             // Who's working on this
    uint96 bountyPayout;         // Additional ERC-20 bounty
    bool requiresApplication;    // Must apply vs. direct claim
    Status status;               // Current lifecycle state
    address bountyToken;         // Which ERC-20 for bounty
}
```

**Task Status Flow:**

```
UNCLAIMED → CLAIMED → SUBMITTED → COMPLETED
    ↑         │  ↑         │
    └─────────┘  └─────────┘
     unclaimTask   rejectTask
    │
    └──→ CANCELLED
```

| Status | Description |
|--------|-------------|
| `UNCLAIMED` | Task created, waiting for someone to take it |
| `CLAIMED` | Worker has committed to complete the task |
| `SUBMITTED` | Work done, awaiting review |
| `COMPLETED` | Approved and tokens/bounty paid out |
| `CANCELLED` | Task abandoned, budget reclaimed |

### Applications

For tasks requiring **competitive selection**, the application system provides structured proposal management.

```solidity
// Storage for applications
mapping(uint256 => address[]) taskApplicants;           // All who applied
mapping(uint256 => mapping(address => bytes32)) taskApplications;  // Application details
```

**Application Flow:**

```
Task Created (requiresApplication: true)
        │
        ▼
  ┌─────────────────┐
  │  Open for       │◄──── Multiple applicants
  │  Applications   │       submit proposals
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ Manager Reviews │◄──── Off-chain review
  │  Applications   │       (IPFS content)
  └────────┬────────┘
           │
           ▼
  ┌─────────────────┐
  │ approveApplication() │
  │  Assigns winner  │
  └────────┬────────┘
           │
           ▼
    Task → CLAIMED
```

### Participation Tokens

**Participation tokens represent ownership stake** in the organization. They're minted fresh for each completed task - not transferred from a pool.

```solidity
interface IParticipationToken is IERC20 {
    function mint(address, uint256) external;
}
```

**Why Minting Matters:**

Traditional payment depletes a treasury:
```
Treasury: 1000 tokens → Pay 100 → Treasury: 900 tokens
```

Participation token minting grows ownership:
```
Total Supply: 10,000 → Mint 100 to worker → Total Supply: 10,100
                                           Worker owns 100/10,100 = ~0.99%
```

Each task completion **increases total supply** while distributing ownership proportionally to contributors.

### Bounties

Bounties provide **flexible external rewards** in any ERC-20 token alongside participation tokens.

**Use Cases:**

| Scenario | Participation Tokens | Bounty Token | Bounty Amount |
|----------|---------------------|--------------|---------------|
| Internal dev work | 500 tokens | None | 0 |
| Bug bounty program | 100 tokens | USDC | $500 |
| Community translation | 50 tokens | None | 0 |
| Security audit | 1000 tokens | ETH | 2 ETH |
| Expense reimbursement | 0 tokens | USDC | $200 |

**Budget Management:**

Each project tracks bounty spending per token:

```solidity
// Add USDC bounty budget to project
setConfig(ConfigKey.BOUNTY_CAP, abi.encode(projectId, USDC, 10000e6));  // $10,000 cap

// Create task with bounty
createTask(
    payout: 100e18,
    title: "Security review",
    metadataHash: 0x...,
    projectId: projectId,
    bountyToken: USDC,
    bountyPayout: 500e6,     // $500
    requiresApplication: true
);
// Project USDC budget: spent += 500
```

---

## Permission System

TaskManager uses **Hats Protocol** for decentralized, composable role management.

### Hats Protocol Integration

Hats Protocol represents roles as ERC-1155 tokens. "Wearing a hat" means having permission to perform certain actions.

```
              ┌──────────────┐
              │   Top Hat    │  (Organization root)
              │   (Admin)    │
              └──────┬───────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ Creator │  │ Manager │  │ Reviewer│
   │   Hat   │  │   Hat   │  │   Hat   │
   └────┬────┘  └────┬────┘  └────┬────┘
        │            │            │
        ▼            ▼            ▼
   Can create    Can assign    Can approve
     tasks         tasks      submissions
```

### Permission Types

Four granular permissions control task operations:

```solidity
library TaskPerm {
    uint8 internal constant CREATE = 1 << 0;   // 0001 - Create tasks
    uint8 internal constant CLAIM  = 1 << 1;   // 0010 - Claim/apply for tasks
    uint8 internal constant REVIEW = 1 << 2;   // 0100 - Complete/approve tasks
    uint8 internal constant ASSIGN = 1 << 3;   // 1000 - Assign tasks to others
}
```

**Permission Composition:**

Permissions can be combined using bitwise OR:

```solidity
// Developer hat: can create and claim
uint8 devPerms = TaskPerm.CREATE | TaskPerm.CLAIM;  // 0011

// Lead hat: full permissions
uint8 leadPerms = TaskPerm.CREATE | TaskPerm.CLAIM | TaskPerm.REVIEW | TaskPerm.ASSIGN;  // 1111
```

**Setting Permissions:**

```solidity
// Global permission (applies to all projects)
setConfig(ConfigKey.ROLE_PERM, abi.encode(devHatId, devPerms));

// Project-specific permission (overrides global)
setProjectRolePerm(projectId, devHatId, TaskPerm.CLAIM);  // Only claim in this project
```

### Project Managers

**Project managers bypass the hat system** with full control over their projects:

```solidity
function _isPM(bytes32 pid, address who) internal view returns (bool) {
    return (who == executor) || projects[pid].managers[who];
}
```

Project managers can:
- Create and cancel tasks
- Assign tasks to anyone
- Review and complete submissions
- Update task details

**Adding/Removing Managers:**

```solidity
setConfig(ConfigKey.PROJECT_MANAGER, abi.encode(projectId, newManager, true));   // Add
setConfig(ConfigKey.PROJECT_MANAGER, abi.encode(projectId, oldManager, false));  // Remove
```

---

## Task Lifecycle

### State Transitions

```
                    ┌──────────────────────────────────────────────┐
                    │                                              │
                    ▼                                              │
            ┌───────────────┐                                      │
 createTask │   UNCLAIMED   │─────────────────────────────────────┐│
            └───────┬───────┘                                     ││
                    │                                             ││
     ┌──────────────┼──────────────┐                              ││
     │              │              │                              ││
     ▼              ▼              ▼                              ▼│
 claimTask    assignTask    approveApplication              cancelTask
     │              │              │                              │
     └──────────────┴──────────────┘                              │
                    │                                             │
                    ▼                                             │
            ┌───────────────┐   unclaimTask                       │
            │    CLAIMED    │──────────────► back to UNCLAIMED    │
            └───────┬───────┘   (claimer, or ASSIGN once expired) │
                    │              ▲                              │
                    ▼              │ rejectTask                   │
               submitTask          │ (REVIEW)                     │
                    │              │                              │
                    ▼              │                              │
            ┌───────────────┐      │                              │
            │   SUBMITTED   │──────┘                              │
            └───────┬───────┘                                     │
                    │                                             │
                    ▼                                             │
             completeTask                                         │
                    │                                             │
                    ▼                                             │
            ┌───────────────┐                            ┌────────────────┐
            │   COMPLETED   │                            │   CANCELLED    │
            └───────────────┘                            └────────────────┘
              Tokens minted                                Budget reclaimed
              Bounty paid
```

### Actions by Status

| Current Status | Available Actions | Required Permission |
|----------------|-------------------|---------------------|
| `UNCLAIMED` | `claimTask` | CLAIM permission |
| `UNCLAIMED` | `assignTask` | ASSIGN permission |
| `UNCLAIMED` | `applyForTask` | CLAIM permission (if requiresApplication) |
| `UNCLAIMED` | `approveApplication` | ASSIGN permission |
| `UNCLAIMED` | `updateTask` | CREATE permission |
| `UNCLAIMED` | `cancelTask` | CREATE permission |
| `CLAIMED` | `submitTask` | Only the claimer |
| `CLAIMED` | `unclaimTask` — release back to the pool | Only the claimer |
| `CLAIMED` (claim expired) | `claimTask` / `assignTask` / `approveApplication` — takeover | CLAIM / ASSIGN / ASSIGN |
| `CLAIMED` (claim expired) | `unclaimTask` — release back to the pool | ASSIGN permission |
| `CLAIMED` (claim expired, requiresApplication) | `applyForTask` | CLAIM permission |
| `SUBMITTED` | `completeTask` | REVIEW permission |
| `SUBMITTED` | `rejectTask` — back to `CLAIMED` for rework | REVIEW permission |

---

## Deadlines & Takeover (v6)

Tasks carry three deadline fields. Two are configured by creators/editors; the third is
derived per claim. All are optional — `0` means "no deadline", and every task created
before v6 reads zeros (no behavior change).

| Field | Type | Set by | Meaning |
|-------|------|--------|---------|
| `absoluteDeadline` | `uint48` unix | create / `updateTask` | Calendar cutoff. While the task is CLAIMED past this moment, the claim is open to takeover. |
| `completionWindow` | `uint32` seconds | create / `updateTask` | Per-claim window: each claimer must submit within this many seconds of claiming, or the claim becomes open to takeover. |
| `claimDeadline` | `uint48` unix | contract | `claimTime + completionWindow`, recomputed at every claim, assignment, application approval, and rejection (fresh window for rework). `0` when no window. |

A fourth, **soft due date** lives only in the task's IPFS metadata JSON (`dueDate`,
unix seconds) — display-only, never enforced on-chain.

### Lenient enforcement model

Deadlines never block work — they only remove claim *protection*:

- **`submitTask` is never deadline-gated.** A late claimer can still submit (and be
  paid) right up until someone actually takes the task over.
- A CLAIMED task is **expired** when `claimDeadline` or `absoluteDeadline` (whichever
  is set) is strictly in the past. The deadline second itself is still protected.
- An expired claim can be **taken over** in one transaction: `claimTask` (CLAIM
  permission), `assignTask` (ASSIGN), or `approveApplication` (ASSIGN, for
  application-gated tasks). The contract emits `TaskClaimExpired(id, previousClaimer,
  newClaimer)` followed by the normal lifecycle event, and the new claimer gets a
  fresh window. The ousted claimer can no longer submit.
- For `requiresApplication` tasks, direct `claimTask` still reverts — but new
  applicants may `applyForTask` while the task is CLAIMED-and-expired, and any past
  or new applicant (including the ousted claimer) can be approved into the takeover.
- The expired claimer may re-claim their own task to refresh the window — visible
  on-chain as `TaskClaimExpired(prev == new)`.
- `SUBMITTED` tasks are **never** takeover-able: delivered work must be reviewed
  (completed or rejected) first. `rejectTask` restarts the window so rework gets a
  fresh allowance.
- Past the `absoluteDeadline`, claims (and takeovers) are still allowed — they are
  simply born unprotected. Reviewers keep full control via `completeTask`.

### Releasing a claim (`unclaimTask`)

A takeover hands the task to a *named* replacement. `unclaimTask` is the same move with
no replacement: status returns to `UNCLAIMED`, `claimer` is zeroed, `claimDeadline` is
cleared (`absoluteDeadline` / `completionWindow` are task config and survive), and the
task is open to anyone eligible again.

- **The claimer may always release**, expired or not, with **no permission check at all**.
  This is deliberate: `assignTask` / `createAndAssignTask` never check the assignee's
  mask, and a hat can be revoked after a claim — so gating release on `CLAIM` would trap
  exactly the people who most need out.
- **An `ASSIGN` holder (or project manager / executor) may release an expired claim.**
  Same gate `assignTask`'s takeover uses, so this grants no new authority: whoever can
  release could already reassign to anyone. A live, unexpired claim stays protected from
  everyone but its own claimer.
- **`SUBMITTED` is excluded.** Delivered work must be reviewed first — this is what keeps
  `completeTask`'s `mint(claimer, …)` from ever seeing `address(0)`, which would brick the
  task (un-completable, un-submittable, un-cancellable, bounty reserved forever). The route
  out of `SUBMITTED` is `rejectTask` → `CLAIMED` → `unclaimTask`.
- **Budgets are untouched.** `spent` tracks what a non-cancelled task has committed, not who
  holds it. Releasing makes the task `cancelTask`-able again, and `cancelTask` remains the
  single place a reservation is refunded — so a claim/release cycle can never double-refund.
- **Applications survive.** Hashes in `taskApplications` are never deleted, so the original
  pool (including the releaser) stays approvable exactly as after a takeover. The applicant
  *array* was already emptied at approval time; index `TaskApplicationSubmitted` off-chain
  for the true pool.
- **A claimer can refresh their own window** by releasing and immediately re-claiming, which
  pre-empts a `completionWindow` takeover. This is accepted: v6 already lets an *expired*
  claimer re-claim to refresh, and the remedy is unchanged — set an `absoluteDeadline` (or
  push one into the past via `updateTask`), which no amount of re-claiming can refresh.
  Application-gated tasks are immune: their releaser needs a fresh approval to get back in.

### Editing deadlines

`updateTask` carries both knobs under its existing permission gates (executor / PM /
`EDIT_FULL` any non-terminal status; `CREATE` while UNCLAIMED):

- Changing `completionWindow` while a task is claimed adjusts the live
  `claimDeadline`, preserving the original claim start (`claimDeadline - oldWindow +
  newWindow`); a previously windowless claim starts `now + newWindow`; setting `0`
  clears it.
- A **past `absoluteDeadline` is deliberately accepted on update** (create paths
  revert `InvalidDeadline` for non-future values). This is the admin lever that opens
  an abandoned CLAIMED task to takeover — `cancelTask` is UNCLAIMED-only, so no other
  remedy exists, including for tasks claimed before v6. A task with **both** deadline
  fields zero never expires, so this two-step (`updateTask` with a past absolute
  deadline, then `unclaimTask` or a takeover) is the only way to unstick it. Set a
  `completionWindow` at creation to avoid needing it.

### Events (indexer contract)

| Event | Emitted |
|-------|---------|
| `TaskDeadlinesSet(uint256 indexed id, uint48 absoluteDeadline, uint32 completionWindow)` | At create only when at least one value is non-zero; on `updateTask` whenever either value changes. |
| `TaskClaimDeadlineSet(uint256 indexed id, uint48 claimDeadline)` | Only when the stored value changes (claim/assign/approve start, reject reset, window-edit adjustment, clear). |
| `TaskClaimExpired(uint256 indexed id, address indexed previousClaimer, address indexed newClaimer)` | On takeover, always before the lifecycle event (`TaskClaimed` / `TaskAssigned` / `TaskApplicationApproved`) in the same transaction. |
| `TaskUnclaimed(uint256 indexed id, address indexed previousClaimer, address indexed caller)` | On `unclaimTask`. `caller == previousClaimer` ⇒ voluntary self-release; otherwise an ASSIGN holder released an expired claim. Never accompanied by `TaskClaimExpired` — no new claimer is named. |

Intra-tx ordering guarantees: `TaskCreated` → `TaskDeadlinesSet?` →
`TaskClaimDeadlineSet?` (create paths); `TaskClaimExpired` → lifecycle event →
`TaskClaimDeadlineSet?` (takeovers); `TaskUnclaimed` → `TaskClaimDeadlineSet(id, 0)?`
(release).

---

## How It Works (With Examples)

### Example 1: Simple Open Task

**Scenario:** A design co-op needs someone to create a logo.

**Step 1: Project manager creates task**
```solidity
// Anyone with CREATE permission for the "branding" project
createTask(
    payout: 200e18,              // 200 participation tokens
    title: "Design new logo",
    metadataHash: 0xabc...,      // IPFS hash with full brief
    projectId: brandingProjectId,
    bountyToken: address(0),     // No bounty
    bountyPayout: 0,
    requiresApplication: false   // First-come, first-served
);
// Emits: TaskCreated(id: 1, ...)
```

**Step 2: Contributor claims task**
```solidity
// Anyone with CLAIM permission
claimTask(1);
// Emits: TaskClaimed(id: 1, claimer: 0x...)
// Task status: UNCLAIMED → CLAIMED
```

**Step 3: Contributor completes work and submits**
```solidity
// Only the claimer can submit
submitTask(1, 0xdef...);  // IPFS hash with deliverables
// Emits: TaskSubmitted(id: 1, submissionHash: 0xdef...)
// Task status: CLAIMED → SUBMITTED
```

**Step 4: Reviewer approves**
```solidity
// Anyone with REVIEW permission
completeTask(1);
// Mints 200 participation tokens to claimer
// Emits: TaskCompleted(id: 1, completer: 0x...)
// Task status: SUBMITTED → COMPLETED
```

### Example 2: Competitive Application

**Scenario:** An engineering co-op needs a complex feature built.

**Step 1: Create task requiring applications**
```solidity
createTask(
    payout: 1000e18,
    title: "Build payment integration",
    metadataHash: 0x...,
    projectId: engineeringProjectId,
    bountyToken: USDC,
    bountyPayout: 2000e6,          // $2000 USDC
    requiresApplication: true       // Must apply
);
// Task ID: 5
```

**Step 2: Multiple developers apply**
```solidity
// Developer A
applyForTask(5, hashOfProposalA);
// Emits: TaskApplicationSubmitted(5, devA, hashOfProposalA)

// Developer B
applyForTask(5, hashOfProposalB);
// Emits: TaskApplicationSubmitted(5, devB, hashOfProposalB)
```

**Step 3: Manager reviews and selects**
```solidity
// Off-chain: review proposals on IPFS
// On-chain: approve winner
approveApplication(5, devB);
// Emits: TaskApplicationApproved(5, devB, manager)
// Task status: UNCLAIMED → CLAIMED
// Clears all other applications
```

**Step 4: Complete as normal**
```solidity
submitTask(5, deliverableHash);
completeTask(5);
// Developer B receives:
//   - 1000 participation tokens (minted)
//   - $2000 USDC (transferred)
```

### Example 3: Direct Assignment

**Scenario:** Manager wants to assign work to a specific contributor.

**Option A: Create and assign in one transaction**
```solidity
createAndAssignTask(
    payout: 150e18,
    title: "Fix login bug",
    metadataHash: 0x...,
    projectId: bugfixProjectId,
    assignee: alice,
    bountyToken: address(0),
    bountyPayout: 0,
    requiresApplication: false
);
// Task created and immediately assigned to Alice
// Status starts at CLAIMED
```

**Option B: Create then assign separately**
```solidity
// Step 1
createTask(...);  // Task ID: 10

// Step 2: Realize Alice should handle it
assignTask(10, alice);
// Emits: TaskAssigned(10, alice, manager)
```

### Example 4: Budget Management

**Scenario:** Managing project resources across tasks.

**Set up project with budgets**
```solidity
// Create project with 10,000 token cap
createProject(
    title: "Q2 Development",
    metadataHash: 0x...,
    cap: 10000e18,
    managers: [],
    createHats: [devHat],
    claimHats: [devHat],
    reviewHats: [leadHat],
    assignHats: [leadHat]
);
// Project ID: 0x...abc

// Add USDC bounty budget
setConfig(
    ConfigKey.BOUNTY_CAP,
    abi.encode(projectId, USDC, 5000e6)  // $5000 cap
);
```

**Create tasks against budget**
```solidity
// Task 1: Uses 500 tokens, $200 USDC
createTask(500e18, ..., USDC, 200e6, ...);
// Project: spent = 500, USDC spent = 200

// Task 2: Uses 800 tokens
createTask(800e18, ..., address(0), 0, ...);
// Project: spent = 1300, USDC spent = 200

// Attempt task exceeding budget
createTask(9000e18, ...);
// REVERTS: BudgetExceeded
```

**Cancel task to reclaim budget**
```solidity
cancelTask(taskId);
// Project: spent -= taskPayout
// USDC spent -= taskBountyPayout
// Task status: CANCELLED
```

### Example 5: Multi-Hat Permissions

**Scenario:** Different roles have different abilities per project.

**Set up permission matrix**
```solidity
// Global permissions (default for all projects)
setConfig(ConfigKey.ROLE_PERM, abi.encode(
    contributorHat,
    TaskPerm.CLAIM  // Contributors can claim anywhere
));

setConfig(ConfigKey.ROLE_PERM, abi.encode(
    seniorDevHat,
    TaskPerm.CREATE | TaskPerm.CLAIM | TaskPerm.REVIEW
));

// Project-specific override
setProjectRolePerm(
    sensitiveProjectId,
    contributorHat,
    0  // Revoke claim permission for this project
);

setProjectRolePerm(
    sensitiveProjectId,
    seniorDevHat,
    TaskPerm.CREATE | TaskPerm.CLAIM | TaskPerm.REVIEW | TaskPerm.ASSIGN
);
```

**Permission resolution**
```solidity
// For sensitiveProject:
//   - Contributors: NO permissions (project override = 0)
//   - Senior devs: Full permissions (project override)

// For other projects:
//   - Contributors: CLAIM only (global)
//   - Senior devs: CREATE | CLAIM | REVIEW (global)
```

---

## Technical Reference

### Contract Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     TaskManager.sol                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              ERC-7201 Storage Layout                 │   │
│  │                                                     │   │
│  │  ┌──────────────┐    ┌──────────────┐              │   │
│  │  │   Projects   │    │    Tasks     │              │   │
│  │  │ mapping[id]  │    │ mapping[id]  │              │   │
│  │  └──────────────┘    └──────────────┘              │   │
│  │                                                     │   │
│  │  ┌──────────────┐    ┌──────────────┐              │   │
│  │  │ Applications │    │ Permissions  │              │   │
│  │  │   storage    │    │  rolePerms   │              │   │
│  │  └──────────────┘    └──────────────┘              │   │
│  │                                                     │   │
│  │  ┌──────────────────────────────────────────┐      │   │
│  │  │  Configuration: hats, token, executor    │      │   │
│  │  └──────────────────────────────────────────┘      │   │
│  └─────────────────────────────────────────────────────┘   │
└────────────────────────────┬────────────────────────────────┘
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │ TaskPerm │      │BudgetLib │      │  HatMgr  │
    │  (perms) │      │ (budget) │      │  (hats)  │
    └──────────┘      └──────────┘      └──────────┘
```

### Storage Layout (ERC-7201)

All storage uses namespaced slots for upgrade safety:

```solidity
struct Layout {
    mapping(bytes32 => Project) _projects;
    mapping(uint256 => Task) _tasks;
    IHats hats;
    IParticipationToken token;
    uint256[] creatorHatIds;                    // Who can create projects
    uint48 nextTaskId;
    uint48 nextProjectId;
    address executor;                           // Admin address
    mapping(uint256 => uint8) rolePermGlobal;   // Hat → global permissions
    mapping(bytes32 => mapping(uint256 => uint8)) rolePermProj;  // Project → hat → permissions
    uint256[] permissionHatIds;                 // Tracked hats with permissions
    mapping(uint256 => address[]) taskApplicants;
    mapping(uint256 => mapping(address => bytes32)) taskApplications;
}
```

### Key Functions

#### Project Management

| Function | Description | Access |
|----------|-------------|--------|
| `createProject` | Create new project with budgets and permissions | Creator hat or executor |
| `deleteProject` | Remove project entirely | Creator hat or executor |

#### Task Management

| Function | Description | Access |
|----------|-------------|--------|
| `createTask` | Create new task in project | CREATE permission for project |
| `updateTask` | Modify unclaimed task details | CREATE permission for project |
| `cancelTask` | Cancel unclaimed task, reclaim budget | CREATE permission for project |
| `claimTask` | Self-assign open task (or take over an expired claim) | CLAIM permission for project |
| `assignTask` | Assign task to specific address | ASSIGN permission for project |
| `unclaimTask` | Release a claimed task back to the pool | Task claimer always; ASSIGN once the claim has expired |
| `submitTask` | Submit completed work | Task claimer only |
| `completeTask` | Approve submission, trigger payout | REVIEW permission for project |
| `rejectTask` | Send a submission back for rework | REVIEW permission for project |
| `createAndAssignTask` | Create and assign atomically | CREATE + ASSIGN permissions |

#### Application System

| Function | Description | Access |
|----------|-------------|--------|
| `applyForTask` | Submit application for task | CLAIM permission, task requires application |
| `approveApplication` | Select applicant, assign task | ASSIGN permission for project |

#### Configuration

| Function | Description | Access |
|----------|-------------|--------|
| `setConfig` | Update executor, hats, budgets | Executor only |
| `setProjectRolePerm` | Set project-specific hat permissions | Creator hat or executor |

### Events

Complete audit trail for off-chain indexing:

```solidity
// Project lifecycle
event ProjectCreated(bytes32 indexed id, bytes title, bytes32 metadataHash, uint256 cap);
event ProjectCapUpdated(bytes32 indexed id, uint256 oldCap, uint256 newCap);
event ProjectManagerUpdated(bytes32 indexed id, address indexed manager, bool isManager);
event ProjectDeleted(bytes32 indexed id);
event ProjectRolePermSet(bytes32 indexed id, uint256 indexed hatId, uint8 mask);
event BountyCapSet(bytes32 indexed projectId, address indexed token, uint256 oldCap, uint256 newCap);

// Task lifecycle
event TaskCreated(uint256 indexed id, bytes32 indexed project, uint256 payout,
                  address bountyToken, uint256 bountyPayout, bool requiresApplication,
                  bytes title, bytes32 metadataHash);
event TaskUpdated(uint256 indexed id, uint256 payout, address bountyToken,
                  uint256 bountyPayout, bytes title, bytes32 metadataHash);
event TaskClaimed(uint256 indexed id, address indexed claimer);
event TaskAssigned(uint256 indexed id, address indexed assignee, address indexed assigner);
event TaskUnclaimed(uint256 indexed id, address indexed previousClaimer, address indexed caller);
event TaskSubmitted(uint256 indexed id, bytes32 submissionHash);
event TaskCompleted(uint256 indexed id, address indexed completer);
event TaskCancelled(uint256 indexed id, address indexed canceller);
event TaskRejected(uint256 indexed id, address indexed rejector, bytes32 rejectionHash);

// Deadlines & takeover (v6)
event TaskDeadlinesSet(uint256 indexed id, uint48 absoluteDeadline, uint32 completionWindow);
event TaskClaimDeadlineSet(uint256 indexed id, uint48 claimDeadline);
event TaskClaimExpired(uint256 indexed id, address indexed previousClaimer, address indexed newClaimer);

// Application system
event TaskApplicationSubmitted(uint256 indexed id, address indexed applicant, bytes32 applicationHash);
event TaskApplicationApproved(uint256 indexed id, address indexed applicant, address indexed approver);

// Configuration
event HatSet(HatType hatType, uint256 hat, bool allowed);
event ExecutorUpdated(address newExecutor);
```

### Error Reference

| Error | Cause |
|-------|-------|
| `NotFound` | Task or project doesn't exist |
| `BadStatus` | Invalid operation for current task status (also: releasing a claim that is still protected) |
| `NotCreator` | Caller lacks creator hat or executor role |
| `NotClaimer` | Caller is not the task's current claimer |
| `NotExecutor` | Only executor can call this config function |
| `Unauthorized` | Caller lacks required permission |
| `NotApplicant` | Address hasn't applied for this task |
| `AlreadyApplied` | Cannot apply twice for same task |
| `RequiresApplication` | Task requires application, can't direct claim |
| `NoApplicationRequired` | Task is open, use claimTask instead |
| `BudgetExceeded` | Task payout would exceed project cap |
| `SpentUnderflow` | Budget accounting error |

---

## Code Walkthrough

### Permission Check Flow

When a user attempts an action, the permission system evaluates in order:

```solidity
function _checkPerm(bytes32 pid, uint8 flag) internal view {
    address s = _msgSender();

    // 1. Check hat-based permissions
    if (TaskPerm.has(_permMask(s, pid), flag)) return;  // Allowed

    // 2. Check if project manager
    if (_isPM(pid, s)) return;  // Managers bypass hat checks

    // 3. No permission found
    revert Unauthorized();
}
```

The `_permMask` function aggregates permissions from all hats the user wears:

```solidity
function _permMask(address user, bytes32 pid) internal view returns (uint8 m) {
    // Batch check all permission hats at once
    uint256[] memory bal = hats.balanceOfBatch(wearers, hats_);

    for (uint256 i; i < len;) {
        if (bal[i] == 0) continue;  // User doesn't wear this hat

        uint256 h = hats_[i];
        uint8 mask = rolePermProj[pid][h];  // Project-specific first
        m |= mask == 0 ? rolePermGlobal[h] : mask;  // Fall back to global
    }
}
```

**Key insight:** Project permissions override global permissions completely. If a hat has global `CREATE | CLAIM` but project permission `CLAIM` only, the user gets only `CLAIM` for that project.

### Task Completion and Payout

When `completeTask` is called, two payouts occur atomically:

```solidity
function completeTask(uint256 id) external {
    // Permission check
    _checkPerm(tasks[id].projectId, TaskPerm.REVIEW);

    Task storage t = _task(id);
    if (t.status != Status.SUBMITTED) revert BadStatus();

    // Update status
    t.status = Status.COMPLETED;

    // 1. Mint participation tokens
    token.mint(t.claimer, uint256(t.payout));

    // 2. Transfer bounty (if any)
    if (t.bountyToken != address(0) && t.bountyPayout > 0) {
        IERC20(t.bountyToken).safeTransfer(t.claimer, uint256(t.bountyPayout));
    }

    emit TaskCompleted(id, _msgSender());
}
```

**Note:** The contract must hold sufficient bounty tokens. The participation token is minted, not transferred.

### Budget Tracking

Task creation and cancellation update project budgets:

```solidity
// On task creation
function _createTask(...) internal {
    Project storage p = projects[pid];

    // Participation token budget
    uint256 newSpent = p.spent + payout;
    if (p.cap != 0 && newSpent > p.cap) revert BudgetExceeded();
    p.spent = uint128(newSpent);

    // Bounty budget (if applicable)
    if (bountyToken != address(0) && bountyPayout > 0) {
        p.bountyBudgets[bountyToken].addSpent(bountyPayout);
    }
}

// On task cancellation
function cancelTask(uint256 id) external {
    Project storage p = projects[t.projectId];

    // Reclaim participation budget
    p.spent -= t.payout;

    // Reclaim bounty budget
    if (t.bountyToken != address(0) && t.bountyPayout > 0) {
        p.bountyBudgets[t.bountyToken].subtractSpent(t.bountyPayout);
    }
}
```

### Application Lifecycle

The application system manages competitive task assignment:

```solidity
// Apply for task
function applyForTask(uint256 id, bytes32 applicationHash) external {
    _requireCanClaim(id);  // Must have CLAIM permission

    Task storage t = _task(id);
    if (!t.requiresApplication) revert NoApplicationRequired();
    if (taskApplications[id][applicant] != bytes32(0)) revert AlreadyApplied();

    taskApplicants[id].push(applicant);
    taskApplications[id][applicant] = applicationHash;

    emit TaskApplicationSubmitted(id, applicant, applicationHash);
}

// Approve application
function approveApplication(uint256 id, address applicant) external {
    _requireCanAssign(tasks[id].projectId);  // Must have ASSIGN permission

    if (taskApplications[id][applicant] == bytes32(0)) revert NotApplicant();

    // Assign to applicant
    t.status = Status.CLAIMED;
    t.claimer = applicant;

    // Clear all applications
    delete taskApplicants[id];

    emit TaskApplicationApproved(id, applicant, _msgSender());
}
```

---

## The Vision: Work as Ownership

TaskManager isn't just software - it's a new paradigm for how organizations can operate.

**Traditional employment:**
- You work → Company profits → Shareholders benefit
- Your labor enriches others

**POA with TaskManager:**
- You work → Task completed → Tokens minted to you
- Your labor builds your ownership stake

Every task you complete increases your voice in governance, your share of dividends, and your stake in the organization's success. The more you contribute, the more you own.

This is **worker ownership made executable** - not through legal documents and trust, but through transparent, immutable smart contracts that ensure fair compensation for every contribution.

---

**Version:** 1.0
**Last Updated:** 2025
**Maintainers:** POA Engineering Team
**License:** MIT
