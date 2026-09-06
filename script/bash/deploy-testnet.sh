#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# deploy-testnet.sh - Full cross-chain protocol deployment on testnets
#
# Orchestrates MainDeploy.s.sol across 2 chains:
#   Home:      Sepolia
#   Satellite: Base Sepolia
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY (funded on both Sepolia and Base Sepolia)
#   - jq (for JSON parsing: brew install jq)
#   - foundry.toml with RPC endpoints configured
#
# Usage:
#   ./script/bash/deploy-testnet.sh                  # Full deployment (all 4 steps)
#   ./script/bash/deploy-testnet.sh --step 1         # Deploy home chain only
#   ./script/bash/deploy-testnet.sh --step 2         # Deploy satellite
#   ./script/bash/deploy-testnet.sh --step 3         # Register satellite + transfer ownership
#   ./script/bash/deploy-testnet.sh --step 4         # Verify deployment
#   ./script/bash/deploy-testnet.sh --step summary   # Print deployed addresses
#   ./script/bash/deploy-testnet.sh --dry-run        # Simulate without broadcasting
#   ./script/bash/deploy-testnet.sh --yes            # Skip confirmation prompt
#############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/../config/main-deploy-state.json"

# ═══════════════════════════ Chain Configuration ═══════════════════════════

# Home Chain: Sepolia
HOME_RPC="sepolia"
HOME_DOMAIN=11155111
HOME_MAILBOX="0xfFAEF09B3cd11D9b20d1a19bECca54EEC2884766"

# Satellite Chain: Base Sepolia
SAT_NAMES=("Base Sepolia")
SAT_RPCS=("base-sepolia")
SAT_DOMAINS=(84532)
SAT_MAILBOXES=(
    "0x6966b0E55883d49BFB24539356a2f8A673E02039"
)

# ═══════════════════════════ Output Helpers ═══════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ═══════════════════════════ JSON Helper ═══════════════════════════

json_get() {
    jq -r ".$2" "$1"
}

# ═══════════════════════════ Argument Parsing ═══════════════════════════

STEP=""
DRY_RUN=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step)       STEP="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --yes|-y)     SKIP_CONFIRM=true; shift ;;
        --help|-h)
            echo "Usage: ./script/bash/deploy-testnet.sh [OPTIONS]"
            echo ""
            echo "Deploys full POA protocol on Sepolia (home) + Base Sepolia (satellite)."
            echo ""
            echo "Steps:"
            echo "  1  Deploy home chain infrastructure + governance org (Sepolia)"
            echo "  2  Deploy satellite infrastructure (Base Sepolia)"
            echo "  3  Register satellite on Hub + transfer ownership to governance"
            echo "  4  Verify deployment (read-only)"
            echo ""
            echo "Options:"
            echo "  --step N       Run only step N (1-4, or 'summary')"
            echo "  --dry-run      Simulate without broadcasting transactions"
            echo "  --yes, -y      Skip confirmation prompt"
            echo "  --help, -h     Show this help"
            exit 0
            ;;
        *)  error "Unknown option: $1"; exit 1 ;;
    esac
done

# ═══════════════════════════ Environment ═══════════════════════════

load_env() {
    if [ -f "$PROJECT_DIR/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/.env"
        set +a
    fi

    # Prevent .env from overriding chain-specific vars managed by this script
    unset MAILBOX SATELLITE_DOMAIN HUB_DOMAIN 2>/dev/null || true

    # Support both PRIVATE_KEY and DEPLOYER_PRIVATE_KEY
    if [ -z "${PRIVATE_KEY:-}" ] && [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
        export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"
    fi

    if [ -z "${PRIVATE_KEY:-}" ]; then
        error "PRIVATE_KEY (or DEPLOYER_PRIVATE_KEY) not set. Add it to .env"
        exit 1
    fi
}

# ═══════════════════════════ Error Handling ═══════════════════════════

CURRENT_STEP=""
CURRENT_STEP_NUM=""

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "${CURRENT_STEP:-}" ]; then
        echo ""
        error "Failed during: ${CURRENT_STEP}"
        echo ""
        if [ -n "${CURRENT_STEP_NUM:-}" ]; then
            error "To resume, run:"
            error "  ./script/bash/deploy-testnet.sh --step $CURRENT_STEP_NUM"
        fi
    fi
}
trap cleanup EXIT

