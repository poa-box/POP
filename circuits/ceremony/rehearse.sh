#!/usr/bin/env bash
# Rehearsal — exercises the ENTIRE phase-2 ceremony flow end-to-end on a tiny throwaway circuit, so we
# prove the tooling (begin -> N contributors -> beacon-finalize -> verify -> export -> proof round-trip)
# works before running it for real on the ~1.2M-constraint POP circuits.
#
# It generates its own small Powers-of-Tau locally (2^12), so it needs NO multi-GB download. The real
# run swaps in the real r1cs + the hash-verified Hermez ptau (see CEREMONY.md); the phase-2 steps are
# byte-for-byte the same scripts exercised here.
#
# Usage: rehearse.sh [workdir]   (default: a fresh temp dir; deleted on success unless KEEP=1)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
log "Rehearsal workdir: $WORK"

# circom compiler: prefer the repo's built binary, else PATH.
CIRCOM="${CIRCOM:-${POP_ZK_WORK}/circom-src/target/release/circom}"
[[ -x "$CIRCOM" ]] || CIRCOM="$(command -v circom || true)"
[[ -x "$CIRCOM" ]] || err "circom not found (set CIRCOM or build ${POP_ZK_WORK}/circom-src)"
log "circom: $($CIRCOM --version)"

cd "$WORK"

# --- tiny circuit: prove knowledge of two factors of a public product (2 constraints) ---
cat > tiny.circom <<'CIRCOM'
pragma circom 2.0.0;
template Multiplier() {
    signal input a;
    signal input b;
    signal output c;
    c <== a * b;
}
component main = Multiplier();
CIRCOM

log "1/6  compiling tiny circuit"
"$CIRCOM" tiny.circom --r1cs --wasm -o . >/dev/null

log "2/6  generating a small local Powers-of-Tau (2^12) — stands in for the Hermez ptau"
sj powersoftau new bn128 12 pot_0000.ptau -v >/dev/null
sj powersoftau contribute pot_0000.ptau pot_0001.ptau --name="rehearsal p1" -e="rehearsal-phase1-entropy" >/dev/null
sj powersoftau prepare phase2 pot_0001.ptau pot_final.ptau -v >/dev/null

log "3/6  phase2-begin (coordinator initial zkey)"
"${HERE}/phase2-begin.sh" tiny tiny.r1cs pot_final.ptau "$WORK/out" >/dev/null

log "4/6  three independent contributions"
CEREMONY_ENTROPY="alice-secret-$RANDOM$RANDOM" \
  "${HERE}/phase2-contribute.sh" tiny out/tiny_0000.zkey out/tiny_0001.zkey "alice" out/tiny.transcript.txt >/dev/null
CEREMONY_ENTROPY="bob-secret-$RANDOM$RANDOM" \
  "${HERE}/phase2-contribute.sh" tiny out/tiny_0001.zkey out/tiny_0002.zkey "bob" out/tiny.transcript.txt >/dev/null
CEREMONY_ENTROPY="carol-secret-$RANDOM$RANDOM" \
  "${HERE}/phase2-contribute.sh" tiny out/tiny_0002.zkey out/tiny_0003.zkey "carol" out/tiny.transcript.txt >/dev/null

log "5/6  phase2-finalize (beacon + verify + export)"
BEACON="0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
"${HERE}/phase2-finalize.sh" tiny out/tiny_0003.zkey tiny.r1cs pot_final.ptau "$WORK/out" "$BEACON" 10 >/dev/null

log "6/6  proving a real witness against the ceremony zkey + verifying it"
node -e "const{writeFileSync}=require('fs');writeFileSync('input.json',JSON.stringify({a:'3',b:'11'}))"
sj wtns calculate tiny_js/tiny.wasm input.json witness.wtns >/dev/null
sj groth16 prove out/tiny_final.zkey witness.wtns proof.json public.json >/dev/null
sj groth16 verify out/vkey_tiny.json public.json proof.json | tee verify.out | grep -q "OK" || err "proof did NOT verify against the ceremony key"

# Independent audit: every contributor's hash must appear in the transcript.
for who in alice bob carol; do
  grep -q "^${who}  " out/tiny.transcript.txt || err "contributor ${who} missing from transcript"
done

echo
log "REHEARSAL PASSED — full ceremony flow works end-to-end:"
log "  setup -> alice -> bob -> carol -> beacon -> verify(OK) -> export -> proof round-trip(OK)"
echo "----- transcript -----"
cat out/tiny.transcript.txt
echo "----------------------"

if [[ "${KEEP:-0}" != "1" && -z "${1:-}" ]]; then rm -rf "$WORK"; log "cleaned up $WORK (KEEP=1 to retain)"; fi
