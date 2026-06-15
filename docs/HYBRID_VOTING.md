# HybridVoting: Community-Owned Governance for Perpetual Organizations

## Philosophy: Beyond "One Token, One Vote"

Traditional governance systems force a false choice: either pure democracy (one person, one vote) where contribution goes unrewarded, or plutocracy (one token, one vote) where capital dominates labor. Neither reflects how real communities make decisions.

**HybridVoting reimagines governance for worker-owned organizations.** It recognizes that different stakeholders bring different value: the founding contributor who shaped the vision, the worker who builds day-to-day, the token holder who provides resources, the community member who uses what's built. Each deserves a voice proportional to their relationship with the organization.

### Multi-Constituency Governance

The breakthrough of HybridVoting is its ability to represent **multiple stakeholder classes simultaneously**, each with their own share of governance power:

- **Members** can hold a guaranteed percentage of decision-making weight through traditional one-person-one-vote democracy—ensuring that human participation, not capital, anchors the organization.

- **Workers** who contribute labor can earn governance power proportional to their effort, measured through ParticipationTokens granted for completed tasks and contributions.

- **Users and customers** who depend on what the organization creates can be given a formal voice, aligning the organization with those it serves rather than extracting from them.

- **The broader community**—supporters, advocates, ecosystem participants—can participate in shaping direction without needing to be insiders or investors.

This isn't theoretical. A single organization can allocate 40% to worker-members (direct democracy), 35% to labor contributors (token-weighted by work performed), 15% to active users, and 10% to community supporters. Each constituency votes within their class; the final outcome blends all voices according to their designated weight.

The result is governance that mirrors the actual social contract of an organization—who it belongs to, who it serves, and who sustains it. For the first time, the people who build, use, and believe in something can all own it together, with influence proportional to their stake in its success.

---

## Core Concepts

### Voting Classes: Giving Every Voice Its Weight

At the heart of HybridVoting is the **class system**. Each class represents a distinct stakeholder group with its own voting strategy:

```solidity
struct ClassConfig {
    ClassStrategy strategy;   // How voting power is calculated
    uint8 slicePct;           // Percentage of total voting weight (1-100)
    bool quadratic;           // Reduce whale dominance (for token strategies)
    uint256 minBalance;       // Minimum stake required
    address asset;            // Token address (for ERC20 strategies)
    uint256[] hatIds;         // Required role(s) to participate
}
```

**Example: A Worker Cooperative**

Imagine a cooperative where workers, investors, and the broader community all have a stake:

| Class | Strategy | Slice | Purpose |
|-------|----------|-------|---------|
| Workers | DIRECT | 50% | Those who labor should have the strongest voice |
| Token Holders | ERC20_BAL (quadratic) | 35% | Investors and contributors earn influence |
| Community | DIRECT | 15% | Users and supporters shape the direction |

All slices must sum to 100%. This creates a balanced governance where no single group can dominate.

---

### Voting Strategies

#### DIRECT: One Person, One Vote

The democratic foundation. Every eligible voter gets equal power (100 raw points) regardless of wealth or tenure.

```solidity
if (cls.strategy == HybridVoting.ClassStrategy.DIRECT) {
    return 100; // Direct democracy: 1 person = 100 raw points
}
```

**When to use DIRECT:**
- Core team decisions where experience matters more than stake
- Community sentiment checks
- Constitutional changes requiring broad consensus

#### ERC20_BAL: Token-Weighted Voting

Voting power scales with token holdings. This rewards contribution (via ParticipationTokens earned through work) while optionally applying quadratic dampening.

```solidity
if (cls.strategy == HybridVoting.ClassStrategy.ERC20_BAL) {
    uint256 balance = IERC20(cls.asset).balanceOf(voter);
    if (balance < cls.minBalance) return 0;
    uint256 power = cls.quadratic ? VotingMath.sqrt(balance) : balance;
    return power * 100;
}
```