# ═══════════════════════════ Pre-flight Checks ═══════════════════════════

preflight_checks() {
    header "Pre-flight Checks"

    if ! command -v forge &>/dev/null; then
        error "forge not found. Install Foundry first."
        exit 1
    fi
    if ! command -v cast &>/dev/null; then
        error "cast not found. Install Foundry first."
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        error "jq required for JSON parsing. Install with: brew install jq"
        exit 1
    fi

    # Derive deployer address
    DEPLOYER_ADDRESS=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null) || {
        error "Invalid PRIVATE_KEY. Could not derive address."
        exit 1
    }
    info "Deployer: $DEPLOYER_ADDRESS"
    echo ""

    # Check RPC connectivity and balances
    local all_rpcs=("$HOME_RPC" "${SAT_RPCS[@]}")
    local all_names=("Sepolia (home)" "${SAT_NAMES[@]}")

    for i in "${!all_rpcs[@]}"; do
        local rpc="${all_rpcs[$i]}"
        local name="${all_names[$i]}"

        local balance
        balance=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$rpc" 2>/dev/null) || {
            error "Cannot reach $name (--rpc-url $rpc). Check foundry.toml."
            exit 1
        }
        local eth_balance
        eth_balance=$(cast from-wei "$balance" 2>/dev/null || echo "?")
        info "$name: $eth_balance ETH"
    done

    echo ""

    # Verify external contracts exist on Sepolia
    info "Checking external contracts on Sepolia..."
    local hats_code
    hats_code=$(cast code 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137 --rpc-url sepolia 2>/dev/null)
    if [ "$hats_code" = "0x" ] || [ -z "$hats_code" ]; then
        error "Hats Protocol not deployed on Sepolia at 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137"
        exit 1
    fi
    success "Hats Protocol: deployed"

    local ep_code
    ep_code=$(cast code 0x0000000071727De22E5E9d8BAf0edAc6f37da032 --rpc-url sepolia 2>/dev/null)
    if [ "$ep_code" = "0x" ] || [ -z "$ep_code" ]; then
        error "EntryPoint v0.7 not deployed on Sepolia"
        exit 1
    fi
    success "EntryPoint v0.7: deployed"

    echo ""

    # Verify external contracts exist on Base Sepolia
    info "Checking external contracts on Base Sepolia..."
    local sat_hats_code
    sat_hats_code=$(cast code 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137 --rpc-url base-sepolia 2>/dev/null)
    if [ "$sat_hats_code" = "0x" ] || [ -z "$sat_hats_code" ]; then
        error "Hats Protocol not deployed on Base Sepolia"
        exit 1
    fi
    success "Hats Protocol on Base Sepolia: deployed"

    local sat_ep_code
    sat_ep_code=$(cast code 0x0000000071727De22E5E9d8BAf0edAc6f37da032 --rpc-url base-sepolia 2>/dev/null)
    if [ "$sat_ep_code" = "0x" ] || [ -z "$sat_ep_code" ]; then
        error "EntryPoint v0.7 not deployed on Base Sepolia"
        exit 1
    fi
    success "EntryPoint v0.7 on Base Sepolia: deployed"

    echo ""

    # Build with production profile (via_ir + optimizer to stay under contract size limit)
    # --skip test avoids Yul optimizer stack-too-deep in DeployerTest.t.sol
    info "Building contracts (FOUNDRY_PROFILE=production)..."
    FOUNDRY_PROFILE=production forge build --skip test --silent
    success "Build complete."
}

preflight_checks_minimal() {
    header "Pre-flight Checks (read-only)"

    if ! command -v forge &>/dev/null; then
        error "forge not found. Install Foundry first."
        exit 1
    fi

    cast chain-id --rpc-url "$HOME_RPC" &>/dev/null || {
        error "Cannot reach home chain (--rpc-url $HOME_RPC). Check foundry.toml."
        exit 1
    }
    success "Sepolia RPC reachable."
}

