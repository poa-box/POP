#!/usr/bin/env bash
# migrate-kubi.sh — KUBI (Kansas Blockchain) migration with 12-hour vote windows (quorum 2).
#
# Differs from migrate-all.sh: seed proposals are created+voted UP FRONT (they are
# independent until announced; announcing in index order preserves chunk ordering),
# so the second voter is asked to vote only TWICE:
#   round 1: all 5 seed proposals   (one 12h window)
#   round 2: the cutover proposal   (one 12h window, after seeds execute + regen)
# Total wall time ≈ 24h. Resume-safe: created proposal ids persist in out/kubi.state/;
# rerunning after ANY interruption picks up exactly where it left off.
#
#   caffeinate -i bash script/accessv2/tools/migrate-kubi.sh 2>&1 | tee kubi-migration.log
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root, wherever invoked from

if [ -f .env ]; then set -a; . ./.env; set +a; fi
KEY="${PRIVATE_KEY:-${DEPLOYER_PRIVATE_KEY:-}}"
[ -n "$KEY" ] || { echo "STOP: no PRIVATE_KEY / DEPLOYER_PRIVATE_KEY in .env"; exit 1; }
SENDER=0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
WINNER_TOPIC=$(cast keccak "Winner(uint256,uint256,bool,bool,uint64)")

CHAIN=gnosis
FORK=gnosis-gateway
HV=0x13CBd5eD47bF177968B24D84516a75879c23971E
HV_LC=$(echo "$HV" | tr 'A-F' 'a-f')
GAS=5000000
MINUTES="${KUBI_MINUTES:-720}"   # 12h windows (override: KUBI_MINUTES=30 for a drill)
STATE=script/accessv2/out/kubi.state
SUBGRAPH='https://api.studio.thegraph.com/query/73367/poa-gnosis-v-1/version/latest'
mkdir -p "$STATE"

migrated() { # true if KUBI's authority is already unpaused (cutover done)
  local DDp=0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a SALT ADDR P
  SALT=$(cast call --rpc-url $CHAIN $DDp "computeSalt(string,string)(bytes32)" "MembershipAuthorityProxy:KUBI" "v1" 2>/dev/null) || return 1
  ADDR=$(cast call --rpc-url $CHAIN $DDp "computeAddress(bytes32)(address)" $SALT 2>/dev/null) || return 1
  P=$(cast call --rpc-url $CHAIN $ADDR "paused()(bool)" 2>/dev/null) || return 1
  [ "$P" = "false" ]
}

