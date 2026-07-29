#!/usr/bin/env bash
#
# audit-verify.sh — one-command validation for the protocol-security-audit branch.
#
# Runs the full local gate (fmt + build + size ceiling + tests) and every
# production-profile fork sim for the 8 audit workstreams (WS-A..WS-G + the
# QuickJoin seed), then prints a PASS/FAIL summary. It NEVER broadcasts —
# `plan` prints the ordered mainnet runbook for you to run by hand.
#
# Usage:
#   script/audit-verify.sh              # gate + all sims (default)
#   script/audit-verify.sh gate         # fmt + build + --sizes + full test suite only
#   script/audit-verify.sh sims         # all fork sims only
#   script/audit-verify.sh sim WS-C     # one workstream's sims (WS-A|WS-B|WS-C|WS-D|WS-E|WS-F|WS-G|SEED)
#   script/audit-verify.sh probe        # re-probe that every chosen version is still FREE on-chain
#   script/audit-verify.sh plan         # print the ordered broadcast runbook (no execution)
#   script/audit-verify.sh clean        # remove this script's isolated out-verify-*/cache-verify-* dirs
#
# Notes:
#  * Sims run SEQUENTIALLY on purpose — running many public-RPC forks at once
#    triggers HTTP 429 rate-limits. Each sim gets an isolated FOUNDRY_OUT/CACHE
#    so a concurrent `forge` in another terminal can't clobber it, and each is
#    auto-retried up to twice on a rate-limit.
#  * Tests MUST run under the default profile (the optimizer miscompiles
#    vm.roll); sims MUST run under FOUNDRY_PROFILE=production (broadcast bytecode).
#  * PaymasterHub sims pin --optimizer-runs 1 (it only fits under EIP-170 at runs=1,
#    which is what its broadcast uses).

set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# ---- locate repo root (this script lives in script/) --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-verify.XXXXXX")"
PAYMASTER_CEILING=24576