# ═══════════════════════════ Confirmation ═══════════════════════════

confirm_deployment() {
    if [ "$SKIP_CONFIRM" = true ]; then return; fi
    if [ "$DRY_RUN" = true ]; then
        info "Dry run mode — no transactions will be broadcast."
        return
    fi

    echo ""
    warn "This will broadcast transactions on TESTNET chains:"
    echo "    Sepolia      (home chain)"
    echo "    Base Sepolia  (satellite)"
    echo ""
    echo "    Deployer: $DEPLOYER_ADDRESS"
    echo ""
    read -rp "  Type 'yes' to continue: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
}

# ═══════════════════════════ Forge Runner ═══════════════════════════

run_forge_script() {
    local contract="$1"
    local rpc="$2"
    shift 2

    local broadcast_flag="--broadcast"
    if [ "$DRY_RUN" = true ]; then
        broadcast_flag=""
    fi

    # shellcheck disable=SC2086
    FOUNDRY_PROFILE=production \
    forge script "script/MainDeploy.s.sol:${contract}" \
        --rpc-url "$rpc" \
        --skip test \
        $broadcast_flag \
        --slow \
        "$@"
}

# ═══════════════════════════ Step 1: Home Chain ═══════════════════════════

step1_deploy_home() {
    CURRENT_STEP="Deploy Home Chain (Sepolia)"
    CURRENT_STEP_NUM=1
    header "Step 1: Deploy Home Chain (Sepolia, domain $HOME_DOMAIN)"

    if [ -f "$STATE_FILE" ]; then
        warn "State file already exists: $STATE_FILE"
        warn "Home chain may already be deployed."
        if [ "$SKIP_CONFIRM" != true ]; then
            read -rp "  Overwrite and redeploy? (yes/no): " confirm
            if [ "$confirm" != "yes" ]; then
                info "Skipping step 1. Using existing state."
                return
            fi
        fi
    fi

    MAILBOX="$HOME_MAILBOX" \
    HUB_DOMAIN="$HOME_DOMAIN" \
    run_forge_script DeployHomeChain "$HOME_RPC"

    if [ ! -f "$STATE_FILE" ]; then
        error "State file not created: $STATE_FILE"
        exit 1
    fi

    echo ""
    success "Home chain deployed."
    info "  Hub:                $(json_get "$STATE_FILE" "homeChain.hub")"
    info "  PoaManager:         $(json_get "$STATE_FILE" "homeChain.poaManager")"
    info "  Executor:           $(json_get "$STATE_FILE" "homeChain.governance.executor")"
    info "  GovernanceFactory:  $(json_get "$STATE_FILE" "homeChain.governanceFactory")"
    info "  AccessFactory:      $(json_get "$STATE_FILE" "homeChain.accessFactory")"
    info "  ModulesFactory:     $(json_get "$STATE_FILE" "homeChain.modulesFactory")"
}

# ═══════════════════════════ Step 2: Satellite ═══════════════════════════

step2_deploy_satellite() {
    CURRENT_STEP="Deploy Satellite (Base Sepolia)"
    CURRENT_STEP_NUM=2

    if [ ! -f "$STATE_FILE" ]; then
        error "Home chain state not found: $STATE_FILE"
        error "Run step 1 first: ./script/bash/deploy-testnet.sh --step 1"
        exit 1
    fi

    local domain="${SAT_DOMAINS[0]}"
    local rpc="${SAT_RPCS[0]}"
    local mailbox="${SAT_MAILBOXES[0]}"
    local sat_state_file="$SCRIPT_DIR/../config/satellite-state-${domain}.json"

    if [ -f "$sat_state_file" ]; then
        warn "Base Sepolia satellite state already exists: $sat_state_file"
        if [ "$SKIP_CONFIRM" != true ]; then
            read -rp "  Redeploy? (yes/no): " confirm
            if [ "$confirm" != "yes" ]; then
                info "Skipping satellite deployment."
                return
            fi
        fi
    fi

    header "Step 2: Deploy Satellite on Base Sepolia (domain $domain)"

    MAILBOX="$mailbox" \
    SATELLITE_DOMAIN="$domain" \
    SOLIDARITY_FUND="5000000000000000" \
    run_forge_script DeploySatellite "$rpc"

    if [ ! -f "$sat_state_file" ]; then
        error "Satellite state file not created: $sat_state_file"
        exit 1
    fi

    echo ""
    success "Base Sepolia satellite deployed."
    info "  Satellite:          $(json_get "$sat_state_file" "satellite")"
    info "  PoaManager:         $(json_get "$sat_state_file" "poaManager")"
    info "  GovernanceFactory:  $(json_get "$sat_state_file" "governanceFactory")"
    info "  AccessFactory:      $(json_get "$sat_state_file" "accessFactory")"
    info "  ModulesFactory:     $(json_get "$sat_state_file" "modulesFactory")"
}

