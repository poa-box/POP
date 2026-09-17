# Perpetual Organization Protocol (POP)

**Version:** 1.0
**License:** MIT

---

## The Stakes: Why This Matters

In the current economy, workers create value that flows upward. Platform companies capture billions while drivers and delivery workers scrape by. Tech giants extract data from communities and return nothing. Cooperative movements have fought this for over a century, but they've been limited by the same problems: How do you coordinate ownership across thousands of people? How do you make collective decisions without intermediaries who accumulate power? How do you ensure that democratic governance actually happens, transparently and verifiably?

**Blockchain changes what's possible.**

The Perpetual Organization Protocol (POP) is infrastructure for a different kind of organization—one where work creates ownership, where governance is transparent and cryptographically guaranteed, and where power cannot be quietly accumulated by insiders. It's not a marginal improvement to existing structures. It's a complete alternative.

```
Traditional Model:
  Worker → Labor → Company → Profits → Shareholders → Worker gets wages

POP Model:
  Worker → Labor → Participation Tokens → Ownership + Governance → Worker owns the organization
```

Every task completed in a POP organization mints ownership stake to the person who did the work. Every decision happens on-chain, visible to all members. No backroom deals. No invisible hierarchies. No extraction.

---

## Who Is POP For?

### Direct Democracy Groups

If you believe that every member's voice should count equally—not weighted by wealth, not diluted by delegation—POP provides the infrastructure:

- **Neighborhood Associations:** Collective decisions about shared resources, transparent budgets, equal votes
- **Tenant Unions:** Coordinating collective action with cryptographic accountability
- **Clubs and Societies:** From book clubs with treasuries to hobby groups making equipment purchases
- **Community Land Trusts:** Democratic stewardship of shared property
- **Parent-Teacher Organizations:** Equal voice regardless of who has time for meetings
- **Mutual Aid Networks:** Pooling resources, making collective decisions about distribution

POP's `DirectDemocracyVoting` contract enforces pure equality: every eligible member gets exactly 100 voting points. Period. You cannot buy more. You cannot inherit more. Your voice is equal to everyone else's.

```solidity
// DirectDemocracyVoting: Pure equality enforced in code
function _calculateVotes(address voter) internal pure returns (uint256) {
    return 100; // Every voter. No exceptions. No weights.
}
```

### Worker Cooperatives

The classic use case: organizations owned by the people who do the work.

Traditional cooperatives struggle with:
- Governance that scales beyond physical meetings
- Transparent, auditable decision-making
- Compensating contributors fairly across time zones
- Onboarding members without bureaucratic friction

POP solves these by making ownership programmable:
- Complete tasks → receive participation tokens → own more of the organization
- Vote on proposals → decisions execute automatically on-chain
- Revenue arrives → distribution happens proportionally to ownership

### DAOs Seeking Democratic Foundations

Most DAOs default to plutocracy: more tokens = more votes. This is just shareholder capitalism with extra steps.

POP offers alternatives:
- **DirectDemocracyVoting:** One person, one vote—pure equality
- **HybridVoting:** Balance multiple constituencies (e.g., 60% weight to member-vote, 40% to token-weighted)
- **Quadratic voting:** Limit whale influence in hybrid systems

If you want your DAO to be actually democratic, POP provides the contracts.

### Open Source Projects

Contributors to open source create enormous value but traditionally own nothing. POP enables:

- Issue completion → participation tokens minted to contributor
- Token holders govern project direction
- If the project generates revenue (sponsorships, grants, commercial licensing), it flows to contributors proportionally

The maintainer who's been contributing for years has more stake than someone who just arrived—but that stake was earned through contribution, not purchased.

### Artist and Creator Collectives

Musicians, writers, visual artists, and other creators can:
- Pool resources and infrastructure
- Make collective decisions about shared direction
- Distribute revenue fairly when work sells
- Build organizations that persist beyond any individual

---

## Core Principles

### 1. Work Creates Ownership

