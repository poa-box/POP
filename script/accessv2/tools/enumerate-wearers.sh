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

# enumerate <org> <rpc> <executor> <quickjoin>
enumerate() {
  local org="$1" rpc="$2" exec="$3" qj="$4"
  echo ">> $org  (rpc=$rpc)"
  local tmp
  tmp="$(mktemp)"
  cast logs --rpc-url "$rpc" --address "$exec" "$HM_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "import sys,json; [print('0x'+l['topics'][1][-40:]) for l in json.load(sys.stdin)]" >>"$tmp" || true
  cast logs --rpc-url "$rpc" --address "$qj"   "$QJ_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "import sys,json; [print('0x'+l['topics'][1][-40:]) for l in json.load(sys.stdin)]" >>"$tmp" || true
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

enumerate test6         gnosis-gateway 0xA09F1035Ff97d17ccA40048F027c654b66B83183 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d
enumerate decentralpark gnosis-gateway 0x2A01133997abE2a001862cf0B03B22fe958FA4bC 0xBEba9EF99aa6E0693c22b60d4Ea5ed7C395F26f1
enumerate kubi          gnosis-gateway 0x23f90B3859818A843C3a848627A304Bc53947342 0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf
enumerate poa           arbitrum       0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a

echo "done."