# ═══════════════════════════ Step 3: Register & Transfer ═══════════════════════════

step3_register_and_transfer() {
    CURRENT_STEP="Register Satellite & Transfer Ownership"
    CURRENT_STEP_NUM=3
    header "Step 3: Register Satellite & Transfer Hub Ownership"

    if [ ! -f "$STATE_FILE" ]; then
        error "Home chain state not found: $STATE_FILE"
        error "Run step 1 first."
        exit 1
    fi

    local domain="${SAT_DOMAINS[0]}"
    local sat_file="$SCRIPT_DIR/../config/satellite-state-${domain}.json"
    if [ ! -f "$sat_file" ]; then
        error "Missing satellite state: $sat_file"
        error "Run step 2 first: ./script/bash/deploy-testnet.sh --step 2"
        exit 1
    fi

    SATELLITE_DOMAIN_0="$domain" \
    NUM_SATELLITES=1 \
    run_forge_script RegisterAndTransfer "$HOME_RPC"

    echo ""
    success "Satellite registered and Hub ownership transferred to Executor."
}

# ═══════════════════════════ Step 4: Verify ═══════════════════════════

step4_verify() {
    CURRENT_STEP="Verify Deployment"
    CURRENT_STEP_NUM=4
    header "Step 4: Verify Deployment"

    if [ ! -f "$STATE_FILE" ]; then
        error "Home chain state not found: $STATE_FILE"
        exit 1
    fi

    FOUNDRY_PROFILE=production \
    forge script script/deploy/MainDeploy.s.sol:VerifyDeployment \
        --rpc-url "$HOME_RPC" \
        --skip test

    echo ""
    success "Verification complete."
}

# ═══════════════════════════ Summary ═══════════════════════════

