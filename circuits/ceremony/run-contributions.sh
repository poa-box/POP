#!/usr/bin/env bash
# run-contributions.sh — run ALL contributions for one circuit, back-to-back, on THIS machine.
#
# The coordinator runs this ONCE per circuit; each contributor, in turn, types their OWN random entropy
# at the prompt (the only thing anyone types). It chains _0000 -> _0001 -> ... -> _000N and records each
# step in the transcript. (Single-machine model — simplest. If you want each contributor on their own
# machine instead, run phase2-contribute.sh per hop and pass the zkey between them; see CEREMONY.md.)
#
# Usage: run-contributions.sh <circuit> <out-dir> <name1> [name2 ...]
#   <out-dir> must already contain <circuit>_0000.zkey + <circuit>.transcript.txt (from phase2-begin.sh).
#   Set CEREMONY_ENTROPY to run non-interactively (each contributor gets a DISTINCT derived value) —
#   for rehearsals/CI ONLY; real contributors leave it unset and type at the prompt.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -ge 3 ]] || err "usage: run-contributions.sh <circuit> <out-dir> <name1> [name2 ...]"
CIRCUIT="$1"; OUT="$2"; shift 2
NAMES=("$@")
TS="${OUT}/${CIRCUIT}.transcript.txt"
[[ -f "${OUT}/${CIRCUIT}_0000.zkey" ]] || err "run phase2-begin.sh first — ${OUT}/${CIRCUIT}_0000.zkey missing"
[[ -f "$TS" ]] || err "transcript missing: $TS"

N=${#NAMES[@]}
log "Running $N contributions for ${CIRCUIT}. Each contributor types their OWN entropy when prompted."
for i in $(seq 1 "$N"); do
  WHO="${NAMES[$((i - 1))]}"
  IN=$(printf "%s/%s_%04d.zkey" "$OUT" "$CIRCUIT" $((i - 1)))
  OUTZ=$(printf "%s/%s_%04d.zkey" "$OUT" "$CIRCUIT" "$i")
  echo
  log "══════ Contributor ${i}/${N}: ${WHO} — hand them the keyboard ══════"
  log "Type RANDOM keys, then Enter. Input is HIDDEN — not shown on screen, not saved, not in \`ps\`."
  if [[ -n "${CEREMONY_ENTROPY:-}" ]]; then
    CEREMONY_ENTROPY="${CEREMONY_ENTROPY}-${i}-${WHO}" "${HERE}/phase2-contribute.sh" "$CIRCUIT" "$IN" "$OUTZ" "$WHO" "$TS"
  else
    "${HERE}/phase2-contribute.sh" "$CIRCUIT" "$IN" "$OUTZ" "$WHO" "$TS"
  fi
done

LASTZ=$(printf "%s/%s_%04d.zkey" "$OUT" "$CIRCUIT" "$N")
echo
log "All $N contributions recorded in ${TS}."
log "Last contribution: ${LASTZ}"
log "Next: beacon-announce.sh ${CIRCUIT} ${LASTZ} 300 --rpc <eth-rpc>"
