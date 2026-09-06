# POA Protocol Deployment Scripts

This directory contains deployment scripts for the POA (Perpetual Organization Architect) Protocol infrastructure and individual organizations.

## 🏗️ Architecture Overview

The deployment system consists of two main scripts:

1. **DeployInfrastructure.s.sol** - Deploys protocol infrastructure (once per chain)
2. **DeployOrg.s.sol** - Deploys individual organizations from JSON configs (many times)

## 📋 Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Private key for deployment with sufficient gas funds
- That's it! (RPC endpoints are pre-configured in `foundry.toml`)

## 🚀 Quick Start

### Step 0: Configure Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit .env and add your private key
# DEPLOYER_PRIVATE_KEY=0x...
# ETHERSCAN_API_KEY=... (optional, for contract verification)
```

### Step 1: Deploy Infrastructure

Deploy all protocol infrastructure contracts to the target chain. This is done **once per chain**.

```bash
# Deploy infrastructure (uses DEPLOYER_PRIVATE_KEY from .env)
forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url sepolia \
  --broadcast

# With verification (requires ETHERSCAN_API_KEY in .env):
source .env  # Load ETHERSCAN_API_KEY into your shell
forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

**Available networks:** `sepolia`, `holesky`, `optimism-sepolia`, `base-sepolia`, `arbitrum-sepolia`, `polygon-amoy`, `mainnet`, `optimism`, `base`, `arbitrum`, `polygon`, `local`

**What gets deployed:**
- Implementation contracts for all modules
- PoaManager (upgradeable beacon manager)
- ImplementationRegistry (tracks versions)
- OrgRegistry (tracks all orgs)
- OrgDeployer (orchestrates org creation)
- Factory contracts (GovernanceFactory, AccessFactory, ModulesFactory)
- Global UniversalAccountRegistry
- PaymasterHub (gas sponsorship) + the seeded global rulebook
- AuthorityRouter singleton, with PaymasterHub and OrgRegistry repointed at it (Access v2 read path)

**Output:**
The script automatically saves deployment addresses to `script/config/infrastructure.json`. This file is committed to the repo and automatically loaded by org deployments - no manual copying needed!

### Step 2: Configure Your Organization

Create a JSON configuration file for your organization. See example configs:

- **`org-config-example.json`** - Hybrid voting (token + direct democracy)
- **`org-config-direct-democracy.json`** - Pure direct democracy

#### Configuration Structure

```json
{
  "orgId": "unique-org-identifier",
  "orgName": "Organization Display Name",
  "autoUpgrade": true,
  "threshold": {
    "hybrid": 50,
    "directDemocracy": 50
  },
  "roles": [
    {
      "name": "MEMBER",
      "image": "ipfs://QmHash",
      "canVote": true
    }
  ],
  "votingClasses": [
    {
      "strategy": "DIRECT",
      "slicePct": 50,
      "quadratic": false,
      "minBalance": 0,
      "asset": "0x0000000000000000000000000000000000000000",
      "hatIds": []
    },
    {
      "strategy": "ERC20_BAL",
      "slicePct": 50,
      "quadratic": false,
      "minBalance": "4000000000000000000",
      "asset": "0x0000000000000000000000000000000000000000",
      "hatIds": []
    }
  ],
  "roleAssignments": {
    "quickJoinRoles": [0],
    "tokenMemberRoles": [0],
    "tokenApproverRoles": [1],
    "taskCreatorRoles": [1],
    "educationCreatorRoles": [1],
    "educationMemberRoles": [0],
    "hybridProposalCreatorRoles": [1],
    "ddVotingRoles": [0],
    "ddCreatorRoles": [1]
  },
  "ddInitialTargets": [],
  "withPaymaster": false
}
```

#### Configuration Guide

**Roles:**
- Define organizational roles (hats) that members can hold
- Each role has a name, image (IPFS hash), and voting capability
- Role indices (0, 1, 2...) are used in role assignments

**Voting Classes:**
- `DIRECT` - One person, one vote (direct democracy)
- `ERC20_BAL` - Token-weighted voting (participation token)
- `HAT_WEIGHTED` - Hat-based weighted voting
- `slicePct` - Percentage of voting power (must sum to 100)
- `quadratic` - Enable quadratic voting for this class
- `minBalance` - Minimum token balance required to vote (in wei)

**Role Assignments:**
- `quickJoinRoles` - Roles auto-assigned when joining via QuickJoin
- `tokenMemberRoles` - Roles that can hold participation tokens
- `tokenApproverRoles` - Roles that can approve token transfers
- `taskCreatorRoles` - Roles that can create tasks
- `educationCreatorRoles` - Roles that can create education content
- `educationMemberRoles` - Roles that can access education
- `hybridProposalCreatorRoles` - Roles that can create governance proposals
- `ddVotingRoles` - Roles that can vote in direct democracy polls
- `ddCreatorRoles` - Roles that can create direct democracy polls