**Linear vs Quadratic:**

| Tokens | Linear Power | Quadratic Power (sqrt) |
|--------|--------------|------------------------|
| 100 | 100 | 10 |
| 10,000 | 10,000 | 100 |
| 1,000,000 | 1,000,000 | 1,000 |

Quadratic voting means a whale with 1,000,000 tokens has 100x the power of someone with 100 tokens (not 10,000x). This preserves the signal that more stake = more voice, while preventing plutocratic capture.

---

### Hats: Role-Based Permissions

HybridVoting integrates with **Hats Protocol** for nuanced role management. Each class can require voters to wear specific "hats" (roles):

```solidity
hatIds: [EXECUTIVE_HAT_ID]  // Only executives can vote in this class
hatIds: []                   // No hat required - open to all
```

**Example: Graduated Permissions**

```
Hat ID 1: "Member" - Can vote in community polls
Hat ID 2: "Contributor" - Earned tokens grant voting power
Hat ID 3: "Core Team" - Strategic decisions require this hat
```

A single voter can participate in multiple classes if they hold the required hats. Alice the founding developer might vote as:
- A Core Team member (30% slice, DIRECT)
- A token holder (50% slice, ERC20_BAL with her earned ParticipationTokens)
- A community member (20% slice, DIRECT)

Her influence spans all relevant constituencies.

---

## Proposal Lifecycle

### 1. Creation

Only authorized creators (those wearing a creator hat, or the Executor) can create proposals:

```solidity
function createProposal(
    bytes calldata title,
    bytes32 descriptionHash,
    uint32 minutesDuration,    // 10 min - 30 days
    uint8 numOptions,          // Up to 50 options
    IExecutor.Call[][] calldata batches,  // On-chain actions per option
    uint256[] calldata hatIds  // Optional: restrict to specific roles
) external onlyCreator whenNotPaused
```

**Key Feature: Class Snapshots**

When a proposal is created, the current class configuration is **frozen into the proposal**:

```solidity
function _snapshotClasses(Proposal storage p, Layout storage l) internal {
    for (uint256 i; i < l.classes.length;) {
        p.classesSnapshot.push(l.classes[i]);
        // ...
    }
}
```

This means governance changes mid-vote don't retroactively alter existing proposals. If the DAO votes to shift from 50/50 to 60/40 split, proposals created before that change retain their original 50/50 structure.

### 2. Voting

Voters distribute their power across options using a weighted ballot:

```solidity
function vote(uint256 id, uint8[] calldata idxs, uint8[] calldata weights) external
```

**Example: Split Vote**

Alice wants to mostly support Option 0 but hedge toward Option 1:
```
idxs:    [0, 1]
weights: [70, 30]  // 70% to Option 0, 30% to Option 1
```

Her voting power in each class is allocated proportionally. If she has 100 raw points in DIRECT and 50 raw points in ERC20_BAL:
- Option 0 gets: (100 * 70%) = 70 DIRECT + (50 * 70%) = 35 token
- Option 1 gets: (100 * 30%) = 30 DIRECT + (50 * 30%) = 15 token

**Weights must sum to 100%.**

### 3. Winner Determination

After the voting period ends, anyone can call `announceWinner`:

```solidity
function announceWinner(uint256 id) external returns (uint256 winner, bool valid)
```

The algorithm:

1. **Calculate each option's score across all classes:**
   ```solidity
   for (uint256 cls; cls < numClasses; ++cls) {
       if (totalsRaw[cls] > 0) {
           uint256 classContribution = (perOptionPerClassRaw[opt][cls] * slices[cls]) / totalsRaw[cls];
           score += classContribution;
       }
   }
   ```

2. **Normalize within each class:** If 1000 raw points voted in the "Worker" class and Option A got 600, Option A claims 60% of the Worker slice.

3. **Weight by slice percentage:** That 60% is multiplied by the class slice (e.g., 50%) giving 30% of total governance power.

