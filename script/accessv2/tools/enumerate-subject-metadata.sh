#!/usr/bin/env bash
# ============================================================================
# enumerate-subject-metadata.sh — canonical legacy role-name/CID snapshots
# ============================================================================
# EligibilityModule writes a nonzero metadata CID into Hats.details as a hex
# string, so viewHat() alone cannot recover the semantic role name. This tool
# folds HatMetadataUpdated(uint256,string,bytes32) events last-write-wins and
# writes the deterministic fixture consumed by AccessV2MigrationBase.
#
# Hats maxSupply and imageURI remain live fork reads during migration. The
# builder reconciles every CID-shaped details value against this fixture and
# fails closed on a missing/stale row.
#
# Output: script/accessv2/fixtures/<org>.subjectmeta.json
#   { hatIds[], names[], metadataCIDs[] }
#
# Usage: bash script/accessv2/tools/enumerate-subject-metadata.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/script/accessv2/fixtures"
mkdir -p "$OUT"

META_TOPIC="$(cast sig-event 'HatMetadataUpdated(uint256,string,bytes32)')"

# enumerate <org> <rpc> <eligibility-module>
enumerate() {
  local org="$1" rpc="$2" eligibility="$3"
  local tmp
  echo ">> $org  (rpc=$rpc, eligibility=$eligibility)"
  tmp="$(mktemp)"
  cast logs --rpc-url "$rpc" --address "$eligibility" "$META_TOPIC" --from-block 0 --json >"$tmp"

  python3 - "$tmp" "$OUT/$org.subjectmeta.json" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
events = json.load(open(src))
events.sort(key=lambda log: (int(log["blockNumber"], 16), int(log["logIndex"], 16)))

latest = {}
for log in events:
    hat_id = int(log["topics"][1], 16)
    raw = bytes.fromhex(log["data"][2:])
    if len(raw) < 96:
        raise ValueError(f"short HatMetadataUpdated data for {hex(hat_id)}")
    name_offset = int.from_bytes(raw[0:32], "big")
    metadata_cid = raw[32:64]
    if name_offset + 32 > len(raw):
        raise ValueError(f"invalid name offset for {hex(hat_id)}")
    name_length = int.from_bytes(raw[name_offset:name_offset + 32], "big")
    name_start = name_offset + 32
    name_end = name_start + name_length
    if name_end > len(raw):
        raise ValueError(f"invalid name length for {hex(hat_id)}")
    name = raw[name_start:name_end].decode("utf-8")
    if not name:
        raise ValueError(f"empty canonical name for {hex(hat_id)}")
    latest[hat_id] = (name, "0x" + metadata_cid.hex())

hat_ids, names, metadata_cids = [], [], []
for hat_id in sorted(latest):
    name, metadata_cid = latest[hat_id]
    hat_ids.append(hex(hat_id))
    names.append(name)
    metadata_cids.append(metadata_cid)

with open(dst, "w") as out:
    json.dump(
        {"hatIds": hat_ids, "names": names, "metadataCIDs": metadata_cids},
        out,
        indent=2,
    )
    out.write("\n")
print(f"   {len(hat_ids)} canonical metadata rows -> {dst}")
PY
  rm -f "$tmp"
}

enumerate test6         gnosis-gateway 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B
enumerate decentralpark gnosis-gateway 0xe4A02F20B8282A272879e31479Ee070dab07B015
enumerate kubi          gnosis-gateway 0x27114Cb757BeDF77E30EeB0Ca635e3368d8C2914
enumerate poa           arbitrum       0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b

echo "done."