This is the foundation. In POP organizations, **contribution is the path to ownership**. Not investment. Not connections. Not inheritance. Work.

```solidity
// ParticipationToken: The ownership primitive
// When work is approved:
function mint(address to, uint256 amount) external onlyTaskOrEdu {
    _mint(to, amount);
    // `to` now owns more of the organization
}

// You cannot buy your way in:
function transfer(address, uint256) public pure override returns (bool) {
    revert TransfersDisabled();
}

function transferFrom(address, address, uint256) public pure override returns (bool) {
    revert TransfersDisabled();
}
```

Participation tokens are non-transferable. You earn them. You keep them. They represent your accumulated contribution to the organization.

### 2. One Member, One Voice (When It Matters)

POP's DirectDemocracyVoting ensures that wealth cannot distort governance. Every member who meets the eligibility requirements (wearing the appropriate Hats) gets equal voting power.

This matters because:
- Plutocratic voting replicates the problems of capitalism
- Token-weighted governance allows coordination attacks by wealthy actors
- Democratic legitimacy requires equal standing

### 3. Multiple Stakeholders, Proportional Voice

Not every decision should be pure direct democracy. Sometimes you want to balance:
- Workers (equal voice)
- Long-term contributors (token-weighted)
- Community members (different eligibility criteria)

HybridVoting lets organizations configure multiple "classes" of voters with different weights. A single proposal might give:
- 50% weight to worker-members (one person, one vote)
- 30% weight to token holders (contribution-weighted)
- 20% weight to community advisors

### 4. Collective Infrastructure, Individual Autonomy

Organizations share infrastructure—gasless transactions, identity systems, upgrade mechanisms—while maintaining complete autonomy over their own governance.

The PaymasterHub exemplifies this: smaller organizations get subsidized by the solidarity fund (fed by larger organizations). This isn't charity—it's mutual aid encoded in smart contracts.

### 5. Transparency by Default

Every proposal, every vote, every task, every payment happens on-chain. There's no hidden ledger. No decisions made in private channels that members can't see.

This creates:
- Accountability that doesn't depend on trust
- Historical records that can't be revised
- Governance that's auditable by anyone

---

## System Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Protocol Layer                  │
                    │   PoaManager · ImplementationRegistry        │
                    │   PaymasterHub · UniversalAccountRegistry    │
                    └──────────────────────┬──────────────────────┘
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    │             Deployment Layer                 │
                    │          OrgDeployer · OrgRegistry           │
                    │           Factory Contracts                  │
                    └──────────────────────┬──────────────────────┘
                                           │
         ┌─────────────────────────────────┼─────────────────────────────────┐
         │                                 │                                 │
         ▼                                 ▼                                 ▼
┌───────────────────┐            ┌───────────────────┐            ┌───────────────────┐
│    Governance     │            │      Access       │            │    Operations     │
│                   │            │                   │            │                   │
│ • DirectDemocracy │            │ • MembershipAuth. │            │ • TaskManager     │
│ • HybridVoting    │            │ • QuickJoin       │            │ • EducationHub    │
│ • Executor        │            │ • Participation   │            │ • PaymentManager  │
│                   │            │   Token           │            │                   │
└───────────────────┘            └───────────────────┘            └───────────────────┘
```

### Protocol Layer

Shared infrastructure for all POP organizations:

| Contract | Purpose |
|----------|---------|
| **PaymasterHub** | Gasless transactions with solidarity-based mutual aid |
| **UniversalAccountRegistry** | Shared identity—usernames work across all POP orgs |
| **ImplementationRegistry** | Version management for upgradeable contracts |
| **PoaManager** | Protocol-level configuration |

### Deployment Layer

How organizations come into existence:

| Contract | Purpose |
|----------|---------|
| **OrgDeployer** | Single-transaction atomic deployment of complete organizations |
| **OrgRegistry** | Central registry of all organizations and their contracts |
| **Factory Contracts** | Create governance, access, and operational modules |

### Organization Layer

Each organization is a set of interconnected modules:

- **Governance:** How decisions are made (voting, execution)
- **Access:** Who can participate (roles, membership, onboarding)
- **Operations:** How work is coordinated and compensated

---

## Key Components

### ParticipationToken

The ownership primitive. Every POP organization has one.

**Key Properties:**
- **Non-transferable:** Cannot be bought, sold, or delegated
- **Minted through contribution:** TaskManager and EducationHub mint tokens
- **Voting-enabled:** Built on ERC20Votes for governance integration
- **Auto-delegating:** Votes automatically count for the holder

```solidity
// Key functions
function mint(address to, uint256 amount) external onlyTaskOrEdu;
function requestTokens(uint96 amount, string calldata ipfsHash) external isMember;
function approveRequest(uint256 id) external onlyApprover;

