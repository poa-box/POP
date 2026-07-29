# PaymasterHub bug: `accountGasLimits` / `gasFees` unpacked in reverse of ERC-4337 v0.7

**Status:** live in the deployed PaymasterHub (Gnosis `0xdEf1038C297493c0b5f82F0CDB49e929B53B4108`,
and the Arbitrum hub if it shares the bytecode). Workaround in place on Test6 (see below). Not fixed.

**Severity:** medium. No fund theft and no bypass of the core allow/deny or budget accounting — but
every org-configurable *gas guardrail* (rule gas hints, fee caps) silently applies to the **wrong
field**, which (a) rejects legitimate operations (live incident, 2026-07-10) and (b) means the caps
an org thinks it set are **not actually enforced** against the intended field.

---

## Root cause

`src/interfaces/PackedUserOperation.sol` (`UserOpLib`) unpacks both packed gas words with the halves
reversed relative to the canonical v0.7 `UserOperationLib` (eth-infinitism EntryPoint
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`), which is also what viem / permissionless / Pimlico
produce on the wire:

| Word | Canonical v0.7 (EntryPoint, viem, bundlers) | This repo's `UserOpLib` |
|---|---|---|
| `accountGasLimits` | HIGH 128 = `verificationGasLimit`, LOW 128 = `callGasLimit` | HIGH = `callGasLimit`, LOW = `verificationGasLimit` (**swapped**) |
| `gasFees` | HIGH 128 = `maxPriorityFeePerGas`, LOW 128 = `maxFeePerGas` | HIGH = `maxFeePerGas`, LOW = `maxPriorityFeePerGas` (**swapped**) |

The `pack*` twins in the same lib are reversed identically, so anything that packs *and* unpacks
with this lib round-trips cleanly — which is exactly why the test suite never caught it (below).

The EntryPoint itself unpacks canonically for real gas accounting, so **execution gas limits and fee
handling on-chain are correct**; only the hub's *validation semantics* are wrong.

## Affected call sites (all in `src/PaymasterHub.sol`)

1. **`_validateRules` — line ~1785** (the live incident):
   ```solidity
   (, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);
   if (callGasLimit > rule.maxCallGasHint) revert GasTooHigh();
   ```
   The discarded first return is (per the swapped lib) the LOW half = the wire's **callGasLimit**;
   the value actually compared is the HIGH half = the wire's **verificationGasLimit**. So
   `rule.maxCallGasHint` caps *verification* gas, not call gas.

2. **`_validateFeeCaps` fees — line ~1879:** `caps.maxFeePerGas` is enforced against the wire's
   *priority* fee and `caps.maxPriorityFeePerGas` against the wire's *max* fee. Frequently masked
   because bundlers often set the two fees equal — but wrong whenever they differ.

3. **`_validateFeeCaps` gas — line ~1887:** `caps.maxCallGas` actually caps verification gas;
   `caps.maxVerificationGas` actually caps call gas. Consequence of note: an org that sets
   `maxCallGas` to bound execution gas is **not bounding it at all** — a sponsored op can carry an
   arbitrarily large `callGasLimit` (subject only to budget/`maxCost` math), accelerating budget
   drain within an epoch.

Also audit `src/PaymasterHubLens.sol` for parity: it mirrors validation for off-chain preflight
(`ruleFor` / eligibility / budget views) — any duplicated gas checks must be fixed identically or the
Lens will disagree with the hub.

## Why it was never caught

1. **Every pre-existing production rule has `maxCallGasHint = 0`** and the check is gated on
   `hint > 0` — so the buggy comparison never executed. Verified on-chain: QuickJoin's
   `registerAndQuickJoinWithPasskey` / `registerAndClaimHatsWithPasskey` rules on Test6 are
   `(0, allowed)`. Test6's `FeeCaps` are all zero too. The zk-email claim rules (2026-07) were the
   **first ever** with nonzero hints.
2. **The tests are self-consistently swapped.** Active tests build ops with the repo's own
   `UserOpLib.packAccountGasLimits(...)` (e.g. `test/PaymasterHubSolidarity.t.sol:1352`,
   `test/PasskeyPaymasterIntegration.t.sol:237`), so pack+unpack round-trips and the assertions pass
   while testing the wrong wire layout. Several fixtures even use symmetric values (`500k/500k`,
   `100k/100k`) that cannot distinguish a swap in principle. The comments at
   `PasskeyPaymasterIntegration.t.sol:1133-1169` ("verification=400k within 500k cap") show the
   tests *encode the swapped semantics as intended behavior*.
3. **The EntryPoint-fork integration tests are skipped** (`test/PaymasterHub*.t.sol.skip` — need an
   EntryPoint fork per CLAUDE.md), so no test ever ran a *canonically packed* op through
   `validatePaymasterUserOp`.

## Live incident (how it surfaced)

2026-07-10, Test6 zk-email one-step claim (`registerAndClaimByDomainWithPasskey`): Pimlico-packed op
with wire `verificationGasLimit = 1,500,000` (account deploy via initCode + P256 verification) and
wire `callGasLimit = 500,000`; rule hint `1,200,000`. Hub compared **1.5M** (mis-read as callGas)
against the 1.2M hint → `AA33 reverted 0xb2577430` (`GasTooHigh()`). The op's true callGas (500k) was
comfortably under the hint. (An earlier attempt failed at the eligibility gate, which runs before the
rule check, masking this until eligibility was fixed.)

## Workaround currently in place (must be revisited after the fix)

The 4 zk-email rule hints on Test6 were zeroed (check skipped, matching every other production rule)
via `Satellite.adminCall → PaymasterHub.setRulesBatch(TEST6_ORG, proxy×4, sels, allowed, hints=0)`,
tx `0x3d49384743fea1dc2d293a32a3ae00ac0d80bd1333fa8040ad6ae027c5203426` (Gnosis). Protection
meanwhile comes from the selector allowlist + hat eligibility + per-hat budget.

## Required fix

1. **Correct `UserOpLib`** in `src/interfaces/PackedUserOperation.sol`: both `unpack*` and both
   `pack*` helpers to canonical v0.7 order (HIGH = verificationGasLimit / maxPriorityFeePerGas).
   Simplest safe route: mirror eth-infinitism's `UserOperationLib.unpackUints` verbatim.
2. **Audit every call site** — the three in `PaymasterHub.sol`, plus `PaymasterHubLens.sol` parity,
   plus any test helpers that hand-pack.
3. **Regression tests that pack canonically, not with the repo helper.** Hardcoded `bytes32`
   vectors (or vectors generated by viem / the reference `UserOperationLib`), with **asymmetric**
   values (verification ≠ call, priority ≠ maxFee) so a swap can never pass. Cover: rule-hint
   boundary (call just under/over hint while verification is far above/below), all three fee-cap
   fields, and the fee pair with priority ≠ maxFee.
4. **Add at least one `validatePaymasterUserOp` test with a fully canonical op** (the skipped
   EntryPoint-fork suites exist for this — rename to `.t.sol` locally per CLAUDE.md, or add a unit
   test that calls `validatePaymasterUserOp` pranked as the EntryPoint with a hand-packed canonical
   op).
5. **Upgrade rollout** (the hub is beacon-upgradeable): canonical cross-chain pattern — probe the
   ImplementationRegistry for the next free version on BOTH chains (registry + CREATE2 surfaces, per
   CLAUDE.md §6), DD same-address deploys, `FOUNDRY_PROFILE=production` fork-sims before broadcast,
   Hub (Arbitrum) + Satellite (Gnosis) upgrade. Size note: the hub sits ~112 bytes under EIP-170 at
   `runs=1` — an order swap is size-neutral, but run `--sizes` anyway.
6. **After the upgrade:** restore meaningful hints on the 4 zk-email rules (they are currently 0),
   now expressed as true `callGasLimit` caps (e.g. 800k for plain claims, 1.2M for the
   register-and-claim variants), and reconsider org fee caps now that they'd bind the right fields.
7. **Process guard:** adopt the rule that wire-format encode/decode pairs are never validated only
   against the repo's own inverse helper — always include at least one fixture from the reference
   implementation or an independent client (viem output, spec test vectors).

## Reproduction

Any v0.7 UserOp built by a standard bundler stack with `verificationGasLimit > rule.maxCallGasHint ≥
callGasLimit` against a rule with a nonzero hint. The full failing op (calldata, gas fields,
paymasterData) from the live incident is preserved in the session notes of 2026-07-10; hint was
1.2M, wire verification 1.5M, wire callGas 500k.