### Step 3: Deploy Your Organization

**IMPORTANT**: Organization deployment requires ~22M gas, which exceeds Ethereum Sepolia's block gas limit (~16.7M). **You must deploy on an L2 network** (Base Sepolia, Optimism Sepolia, or Arbitrum Sepolia):

```bash
# Deploy org on Base Sepolia (recommended - higher gas limits)
FOUNDRY_PROFILE=production forge script script/org/DeployOrg.s.sol:DeployOrg \
  --rpc-url base-sepolia \
  --broadcast

# With verification on Base Sepolia:
source .env  # Load ETHERSCAN_API_KEY into your shell
FOUNDRY_PROFILE=production forge script script/org/DeployOrg.s.sol:DeployOrg \
  --rpc-url base-sepolia \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api-sepolia.basescan.org/api

# Or use Optimism Sepolia:
FOUNDRY_PROFILE=production forge script script/org/DeployOrg.s.sol:DeployOrg \
  --rpc-url optimism-sepolia \
  --broadcast

# Or with a custom config:
ORG_CONFIG_PATH=script/my-org-config.json \
FOUNDRY_PROFILE=production forge script script/org/DeployOrg.s.sol:DeployOrg \
  --rpc-url base-sepolia \
  --broadcast
```

**Why L2?** The full organization deployment deploys 8+ contracts in one transaction, requiring ~22.5M gas. L2 networks have much higher gas limits and lower costs.

**Zero setup needed!** The script automatically:
- ✅ Reads your private key from `.env`
- ✅ Loads infrastructure addresses from `script/infrastructure.json`
- ✅ Uses the example config or your custom one