// Transfer functions revert—no market for ownership
function transfer(address, uint256) public pure override returns (bool) {
    revert TransfersDisabled();
}
```

**Ownership Calculation:**
```
Your ownership = Your tokens / Total supply

Example:
- Total supply: 10,000 tokens
- You complete task worth 100 tokens
- New supply: 10,100 tokens
- Your ownership: 100/10,100 ≈ 0.99%
```

### TaskManager

Work coordination that creates ownership.

**Hierarchy:**
```
Organization
└── Projects (budgets, managers)
    └── Tasks (work units, payouts)
        └── Applications (for complex work)
```

**The Ownership Cycle:**
```
1. Organization creates task with payout:
   createTask(projectId, payout, bounty, ...)

2. Worker claims or applies:
   claimTask(taskId) / applyForTask(taskId, ...)

3. Worker completes and submits:
   submitTask(taskId, submissionHash)

4. Reviewer approves:
   approveTask(taskId)
   → Participation tokens minted to worker
   → Bounty transferred (if applicable)
   → Worker now owns more of the organization
```

### DirectDemocracyVoting

Pure one-person-one-vote governance.

```solidity
// Every eligible voter gets exactly 100 points
// No more. No less. No exceptions.
uint256 constant VOTE_POINTS = 100;

// Create proposals with multiple options
function createProposal(
    string calldata title,
    bytes32 descriptionHash,
    uint256 duration,
    bytes[] calldata options,   // Not just yes/no
    IExecutor.Call[][] calldata calls
) external returns (uint256 proposalId);

// Vote by distributing your 100 points across options
function vote(
    uint256 proposalId,
    uint256[] calldata optionIndices,
    uint256[] calldata weights  // Must sum to 100
) external;

// After voting ends, execute winning option
function executeProposal(uint256 proposalId) external;
```

**Key Features:**
- Multi-option proposals (not just yes/no)
- Distribute voting power across options
- Quorum requirements (minimum participation)
- Strict majority required (>50% of participating votes)
- On-chain execution of winning proposals

### HybridVoting

Multi-constituency governance for complex organizations.

```solidity
struct VotingClass {
    uint16 weight;           // Percentage of total voting power
    bool isDirectDemocracy;  // true = equal votes, false = token-weighted
    bool useQuadratic;       // Apply sqrt() to token-weighted votes
    uint256[] eligibleHatIds;// Which hats can vote in this class
}
```

**Example Configuration:**
```
Class 0: Workers
  - Weight: 50%
  - DirectDemocracy: true (equal votes)
  - Hats: [workerHatId]

Class 1: Token Holders
  - Weight: 50%
  - DirectDemocracy: false (token-weighted)
  - UseQuadratic: true (limit whale influence)
  - Hats: [memberHatId]
```

### Executor

The "hands" of the organization. Can only act when instructed by governance.

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}

// Only the authorized voting contract can trigger execution
function execute(uint256 proposalId, Call[] calldata batch) external;
```

After deployment, the Executor's ownership is **immediately renounced**. No individual can control it. Only collective decisions through governance.