4. **Sum across classes:** Each option's final score is the sum of its weighted contributions from all classes.

5. **Apply quorum and margin:**
   - Winner's score must meet the quorum percentage
   - Winner must strictly exceed second place (no ties)

### 4. Execution

If the winning option has associated on-chain actions (`batches`), they're executed through the Executor:

```solidity
if (valid && batch.length > 0) {
    l.executor.execute(id, batch);
}
```

The Executor enforces:
- Target must be on the allowlist
- Maximum 20 calls per batch
- Cannot call itself (no recursion attacks)

---

## Real-World Scenarios

### Scenario 1: The Daily Operations Vote

**Setup:** A small cooperative runs weekly resource allocation votes.

```solidity
// Class configuration
classes[0] = ClassConfig({
    strategy: DIRECT,
    slicePct: 100,     // Workers decide everything
    hatIds: [MEMBER_HAT]
});
```

Every member gets equal say. No tokens, no wealth-weighting. Pure democracy for operational decisions.

### Scenario 2: Treasury Allocation

**Setup:** Deciding how to allocate a $100K grant across projects.

```solidity
classes[0] = ClassConfig({
    strategy: DIRECT,
    slicePct: 40,
    hatIds: [CORE_TEAM_HAT]  // Core team has strong input
});

classes[1] = ClassConfig({
    strategy: ERC20_BAL,
    slicePct: 40,
    quadratic: true,          // Dampen whale influence
    minBalance: 100 ether,
    asset: participationToken,
    hatIds: []                // Anyone with tokens
});

classes[2] = ClassConfig({
    strategy: DIRECT,
    slicePct: 20,
    hatIds: [COMMUNITY_HAT]   // Users have a voice
});
```

Core team expertise guides the decision (40%), but token holders who've earned through contribution have significant input (40%), and the community can steer toward user-friendly options (20%).

### Scenario 3: Constitutional Change

**Setup:** Changing the organization's fundamental rules.

```solidity
classes[0] = ClassConfig({
    strategy: DIRECT,
    slicePct: 50,
    hatIds: []  // All members vote equally
});

classes[1] = ClassConfig({
    strategy: ERC20_BAL,
    slicePct: 50,
    quadratic: true,
    minBalance: 1 ether,
    asset: participationToken,
    hatIds: []
});

// Plus: 75% quorum requirement
quorumPct: 75
```

Major changes require both broad democratic support AND buy-in from contributors. Neither group can impose on the other.

### Scenario 4: Restricted Technical Decision

**Setup:** Only developers should vote on code architecture.

```solidity
uint256[] memory hatIds = [DEVELOPER_HAT];

// When creating proposal:
createProposal(
    "Database Migration Strategy",
    descHash,
    1440,  // 24 hours
    3,     // Three technical options
    batches,
    hatIds  // RESTRICTED: only developers can vote
);
```

The `restricted` flag + `pollHatIds` ensure only qualified voices participate.

---

## Technical Deep Dive

### Storage Architecture (ERC-7201)

HybridVoting uses namespaced storage to prevent upgrade collisions:

```solidity
/// @custom:storage-location erc7201:poa.hybridvoting.v2.storage
struct Layout {
    IHats hats;
    IExecutor executor;
    mapping(address => bool) allowedTarget;
    uint256[] creatorHatIds;
    uint8 quorumPct;
    ClassConfig[] classes;
    Proposal[] _proposals;
    bool _paused;
    uint256 _lock;
}

bytes32 private constant _STORAGE_SLOT = 0x7a3e8e3d...;
```

This pattern enables safe upgrades while maintaining full state.

### Vote Power Calculation

The core algorithm in `HybridVotingCore._calculateClassPower`:

```solidity
function _calculateClassPower(address voter, ClassConfig memory cls, Layout storage l)
    internal view returns (uint256)
{
    // 1. Check hat gating
    bool hasClassHat = (voter == address(l.executor)) || (cls.hatIds.length == 0);
    if (!hasClassHat && cls.hatIds.length > 0) {
        for (uint256 i; i < cls.hatIds.length;) {
            if (l.hats.isWearerOfHat(voter, cls.hatIds[i])) {
                hasClassHat = true;
                break;
            }
        }
    }
    if (!hasClassHat) return 0;

    // 2. Apply strategy
    if (cls.strategy == DIRECT) {
        return 100;
    } else if (cls.strategy == ERC20_BAL) {
        uint256 balance = IERC20(cls.asset).balanceOf(voter);
        if (balance < cls.minBalance) return 0;
        return (cls.quadratic ? sqrt(balance) : balance) * 100;
    }
    return 0;
}
```

### N-Class Winner Selection

The `VotingMath.pickWinnerNSlices` function handles arbitrarily many classes:

```solidity
function pickWinnerNSlices(
    uint256[][] memory perOptionPerClassRaw,
    uint256[] memory totalsRaw,
    uint8[] memory slices,
    uint8 quorumPct,
    bool strict
) internal pure returns (uint256 win, bool ok, uint256 hi, uint256 second) {
    for (uint256 opt; opt < numOptions; ++opt) {
        uint256 score;
        for (uint256 cls; cls < numClasses; ++cls) {
            if (totalsRaw[cls] > 0) {
                // Proportional share of this class's slice
                uint256 classContribution =
                    (perOptionPerClassRaw[opt][cls] * slices[cls]) / totalsRaw[cls];
                score += classContribution;
            }
        }
        // Track winner and runner-up
        if (score > hi) {
            second = hi;
            hi = score;
            win = opt;
        } else if (score > second) {
            second = score;
        }
    }

    // Validate quorum and margin
    bool quorumMet = hi >= quorumPct;
    bool meetsMargin = strict ? (hi > second) : (hi >= second);
    ok = quorumMet && meetsMargin;
}
```

---

## Integration with POA Ecosystem

### ParticipationToken

The `ERC20_BAL` strategy typically uses **ParticipationTokens** as the voting asset. These tokens are:

- **Non-transferable:** You can't buy influence; you earn it
- **Minted by TaskManager:** Completing approved work grants tokens
- **Minted by EducationHub:** Learning and growing earns recognition
- **Self-delegating:** Votes automatically count for the holder

This creates a virtuous cycle: contribute work, earn tokens, gain voting power, shape what work gets funded.

### Executor

All governance actions flow through the Executor contract:

1. HybridVoting determines the winning option
2. If that option has associated calls, Executor processes them
3. Executor validates targets against an allowlist
4. Successful execution emits events for indexing

This separation ensures the voting logic remains pure while the Executor handles the messy reality of on-chain actions.

### Hats Protocol

HybridVoting leans heavily on Hats for access control:

- **Creator Hats:** Who can propose new votes
- **Class Hats:** Who can vote in each class
- **Poll Hats:** Optional per-proposal restrictions

Hats enables dynamic, attestation-based roles without redeploying contracts.

---

## Security Considerations

### Protections Built In

1. **Snapshot Isolation:** Class configs frozen at proposal creation
2. **Target Allowlisting:** Only pre-approved contracts can be called
3. **Reentrancy Guard:** Vote accumulation is protected
4. **Pausability:** Emergency brake via Executor
5. **Quorum + Margin:** Prevents low-turnout hijacking

### Attack Mitigations

| Attack Vector | Mitigation |
|--------------|------------|
| Flash loan voting | ParticipationTokens are non-transferable |
| Governance capture | Multi-class structure distributes power |
| Whale dominance | Quadratic voting dampens large holders |
| Empty proposal spam | Creator hat requirement |
| Mid-vote manipulation | Class configuration snapshots |
| Zero-weight Sybils | A voter with no power in any class is rejected (`Unauthorized`) — cannot pad turnout/quorum |

