# OrgDeployer: The Genesis of Worker-Owned Organizations

## Philosophy: From Individual Action to Collective Power

The `OrgDeployer` contract is the foundational layer that transforms a group of individuals into a **Perpetual Organization**. In a single atomic transaction, it weaves together governance, access control, economic participation, and collaborative work infrastructure into a unified system where every member has voice, every contribution has value, and every decision belongs to the community.

This document explores how `OrgDeployer` embodies the Poa vision: organizations that are owned by those who build them, governed by those who participate in them, and designed to persist beyond any individual founder.

---

## Core Principles in Code

### 1. Atomic Birth: One Transaction, One Organization

The `deployFullOrg` function creates an entire organization in a single transaction. This isn't just technical elegance—it's a design choice with purpose. There is no interim period where a founder "owns" the organization before handing it over. From the moment of creation, the governance structure is complete and autonomous.

```solidity
function deployFullOrg(DeploymentParams calldata params)
    external
    returns (DeploymentResult memory result)
{
    // Manual reentrancy guard
    Layout storage l = _layout();
    if (l._status == 2) revert Reentrant();
    l._status = 2;

    result = _deployFullOrgInternal(params);

    // Reset reentrancy guard
    l._status = 1;
    return result;
}
```

The reentrancy guard ensures this creation cannot be interrupted or manipulated—the organization is born whole or not at all.

### 2. The Deployer's Paradox: Power That Immediately Dissolves

At the end of deployment, something important happens:

```solidity
/* 11. Renounce executor ownership - now only governed by voting */
OwnableUpgradeable(result.executor).renounceOwnership();
```

The deployer—the person who initiated the organization—**immediately relinquishes all special privileges**. From this moment forward, only collective decisions through the voting mechanisms can control the organization. This is the Poa approach: no hidden backdoors, no founder override, no "emergency" admin keys.

The deployer becomes just another member, distinguished only by being the first to believe in the community's potential.

---

## Architecture: The Three Pillars

OrgDeployer orchestrates three specialized factories, each responsible for a domain of organizational life:

```
                    ┌─────────────────────┐
                    │    OrgDeployer      │
                    │   (Orchestrator)    │
                    └──────────┬──────────┘
                               │
           ┌───────────────────┼───────────────────┐
           │                   │                   │
           ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ GovernanceFactory│ │  AccessFactory  │ │ ModulesFactory  │
│                 │ │                 │ │                 │
│ • Executor      │ │ • QuickJoin     │ │ • TaskManager   │
│ • Hats Tree     │ │ • Participation │ │ • EducationHub  │
│ • HybridVoting  │ │   Token         │ │ • PaymentManager│
│ • DirectDemo    │ │                 │ │                 │
│ • Eligibility   │ │                 │ │                 │
│ • Toggle        │ │                 │ │                 │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

### Pillar 1: Governance (Who Decides)

The **GovernanceFactory** creates the decision-making infrastructure:

- **Executor**: The "hands" of the organization—it can only act when instructed by approved governance mechanisms
- **HybridVoting**: Combines token-weighted voting with direct democracy, allowing organizations to balance expertise with equality
- **DirectDemocracyVoting**: Pure one-person-one-vote for decisions that require equal say
- **Hats Protocol Integration**: A flexible role system where "hats" represent responsibilities, not permanent hierarchies

### Pillar 2: Access (Who Belongs)

The **AccessFactory** creates the membership infrastructure:

- **QuickJoin**: The welcoming door—enables new members to join and immediately receive their roles
- **ParticipationToken**: Non-transferable tokens that represent contribution, not speculation

### Pillar 3: Modules (What Work Happens)

The **ModulesFactory** creates the collaboration infrastructure:

- **TaskManager**: Coordinated work with token rewards
- **EducationHub**: Knowledge sharing and skill development
- **PaymentManager**: Treasury operations and member compensation

---

## The Deployment Sequence: 12 Steps

```
Step 1: Validate Role Configurations
        ↓
Step 2: Validate Deployer Address
        ↓
Step 3: Create Org in Bootstrap Mode
        ↓
Step 4: Deploy Governance Infrastructure
        ↓
Step 5: Set Org Executor
        ↓
Step 6: Register Hats Tree
        ↓
Step 7: Register with PaymasterHub
        ↓
Step 8: Deploy Access Infrastructure
        ↓
Step 9: Deploy Functional Modules
        ↓
Step 10: Deploy Voting Mechanisms
        ↓
Step 11: Wire Cross-Module Connections
        ↓