### QuickJoin

Frictionless onboarding.

```solidity
// User already has username from another POP org
function quickJoinWithUser() external;

// Register username and join with passkey in one call
function registerAndQuickJoinWithPasskey(...) external returns (address account);

// Register username and join with EOA in one call
function registerAndQuickJoin(address user, string calldata username, ...) external;
```

1. User calls QuickJoin
2. Username registered (if needed) in UniversalAccountRegistry
3. Member hats minted to user
4. User is immediately ready to participate

### EducationHub

Learning as a path to ownership.

```solidity
// Creator creates educational module
function createModule(
    bytes calldata title,
    bytes32 contentHash,  // IPFS hash of learning content
    uint256 payout,       // Tokens earned on completion
    uint8 correctAnswer   // Answer hash stored privately
) external;

// Member completes module
function completeModule(uint256 id, uint8 answer) external;
// If correct: participation tokens minted to learner
```

Organizations can create onboarding paths, skill assessments, or knowledge-sharing incentives.

### PaymentManager

Revenue distribution for worker-owners.

```solidity
// Accept payments
receive() external payable;
function payERC20(address token, uint256 amount) external;

// Create distribution (off-chain merkle tree calculation)
function createDistribution(
    address payoutToken,
    uint256 amount,
    bytes32 merkleRoot,
    uint256 checkpointBlock
) external returns (uint256 distributionId);

// Members claim their share
function claimDistribution(
    uint256 distributionId,
    uint256 claimAmount,
    bytes32[] calldata merkleProof
) external;
```

Revenue → Merkle distribution → Members claim proportionally to ownership.

### PaymasterHub

Shared gas sponsorship with built-in solidarity.

Traditional ERC-4337 paymasters cost ~$500 each. PaymasterHub is multi-tenant—one contract serves all POP organizations.

**The Solidarity System:**
```
┌─────────────────────────────────────────────────────┐
│                   PaymasterHub                       │
│                                                      │
│  Grace Period (90 days):                            │
│  └── New orgs get 0.01 ETH (~3000 txns) free       │
│                                                      │
│  Progressive Tiers:                                  │
│  ├── Tier 1: 0.003 ETH → 0.006 ETH match (2x)      │
│  ├── Tier 2: 0.006 ETH → 0.009 ETH match (1.5x)    │
│  └── Tier 3: 0.017 ETH+ → Self-sufficient          │
│                                                      │
│  Every Transaction:                                  │
│  └── 1% → Solidarity Fund                           │
│                                                      │
│  Result: Established orgs subsidize emerging ones   │
└─────────────────────────────────────────────────────┘
```

Mutual aid, encoded in smart contracts.

---

## Role-Based Access with the MembershipAuthority

Every org owns one `MembershipAuthority`: membership, eligibility and permissions in a single
per-org contract, expressed as **subjects**.

```
              ┌──────────────┐
              │    ADMIN     │  ← held by the Executor (lock-out guard)
              └──────┬───────┘
                     │
        ┌────────────┼────────────┐        ┌────────────────────┐
        ▼            ▼            ▼        │  GROUP: Reviewers  │
   ┌─────────┐  ┌─────────┐  ┌─────────┐   │  = {Worker, …}     │
   │ Member  │  │ Worker  │  │Reviewer │◄──┤  derived membership│
   │  role   │  │  role   │  │  role   │   └────────────────────┘
   └─────────┘  └─────────┘  └─────────┘
        │            │            │
        ▼            ▼            ▼
     Can vote     Can claim    Can approve
   in proposals    tasks        work
```

**Key Features:**
- Role and group subjects, with per-subject default verdicts (`open` = anyone may claim) and caps
- Permission rows keyed by module (voting, tasks, education, token) — no separate eligibility module
- Vouching attestors for role progression
- Dynamic assignment through governance, all from one contract

