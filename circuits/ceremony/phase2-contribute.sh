#!/usr/bin/env bash
# Phase-2 ceremony — STEP 2 (each independent contributor, on their OWN machine).
# Adds one contribution of fresh, private entropy on top of the previous contributor's zkey.
#
# Security model: the setup is sound as long as AT LEAST ONE contributor is honest and destroys their
# entropy. So each contributor must (a) provide entropy only they know, (b) never reveal or reuse it,
# (c) publish the printed contribution hash so others can confirm their step is in the final transcript.
#
# Usage: phase2-contribute.sh <circuit-name> <in.zkey> <out.zkey> <contributor-id> [transcript]
#   Entropy is read from the CEREMONY_ENTROPY env var if set (non-interactive/rehearsal), otherwise
#   snarkjs prompts for it interactively (preferred for real contributors — nothing is logged).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

[[ $# -ge 4 ]] || err "usage: phase2-contribute.sh <circuit-name> <in.zkey> <out.zkey> <contributor-id> [transcript]"
NAME="$1"; IN="$2"; OUT="$3"; WHO="$4"; TS="${5:-}"
[[ -f "$IN" ]] || err "input zkey not found: $IN"

log "Contribution by '${WHO}' on ${NAME}"
log "  input:  $IN ($(sha256_of "$IN"))"

if [[ -n "${CEREMONY_ENTROPY:-}" ]]; then
  # Non-interactive path (rehearsal / CI). NB snarkjs wants `-e=value` (equals), not `-e value`.
  # `</dev/null` so snarkjs never touches stdin (matters inside run-contributions' loop — see below).
  sj zkey contribute "$IN" "$OUT" --name="$WHO" -e="$CEREMONY_ENTROPY" </dev/null
else
  # Interactive: read the contributor's entropy with echo OFF (read -rs) — nothing shows on screen, so
  # the coordinator / a shoulder-surfer / a screen recording never sees it, and it isn't in shell
  # history. We pass it via `-e` (NOT snarkjs's own prompt): snarkjs then prints NO entropy prompt, so
  # there's exactly ONE (hidden) prompt — the contributor can't be tricked into re-typing it visibly.
  # (Tradeoff: `-e` puts the entropy in this process's argv for ~2s, visible to a concurrent `ps` on
  #  THIS machine. Fine on a trusted single machine; for zero local exposure use the own-machines model.)
  printf '\033[1;36m[ceremony]\033[0m  %s: smash the keyboard with RANDOM keys — HIDDEN, nothing will show — then Enter: ' "$WHO" >&2
  read -rs ENTROPY_INPUT; printf '\n' >&2
  [[ ${#ENTROPY_INPUT} -ge 8 ]] || err "need at least a few random characters — your entropy is what makes this secure"
  log "  contributing… (this takes ~1–2 min for the real key — don't touch anything)"
  # `</dev/null`: snarkjs must NOT read the terminal, or in run-contributions' loop it would swallow
  # the NEXT contributor's keystrokes and the loop couldn't prompt them. Entropy is already in `-e=`.
  sj zkey contribute "$IN" "$OUT" --name="$WHO" -e="$ENTROPY_INPUT" </dev/null
  unset ENTROPY_INPUT
fi

CONTRIB_SHA="$(sha256_of "$OUT")"
log "  output: $OUT ($CONTRIB_SHA)"
log "Publish this so others can verify your step is in the final transcript:"
log "  ${WHO}  ->  ${CONTRIB_SHA}"

if [[ -n "$TS" ]]; then
  transcript "$TS" "${WHO}  ${CONTRIB_SHA}"
fi

log "Pass ${OUT} to the next contributor (or run phase2-finalize.sh if you are last)."
