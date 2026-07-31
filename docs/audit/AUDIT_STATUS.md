# Audit Remediation Status

**Read this before re-auditing or re-checking any finding — it is the canonical per-finding disposition.**

- Full report: [`AUDIT_REPORT.md`](./AUDIT_REPORT.md) (84 merged findings from 126 raw; IDs below match its headings)
- Raw finder output: [`audit-findings.raw.json`](./audit-findings.raw.json) (126 items, global sequential ids — NOT the C/H/M/L ids)
- Coverage-gap analysis: [`AUDIT_COVERAGE_GAPS.md`](./AUDIT_COVERAGE_GAPS.md)

**Remediation shipped 2026-07** on the `hudsonhrh/protocol-security-audit` branch (PR #185), in seven workstreams (WS-A..WS-G), deployed to **Gnosis + Arbitrum** (CashOutRelay: **Base**).

**On-chain verification (2026-07-30):** all 14 beacon types on both chains point at their registry-latest implementation, and every implementation's runtime bytecode was verified against the local `FOUNDRY_PROFILE=production` build (PaymentManager additionally SHA-256 exact-matched). When re-verifying, ALWAYS compare against the **production** profile build — the default profile has the optimizer OFF and produces ~2× larger bytecode; comparing against it will falsely report stale deployments. Grep the source for exact function names before probing selectors (e.g. it is `distributionCounter()`, not `distributionCount()`).

## Deployed versions (identical impl addresses on both chains via CREATE3)

| Type | Version | Implementation |
|---|---|---|
| Executor | v4 | `0x387DE39Ee52B5206C6342172EbC60D78525445AC` |
| QuickJoin | v6 | `0x8c6b86E291272dC48F8A0679fa538e64e5b6bf0D` |
| ParticipationToken | v5 | `0x634e7905f0B3c6a8e412FE183e26064418374bce` |
| TaskManager | v6-era (untouched by audit) | `0x7833c4670C42dbCe1a7aB1BAB7e7Baf0A982ff57` |
| EducationHub | v2 | `0xfc19aDBc358e1A2B7f619584eCA7d50ae97048d0` |
| HybridVoting | v12 (deploy-time quorum, 2026-07-30) | `0x04477E365F6474D10FF2A526903cc9390c688c92` |
| DirectDemocracyVoting | v12 (deploy-time quorum, 2026-07-30) | `0x7D9009fC91d3F57FFceD58079Ea51fF90f56267c` |
| EligibilityModule | v6 | `0xB138504a06d1eD636EA2C485a7F055Ce79f9D37E` |
| ToggleModule | v2 | `0x808c9F60415CF6C4740F876362B3393A7917Fd50` |
| PaymentManager | v4 | `0x5126A721d043fa3Cd86008137ee2CCD20d3cedfb` |
| PaymasterHub (BeaconProxy, NOT UUPS) | v19 | `0xE398A26c044dbcfb12B4D1714c66029e7C84ADe7` |
| PasskeyAccount | v2 | `0xC16FCdFD434e333A6C53d7212531c5Bd55E5aD52` |
| PasskeyAccountFactory | v2 | `0xf281151f969265A01754F136813160856408037D` |
| OrgDeployer | v17 (deploy-time gov config; zk-email wiring) | `0xab8124C986Cf056dA23184913FA73352c8695615` |
| GovernanceFactory / AccessFactory | v17 (canVote class filter / token identity) | `0x7D1Acf8B90569ba5F2B17FA676bF63bEa4c4FB5D` / `0xCA52D4899d6eF0BFce48777fCeaAffc8F2a790b2` |
| ZkEmailInvites | latest | Gnosis `0x3b9329Da59BA13bE96685d36c5C56e2e78af5C1E` / Arbitrum `0xA6fbccec1a9425f924d3476bddCAcEF6903455D8` |

Hub proxies: Gnosis `0xdEf1038C297493c0b5f82F0CDB49e929B53B4108`, Arbitrum `0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11`.

## Status legend

- **FIXED** — code shipped and live on-chain.
- **PARTIAL** — one leg fixed, the rest deferred (issue linked).
- **ACCEPTED** — deliberate decision not to change code; reason given.
- **REJECTED** — a fix was implemented and then *reverted* because it broke intended behavior; do not re-implement without reading the reason.
- **DEFERRED** — tracked in a GitHub issue for later.
- **OPEN** — not addressed in this pass.

## Critical

| ID | Status | Disposition |
|---|---|---|
| C-01 | **FIXED** (WS-A) | Both `setTaskManager`/`setEducationHub` executor-gated for first AND subsequent calls; atomic deploy wires them via an Executor-owner one-shot bootstrap before ownership renounce. PT v5 + Executor v4 + OrgDeployer v16. Live eduHub-less orgs (DecentralPark) closed by the beacon upgrade. |

## High

| ID | Status | Disposition |
|---|---|---|
| H-01 | **FIXED** (WS-F), operational caveat | `executeData` gated to stored `bungeeExecutor` + owner (Base). ⚠️ `bungeeExecutor` is currently **unset** (address not recoverable on-chain), so the automated Bungee route is inoperative — owner-only for now. Tracked in #186. Close #176. |
| H-02 | **ACCEPTED** | EducationHub 1-of-256 answer gate stays; education payouts treated as low-stakes/trust-scoped. Revisit if payouts become material (see also M-01). |
| H-03 | **FIXED** (WS-D) | Eligibility-based claim gate: QuickJoin v6 + ZkEmailInvites reject **default-open** hats via the `HatOpenlyClaimable` probe; privileged roles ship vouch-gated (`defaults.eligible=false`) in all config templates. NOTE: the first attempt (a claimable-hats allowlist) was **reverted** — it broke vouch-first onboarding; do not resurrect it without reading that history. |
| H-04 | **FIXED** (WS-G) | M-of-N per-account threshold guardians (owner-managed set, quorum of distinct approvals, delay + cancel retained). PasskeyAccount v2. Close #177. |
| H-05 | **PARTIAL** (WS-B) | Executed-flag leg FIXED in HV v11 + DDV v11: `executed` set up-front as the in-flight reentrancy lock but **reset on failed execution**, so transient reverts are retryable (also resolves L-59). The DD-can-never-execute design flaw is DEFERRED → #178 (needs subgraph+frontend refactor). #140 related. |
| H-06 | **ACCEPTED (docs-only)** | Live-balance voting kept as an intended feature for the soulbound PT. Prominent warnings added in `HybridVotingCore` + `GovernanceFactory`: any custom `ERC20_BAL` class asset MUST be non-transferable. No snapshotting implemented; no on-chain soulbound check. Org-config review must enforce this. |

## Medium

| ID | Status | Disposition |
|---|---|---|
| M-01 | **OPEN** | EducationHub payout not capped to `ValidationLib.MAX_PAYOUT`. Bounded by creator-hat gating; matters more if H-02 stays accepted. |
| M-02 | **DEFERRED** → #182 | Vouch + strike reputation system (net-negative removes wearer) filed as a feature. |
| M-03 | **FIXED** (WS-D) | `setDefaultEligibility` and `configureVouching` revert when enabling default-eligible on a vouch+combine hat (both directions). |
| M-04 | **FIXED** (WS-C) | `withdrawOrgDeposit(orgId,to,amount)` (org-admin, bounded by deposited−spent, nonReentrant) + poaManager-gated solidarity/emergency withdraw. Hub v19 via PaymasterAdminLib. Close #179. |
| M-05 | **FIXED** (WS-C) | Solidarity draw reserved at validation time, reconciled in postOp (PaymasterFinanceLib delegatecall lib keeps hub under EIP-170). Closes #123. |
| M-06 | **FIXED** (WS-G) | Init calldata no longer embeds guardian/delay; `getAddress` is pure in `(credentialId,x,y,salt)`. **Known side effect:** all pre-upgrade counterfactual (never-deployed) addresses migrated. Analyzed 2026-07-30: zero affected users on either chain (every vouched wearer is either a deployed account or an active EOA; no funded stranded counterfactuals). Frontends must never cache `getAddress` results. |
| M-07 | **ACCEPTED** | `deleteProject` still strands non-terminal tasks. Ops rule: **never delete a project with active tasks**. TaskManager not upgraded this pass (shares BudgetLib). |
| M-08 | **FIXED** (WS-E) | `Distribution.creationBlock` appended (ERC-7201 append-only); finalize gate anchored to creation, not checkpoint. PaymentManager v4. |
| M-09 | **FIXED** (WS-A) | `RoleResolver` reverts `UnregisteredRole(roleIdx)` on hat-0 resolution. |
| M-10 | **FIXED** (WS-C) | Open `reinitializeProtocolAdmin` replaced by `setProtocolAdmin` `onlyPoaManager`; protocolAdmin set on both chains via Hub adminCall. Close #180. |
| M-11 | **FIXED** (WS-C) | Lens decodes `paymasterAndData`/subjectType before org checks; onboarding/org-deploy branches reachable. Lens redeployed both chains. Close #181. |
| M-12 | **FIXED** (WS-C) | `depositToEntryPoint(bytes32 orgId)` is org-operator-gated and routes through `_depositForOrg` (credits org accounting). |
| M-13 | **ACCEPTED** (documented centralization) | Mirror-mode upgrade authority is the intended model. Standing recommendation NOT yet done: move PoaManager/Hub/Satellite owner EOA to a multisig/timelock. |
| M-14 | **FIXED** (WS-B) | `MAX_POLL_HATS` cap in both HybridVoting and DDV `_initProposal` (vote ABI unchanged). |
| M-15 | **OPEN** | `announceWinner` still `whenNotPaused` — an emergency pause freezes settlement of decided proposals. Governance-gated liveness footgun. |
| M-16 | **FIXED** (WS-F) | `createDepositFromBalance` takes an explicit amount (bounded by available) and derives `requestHash` from a monotonic nonce (also covers L-48). |
| M-17 | **OPEN** (ops-mitigated) | Broadcast still splits fees evenly with no per-satellite isolation. Standard practice avoids it: per-chain `Satellite.upgradeBeaconDirect` / `adminCall` (see CLAUDE.md). |

## Low

**Fixed:** L-03, L-04, L-05 (WS-B) · L-11, L-53, L-60 (WS-A) · L-16, L-18, L-19, L-58 (WS-E) · L-26 (WS-D) · L-28, L-29, L-30, L-31, L-32, L-33, L-34, L-35, L-36, L-37 (WS-C, hub v19 + lens) · L-41 (WS-G, on-curve check on staged recovery key) · L-44, L-45, L-46, L-47, L-48 (WS-F, incl. full ERC-7201 + Ownable2Step migration with storage-survival sims) · L-59 (WS-B, executed-as-lock pattern).

**Rejected:**
- **L-02 (`TargetSelf` guard)** — implemented, then **reverted**. Governance proposals MUST be able to target the voting contract itself (`setConfig`/`setClasses`/quorum changes — every org's genesis config proposal does this). The guard bricked governance self-amendment. Do not re-add.

**Accepted:**
- **L-10** — Executor pause/sweep unreachable post-renounce; guardian-hat feature deliberately skipped. Pause is deploy-window-only (documented).

**Deferred:**
- **L-49** — Hyperlane message stall on re-registered version; mitigated by the `upgradeBeaconDirect` escape hatch used in practice.
- **L-50, L-57** — PoaManager-code fixes; PoaManager is **non-upgradeable**, not worth a core redeploy. Revisit at the next PoaManager migration.

**Open (not addressed this pass):** L-01, L-06, L-07, L-08, L-09, L-12, L-13, L-14, L-15, L-17, L-20, L-21, L-22, L-23, L-24, L-25, L-27, L-38, L-39, L-40, L-42, L-43, L-51, L-52, L-54, L-55, L-56, L-61, L-62, L-63. Mostly documentation/hardening or governance-gated footguns; L-12/L-13/L-14 are the TaskManager items (untouched this pass), L-39/L-42/L-43 the passkey-hardening leftovers, L-21/L-55 the squatting/front-running class.

## Informational (I-01 … I-20)

**None systematically addressed.** Individual instances may have been incidentally cleaned in touched contracts, but treat all twenty as open. I-03 (`require`-string sweep) is the largest cluster.

## Post-audit additions (not in the report)

- **UserOpLib v0.7 gas-word unpacking was reversed** (found post-audit by an external review agent): `accountGasLimits`/`gasFees` HIGH/LOW halves swapped, so rule gas hints and fee caps constrained the wrong fields. Fixed with hardcoded canonical test vectors; shipped with hub v19. See `docs/PAYMASTERHUB_GAS_UNPACK_BUG.md`.
- **zk-email role invitations** (PR #170, merged via #185): client-side Groth16 proving, on-chain verification, dormant-allowlist support; OrgDeployer v16 `deployFullOrgWithZkEmail` + `setZkEmailInfrastructure` wired on both chains.
- **M-06 counterfactual-address migration analysis** (2026-07-30): documented above.
- **Issues #176, #177, #179, #180, #181 are fixed and deployed but still OPEN on GitHub** — close them referencing this file.

## How to re-verify (agents: do this instead of ad-hoc probing)

```sh
./script/audit-verify.sh gate     # build + tests + sims
# Beacon sweep (per chain): PoaManager.getBeaconById(keccak256(type)) -> beacon.implementation()
#   must equal ImplementationRegistry.getLatestImplementation(type),
#   and its bytecode size/hash must match the FOUNDRY_PROFILE=production build.
# Gnosis PoaManager  0x794fD39e75140ee1545B1B022E5486B7c863789b  registry 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63
# Arbitrum PoaManager 0xFF585Fae4A944cD173B19158C6FC5E08980b0815 registry 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9
```
