I have a comprehensive picture. Here is my prioritized gap analysis.

---

# Audit Coverage Gap Analysis — POP Protocol

The 126 findings are broad, but several **high-impact classes** are missing or under-examined. Prioritized, concrete follow-ups:

## P0 — Core economic/timing attacks not covered

1. **HybridVoting ERC20_BAL voting power is read LIVE, not from a block snapshot** — `src/libs/HybridVotingProposals.sol:137` `_snapshotClasses` snapshots only the *class config*, while `src/libs/HybridVotingCore.sol:147` reads `IERC20(cls.asset).balanceOf(voter)` at vote() time. If any voting class asset is a *transferable* ERC20 (not PT, which is non-transferable), this is a **flash-loan / borrow-vote-return governance capture**: acquire tokens, vote, return in the same block. The existing "whale split sqrt" finding is a weaker sibling; the flash-loan primitive on a non-quadratic ERC20_BAL class is far more severe and unlisted. Check whether OrgDeployer ever wires a transferable token as a class asset.

2. **PT mint-timing governance manipulation across TaskManager → ParticipationToken → HybridVoting** — no finding connects the three. `ParticipationToken.approveRequest`/TaskManager task payout mint PT (`src/ParticipationToken.sol:322`, `src/TaskManager.sol`), and HybridVoting reads PT balance live. A CONTRIBUTOR-hat holder who also approves PT requests can mint voting power to allied addresses *mid-proposal* (before announceWinner) to swing an outcome. The listed "live hat eligibility" finding covers hats, not token-balance minting. Verify: is there any snapshot/lock between proposal creation and vote tally for PT-class power?

3. **EOADelegation is essentially unaudited** — `src/EOADelegation.sol` appears in zero findings. Concrete checks: (a) `validateUserOp` recovers `address(this)` as owner during 7702 delegation — but if this contract is ever CREATE3-deployed and called *directly* (not via 7702 delegation), `address(this)` is the deployed contract, not an EOA, so `execute`'s `msg.sender==address(this)` self-call guard combined with a signature that recovers to the contract could be abused; confirm the deployed-standalone instance can't validate any UserOp. (b) `executeBatch` (line 93) has **no per-call value/target restriction and is reachable via EntryPoint** — paymaster batch-rule validation (`_validateBatchRules`) must be the only gate; confirm PT sponsorship can't be tricked. (c) prefund `call` return ignored (line 65) — griefing surface.

## P1 — Paymaster ↔ account calldata contract gaps

4. **executeBatch validation-time gas DoS in PaymasterHub** — `src/PaymasterHub.sol:1794` `_validateBatchRules` does `abi.decode(callData[4:], (address[],uint256[],bytes[]))` into memory over **attacker-controlled, unbounded arrays** inside `validatePaymasterUserOp`. ERC-4337 validation has strict gas limits; a large/nested batch either (a) blows the paymaster's validation gas (bundler-side griefing / reputation damage to the paymaster), or (b) reverts on malformed ABI. Neither the DoS nor the malformed-decode revert is in the findings (only the *Lens* mis-prediction is). Check for a batch-length cap and decode-revert handling.

5. **EOADelegation ↔ PaymasterHub selector contract** — `PaymasterCalldataLib.parseExecuteCall`/`_extractTargetSelector` assume the `0xb61d27f6` envelope and specific batch selectors `0x47e1da2a`/`0x18dfb3c7`. Confirm EOADelegation's `execute`/`executeBatch` selectors **exactly match** these — if EOADelegation's `executeBatch(address[],uint256[],bytes[])` selector differs, sponsored 7702 batches either bypass rule-checking (fall through to `target=userOp.sender` in `_extractTargetSelector:1865`) or fail. This inter-contract selector coupling is undocumented and unverified.

## P2 — Cross-chain & deployment (thin coverage)

