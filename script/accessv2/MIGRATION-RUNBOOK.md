# Access v2 Migration Runbook (Wave D)

Broadcast order for the Hats → MembershipAuthority cutover. Normative design: `ACCESS-V2-SPEC.md`
§6 (in `.context/rolemanager/` during development). Every step below was **fork-rehearsed under
`FOUNDRY_PROFILE=production`** on live Gnosis/Arbitrum state before this document was written; the
per-proposal gas figures are measured, not estimated. Re-run the sims immediately before each
broadcast — they assert against live state and fail loudly if anything drifted.

**Nothing in this runbook has been broadcast.** The v1 (`script/rolemanager/`) runbook is
superseded — do not run it.

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
cutover proposal is created (the app reads the gateway, not Studio). Wave E deliverable.

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

### Measured announceWinner gas (fork rehearsal, production profile)

| Org | seed proposals | cutover | recommended `--gas-limit` |
|-----|----------------|---------|---------------------------|
| Test6 | 2.18M / 0.40M / 2.23M | 0.40M | 4,000,000 per proposal |
| Decentral Park | 2.13M / 0.40M / 0.99M | 0.41M | 4,000,000 |
| Poa | 1.99M / 1.21M | 0.40M | 4,000,000 |
| **KUBI** | 2.09M / 0.21M / **3.13M** / 2.05M | 0.40M | **5,000,000** (seed.3 exceeds the usual 3M guidance) |

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
- **maxMembers**: titled roles tightened to live active count; the open member role stays
  UNLIMITED (capping it would brick QuickJoin).

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

## Access-v2 contract-surface notes (Wave D FIX-B)

- **CutoverVerifier (C4)** — a stateless protocol singleton (`src/CutoverVerifier.sol`, immutable
  `hats` + `orgRegistry`, ZERO storage) registered per chain in the Phase-0 wave
  (`addContractType("CutoverVerifier", …)`, deterministic CREATE3 address). Its single view-revert
  entrypoint `verify(orgId, authority, router, subjects[], expectedCounts[])` belongs as the LAST
  call of the cutover Executor batch: it `require()`s (a) `router.authorityOf(subject) == authority`
  for every subject (bind landed, no spoof), (b) `authority.paused() == false`, (c) per subject
  `memberCount == expectedCounts[i]` (generation-time counts baked into the batch — drift between
  generation and `announceWinner` reverts the whole batch, enforcing regenerate-before-cutover
  on-chain) AND `memberCount <= hats.hatSupply(subject)` via the CANONICAL Hats (enumeration-
  independent upper bound — closes the self-referential-parity gap), and (d) the admin (topHat) id
  resolves THROUGH THE ROUTER (`isWearerOfHat(orgExecutor, subjects[0])` + `viewHat(...).active`).
  `subjects[0]` MUST be the admin (topHat) id.
- **Seed acceptedAt = epoch 1 (C3, ruling R7)** — `seedMemberships` writes `acceptedAt = 1`, NOT
  `block.timestamp`. Seeded members are pre-existing, so `activeMemberSince = 1 <=` any in-flight
  proposal's `createdAt`, keeping those proposals votable across the cutover; post-cutover `claim()`
  members get `acceptedAt = now` and stay gated out of pre-claim proposals (the §4 anti-packing
  property survives).

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