Step 12: Renounce Ownership
```

### Step-by-Step: What's Really Happening

#### 1-2. Validation: Ensuring a Sound Foundation

```solidity
_validateRoleConfigs(params.roles);
if (params.deployerAddress == address(0)) {
    revert InvalidAddress();
}
```

Before anything is created, the contract validates that the role structure makes sense—no circular hierarchies, valid vouching configurations, non-empty role names. An organization built on flawed foundations will fail its members.

#### 3. Bootstrap Mode: A Protected State

```solidity
if (!_orgExists(params.orgId)) {
    l.orgRegistry.createOrgBootstrap(params.orgId, bytes(params.orgName), bytes32(0));
} else {
    revert OrgExistsMismatch();
}
```

The organization is created in "bootstrap mode"—a protected state where contracts can be registered but no external parties can interfere. The organization is being assembled but not yet ready for the world.

#### 4-6. The Executor and the Hat Tree

The Executor is deployed first because it becomes the owner of nearly everything else. Then the Hats tree is created—a hierarchy of roles that defines who can do what within the organization.

```solidity
GovernanceFactory.GovernanceResult memory gov = _deployGovernanceInfrastructure(params);
result.executor = gov.executor;
l.orgRegistry.setOrgExecutor(params.orgId, result.executor);
l.orgRegistry.registerHatsTree(params.orgId, gov.topHatId, gov.roleHatIds);
```

#### 7. PaymasterHub: Shared Infrastructure

```solidity
IPaymasterHub(l.paymasterHub).registerAndConfigureOrg{value: msg.value}(params.orgId, topHatId, config);
```

Organizations share a common PaymasterHub for gas sponsorship. Infrastructure should serve all communities, not be duplicated inefficiently.

When `paymasterConfig.autoWhitelistContracts` is set, the deployer no longer seeds a hardcoded selector whitelist. Instead it registers each deployed module (and the shared registries) with its module typeId (`_buildTargetTypes`), and the org's sponsored selectors resolve through the PaymasterHub's Poa-managed **global rulebook** (see `docs/PAYMASTER_HUB.md` → Rules Engine). Orgs deployed with `autoUpgrade = true` start in Mirror mode (rules follow the rulebook automatically); `autoUpgrade = false` would start Static with a local snapshot of the current rulebook. Adding a new sponsored function no longer requires touching OrgDeployer — one `setGlobalRulesBatch` covers all Mirror orgs, current and future.

#### 8-9. Access and Modules: The Living Organization

With governance in place, the organization gains its ability to accept members and coordinate work:

```solidity
access = l.accessFactory.deployAccess(accessParams);
modules = l.modulesFactory.deployModules(moduleParams);
```

#### 10-11. Wiring the Connections

The organization isn't just individual contracts—it's an interconnected system:

```solidity
IParticipationToken(result.participationToken).setTaskManager(result.taskManager);
IParticipationToken(result.participationToken).setEducationHub(result.educationHub);
IExecutorAdmin(result.executor).setHatMinterAuthorization(result.quickJoin, true);
IExecutorAdmin(result.executor).setCaller(result.hybridVoting);
```

Tasks and education can mint tokens. QuickJoin can assign hats. HybridVoting controls the Executor. These connections create a system where contribution flows into representation.

#### 12. The Final Release

```solidity
OwnableUpgradeable(result.executor).renounceOwnership();
```

The organization is now self-governing. The deployer has no more power than any other member.

---

## Role Configuration: Designing Community Structure

One of the most powerful aspects of OrgDeployer is its flexible role system. Roles aren't just labels—they're bundles of permissions, voting power, and community responsibilities.

### The RoleConfig Structure

```solidity
struct RoleConfig {
    string name;                           // Human-readable identifier
    string image;                          // Visual representation
    bool canVote;                          // Participation in governance
    RoleVouchingConfig vouching;           // How new members earn this role
    RoleEligibilityDefaults defaults;      // Initial standing
    RoleHierarchyConfig hierarchy;         // Administrative relationships
    RoleDistributionConfig distribution;   // Who starts with this role
    HatConfig hatConfig;                   // Hats Protocol settings
}
```

### Example: A Three-Tier Community

Consider a community with three roles:

**NEWCOMER** (Index 0)
- Assigned automatically via QuickJoin
- Cannot vote
- Limited token holding rights
- Path to becoming a Member

**MEMBER** (Index 1)
- Requires vouching from 3 existing Members
- Full voting rights
- Can hold and earn tokens
- Can create tasks and educational content

**STEWARD** (Index 2)
- Requires vouching from 2 Stewards or 5 Members
- Can moderate content
- Administrative capabilities
- Trusted community guides

### Role Bitmaps: Efficient Permission Assignment

Rather than listing roles individually, OrgDeployer uses bitmaps for gas-efficient permission assignment:

```solidity
struct RoleAssignments {
    uint256 quickJoinRolesBitmap;           // Bit N = Role N on join
    uint256 tokenMemberRolesBitmap;         // Bit N = Role N holds tokens
    uint256 tokenApproverRolesBitmap;       // Bit N = Role N approves transfers
    uint256 taskCreatorRolesBitmap;         // Bit N = Role N creates tasks
    uint256 educationCreatorRolesBitmap;    // Bit N = Role N creates courses
    uint256 educationMemberRolesBitmap;     // Bit N = Role N accesses courses
    uint256 hybridProposalCreatorRolesBitmap; // Bit N = Role N proposes
    uint256 ddVotingRolesBitmap;            // Bit N = Role N votes in DD
    uint256 ddCreatorRolesBitmap;           // Bit N = Role N creates polls
}
```

Example: If `tokenMemberRolesBitmap = 0b110` (binary), roles 1 and 2 can hold tokens, but role 0 cannot.

---

## The Vouching System: Trust Through Community

Poa believes that membership should be earned through community recognition, not purchased or self-assigned. The vouching system implements this:

```solidity
if (vouchCount > 0) {
    uint256[] memory hatIds = new uint256[](vouchCount);
    uint32[] memory quorums = new uint32[](vouchCount);
    uint256[] memory membershipHatIds = new uint256[](vouchCount);
    bool[] memory combineFlags = new bool[](vouchCount);

    // ... populate arrays from role configs ...

    IExecutorAdmin(result.executor).batchConfigureVouching(
        gov.eligibilityModule,
        hatIds,
        quorums,
        membershipHatIds,
        combineFlags
    );
}
```

### How Vouching Works

1. A newcomer requests a higher-tier role
2. Existing members with vouching power signal their approval
3. Once the quorum is met, the role is granted
4. The new member inherits the responsibilities and rights of their role

This creates a web of trust—every Member was vouched for by other Members, creating accountability chains throughout the community.

---

## Beacon Proxies: Evolvable but Accountable

Every contract deployed uses the Beacon Proxy pattern, allowing organizations to upgrade their infrastructure:

```solidity
struct AccessParams {
    // ...
    bool autoUpgrade;  // Follow platform upgrades automatically
    // ...
}
```

Organizations can choose:
- **Auto-Upgrade (autoUpgrade = true)**: Trust the Poa platform to evolve your contracts responsibly
- **Static Mode (autoUpgrade = false)**: Lock to a specific implementation, requiring explicit governance votes to upgrade

This respects organizational sovereignty while enabling shared infrastructure improvements.

---

## Security Considerations

### 1. Reentrancy Protection

The manual reentrancy guard prevents the complex deployment from being attacked:

```solidity
if (l._status == 2) revert Reentrant();
l._status = 2;
// ... deployment logic ...
l._status = 1;
```

### 2. Role Validation

Comprehensive validation prevents malformed organizations:

```solidity
function _validateRoleConfigs(RoleConfigStructs.RoleConfig[] calldata roles) internal pure {
    if (len == 0) revert InvalidRoleConfiguration();
    if (len > 32) revert InvalidRoleConfiguration();

    for (uint256 i = 0; i < len; i++) {
        if (role.vouching.enabled) {
            if (role.vouching.quorum == 0) revert InvalidRoleConfiguration();
            if (role.vouching.voucherRoleIndex >= len) revert InvalidRoleConfiguration();
        }
        // ... additional validations ...
    }
}
```

### 3. Bootstrap Mode

Only during the protected bootstrap phase can contracts be registered, preventing injection attacks:

```solidity
(,, bool bootstrap,) = l.orgRegistry.orgOf(orgId);
if (!bootstrap) revert("Deployment complete");
```

---

## Integration Points

### For Frontend Developers

Listen for the `OrgDeployed` event to capture all contract addresses:

```solidity
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
```

### For Subgraph Indexers

The event structure enables complete organization discovery in a single event, simplifying indexing.

---

## Conclusion

The OrgDeployer contract is more than deployment infrastructure—it's a commitment to worker ownership in code. Every function, every validation, every connection serves the principle that organizations should belong to those who build them.

When you call `deployFullOrg`, you're:
- Establishing a governance system that respects every voice
- Creating economic infrastructure that rewards contribution over capital
- Building collaborative tools that enable meaningful work
- Setting up permission systems that trust communities to self-govern

And then, in that final `renounceOwnership()`, the organization belongs to everyone who will ever be a part of it.

---

## Quick Reference

| Function | Purpose |
|----------|---------|
| `deployFullOrg(params)` | Deploy complete organization |
| `registerContract(...)` | Factory callback for contract registration |
| `batchRegisterContracts(...)` | Optimized batch registration |

| Struct | Purpose |
|--------|---------|
| `DeploymentParams` | Full organization configuration |
| `DeploymentResult` | Deployed contract addresses |
| `RoleAssignments` | Permission bitmaps for all modules |

| Factory | Deploys |
|---------|---------|
| `GovernanceFactory` | Executor, Voting, Hats modules |
| `AccessFactory` | QuickJoin, ParticipationToken |
| `ModulesFactory` | TaskManager, EducationHub, PaymentManager |