6. **PoaManagerHub fee-splitting and refund** — `src/crosschain/PoaManagerHub.sol:196` `fee = msg.value / count` and dispatches `fee` per satellite; integer division dust and `preBalance` accounting (line 70/93/114) mean over/under-payment. Check: does an underquoted `msg.value` silently under-fund some satellites (partial broadcast) while succeeding? Only "single reverting satellite bricks broadcast" is listed; the **fee-division underpayment** is not.

7. **DeterministicDeployer CREATE3 cross-chain address divergence** — `src/crosschain/DeterministicDeployer.sol` is `onlyOwner`. If owner differs per chain, or the deployer is deployed at different addresses, CREATE3 addresses diverge — bricking the "same address everywhere" invariant EOADelegation/PasskeyAccount rely on. No finding checks the deployer-owner / deployer-address consistency assumption.

8. **BudgetLib underflow/cap sentinel confusion** — `src/libs/BudgetLib.sol` — `cap=0` means DISABLED but `addSpent` with `cap=0` and `delta>0` reverts `BudgetExceeded` (since `newSpent > 0`), while `cap=UNLIMITED` skips the check. Verify every caller (TaskManager project budgets, PaymasterHub) distinguishes disabled-vs-unlimited correctly — a mis-set `cap=0` on a live project silently blocks all spend (self-DoS). Not covered.

## P3 — Under-examined contracts/capabilities

9. **PaymasterHub `_postOpFallback` solidarity accounting** (`src/PaymasterHub.sol:790+`) — the fallback recomputes `solidarityFee` and can push `org.spent` past `org.deposited` (phantom debt). One low finding mentions phantom debt generally; verify the *fallback* path specifically doesn't double-charge or mis-credit `solidarity.balance` when `depositAvailable < actualGasCost + fee` (the partial branch). This is the reverting-postOp path — highest-value to get right and least-tested.

10. **ModulesFactory owner = executor for every module** (`src/factories/ModulesFactory.sol:172-195`) — every module beacon owner is `params.executor`, and Executor renounces ownership post-deploy. Cross-check with the listed "Executor owner-only functions become unreachable" finding: this means **module beacon ownership is also stranded** the moment Executor renounces — no module can ever be pinned to Static beacon mode or emergency-paused. Confirm whether any module needs post-deploy owner action that renounce permanently blocks.

11. **PoaManager beacon ownership / adminCall reachability** — `PoaManagerHub.adminCall` (line 104) calls `poaManager.adminCall`. Verify `PoaManager.adminCall`'s target allowlist — an owner-only `adminCall` that can call *any* target including its own beacons is a governance-capture single point (related to the listed "arbitrary impl push" but the `adminCall` arbitrary-target primitive itself isn't enumerated).

12. **Lens contracts as trusted subgraph source** — `DirectDemocracyVotingLens.sol` has **zero findings** (only Hybrid/TaskManager/Paymaster Lenses were reviewed). Given the subgraph trusts Lens output, check `DirectDemocracyVotingLens` for the same tautology/dead-return bugs found in `HybridVotingLens` (always-active, always-zero-timestamp).

## P4 — Documented-but-unverified

13. **HybridVoting three-library shared-slot invariant** (per CLAUDE.md) — `HybridVotingCore`/`Config`/`Proposals` share `keccak256("poa.hybridvoting.v2.storage")`. No finding verifies the three `Layout` structs are byte-identical; a field-order drift between libs is a silent storage-corruption bug. Diff the three struct definitions.

14. **P256 precompile availability at 0x100 vs fallback verifier** — findings note "fallback absence → silent total failure" but not the **osaka-vs-cancun divergence**: production targets cancun (no guaranteed P256 precompile on all L2s). Verify PasskeyAccount signature verification actually works on the *deployment* chains (Base/Optimism/Arbitrum Sepolia) under cancun, not just osaka test EVM — a documented gotcha never validated against a real target chain.

**Key files with the least coverage:** `src/EOADelegation.sol` (0 findings), `src/libs/BudgetLib.sol` (0), `src/crosschain/DeterministicDeployer.sol` (0), `src/lens/DirectDemocracyVotingLens.sol` (0), `src/factories/ModulesFactory.sol` (0 module-wiring findings).