**What gets deployed:**
- Executor (org's execution contract)
- HybridVoting (governance contract)
- DirectDemocracyVoting (polling contract)
- QuickJoin (membership onboarding)
- ParticipationToken (org-specific token)
- TaskManager (task coordination)
- EducationHub (learning system)
- PaymentManager (payment processing)
- Hats tree (role hierarchy)

**Output:**
The script outputs all deployed contract addresses for your organization.

## 🔧 Example Deployment Flow

### Deploy Infrastructure (Base Sepolia Testnet)

```bash
# 1. Set up your .env file (one-time setup)
cp .env.example .env
# Edit .env with your private key and optionally Etherscan API key

# 2. Deploy infrastructure on Base Sepolia (recommended for org deployments)
forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url base-sepolia \
  --broadcast

# 3. Addresses automatically saved to script/infrastructure.json
```

### Deploy Organization

```bash
# Everything is auto-loaded from .env and infrastructure.json - just deploy!
# NOTE: Must use same network as infrastructure deployment
FOUNDRY_PROFILE=production forge script script/org/DeployOrg.s.sol:DeployOrg \
  --rpc-url base-sepolia \
  --broadcast
```

## 📝 Advanced Usage

### Custom Voting Configurations

**Pure Direct Democracy:**
```json
"votingClasses": [
  {
    "strategy": "DIRECT",
    "slicePct": 100,
    "quadratic": false,
    "minBalance": 0,
    "asset": "0x0000000000000000000000000000000000000000",
    "hatIds": []
  }
]
```

**Pure Token Voting:**
```json
"votingClasses": [
  {
    "strategy": "ERC20_BAL",
    "slicePct": 100,
    "quadratic": false,
    "minBalance": "1000000000000000000",
    "asset": "0x0000000000000000000000000000000000000000",
    "hatIds": []
  }
]
```

**Hybrid (50/50):**
```json
"votingClasses": [
  {
    "strategy": "DIRECT",
    "slicePct": 50,
    ...
  },
  {
    "strategy": "ERC20_BAL",
    "slicePct": 50,
    ...
  }
]
```

### Quadratic Voting

Enable quadratic voting for more equitable power distribution:

```json
{
  "strategy": "ERC20_BAL",
  "slicePct": 100,
  "quadratic": true,
  "minBalance": "1000000000000000000",
  ...
}
```

### Multiple Organizational Roles

Create complex role structures:

```json
"roles": [
  {"name": "FOUNDING_MEMBER", "image": "ipfs://...", "canVote": true},
  {"name": "FULL_MEMBER", "image": "ipfs://...", "canVote": true},
  {"name": "CONTRIBUTOR", "image": "ipfs://...", "canVote": false},
  {"name": "ADVISOR", "image": "ipfs://...", "canVote": false}
]
```

## 🧪 Local Testing

To test deployments locally using Anvil:

```bash
# 1. Start local fork
anvil --fork-url https://sepolia.drpc.org

# 2. Deploy (use anvil's default private key)
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url local \
  --broadcast
```

## 📚 Supported Networks

The protocol is deployed on **Sepolia testnet** with Hats Protocol at `0x3bc1A0Ad72417f2d411118085256fC53CBdDd137`.

You can use any of these public dRPC endpoints:
- **Sepolia**: `https://sepolia.drpc.org`
- **Holesky**: `https://holesky.drpc.org`
- **Optimism Sepolia**: `https://optimism-sepolia.drpc.org`
- **Base Sepolia**: `https://base-sepolia.drpc.org`
- **Arbitrum Sepolia**: `https://arbitrum-sepolia.drpc.org`
- **Polygon Amoy**: `https://polygon-amoy.drpc.org`

## ✅ Contract Verification

To verify your contracts on Etherscan (or other block explorers), you need an API key:

### Step 1: Get an API Key

1. Go to the block explorer for your network:
   - **Sepolia/Ethereum**: https://etherscan.io/myapikey
   - **Optimism**: https://optimistic.etherscan.io/myapikey
   - **Base**: https://basescan.org/myapikey
   - **Arbitrum**: https://arbiscan.io/myapikey
   - **Polygon**: https://polygonscan.com/myapikey

2. Create an account and generate a new API key

### Step 2: Set Your API Key

```bash
export ETHERSCAN_API_KEY=YOUR_API_KEY_HERE
```

### Step 3: Deploy with Verification

```bash
source .env  # Load ETHERSCAN_API_KEY into your shell
forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

**For non-Ethereum chains**, you need to specify the verifier URL:

```bash
# Base Sepolia example
source .env  # Load ETHERSCAN_API_KEY into your shell
forge script script/deploy/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url base-sepolia \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api-sepolia.basescan.org/api
```

### Common Verifier URLs:

- **Sepolia**: (default, no need to specify)
- **Optimism Sepolia**: `https://api-sepolia-optimistic.etherscan.io/api`
- **Base Sepolia**: `https://api-sepolia.basescan.org/api`
- **Arbitrum Sepolia**: `https://api-sepolia.arbiscan.io/api`
- **Optimism**: `https://api-optimistic.etherscan.io/api`
- **Base**: `https://api.basescan.org/api`
- **Arbitrum**: `https://api.arbiscan.io/api`
- **Polygon**: `https://api.polygonscan.com/api`

### Alternative: Verify After Deployment

If verification fails during deployment, you can verify later:

```bash
source .env  # Load ETHERSCAN_API_KEY into your shell
forge verify-contract <CONTRACT_ADDRESS> \
  src/OrgDeployer.sol:OrgDeployer \
  --chain-id 11155111 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address)" ...)
```

## 🔐 Security Considerations

1. **Private Key Management**: Never commit private keys. Use environment variables or hardware wallets.
2. **Verification**: Always verify contracts on block explorers after deployment.
3. **Testing**: Test on testnet before mainnet deployment.
4. **Upgradability**: Infrastructure contracts use beacon proxy pattern for upgrades.
5. **Ownership**: OrgRegistry ownership is transferred to OrgDeployer during setup.

## 🐛 Troubleshooting

**Error: "OrgDeployer already exists"**
- Each org needs a unique `orgId`
- Change the `orgId` in your config file

**Gas estimation failed / Gas limit too high**
- Use `FOUNDRY_PROFILE=production` to enable optimizer (37% smaller contracts)
- Add `--gas-limit 30000000` to your forge script command
- Check that all addresses are correct
- Consider deploying on L2s (Optimism, Base, Arbitrum) for lower gas costs

**Voting class percentages don't sum to 100**
- Ensure `slicePct` values sum exactly to 100
- Example: Two classes should be 50/50, or 60/40, etc.

**Verification fails during deployment**
- Make sure `ETHERSCAN_API_KEY` is set correctly
- For non-Ethereum chains, add `--verifier-url` (see verification section)
- Check that the API key is valid for the network you're deploying to
- If it continues to fail, deploy without `--verify` and verify contracts manually afterward

**"Chain 11155111 not supported by etherscan" error**
- Sepolia uses the default Etherscan verifier, no special URL needed
- For other networks, use the appropriate `--verifier-url` (see verification section)

## 📖 Additional Resources

- [Hats Protocol Documentation](https://docs.hatsprotocol.xyz)
- [Foundry Book](https://book.getfoundry.sh/)
- [OpenZeppelin Upgradeable Contracts](https://docs.openzeppelin.com/contracts/4.x/upgradeable)
