# Access v2 Migration Runbook (Wave D)

Broadcast order for the Hats → MembershipAuthority cutover. Normative design: `ACCESS-V2-SPEC.md`
§6 (in `.context/rolemanager/` during development). Every step below was **fork-rehearsed under
`FOUNDRY_PROFILE=production`** on live Gnosis/Arbitrum state before this document was written; the
per-proposal gas figures are measured, not estimated. Re-run the sims immediately before each
broadcast — they assert against live state and fail loudly if anything drifted.

**Nothing in this runbook has been broadcast.** The superseded v1 RoleManager runbook and its
scripts (`script/rolemanager/`, never broadcast) were deleted in the 2026-08 script cleanup.

---

## Phase 0 — protocol wave (once per chain; Gnosis first, then Arbitrum)

Scripts in `script/accessv2/`; all admin calls are Satellite-local (Gnosis) / Hub-local (Arbitrum)
as Hudson (`0xA6F4…b2c9`). Versions were dual-surface probed (registry + CREATE2, both chains)
2026-08-22 — **re-probe before broadcast** (CLAUDE.md loop): MembershipAuthority v1, AuthorityRouter
v1, PaymasterHub v20, DD/HV v13, TM/PT/QJ v8, EducationHub v4, Executor v5.

| # | Step | Script | Sim (must PASS first) |
|---|------|--------|----------------------|
| 1 | Register MembershipAuthority + AuthorityRouter (impl + beacon), deploy router singleton (CREATE3 — same address both chains), PaymasterHub → v20 (adds `setHats`), **hub `setHats(router)` repoint while router is EMPTY** (§6 step 0.5) | `RegisterAccessV2Protocol.s.sol` (Step1/Step2 per chain) | `SimGnosis` / `SimArbitrum` — includes router-passthrough neutrality proof for a live wearer |
| 2 | Register + bump the 7 dual-path module beacons (DD, HV, TM, PT, EDU, QJ, Executor) | `UpgradeAccessV2Modules.s.sol` | `SimGnosis` / `SimArbitrum` — byte-identical legacy read snapshot pre/post on a live org; `membershipAuthority()==0` |
| 3 | Global rulebook: +10 MembershipAuthority user-facing selectors (`DefaultGlobalRules.sol` is the source of truth) | `SyncAccessV2GlobalRules.s.sol` | `SimGnosis` / `SimArbitrum` — getRule before/after with correct `{maxCallGasHint, allowed}` field order |

```sh
FOUNDRY_PROFILE=production forge script script/accessv2/<script>:<SimX> --fork-url <gnosis-gateway|arbitrum> -vvv
```

Use `gnosis-gateway` (plain `gnosis` alias rate-limits). A `-32029` / "EVM error" mid-sim is public-RPC
flakiness — retry, or switch to `gnosis-drpc`; a real failure reproduces on both endpoints.

**Subgraph gate (§6 step-0 item 7):** the v2 subgraph (authority template + fold mirror + pending
entity) must be published to Studio AND the decentralized gateway on both chains BEFORE the first
cutover proposal is created (the app reads the gateway, not Studio).
STATUS 2026-08-26: **Gnosis LIVE and verified** — Studio serves the post-fix PR-211 build
(deployment QmUAxz2tPcj3FekGtSKnewauZho1rhEqhsMZWffHKASfmb, 0 indexing errors, synced to head;
verified by probing a fix-removed field). **Arbitrum still syncing.** Before the FIRST cutover
proposal on each chain, confirm the GATEWAY (not just Studio) serves this schema — the frontend
capability probe will refuse the v2 surfaces otherwise (by design).

## Phase 1 — per-org ceremony (order: Test6 → Decentral Park → Poa → KUBI)

Each org: three ops surfaces in `MigrateOrgToAuthority.s.sol`, env-driven `ORG=TEST6|DP|KUBI|POA`.

1. **Predeploy** (broadcast, Hudson — DeterministicDeployer.deploy is onlyOwner):
   ```sh
   ORG=TEST6 FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:PredeployAuthority \
     --rpc-url gnosis --broadcast --slow
   ```
   CREATE2 salt `("MembershipAuthorityProxy:<Org>", "v1")` → address knowable before proposals.
   **C5 (front-run grief close):** the proxy is deployed WITH init data — it lands ATOMICALLY
   INITIALIZED (empty genesis: executor/orgId/paused only) in the deploy tx, so no attacker can
   initialize the predicted slot first during the seed-proposal vote window. The predeploy script
   asserts `executor == org Executor` and `paused == true` after deploy.

