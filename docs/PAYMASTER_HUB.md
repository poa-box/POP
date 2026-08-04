# PaymasterHub Documentation

**Version:** 1.0
**Author:** POA Engineering Team
**License:** MIT

---

## Table of Contents

1. [What is PaymasterHub?](#what-is-paymasterhub)
2. [Core Features Overview](#core-features-overview)
3. [Feature Details](#feature-details)
   - [Multi-Tenant Architecture](#multi-tenant-architecture)
   - [Solidarity Fund System](#solidarity-fund-system)
   - [Rules Engine](#rules-engine)
   - [Budget System](#budget-system)
   - [Fee & Gas Caps](#fee--gas-caps)
   - [Bundler Bounties](#bundler-bounties)
   - [Access Control](#access-control)
4. [How Features Work (With Examples)](#how-features-work-with-examples)
5. [Technical Overview](#technical-overview)

---

## What is PaymasterHub?

**PaymasterHub is a shared gas sponsorship system for worker cooperatives** built on ERC-4337 Account Abstraction. It solves a critical infrastructure problem: deploying a separate paymaster contract for each organization costs ~$500 on mainnet (~40M gas), making it prohibitively expensive for small cooperatives.

### The Problem

Traditional ERC-4337 paymasters are **single-tenant** - each organization needs its own contract:
- ❌ **Expensive deployment:** $500 per org on mainnet
- ❌ **No shared resources:** Each org siloed
- ❌ **No mutual aid:** Organizations can't help each other

### The Solution

PaymasterHub is **multi-tenant** - unlimited organizations share one contract:
- ✅ **99.8% cost reduction:** Deploy once, use forever
- ✅ **Shared solidarity fund:** 1% automatic contribution → redistributed progressively
- ✅ **Protocol-level cooperation:** Small orgs get most support automatically

### What It Does

1. **Sponsors gas costs** for any user operation (transaction) from organizations registered with the hub
2. **Validates transactions** against configurable rules (which contracts/functions are allowed)
3. **Enforces budgets** per user, per role, or per organization over time periods
4. **Collects 1% fees** into a solidarity fund that redistributes to organizations based on need
5. **Incentivizes bundlers** with optional bounties for fast transaction inclusion

---

## Core Features Overview

### 1. **Multi-Tenant Architecture**
Unlimited organizations share one PaymasterHub contract. Each org has isolated configuration, rules, budgets, and financial tracking. No cross-contamination.

### 2. **Solidarity Fund System**
- **Grace Period:** New co-ops get 0.01 ETH (~$30) free gas for 90 days with zero deposits
- **Progressive Tiers:** Small deposits get best match rates (2x), large orgs self-fund
- **Automatic Contribution:** 1% of all gas spending goes to solidarity fund
- **50/50 Payment Split:** Every transaction splits costs between org's deposits and solidarity

### 3. **Rules Engine**
Per-organization whitelist/blacklist of which smart contracts and functions users can call. Three validation modes:
- **Generic:** For accounts that execute nested calls (most common)
- **Executor:** For the organization's executor contract itself
- **Coarse:** Account-level only, skip function validation

### 4. **Budget System**
Time-based spending limits with automatic epoch rolling:
- **Per-Account budgets:** Limit individual user spending
- **Per-Role budgets:** Limit spending for all users with a Hats Protocol role
- **Per-Org budgets:** Global organization-wide caps

### 5. **Fee & Gas Caps**
Protect against gas price spikes and expensive operations:
- Max fee per gas (base fee)
- Max priority fee per gas (tip)
- Max call gas, verification gas, pre-verification gas

### 6. **Bundler Bounties**
Optional rewards to incentivize fast transaction inclusion:
- Pay bundlers a % of gas cost or fixed amount (whichever is lower)
- Org-specific configuration
- Funded separately from main paymaster deposits

### 7. **Access Control**
Hats Protocol integration for decentralized governance:
- **Admin Hat:** Full control (pause, rules, budgets, fee caps, bounties)
- **Operator Hat:** Delegated management (rules, budgets, fee caps only)
- **PoaManager:** Protocol-level governance (upgrades, grace period, bans)

---

## Feature Details

### Multi-Tenant Architecture

#### How It Works

Each organization is identified by a unique `bytes32 orgId` (typically `keccak256(abi.encodePacked(orgName))`). All configuration and state is scoped to this ID using **ERC-7201 namespaced storage**:

```solidity
// Each org has isolated storage
mapping(bytes32 orgId => OrgConfig) private _orgs;
mapping(bytes32 orgId => OrgFinancials) private _financials;
mapping(bytes32 orgId => mapping(address => mapping(bytes4 => Rule))) private _rules;
mapping(bytes32 orgId => mapping(bytes32 => Budget)) private _budgets;
```

#### Storage Isolation

**What gets isolated per org:**
- Configuration (admin hat, operator hat, pause state, registration time)
- Financial tracking (deposits, spending, solidarity usage)
- Rules (which contracts/functions are allowed)
- Budgets (spending limits per user/role/org)
- Fee caps (gas price limits)

**What is shared globally:**
- Solidarity fund balance
- Grace period configuration (days, spending limit, minimum deposit)
- Entry point, Hats Protocol, PoaManager addresses

#### Benefits

- ✅ **Cost:** Deploy once ($500), add unlimited orgs ($8 each)
- ✅ **Security:** Orgs cannot access each other's funds or configuration
- ✅ **Upgradeability:** One upgrade applies to all organizations
- ✅ **Solidarity:** Shared pool enables mutual aid at scale

---

### Solidarity Fund System

The solidarity fund is **automatic mutual aid at the protocol level**. Every transaction contributes 1% of its gas cost to a shared pool, which is then redistributed to organizations based on need using a progressive tier system.

#### Components

**1. Grace Period (First 90 Days)**
- **Free gas:** 0.01 ETH (~$30 value) with zero deposits required
- **Purpose:** Bootstrap new cooperatives, prove legitimacy
- **Limit:** Spending-only (no transaction counting)
- **Example:** On Base L2 with $0.01 per tx, 0.01 ETH = ~3000 transactions

**2. Progressive Tier System (After Grace)**

Organizations are assigned to tiers based on their **current deposit balance**:

| Tier | Deposit | Match Allowance | Total Budget (90 days) | Target Orgs |
|------|---------|-----------------|------------------------|-------------|
| **1** | 0.003 ETH (~$10) | 0.006 ETH (2x) | 0.009 ETH (~$30) | Micro co-ops |
| **2** | 0.006 ETH (~$20) | 0.009 ETH (1.5x avg) | 0.015 ETH (~$50) | Small co-ops |
| **3** | 0.017+ ETH (~$50+) | 0 (no match) | Deposits only | Large/profitable co-ops |

**Match Calculation Logic:**
```solidity
// Tier 1: 1x deposit → 2x match
if (deposited <= minDeposit) {
    return deposited * 2; // 0.003 ETH → 0.006 ETH match
}

// Tier 2: First 1x at 2x, second 1x at 1x
if (deposited <= minDeposit * 2) {
    return (minDeposit * 2) + (deposited - minDeposit);
    // 0.006 ETH → 0.006 + 0.003 = 0.009 ETH match
}

// Tier 3: Self-sufficient, no match
return 0;
```

**3. 50/50 Payment Split**

Every transaction tries to split costs evenly between the org's deposits and solidarity:

```
During Grace (Day 0-90):
  fromSolidarity = 100% of gas cost
  fromDeposits = 0%

After Grace (Day 91+):
  halfCost = actualGasCost / 2

  // Try 50/50 split
  fromDeposits = min(halfCost, depositAvailable)
  fromSolidarity = min(halfCost, solidarityRemaining)

  // If one pool is short, use the other
  if (fromDeposits + fromSolidarity < actualGasCost) {
      Try deposits first, then solidarity
  }
```

**Why 50/50?**
- ✅ Immediate benefit even if you don't exhaust deposits
- ✅ Prevents gaming (can't hoard deposits to maximize solidarity)
- ✅ Fair to all participants

**4. 90-Day Periods with Dual Reset**

Solidarity allowances reset when:
- **Time-based:** 90 days elapse since period start, OR
- **Deposit-based:** Deposit balance crosses minimum threshold from below

This creates a natural commitment mechanism without per-transaction overhead.

**5. Automatic Fee Collection**

Every transaction automatically collects **1% solidarity fee**:

```solidity
solidarityFee = (actualGasCost * 100) / 10000; // 1%

// Update org spending
org.spent += fromDeposits;
org.solidarityUsedThisPeriod += fromSolidarity;

// Update solidarity fund
solidarity.balance -= fromSolidarity; // Paid out
solidarity.balance += solidarityFee;  // Collected
```

#### Deposit & Donation Functions

**Anyone can support any organization:**

```solidity
// Support specific org (anyone can deposit)
hub.depositForOrg{value: 0.01 ether}(orgId);

// Donate to solidarity pool directly
hub.donateToSolidarity{value: 1 ether}();
```

Deposits increment:
- `org.deposited` (current balance)
- `org.totalDeposited` (lifetime cumulative, never decreases)
- `solidarity.numActiveOrgs` (if first deposit)

#### Ban Mechanism

PoaManager can ban malicious actors from solidarity access:

```solidity
// Ban org from solidarity (they can still use own deposits)
hub.setBanFromSolidarity(orgId, true);

// Unban
hub.setBanFromSolidarity(orgId, false);
```

Banned orgs:
- ✅ Can still deposit and use own funds
- ❌ Cannot access solidarity during grace period
- ❌ Cannot receive solidarity match after grace
- ✅ Still contribute 1% fee (become net contributors)

#### Configuration (PoaManager Only)

```solidity
// Adjust grace period parameters
hub.setGracePeriodConfig(
    90,              // initialGraceDays
    0.01 ether,      // maxSpendDuringGrace
    0.003 ether      // minDepositRequired
);

// Adjust solidarity fee (1% default, max 10%)
hub.setSolidarityFee(100); // basis points (100 = 1%)
```

---

### Rules Engine

The rules engine validates **which smart contracts and functions** users can call. Resolution has two tiers: each org's **local rules** (address-keyed, org-managed) and the protocol-wide **global rulebook** (type-keyed, Poa-managed). All rule logic lives in `PaymasterRuleLib`, a delegatecall library operating on the hub's own storage (EIP-170 headroom + ERC-7562-safe validation).

#### Rule Structure

```solidity
struct Rule {
    uint32 maxCallGasHint;  // Optional gas limit hint (field order matters for decoders!)
    bool allowed;           // Is this target/selector allowed?
}

// Local rules:  orgId → target address → selector → Rule   (poa.paymasterhub.rules)
// Global rules: module typeId → selector → Rule             (poa.paymasterhub.globalrules)
```

#### Global Rulebook (type-keyed, Poa-managed)

Local rules are keyed by each org's own proxy addresses, so a new protocol function used to require a vote in *every* org (or a `adminBatchAddRules` fan-out enumerating them all) plus an OrgDeployer redeploy. The global rulebook removes that burden — it is the `SwitchableBeacon` analog for sponsorship rules:

- Entries are keyed by `(module typeId, selector)` where typeId = `keccak256(moduleName)` — the same IDs `OrgRegistry`/`ModuleTypes` use. One entry covers the matching module of **every** org.
- Each org maps its proxy addresses to typeIds (`setTargetTypesBatch`, seeded automatically by OrgDeployer at deploy). Resolution is inert for an org until its targets are mapped.
- Per-org **rules mode** (`setRulesMode`): `0 = Mirror` (default) — local rules first, then global rulebook; `1 = Static` — local rules only, the org votes changes in exactly like a pinned beacon upgrade.
- Mirror orgs can veto one specific global rule without leaving Mirror mode: `setGlobalRuleBlock(orgId, target, selector, true)`.
- The rulebook is enumerable on-chain (`getGlobalRuleCount` / `getGlobalRuleAt`), which powers `snapshotGlobalRules`.

Resolution order (fail-closed at every step):

```text
local rule allowed?            → allow (local maxCallGasHint applies)
org rules mode == Static?      → deny
org blocked (target,selector)? → deny
targetTypes[org][target] == 0? → deny
global rule allowed?           → allow (global maxCallGasHint applies)
else                           → deny (RuleDenied)
```

**Managing the rulebook (poaManager or protocolAdmin):**

```solidity
// Upsert entries (allowed=true) or remove them (allowed=false)
hub.setGlobalRulesBatch(typeIds, selectors, allowed, maxCallGasHints);
```

The canonical seed set lives in `script/helpers/DefaultGlobalRules.sol`. To sponsor a new function protocol-wide: add it there, broadcast one `setGlobalRulesBatch` per chain — every Mirror org picks it up instantly, and no OrgDeployer redeploy is needed. Removing an entry is the central kill-switch: sponsorship stops immediately for all Mirror orgs.

**Org-side controls (admin/operator hat, or PoaManager):**

```solidity
hub.setTargetTypesBatch(orgId, targets, typeIds);      // map/clear module typeIds
hub.setRulesMode(orgId, mode);                         // 0 = Mirror, 1 = Static
hub.setGlobalRuleBlock(orgId, target, selector, bool); // veto one global rule
hub.adoptGlobalRules(orgId, targets, selectors);       // copy specific entries → local rules
hub.snapshotGlobalRules(orgId, targets);               // copy ALL applicable entries → local rules
```

A Static-leaning org should pass `snapshotGlobalRules` + `setRulesMode(orgId, 1)` in one governance batch — sponsorship continues from the local copies and later rulebook changes no longer apply. OrgDeployer does this automatically for orgs deployed with `autoUpgrade = false`; Mirror orgs get only target-type mappings (zero local rules) and resolve everything through the rulebook.

Trust note: this adds **no new Poa power** — PoaManager could already write any org's local rules via the `onlyOrgOperator` bypass (and `adminBatchAddRules`). The rulebook just makes that administration transparent (evented, enumerable) and instantly revocable, while Static mode / blocks give orgs an explicit opt-out.

#### Validation Modes

**1. Generic Mode (RULE_ID = 0x00000000)**

For accounts that execute **nested calls** (e.g., SimpleAccount calling `execute(target, data)`): the inner `(target, selector)` is extracted from calldata, and `executeBatch` variants are validated **per inner call** (every inner pair must resolve allowed; gas hints are not checked per-inner-call).

**2. Coarse Mode (RULE_ID = 0x000000FF)**

Checks `(userOp.sender, outer selector)` — account-level rules. Note the account itself has no target-type mapping, so coarse mode resolves through local rules only.

#### Setting Local Rules

```solidity
// Allow (clears any standing global-rule block for the pair)
hub.setRule(orgId, target, selector, true, 500000);

// EXPLICIT DENY — actually revokes for Mirror orgs: writes the local deny AND blocks the
// global fallback (without the block, allowed=false would silently fall through to the rulebook)
hub.setRule(orgId, target, selector, false, 0);

// Batch rules (same allow/deny semantics per entry)
hub.setRulesBatch(orgId, targets, selectors, allowedFlags, gasHints);

// RESET to protocol default: deletes the local rule AND any standing block — a Mirror org
// falls back to the global rulebook for this pair afterwards
hub.clearRule(orgId, target, selector);
```

**Access:** Admin or Operator hat (or PoaManager)

Legacy note: the hub also keeps the pre-rulebook 13-field `registerAndConfigureOrg` overload (selector `0xc6f422d9`) so already-deployed OrgDeployer versions keep working across the v20 upgrade — they seed address-keyed local rules exactly as before.

#### Reading effective rules

`PaymasterHubLens.effectiveRuleOf(orgId, target, selector)` returns `(allowed, maxCallGasHint, source)` with `source`: 0 = denied, 1 = local rule, 2 = global rulebook. `lens.wouldValidate` predicts the full validation including global resolution. `hub.getRule` returns the LOCAL rule only.

---

### Budget System

Time-based spending limits with automatic **epoch rolling**. Budgets can be per-account, per-role (Hats Protocol), or per-org.

#### Budget Structure

```solidity
struct Budget {
    uint128 capPerEpoch;   // Maximum spending per epoch
    uint128 usedInEpoch;   // Current epoch usage
    uint32 epochLen;       // Epoch length in seconds
    uint32 epochStart;     // When current epoch started
}

// Storage: orgId → subjectKey → Budget
mapping(bytes32 => mapping(bytes32 => Budget)) private _budgets;
```

#### Subject Types

**1. Account Budget**
```solidity
// Key: keccak256(abi.encodePacked(uint8(0), bytes20(accountAddress)))
bytes32 key = keccak256(abi.encodePacked(uint8(0), bytes20(0x1234...)));
hub.setBudget(orgId, key, 0.1 ether, 7 days);
```

**2. Hat (Role) Budget**
```solidity
// Key: keccak256(abi.encodePacked(uint8(1), bytes20(hatId)))
bytes32 key = keccak256(abi.encodePacked(uint8(1), bytes20(uint160(hatId))));
hub.setBudget(orgId, key, 1 ether, 30 days);
```

**3. Org-Wide Budget**
```solidity
// Key: bytes32(0)
hub.setBudget(orgId, bytes32(0), 10 ether, 90 days);
```

#### Automatic Epoch Rolling

Budgets automatically roll to a new epoch when time elapses:

```solidity
function _checkBudget(bytes32 orgId, bytes32 subjectKey, uint256 maxCost) {
    Budget storage budget = _budgets[orgId][subjectKey];

    // Auto-roll if epoch has passed
    if (block.timestamp >= budget.epochStart + budget.epochLen) {
        budget.epochStart = uint32(block.timestamp);
        budget.usedInEpoch = 0;
    }

    // Check if transaction would exceed cap
    if (budget.usedInEpoch + maxCost > budget.capPerEpoch) {
        revert BudgetExceeded();
    }

    return budget.epochStart; // Used in postOp
}
```

After transaction succeeds, usage is updated:

```solidity
function _updateUsage(bytes32 orgId, bytes32 subjectKey, uint32 epochStart, uint256 actualGasCost) {
    Budget storage budget = _budgets[orgId][subjectKey];

    // Only update if we're still in the same epoch
    if (budget.epochStart == epochStart) {
        budget.usedInEpoch += uint128(actualGasCost);
        emit UsageIncreased(orgId, subjectKey, actualGasCost, budget.usedInEpoch, epochStart);
    }
}
```

#### Epoch Length Constraints

```solidity
MIN_EPOCH_LENGTH = 1 hour
MAX_EPOCH_LENGTH = 365 days
```

#### Setting Budgets

```solidity
// Set budget
hub.setBudget(
    orgId,
    subjectKey,
    0.1 ether,     // capPerEpoch
    7 days         // epochLen
);

// Manually reset epoch start
hub.setEpochStart(orgId, subjectKey, uint32(block.timestamp));
```

**Access:** Admin or Operator hat

---

### Fee & Gas Caps

Protect organizations from gas price spikes and expensive operations.

#### Fee Caps Structure

```solidity
struct FeeCaps {
    uint256 maxFeePerGas;           // Max base fee
    uint256 maxPriorityFeePerGas;   // Max priority fee (tip)
    uint32 maxCallGas;              // Max gas for main execution
    uint32 maxVerificationGas;      // Max gas for signature verification
    uint32 maxPreVerificationGas;   // Max gas for bundler overhead
}

// Storage: orgId → FeeCaps
mapping(bytes32 => FeeCaps) private _feeCaps;
```

#### Validation

During `validatePaymasterUserOp`, fees are checked:

```solidity
function _validateFeeCaps(PackedUserOperation calldata userOp, bytes32 orgId) {
    FeeCaps storage caps = _feeCaps[orgId];

    // Unpack fees from userOp.gasFees
    uint256 maxPriorityFeePerGas = uint128(userOp.gasFees);
    uint256 maxFeePerGas = uint128(userOp.gasFees >> 128);

    // Check base fee
    if (caps.maxFeePerGas != 0 && maxFeePerGas > caps.maxFeePerGas) {
        revert FeeTooHigh();
    }

    // Check priority fee
    if (caps.maxPriorityFeePerGas != 0 && maxPriorityFeePerGas > caps.maxPriorityFeePerGas) {
        revert FeeTooHigh();
    }

    // Unpack gas limits from userOp.accountGasLimits
    uint256 verificationGasLimit = uint128(userOp.accountGasLimits);
    uint256 callGasLimit = uint128(userOp.accountGasLimits >> 128);
    uint256 preVerificationGas = userOp.preVerificationGas;

    // Check gas limits
    if (caps.maxCallGas != 0 && callGasLimit > caps.maxCallGas) {
        revert GasTooHigh();
    }

    if (caps.maxVerificationGas != 0 && verificationGasLimit > caps.maxVerificationGas) {
        revert GasTooHigh();
    }

    if (caps.maxPreVerificationGas != 0 && preVerificationGas > caps.maxPreVerificationGas) {
        revert GasTooHigh();
    }
}
```

#### Setting Fee Caps

```solidity
hub.setFeeCaps(
    orgId,
    200 gwei,   // maxFeePerGas
    20 gwei,    // maxPriorityFeePerGas
    2000000,    // maxCallGas
    1000000,    // maxVerificationGas
    500000      // maxPreVerificationGas
);
```

**Zero value = no limit**

**Access:** Admin or Operator hat

---

### Access Control

PaymasterHub uses **Hats Protocol** for decentralized, role-based access control. Each organization has two hats:

#### 1. Admin Hat (Required)

**Who:** Typically the organization's top hat (hat tree root)

**Permissions:**
- ✅ All Operator permissions (below)
- ✅ Pause/unpause paymaster
- ✅ Set operator hat (delegate management)
- ✅ Configure bounties

**Examples:**
- Emergency pause during security incident
- Delegate day-to-day management to treasurer
- Enable bundler bounties for fast inclusion

#### 2. Operator Hat (Optional)

**Who:** Delegated role (e.g., treasurer, operations manager)

**Permissions:**
- ✅ Set rules (whitelist contracts/functions)
- ✅ Set budgets (spending limits)
- ✅ Set fee caps (gas price protection)
- ✅ Deposit to EntryPoint (fund paymaster)

**Cannot:**
- ❌ Pause paymaster
- ❌ Change admin/operator hats
- ❌ Configure bounties

**Examples:**
- Treasurer manages budgets and deposits
- Operations manager whitelists new contracts
- Security team adjusts fee caps

#### 3. PoaManager (Protocol Governance)

**Who:** Protocol-level governance (not org-specific)

**Permissions:**
- ✅ Upgrade PaymasterHub implementation (UUPS)
- ✅ Set grace period config (days, spending limit, min deposit)
- ✅ Ban orgs from solidarity (anti-fraud)
- ✅ Adjust solidarity fee percentage (1% default, max 10%)

**Cannot:**
- ❌ Access org-specific configuration
- ❌ Withdraw org deposits
- ❌ Override org rules/budgets

#### Modifier Implementation

```solidity
modifier onlyOrgAdmin(bytes32 orgId) {
    OrgConfig storage org = _orgs[orgId];
    if (org.adminHatId == 0) revert OrgNotRegistered();
    if (!IHats(hats).isWearerOfHat(msg.sender, org.adminHatId)) {
        revert NotAdmin();
    }
    _;
}

modifier onlyOrgOperator(bytes32 orgId) {
    OrgConfig storage org = _orgs[orgId];
    if (org.adminHatId == 0) revert OrgNotRegistered();

    bool isAdmin = IHats(hats).isWearerOfHat(msg.sender, org.adminHatId);
    bool isOperator = org.operatorHatId != 0 &&
                      IHats(hats).isWearerOfHat(msg.sender, org.operatorHatId);

    if (!isAdmin && !isOperator) revert NotOperator();
    _;
}
```

#### Setting Operator Hat

```solidity
// Admin delegates management to treasurer hat
hub.setOperatorHat(orgId, treasurerHatId);

// Admin revokes delegation
hub.setOperatorHat(orgId, 0);
```

---

## How Features Work (With Examples)

### Example 1: Bootstrapping Food Co-op

**Scenario:** New food co-op on Base L2 with zero funds.

**Month 1-3 (Grace Period):**

1. **Register org:**
```solidity
hub.registerOrg(
    keccak256("FoodCoOp"),
    topHatId,
    treasurerHatId
);
```

2. **Set basic rules:**
```solidity
// Allow POS system contract
hub.setRule(orgId, posSystemAddress, 0x12345678, true, 300000);

// Allow USDC payments
hub.setRule(orgId, usdcAddress, 0xa9059cbb, true, 100000);
```

3. **Members use the system:**
- User operation: POS records sale → USDC transfer
- Gas cost: 0.01 ETH per transaction ($0.01 on Base)
- Payment: 100% from solidarity (grace period)
- Usage: ~250 transactions = 0.0025 ETH spent
- Remaining: 0.0075 ETH grace limit left

**Month 4 (Enter Tier 1):**

Grace period ends (90 days). Co-op deposits first funds:

```solidity
// Community member donates $10
hub.depositForOrg{value: 0.003 ether}(orgId);
```

Now in **Tier 1:**
- Deposit: 0.003 ETH
- Match allowance: 0.006 ETH (2x)
- Total budget: 0.009 ETH per 90 days

**Month 4-6 (First Period):**
- Spending: 0.0027 ETH over 3 months (~270 tx)
- Payment via 50/50:
  - From deposits: 0.001 ETH (exhausted)
  - From solidarity: 0.0017 ETH (used 0.0017 of 0.006 allowance)
- Fee contributed: ~0.000027 ETH (1%)

**Result:** $10 deposit enabled $27 in gas spending → $17 net benefit

---

### Example 2: Tech Co-op with Growing Userbase

**Scenario:** Worker-owned tech co-op on Arbitrum, 3 months old, 20 active users.

**Month 4 (Post-Grace):**

Treasurer deposits operating budget:

```solidity
hub.depositForOrg{value: 0.006 ether}(orgId);
```

Now in **Tier 2:**
- Deposit: 0.006 ETH (~$20)
- Match calculation:
  - First 0.003 at 2x = 0.006 ETH
  - Second 0.003 at 1x = 0.003 ETH
  - Total match: 0.009 ETH (~$30)
- Total budget: 0.015 ETH (~$50) per 90 days

**Set per-user budgets:**

```solidity
// Limit each developer to 0.01 ETH per week
for (uint256 i = 0; i < 20; i++) {
    bytes32 key = keccak256(abi.encodePacked(uint8(0), bytes20(userAccounts[i])));
    hub.setBudget(orgId, key, 0.01 ether, 7 days);
}
```

**Month 4-6 (First Period):**
- Spending: 0.0045 ETH over 3 months (~450 tx)
- Payment via 50/50:
  - From deposits: 0.002 ETH
  - From solidarity: 0.0025 ETH (used 0.0025 of 0.009 allowance)
- Fee contributed: ~0.000045 ETH (1%)

**Result:** $20 deposit enabled $45 in spending → $25 net benefit from solidarity

---

### Example 3: Established Co-op with Profitable Operations

**Scenario:** Successful worker co-op with 200 users, $300/month in gas costs.

**Month 4 (Post-Grace):**

Treasurer deposits operating budget:

```solidity
hub.depositForOrg{value: 0.05 ether}(orgId);
```

Now in **Tier 3:**
- Deposit: 0.05 ETH (~$150)
- Match allowance: 0 (self-sufficient threshold)
- Total budget: Deposits only

**Monthly spending:**
- Gas costs: ~0.1 ETH ($300)
- From deposits: 0.1 ETH (100%)
- From solidarity: 0 (no match)
- Fee contributed: ~0.001 ETH ($3)

**Result:** Net contributor to ecosystem ($36/year in fees) → Supports 3-4 Tier 1 orgs

---

### Example 4: Emergency Budget Controls

**Scenario:** Organization needs to limit spending during cash flow crunch.

**Set org-wide monthly cap:**

```solidity
// Limit entire org to 0.05 ETH per 30 days
hub.setBudget(
    orgId,
    bytes32(0),      // Org-wide budget (key = 0)
    0.05 ether,
    30 days
);
```

**Limit high-risk operations:**

```solidity
// Block expensive DeFi protocols
hub.setRule(orgId, uniswapRouterAddress, 0x414bf389, false, 0);
hub.setRule(orgId, aavePoolAddress, 0xabcdef00, false, 0);

// Set conservative gas caps
hub.setFeeCaps(
    orgId,
    50 gwei,    // maxFeePerGas (conservative)
    5 gwei,     // maxPriorityFeePerGas
    500000,     // maxCallGas
    300000,     // maxVerificationGas
    100000      // maxPreVerificationGas
);
```

**Pause if needed:**

```solidity
// Emergency pause (admin only)
hub.setPause(orgId, true);

// Resume when resolved
hub.setPause(orgId, false);
```

---

### Example 5: Delegated Management

**Scenario:** Admin delegates day-to-day management to treasurer.

**Set operator hat:**

```solidity
// Admin delegates to treasurer hat
hub.setOperatorHat(orgId, treasurerHatId);
```

**Now treasurer can:**
- ✅ Add/remove contract rules
- ✅ Adjust user/role budgets
- ✅ Update fee caps
- ✅ Deposit to EntryPoint

**But cannot:**
- ❌ Pause the paymaster
- ❌ Change admin/operator hats
- ❌ Configure bounties

**Revoke delegation:**

```solidity
// Admin revokes operator privileges
hub.setOperatorHat(orgId, 0);
```

---

## Technical Overview

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  PaymasterHub (Proxy)                    │
│  ┌──────────────────────────────────────────────────┐   │
│  │            ERC-7201 Namespaced Storage           │   │
│  │                                                  │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │   │
│  │  │ Org Alpha│  │ Org Beta │  │ Org Gamma│      │   │
│  │  │          │  │          │  │          │      │   │
│  │  │ Config   │  │ Config   │  │ Config   │      │   │
│  │  │ Rules    │  │ Rules    │  │ Rules    │      │   │
│  │  │ Budgets  │  │ Budgets  │  │ Budgets  │      │   │
│  │  │Financial │  │Financial │  │Financial │      │   │
│  │  └──────────┘  └──────────┘  └──────────┘      │   │
│  │                                                  │   │
│  │         ┌───────────────────────┐               │   │
│  │         │  Solidarity Fund      │               │   │
│  │         │  (Shared Pool)        │               │   │
│  │         │  - Balance            │               │   │
│  │         │  - Active Orgs        │               │   │
│  │         │  - Fee % (1%)         │               │   │
│  │         └───────────────────────┘               │   │
│  │                                                  │   │
│  │         ┌───────────────────────┐               │   │
│  │         │  Grace Period Config  │               │   │
│  │         │  - Days (90)          │               │   │
│  │         │  - Max Spend (0.01Ξ)  │               │   │
│  │         │  - Min Deposit (0.003Ξ)│              │   │
│  │         └───────────────────────┘               │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
          ┌────────────────────────┐
          │   EntryPoint v0.7      │
          │  (Canonical Singleton) │
          │   0x0000...da032       │
          └────────────────────────┘
```

### ERC-4337 Integration

PaymasterHub implements the **IPaymaster** interface from ERC-4337:

```solidity
interface IPaymaster {
    enum PostOpMode { opSucceeded, opReverted, postOpReverted }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external;
}
```

**Validation Flow:**

1. **User creates UserOp** with paymaster field:
```
paymasterAndData = PaymasterHub address (20 bytes)
                 + version (1 byte)
                 + orgId (32 bytes)
                 + subjectType (1 byte)
                 + subjectId (32 bytes)
                 + ruleId (4 bytes)
```

2. **EntryPoint calls `validatePaymasterUserOp`:**
   - Decode paymaster data
   - Check org is registered and not paused
   - Validate subject eligibility (user or hat)
   - Validate rules (target/selector whitelist)
   - Validate fee/gas caps
   - Check per-subject budget
   - Check org balance (deposits)
   - Check solidarity access (grace or tier)
   - Return context for postOp

3. **EntryPoint executes UserOp**

4. **EntryPoint calls `postOp`:**
   - Update per-subject budget usage
   - Update org financials (50/50 split)
   - Collect 1% solidarity fee

### Storage Layout (ERC-7201)

All storage uses **namespaced slots** to prevent collisions and enable safe upgrades:

```solidity
// Slot calculation: keccak256(abi.encode(uint256(keccak256("namespace")) - 1)) & ~bytes32(uint256(0xff))

MAIN_STORAGE_LOCATION           = 0x9a7a... // entryPoint, hats, poaManager
ORGS_STORAGE_LOCATION           = 0x7e8e... // orgId → OrgConfig
FINANCIALS_STORAGE_LOCATION     = 0x1234... // orgId → OrgFinancials
FEECAPS_STORAGE_LOCATION        = 0x31c1... // orgId → FeeCaps
RULES_STORAGE_LOCATION          = 0xbe22... // orgId → target → selector → Rule
BUDGETS_STORAGE_LOCATION        = 0xf14d... // orgId → subjectKey → Budget
SOLIDARITY_STORAGE_LOCATION     = 0xabcd... // SolidarityFund
GRACEPERIOD_STORAGE_LOCATION    = 0xfedc... // GracePeriodConfig
```

**Benefits:**
- ✅ No storage collisions between orgs
- ✅ Safe upgrades (can add new namespaced storage)
- ✅ Gas-efficient (no extra indirection)
- ✅ Clear separation of concerns

### UUPS Upgradeability

PaymasterHub uses **Universal Upgradeable Proxy Standard**:

```solidity
contract PaymasterHub is
    IPaymaster,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != _getMainStorage().poaManager) {
            revert NotPoaManager();
        }
    }
}
```

**Upgrade Process:**

1. PoaManager deploys new implementation
2. PoaManager calls `upgradeToAndCall()` on proxy
3. All orgs automatically use new logic
4. Storage preserved (ERC-7201 namespace protection)

**Only PoaManager can upgrade** - individual orgs cannot.

### Gas Costs

**Deployment:**
- Implementation: ~4M gas (~$500 on mainnet)
- Organization registration: ~65k gas (~$8)
- **Savings:** 99.8% vs traditional paymaster (~40M gas per org)

**Per-Transaction Overhead:**

| Component | Gas Cost | Notes |
|-----------|----------|-------|
| Budget check | ~600 | Includes epoch rolling |
| Rule validation | ~400 | Target/selector extraction |
| Solidarity checks | ~250 | Grace or tier validation |
| Financial updates (postOp) | ~10,300 | 2 SSTOREs + calculations |
| **Total** | **~11,550** | ~7% of typical 150k UserOp |

**Optimizations Applied:**
- Removed transaction counting (-2,900 gas)
- Removed unused lifetime solidarity tracking (-2,900 gas)
- Removed unused fees contributed tracking (-2,900 gas)
- Removed total fees collected tracking (-2,900 gas)
- **Total saved:** ~11,600 gas/tx (reduced from 19k to 10.3k)

### Security Considerations

**1. Reentrancy Protection**
```solidity
function postOp(...) external override onlyEntryPoint nonReentrant {
    // Protected from extraction attacks
}
```

**2. Financial Isolation**
- Each org has separate `OrgFinancials` struct
- Cannot spend other orgs' deposits
- Solidarity tracked separately per 90-day period

**3. Access Control**
- Hats Protocol role-based permissions
- Org admin cannot affect other orgs
- PoaManager cannot access org deposits
- Operator hat limits delegation scope

**4. Overflow Protection**
- Solidity 0.8+ built-in checks
- Safe casting with explicit checks
- Packed storage with bounded types

**5. Upgrade Safety**
- Only PoaManager can upgrade
- ERC-7201 namespaced storage prevents collisions
- Initializer protection prevents re-initialization

**6. Grace Period Abuse Prevention**
- Spending limit (0.01 ETH default)
- Ban mechanism for malicious actors
- Off-chain monitoring + on-chain enforcement

### Contract Size

**Current:** ~25 KB compiled bytecode
**Limit:** 24 KB (Spurious Dragon)
**Status:** ✅ Within limit after optimizations

### Events

Complete audit trail via events:

```solidity
// Organization lifecycle
event OrgRegistered(bytes32 indexed orgId, uint256 adminHatId, uint256 operatorHatId);
event PauseSet(bytes32 indexed orgId, bool paused);

// Financial tracking
event OrgDepositReceived(bytes32 indexed orgId, address indexed from, uint256 amount);
event SolidarityDonationReceived(address indexed from, uint256 amount);
event SolidarityFeeCollected(bytes32 indexed orgId, uint256 amount);

// Configuration
event RuleSet(bytes32 indexed orgId, address indexed target, bytes4 indexed selector, bool allowed, uint32 maxCallGasHint);
event BudgetSet(bytes32 indexed orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen, uint32 epochStart);
event FeeCapsSet(bytes32 indexed orgId, uint256 maxFeePerGas, ...);

// Usage tracking
event UsageIncreased(bytes32 indexed orgId, bytes32 subjectKey, uint256 delta, uint128 usedInEpoch, uint32 epochStart);

// Governance
event GracePeriodConfigUpdated(uint32 initialGraceDays, uint128 maxSpendDuringGrace, uint128 minDepositRequired);
event OrgBannedFromSolidarity(bytes32 indexed orgId, bool banned);
```

### Further Reading

- [ERC-4337: Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
- [UUPS Proxies](https://eips.ethereum.org/EIPS/eip-1822)
- [Hats Protocol Documentation](https://docs.hatsprotocol.xyz/)
- [Worker Cooperative Principles](https://www.ica.coop/en/cooperatives/cooperative-identity)

---

**Version:** 1.0
**Last Updated:** 2025
**Maintainers:** POA Engineering Team
**License:** MIT