vote_count() { # $1 proposal id -> prints the subgraph's vote count (may lag ~a minute)
  curl -s -X POST "$SUBGRAPH" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ proposal(id: \\\"${HV_LC}-$1\\\") { votes { id } } }\"}" 2>/dev/null \
    | python3 -c "import json,sys
try: print(len(json.load(sys.stdin)['data']['proposal']['votes']))
except Exception: print('?')" 2>/dev/null || echo "?"
}

create_and_vote() { # $1 kind  $2 index — creates (or resumes) + votes; sets CV_ID
  local IDFILE="$STATE/$1.$2.id" OUT ID
  if [ -f "$IDFILE" ]; then
    CV_ID=$(cat "$IDFILE")
    # Re-attempt the self-vote (no-op revert if already voted) — covers a crash between create and vote.
    ORG=KUBI ID=$CV_ID FOUNDRY_PROFILE=production forge script \
      script/accessv2/MigrateOrgToAuthority.s.sol:VoteMigrationProposal \
      --rpc-url $CHAIN --broadcast --slow --sender $SENDER >/dev/null 2>&1 || true
    echo "── [KUBI] $1.$2: resuming as proposal #$CV_ID (created; self-vote ensured)"
    return 0
  fi
  local JSON="script/accessv2/out/kubi.$1.$2.json"
  [ -f "$JSON" ] || { echo "STOP: $JSON missing"; exit 1; }
  OUT=$(ORG=KUBI KIND=$1 INDEX=$2 MINUTES=$MINUTES FOUNDRY_PROFILE=production forge script \
        script/accessv2/MigrateOrgToAuthority.s.sol:CreateMigrationProposal \
        --rpc-url $CHAIN --broadcast --slow --sender $SENDER 2>&1) || true
  ID=$(echo "$OUT" | grep -oE "CREATED proposal #[0-9]+" | grep -oE "[0-9]+$" || true)
  [ -n "$ID" ] || { echo "$OUT" | tail -12; echo "STOP: create failed for $1.$2"; exit 1; }
  echo "$ID" > "$IDFILE"
  ORG=KUBI ID=$ID FOUNDRY_PROFILE=production forge script \
    script/accessv2/MigrateOrgToAuthority.s.sol:VoteMigrationProposal \
    --rpc-url $CHAIN --broadcast --slow --sender $SENDER >/dev/null 2>&1 \
    || { echo "STOP: your vote on #$ID failed"; exit 1; }
  echo "── [KUBI] $1.$2: created proposal #$ID, your vote cast (1/2)"
  CV_ID=$ID
}

wait_out_window() { # $@ = proposal ids — waits until every window closed; polls vote counts
  local END=0 E id NOW LEFT LINE C WARNED=0
  for id in "$@"; do
    E=$(cast call $HV 'proposalEndTimestamp(uint256)(uint64)' "$id" --rpc-url $CHAIN 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    [ -n "$E" ] && [ "$E" -gt "$END" ] && END=$E
  done
  [ "$END" -gt 0 ] || { echo "STOP: could not read window end from chain"; exit 1; }
  echo "   window closes: $(date -r $END '+%a %H:%M:%S') — polling vote counts every 30 min"
  while :; do
    NOW=$(date +%s); LEFT=$(( END + 45 - NOW ))
    [ $LEFT -le 0 ] && break
    LINE=""
    for id in "$@"; do C=$(vote_count "$id"); LINE="$LINE #$id:${C}/2"; done
    echo "   [$(date '+%H:%M')] votes (subgraph):$LINE — $(( LEFT / 60 ))m left"
    if [ $LEFT -lt 7200 ] && [ $WARNED -eq 0 ]; then
      for id in "$@"; do
        C=$(vote_count "$id")
        if [ "$C" != "?" ] && [ "$C" -lt 2 ]; then
          echo ""
          echo "   🔔🔔🔔 UNDER 2h LEFT AND PROPOSAL #$id HAS $C/2 VOTES — GET THE SECOND VOTER NOW 🔔🔔🔔"
          echo ""
          WARNED=1
        fi
      done
    fi
    sleep $(( LEFT < 1800 ? LEFT : 1800 ))
  done
}

announce_and_verify() { # $1 proposal id — announce; PASS iff Winner(valid=true, executed=true)
  local id=$1 TX
  if ! cast call $HV 'announceWinner(uint256)' "$id" --from $SENDER --rpc-url $CHAIN >/dev/null 2>&1; then
    local ERR
    ERR=$(cast call $HV 'announceWinner(uint256)' "$id" --from $SENDER --rpc-url $CHAIN 2>&1 | grep -oE '0x[0-9a-f]{8}' | head -1 || true)
    if [ "$ERR" = "0x0dc10197" ]; then # AlreadyExecuted — a previous run announced it
      echo "   #$id: already announced (previous run) — continuing"
      return 0
    fi
    echo "   waiting 120s (announce not ready: $ERR)..."; sleep 120
  fi
  TX=$(cast send $HV 'announceWinner(uint256)' "$id" --gas-limit $GAS --rpc-url $CHAIN \
       --private-key "$KEY" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['transactionHash'])")
  echo "   #$id announced: $TX"
  cast receipt "$TX" --rpc-url $CHAIN --json | python3 -c "
import json,sys
r=json.load(sys.stdin)
if r['status']!='0x1':
    print('   STOP: announce tx reverted — rerun this script; it resumes safely'); sys.exit(1)
for l in r['logs']:
    if l['topics'][0]=='$WINNER_TOPIC':
        d=bytes.fromhex(l['data'][2:])
        valid=int.from_bytes(d[0:32],'big')==1; executed=int.from_bytes(d[32:64],'big')==1
        if valid and executed: print('   ✅ #$id EXECUTED'); sys.exit(0)
        if not valid:
            print('   STOP: proposal #$id INVALID — the second voter did not vote in time (quorum 2).')
            print('   The proposal is burned. Fix: delete its id file under $STATE/ and rerun this')
            print('   script — it will re-create ONLY that proposal (fresh 12h window).'); sys.exit(1)
        print('   STOP: #$id batch swallowed (executed=false). Do not proceed — send this output to Claude.'); sys.exit(1)
print('   STOP: no Winner event on #$id — send this output to Claude.'); sys.exit(1)"
}

regen() {
  bash script/accessv2/tools/enumerate-wearers.sh >/dev/null 2>&1
  bash script/accessv2/tools/enumerate-tm-perms.sh >/dev/null 2>&1
  ORG=KUBI FOUNDRY_PROFILE=production forge script \
    script/accessv2/MigrateOrgToAuthority.s.sol:GenerateBatches --fork-url $FORK >/dev/null 2>&1 \
    || { echo "STOP: GenerateBatches failed"; exit 1; }
  echo "── [KUBI] batches regenerated"
}

# ════════════════════════════════════════════════════════════════════════════
if migrated; then echo "✅ KUBI already migrated — nothing to do"; exit 0; fi
echo "════════════ MIGRATING KUBI (windows: ${MINUTES}m, quorum 2) ════════════"

# Phase 1: rehearsal + predeploy + regen — skipped entirely once seeds exist (resume).
if [ ! -f "$STATE/seed.1.id" ]; then
  bash script/accessv2/tools/enumerate-wearers.sh >/dev/null 2>&1
  bash script/accessv2/tools/enumerate-tm-perms.sh >/dev/null 2>&1
  echo "── [KUBI] final rehearsal (a few minutes)..."
  FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:SimMigrateKubi \
    --fork-url $FORK 2>&1 | grep -q "governed migration sim complete" \
    || { echo "STOP: rehearsal did not PASS — do not proceed; send this to Claude"; exit 1; }
  echo "   rehearsal PASS ✓"
  ORG=KUBI FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:PredeployAuthority \
    --rpc-url $CHAIN --broadcast --slow --sender $SENDER >/dev/null 2>&1 || { echo "STOP: predeploy failed"; exit 1; }
  echo "── [KUBI] authority predeployed ✓"
  regen
fi

# Phase 2: create + self-vote ALL seed proposals up front (announce order enforces chunk order).
N=$(ls script/accessv2/out/kubi.seed.*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$N" -ge 1 ] || { echo "STOP: no kubi.seed.*.json files"; exit 1; }
SEED_IDS=()
for i in $(seq 1 $N); do create_and_vote seed $i; SEED_IDS+=("$CV_ID"); done

if [ ! -f "$STATE/seeds.done" ]; then
  echo ""
  echo "   🔔🔔 ROUND 1 — SECOND VOTER: vote (option 1) on ALL of these KUBI proposals 🔔🔔"
  echo "   🔔🔔    proposal ids: ${SEED_IDS[*]}  — deadline ≈ $(date -v+${MINUTES}M '+%a %H:%M') 🔔🔔"
  echo ""
  # Phase 3: wait out the shared window, then announce IN ORDER (seed.N may depend on seed.N-1).
  wait_out_window "${SEED_IDS[@]}"
  for id in "${SEED_IDS[@]}"; do announce_and_verify "$id"; done
  touch "$STATE/seeds.done"
  echo "── [KUBI] all $N seed proposals executed ✓"
fi

# Phase 4: regenerate the cutover AFTER seeds landed (CutoverVerifier counts bake at generation),
# then run it through its own 12h window. Regen is skipped when resuming mid-cutover.
if [ ! -f "$STATE/cutover.1.id" ]; then regen; fi
create_and_vote cutover 1
CUT_ID=$CV_ID
if [ ! -f "$STATE/cutover.done" ]; then
  echo ""
  echo "   🔔🔔 ROUND 2 (FINAL) — SECOND VOTER: vote (option 1) on KUBI proposal #$CUT_ID 🔔🔔"
  echo "   🔔🔔    deadline ≈ $(date -v+${MINUTES}M '+%a %H:%M') 🔔🔔"
  echo ""
  wait_out_window "$CUT_ID"
  announce_and_verify "$CUT_ID"
  touch "$STATE/cutover.done"
fi

# Phase 5: the arbiter — the authority must be live (unpaused) on-chain.
if migrated; then
  echo ""
  echo "════════════ 🎉 KUBI MIGRATED — verify the org page in the app ════════════"
else
  echo "STOP: cutover announced but the authority is still paused — send this output to Claude"
  exit 1
fi