2. **Generate proposal JSON** (fork, no broadcast):
   ```sh
   ORG=TEST6 FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:GenerateBatches \
     --fork-url gnosis-gateway
   ```
   Writes `out/<org>.seed.N.json` + `out/<org>.cutover.1.json`. Batches are LIVE-STATE-DERIVED:
   **regenerate right before the cutover proposal is created** (the delta-seed discipline). For
   KUBI-sized orgs, freeze legacy joins (QuickJoin allowlist off) between final generation and
   cutover execution.

3. **Proposals** (the org, via frontend): each JSON is one 1-option executable HybridVoting
   proposal, created IN ORDER (seed.1 … seed.N, then cutover.1), each finalized with an EXPLICIT
   gas limit — `announceWinner`'s try/catch defeats `eth_estimateGas` (CLAUDE.md gotcha):
   ```sh
   cast send <HV> 'announceWinner(uint256)' <id> --gas-limit <figure below>
   ```

4. **Verify**: re-run the org's governed sim (below) BEFORE step 3. The §6 verification reads are
   realized by `CutoverVerifier.verify` (C4) appended as the LAST call of the cutover batch — it
   `require()`s per-subject memberCount == the generation-time count, memberCount <= canonical Hats
   supply, and router-through resolution of the admin id; a failed check reverts the WHOLE batch, so
   nothing half-lands. See the CutoverVerifier note below for the full check set.

### announceWinner discipline (STRICT IN-ORDER + post-state verification)

`announceWinner`'s `try/catch` swallows a batch revert: it succeeds, emits `ProposalExecutionFailed`
(`Executor.CallFailed`), marks the proposal `executed`, and **nothing lands** — the proposal is
permanently burned and must be re-created + re-voted through a full window. Two rules close this:

1. **Finalize IN ORDER and one at a time.** Create+finalize `seed.1`, then `seed.2`, … then
   `cutover.1`. Never finalize `seed.N` before `seed.N-1` has executed — the later batch assumes the
   earlier one's state.
2. **After EVERY `announceWinner`, verify before creating the next proposal.** Check the tx did NOT
   emit `ProposalExecutionFailed` / `Executor.CallFailed` (i.e. `didExecute == true`), then read the
   seed-invariant surface for that batch's subjects (`authority.isMember` / `memberCount` for the
   slice just seeded). If a batch silently no-op'd, STOP and re-create that proposal — do not proceed.
   For the cutover, the appended `CutoverVerifier.verify` makes a silent no-op impossible (any drift
   reverts the whole batch), but still confirm `didExecute == true`.

Always pass the explicit `--gas-limit` from the table below; the try/catch defeats `eth_estimateGas`.

### Measured announceWinner gas (fork rehearsal, production profile)

| Org | seed proposals | cutover | recommended `--gas-limit` |
|-----|----------------|---------|---------------------------|
| Test6 | 2.18M / 0.40M / 2.23M | 0.40M | 4,000,000 per proposal |
| Decentral Park | 2.13M / 0.40M / 0.99M | 0.41M | 4,000,000 |
| Poa | 1.99M / 1.21M | 0.40M | 4,000,000 |
| **KUBI** | 2.09M / 0.21M / **3.13M** / 2.05M | 0.40M | **5,000,000** (seed.3 exceeds the usual 3M guidance) |

**Proposal CREATION gas (A7, measured):** the largest seed proposal's `createProposal` costs
4.1M–4.9M gas per org (Test6 4.39M, DP 4.34M, Poa 4.14M, KUBI 4.95M) — HV stores the full batch.
Creation is a plain wallet tx (`eth_estimateGas` works — no try/catch trap), but the signer's wallet
must not cap below ~5.5M, and creation must NOT go through the sponsored/gasless path: the global
rulebook's HV `createProposal` hint would under-fund it. Org admins create seed/cutover proposals
from a funded EOA.