Orgs deployed before Access v2 run on [Hats Protocol](https://docs.hatsprotocol.xyz) and read
through the protocol's `AuthorityRouter` until they migrate.

---

## See It In Action

### Example 1: Neighborhood Book Club

**Setup:** 12 members, shared treasury for book purchases, equal voice.

```
Deployment:
├── DirectDemocracyVoting (every member gets 100 points)
├── ParticipationToken (tracks membership)
├── Executor (holds treasury, executes decisions)
└── QuickJoin (easy onboarding)

Flow:
1. Member proposes: "Buy 'Parable of the Sower' for $15"
2. Other members vote (100 points each, majority wins)
3. Proposal passes → Executor sends $15 to bookseller
4. Book arrives, everyone reads, democracy happened
```

No bank account. No treasurer who could abscond. No disputes about who decided what.

### Example 2: Worker Cooperative

**Setup:** Design agency with 8 worker-owners, hybrid governance.

```
Deployment:
├── HybridVoting (50% equal vote + 50% contribution-weighted)
├── ParticipationToken (ownership stake)
├── TaskManager (project/task coordination)
├── PaymentManager (revenue distribution)
├── Executor
└── QuickJoin

Work Cycle:
1. Client pays 10 ETH for project
2. Project created in TaskManager with tasks
3. Designers claim tasks, complete work
4. Reviewers approve → tokens minted to workers
5. Quarter ends → PaymentManager distributes revenue
   └── Each worker receives proportional to their tokens

Governance:
1. Major decision: "Should we take on crypto clients?"
2. HybridVoting proposal created
3. Everyone votes:
   ├── Class 0 (DirectDemocracy): Alice, Bob, Carol... each 100 points
   └── Class 1 (Token-weighted): Weighted by accumulated contribution
4. Results combined per class weights
5. Decision executes on-chain
```

### Example 3: Open Source Project

**Setup:** JavaScript library with global contributors.

```
Deployment:
├── DirectDemocracyVoting (contributors govern direction)
├── ParticipationToken (contribution = ownership)
├── TaskManager (issues = tasks with payouts)
├── EducationHub (onboarding modules)
├── PaymentManager (sponsor/grant distribution)
└── QuickJoin

Contribution Flow:
1. Issue labeled with token payout (e.g., "fix bug = 50 tokens")
2. Contributor claims task, submits PR
3. Maintainer approves → tokens minted
4. Contributor now has governance stake

Revenue:
1. Corporate sponsor sends 5 ETH
2. PaymentManager receives funds
3. Distribution created based on token holdings
4. Every contributor claims their share

Governance:
1. Proposal: "Adopt TypeScript for v2"
2. All token holders vote (equal voice)
3. Majority decides
4. Direction set democratically
```

---

## For Developers

### Quick Start

**Key Contracts:**
| Contract | Purpose | Key Entry Points |
|----------|---------|------------------|
| `OrgDeployer` | Deploy complete organization | `deployFullOrg()` |
| `ParticipationToken` | Ownership tokens | `mint()`, `balanceOf()` |
| `TaskManager` | Work coordination | `createTask()`, `completeTask()` |
| `DirectDemocracyVoting` | Equal-voice governance | `createProposal()`, `vote()` |
| `HybridVoting` | Multi-class governance | `createProposal()`, `vote()` |
| `Executor` | Execute governance decisions | `execute()` |

### Key Events for Indexing

```solidity
// TaskManager
event TaskCompleted(uint256 indexed taskId, address indexed worker);
event TaskCreated(uint256 indexed projectId, uint256 indexed taskId, ...);

// ParticipationToken
event Transfer(address indexed from, address indexed to, uint256 value);
// (from = address(0) indicates mint)

// Voting
event ProposalCreated(uint256 indexed proposalId, address indexed creator, ...);
event Voted(uint256 indexed proposalId, address indexed voter, ...);
event ProposalExecuted(uint256 indexed proposalId);

// QuickJoin
event QuickJoined(address indexed user, bool usernameCreated, uint256[] hatIds);
```

### Integration Patterns

**Check Membership:**
```solidity
IParticipationToken token = IParticipationToken(tokenAddress);
uint256 balance = token.balanceOf(user);
bool isMember = balance > 0;
```

**Check Voting Power:**
```solidity
// For DirectDemocracy: every member has 100 points
// For Hybrid: varies by class

IDirectDemocracyVoting voting = IDirectDemocracyVoting(votingAddress);
// Check if user can vote (wears eligible hat)
```

**Create Proposal Programmatically:**
```solidity
IExecutor.Call[] memory calls = new IExecutor.Call[](1);
calls[0] = IExecutor.Call({
    target: treasuryAddress,
    value: 0.1 ether,
    data: "" // ETH transfer
});

bytes[] memory options = new bytes[](2);
options[0] = "Approve payment";
options[1] = "Reject";

IExecutor.Call[][] memory callsPerOption = new IExecutor.Call[][](2);
callsPerOption[0] = calls;  // Execute on "Approve"
callsPerOption[1] = new IExecutor.Call[](0);  // No-op on "Reject"

voting.createProposal(
    "Pay contractor",
    descriptionHash,
    7 days,
    options,
    callsPerOption
);
```

---

## Technical Foundation

### Upgradeable Architecture

All POP contracts use UUPS proxies with ERC-7201 namespaced storage:

```solidity
// Storage slot calculated from namespace
bytes32 private constant _STORAGE_SLOT =
    keccak256("poa.participationtoken.storage");

function _layout() private pure returns (Layout storage s) {
    assembly { s.slot := _STORAGE_SLOT }
}
```

**SwitchableBeacon** lets organizations choose:
- **Mirror Mode:** Auto-follow protocol upgrades
- **Static Mode:** Pin to specific version (governance-controlled)

### Security

- **Reentrancy guards** on all state-changing functions
- **Role-based access** through each org's `MembershipAuthority`
- **Input validation** via ValidationLib
- **Emergency pause** capabilities
- **Atomic deployment** (no intermediate vulnerable states)
- **Ownership renounced** immediately after deployment

### Gas Optimization

- Bitmap-based permission management
- Packed storage layouts (ERC-7201)
- Batch operations for common patterns
- Shared PaymasterHub reduces per-org costs

---

## The Bigger Picture

POP isn't just smart contracts. It's infrastructure for economic democracy.

Every organization deployed adds another node to a network of worker-owned, democratically-governed entities. The PaymasterHub's solidarity fund means that success compounds—established organizations subsidize emerging ones.

Every task completed transfers ownership to the person who did the work. Not to shareholders. Not to executives. To workers.

Every vote cast on-chain creates an auditable record of collective decision-making. No backroom deals. No revised minutes. No "that's not what we agreed."

This is what becomes possible when you rebuild organizations on cryptographic foundations:
- **Ownership that cannot be extracted**
- **Governance that cannot be captured**
- **Transparency that cannot be redacted**
- **Solidarity that is programmatic**

The cooperative movement has been building toward this for 200 years. Now we have the tools.

---

## Documentation Index

Detailed documentation for each component:

- [DirectDemocracyVoting](./DIRECT_DEMOCRACY_VOTING.md) - One person, one vote governance
- [HybridVoting](./HYBRID_VOTING.md) - Multi-constituency voting system
- [TaskManager](./TASK_MANAGER.md) - Work coordination and token rewards
- [OrgDeployer](./ORG_DEPLOYER.md) - Atomic organization deployment
- [PaymasterHub](./PAYMASTER_HUB.md) - Shared gas sponsorship with solidarity
- [SwitchableBeacon](../SWITCHABLE_BEACON.md) - Upgrade management architecture

---

## Build With Us

POP is open source under the MIT license.

If you believe that organizations should belong to the people who build them—not to investors who extract value—this is your infrastructure.

**Build together. Own together. Govern together.**

---

*The Perpetual Organization Protocol*
