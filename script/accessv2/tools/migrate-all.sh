#!/usr/bin/env bash
# migrate-all.sh — run the ENTIRE remaining migration (DP -> POA -> KUBI) unattended.
# One command. Stops hard, with a plain explanation, the moment anything is not ✅.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root, wherever invoked from

if [ -f .env ]; then set -a; . ./.env; set +a; fi
KEY="${PRIVATE_KEY:-${DEPLOYER_PRIVATE_KEY:-}}"
[ -n "$KEY" ] || { echo "STOP: no PRIVATE_KEY / DEPLOYER_PRIVATE_KEY in .env"; exit 1; }
SENDER=0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
WINNER_TOPIC=$(cast keccak "Winner(uint256,uint256,bool,bool,uint64)")

org_cfg() { # sets CHAIN FORK HV GAS ORGFILE SIMNAME for $1
  case "$1" in
    DP)   CHAIN=gnosis;   FORK=gnosis-gateway; HV=0x1B80CA1EF7F274E141658A666fc12277957bF7A1; GAS=4000000; ORGFILE=decentralpark; SIMNAME=SimMigrateDecentralPark ;;
    POA)  CHAIN=arbitrum; FORK=arbitrum;       HV=0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5; GAS=4000000; ORGFILE=poa;           SIMNAME=SimMigratePoa ;;
    KUBI) CHAIN=gnosis;   FORK=gnosis-gateway; HV=0x13CBd5eD47bF177968B24D84516a75879c23971E; GAS=5000000; ORGFILE=kubi;          SIMNAME=SimMigrateKubi ;;
    *) echo "unknown org $1"; exit 1 ;;
  esac
}

verify_winner() { # $1 tx  $2 chain — succeeds iff Winner(valid=true, executed=true) and no swallow
  cast receipt "$1" --rpc-url "$2" --json | python3 -c "
import json,sys
r=json.load(sys.stdin)
if r['status']!='0x1':
    print('   STOP: announce tx reverted (likely voting window still open) — rerun this script; it resumes safely'); sys.exit(1)
for l in r['logs']:
    if l['topics'][0]=='$WINNER_TOPIC':
        d=bytes.fromhex(l['data'][2:])
        valid=int.from_bytes(d[0:32],'big')==1; executed=int.from_bytes(d[32:64],'big')==1
        if valid and executed: print('   ✅ EXECUTED'); sys.exit(0)
        if not valid: print('   STOP: proposal INVALID (quorum not met — for KUBI: the second voter did not vote in time). Proposal is burned; rerun this script to create a fresh one.'); sys.exit(1)
        print('   STOP: batch swallowed (executed=false). Do not proceed — send this output to Claude.'); sys.exit(1)
print('   STOP: no Winner event found — send this output to Claude.'); sys.exit(1)"
}

run_one() { # $1 org  $2 kind  $3 index  $4 minutes
  org_cfg "$1"
  local JSON="script/accessv2/out/${ORGFILE}.$2.$3.json"
  [ -f "$JSON" ] || { echo "STOP: $JSON missing"; exit 1; }
  echo "══ [$1] $2.$3 (window $4m, gas $GAS)"
  local OUT ID
  OUT=$(ORG=$1 KIND=$2 INDEX=$3 MINUTES=$4 FOUNDRY_PROFILE=production forge script \
        script/accessv2/MigrateOrgToAuthority.s.sol:CreateMigrationProposal \
        --rpc-url $CHAIN --broadcast --slow --sender $SENDER 2>&1) || true
  ID=$(echo "$OUT" | grep -oE "CREATED proposal #[0-9]+" | grep -oE "[0-9]+$" || true)
  [ -n "$ID" ] || { echo "$OUT" | tail -12; echo "STOP: create failed"; exit 1; }
  echo "   proposal #$ID created"
  ORG=$1 ID=$ID FOUNDRY_PROFILE=production forge script \
    script/accessv2/MigrateOrgToAuthority.s.sol:VoteMigrationProposal \
    --rpc-url $CHAIN --broadcast --slow --sender $SENDER >/dev/null 2>&1 || { echo "STOP: vote failed"; exit 1; }
  echo "   voted ✓"
  if [ "$1" = "KUBI" ]; then
    echo ""
    echo "   🔔🔔 KUBI: SECOND VOTER MUST VOTE ON PROPOSAL #$ID WITHIN $4 MINUTES (frontend) 🔔🔔"
    echo ""
  fi
  local W=$(( $4 * 60 + 60 ))
  echo "   waiting ${W}s..."
  sleep $W
  local TX
  TX=$(cast send $HV 'announceWinner(uint256)' $ID --gas-limit $GAS --rpc-url $CHAIN \
       --private-key "$KEY" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['transactionHash'])")
  echo "   announced: $TX"
  verify_winner "$TX" "$CHAIN"
}

