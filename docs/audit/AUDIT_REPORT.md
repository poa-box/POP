# POP Protocol — Final Security Audit Report

## Executive Summary

**Protocol overview.** POP is a modular, on-chain organization (DAO) platform built on three layers: shared **Protocol** infrastructure (`PoaManager`, `PaymasterHub`, `ImplementationRegistry`, `OrgRegistry`, `UniversalAccountRegistry`); a **Deployment** orchestration layer (`OrgDeployer` + three factories) that atomically stands up a full org in one transaction; and per-org **Organization** modules (`Executor`, `DirectDemocracyVoting`, `HybridVoting`, `ParticipationToken`, `TaskManager`, `QuickJoin`, `EducationHub`, `PaymentManager`). It uses ERC-7201 namespaced storage, BeaconProxy + `SwitchableBeacon` upgradeability, Hats Protocol for role-based access control, ERC-4337 account abstraction with WebAuthn/P256 passkeys and a multi-tenant gas-sponsoring paymaster, a ZKP2P/Bungee-based fiat cash-out relay, and Hyperlane cross-chain messaging.

**Overall posture.** The protocol is architecturally coherent and, in its core governance and upgrade paths, largely defends itself through atomic deployment and disciplined CEI. However, this audit surfaced **one critical unauthenticated-mint vulnerability** that grants governance takeover of any org deployed without an EducationHub, plus a cluster of high-severity issues in **theft of in-flight cash-out funds**, **trivially-defeatable education rewards**, **caller-controlled hat minting**, and a **protocol-wide passkey-guardian single point of failure**. The recurring theme is *authorization delegated to configuration or to caller ordering* rather than enforced on-chain.

**Findings by severity:**

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 6 |
| Medium | 17 |
| Low | 40 |
| Informational / Optimization | 20 |
| **Total (merged)** | **84** (from 126 raw + 1 added in verification) |

*(H-06 was added by the orchestrator while verifying the coverage-gap analysis; it is a CONFIRMED live-balance/no-snapshot governance risk that the finder pass under-rated.)*

**Headline risks — fix these first:**

1. **[C-01] Unauthenticated `setEducationHub`/`setTaskManager` first-set → unlimited PT mint → governance takeover.** Any org deployed with `educationHubConfig.enabled = false` leaves `educationHub == address(0)` forever, and the first-set branch has no auth. An unprivileged attacker binds a malicious minter and mints unlimited voting power. A live org (DecentralPark on Gnosis) is already in this state. **Gate both setters to the executor.**
2. **[H-01] Permissionless `CashOutRelay.executeData` steals bridged USDC.** No `msg.sender` gate and no binding between delivered funds and the attacker-controlled `depositor`; anyone can redirect freshly-bridged USDC into their own ZKP2P deposit. **Restrict to the trusted Bungee executor / bind funds to depositor.**
3. **[H-02] EducationHub answers are brute-forceable on-chain (1-of-256).** The quiz gate provides zero protection; any member auto-completes every module and farms participation tokens. **Move to commit-reveal or signed attestation.**
4. **[H-04] Global passkey guardian is a protocol-wide single point of failure.** One compromised POA guardian key can recover-and-drain every `PasskeyAccount`. **Move to per-account/threshold guardians and harden recovery.**
5. **[H-03] `QuickJoin.claimHatsWithUser` forwards arbitrary caller-chosen hat IDs.** Combined with the shipped default of `defaultEligible=true` on privileged (e.g. executive) role hats, any username holder can self-mint a privileged hat. **Add a claimable-hats allowlist and ship privileged hats vouch-gated by default.**
6. **[H-06] HybridVoting reads token voting power LIVE with no snapshot.** The default non-transferable ParticipationToken is safe, but the factory permits an org to wire any transferable ERC20 as a voting-class asset, making governance flash-loan-capturable. **Snapshot balances at proposal creation, or hard-require soulbound class assets.**

A strong systemic recommendation: **enforce authorization invariants on-chain rather than delegating them to the frontend, to eligibility-module configuration, or to atomic-deploy ordering.** Several findings (C-01, H-03, M-06/M-07 eligibility footguns) are only "safe today" because of an off-chain assumption or a single deployment path.

---

## Critical