### ERC20_BAL weight is read **live** — safe-configuration requirements

⚠️ **Important nuance.** "Snapshot Isolation" above freezes the *class configuration* (strategy, slice, asset, hat gating) at proposal creation — it does **not** snapshot token *balances*. An `ERC20_BAL` class reads `IERC20(asset).balanceOf(voter)` at the moment `vote()` is called, not a `getPastVotes` checkpoint. This is intentional and safe **only when the org is configured as follows**:

1. **Use the soulbound ParticipationToken as the `ERC20_BAL` asset.** PT's `transfer`/`transferFrom`/`approve`/`delegate` all revert, so the classic *transfer-and-revote* / flash-loan inflation is structurally impossible — the same tokens cannot be moved between addresses to be counted twice within one proposal.
2. **Keep PT mint authority narrow.** Because weight is live, anyone who can mint PT mid-proposal can raise their own vote weight. Mint is gated to the TaskManager / EducationHub / approvers, and an approver **cannot self-approve** their own token request. Do **not** grant broad project `SELF_REVIEW` (which lets a contributor self-complete tasks and mint themselves PT) to members you would not trust to inflate a vote. Use designated project leads and fixed project budgets.

🚫 **Do not** configure an `ERC20_BAL` class over a freely **transferable** ERC20 unless that token is checkpoint-based and you have added an explicit `getPastVotes` snapshot — with a plain transferable token, live `balanceOf` allows transfer-and-revote across colluding hat-wearers.

These boundaries are proven by `test/HybridVotingSafeConfig.t.sol`: soulbound transfers revert, unprivileged actors cannot self-mint, a decided outcome cannot be flipped without mint authority, and a 128k-call fuzzing invariant shows unprivileged voting/transfer/mint activity never changes PT supply or voter balances. The same file's `test_Boundary_MintAuthorityIsTheLever` demonstrates, executably, the inflation that an *unsafe* config (broad mint authority) would expose.

---

## Configuration Limits

| Constant | Value | Purpose |
|----------|-------|---------|
| MAX_OPTIONS | 50 | Ballot choice limit |
| MAX_CALLS | 20 | Execution batch size |
| MAX_CLASSES | 8 | Voting constituency limit |
| MAX_DURATION | 43,200 min | 30 day voting window |
| MIN_DURATION | 1 min | Testing floor |

---

## Events for Off-Chain Indexing

```solidity
event NewProposal(uint256 id, bytes title, bytes32 descriptionHash, uint8 numOptions, uint64 endTs, uint64 created);
event NewHatProposal(uint256 id, bytes title, bytes32 descriptionHash, uint8 numOptions, uint64 endTs, uint64 created, uint256[] hatIds);
event VoteCast(uint256 indexed id, address indexed voter, uint8[] idxs, uint8[] weights, uint256[] classRawPowers, uint64 timestamp);
event Winner(uint256 indexed id, uint256 indexed winningIdx, bool valid, bool executed, uint64 timestamp);
event ProposalExecuted(uint256 indexed id, uint256 indexed winningIdx, uint256 numCalls);
event ClassesReplaced(uint256 indexed version, bytes32 indexed classesHash, ClassConfig[] classes, uint64 timestamp);
```

---

## The Vision: Ownership That Scales

HybridVoting exists because we believe governance should reflect how communities actually function. Not as atomized token holders, but as interconnected stakeholders with overlapping interests.

A worker who builds the product *and* holds earned tokens *and* uses what they build deserves to vote in all three capacities. Their voice carries across classes, weighted by their actual relationship with the organization.

This is governance designed for **perpetual organizations**—entities that outlive their founders, evolve with their communities, and remain accountable to everyone who contributes to their mission.

Build together. Own together. Govern together.

---

*HybridVoting is part of the Perpetual Organization Architecture (POA) smart contract system.*