regen() { # $1 org
  org_cfg "$1"
  bash script/accessv2/tools/enumerate-wearers.sh >/dev/null 2>&1
  bash script/accessv2/tools/enumerate-tm-perms.sh >/dev/null 2>&1
  ORG=$1 FOUNDRY_PROFILE=production forge script \
    script/accessv2/MigrateOrgToAuthority.s.sol:GenerateBatches --fork-url $FORK >/dev/null 2>&1 \
    || { echo "STOP: GenerateBatches failed for $1"; exit 1; }
  echo "── [$1] batches regenerated"
}

migrated() { # $1 org — true if this org's authority is already unpaused (cutover done)
  org_cfg "$1"
  local DDp=0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a
  local SALT ADDR P
  SALT=$(cast call --rpc-url $CHAIN $DDp "computeSalt(string,string)(bytes32)" "MembershipAuthorityProxy:$2" "v1" 2>/dev/null) || return 1
  ADDR=$(cast call --rpc-url $CHAIN $DDp "computeAddress(bytes32)(address)" $SALT 2>/dev/null) || return 1
  P=$(cast call --rpc-url $CHAIN $ADDR "paused()(bool)" 2>/dev/null) || return 1
  [ "$P" = "false" ]
}

do_org() { # $1 org  $2 SpecName  $3 minutes
  org_cfg "$1"
  if migrated "$1" "$2"; then echo "✅ [$1] already migrated — skipping"; return 0; fi
  echo "════════════ MIGRATING $1 ════════════"
  bash script/accessv2/tools/enumerate-wearers.sh >/dev/null 2>&1
  bash script/accessv2/tools/enumerate-tm-perms.sh >/dev/null 2>&1
  echo "── [$1] final rehearsal (a few minutes)..."
  FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:$SIMNAME \
    --fork-url $FORK 2>&1 | grep -q "governed migration sim complete" \
    || { echo "STOP: rehearsal for $1 did not PASS — do not proceed; send this to Claude"; exit 1; }
  echo "   rehearsal PASS ✓"
  ORG=$1 FOUNDRY_PROFILE=production forge script script/accessv2/MigrateOrgToAuthority.s.sol:PredeployAuthority \
    --rpc-url $CHAIN --broadcast --slow --sender $SENDER >/dev/null 2>&1 || { echo "STOP: predeploy failed"; exit 1; }
  echo "── [$1] authority predeployed ✓"
  regen "$1"
  local N i
  N=$(ls script/accessv2/out/${ORGFILE}.seed.*.json 2>/dev/null | wc -l | tr -d ' ')
  echo "── [$1] $N seed proposals + 1 cutover"
  i=1
  while [ $i -le $N ]; do
    # resume-safety: if a seed's memberships already landed, re-running is idempotent — always run.
    run_one "$1" seed $i "$3"
    i=$(( i + 1 ))
  done
  regen "$1"
  run_one "$1" cutover 1 "$3"
  echo "════════════ ✅ $1 MIGRATED ════════════"
}

# KUBI housekeeping: settle the three stale proposals first (tolerates already-settled).
kubi_settle() {
  org_cfg KUBI
  for id in 21 22 23; do
    local TX
    TX=$(cast send $HV 'announceWinner(uint256)' $id --gas-limit 3000000 --rpc-url $CHAIN \
         --private-key "$KEY" --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('transactionHash','none'))" 2>/dev/null || echo none)
    echo "── KUBI settle #$id: ${TX}"
  done
}

ORGS="${ORGS:-DP POA}"   # default: DP + POA. For KUBI later: ORGS=KUBI bash script/accessv2/tools/migrate-all.sh
for O in $ORGS; do
  case "$O" in
    DP)   do_org DP  "DecentralPark" 15 ;;
    POA)  do_org POA "Poa"           15 ;;
    KUBI)
      echo ""
      echo "🔔 KUBI: 6 proposals, 30-minute windows each. If their quorum is now 2,"
      echo "   the second voter must vote on EVERY proposal — watch for the 🔔 lines."
      echo ""
      kubi_settle
      do_org KUBI "KUBI" 30 ;;
  esac
done

echo ""
echo "🎉 DONE: $ORGS migrated. Verify each org's page in the app."