### Per-org decisions (recorded per §6 — not migration defaults)

- **delegable column**: open member role (QuickJoin) → `delegable=true`; every titled/officer role →
  **sticky** (`delegable=false`). Encoded in the seed builder; change requires editing
  `AccessV2MigrationBase._buildMembershipsAndTighten` before generation.
- **vouch**: Test6, Decentral Park, Poa → AMNESTY (members hold seeded explicit grants; re-vouch
  later if lapse semantics wanted). **KUBI → VERBATIM port** — RECORDS-FIRST (C2): the seed
  reconstructs each member's ACTUAL per-voucher records from the legacy EligibilityModule (probing
  `vouchers(subject, wearer, candidate)` across the candidate set) and ports them via
  `seedVouchers(subject, user, vouchers[])`, NOT a bare count — so a ported voucher can revoke and
  cannot re-vouch to double-count. **Self-voucher configs (voucherSubject == subject) ARE now
  ported** (C1): the authority accepts them (emits the `SelfVoucher` lint, no revert), so KUBI's
  Executives-vouch-Executives officer gate survives verbatim. Only an EMPTY subject bootstrap-
  deadlocks, recoverable via a governance seed/grant exactly like legacy.
- **maxMembers (R1)**: adopts the legacy `hats.viewHat(id).maxSupply` **VERBATIM** for EVERY subject
  (admin, titled, and the open member role) — the honest live cap. NOT tightened to the current count
  (which would revert `SubjectFull` on the next grant/claim/vouch and create the linted
  `VouchWithMaxMembers` anti-pattern) and NOT guessed-unlimited. Hats guarantees `supply <= maxSupply`,
  so the seeded `memberCount` is always `<= maxMembers` (SEED INVARIANT holds). The open member role's
  QuickJoin was already bounded by the same `maxSupply` legacy-side, so nothing regresses.
