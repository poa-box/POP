#!/usr/bin/env bash
# ============================================================================
# enumerate-wearers.sh — Access-v2 migration candidate enumerator (Wave D2, §6)
# ============================================================================
# Produces the per-org CANDIDATE WEARER list that the on-fork seed builder reads
# authoritative state for (ACCESS-V2-SPEC.md §6: "enumerate wearers via event
# logs + fork reads"). The event logs give the candidate SET (who was ever
# minted a hat via POP's join path); the fork read (in the Solidity seed
# builder) decides who is CURRENTLY a member and with what eligibility source.
#
# Candidate sources (both are the real POP join path, and both index `user`, so
# the query is bounded to two single contracts per org — no global Hats scan):
#   - Executor.HatsMinted(address indexed user, uint256[] hatIds)
#   - QuickJoin.QuickJoined(address indexed user, uint256[] hatIds)
#
# Output: script/accessv2/fixtures/<org>.candidates.json  (a JSON address array,
# consumed by RehearseMigration via vm.parseJsonAddressArray).
#
# zsh word-split trap (memory): every chain/address is passed as an explicit arg.
# Usage: bash script/accessv2/tools/enumerate-wearers.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/script/accessv2/fixtures"
mkdir -p "$OUT"

HM_TOPIC="$(cast sig-event 'HatsMinted(address,uint256[])')"
QJ_TOPIC="$(cast sig-event 'QuickJoined(address,uint256[])')"

# enumerate <org> <rpc> <executor> <quickjoin> <orgId> <subgraph>
enumerate() {
  local org="$1" rpc="$2" exec="$3" qj="$4" orgid="$5" sg="$6"
  echo ">> $org  (rpc=$rpc)"
  local tmp
  tmp="$(mktemp)"
  cast logs --rpc-url "$rpc" --address "$exec" "$HM_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "import sys,json; [print('0x'+l['topics'][1][-40:]) for l in json.load(sys.stdin)]" >>"$tmp" || true
  cast logs --rpc-url "$rpc" --address "$qj"   "$QJ_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "import sys,json; [print('0x'+l['topics'][1][-40:]) for l in json.load(sys.stdin)]" >>"$tmp" || true
  # THIRD SOURCE — the legacy subgraph indexes EVERY mint path since genesis (deploy-time founder
  # mints, admin mints, EM direct mints), which the two join-path events above cannot see. This
  # closed a live gap: Test6/Poa/KUBI founders were absent from the event-only candidate set, so
  # the founder EOA was silently not seeded (caught post-cutover on Test6, 2026-08-27).
  curl -s -X POST "$sg" -H "Content-Type: application/json" \
    -d "{\"query\":\"{ users(where:{organization:\\\"$orgid\\\"}, first:1000){ address } }\"}" 2>/dev/null \
    | python3 -c "import sys,json
try:
    for u in json.load(sys.stdin)['data']['users']: print(u['address'])
except Exception: pass" >>"$tmp" || true
  # dedupe + drop zero, emit a JSON array
  python3 - "$tmp" "$OUT/$org.candidates.json" <<'PY'
import sys, json
src, dst = sys.argv[1], sys.argv[2]
seen = []
for line in open(src):
    a = line.strip().lower()
    if len(a) == 42 and a != "0x" + "0"*40 and a not in seen:
        seen.append(a)
json.dump(seen, open(dst, "w"), indent=2)
print(f"   {len(seen)} candidates -> {dst}")
PY
  rm -f "$tmp"
}

SG_GNOSIS="https://api.studio.thegraph.com/query/73367/poa-gnosis-v-1/version/latest"
SG_ARB="https://api.studio.thegraph.com/query/73367/poa-arb-v-1/version/latest"

enumerate test6         gnosis-gateway 0xA09F1035Ff97d17ccA40048F027c654b66B83183 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b "$SG_GNOSIS"
enumerate decentralpark gnosis-gateway 0x2A01133997abE2a001862cf0B03B22fe958FA4bC 0xBEba9EF99aa6E0693c22b60d4Ea5ed7C395F26f1 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78 "$SG_GNOSIS"
enumerate kubi          gnosis-gateway 0x23f90B3859818A843C3a848627A304Bc53947342 0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e "$SG_GNOSIS"
enumerate poa           arbitrum       0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069 "$SG_ARB"

echo "done."