### [C-01] Unauthenticated first-set of `setEducationHub`/`setTaskManager` allows unlimited PT minting and governance takeover
**Severity:** Critical · **Verdict:** CONFIRMED · **Category:** Access control / minting
**Locations:** `src/ParticipationToken.sol:185-210` (setTaskManager 185-196, setEducationHub 198-210); mint guard `_checkTaskOrEdu` 157-162; `src/OrgDeployer.sol:494-497`; `src/factories/ModulesFactory.sol:112-113`; live reference `script/fixes/AddEducationHubDecentralPark.s.sol:42`
*(merges raw findings #1, #4, #60)*

**Bug.** `setEducationHub` and `setTaskManager` use a "first write is open" pattern: when the stored address is `address(0)`, **any caller** may set it with no authorization check; only subsequent overwrites require `msg.sender == executor`. `mint()` is gated by `_checkTaskOrEdu`, which authorizes `l.executor`, `l.taskManager`, **and** `l.educationHub` as fully-privileged minters, with no upper bound on mint amount. `initialize()` never sets `educationHub`, and `OrgDeployer` only calls `setEducationHub` when `educationHubConfig.enabled == true`. Any org deployed with EducationHub disabled therefore leaves `l.educationHub == address(0)` **permanently**, keeping the unauthenticated branch reachable forever.

**Exploit.** For such an org: (1) attacker deploys `MintBot`; (2) calls `token.setEducationHub(MintBot)` — passes, no auth; (3) `MintBot` calls `token.mint(attacker, 2**200)` — passes `_checkTaskOrEdu`. Because HybridVoting's `ERC20_BAL` class reads live `balanceOf(voter)` as weight (`src/libs/HybridVotingCore.sol:147`) and PT auto-delegates to self on mint (`ParticipationToken.sol:360-362`), the minted supply is immediately dominant voting power → the attacker passes arbitrary proposals through the Executor. This is confirmed reachable against a live Gnosis org (DecentralPark) per the team's own fix script (`AddEducationHubDecentralPark.s.sol:42`: *"ParticipationToken.educationHub == 0x0 -> first-call setEducationHub is open"*), and by `test/DeployerTest.t.sol:4858-4874`.

**Note on `setTaskManager`.** The `taskManager` arm is *not* currently reachable because `OrgDeployer.sol:494` always calls `setTaskManager` unconditionally in the atomic deploy tx. It remains a latent defense-in-depth hole: any future multi-tx or migration deploy path that leaves `taskManager == 0` reopens the identical critical bug.

**Fix.** Require `_msgSender() == l.executor` (or an executor-authorized bootstrap) for **both** the first and subsequent calls on **both** setters, and validate the input is non-zero. Wire the initial values inside `initialize` or via an executor-authorized bootstrap while the deployer transiently holds authority — do not rely on caller ordering. Add a test asserting an unprivileged caller cannot bind a minter when the value is unset.

---

## High

### [H-01] Permissionless `executeData` lets anyone redirect freshly-bridged USDC to an attacker-owned ZKP2P deposit
**Severity:** High · **Verdict:** CONFIRMED · **Category:** Access control / fund theft
**Locations:** `src/cashout/CashOutRelay.sol:121-158` (executeData), 213 (`depositTo(params.depositor,...)`); contrast owner-gated siblings at 218-221, 229, 256-261; integration flow `script/cashout/cashout-e2e.mjs:121,151-169,186-191`
*(raw #3)*

**Bug.** `executeData` has no `msg.sender` gate and no cryptographic binding between the delivered USDC and the caller-controlled `CashOutParams.depositor` (decoded from `callData`). The only guard is `available = balanceOf(this) - totalFailedAmount; require(available >= expectedAmount)`, which protects previously-reserved failed-deposit funds but *not* fresh, not-yet-assigned USDC. On success it creates a ZKP2P deposit **owned by `params.depositor`**. `requestHash` is attacker-chosen and used only for failed-deposit dedup. The team gated `completeCashOut` and `createDepositFromBalance` owner-only for exactly this front-running concern; `executeData` was left open, contradicting the contract's own threat model.

**Exploit.** The production Bungee `depositRoute` flow (per `cashout-e2e.mjs`) transfers USDC to the relay and only later triggers deposit creation in a *separate* transaction, creating a multi-minute window where victim USDC sits unassigned. During that window an attacker calls `executeData(requestHash=any, amounts=[victimAmount], tokens=[usdc], callData=encode(CashOutParams{depositor: attacker,...}))`; `available >= expectedAmount` passes and the deposit is minted to the attacker, who completes the P2P fill and receives the fiat. Loss scales with value in transit.

**Fix.** Restrict `executeData` to the trusted Bungee executor/inbox address stored in storage, or bind delivered funds to `depositor` via a signed/attested `requestHash` the relay verifies. At minimum gate it the same way `completeCashOut`/`createDepositFromBalance` are gated.

---

### [H-02] EducationHub correct answer is trivially recoverable on-chain — any member auto-passes every module and farms tokens
**Severity:** High · **Verdict:** CONFIRMED · **Category:** Cryptographic gating / reward abuse
**Locations:** `src/EducationHub.sol:206` (answerHash), 237-239 (completeModule + mint), 233/`onlyMember`; mint auth `src/ParticipationToken.sol:157-159`
*(raw #2)*

**Bug.** Module answers are stored as `answerHash = keccak256(abi.encodePacked(id, correctAnswer))` where `id` is public (emitted, returned by `nextModuleId`/`getModule`) and `correctAnswer` is a `uint8` (only 256 values). `completeModule` accepts an answer when `keccak256(abi.encodePacked(uint48(id), answer)) == m.answerHash`. There is no commit-reveal, no per-user salt, no secret entropy — recovering the answer is a 1-of-256 brute force computable off-chain instantly (or by reading `answerHash` from storage).

**Exploit.** Any member-hat holder iterates `a = 0..255`, matches `answerHash`, and calls `completeModule(id, a)` without reading any content; `l.token.mint(msg.sender, m.payout)` fires (EducationHub is an authorized PT minter). Repeated across every module, this is an unbounded participation-token farming vector that dilutes supply and governance/reward weight. See also [M-01] (payout can be set up to `type(uint128).max`), which makes each farmed mint catastrophic.

**Fix.** Do not derive the gate from a low-entropy on-chain hash. Use commit-reveal with a secret the contract never learns, or an executor/creator-signed EIP-712 completion attestation per `(learner, id)`, or off-chain attestation before mint.

---

### [H-03] `claimHatsWithUser` / `registerAndClaimHats` mint caller-controlled hat IDs — privilege escalation via default-eligible privileged hats
**Severity:** High · **Verdict:** PLAUSIBLE · **Category:** Access control / privilege escalation
**Locations:** `src/QuickJoin.sol:337-347, 356-377, 387-421`; `src/Executor.sol:141-152`; `src/EligibilityModule.sol:949-960`; default config `test/DeployerTest.t.sol:212, 224-243, 255-265`; `src/HatsTreeSetup.sol:250-251`; `script/org/DeployOrg.s.sol:267-269`
*(raw #5)*

**Bug.** `claimHatsWithUser` and the two `registerAndClaimHats*` functions forward an arbitrary caller-supplied `claimHatIds` array to `Executor.mintHatsForUser`, which calls `Hats.mintHat` for each. QuickJoin performs **no** check that the requested hats are org member hats — all authorization is delegated to the eligibility module. The Executor wears the org top hat, so it is admin of every hat; the *only* barrier is `EligibilityModule.getWearerStatus` returning eligible.

Critically, the shipped default builder sets `RoleEligibilityDefaults({eligible:true})` with vouching disabled for **every** role, including the privileged executive role (taskCreator/proposalCreator/tokenApprover bitmaps). Under that default, `getWearerStatus` returns `eligible=true` for all addresses.

**Exploit.** Attacker registers any username (permissionless), then calls `claimHatsWithUser([executiveHatId])`. QuickJoin forwards it; the Executor (admin) mints; the eligibility module returns `eligible=true` → the attacker self-mints a privileged hat with zero vouch.

**Nuance.** The verification split noted that the residual escalation is reachable independently via `EligibilityModule.claimVouchedHat` when a privileged hat is misconfigured `defaultEligible=true`; QuickJoin's path is actually *narrower* (requires a username). The real defect is twofold: (a) QuickJoin adds no defense-in-depth allowlist, and (b) the deploy defaults ship privileged hats as open-join. Both should be fixed.

**Fix.** Constrain `claimHatIds` to a governance-approved claimable-hats allowlist (like `memberHatIds`); ship privileged role hats `defaultEligible=false` + vouch-gated by default; add a test asserting a non-eligible caller cannot self-mint a privileged hat.

---

### [H-04] Global POA guardian is a protocol-wide single point of failure over all passkey accounts
**Severity:** High · **Verdict:** PLAUSIBLE · **Category:** Centralization / account takeover
**Locations:** `src/PasskeyAccount.sol:322-413` (initiateRecovery/completeRecovery), 146 (guardian init), 301 (setGuardian), 416 (cancelRecovery), 55 (MIN_RECOVERY_DELAY); `src/PasskeyAccountFactory.sol:244-255, 167-169`
*(raw #6)*

**Bug.** Each account's `l.guardian` is copied at `initialize()` from the factory's single global `config.poaGuardian`, so **one address is the guardian for every account**. `initiateRecovery` (onlyGuardian) stages an arbitrary attacker P256 key with only a non-zero-coordinate check; `completeRecovery` has **no access control** ("anyone can call after delay") and, once the ≥1-day delay elapses, deletes all existing credentials and installs the recovery key as the sole credential. A compromised or malicious global guardian can take over and drain every account whose owner is offline during the delay window.

**Exploit.** Guardian `G` (single key) is compromised → attacker calls `initiateRecovery` on victim account → owner does not `cancelRecovery` within `recoveryDelay` → any address calls `completeRecovery` → victim credentials wiped, attacker key installed → attacker signs UserOps and drains funds. Repeatable across all accounts.

**Mitigating facts.** Owners can opt out via `setGuardian(address(0))` (no zero-guard), and the delay + `RecoveryInitiated` event give a monitor-and-cancel window. `completeRecovery` being permissionless is by design (it only completes a guardian-authorized, cancellable request). The core risk is the *shared global guardian*, not the permissionless completion.

**Fix.** Make the guardian per-account and owner-chosen, or use a multi-guardian/threshold scheme; require the recovery credential to be pre-authorized; add an owner-configurable cooldown that survives the owner being offline. At minimum, hold the guardian key in a timelock/multisig and document the trust assumption prominently.

---

### [H-05] `DirectDemocracyVoting` is wired with execution machinery it can never use — passed proposals silently no-op forever
**Severity:** High (upgraded from raw Medium given governance-integrity impact) · **Verdict:** CONFIRMED · **Category:** Deployment correctness / governance
**Locations:** `src/OrgDeployer.sol:527` (setCaller = hybridVoting only), 724/487-488; `src/Executor.sol:91-98, 155-156` (single allowedCaller); `src/DirectDemocracyVoting.sol:424-444` (execute + AlreadyExecuted); `src/factories/GovernanceFactory.sol:284,297-298`; docs `DIRECT_DEMOCRACY_VOTING.md:34,582`
*(merges raw #14, #7)*

**Bug.** The Executor supports exactly **one** authorized caller, and `OrgDeployer.sol:527` sets it to `result.hybridVoting`. Yet `DirectDemocracyVoting` is deployed with a full execution surface (`ddInitialTargets`, per-option `IExecutor.Call[][]` batches, target validation) and calls `l.executor.execute(id, batch)`. Because DD is never authorized on the Executor, every DD proposal carrying an execution batch reverts `UnauthorizedCaller` inside the `try/catch` at `announceWinner` line 438 and only emits `ProposalExecutionFailed`.

Compounding this (raw #7): `announceWinner` sets `prop.executed = true` at line 425 **before** execution. So a "passed" DD proposal is permanently consumed — `AlreadyExecuted` blocks any retry — even though its on-chain effect never applied. This also makes execution failure *unrecoverable* for HybridVoting proposals whose winning batch reverts transiently (e.g. a momentarily paused target).

**Exploit / failure.** An org deployed expecting DD-governed treasury actions (the deployer explicitly passes `ddInitialTargets`) has those actions silently no-op forever. A poll appears "passed" (Winner emitted `valid=true`) while its effect never applies and can never be re-triggered. This directly contradicts the documented binding on-chain execution of DD.

**Fix.** Decide the model: either (a) make DD polling-only, remove its execution surface and `ddInitialTargets`, and revert at deploy if `ddInitialTargets` is non-empty; or (b) extend the Executor to authorize multiple callers (or a governance router) and register DD at deploy. Independently, do not set `executed = true` until after a successful `execute` (or leave it false on failure so a transient revert can be retried), for both DD and HybridVoting.

---

### [H-06] HybridVoting reads token voting power LIVE (no snapshot) — a transferable voting-class asset is flash-loan/borrow-vote-return exploitable
**Severity:** High (Critical for any org that configures a transferable ERC20 voting class) · **Verdict:** CONFIRMED (added during orchestrator verification of the coverage-gap analysis) · **Category:** Governance / economic
**Locations:** `src/libs/HybridVotingCore.sol:146-151` (`IERC20(cls.asset).balanceOf(voter)` read at vote time); `src/libs/HybridVotingProposals.sol` `_snapshotClasses` (snapshots class *config* only, not balances); `src/factories/GovernanceFactory.sol:335-346` (`_updateClassesWithTokenAndHats` only overrides `asset` when it is `address(0)` — a non-zero custom asset is kept as-is)

**Bug.** An `ERC20_BAL` voting class computes power as `IERC20(cls.asset).balanceOf(voter)` at the moment `vote()` executes. There is **no balance snapshot** at proposal creation (unlike ERC20Votes `getPastVotes`); the only thing snapshotted is the class configuration. The default deploy path wires the class asset to the non-transferable `ParticipationToken`, which is immune (balances can't be flash-acquired). But `GovernanceFactory._updateClassesWithTokenAndHats` only fills in the asset when the config passes `address(0)` — an org may configure an `ERC20_BAL` class backed by **any transferable ERC20**, and nothing enforces the asset be soulbound/non-transferable.

**Exploit.** For an org whose HybridVoting has a non-quadratic `ERC20_BAL` class over a transferable token `T`: attacker flash-borrows a large amount of `T`, calls `vote(proposalId, ...)` (power = live `balanceOf` = borrowed amount), then repays the flash loan — all in one transaction. Governance is captured for the cost of a flash-loan fee. Even without flash loans, a token holder can vote, transfer the tokens to a second hatted account, and vote again (double-spend of voting power across accounts within the same open proposal). Quadratic dampening does not prevent this (it only reshapes the curve; see [L-09]).

**Fix.** Snapshot token balances at proposal creation using ERC20Votes `getPastVotes(voter, snapshotBlock)` (ParticipationToken already extends ERC20Votes with block-number clock), or hard-require that every `ERC20_BAL` class asset is non-transferable (assert the asset reverts on transfer / is on an allowlist of soulbound tokens) and document the constraint. At minimum, `GovernanceFactory` should reject a non-zero custom asset unless it is explicitly attested soulbound.

---

## Medium

### [M-01] EducationHub module payout can be set up to `type(uint128).max`, bypassing the protocol `MAX_PAYOUT` cap
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Missing validation
**Locations:** `src/EducationHub.sol:197, 219` (payout check); `src/libs/ValidationLib.sol:19-20`; contrast `src/TaskManager.sol:644,735,1089`; mint `src/ParticipationToken.sol:295-299`
*(raw #8)*

`createModule`/`updateModule` validate payout only as `payout == 0 || payout > type(uint128).max`, accepting ~3.4e38 — far above the protocol-wide `ValidationLib.MAX_PAYOUT = 1e24` enforced everywhere else (`requireValidPayout96`). `completeModule` mints `m.payout` directly, and PT `mint` has no upper bound. A creator-hat wearer (privileged, but the invariant should still hold) sets an enormous payout; combined with [H-02] every member then farms ~3.4e38 tokens per completion. **Fix:** call `ValidationLib.requireValidPayout(payout)` in both functions.

### [M-02] A single marginal voucher can unilaterally burn a legitimately-seated vouched hat
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Governance / griefing
**Locations:** `src/EligibilityModule.sol:795-826` (revokeVouch → `setHatWearerStatus(..., false)`), claim path 868-886; test `test/DeployerTest.t.sol:2241-2255`
*(raw #9)*

When `combineWithHierarchy == false` and a vouched wearer has no specific rules, `revokeVouch` burns the wearer's hat as soon as the decremented count drops below quorum. Because a member becomes a wearer the instant quorum is *exactly* met, the voucher who supplied the marginal (quorum-th) vouch can eject a validly-seated member at any later time — for quorum=1, a single member is a unilateral seat-and-eject kill switch; for quorum N, any of the N vouchers can eject. No cooldown, no admin confirmation, no distinction between "still gathering vouches" and "already seated." **Fix:** only auto-burn while the wearer is *not yet* wearing the hat, or gate the auto-burn behind a config flag / superAdmin action.

### [M-03] Vouch-gated hat becomes open-join when `defaultEligible=true` — no on-chain guard couples the two settings
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Access control footgun
**Locations:** `src/EligibilityModule.sol:943-960` (`eligible = hierarchyEligible || vouchEligible`), claim 868-886; test `test/DeployerTest.t.sol:1981-2024`
*(raw #10)*

When vouching is enabled *and* `combineWithHierarchy=true`, eligibility is `hierarchyEligible || vouchEligible`. If `setDefaultEligibility(hat, true, true)` is later set, `hierarchyEligible` is true for every address, so the vouch quorum is fully bypassed and anyone can `claimVouchedHat`. The two calls (`configureVouching(combine=true)` and `setDefaultEligibility(true)`) are independently valid `onlySuperAdmin` writes; no on-chain check catches the dangerous combination — the codebase pushes prevention entirely to the frontend (test NatSpec explicitly says so). Governance-reachable (superAdmin is the Executor), so requires a proposal, but a legitimate-looking config change silently disables the gate. **Fix:** revert in `setDefaultEligibility`/`configureVouching` when enabling default-eligible on a vouch+combine hat, or make `getWearerStatus` ignore the hierarchy *default* (not per-wearer overrides) for such hats.

### [M-04] All deposited ETH is permanently locked in PaymasterHub — no `withdrawTo` path exists
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Fund lockup
**Locations:** `src/PaymasterHub.sol:503-586, 1177-1183`; `IEntryPoint.withdrawTo` declared but never called; regression evidence `test/PaymasterHub.t.sol.skip:620-636`
*(raw #11)*

Every ETH inflow (`depositForOrg`, `donateToSolidarity`, `registerAndConfigureOrg`, `depositToEntryPoint`) forwards to `EntryPoint.depositTo(address(this))`. The contract exposes **no** function that ever calls `withdrawTo`, and no `addStake`/rescue. Org deposits, the solidarity fund, and any over/mis-sent ETH can only leave as gas reimbursement for that org's own future UserOps. An org that winds down or over-funds cannot recover its ETH; the protocol cannot migrate the solidarity fund. An older impl *had* `withdrawFromEntryPoint` (per the skipped test), so this is a regression. Recoverable only via UUPS upgrade. **Fix:** add a guarded `withdrawOrgDeposit(orgId, to, amount)` (bounded by `deposited - spent`, callable by org admin) plus a PoaManager-gated solidarity/emergency withdraw.

### [M-05] Grace-period / solidarity-match limits bypassable within a single bundle (no validation-time solidarity reservation)
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Accounting / bundle safety
**Locations:** `src/PaymasterHub.sol:442-490` (`_checkSolidarityAccess`, view-only), 993-996 (postOp mutation); contrast reserving siblings `_checkBudget` 1924, `_checkOrgBalance` 705/721
*(raw #12)*

`_checkSolidarityAccess` only *reads* `solidarityUsedThisPeriod`/`solidarity.balance`; the mutation happens later in postOp. Unlike per-subject budgets and org deposits (which reserve `maxCost` at validation time for bundle safety), solidarity has no validation-time reservation. Under ERC-4337 the EntryPoint runs all validations before any postOp, so multiple UserOps for the same grace-period org in one bundle each see the same pre-postOp counter (e.g. 0) and pass, then each postOp charges solidarity — summing past `maxSpendDuringGrace` / tier `matchAllowance`. Distinct attacker-controlled subject accounts get independent per-subject budgets, so that reservation does not bound aggregate solidarity draw. **Fix:** reserve the projected solidarity portion at validation time and reconcile in postOp, mirroring `adjustBudget`.

### [M-06] Counterfactual passkey account address depends on mutable guardian/recoveryDelay — governance changes brick pre-funded accounts
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Determinism / fund lockup
**Locations:** `src/PasskeyAccountFactory.sol:276-302, 247-260, 365-371` (salt excludes config); `src/PoaManager`-gated `setPoaGuardian`/`setRecoveryDelay` 167/177; consumers `UniversalAccountRegistry.sol:163,285`, `QuickJoin.sol:245,320,413`
*(raw #13)*

`getAddress()`/`createAccount()` embed `config.poaGuardian` and `config.recoveryDelay` into the BeaconProxy init code, which is part of the CREATE2 preimage — yet `_computeSalt` does **not** include them. So `setPoaGuardian`/`setRecoveryDelay` change every not-yet-deployed account's predicted address. If governance rotates the guardian or delay after a user's address is computed/registered/funded but before deployment, the account deploys at a different address, orphaning the username→address mapping and stranding any ETH pre-sent to the counterfactual address. `_register` reverts `UsernameTaken` on the stale name, blocking self-heal. **Fix:** don't embed mutable global config in init code/salt — initialize accounts with no guardian/delay and have them pull lazily from the factory, or make these values immutable once live. `getAddress` must be a pure function of `(credentialId, pubKeyX, pubKeyY, salt)`.

### [M-07] `deleteProject` strands claimed tasks and their bounties (no active-task check)
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Correctness / fund lockup
**Locations:** `src/TaskManager.sol:440-470` (deleteProject), 888-912 (completeTask), 940-947 (cancelTask); test `test/TaskManager.t.sol:3842-3846`
*(raw #19)*

`deleteProject` does `delete l._projects[pid]` and clears project permission overrides without verifying the project has no non-terminal tasks; tasks still store `projectId = pid`. After deletion, `completeTask` is reachable only by the executor or a global-REVIEW-hat holder (project managers survive `delete` since it can't clear mappings, but project-scoped perm overrides are wiped), and `cancelTask` reverts (`BadStatus` for CLAIMED/SUBMITTED; and for UNCLAIMED it now reverts `SpentUnderflow` because `p.spent` was zeroed). A worker's submitted work and escrowed bounty can become permanently unreachable. **Fix:** block `deleteProject` when the project has any non-terminal task (track `activeTaskCount`), or require draining first.

*(Note: the raw finding's "over-mint past cap" leg was refuted — `delete` cannot resurrect a project id; the confirmed impact is stranded claimed work/bounties.)*

### [M-08] Distribution finalize timer is anchored to `checkpointBlock` (in the past), letting owner reclaim before claimants can claim
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Correctness
**Locations:** `src/PaymentManager.sol:139` (checkpoint must be past), 275-277 (finalize gate on `checkpointBlock + minClaimPeriodBlocks`), 269 (onlyOwner)
*(raw #20)*

`finalizeDistribution` gates on `block.number < dist.checkpointBlock + minClaimPeriodBlocks`, but `checkpointBlock` is required strictly in the past at creation and can legitimately be far in the past (a period boundary). Claimants can only start claiming at *creation*, so the real window is `minClaimPeriodBlocks - (creationBlock - checkpointBlock)`, which can be zero/negative. Owner-controlled (the Executor), and a malicious owner can already pass `minClaimPeriodBlocks=0`; the guard is nonetheless ineffective and a footgun for an honest owner using an old checkpoint. **Fix:** store creation block and anchor the gate to `creationBlock + minClaimPeriodBlocks`.

### [M-09] `resolveRoleBitmap` maps unconfigured roles to hat ID 0, producing a dead authorization entry instead of reverting
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Correctness / deploy footgun
**Locations:** `src/libs/RoleResolver.sol:40-64`; `src/OrgRegistry.sol:472-474` (getRoleHat returns 0, no bounds); `src/libs/HatManager.sol:24-42`; consumers in the three factories
*(raw #21)*

`resolveRoleBitmap` resolves each set bit via `getRoleHat(orgId, roleIdx)`, which returns 0 for any unregistered index with no revert; the zero is not filtered and is stored as an authorized voting/creator/member hat. Since Hats never mints hat 0, the entry is permanently dead (grants nobody) while `getHatCount`/views report a bogus non-zero count. An off-by-one or above-range bitmap bit deploys "successfully" with a silently broken role permission and no error. **Fix:** in `resolveRoleBitmap`/`resolveRoleHats`, revert `UnregisteredRole(roleIdx)` (preferred for a deploy path) or drop zero entries; optionally bound `getRoleHat` by the registered role count.

### [M-10] `PaymasterHub.reinitializeProtocolAdmin` has no access control — front-runnable seizure of `protocolAdmin`
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Access control / upgrade
**Locations:** `src/PaymasterHub.sol:240-243` (reinitializer(2), no auth), 1041/1242 (protocolAdmin bypass), 1037-1050 (adminBatchAddRules); `src/PoaManager.sol:93-106` (bare `upgradeTo`, no upgradeAndCall); deploy path `script/upgrades/UpgradeAndFixVouchRules.s.sol:204-214`
*(raw #15)*

`reinitializeProtocolAdmin(address)` is `reinitializer(2)` with **no** caller check and sets `protocolAdmin`, a privileged principal that bypasses the poaManager gate in `adminBatchAddRules` and `setSolidarityFee`. `PoaManager.upgradeBeacon` performs a bare `beacon.upgradeTo` with no post-upgrade delegatecall, so the reinit must be a separate tx; the production cross-chain upgrade path does not bundle it. On any chain where the new impl is live but the reinit is unconsumed, an attacker front-runs and permanently becomes `protocolAdmin` (one-shot reinitializer), then whitelists arbitrary `(target, selector)` rules across all registered orgs, redirecting sponsored gas. **Fix:** gate the function to poaManager/owner.

### [M-11] `PaymasterHubLens.wouldValidate` can never validate onboarding or org-deploy sponsorship (dead branches)
**Severity:** Medium · **Verdict:** CONFIRMED · **Category:** Correctness (off-chain predictor)
**Locations:** `src/PaymasterHubLens.sol:216-242` (OrgNotRegistered/OrgIdMismatch before onboarding/deploy branches); contrast `src/PaymasterHub.sol:619,633,646`
*(merges raw #16, #85 onboarding-branch leg)*

`wouldValidate` rejects with `OrgNotRegistered` (adminHatId==0) then `OrgIdMismatch` (decoded orgId != passed orgId) *before* the onboarding/org-deploy branches. Those branches require decoded orgId == `bytes32(0)`, but org 0 is never registered, so either check fires first — the branches are unreachable. The real hub validates onboarding/org-deploy *before* any org lookup, so for every op the hub would sponsor, `wouldValidate` returns false. Bundlers using it as a pre-flight get false negatives for two entire sponsorship classes. **Fix:** decode `paymasterAndData` first and branch on subjectType before the org-registration and orgId-equality checks, matching the hub's ordering.

### [M-12] `depositToEntryPoint` credits no org accounting — misleading "fund your org" bullet routes operator funds to the shared pool
**Severity:** Medium (documentation/UX; downgraded from raw's implication of loss) · **Verdict:** PLAUSIBLE · **Category:** Correctness / UX footgun
**Locations:** `src/PaymasterHub.sol:1177-1183` (shared-pool, self-documented), 503-569 (`depositForOrg` credits org); docs `PAYMASTER_HUB.md:591` (misleading operator bullet)
*(raw #22)*

`depositToEntryPoint` forwards `msg.value` to the EntryPoint without touching `org.deposited`/`periodStart`/`numActiveOrgs` — by design it is a shared-pool top-up (the contract's own NatSpec says so). The defect is the misleading operator-permission doc bullet ("Deposit to EntryPoint (fund paymaster)") plus the function name, which invites an operator to use it as org funding; the org gets no credit while the ETH subsidizes the common pool. **Fix:** correct the docs to direct org funding to `depositForOrg`, and/or rename/remove `depositToEntryPoint` or have it call `_depositForOrg(orgId, msg.value)`.

### [M-13] PoaManager owner can push an arbitrary implementation to every Mirror-mode org with no allowlist, timelock, or storage-layout check
**Severity:** Medium (centralization; not a code bug) · **Verdict:** PLAUSIBLE · **Category:** Centralization / upgrade risk
**Locations:** `src/PoaManager.sol:93-106`; `src/SwitchableBeacon.sol:82-84` (Mirror reads live); cross-chain entry `src/crosschain/PoaManagerHub.sol:64,77`
*(raw #23)*

`upgradeBeacon` only checks non-zero/has-code, then `beacon.upgradeTo(newImpl)`; every Mirror-mode org's `SwitchableBeacon` reads this global beacon live, so a new impl becomes the delegatecall target for all mirror-mode orgs in one tx — no allowlist, no timelock, no layout compatibility check. In production the owner is a single EOA. This is the intended BeaconProxy model (orgs can pin to Static mode to opt out), so it is a documented centralization fact rather than a code defect, but it is the single largest authority concentration. **Fix (hardening):** require the owner to be a multisig/timelock; enforce a timelock on `upgradeBeacon` so mirror-mode orgs get a warning window to `pinToCurrent()`; consider validating `newImpl` against an allowlist. Documented as a trust assumption in the centralization section below.

### [M-14] Unbounded `pollHatIds` makes every restricted-poll `vote()` O(n), enabling gas-griefing
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** DoS / gas
**Locations:** `src/DirectDemocracyVoting.sol:330-339, 378-392` (linear scan), 334 (unused O(1) `pollHatAllowed`), `onlyCreator` 229-236; same pattern `src/libs/HybridVotingCore.sol:42-53`
*(raw #17)*

`createProposal` accepts `hatIds` with no length cap (unlike `MAX_OPTIONS`/`MAX_CALLS`), and `vote()` linearly scans `pollHatIds` calling `isWearerOfHat` per entry until a match. A creator placing the real allowed hat last among thousands of fabricated IDs forces every legitimate voter to pay for the full cross-contract scan, potentially exceeding the block/paymaster gas limit and reverting all votes. An O(1) `pollHatAllowed` mapping is already populated but ignored by `vote()`. Requires a creator-hat (privileged) caller, bounding severity, but it's a real gas footgun and sponsored-gas drain. **Fix:** add `MAX_POLL_HATS`, and have `vote()` consult the existing `pollHatAllowed` mapping directly.

### [M-15] `announceWinner` is blocked while paused — executor-controlled majority can freeze settlement of decided proposals
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Governance liveness
**Locations:** `src/HybridVoting.sol:288-296` (whenNotPaused), 178-184 (pause onlyExecutor); mirror in `src/DirectDemocracyVoting.sol:414-419`
*(raw #18)*

`announceWinner` carries `whenNotPaused` and is the only finalization/execution path. Pausing after voting closes but before finalization prevents the outcome from ever being announced/executed until unpause. Pausing is executor-gated (requires a passed proposal), so it's not an unprivileged escalation — a governance majority could already swap the module — but a legitimate emergency pause also freezes settlement of all in-flight decided proposals, a recoverable liveness hazard. **Fix:** remove `whenNotPaused` from finalization, or add an explicit non-pausable finalize path; pausing should stop new votes, not read-out/execution of completed ones.

### [M-16] `createDepositFromBalance` sweeps the entire relay balance for one depositor, co-mingling unrelated deliveries; weak `block.timestamp` requestHash
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Accounting (owner-only footgun)
**Locations:** `src/cashout/CashOutRelay.sol:260-277` (owner-only, `available` = full balance), 282-295 (recoverFailed), 317-327 (emergencyRecover)
*(raw #24)*

`createDepositFromBalance` takes no amount parameter and sweeps `available = balanceOf - totalFailedAmount` (the entire free balance) into a single `params.depositor` on both success and failure paths — unlike `executeData`/`completeCashOut` which scope to a specific request. In a multi-tenant relay, if user A's undeposited USDC coexists with user B's, an owner call for B assigns A's funds to B (into B's escrow, or B's `recoverFailed` claim). `requestHash = keccak256(depositor, block.timestamp)` can also collide same-block (`RequestHashAlreadyFailed`). Owner-only, so an operational footgun, not an unprivileged exploit; the "permanently strand" framing was overstated (reverts leave funds retryable). No unit test covers this function. **Fix:** pass an explicit amount (bounded by `available`) and derive `requestHash` from a monotonic nonce/per-delivery identifier.

### [M-17] Cross-chain broadcast: one reverting/underfunded satellite blocks all cross-chain upgrades and rolls back the local upgrade
**Severity:** Medium · **Verdict:** PLAUSIBLE · **Category:** Availability / cross-chain
**Locations:** `src/crosschain/PoaManagerHub.sol:193-208` (`fee = msg.value/count`, no `quoteDispatch`, no per-satellite try/catch), local-before-broadcast 71/73/94/96/115/117
*(raw #79)*

`_broadcast` splits `msg.value` evenly and dispatches to all active satellites in a single loop with no per-satellite error isolation; any one dispatch revert (underpayment on a costlier IGP, a misconfigured domain) reverts the whole tx. Because the home-chain `upgradeBeacon` runs *before* `_broadcast` in the same tx, a remote fee issue also rolls back the intended local upgrade. Owner-only, self-recoverable via `removeSatellite`/retry (excess refunded), and local-only escape hatches exist (`upgradeBeaconLocal`), so bounded, but a single bad domain blocks all cross-chain propagation. **Fix:** quote each satellite's fee via `quoteDispatch` and dispatch the exact amount per satellite; wrap each dispatch in try/catch (emit failure) so one bad domain isn't fatal; decouple the local upgrade from the broadcast.

---

## Low

The following are lower-impact correctness, robustness, DoS-under-privileged-misconfig, and defense-in-depth issues. Grouped by theme for brevity; each cites file:lines.

**Voting / governance**
- **[L-01]** Live (non-snapshot) eligibility lets a passed proposal mint voting hats that swing concurrently-open proposals; docs advertise "one person one vote" without this caveat. `src/DirectDemocracyVoting.sol:373-392,438-442`. (raw #25) **Fix:** document live-eligibility; snapshot eligibility at creation if concurrent proposals are used.
- **[L-02]** `announceWinner`/Executor do not block the voting contract itself as an execution target; a whitelisted self-call can invoke executor-gated `setConfig`/`pause`/`unpause` (contradicts documented `TargetSelf` protection). `src/DirectDemocracyVoting.sol:430-442,197-226`; `VotingErrors.TargetSelf` defined but unused. (raw #26) **Fix:** revert `TargetSelf` when `batch[i].target == address(this)`.
- **[L-03]** `HybridVotingCore.vote` uses `require(..., "Class raw overflow")` string instead of `VotingErrors.Overflow()`. `src/libs/HybridVotingCore.sol:101`. (raw #27)
- **[L-04]** `MIN_DURATION` diverges: facade constant = 1, enforced library value = 10; docs advertise 1 min. Durations 1–9 revert `DurationOutOfRange`. `src/HybridVoting.sol:22` vs `src/libs/HybridVotingProposals.sol:16`; docs `HYBRID_VOTING.md:497`. (raw #28)
- **[L-05]** `HybridVotingLens.getProposalEndTimestamp` always returns 0; `isProposalActive` is a tautology (`x || !x`) → always true for existing proposals, reverts for nonexistent. `src/lens/HybridVotingLens.sol:12-36`; no on-chain consumers. (merges raw #29, #55) **Fix:** implement against a real `endTimestamp` getter or delete.
- **[L-06]** `HybridVotingProposals._validateTargets` only checks call count, not targets; docs claim a target allowlist that exists nowhere (Executor also has no allowlist). `src/libs/HybridVotingProposals.sol:77-135`; `src/Executor.sol:155-173`; docs `HYBRID_VOTING.md:220-221,461-474`. (raw #30) **Fix:** restore an allowlist or correct the docs.
- **[L-07]** Cross-class threshold is measured against total configured governance power; an abstaining configured class caps reachable score below 100%, making moderate thresholds unreachable and surprising vs docs. `src/libs/VotingMath.sol:342-370`. (raw #56) **Fix:** document precisely (or renormalize over participating classes).
- **[L-08]** A voter can saturate an option's per-class `classRaw` to `uint128` max, permanently reverting further votes onto that option — only reachable under the discouraged transferable-asset config. `src/libs/HybridVotingCore.sol:98-103`. (raw #57) **Fix:** store per-option tallies as `uint256` or clamp instead of reverting.
- **[L-09]** Quadratic ERC20_BAL over a transferable asset lets a whale split holdings across colluding hatted accounts for `sqrt(k)` net power gain (defeats quadratic dampening) — reachable only under the discouraged transferable config. `src/libs/HybridVotingCore.sol:146-151`. (raw #58) **Fix:** require/assert soulbound assets for quadratic classes; document.

**Executor**
- **[L-10]** After `renounceOwnership` (done at deploy), all seven `onlyOwner` functions — including `pause`/`unpause`/`sweep` — are permanently unreachable; there is no live pause/guardian mechanism despite the advertised safety net. `src/Executor.sol:176-269`; `src/OrgDeployer.sol:561`. (raw #31) **Fix:** gate `pause`/`unpause`/`sweep` on a persistent guardian hat, or remove them to avoid a false sense of a pause.
- **[L-11]** `sweep()` uses `.transfer()` (2300-gas stipend) which reverts for contract recipients (Safe/AA wallets). Largely moot given [L-10], but a latent recovery bug. `src/Executor.sol:190-195`. (raw #32) **Fix:** use `.call{value:}`.

**TaskManager**
- **[L-12]** Applicants can never refresh their application (`taskApplications[id][applicant]` written once, never cleared; `applyForTask` reverts `AlreadyApplied`), so after a v6 takeover a reviewer can only approve against a stale application hash. `src/TaskManager.sol:978-996,1008-1025`. (raw #33) **Fix:** allow `applyForTask` to overwrite an existing hash, or clear per-applicant entries on approval/cancel.
- **[L-13]** `taskApplicants` enumeration array is emptied on approval while the approvable set (persisted hashes) is not, so `TaskManagerLens.TASK_APPLICANTS`/`TASK_APPLICANT_COUNT` report 0 for tasks that still have approvable applicants. `src/TaskManager.sol:1022,1541-1548`; `src/lens/TaskManagerLens.sol`. (raw #34) **Fix:** keep the array consistent with the mapping.
- **[L-14]** `EDIT_FULL` post-claim edits let a hat holder inflate a claimed task's payout to the project cap and re-point the bounty to a funded token before review, with no forced re-approval. `src/TaskManager.sol:711-764`. (raw #59) **Fix:** reset SUBMITTED→CLAIMED (re-approval) when `EDIT_FULL` changes payout/bounty post-claim, or restrict those fields to PM/executor. *(Reachable only via a governance-granted `EDIT_FULL` hat — treat as an economic-authority grant in role guidance.)*

**EducationHub**
- **[L-15]** `updateModule` cannot correct a wrong answer — `answerHash` is immutable after creation; the only remedy (remove+recreate) orphans progress under a new id. `src/EducationHub.sol:211-223`. (raw #35) **Fix:** add a `correctAnswer` param that recomputes `answerHash`, or document immutability.
- **[L-16]** `setToken` can repoint the reward token with no minter-wiring check, silently bricking `completeModule` until fixed (executor-only footgun). `src/EducationHub.sol:167-171`. (raw #113) **Fix:** verify `IParticipationToken(newToken).educationHub() == address(this)`.

**PaymentManager**
- **[L-17]** ETH distribution claims use a raw `call` to `msg.sender`; a contract leaf that reverts on receive cannot claim (funds later swept to owner). `src/PaymentManager.sol:199-204,253-258`. (raw #36) **Fix:** pull-payment escrow or WETH fallback; note canonical `PasskeyAccount` has `receive()` so only arbitrary custom contract members are affected.
- **[L-18]** `finalizeDistribution` lacks `nonReentrant` (unique among value-moving externals) though it makes an external ETH call to `owner()`; CEI is respected today so no live bug. `src/PaymentManager.sol:269-294`. (raw #61) **Fix:** add `nonReentrant`.
- **[L-19]** Opting out blocks claims on distributions where the address was *already allocated* (global mutable flag vs documented "future distributions"); recoverable by opting back in before finalize. `src/PaymentManager.sol:181,235`. (raw #62) **Fix:** remove opt-out from the claim path or snapshot per-distribution.
- **[L-20]** Fee-on-transfer / rebasing payout tokens desync `totalCommitted` (nominal), risking last-claim reverts and blocked `withdraw`. Owner chooses the token. `src/PaymentManager.sol:144-151`. (raw #63) **Fix:** document standard-ERC20-only, or measure balance deltas.

**QuickJoin / UniversalAccountRegistry**
- **[L-21]** Username registration is permissionless with no reservation; a griefer can front-run a sponsored `registerAndQuickJoin` (reverts `UsernameTaken`, wasting relayer gas) or squat desirable usernames for free. Victim can retry with a different name (nonce not consumed on revert). `src/UniversalAccountRegistry.sol:97-99,362-373`. (raw #64) **Fix:** rate-limit/fee/allowlist, or treat an already-correctly-registered `(user,name)` as success in QuickJoin.
- **[L-22]** `quickJoinNoUserMasterDeploy` mints member hats without requiring a username, unlike every other join path, breaking the implicit member⇒username invariant (master/executor-only). `src/QuickJoin.sol:463-466,200-211`. (raw #65) **Fix:** document the relaxation or add the `NoUsername` guard.
- **[L-23]** Permissionless `registerAndQuickJoin*` gate membership solely on signature consent + eligibility module; orgs assuming they control the QuickJoin entrypoint are mistaken (control is in the eligibility module / paymaster). `src/QuickJoin.sol:264-284,295-328`. (raw #116) **Fix:** document, or add an optional onboarding-open flag / allowlist hat.

**Eligibility / Toggle / HatsTreeSetup**
- **[L-24]** `whenNotPaused` is applied inconsistently: many bulk/batch eligibility and hat-minting mutators (`setBulkWearerEligibility`, `batchSetWearerEligibility`, `batchMintHats`, `configureVouching`, `resetVouches`, …) are *not* paused, undermining the emergency freeze (superAdmin-only). `src/EligibilityModule.sol:262-317` and listed sites. (raw #37) **Fix:** apply `whenNotPaused` uniformly.
- **[L-25]** `vouchFor` with `membershipHatId=0` and `combineWithHierarchy=false` makes a hat permanently un-vouchable (hat 0 is never worn); recoverable by superAdmin. `src/EligibilityModule.sol:725-741`; `configureVouching` no validation. (raw #38) **Fix:** reject `membershipHatId==0` when quorum>0 and combine=false.
- **[L-26]** `ToggleModule.setEligibilityModule` has no zero-address check, no event, and can be overwritten repeatedly; whatever address it holds gains org-wide hat toggle authority (executor/governance-only post-deploy). `src/ToggleModule.sol:131-136`. (merges raw #39, #83) **Fix:** reject `address(0)`, emit an event, add a getter, consider settable-once.
- **[L-27]** `roleApplicants` array grows unboundedly and is never pruned; withdraw/claim clear the mapping but not the array, and re-applies push duplicates → dirty off-chain data and growing `eth_call` cost (no on-chain iterator exists). `src/EligibilityModule.sol:894-918`. (raw #40) **Fix:** index-map + swap-and-pop on withdraw/claim, or drop the array and rely on events.

**PaymasterHub / paymaster libs**
- **[L-28]** postOp fallback (`postOpReverted`) skips the 1% solidarity fee for funded grace orgs, diverging from the normal path (which collects it). `src/PaymasterHub.sol:813-828,915-923,942-1000`. (raw #41) **Fix:** charge the fee for funded orgs in the fallback, matching `_updateOrgFinancials`.
- **[L-29]** `adminBatchAddRules` indexes `targets[i]`/`selectors[i]` by `orgIds.length` with no array-length check and no zero-address guard (unlike `_setRulesBatch`) → opaque OOB panic or silent truncation, and can write an allowed rule at `target==address(0)`. `src/PaymasterHub.sol:1037-1050`. (merges raw #42, #52) **Fix:** add `ArrayLengthMismatch` + per-entry `ZeroAddress` checks.
- **[L-30]** Solidarity fee can push `org.spent > org.deposited`, creating phantom debt that a later deposit silently repays first; the fallback path avoids this by zeroing the fee, the main tier path doesn't. `src/PaymasterHub.sol:955-992`. (raw #43) **Fix:** cap the fee charge at remaining `depositAvailable`.
- **[L-31]** `PaymasterGraceLib.solidarityFee` is dead code that already diverges from both inline fee computations (unconditional grace-zero vs the funded-grace-org-pays-fee behavior); a future refactor wiring it in would silently break the funded-grace fee invariant. `src/libs/PaymasterGraceLib.sol:24-33`. (raw #44) **Fix:** delete it or make grace-zeroing a caller-passed flag; correct its NatSpec.
- **[L-32]** `clampedDeduction`'s `deducted` return is discarded while `solidarityUsedThisPeriod` is bumped by the full requested amount → over-counts usage when the fund is short (and silently absorbs the shortfall). `src/libs/PaymasterPostOpLib.sol:27-34`; call sites `src/PaymasterHub.sol:834,839,868`. (raw #45) **Fix:** increment by `deducted`, not the requested cost; telemeter the shortfall.
- **[L-33]** Non-standard `execute` `dataOffset` leaves the outer selector `0xb61d27f6` as the rule key; if an org whitelists `(target, 0xb61d27f6)`, an inner call bypasses per-selector allowlisting. Fail-closed by default (no such rule normally exists). `src/PaymasterHub.sol:1840-1860`. (raw #67) **Fix:** revert on non-standard offset instead of falling back to the outer selector.
- **[L-34]** `parseExecuteCall` reads a full 32-byte inner-selector word while only bounds-checking a single byte, permitting an OOB calldata read of the inner selector from adjacent handleOps calldata (duplicated inline at `PaymasterHub.sol:1852-1856`). No confirmed privilege bypass (account decodes the same calldata; other whitelist fields are in-bounds). `src/libs/PaymasterCalldataLib.sol:43-50`. (raw #68) **Fix:** require `dataStart + 4 <= callData.length` (or `+32`).
- **[L-35]** `PaymasterHubLens.wouldValidate` mis-predicts `executeBatch` UserOps (checks one synthetic `(sender, batchSelector)` rule instead of per-inner-call rules the hub enforces). `src/PaymasterHubLens.sol:354-363`. (raw #54) **Fix:** mirror `_validateBatchRules` (AND each inner `(target, innerSelector)`).
- **[L-36]** `wouldValidate` skips onboarding/org-deploy/fee-cap gates the real validator enforces, returning false positives/negatives for those paths. `src/PaymasterHubLens.sol:211-284`. (merges raw #85 remainder, #100) **Fix:** mirror the real gates or document non-authoritative scope.
- **[L-37]** Lens epoch math (`epochStart + epochLen`, `epochsPassed * epochLen`) is done in `uint32` and can revert a view near the 2106 ceiling or for an operator-chosen large `epochStart`. `src/PaymasterHubLens.sol:120-127,277`. (raw #111) **Fix:** widen to `uint256` before add/multiply (as `isInGracePeriod` does).

**PasskeyAccount / WebAuthn / P256**
- **[L-38]** `abi.decode` of an attacker-controlled malformed signature reverts instead of returning `SIG_VALIDATION_FAILED`, violating the IAccount contract (no auth bypass; EntryPoint treats revert as failed op). `src/PasskeyAccount.sol:199-213`. (raw #46) **Fix:** bounded parse returning the failure code.
- **[L-39]** `P256Verifier.verify` returns `false` indistinguishably whether the signature is invalid or *no verifier is deployed* on the chain (staticcall to a codeless address returns success + empty data); fail-closed but silently bricks passkey auth on an unprovisioned chain. `src/libs/P256Verifier.sol:137-155`. (merges raw #47, #73) **Fix:** deploy-time invariant asserting precompile-or-fallback presence; add on-curve `isValidPublicKey` validation at registration for defense-in-depth.
- **[L-40]** `signCount` is written during validation and enforced strictly increasing, breaking bundling/reordering for counter-enabled authenticators (later-count op mined first strands earlier ops). Inert for signCount=0 platform passkeys; no fund loss/replay (userOpHash/nonce protects). `src/PasskeyAccount.sol:216-230`. (raw #69) **Fix:** rely on the EntryPoint nonce for replay protection; treat signCount as a soft clone heuristic.
- **[L-41]** Recovery installs a key with no on-curve validity check; a guardian mistake (off-curve coords) could wipe the sole credential — but recoverable by the guardian re-initiating with a fresh valid key. `src/PasskeyAccount.sol:322-391`. (raw #71) **Fix:** validate `isValidPublicKey` in `initiateRecovery`.
- **[L-42]** WebAuthn verification never checks `rpIdHash` or `origin`; assertions from any relying party verify (only the challenge binds). Residual risk is cross-context/phishing signing; replay otherwise blocked by userOpHash/nonce. `src/libs/WebAuthnLib.sol:110-150`. (raw #72) **Fix:** pin `authenticatorData[0:32]` to an expected `rpIdHash`; optionally verify `origin`.
- **[L-43]** `MAX_CREDENTIALS` (10) is unenforced when the factory config returns >10; PoaManager can set up to 255, inflating unbounded recovery/removal loops. `src/PasskeyAccount.sol:248-251,553-565`; `src/PasskeyAccountFactory.sol:187`. (raw #70) **Fix:** clamp effective max to `min(configValue, MAX_CREDENTIALS)` or bound `setMaxCredentials`.

**CashOutRelay (upgrade/storage)**
- **[L-44]** CashOutRelay omits `_disableInitializers()` (only upgradeable contract in `src/` that does) — the bare implementation can be initialized. Attempted brick/hijack is blocked by OZ v5 `onlyProxy` on `upgradeToAndCall` and EIP-6780 on cancun, and impl storage is separate from proxy funds, so no fund freeze — but a clear hard-rule violation and defense gap. `src/cashout/CashOutRelay.sol:20-313`. (raw #81) **Fix:** add `constructor(){ _disableInitializers(); }` and add to the impl-cannot-be-initialized test suite.
- **[L-45]** CashOutRelay uses sequential storage + `uint256[44] __gap` — the only `__gap` in `src/`, violating the ERC-7201-exclusive rule, and it's absent from the CI upgrade-safety baseline. Current layout is self-consistent; risk is a future mid-list insertion corrupting `totalFailedAmount`/`owner` with no CI guard. `src/cashout/CashOutRelay.sol:96-115,340`. (merges raw #53, #82, #124) **Fix:** migrate to ERC-7201 `Layout` and add to `upgrades/baseline`.
- **[L-46]** CashOutRelay hand-rolls `address public owner` (not OZ Ownable), with `owner` set only in `initialize` and no `transferOwnership` — a compromised/lost owner key is unrecoverable, and with UUPS the owner can also upgrade the impl. `src/cashout/CashOutRelay.sol:104`. (raw #109) **Fix:** adopt `Ownable2StepUpgradeable` (transfer + event).
- **[L-47]** `executeData` deposits the claimed `amounts[0]` rather than the actual available balance (its own comment says otherwise); bridge over-delivery leaves untracked surplus recoverable via [H-01] or `emergencyRecover`. `src/cashout/CashOutRelay.sol:135-143`. (raw #80) **Fix:** align to comment or document `amounts[0]` authoritative and reconcile surplus.
- **[L-48]** `createDepositFromBalance` requestHash from `block.timestamp` can collide (same-block same-depositor) → `RequestHashAlreadyFailed` revert. Covered by [M-16]; see its fix. `src/cashout/CashOutRelay.sol:260-277`. (raw #24 sub-issue)

**Cross-chain / registries**
- **[L-49]** Cross-chain beacon upgrade can permanently stall the Hyperlane message if the `(type, version)`/impl is already registered — `handle()` re-reverts `VersionExists`/`SameImplementation` with no try/catch/idempotency. Recoverable locally via `upgradeBeaconDirect` with a fresh version; no lost funds. `src/crosschain/PoaManagerSatellite.sol:65-71`. (raw #75) **Fix:** try/catch in `handle()` (emit `UpgradeSkipped`) or make `upgradeBeacon` idempotent.
- **[L-50]** `updateImplRegistry` doesn't verify PoaManager owns the new registry; pointing at an unowned registry silently breaks all future `upgradeBeacon`/`addContractType` until re-pointed (owner-only, self-healing). `src/PoaManager.sol:41-46`. (raw #76) **Fix:** require `registry.owner() == address(this)` (try/catch).
- **[L-51]** `registerHatsTree` re-registration with a shorter role array leaves stale `roleHatOf` indices (no length tracking/truncation) that resolvers/subgraph read as authoritative; also re-points the metadata-admin topHat fallback silently (executor-only). No on-chain consumer re-resolves post-deploy today, so latent. `src/OrgRegistry.sol:445-466`; resolvers `src/libs/RoleResolver.sol:28,57`. (merges raw #77, #122) **Fix:** make single-shot or clear indices ≥ new length; split topHat updates from role-hat updates; emit an event on metadata-admin change.
- **[L-52]** `registerOrgContract` accepts arbitrary unvalidated proxy/beacon/moduleOwner mappings (only non-zero + `TypeTaken`), which off-chain consumers trust as canonical; executor can additively poison the namespace with rogue typeIds. Existing types can't be clobbered; executor-gated. `src/OrgRegistry.sol:264-308`. (raw #78) **Fix:** validate the EIP-1967 beacon slot / beacon code, or restrict post-bootstrap type registration to a curated set; document off-chain consumers must verify on-chain.

**Deployment**
- **[L-53]** Paymaster auto-whitelist targets the wrong contract for `updateOrgMetaAsAdmin` (`registryAddr` = UniversalAccountRegistry, but the function is on OrgRegistry), so gasless org-metadata edits are never sponsored. `src/OrgDeployer.sol:923-928`. (raw #48) **Fix:** register that rule against `address(l.orgRegistry)`.
- **[L-54]** Initial wearers for non-voting roles are made eligible but never minted the hat and never emitted (both HatsTreeSetup mint loops and `_collectInitialWearers` gate on `canVote`), silently dropping configured distribution for e.g. a non-voting CONTRIBUTOR role. `src/OrgDeployer.sol:622-655`; `src/HatsTreeSetup.sol:257,270`. (raw #49) **Fix:** decouple minting/emitting from `canVote`, or revert on `canVote=false` + non-empty distribution.
- **[L-55]** Permissionless `deployFullOrg` with caller-chosen `orgId` allows front-running/squatting a predictable (keccak-of-name) orgId; a legitimate team can be permanently blocked (no eviction). `src/OrgDeployer.sol:365-400`; `src/OrgRegistry.sol:149`. (raw #74) **Fix:** derive `orgId = keccak256(msg.sender, deployerAddress, salt)` or gate behind a registrar.
- **[L-56]** `HatsTreeSetup.setupHatsTree` has no access control; safe only because the deploy flow is atomic and the (shared) contract holds no persistent superAdmin. A future split-transaction path would let an attacker capture the topHat. `src/HatsTreeSetup.sol:65-92`. (raw #117) **Fix:** one-shot `used` guard or restrict caller to the factory; document the atomicity requirement.

**Misc**
- **[L-57]** `upgradeBeacon` calls `registry.registerImplementation` without the `address(registry)!=0` guard that `addContractType` has, giving an opaque revert if the registry is unset. `src/PoaManager.sol:93-103`. (raw #50) **Fix:** mirror the guard or add an explicit error.
- **[L-58]** `registerImplementation(setLatest=false)` on a new type creates it with `latest` unset, so `getLatestImplementation` reverts `TypeUnknown` for a registered type (owner-reachable via `adminCall`; current callers always pass `true`). `src/ImplementationRegistry.sol:70-112`. (raw #51) **Fix:** force `latest = vId` on first registration, or add a distinct `NoLatestSet` error.
- **[L-59]** `HybridVoting.announceWinner` lacks the `nonReentrant` guard its DirectDemocracy sibling uses; the `_lock` slot is declared/initialized but never wired. CEI holds (`executed` set before execute) so not exploitable today, but a defense-in-depth regression and a misleading dead field. `src/libs/HybridVotingCore.sol:156-231`; `src/HybridVoting.sol:73`. (raw #84) **Fix:** wire `_lock` into a `nonReentrant` modifier or remove it and document CEI reliance.
- **[L-60]** `mintHatsForUser` loops over an unbounded caller-supplied `hatIds` with no cap and ignores `mintHat`'s bool return (though Hats `mintHat` reverts rather than returning false, and callers pass small governance-set arrays). `src/Executor.sol:141-152`. (raw #112) **Fix:** add a length cap; check the return for parity with `EligibilityModule`.
- **[L-61]** `getHatArray` copies an unbounded storage array to memory and `hasAnyHat`/`findHatIndex` scale linearly with no cap on hat-array length — a privileged (executor) self-grief that can inflate authorization-check gas and push sponsored ops over budget. `src/libs/HatManager.sol:91-93,76-84`. (merges raw #66, #99) **Fix:** cache length in `findHatIndex`; enforce a `MAX_HATS` cap on the add path.
- **[L-62]** `changeUsername` has no username reservation but does not consume the nonce on `UsernameTaken` revert; covered by [L-21]. `src/UniversalAccountRegistry.sol:97-99,362-373`. (raw #64 sub-issue)
- **[L-63]** A single per-user `claimed` flag with a shared merkle root forces one-leaf-per-address semantics: a duplicate-address tree silently drops the second allocation, and an over-sum tree lets earlier claimants drain the cap (later claimants hit `OverClaimed`). Owner-only distribution creation; correctness depends fully on the off-chain builder with no on-chain/documented guardrail. `src/PaymentManager.sol:180-196`. (raw #114) **Fix:** document the invariant; consider per-leaf index + claimed bitmap.

---

## Informational / Optimization

- **[I-01]** Doc/code mismatch: threshold uses `>=` (code, tested) but the DD design doc specifies strict `>` and renames `thresholdPct`→`quorum`. `src/libs/VotingMath.sol:246,249`; docs `DIRECT_DEMOCRACY_VOTING.md:165-169`. (raw #86) **Fix:** reconcile doc to code.
- **[I-02]** Dead code: `VotingMath.meetsThreshold` has no callers and can drift from `pickWinnerMajority` (it hardcodes strict-majority, omitting the `hi==0` guard and non-strict path). `src/libs/VotingMath.sol:206-212`. (raw #87) **Fix:** remove or mark deprecated + test.
- **[I-03]** `require()`-with-string violations of the custom-errors-only hard rule (larger bytecode; discards sub-call revert data): `Executor.configureVouching/batchConfigureVouching/setDefaultEligibility` (`src/Executor.sol:220-268`), `UniversalAccountRegistry.registerBatch` (`:190`), `EligibilityModule`/`ToggleModule` reentrancy/pause/mint checks (`src/EligibilityModule.sol:128,135,393,555,565,580,873,876,883,901`; `src/ToggleModule.sol:93`), `CashOutRelay.withdrawETH` message-less `require(ok)` (`:333`). (merges raw #88, #97, #98, #107, #108) **Fix:** replace with custom errors; preserve/bubble sub-call revert data (e.g. `CallFailed`).
- **[I-04]** `Executor.execute` forwards batch `value` with no up-front total-vs-balance check, so value-bearing proposals fail late (atomic rollback holds; insufficient-ETH is caught as opaque `ProposalExecutionFailed`). `src/Executor.sol:161-171`. (raw #89) **Fix:** optional pre-sum + distinct `InsufficientBalance()` error.
- **[I-05]** Permission/existence checks in several TaskManager entrypoints run against project id 0 for non-existent task ids before the `NotFound` revert (no state change today; latent footgun if a future refactor mutates between the checks). `src/TaskManager.sol:340-341,845,890-892,925,941,1009`. (raw #90) **Fix:** do the `id < nextTaskId` check first.
- **[I-06]** `createAndAssignTask`/`updateTask` omit the `uint128` overflow guard on PT `spent` that `_createTask` has; effectively unreachable given the 1e24 per-payout cap and `uint48` task-id ceiling. `src/TaskManager.sol:1096-1098,742-744`. (raw #91) **Fix:** extract a shared spend-update helper.
- **[I-07]** ParticipationToken's ERC20Votes checkpointing + auto-self-delegation is dead weight given live-`balanceOf` voting (no in-repo `getPastVotes` consumer); adds gas to every mint. Plausibly forward-compat. `src/ParticipationToken.sol:355-386`. (raw #92) **Fix:** drop ERC20Votes if only live voting is intended, or document live-balance semantics.
- **[I-08]** Long-string `setName` doesn't zero orphaned trailing data slots when shrinking; safe (reads are length-prefixed, inputs bounded). `src/ParticipationToken.sol:271-291`. (raw #93) **Fix:** zero trailing slots or document.
- **[I-09]** `updateOrgMeta`/`registerOrg` are event-sourced only — no on-chain name/metadata storage or getter, and no `metadataHash` validation; correctness depends on a healthy indexer. `src/OrgRegistry.sol:183-220`. (raw #105) **Fix:** persist `metadataHash` (append-only) or document event-sourcing explicitly.
- **[I-10]** Redundant storage/gas: `contractOf.proxy` duplicates `proxyOf` per registration (~1 extra cold SSTORE each, ~200k on a 10-contract batch). `src/OrgRegistry.sol:291-302,362-368`. (raw #106) **Fix:** serve the existence check from `beacon != 0` and drop the duplicate proxy write.
- **[I-11]** `getOrgIds` returns the whole unbounded array (owner-only writes); `orgCount()` + `orgIds(i)` already allow pagination. `src/OrgRegistry.sol:62,405-411,440-442`. (raw #123) **Fix:** add `getOrgIdsRange`; document event-based enumeration for scale.
- **[I-12]** `execute`/`executeBatch` bubble raw returndata via assembly (returnbomb/error-spoofing surface); self-inflicted (auth is EntryPoint/self), `Executed` event emits full data/result (gas-heavy). `src/PasskeyAccount.sol:443-481`. (raw #119) **Fix:** cap bubbled revert length; hash/omit event payloads.
- **[I-13]** clientDataJSON base64url challenge decoding is malleable (4 valid final chars decode identically; non-alphabet bytes skipped) → non-canonical signed messages; harmless today (nonce/userOpHash dedup), latent if signature/clientDataJSON is ever used as a uniqueness key. `src/libs/WebAuthnLib.sol:378-438`. (raw #120) **Fix:** reject non-alphabet chars and require canonical 43-char encoding (re-encode and byte-compare).
- **[I-14]** `estimateVerificationGas`/`isPrecompileAvailable` use a chainid heuristic and a fixed test vector that can misreport; advisory only (not in the security path), currently no in-repo callers. `src/libs/P256Verifier.sol:253-294`. (raw #121) **Fix:** treat as non-authoritative; prefer probing at deploy.
- **[I-15]** `SwitchableBeacon.implementation()` Mirror mode adds an external staticcall per proxy delegatecall (~one extra hop per tx protocol-wide); inherent to the auto-follow feature. `src/SwitchableBeacon.sol:81-90`. (raw #104) **Fix:** document per-call cost; Static mode (`pinToCurrent`) is cheaper for stability-focused orgs.
- **[I-16]** `EligibilityModule` and `ToggleModule` constructors lack the `@custom:oz-upgrades-unsafe-allow constructor` annotation (both correctly call `_disableInitializers()`); the repo's CI upgrade-safety tooling does not parse this annotation, so no live impact. `src/EligibilityModule.sol:201-203`; `src/ToggleModule.sol:61`. (raw #125) **Fix:** add for consistency.
- **[I-17]** Micro-optimizations (no correctness impact): `findHatIndex` reloads `hatArray.length` per iteration (`src/libs/HatManager.sol:76-84`, raw #99); `clearHatArray` zeroes only the length slot leaving stale words + forgoes `delete` refund (`src/libs/HatManager.sol:109-116`, raw #118); redundant `_layout()`/`_msgSender()` loads in EducationHub modifiers (`src/EducationHub.sol:141-156`, raw #94); `claimMultiple` duplicates `claimDistribution` inline and re-reads loop length (`src/PaymentManager.sol:225-262`, raw #95/#96); redundant `abi.encodePacked` buffer in P256 verify hot path (`src/libs/P256Verifier.sol:133-137`, raw #103); unbounded credential/recovery loops + heavy `Executed` payload (`src/PasskeyAccount.sol:368-409`, raw #102); `calculateMatchAllowance` recomputes `minDeposit*2` and has imprecise tier NatSpec (`src/libs/PaymasterGraceLib.sol:44-66`, raw #101); TaskManagerLens decodes unused `id`/`applicant` locals and re-encodes fields (`src/lens/TaskManagerLens.sol:68-138`, raw #110).
- **[I-18]** `claimMultiple` is all-or-nothing: one failing entry reverts the whole batch, discarding valid claims (single `claimDistribution` remains available). `src/PaymentManager.sol:225-262`. (raw #95) **Fix:** optional best-effort mode or document all-or-nothing.
- **[I-19]** `changeUsername`/`deleteAccount` re-lowercase an already-normalized stored name to derive the release hash — redundant but correct; couples correctness to the "stored names are always normalized" invariant. `src/UniversalAccountRegistry.sol:214,231`. (raw #115) **Fix:** hash the stored name directly with a comment, or add an invariant test.
- **[I-20]** `TaskManagerLens.PROJECT_INFO` returns hardcoded `isManager=false` (a documented stub; existence is signaled by revert, not the field). `src/lens/TaskManagerLens.sol:107-111`. (raw #126) **Fix:** rename/update the comment, or compute a real `isManager` with caller context.

---

## Systemic Themes

1. **Authorization delegated off-chain or to configuration, not enforced on-chain.** The most dangerous findings share this shape: [C-01] first-set setters trust caller ordering; [H-03] and [M-03] delegate all hat-mint authority to eligibility-module config with the *frontend* as the only guard against dangerous combinations; [L-52]/[L-78] trust off-chain consumers of unvalidated registry data. Several of these are "safe today" only by accident of the atomic deploy path or a shipped default. **Recommendation: add on-chain allowlists/invariants (claimable-hats allowlist, executor-gated setters, reject dangerous vouch+default-eligible combos) rather than relying on the UI or single deployment path.**

2. **Cross-chain and shared-singleton trust concentration.** [H-04] (one global passkey guardian), [M-13] (owner pushes impl to all mirror-mode orgs), [M-10]/[M-17]/[L-49] (cross-chain admin front-running, broadcast-atomicity, stalled Hyperlane messages) all concentrate protocol-wide power in a single key or a single unisolated code path.

3. **Missing validation-time reservation / late failure.** [M-05] (solidarity not reserved during validation, bundle bypass), [L-30]/[L-32] (fee/deduction accounting drift), [I-04] (value-forwarding fails late) all stem from reading-not-reserving or checking-after-the-fact.

4. **Off-chain predictors diverging from on-chain logic.** The PaymasterHub/HybridVoting Lenses ([M-11], [L-05], [L-35], [L-36], [L-37]) repeatedly mis-predict or return placeholder/tautological results, because parser and validation logic is duplicated rather than shared. **Recommendation: extract shared decode/validation libraries used by both hub and lens.**

5. **Consumed-once / append-only state that desyncs.** [L-12]/[L-13] (application hashes vs enumeration array), [L-27] (roleApplicants never pruned), [L-51] (stale roleHatOf indices), [I-08]/[L-45] (storage slots not cleared) — state written but never reconciled on the removal path.

6. **Rounding / cap / bound edge cases.** [M-01]/[I-06] (payout caps inconsistent across modules), [L-07]/[L-08] (threshold and uint128 saturation), [L-37]/[M-05] (uint32/accounting bounds).

7. **Project convention drift.** `require`-with-string ([I-03]), `__gap` + sequential storage in CashOutRelay ([L-45]), missing `_disableInitializers` ([L-44]), missing OZ annotations ([I-16]) — all deviate from the codebase's own hard rules, and CashOutRelay in particular sits outside the CI upgrade-safety baseline.

---

## Notes on Centralization & Trust Assumptions

These are design facts the team should acknowledge and document, even where they are intended.

- **PoaManager owner (single EOA in production).** Owns every global `UpgradeableBeacon`. Via `upgradeBeacon` ([M-13]) it can, in one transaction with no timelock, allowlist, or storage-layout check, replace the logic of every **Mirror-mode** org module — enabling arbitrary drain/mint/brick across all such orgs. Mirror mode is a *voluntary* trust delegation; orgs that pin to Static mode opt out. Cross-chain, the same owner (Hudson's EOA `0xA6F4…b2c9`) owns `PoaManagerHub` (Arbitrum) and `PoaManagerSatellite` (Gnosis). **Strong recommendation: this key must be a multisig/timelock, and Mirror mode should be documented as a live trust delegation.**

- **Executor authority.** Each org's `Executor` is the DAO execution layer; only the single authorized voting contract can call `execute`, and ownership is renounced at deploy — which also permanently disables `pause`/`unpause`/`sweep` ([L-10]). A governance majority controlling the Executor already holds sweeping power (swap modules, reconfigure eligibility, set metadata admin), so several "medium/low" findings gated behind the Executor ([M-03], [M-15], [L-14], [L-51]) are governance-authorized footguns, not unprivileged exploits — but they are surprising couplings worth surfacing to operators.

- **Paymaster admin (`protocolAdmin` + `poaManager`).** Can whitelist arbitrary `(target, selector)` sponsorship rules across all registered orgs. `protocolAdmin` is set via an **unauthenticated one-shot reinitializer** ([M-10]) that must be fixed. Org deposits and the solidarity fund are currently **unrecoverable** ([M-04]) absent an upgrade.

- **Passkey global guardian.** A single factory-wide `poaGuardian` can recover (and thereby seize) every `PasskeyAccount` whose owner is offline during the recovery delay ([H-04]). This is the single largest user-funds trust concentration in the account-abstraction layer.

- **CashOut relay owner.** A hand-rolled, immutable, single `owner` (no transfer, no two-step — [L-46]) controls `completeCashOut`, `createDepositFromBalance`, `emergencyRecover`, `withdrawETH`, and UUPS upgrades. A compromised key cannot be rotated. `executeData` being permissionless ([H-01]) is the more urgent issue here.

- **Off-chain indexer dependence.** Org names/metadata ([I-09]), the canonical `(orgId → contracts)` registry ([L-52]), and applicant enumeration ([L-13]) are event-sourced or read from mutable/append-only on-chain state that has no authoritative on-chain getter or is trivially poisonable by the executor. Consumers must not treat these as trusted without on-chain verification.