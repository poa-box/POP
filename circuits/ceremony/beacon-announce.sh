#!/usr/bin/env bash
# beacon-announce.sh — STEP 3a: publicly COMMIT to the ceremony beacon BEFORE it exists.
#
# The beacon must be unknowable AND unchoosable at commit time, else the coordinator could grind a
# favorable final key. So we pin the beacon to a FUTURE Ethereum block (its hash doesn't exist yet)
# and bind that choice to the CURRENT contribution state. You then post the printed commitment publicly
# BEFORE that block is mined — that public, pre-block timestamp is the anti-grinding proof.
#
# Usage: beacon-announce.sh <circuit> <last.zkey> <blocks-ahead> --rpc <eth-rpc-url> [--out <dir>]
#   <last.zkey>    the LAST contributor's zkey (the state you're about to finalize)
#   <blocks-ahead> how many blocks in the future to target (mainnet ~12s/block; 300 ≈ 1h)
#   --out <dir>    where to write the commitment (default: the last.zkey's directory)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -ge 3 ]] || err "usage: beacon-announce.sh <circuit> <last.zkey> <blocks-ahead> --rpc <url> [--out <dir>]"
CIRCUIT="$1"; LAST="$2"; AHEAD="$3"; shift 3
RPC=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc) RPC="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    *) err "unknown option: $1";;
  esac
done
[[ -f "$LAST" ]] || err "last zkey not found: $LAST"
[[ "$AHEAD" =~ ^[0-9]+$ && "$AHEAD" -ge 1 ]] || err "blocks-ahead must be a positive integer"
[[ -n "$RPC" ]] || err "--rpc <eth-rpc-url> is required"
command -v cast >/dev/null 2>&1 || err "foundry \`cast\` not found (needed to read the chain height)"
[[ -z "$OUT" ]] && OUT="$(dirname "$LAST")"
mkdir -p "$OUT"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
CURRENT="$(cast block-number --rpc-url "$RPC")"
[[ -n "$CURRENT" ]] || err "could not read the current block height from $RPC"
BEACON_BLOCK=$((CURRENT + AHEAD))
LAST_SHA="$(sha256_of "$LAST")"
COMMIT="${OUT}/${CIRCUIT}.beacon-commit.txt"

{
  echo "POP ceremony beacon commitment"
  echo "circuit:                  ${CIRCUIT}"
  echo "chain_id:                 ${CHAIN_ID}"
  echo "last_contribution_sha256: ${LAST_SHA}"
  echo "beacon_block:             ${BEACON_BLOCK}"
  echo "committed_at_block:       ${CURRENT}"
  echo "committed_at_utc:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$COMMIT"

log "Beacon commitment written: ${COMMIT}"
echo "─────────────────────────────────────────────"
cat "$COMMIT"
echo "─────────────────────────────────────────────"
EST=$((AHEAD * 12))
log "Beacon block ${BEACON_BLOCK} is ~${EST}s (~$((EST / 60)) min) away on mainnet."
log "The proof that you did NOT grind: committed_at_block (${CURRENT}) < beacon_block (${BEACON_BLOCK})."
echo
log "\033[1;33mACTION:\033[0m post the box above PUBLICLY NOW (commit to git / message contributors /"
log "        anywhere timestamped) — it must be public BEFORE block ${BEACON_BLOCK} is mined."
log "Then, once that block exists, run:  beacon-finalize.sh ${COMMIT} ${LAST} <r1cs> <ptau> ${OUT} --rpc <url>"