# ---- on-chain constants (see CLAUDE.md / memory) ------------------------------
DD=0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a
REG_GNOSIS=0x72c16812aE2a6819F4d0D9E432A3818712fa5c63
REG_ARBITRUM=0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_OFF=$'\033[0m'
pass() { printf '%s  PASS%s  %s\n' "$C_GRN" "$C_OFF" "$1"; }
fail() { printf '%s  FAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"; }
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$1"; }

# Each sim row: LABEL | SCRIPT_PATH:CONTRACT | CHAIN | EXTRA_FLAGS
# (SimGnosis/SimArbitrum/SimBase are the fork entrypoints; the Sim* mock helpers
#  in these files are internal and not listed.)
read -r -d '' SIMS <<'TABLE'
WS-A/gnosis    script/upgrades/UpgradeTokenExecutorDeployerSecurity.s.sol:SimGnosis   gnosis    -
WS-A/arbitrum  script/upgrades/UpgradeTokenExecutorDeployerSecurity.s.sol:SimArbitrum arbitrum  -
WS-B/gnosis    script/upgrades/UpgradeGovernanceSecurity.s.sol:SimGnosis              gnosis    -
WS-B/arbitrum  script/upgrades/UpgradeGovernanceSecurity.s.sol:SimArbitrum            arbitrum  -
WS-C/gnosis    script/upgrades/UpgradePaymasterSecurity.s.sol:SimGnosis               gnosis    --optimizer-runs=1
WS-C/arbitrum  script/upgrades/UpgradePaymasterSecurity.s.sol:SimArbitrum             arbitrum  --optimizer-runs=1
WS-D/gnosis    script/upgrades/UpgradeAccessSecurity.s.sol:SimGnosis                  gnosis    -
WS-D/arbitrum  script/upgrades/UpgradeAccessSecurity.s.sol:SimArbitrum                arbitrum  -
WS-E/gnosis    script/upgrades/UpgradeOpsModulesSecurity.s.sol:SimGnosis              gnosis    -
WS-E/arbitrum  script/upgrades/UpgradeOpsModulesSecurity.s.sol:SimArbitrum            arbitrum  -
WS-F/base      script/upgrades/UpgradeCashOutRelaySecurity.s.sol:SimBase              base      -
WS-G/gnosis    script/upgrades/UpgradePasskeyRecoverySecurity.s.sol:SimGnosis         gnosis    -
WS-G/arbitrum  script/upgrades/UpgradePasskeyRecoverySecurity.s.sol:SimArbitrum       arbitrum  -
TABLE

# Each version row: TYPE | VERSION | CHAINS(comma-sep: gnosis,arbitrum)
read -r -d '' VERSIONS <<'TABLE'
ParticipationToken     v5   gnosis,arbitrum
Executor               v4   gnosis,arbitrum
OrgDeployer            v16  gnosis,arbitrum
HybridVoting           v11  gnosis,arbitrum
DirectDemocracyVoting  v11  gnosis,arbitrum
PaymasterHub           v19  gnosis,arbitrum
EligibilityModule      v6   gnosis,arbitrum
QuickJoin              v6   gnosis,arbitrum
ToggleModule           v2   gnosis,arbitrum
PaymentManager         v4   gnosis,arbitrum
EducationHub           v2   gnosis,arbitrum
ImplementationRegistry v2   gnosis,arbitrum
PasskeyAccount         v2   gnosis,arbitrum
PasskeyAccountFactory  v2   gnosis,arbitrum
TABLE

FAILURES=0

# ------------------------------------------------------------------ gate --------
run_gate() {
  info "Gate 1/4: forge fmt --check"
  if forge fmt --check >/"$LOGDIR"/fmt.log 2>&1; then pass "fmt clean"; else fail "fmt (run: forge fmt)"; FAILURES=$((FAILURES+1)); fi

  info "Gate 2/4: forge build (default profile)"
  if forge build >"$LOGDIR"/build.log 2>&1; then pass "default build clean"
  else fail "default build — see $LOGDIR/build.log"; FAILURES=$((FAILURES+1)); fi

  info "Gate 3/4: PaymasterHub EIP-170 size (production, runs=1)"
  FOUNDRY_PROFILE=production forge build --sizes --optimizer-runs 1 >"$LOGDIR"/sizes.log 2>&1
  local sz
  sz="$(grep -E '\| *PaymasterHub *\|' "$LOGDIR"/sizes.log | grep -oE '[0-9]+,[0-9]+' | head -1 | tr -d ,)"
  if [ -n "$sz" ] && [ "$sz" -le "$PAYMASTER_CEILING" ]; then
    pass "PaymasterHub $sz B <= $PAYMASTER_CEILING B ($((PAYMASTER_CEILING - sz)) B headroom)"
  else
    fail "PaymasterHub size $sz B (ceiling $PAYMASTER_CEILING) — see $LOGDIR/sizes.log"; FAILURES=$((FAILURES+1))
  fi

  info "Gate 4/4: full test suite (default profile)"
  if forge test >"$LOGDIR"/test.log 2>&1; then
    pass "$(grep -oE '[0-9]+ tests passed' "$LOGDIR"/test.log | tail -1) / 0 failed"
  else
    fail "test suite — see $LOGDIR/test.log"
    grep -E '^\[FAIL|Suite result: FAILED' "$LOGDIR"/test.log | head; FAILURES=$((FAILURES+1))
  fi
}

# ------------------------------------------------------------------ sims --------
# run_one_sim LABEL SCRIPT:CONTRACT CHAIN EXTRA
run_one_sim() {
  local label="$1" target="$2" chain="$3" extra="$4"
  [ "$extra" = "-" ] && extra=""
  local slug; slug="$(echo "$label" | tr '/' '_')"
  local log="$LOGDIR/sim_$slug.log"
  local attempt
  for attempt in 1 2 3; do
    FOUNDRY_OUT="out-verify-$slug" FOUNDRY_CACHE_PATH="cache-verify-$slug" FOUNDRY_PROFILE=production \
      forge script "$target" --fork-url "$chain" $extra -vvv >"$log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ] && grep -q "PASS" "$log"; then
      pass "$label ($(grep -oE 'PASS[: ].*' "$log" | head -1 | cut -c1-52))"
      rm -rf "out-verify-$slug" "cache-verify-$slug"
      return 0
    fi
    if grep -qiE '429|rate limit|too many requests' "$log"; then
      info "$label rate-limited (attempt $attempt/3) — backing off ${attempt}0s"; sleep "${attempt}0"; continue
    fi
    break
  done
  fail "$label — see $log"
  grep -iE 'revert|error:|assert' "$log" | head -3
  rm -rf "out-verify-$slug" "cache-verify-$slug"
  FAILURES=$((FAILURES+1))
  return 1
}

run_sims() {
  local filter="${1:-}"
  info "Fork sims (sequential, production profile). Filter: ${filter:-<all>}"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    # shellcheck disable=SC2086
    set -- $row
    local label="$1" target="$2" chain="$3" extra="$4"
    if [ -n "$filter" ] && [[ "$label" != "$filter"* ]]; then continue; fi
    run_one_sim "$label" "$target" "$chain" "$extra"
  done <<< "$SIMS"
}

# ------------------------------------------------------------------ probe -------
# probe_one TYPE VERSION CHAIN  -> echoes FREE|TAKEN(reg,create2)
probe_one() {
  local type="$1" ver="$2" chain="$3" registry="$4"
  local reg_taken=no c2=no
  cast call --rpc-url "$chain" "$registry" 'getImplementation(string,string)(address)' "$type" "$ver" >/dev/null 2>&1 && reg_taken=yes
  local salt addr code
  salt="$(cast call --rpc-url "$chain" "$DD" 'computeSalt(string,string)(bytes32)' "$type" "$ver" 2>/dev/null)"
  addr="$(cast call --rpc-url "$chain" "$DD" 'computeAddress(bytes32)(address)' "$salt" 2>/dev/null)"
  code="$(cast code --rpc-url "$chain" "$addr" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "0x" ] && c2=yes
  if [ "$reg_taken" = no ] && [ "$c2" = no ]; then echo "FREE"; else echo "TAKEN(registry=$reg_taken,create2=$c2)"; fi
}

run_probe() {
  info "Two-surface version probe (registry + CREATE2) for every chosen version"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    # shellcheck disable=SC2086
    set -- $row
    local type="$1" ver="$2" chains="$3"
    local line="$type $ver:" ok=1
    IFS=',' read -ra clist <<< "$chains"
    for chain in "${clist[@]}"; do
      local registry; [ "$chain" = gnosis ] && registry="$REG_GNOSIS" || registry="$REG_ARBITRUM"
      local res; res="$(probe_one "$type" "$ver" "$chain" "$registry")"
      line="$line $chain=$res"
      [ "$res" = FREE ] || ok=0
    done
    if [ "$ok" = 1 ]; then pass "$line"; else fail "$line"; FAILURES=$((FAILURES+1)); fi
  done <<< "$VERSIONS"
}

# ------------------------------------------------------------------ plan --------
run_plan() {
  cat <<'PLAN'
============================ BROADCAST RUNBOOK (manual) ============================
Nothing below is executed by this script. Run each step yourself, confirming the
sim for that workstream PASSes first. Broadcast signer / admin EOA:
  0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9  (owns Hub on Arbitrum, Satellite on Gnosis)
All broadcasts use FOUNDRY_PROFILE=production; PaymasterHub also needs --optimizer-runs 1.

ORDERING CONSTRAINTS:
  * The seed workstream was REVERTED — there is NO "QuickJoin before OrgDeployer"
    coupling anymore. For patching EXISTING orgs every workstream is independent;
    order is your choice. Do WS-D FIRST (see priority below).
  1. PRIORITY — WS-D QuickJoin v6 closes a LIVE, exploitable H-03: on Decentral
     Park (Gnosis) the ELIGIBILITY_ADMIN hat is open, so anyone can self-mint it
     via the ungated claimHatsWithUser today. Ship WS-D first.
  2. WS-C Arbitrum ALSO closes the OPEN reinit window (protocolAdmin unset /
     _initialized=1) — do not skip the Arbitrum step.
  3. After WS-C: update the bundler/frontend preflight with the new (non-proxied)
     PaymasterHubLens address (no on-chain pointer).
  4. WS-A beacons before WS-B's FRESH FACTORIES only matters for the deferred
     new-org factory cut-over. Existing-org patching is unaffected by order.

SUGGESTED BATCHES (each: deploy impl -> upgrade beacon/proxy on each chain -> verify):
  Batch 1  WS-D access (DO FIRST) .........  UpgradeAccessSecurity.s.sol      (EligibilityModule v6/QuickJoin v6/ToggleModule v2 — closes live H-03)
  Batch 2  WS-C PaymasterHub v19 ..........  UpgradePaymasterSecurity.s.sol   (Step1/Step2/Step3a/Step3b/Step4, --optimizer-runs 1; closes Arb reinit)
  Batch 3  WS-F CashOutRelay (Base, UUPS) .  UpgradeCashOutRelaySecurity.s.sol:BroadcastBase  --fork-url base
  Batch 4  WS-E ops modules ...............  UpgradeOpsModulesSecurity.s.sol  (PaymentManager v4/EducationHub v2/ImplRegistry v2)
  Batch 5  WS-G passkey ...................  UpgradePasskeyRecoverySecurity.s.sol (PasskeyAccount v2/Factory v2)
  Batch 6  WS-B governance ................  UpgradeGovernanceSecurity.s.sol  (HybridVoting v11/DDV v11)
  Batch 7  WS-A token/executor/deployer ...  UpgradeTokenExecutorDeployerSecurity.s.sol (ParticipationToken v5 + Executor v4 + OrgDeployer v16)

NOT covered by this rollout: creating NEW orgs via the live OrgDeployer proxy
still needs the deferred factory cut-over (fresh factories + OrgRegistry ownership
transfer). Existing orgs are fully patched; new-org onboarding is a follow-up.

Each script's header comment block has its exact Step1/Step2/Step2b/Step3 invocation.
Re-run `script/audit-verify.sh probe` immediately before broadcasting to confirm no
version was taken in the meantime.
===================================================================================
PLAN
}

# ------------------------------------------------------------------ main --------
MODE="${1:-all}"
case "$MODE" in
  gate)  run_gate ;;
  sims)  run_sims "" ;;
  sim)   run_sims "${2:?usage: sim WS-A|WS-B|...|SEED}" ;;
  probe) run_probe ;;
  plan)  run_plan ;;
  clean) rm -rf out-verify-* cache-verify-*; info "removed out-verify-*/cache-verify-*"; exit 0 ;;
  all)   run_gate; echo; run_sims "" ;;
  *) echo "usage: $0 [all|gate|sims|sim <WS>|probe|plan|clean]"; exit 2 ;;
esac

echo
if [ "$MODE" = plan ]; then exit 0; fi
if [ "$FAILURES" -eq 0 ]; then
  printf '%s========== ALL CHECKS PASSED ==========%s\n' "$C_GRN" "$C_OFF"
  echo "logs: $LOGDIR"
  exit 0
else
  printf '%s========== %d CHECK(S) FAILED ==========%s\n' "$C_RED" "$FAILURES" "$C_OFF"
  echo "logs: $LOGDIR"
  exit 1
fi
