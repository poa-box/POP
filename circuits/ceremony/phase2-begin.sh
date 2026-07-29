#!/usr/bin/env bash
# Phase-2 ceremony — STEP 1 (coordinator, once per circuit).
# Produces the initial circuit-specific zkey (contribution 0000) that the first contributor builds on.
#
# Usage: phase2-begin.sh <circuit-name> <r1cs> <ptau> <out-dir>
#   circuit-name  logical name, e.g. PopRoleClaim or PopRoleClaimV2
#   r1cs          the compiled circuit (build/<name>.r1cs)
#   ptau          the phase-1 Powers-of-Tau file (hash-verified — see CEREMONY.md)
#   out-dir       where the ceremony artifacts + transcript land
#
# Output: <out-dir>/<name>_0000.zkey  and a fresh <out-dir>/<name>.transcript.txt
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -eq 4 ]] || err "usage: phase2-begin.sh <circuit-name> <r1cs> <ptau> <out-dir>"
NAME="$1"; R1CS="$2"; PTAU="$3"; OUT="$4"
[[ -f "$R1CS" ]] || err "r1cs not found: $R1CS"
[[ -f "$PTAU" ]] || err "ptau not found: $PTAU"
mkdir -p "$OUT"
TS="${OUT}/${NAME}.transcript.txt"
Z0000="${OUT}/${NAME}_0000.zkey"

log "Phase-2 setup for ${NAME}"
log "  r1cs: $R1CS ($(sha256_of "$R1CS"))"
log "  ptau: $PTAU ($(sha256_of "$PTAU"))"

sj groth16 setup "$R1CS" "$PTAU" "$Z0000"

: > "$TS"
transcript "$TS" "POP zk-email phase-2 ceremony transcript"
transcript "$TS" "circuit:        ${NAME}"
transcript "$TS" "r1cs.sha256:    $(sha256_of "$R1CS")"
transcript "$TS" "ptau.sha256:    $(sha256_of "$PTAU")"
transcript "$TS" "0000.sha256:    $(sha256_of "$Z0000")"
transcript "$TS" "----- contributions -----"

log "Wrote ${Z0000}"
log "Transcript started: ${TS}"
log "Hand ${NAME}_0000.zkey to contributor #1 and run phase2-contribute.sh."