- **subject DEFAULT (A1 + T7)**: `_seedLiveDefaults` adopts the legacy EM's open verdict for **exactly
  one subject** — the org's QuickJoin member role, and only when the catalog's recorded
  `expectOpenMember` says so (T2 reconciles that constant against the live EM before a default is
  emitted). Every other subject seeds **deny-default**, spec §2 DEFAULT ("open roles = default-ALLOW +
  user claim; **titled** roles = deny-by-default + explicit grants"), even when the legacy EM default
  probes open. Reason: legacy *eligibility* is not legacy *wearing* — an EM-default-open titled hat had
  no permissionless mint channel (only executor/EM mint), whereas `MembershipAuthority.claim()` has no
  second gate, so adopting the legacy default verbatim would make the role permissionlessly claimable
  (with sponsored gas). This is live, not hypothetical — the T7 probe caught **4 real subjects** that
  the pre-T7 builder would have opened: Test6 `Treasurer` + `Newcomer`, and **Poa `MEMBER` (7 wearers)
  + `CONTRIBUTOR` (3 wearers)** — i.e. permissionless self-appointment into the Poa governance org's
  voting roles. Suppression costs nothing at cutover (every current wearer is ported with an explicit
  seeded Grant and `CutoverVerifier` pins `hatSupply`, so no wearer rides the default); post-cutover
  appointment is the governance path (`grantRole`, then `mintHat`), exactly like the legacy
  executor-gated mint. Suppressions are logged per subject (`[T7] TITLED role is EM-default-OPEN …`)
  and `_probeOpenSubjectStrangers` proves both arms on the authority after cutover: a stranger CAN
  `claim()` the one open member role (DP), and every other subject rejects a stranger with
  `NotClaimable` (Test6 5/5, KUBI 3/3, Poa 3/3, DP 3 gated + 1 open).
- **role names (specOrder-10)**: subjects adopt the live `hats.viewHat(id).details` string; empty
  details fall back to `Role#N` (admin → `Admin`, reconstructed voucher subjects → `VoucherRole`).
- **subject discovery (A6 / seedCompleteness-6)**: discovery now covers TM creator hats (lens 5), TM
  organizer hats (lens 11), and every HybridVoting voting-class `hatId` (`getClasses()`) in ADDITION
  to the DD/HV/PT/EDU/QJ/TM-permission lists. All three resolve on the module authority arms by pure
  membership (`_authorityHoldsAny` / `activeMemberSince`), so they are seeded as membership-only
  subjects (no perm key). This prevents a post-cutover HV voting class scoring zero (governance
  disenfranchisement) or TM create/organize going dark if an org adds such a hat before broadcast.

### Sims (the gate for everything above)

```sh
FOUNDRY_PROFILE=production forge script script/accessv2/RehearseMigration.s.sol:Rehearse<Org> --fork-url <chain>      # ceremony mechanics
FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:SimMigrate<Org> --fork-url <chain> # FULL governance loop
```

`SimMigrate<Org>` is the strong form: DD predeploy exactly as broadcast, every batch through REAL
`createProposal → vote (live wearers) → warp → announceWinner`, then seed invariant, membership
parity (Test6 56/56, DP 17/17, KUBI 73/73, Poa 25/25 at rehearsal), vouch parity, five behavioral
probes (DD create+vote, TM perm, QuickJoin join chain, PT gate, hub sponsorship through router),
and rollback byte-identity.

## Rollback (§6 — restores legacy hats state; does not reproduce authority-era changes)

Pause the authority, then ONE governance batch: module `setMembershipAuthority(0)` repoint-back ×8
→ legacy hat toggle-ON (reverse of cutover) → router unbind (Executor-gated, same OrgRegistry
path). The dual-path modules make repoint-back byte-identical to pre-migration — rehearsed in every
sim (`ROLLBACK: DD legacy path byte-identical`). The authority-only cleanup wave (removing legacy
code paths) ships only after the LAST org migrates and soaks.

## After all four orgs

- Wave E: subgraph v2 + frontend v2 releases (subgraph BEFORE first cutover, frontend
  feature-detects per module).
- Legacy EM/QuickJoin rulebook entries stay (superset discipline) until the last legacy org
  migrates; then a cleanup `setGlobalRulesBatch` may retire them.
- **Wave G — the de-Hats strip (sequencing decision 2026-08-25):** all migrations run on the
  dual-path impls this runbook rehearsed; ONLY AFTER the last real org is bound + cut over,
  ship authority-only impls in one Mirror-beacon wave. Behavior-neutral by construction for
  migrated orgs (the legacy arm is dead code once `membershipAuthority != 0` everywhere), so
  it needs NO org votes; sim gate = per-org read-parity differential pre/post bump.
  **CAUTION — the 6 inactive Gnosis orgs (Test, Test2, Test3, tkrjehbcuebc, Test5, Argus)
  break at THIS bump** unless pinned Static (`SwitchableBeacon.pinToCurrent()`, executor-owned)
  or migrated first — decide before broadcasting the strip wave. poa-cli's legacy scrap rides
  in this wave too.

## Access-v2 contract-surface notes (Wave D FIX-B)

- **CutoverVerifier (C4)** — a stateless protocol singleton (`src/CutoverVerifier.sol`, immutable
  `hats` + `orgRegistry`, ZERO storage) registered per chain in the Phase-0 wave
  (`addContractType("CutoverVerifier", …)`, deterministic CREATE3 address). Its single view-revert
  entrypoint `verify(orgId, authority, router, subjects[], expectedCounts[], expectedSupplies[])`
  belongs as the LAST call of the cutover Executor batch: it `require()`s (a)
  `router.authorityOf(subject) == authority` for every subject (bind landed, no spoof), (b)
  `authority.paused() == false`, (c) per subject `memberCount == expectedCounts[i]` (generation-time
  counts baked into the batch — AUTHORITY-side drift between generation and `announceWinner` reverts
  the whole batch), `hats.hatSupply(subject) == expectedSupplies[i]` (A5 — a FRESH LEGACY wearer that
  joined post-seed changes the canonical supply but NOT the authority memberCount, so this exact-
  equality guard is the only on-chain signal that a newcomer would be toggled off unported; it forces
  the regenerate-with-delta step before cutover), AND `memberCount <= hats.hatSupply(subject)` via the
  CANONICAL Hats (enumeration-independent upper bound — closes the self-referential-parity gap), and
  (d) the admin (topHat) id resolves THROUGH THE ROUTER (`isWearerOfHat(orgExecutor, subjects[0])` +
  `viewHat(...).active`). `subjects[0]` MUST be the admin (topHat) id.
- **Delta-seed (A5, §6 step-3 first element)** — the cutover batch OPENS with a delta-seed section:
  legacy wearers who joined since the seed proposals executed (live `isWearerOfHat` but not yet an
  authority member) get one `seedRules(Grant)`+`seedMemberships` pair each, INSIDE the atomic cutover
  (executor-gated, pause-exempt, before the unpause). `GenerateBatches` computes it automatically from
  the re-enumerated candidate set — so RE-RUN `tools/enumerate-wearers.sh` immediately before
  regenerating the cutover. No drift → empty delta → the router bind leads the batch (pre-A5 shape).
  The governed sim's drift drill (`SimMigrate*`) proves both arms: a stale batch reverts on `SupplyDrift`
  and a regenerated delta batch ports the newcomer with the verifier passing.
- **DD CREATE2 occupant guard (A7)** — `_ddDeployAuthority` reuses a pre-occupied predicted slot ONLY
  after two guards: the occupant's codehash matches a reference `BeaconProxy` on the org's MA beacon
  (rejects foreign/wrong-beacon bytecode at a colliding CREATE2 slot, CLAUDE.md pt 6), AND its
  `executor()`/`paused()` match this org's empty-genesis predeploy (rejects a legit BeaconProxy for a
  different org). Foreign bytecode reverts loudly instead of being bound as the authority.
