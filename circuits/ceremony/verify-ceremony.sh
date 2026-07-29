#!/usr/bin/env bash
# verify-ceremony.sh — INDEPENDENT audit of a completed POP phase-2 trusted-setup ceremony.
#
# Anyone (a contributor, an outside observer) can run this to confirm — WITHOUT trusting the
# coordinator — that the final zkey is a valid, untampered product of the recorded multi-party
# ceremony over the stated circuit + Powers-of-Tau, and (optionally) that the on-chain verifier and the
# beacon match. It re-derives everything from first principles; a PASS means the deployed crypto is
# exactly what the ceremony produced.
#
# The load-bearing check is `snarkjs zkey verify <r1cs> <ptau> <final.zkey>`, which independently
# recomputes and validates the ENTIRE contribution chain + the beacon. If that says "ZKey Ok!", the
# final key is a sound product of the ceremony. The remaining checks tie that to what was published /
# deployed so nothing was swapped afterward.
#
# Usage:
#   verify-ceremony.sh <circuit-name> <r1cs> <ptau> <final.zkey> <transcript> [options]
# Options:
#   --expect-ptau-sha256 <hex>          fail unless the ptau hashes to this (the value you cross-checked
#                                       against the published Hermez/snarkjs table)
#   --my-hash <hex>                     confirm a specific contribution hash is in the ceremony — a
#                                       contributor pastes the hash snarkjs printed for THEIR step
#   --onchain <verifier-addr> --rpc <url>   confirm the DEPLOYED verifier's bytecode embeds this
#                                       ceremony's verifying key (delta + IC points)
#   --beacon-block <N> --rpc <url>      confirm the transcript's beacon == Ethereum block N's hash
#                                       (--rpc may be an eth RPC; reused for --onchain too)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
# lib.sh enables `set -e`; the auditor runs EVERY check and tallies pass/fail itself (via `bad`), so a
# single failing check (or a missing transcript field) must NOT abort the run. Turn errexit back off;
# hard errors still exit via the explicit `err`/`|| err` calls below.
set +e

[[ $# -ge 5 ]] || err "usage: verify-ceremony.sh <circuit-name> <r1cs> <ptau> <final.zkey> <transcript> [options]"
NAME="$1"; R1CS="$2"; PTAU="$3"; FINAL="$4"; TS="$5"; shift 5

EXPECT_PTAU=""; MY_HASH=""; ONCHAIN=""; RPC=""; BEACON_BLOCK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-ptau-sha256) EXPECT_PTAU="$2"; shift 2;;
    --my-hash) MY_HASH="$2"; shift 2;;
    --onchain) ONCHAIN="$2"; shift 2;;
    --rpc) RPC="$2"; shift 2;;
    --beacon-block) BEACON_BLOCK="$2"; shift 2;;
    *) err "unknown option: $1";;
  esac
done

for f in "$R1CS" "$PTAU" "$FINAL" "$TS"; do [[ -f "$f" ]] || err "not found: $f"; done

PASS=1
ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; PASS=0; }
skip() { printf '  \033[1;33m[skip]\033[0m %s\n' "$*"; }
# Pull a `key:  value` field out of the transcript (first match), trimming whitespace. Empty if absent.
tfield() { grep -m1 "^$1" "$TS" 2>/dev/null | sed "s/^$1//" | tr -d ' \t' | grep -oiE '[0-9a-fx]+' | head -1 || true; }

log "Auditing ${NAME} ceremony"
log "  final zkey:  $FINAL"
log "  transcript:  $TS"
echo

# 1. Powers-of-Tau integrity ------------------------------------------------------------------------
log "1. Powers-of-Tau"
PTAU_SHA="$(sha256_of "$PTAU")"
if [[ -n "$EXPECT_PTAU" ]]; then
  [[ "${PTAU_SHA,,}" == "${EXPECT_PTAU,,}" ]] && ok "ptau sha256 matches the value you cross-checked" \
    || bad "ptau sha256 = $PTAU_SHA (expected $EXPECT_PTAU)"
else
  skip "no --expect-ptau-sha256 given; ptau sha256 = $PTAU_SHA (cross-check against the published table)"
fi
TS_PTAU="$(tfield 'ptau.sha256:')"
if [[ -n "$TS_PTAU" ]]; then
  [[ "${PTAU_SHA,,}" == "${TS_PTAU,,}" ]] && ok "ptau matches the one recorded in the transcript" \
    || bad "ptau differs from the transcript's ptau.sha256 ($TS_PTAU) — WRONG ptau or tampered transcript"
fi
echo

# 2. Cryptographic chain + beacon (the load-bearing check) ------------------------------------------
log "2. Contribution chain + beacon (snarkjs zkey verify)"
VERIFY_OUT="$(mktemp)"
if sj zkey verify "$R1CS" "$PTAU" "$FINAL" >"$VERIFY_OUT" 2>&1 && grep -qi 'ZKey Ok' "$VERIFY_OUT"; then
  NCONTRIB="$(grep -ciE 'contribution|contributor' "$VERIFY_OUT" || true)"
  ok "zkey verify PASSED — the full contribution chain + beacon are valid over this r1cs + ptau"
  ok "snarkjs re-derived $NCONTRIB contribution record(s); their hashes are listed below"
