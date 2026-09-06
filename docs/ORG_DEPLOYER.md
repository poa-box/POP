# OrgDeployer: The Genesis of Worker-Owned Organizations

`OrgDeployer` turns a group of individuals into a **Perpetual Organization** in one atomic
transaction: governance, access control, economic participation and collaborative work, wired
together and handed straight to the community.

> **Access v2.** Orgs deployed today are *authority-native*: access lives in a per-org
> **MembershipAuthority**, not in a Hats Protocol tree. The old `HatsTreeSetup` /
> `EligibilityModule` / `ToggleModule` deploy path is gone. Legacy orgs keep their Hats tree and
> read through the protocol's `AuthorityRouter` until they migrate — see
> [`script/accessv2/MIGRATION-RUNBOOK.md`](../script/accessv2/MIGRATION-RUNBOOK.md).

---

## Core principles in code

### Atomic birth: one transaction, one organization

`deployFullOrg` creates the whole organization in a single call, behind a manual reentrancy guard
(`_deployFullOrgGuarded`). There is no interim period in which a founder "owns" the org before
handing it over — it is born whole or not at all.

### The deployer's paradox: power that immediately dissolves

The last thing the deployer does is give everything away:

```solidity
/* 14. Renounce executor ownership - now only governed by voting */
OwnableUpgradeable(result.executor).renounceOwnership();
```

From that moment only collective decisions through the voting modules can move the org. No hidden
backdoors, no founder override, no emergency admin key. The Executor's ADMIN authority subject is
held by the Executor itself — the lock-out guard, not a person.

---

## Architecture: three factories

```
                    ┌─────────────────────┐
                    │    OrgDeployer      │
                    │   (Orchestrator)    │
                    └──────────┬──────────┘
                               │
           ┌───────────────────┼───────────────────┐
           ▼                   ▼                   ▼
┌──────────────────┐ ┌───────────────────┐ ┌──────────────────┐
│ GovernanceFactory│ │   AccessFactory   │ │  ModulesFactory  │
│                  │ │                   │ │                  │
│ • Executor       │ │ • MembershipAuth. │ │ • TaskManager    │
│ • HybridVoting   │ │ • QuickJoin       │ │ • EducationHub   │
│ • DirectDemocracy│ │ • Participation   │ │ • PaymentManager │
│                  │ │   Token           │ │ • ZkEmailInvites │
└──────────────────┘ └───────────────────┘ └──────────────────┘
```

- **Governance (who decides)** — `Executor` is the org's hands: it acts only when the authorized
  voting contract tells it to. `HybridVoting` blends token weight with one-person-one-vote;
  `DirectDemocracyVoting` is pure one-person-one-vote.
- **Access (who belongs)** — the **MembershipAuthority** is the org's single source of truth for
  membership, eligibility and permissions. `QuickJoin` is the front door; `ParticipationToken` is
  the non-transferable record of contribution.
- **Modules (what work happens)** — `TaskManager`, `EducationHub`, `PaymentManager`, and
  (where the chain has ZK Email infra wired) `ZkEmailInvites`.

### Subjects, not hats

The authority allocates **subject ids** deterministically from its own address:
`newSubjectId(authority, seq)` = `(uint160(authority) << 64) | seq`. Every id is therefore
< 2^224, which is exactly what distinguishes it from a real Hats id (those always carry a nonzero
tophat domain in bits 224-255).

| seq | Subject |
|-----|---------|
| 1 | `ADMIN` — worn by the Executor only |
| 2 + i | role `i` (`params.roles[i]`) |
| 2 + n + j | group `j` (`params.groups[j]`), where `n = roles.length` |