- **Seed acceptedAt = epoch 1 (C3, ruling R7)** — `seedMemberships` writes `acceptedAt = 1`, NOT
  `block.timestamp`. Seeded members are pre-existing, so `activeMemberSince = 1 <=` any in-flight
  proposal's `createdAt`, keeping those proposals votable across the cutover; post-cutover `claim()`
  members get `acceptedAt = now` and stay gated out of pre-claim proposals (the §4 anti-packing
  property survives).

## Orchestrator rulings (recorded spec §6 deviations / realizations)

- **R3 — reconcile stays EXCLUDED from sponsorship (documented §6 step-0 item-4 deviation).** §6
  lists `reconcile` among the sponsored authority selectors, but a permissionless, gas-free reconcile
  is a grief-spam vector (any address can repeatedly burn an org's solidarity-fund gas). It is
  deliberately left unsponsored (see `DefaultGlobalRules.sol` reconcile comment). §8's permissionless
  reconcile repair still functions — the keeper just self-funds the gas. This is the ONE accepted
  divergence from the binding selector list.
- **R4 — "burn-shaped events for unported wearers" (§6 step-3) is realized as full-port + in-batch
  count verification, NOT synthetic burn events.** The ceremony ports EVERY live wearer (candidate
  set + admin), and `CutoverVerifier.verify` require()s per-subject `memberCount == expectedCounts[i]`
  AND `memberCount <= hats.hatSupply(subject)` (the canonical, enumeration-independent Hats supply).
  If any wearer were unported, `hatSupply` would exceed the ported `memberCount` and — combined with
  the generation-time count baked into the batch — the operator's regenerate-before-cutover step
  surfaces the gap; the toggle-off then provably covers exactly the ported set. The unported set is
  therefore provably EMPTY at cutover, which makes synthetic burn-shaped events unnecessary (and
  rollback DEPENDS on toggle-off never burning real balances — §6 ROLLBACK). Subgraph member-set
  divergence is a Wave-E indexing concern, not a cutover-batch one.

## SPEC ERRATA (appended per C5)

**§6 step 1 register-before-initialize → register-before-SUBJECT.** The authority proxy is now
deployed WITH init data (atomic initialize in the deploy tx — C5, front-run grief close), so
`initialize`'s two config events (`MembershipAuthorityInitialized`, `PausedSet`) necessarily PREDATE
`registerOrgContract`. This is the ONE accepted consequence: those config events are
subgraph-derivable from the Organization entity (executor/orgId/paused) with NO `eth_call`, so no
indexing fidelity is lost. The `initialize` genesis is EMPTY (no subjects), so ALL subject events —
the ones that actually matter for the per-org template — are emitted by the seed batches AFTER
`registerOrgContract` leads seed batch 1. The register-before-initialize discipline therefore now
applies to SUBJECT events, which is what matters.