else
  bad "zkey verify FAILED — the final zkey is NOT a valid product of this circuit + ptau"
  tail -5 "$VERIFY_OUT" | sed 's/^/      /'
fi
echo

# 3. Final zkey matches what the transcript recorded ------------------------------------------------
log "3. Final zkey integrity"
FINAL_SHA="$(sha256_of "$FINAL")"
TS_FINAL="$(tfield 'final.sha256:')"
if [[ -n "$TS_FINAL" ]]; then
  [[ "${FINAL_SHA,,}" == "${TS_FINAL,,}" ]] && ok "final zkey sha256 matches the transcript" \
    || bad "final zkey sha256 = $FINAL_SHA differs from transcript ($TS_FINAL) — key swapped after finalize"
else
  skip "transcript has no final.sha256; final zkey sha256 = $FINAL_SHA"
fi
echo

# 4. Contributor self-check ------------------------------------------------------------------------
if [[ -n "$MY_HASH" ]]; then
  log "4. Your contribution is included"
  NEEDLE="$(printf '%s' "$MY_HASH" | tr -d ' \t\n' | tr 'A-Z' 'a-z')"
  HAY="$(tr -d ' \t\n' <"$VERIFY_OUT" | tr 'A-Z' 'a-z')"
  [[ "$HAY" == *"$NEEDLE"* ]] && ok "your contribution hash appears in the verified ceremony" \
    || bad "your contribution hash was NOT found — your step is not in this final key"
  echo
fi

# 5. Beacon == the pre-announced public block ------------------------------------------------------
if [[ -n "$BEACON_BLOCK" ]]; then
  log "5. Beacon == pre-announced Ethereum block $BEACON_BLOCK"
  TS_BEACON="$(tfield 'beacon:')"
  if ! command -v cast >/dev/null 2>&1 || [[ -z "$RPC" ]]; then
    skip "need \`cast\` + --rpc to fetch the block hash; transcript beacon = $TS_BEACON"
  else
    BLOCK_HASH="$(cast block "$BEACON_BLOCK" --field hash --rpc-url "$RPC" 2>/dev/null | sed 's/^0x//' | tr 'A-Z' 'a-z')"
    [[ -n "$BLOCK_HASH" && "${TS_BEACON,,}" == *"$BLOCK_HASH"* ]] \
      && ok "beacon in transcript == hash of block $BEACON_BLOCK ($BLOCK_HASH)" \
      || bad "transcript beacon ($TS_BEACON) != block $BEACON_BLOCK hash ($BLOCK_HASH)"
  fi
  echo
fi

# 6. Deployed verifier came from THIS ceremony -----------------------------------------------------
if [[ -n "$ONCHAIN" ]]; then
  log "6. Deployed verifier $ONCHAIN embeds this ceremony's verifying key"
  if ! command -v cast >/dev/null 2>&1 || [[ -z "$RPC" ]]; then
    skip "need \`cast\` + --rpc to read the deployed bytecode"
  else
    VKEY="$(mktemp)"; sj zkey export verificationkey "$FINAL" "$VKEY" >/dev/null 2>&1
    CODE="$(cast code "$ONCHAIN" --rpc-url "$RPC" 2>/dev/null)"
    if [[ -z "$CODE" || "$CODE" == "0x" ]]; then
      bad "no bytecode at $ONCHAIN on this RPC"
    else
      RES="$(python3 - "$VKEY" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); code=sys.stdin.read().strip().lower()
def h(x): return format(int(x),'064x')
# delta (phase-2/circuit-specific) + every IC point bind this exact circuit + ceremony.
probes=[('delta_x_c1',h(v['vk_delta_2'][0][0])),('delta_x_c0',h(v['vk_delta_2'][0][1]))]
for i,pt in enumerate(v['IC']): probes.append((f'IC{i}_x',h(pt[0])))
hits=sum(1 for _,hx in probes if hx in code)
print(f"{hits}/{len(probes)}")
PY
<<<"$CODE")"
      HITS="${RES%%/*}"; TOTAL="${RES##*/}"
      [[ "$HITS" == "$TOTAL" && "$TOTAL" -gt 0 ]] \
        && ok "all $TOTAL vkey constants (delta + IC) are embedded in the deployed bytecode — it IS this ceremony's key" \
        || bad "only $RES vkey constants found on-chain — deployed verifier does NOT match this ceremony"
      rm -f "$VKEY"
    fi
  fi
  echo
fi

rm -f "$VERIFY_OUT"
echo "─────────────────────────────────────────────"
if [[ "$PASS" == 1 ]]; then
  printf '\033[1;32mAUDIT PASSED\033[0m — %s is a sound, untampered product of the ceremony.\n' "$NAME"
else
  printf '\033[1;31mAUDIT FAILED\033[0m — do NOT trust/deploy this key. See the [FAIL] lines above.\n'; exit 1
fi
