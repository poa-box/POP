#!/usr/bin/env bash
# Phase-2 ceremony — STEP 3 (coordinator, once per circuit, after all contributions).
# Applies a public random beacon (so no contributor picked the final randomness), verifies the result
# against the r1cs + ptau, and exports the on-chain verifier + verifying key.
#
# Usage: phase2-finalize.sh <circuit-name> <last.zkey> <r1cs> <ptau> <out-dir> <beacon-hex> [beacon-iters]
#   beacon-hex   public randomness (e.g. a future Ethereum block hash, sans 0x). Published in advance.
#   beacon-iters power-of-two iterations for the beacon hash (default 10).
#
# Output in <out-dir>: <name>_final.zkey, vkey_<name>.json, Groth16Verifier[<suffix>].sol; transcript
# appended with the beacon + final hashes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -ge 6 ]] || err "usage: phase2-finalize.sh <circuit-name> <last.zkey> <r1cs> <ptau> <out-dir> <beacon-hex> [iters]"
NAME="$1"; LAST="$2"; R1CS="$3"; PTAU="$4"; OUT="$5"; BEACON="$6"; ITERS="${7:-10}"
# snarkjs requires the beacon's numIterationsExp in [10, 63]. Guard here with a clear message.
[[ "$ITERS" =~ ^[0-9]+$ && "$ITERS" -ge 10 && "$ITERS" -le 63 ]] || err "beacon iters must be an integer in [10,63] (got '$ITERS')"
[[ -f "$LAST" ]] || err "last contribution not found: $LAST"
[[ -f "$R1CS" ]] || err "r1cs not found: $R1CS"
[[ -f "$PTAU" ]] || err "ptau not found: $PTAU"
mkdir -p "$OUT"
TS="${OUT}/${NAME}.transcript.txt"
FINAL="${OUT}/${NAME}_final.zkey"
VKEY="${OUT}/vkey_${NAME}.json"
# Verifier contract name matches what the repo vendors: PopRoleClaim -> Groth16Verifier,
# PopRoleClaimV2 -> Groth16VerifierV2.
SUFFIX=""; [[ "$NAME" == *V2 ]] && SUFFIX="V2"
VERIFIER="${OUT}/Groth16Verifier${SUFFIX}.sol"

log "Applying beacon to ${NAME} (beacon=${BEACON}, iters=2^${ITERS})"
sj zkey beacon "$LAST" "$FINAL" "$BEACON" "$ITERS" --name="final beacon"

log "Verifying ${NAME}_final.zkey against r1cs + ptau (MUST report OK)"
sj zkey verify "$R1CS" "$PTAU" "$FINAL"

log "Exporting verifying key + solidity verifier"
sj zkey export verificationkey "$FINAL" "$VKEY"
sj zkey export solidityverifier "$FINAL" "$VERIFIER"

transcript "$TS" "----- finalization -----"
transcript "$TS" "beacon:         ${BEACON} (2^${ITERS})"
transcript "$TS" "final.sha256:   $(sha256_of "$FINAL")"
transcript "$TS" "vkey.sha256:    $(sha256_of "$VKEY")"
transcript "$TS" "verifier.sha256:$(sha256_of "$VERIFIER")"

log "Done. Artifacts in ${OUT}:"
log "  $(basename "$FINAL")  — the production zkey (re-chunk + re-pin to IPFS)"
log "  $(basename "$VKEY")   — COMMIT this (auditable vkey; none currently exists on disk)"
log "  $(basename "$VERIFIER") — re-vendor to src/zkemail/vendor/ and redeploy"
log "  $(basename "$TS")      — the full transcript; keep forever"