print_summary() {
    header "Deployment Summary"

    if [ ! -f "$STATE_FILE" ]; then
        error "No state file found: $STATE_FILE"
        exit 1
    fi

    echo "Home Chain: Sepolia (domain $HOME_DOMAIN)"
    echo "  DeterministicDeployer: $(json_get "$STATE_FILE" "deterministicDeployer")"
    echo "  PoaManager:            $(json_get "$STATE_FILE" "homeChain.poaManager")"
    echo "  PoaManagerHub:         $(json_get "$STATE_FILE" "homeChain.hub")"
    echo "  ImplRegistry:          $(json_get "$STATE_FILE" "homeChain.implRegistry")"
    echo "  OrgRegistry:           $(json_get "$STATE_FILE" "homeChain.orgRegistry")"
    echo "  OrgDeployer:           $(json_get "$STATE_FILE" "homeChain.orgDeployer")"
    echo "  PaymasterHub:          $(json_get "$STATE_FILE" "homeChain.paymasterHub")"
    echo "  AccountRegistry:       $(json_get "$STATE_FILE" "homeChain.globalAccountRegistry")"
    echo "  PasskeyFactory:        $(json_get "$STATE_FILE" "homeChain.universalPasskeyFactory")"
    echo ""
    echo "  Factories:"
    echo "    GovernanceFactory:   $(json_get "$STATE_FILE" "homeChain.governanceFactory")"
    echo "    AccessFactory:       $(json_get "$STATE_FILE" "homeChain.accessFactory")"
    echo "    ModulesFactory:      $(json_get "$STATE_FILE" "homeChain.modulesFactory")"
    echo ""
    echo "  AuthorityRouter:       $(json_get "$STATE_FILE" "homeChain.authorityRouter")"
    echo ""
    echo "  Governance Org (Poa):"
    echo "    Executor:            $(json_get "$STATE_FILE" "homeChain.governance.executor")"
    echo "    HybridVoting:        $(json_get "$STATE_FILE" "homeChain.governance.hybridVoting")"
    echo "    DDVoting:            $(json_get "$STATE_FILE" "homeChain.governance.directDemocracyVoting")"
    echo "    QuickJoin:           $(json_get "$STATE_FILE" "homeChain.governance.quickJoin")"
    echo "    ParticipationToken:  $(json_get "$STATE_FILE" "homeChain.governance.participationToken")"
    echo "    TaskManager:         $(json_get "$STATE_FILE" "homeChain.governance.taskManager")"
    echo "    EducationHub:        $(json_get "$STATE_FILE" "homeChain.governance.educationHub")"
    echo "    PaymentManager:      $(json_get "$STATE_FILE" "homeChain.governance.paymentManager")"
    echo ""

    local domain="${SAT_DOMAINS[0]}"
    local sat_file="$SCRIPT_DIR/../config/satellite-state-${domain}.json"
    if [ -f "$sat_file" ]; then
        echo "Satellite: Base Sepolia (domain $domain)"
        echo "  PoaManagerSatellite:   $(json_get "$sat_file" "satellite")"
        echo "  PoaManager:            $(json_get "$sat_file" "poaManager")"
        echo "  ImplRegistry:          $(json_get "$sat_file" "implRegistry")"
        echo "  OrgRegistry:           $(json_get "$sat_file" "orgRegistry")"
        echo "  OrgDeployer:           $(json_get "$sat_file" "orgDeployer")"
        echo "  PaymasterHub:          $(json_get "$sat_file" "paymasterHub")"
        echo "  AccountRegistry:       $(json_get "$sat_file" "globalAccountRegistry")"
        echo "  PasskeyFactory:        $(json_get "$sat_file" "universalPasskeyFactory")"
        echo ""
        echo "  Factories:"
        echo "    GovernanceFactory:   $(json_get "$sat_file" "governanceFactory")"
        echo "    AccessFactory:       $(json_get "$sat_file" "accessFactory")"
        echo "    ModulesFactory:      $(json_get "$sat_file" "modulesFactory")"
        echo ""
        echo "  AuthorityRouter:       $(json_get "$sat_file" "authorityRouter")"
        echo ""
    else
        warn "Satellite: state file not found ($sat_file)"
    fi

    echo "State files:"
    info "  $STATE_FILE"
    if [ -f "$sat_file" ]; then
        info "  $sat_file"
    fi
}

# ═══════════════════════════ Main ═══════════════════════════

main() {
    header "POA Protocol Testnet Deployment"
    echo "  Home:      Sepolia (domain $HOME_DOMAIN)"
    echo "  Satellite: Base Sepolia (domain ${SAT_DOMAINS[0]})"

    if [ "$STEP" = "summary" ]; then
        print_summary
        echo ""
        success "Done."
        return
    fi

    load_env

    if [ "$STEP" = "4" ]; then
        preflight_checks_minimal
        step4_verify
        echo ""
        success "Done."
        return
    fi

    preflight_checks

    if [ -z "$STEP" ]; then
        confirm_deployment
        step1_deploy_home
        step2_deploy_satellite
        step3_register_and_transfer
        step4_verify
        print_summary
    else
        case "$STEP" in
            1) confirm_deployment; step1_deploy_home ;;
            2) confirm_deployment; step2_deploy_satellite ;;
            3) confirm_deployment; step3_register_and_transfer ;;
            *) error "Unknown step: $STEP (valid: 1, 2, 3, 4, summary)"; exit 1 ;;
        esac
    fi

    echo ""
    success "Done."
}

main
