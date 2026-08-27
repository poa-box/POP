#!/usr/bin/env bash
# ============================================================================
# run-proposal.sh — ONE command per migration proposal: create → vote → wait →
# announceWinner → verify the batch actually executed.
#
#   Usage:  bash script/accessv2/tools/run-proposal.sh <ORG> <KIND> <INDEX> [MINUTES]
#   e.g.:   bash script/accessv2/tools/run-proposal.sh TEST6 seed 2
#           bash script/accessv2/tools/run-proposal.sh TEST6 cutover 1
#
# Requires: source .env first (DEPLOYER_PRIVATE_KEY); run from the repo root.
# For KUBI (voting quorum 2): this script casts YOUR vote, then waits the window —
# have the second voter vote (frontend) DURING that window before it announces.
# ============================================================================
set -euo pipefail

# Self-contained: load .env from the repo root ourselves (forge does this too; plain shells do not).
if [ -f .env ]; then set -a; . ./.env; set +a; fi
# Key resolution matches the forge scripts: PRIVATE_KEY first, then DEPLOYER_PRIVATE_KEY.
KEY="${PRIVATE_KEY:-${DEPLOYER_PRIVATE_KEY:-}}"
[ -n "$KEY" ] || { echo "❌ no PRIVATE_KEY / DEPLOYER_PRIVATE_KEY in .env or the environment"; exit 1; }

ORG="${1:?ORG required: TEST6|DP|KUBI|POA}"
KIND="${2:?KIND required: seed|cutover}"
INDEX="${3:?INDEX required}"
MINUTES="${4:-15}"

SENDER=0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
PEF_TOPIC=0x0ae3aa696c9a6a8953133664900a83b143226935d35bf0af3a07b0652f1802cf

case "$ORG" in
  TEST6) CHAIN=gnosis;   HV=0xF642DdE77848dC195c8089F4042A311Ed650d7a6; GAS=4000000; ORGFILE=test6 ;;
  DP)    CHAIN=gnosis;   HV=0x1B80CA1EF7F274E141658A666fc12277957bF7A1; GAS=4000000; ORGFILE=decentralpark ;;
  KUBI)  CHAIN=gnosis;   HV=0x13CBd5eD47bF177968B24D84516a75879c23971E; GAS=5000000; ORGFILE=kubi ;;
  POA)   CHAIN=arbitrum; HV=0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5; GAS=4000000; ORGFILE=poa ;;
  *) echo "unknown ORG $ORG"; exit 1 ;;
esac

JSON="script/accessv2/out/${ORGFILE}.${KIND}.${INDEX}.json"
[ -f "$JSON" ] || { echo "❌ $JSON not found — run GenerateBatches first"; exit 1; }

echo "══ [$ORG] $KIND.$INDEX on $CHAIN (window ${MINUTES}m, announce gas $GAS)"

# 1. CREATE — capture the proposal id from the helper's output.
CREATE_OUT=$(ORG=$ORG KIND=$KIND INDEX=$INDEX MINUTES=$MINUTES FOUNDRY_PROFILE=production \
  forge script script/accessv2/MigrateOrgToAuthority.s.sol:CreateMigrationProposal \
  --rpc-url $CHAIN --broadcast --slow --sender $SENDER 2>&1)
echo "$CREATE_OUT" | grep -E "CREATED proposal" || { echo "$CREATE_OUT" | tail -15; echo "❌ create failed"; exit 1; }
ID=$(echo "$CREATE_OUT" | grep -oE "CREATED proposal #[0-9]+" | grep -oE "[0-9]+$")
echo "   proposal id: $ID"

# 2. VOTE (option 0, weight 100) from the operator key.
ORG=$ORG ID=$ID FOUNDRY_PROFILE=production \
  forge script script/accessv2/MigrateOrgToAuthority.s.sol:VoteMigrationProposal \
  --rpc-url $CHAIN --broadcast --slow --sender $SENDER > /dev/null 2>&1 \
  && echo "   voted ✓" || { echo "❌ vote failed"; exit 1; }

[ "$ORG" = "KUBI" ] && echo "   ⚠️  KUBI quorum=2: have the SECOND voter vote on proposal #$ID within the next ${MINUTES} minutes."

# 3. WAIT out the vote window (+45s buffer for block timestamps).
WAIT=$(( MINUTES * 60 + 45 ))
echo "   waiting ${WAIT}s for the vote window to close..."
sleep $WAIT

# 4. ANNOUNCE with the explicit gas limit (try/catch defeats estimation).
TX=$(cast send $HV 'announceWinner(uint256)' $ID --gas-limit $GAS --rpc-url $CHAIN \
  --private-key "$KEY" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['transactionHash'])")
echo "   announced: $TX"

# 5. VERIFY: tx succeeded AND no ProposalExecutionFailed (a swallowed batch = burned proposal).
cast receipt "$TX" --rpc-url $CHAIN --json | python3 -c "
import json,sys
r=json.load(sys.stdin)
ok = r['status']=='0x1' and all(l['topics'][0]!='$PEF_TOPIC' for l in r['logs'])
print('   ✅ EXECUTED — safe to run the next proposal' if ok else '   ❌ BATCH FAILED (swallowed) — STOP. Do not proceed; this proposal is burned. Diagnose, then re-create it.')
exit(0 if ok else 1)"