Callers never read these ids back from the authority: the deployer derives them from the proxy
address alone and publishes them via `OrgRegistry.registerHatsTree(orgId, adminSubjectId, …)`
(the registry's storage names are historical; the values are subject ids).

Chain-wide readers that used to call Hats — `PaymasterHub` and `OrgRegistry` — resolve these ids
through the protocol's `AuthorityRouter`, which self-routes an embedded-authority id to that
authority and passes legacy Hats ids straight through. The router must exist and both readers must
point at it; the deploy scripts wire this (see `script/deploy/DeployHelper.s.sol`).

---

## The deployment sequence

```
 1 Validate role/group configuration        9 Wire the token to TaskManager/EducationHub
 2 Create the org in bootstrap mode        10 Bootstrap projects + per-project TM_PERMS rows
 3 Deploy the Executor                     11 Authorize the hat-minting modules
 4 Deploy the MembershipAuthority          12 Repoint modules -> authority, seed genesis
 5 Deploy access (QuickJoin, Token)           memberships, unpause
 6 Deploy functional modules               13 Link the Executor to its governor
 7 Deploy the voting mechanisms            14 Renounce Executor ownership
 8 Register the org with PaymasterHub      15 Emit the deployment events
```

### 1. Validation

`_validateRoleConfigs` rejects the shapes that would otherwise fail deep inside the authority's
constructor, or silently produce a broken org:

- 1..`MAX_ROLES` (16) roles, ≤ `MAX_GROUPS` (8) groups, ≤ `MAX_GROUP_MEMBERS` (16) members each;
  non-empty names.
- vouching: non-zero quorum and an in-range `voucherRoleIndex`.
- every role bitmap addresses only existing role indices.
- `QuickJoinRoleNotOpen` — a role in `quickJoinRolesBitmap` must be `open` (default-ALLOW).
  QuickJoin enumerates the subjects carrying `QJ_AUTOJOIN` with no eligibility filter, so a closed
  role there would brick every join at runtime.
- `DuplicateGroupMemberRole` — a group may not list the same role twice.
- `RoleCapacityBelowGenesisSeed` — a role's `maxMembers` must fit the wearers its genesis seed mints.

### 2. Bootstrap mode

`OrgRegistry.createOrgBootstrap` opens a protected window in which the deployer (and only the
deployer) may register the org's contracts. It closes automatically when the last module registers.

### 3-4. Executor, then authority

The Executor is deployed first — it owns nearly everything else, and it is the ADMIN subject's sole
member. The **MembershipAuthority** is then deployed *born initialized and paused*: its whole access
shape (subjects, defaults, caps, vouch attestors, permission rows) is passed as constructor data, so
there is no window in which an uninitialized authority exists. Its subject ids are published to the
`OrgRegistry`, and `metadataAdminRoleIndex` (when in range) selects the role that may edit org
metadata directly.

### 5-7. Access, modules, voting

Modules are deployed against the org's Executor and role subject ids. No module reads the authority
during its own `initialize` — the repoint happens in step 12, after every address exists.

### 8. PaymasterHub

```solidity
IPaymasterHub(l.paymasterHub).registerAndConfigureOrg{value: msg.value}(orgId, adminSubjectId, config);
```

The org's hub admin is its **ADMIN subject** and its operator is the role named by
`paymasterConfig.operatorRoleIndex` — both resolved through the `AuthorityRouter`.

With `paymasterConfig.autoWhitelistContracts`, the deployer does **not** seed a hardcoded selector
whitelist. It registers each deployed module (and the shared registries) under its module typeId
(`_buildTargetTypes`), and sponsored selectors resolve through the hub's Poa-managed **global
rulebook** (see `docs/PAYMASTER_HUB.md` → Rules Engine). `autoUpgrade = true` orgs start in Mirror
mode (rules follow the rulebook); `autoUpgrade = false` starts Static with a local snapshot. Adding
a sponsored function is one `setGlobalRulesBatch` — never an OrgDeployer change.

### 9-11. Wiring

The token's `setTaskManager` / `setEducationHub` are executor-only, so they are relayed through the
Executor (still owned by the deployer at this point). Bootstrap projects mirror their role lists
into the authority's **per-project** `TM_PERMS` rows, which carry `INHERIT_GLOBAL` — a project grant
*adds to* the org-wide grant instead of shadowing it. `QuickJoin` (and `ZkEmailInvites`, when
deployed) are authorized to mint through `Executor.mintHatsForUser`.

### 12-15. Activation and release

`_activateAuthority` points every module at the authority, seeds the genesis memberships (Executor
on ADMIN, then each role's `mintToDeployer` / `additionalWearers`) and unpauses it. The Executor is
linked to `HybridVoting`, ownership is renounced, and the deployment events are emitted.

---

## Role configuration

### `RoleConfig` (`src/libs/RoleConfigStructs.sol`)

```solidity
struct RoleConfig {
    string name;
    string image;                        // IPFS hash or URI (subgraph metadata)
    bytes32 metadataCID;                 // IPFS CID of the extended role metadata JSON
    bool canVote;                        // included in the HybridVoting default class electorate
    bool open;                           // true = default-ALLOW; false = deny-by-default (titled)
    uint32 maxMembers;                   // 0 = unlimited
    RoleVouchingConfig vouching;         // quorum vouches from `voucherRoleIndex` grant eligibility
    RoleDistributionConfig distribution; // mintToDeployer + additionalWearers
}

struct GroupConfig {
    string name;
    uint256[] memberRoleIndices;         // membership derived from these roles; no cap, no acceptance
}
```

`open` replaces the v1 eligibility defaults, and the Hats-native knobs (hierarchy, maxSupply,
mutability, toggle) are gone — the authority stores only what it actually enforces.

### Example: a three-tier community

| Role | Shape |
|------|-------|
| **NEWCOMER** (0) | `open = true` — auto-joined by QuickJoin, no vote |
| **MEMBER** (1) | `open = false`, vouching enabled (quorum 3 from MEMBER), `canVote = true` |
| **STEWARD** (2) | `open = false`, vouching enabled (quorum 2 from STEWARD), capped via `maxMembers` |

Add a `GroupConfig{"Stewards", [2]}` to give restricted polls and manager delegation something to
point at.

### Role bitmaps

```solidity
struct RoleAssignments {
    uint256 quickJoinRolesBitmap;             // Bit N = Role N auto-joins (QJ_AUTOJOIN; must be open)
    uint256 tokenMemberRolesBitmap;           // Bit N = Role N holds tokens
    uint256 tokenApproverRolesBitmap;         // Bit N = Role N approves transfers
    uint256 taskCreatorRolesBitmap;           // Bit N = Role N is a TaskManager organizer
    uint256 educationCreatorRolesBitmap;      // Bit N = Role N creates courses
    uint256 educationMemberRolesBitmap;       // Bit N = Role N accesses courses
    uint256 hybridProposalCreatorRolesBitmap; // Bit N = Role N proposes
    uint256 ddVotingRolesBitmap;              // Bit N = Role N votes in polls
    uint256 ddCreatorRolesBitmap;             // Bit N = Role N creates polls
}
```

Each bit becomes a permission row on that role's subject. `tokenMemberRolesBitmap = 0b110` means
roles 1 and 2 hold tokens, role 0 does not.

---

## Vouching: trust through community

Vouching is an **attestor** on a role subject, seeded from `RoleVouchingConfig` at deploy time:
`quorum` vouches from members of `voucherRoleIndex` make a user eligible (ALLOW at the attestor
tier — an explicit BAN still wins). Membership is earned through community recognition rather than
purchased or self-assigned, and every accepted member has a traceable eligibility source.

---

## Beacon proxies: evolvable but accountable

Every module is a BeaconProxy behind a per-org `SwitchableBeacon`:

- **Mirror (`autoUpgrade = true`)** — follow protocol upgrades automatically.
- **Static (`autoUpgrade = false`)** — pinned; upgrading takes an explicit governance vote.

See `SWITCHABLE_BEACON.md`.

---

## Security notes

- **Reentrancy** — `_deployFullOrgGuarded` wraps the whole deployment in a manual guard.
- **Validation** — see step 1; misconfiguration fails with the deployer's own named errors rather
  than an opaque revert from inside a factory or the authority's constructor.
- **Bootstrap mode** — contracts can only be registered during the protected window; the deployer's
  own registration callbacks revert `DeploymentComplete` afterwards.
- **No uninitialized window** — the authority is initialized via constructor data, so it can never
  be front-run into a different shape.

---

## Integration points

### Frontend

`OrgDeployed` carries every address plus the authority's subject ids:

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
    address membershipAuthority,
    uint256 adminSubjectId,
    uint256[] roleSubjectIds
);
```

`RolesCreated` carries the role/group names and metadata alongside their subject ids.

### Subgraph

Complete organization discovery from one event, plus per-module `ContractRegistered` entries from
the `OrgRegistry`. Deploy-time module config is emitted *after* registration so the per-org data
source templates index it without any `eth_call`.

---

## Quick reference

| Function | Purpose |
|----------|---------|
| `deployFullOrg(params)` | Deploy a complete organization |
| `deployFullOrgWithZkEmail(params, zkConfig)` | …plus ZK Email role invitations |
| `registerContract(...)` / `batchRegisterContracts(...)` | Factory callbacks for registration |

| Struct | Purpose |
|--------|---------|
| `DeploymentParams` | Full organization configuration |
| `DeploymentResult` | Deployed contract addresses (incl. `membershipAuthority`) |
| `RoleAssignments` | Permission bitmaps for all modules |

| Factory | Deploys |
|---------|---------|
| `GovernanceFactory` | Executor, HybridVoting, DirectDemocracyVoting |
| `AccessFactory` | MembershipAuthority, QuickJoin, ParticipationToken |
| `ModulesFactory` | TaskManager, EducationHub, PaymentManager, ZkEmailInvites |
