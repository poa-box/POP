#!/usr/bin/env bash
# ============================================================================
# enumerate-tm-perms.sh — Access-v2 TaskManager permission-mask enumerator (A2, §4/§6)
# ============================================================================
# Produces the per-org TaskManager permission table the on-fork seed builder reads
# (ACCESS-V2-SPEC.md §4 — "perm table from the audited module inventory"). There is
# NO getter for rolePermGlobal / rolePermProj, so the ONLY source of truth is the
# module's own event stream, folded LAST-WRITE-WINS per key:
#
#   - RolePermSet(uint256 indexed hatId, uint8 mask)                      → global mask per hat
#   - ProjectRolePermSet(bytes32 indexed id, uint256 indexed hatId, uint8 mask) → per-project mask
#
# Both setters (bootstrap / setConfig(ROLE_PERM) for global; _setBatchHatPerm /
# setProjectRolePerm for project) EMIT the resulting stored mask, so replaying the
# events in block/logIndex order and keeping the last value per (hat) / (pid,hat)
# reproduces the exact live storage. project ids (pid) are sequential uint256 the
# event carries as bytes32 — the authority arm queries ctx = bytes32(uint256(pid)+1)
# (TaskManager.sol _permMask, freeze amendment W4), so the seed builder shifts by +1;
# the FIXTURE stores the RAW pid (uint256), the shift happens seed-side.
#
# Output: script/accessv2/fixtures/<org>.tmperms.json — five parallel arrays
#   { globalHats[], globalMasks[], projPids[], projHats[], projMasks[] }
# consumed by AccessV2MigrationBase via vm.parseJsonUintArray. hat/pid values are
# quoted hex strings (safe for full uint256); masks are 0..255 numbers.
# Zero-mask project rows are DROPPED (§4: "zero-mask rows never materialized" — a
# 0 project mask falls through to global in the legacy arm, so it must NOT be seeded).
#
# zsh word-split trap (memory): every chain/address is passed as an explicit arg.
# Usage: bash script/accessv2/tools/enumerate-tm-perms.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/script/accessv2/fixtures"
mkdir -p "$OUT"

RP_TOPIC="$(cast sig-event 'RolePermSet(uint256,uint8)')"
PP_TOPIC="$(cast sig-event 'ProjectRolePermSet(bytes32,uint256,uint8)')"

# enumerate <org> <rpc> <taskManager>
enumerate() {
  local org="$1" rpc="$2" tm="$3"
  echo ">> $org  (rpc=$rpc, tm=$tm)"
  local gtmp ptmp
  gtmp="$(mktemp)"
  ptmp="$(mktemp)"
  # RolePermSet: topics[1]=hatId, data=mask. Emit "block logIndex hatId mask" per line.
  cast logs --rpc-url "$rpc" --address "$tm" "$RP_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "
import sys,json
for l in json.load(sys.stdin):
    bn=int(l['blockNumber'],16); li=int(l['logIndex'],16)
    hat=int(l['topics'][1],16); mask=int(l['data'],16)&0xff
    print(bn,li,hex(hat),mask)
" >>"$gtmp" || true
  # ProjectRolePermSet: topics[1]=pid(bytes32), topics[2]=hatId, data=mask.
  cast logs --rpc-url "$rpc" --address "$tm" "$PP_TOPIC" --from-block 0 --json 2>/dev/null \
    | python3 -c "
import sys,json
for l in json.load(sys.stdin):
    bn=int(l['blockNumber'],16); li=int(l['logIndex'],16)
    pid=int(l['topics'][1],16); hat=int(l['topics'][2],16); mask=int(l['data'],16)&0xff
    print(bn,li,hex(pid),hex(hat),mask)
" >>"$ptmp" || true

  python3 - "$gtmp" "$ptmp" "$OUT/$org.tmperms.json" <<'PY'
import sys, json
gsrc, psrc, dst = sys.argv[1], sys.argv[2], sys.argv[3]

# Global: last-write-wins per hat, ordered by (block, logIndex).
grows = []
for line in open(gsrc):
    p = line.split()
    if len(p) != 4: continue
    grows.append((int(p[0]), int(p[1]), p[2], int(p[3])))
grows.sort(key=lambda r: (r[0], r[1]))
gmask = {}
for _, _, hat, mask in grows:
    gmask[hat] = mask  # last wins

# Project: last-write-wins per (pid, hat).
prows = []
for line in open(psrc):
    p = line.split()
    if len(p) != 5: continue
    prows.append((int(p[0]), int(p[1]), p[2], p[3], int(p[4])))
prows.sort(key=lambda r: (r[0], r[1]))
pmask = {}
for _, _, pid, hat, mask in prows:
    pmask[(pid, hat)] = mask  # last wins

globalHats, globalMasks = [], []
for hat, mask in gmask.items():
    globalHats.append(hat)      # keep every global row (mask may be 0 = explicitly cleared)
    globalMasks.append(mask)

projPids, projHats, projMasks = [], [], []
for (pid, hat), mask in pmask.items():
    if mask == 0:
        continue  # §4: zero-mask project rows never materialized (fall through to global)
    projPids.append(pid)
    projHats.append(hat)
    projMasks.append(mask)

out = {
    "globalHats": globalHats,
    "globalMasks": globalMasks,
    "projPids": projPids,
    "projHats": projHats,
    "projMasks": projMasks,
}
json.dump(out, open(dst, "w"), indent=2)
print(f"   global rows: {len(globalHats)}  project rows(nonzero): {len(projPids)}  -> {dst}")
PY
  rm -f "$gtmp" "$ptmp"
}

enumerate test6         gnosis-gateway 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc
enumerate decentralpark gnosis-gateway 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7
enumerate kubi          gnosis-gateway 0xF57024fC77915Fce8f2608afdd027941bCEE3336
enumerate poa           arbitrum       0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0

echo "done."
