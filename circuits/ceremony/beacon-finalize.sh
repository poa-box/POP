#!/usr/bin/env bash
# beacon-finalize.sh — STEP 3b: after the pre-announced block is mined, fold its hash in as the beacon.
#
# Reads the commitment written by beacon-announce.sh, checks the committed block now exists, confirms
# the contributions haven't changed since you committed (the last zkey still hashes to the committed
# value — so you can't grind by swapping contributions after seeing the block hash), fetches the block
# hash, and runs the beacon finalize. The commitment + block hash are recorded in the transcript.
#
# Usage: beacon-finalize.sh <commit-file> <last.zkey> <r1cs> <ptau> <out-dir> --rpc <eth-rpc-url>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -ge 5 ]] || err "usage: beacon-finalize.sh <commit-file> <last.zkey> <r1cs> <ptau> <out-dir> --rpc <url>"
COMMIT="$1"; LAST="$2"; R1CS="$3"; PTAU="$4"; OUT="$5"; shift 5
RPC=""
while [[ $# -gt 0 ]]; do
  case "$1" in --rpc) RPC="$2"; shift 2;; *) err "unknown option: $1";; esac
done
for f in "$COMMIT" "$LAST" "$R1CS" "$PTAU"; do [[ -f "$f" ]] || err "not found: $f"; done
[[ -n "$RPC" ]] || err "--rpc <eth-rpc-url> is required"
command -v cast >/dev/null 2>&1 || err "foundry \`cast\` not found"

cfield() { grep -m1 "^$1" "$COMMIT" | sed "s/^$1//" | tr -d ' \t'; }
CIRCUIT="$(cfield 'circuit:')"
CHAIN_ID="$(cfield 'chain_id:')"
COMMITTED_SHA="$(cfield 'last_contribution_sha256:')"
BEACON_BLOCK="$(cfield 'beacon_block:')"
COMMITTED_AT="$(cfield 'committed_at_block:')"
[[ -n "$CIRCUIT" && -n "$BEACON_BLOCK" && -n "$COMMITTED_SHA" ]] || err "commitment file is malformed: $COMMIT"

log "Finalizing ${CIRCUIT} with the pre-committed beacon (block ${BEACON_BLOCK})"

# 1. Same chain we committed against.
CHAIN_NOW="$(cast chain-id --rpc-url "$RPC")"
[[ "$CHAIN_NOW" == "$CHAIN_ID" ]] || err "RPC chain_id ${CHAIN_NOW} != committed chain_id ${CHAIN_ID}"

# 2. Contributions unchanged since the commitment (anti-grinding: can't swap after seeing the hash).
LAST_SHA="$(sha256_of "$LAST")"
[[ "${LAST_SHA,,}" == "${COMMITTED_SHA,,}" ]] \
  || err "last zkey sha256 (${LAST_SHA}) != committed (${COMMITTED_SHA}) — contributions changed since commit; ABORT"
log "  contributions match the commitment (last.zkey sha256 ${LAST_SHA:0:16}…)"

# 3. Sanity: we really committed BEFORE the beacon block (the anti-grinding invariant).
[[ -n "$COMMITTED_AT" && "$COMMITTED_AT" -lt "$BEACON_BLOCK" ]] \
  || err "committed_at_block (${COMMITTED_AT}) is not before beacon_block (${BEACON_BLOCK}) — invalid commitment"

# 4. The committed block must now exist.
HEIGHT="$(cast block-number --rpc-url "$RPC")"
if [[ "$HEIGHT" -lt "$BEACON_BLOCK" ]]; then
  err "block ${BEACON_BLOCK} not mined yet (chain height ${HEIGHT}); wait ~$(((BEACON_BLOCK - HEIGHT) * 12))s and retry"
fi

# 5. Fetch the beacon = block hash (strip 0x for snarkjs).
BLOCK_HASH="$(cast block "$BEACON_BLOCK" --field hash --rpc-url "$RPC" | sed 's/^0x//')"
[[ "$BLOCK_HASH" =~ ^[0-9a-fA-F]{64}$ ]] || err "could not read a valid hash for block ${BEACON_BLOCK}"
log "  beacon = block ${BEACON_BLOCK} hash = ${BLOCK_HASH}"

# 6. Run the actual finalize with this beacon.
"${HERE}/phase2-finalize.sh" "$CIRCUIT" "$LAST" "$R1CS" "$PTAU" "$OUT" "$BLOCK_HASH" 10

# 7. Record the commitment link in the transcript (so an auditor can tie beacon -> pre-announced block).
TS="${OUT}/${CIRCUIT}.transcript.txt"
if [[ -f "$TS" ]]; then
  transcript "$TS" "beacon_source:  ethereum chain ${CHAIN_ID} block ${BEACON_BLOCK} (committed at block ${COMMITTED_AT})"
fi

log "Done. Auditors can re-check with:"
log "  verify-ceremony.sh ${CIRCUIT} ${R1CS} ${PTAU} ${OUT}/${CIRCUIT}_final.zkey ${TS} --beacon-block ${BEACON_BLOCK} --rpc <url>"
