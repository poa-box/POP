# Sigstack bot integration

[sigstack-bot](https://github.com/BreadchainCoop/sigstack-bot) is a Signal bot
that runs inside an Intel TDX TEE and proxies chat to private inference. This doc
covers the Poa-side setup for the **Poa DAO task tools** added in
[sigstack-bot#4](https://github.com/BreadchainCoop/sigstack-bot/pull/4): letting
the bot read an org's projects/tasks and (for authorized operators) create and
manage tasks on the org's `TaskManager`.

The bot is, from this repo's perspective, just another **agent EOA** that holds a
TaskManager permission — the same shape as the "Agent role" already used on
Decentral Park (`script/fixes/CreateAgentRoleDecentralPark.s.sol`). Nothing new
is needed on-chain; you grant the bot's wallet a permission through normal
governance.

## 1. Get the bot's wallet address

The bot signs with a key **derived inside its TEE** (dstack `derive_key`) — no
private key is exported. To read the address:

- start the bot with `TOOLS__POA__ENABLED=true` and look for the log line
  `Poa wallet address: 0x… (grant this address project-manager rights on-chain)`, or
- ask the running bot (it exposes a `poa_wallet_info` tool).

Call this address `BOT` below. It is stable for a given TEE image + derivation
path (`poa-tools/task-manager-wallet`).

## 2. Point the bot at the org

The bot needs the org's chain RPC, the Poa subgraph, and the org's `TaskManager`
proxy. Find the TaskManager from the subgraph (see `CLAUDE.md` → *Subgraph*):

```bash
curl -s -X POST 'https://api.studio.thegraph.com/query/73367/poa-gnosis-v-1/version/latest' \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ organization(id:\"0x<orgId>\"){ name taskManager{ id } } }"}'
```

Set on the bot: `TOOLS__POA__RPC_URL`, `TOOLS__POA__SUBGRAPH_URL`,
`TOOLS__POA__TASK_MANAGER`, `TOOLS__POA__NETWORK_NAME`. (Poa governance orgs are
on **Arbitrum**; KUBI/Test6/etc. on **Gnosis**.)

## 3. Grant the bot a TaskManager permission

Read tools need **no** on-chain grant. Write tools require the bot wallet to hold
a permission on the target project. Two options:

### Option A — Project manager (simplest, per project)

One governance call makes `BOT` a manager of project `pid`, bypassing the hat
system for that project (create/assign/review/edit/cancel):

```solidity
TaskManager.setConfig(
    TaskManager.ConfigKey.PROJECT_MANAGER,
    abi.encode(pid, BOT, true)   // (bytes32 pid, address mgr, bool isManager)
);
```

This is executor-gated, so it runs as a proposal executed by the org's Executor
(same batch shape as the `script/fixes/*ViaGovernance.s.sol` scripts). Revoke by
passing `false`.

### Option B — Agent role hat (recommended, least privilege)

Mirror `CreateAgentRoleDecentralPark.s.sol`: create an "Agent"/"Bot" role hat,
grant it a **scoped** TaskPerm mask org-wide, mint the hat to `BOT`, and sponsor
its gas via PaymasterHub. Example mask — the bot can create and assign tasks and
edit task metadata, but not touch payouts, reviews, or budgets:

```solidity
uint8 mask = TaskPerm.CREATE | TaskPerm.ASSIGN | TaskPerm.EDIT_META;
TaskManager.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(botHat, mask));
```

Use `setProjectRolePerm(pid, botHat, mask)` (or `setConfig(PROJECT_ROLE_PERM…)`)
to scope the grant to a single project instead of the whole org.

**TaskPerm bits** (`src/libs/TaskPerm.sol`):

| Bit | Name | Gates |
|-----|------|-------|
| `1<<0` | `CREATE` | createTask, cancelTask, edit while unclaimed |
| `1<<1` | `CLAIM` | claimTask |
| `1<<2` | `REVIEW` | completeTask (mints payout), rejectTask |
| `1<<3` | `ASSIGN` | assignTask, approveApplication |
| `1<<4` | `SELF_REVIEW` | approve one's own submission |
| `1<<5` | `BUDGET` | project/bounty cap edits |
| `1<<6` | `EDIT_META` | edit title/metadata post-claim |
| `1<<7` | `EDIT_FULL` | edit payout/bounty post-claim |

Grant only what the bot should do. In particular `REVIEW` mints tokens and
`EDIT_FULL`/`BUDGET` move value — reserve those for humans unless the bot is
explicitly meant to approve work.

## 4. Fund gas

The bot pays its own gas from `BOT`. Either send it a little native token on the
org's chain, or sponsor it via `PaymasterHub.setBudget(orgId, botSubjectKey, …)`
as in step 5 of the Decentral Park agent script.

## 5. Turn on writes (bot side)

On the bot, writes are gated independently of the chain:

- `TOOLS__POA__ENABLE_WRITES=true`
- `TOOLS__POA__AUTHORIZED_SENDERS=<comma/space-separated Signal numbers>`

Only those senders can invoke write tools, even in group chats. See
[`docs/poa-integration.md`](https://github.com/BreadchainCoop/sigstack-bot/blob/main/docs/poa-integration.md)
in the bot repo.

## Security notes

- **Key custody:** the signing key never leaves the TEE. Whoever controls the TEE
  image/deployment effectively controls `BOT` — treat granting it `REVIEW`/
  `EDIT_FULL`/`BUDGET` as delegating value movement to that operator.
- **Two independent gates:** the bot's sender allowlist limits *who can ask*; the
  on-chain permission limits *what the wallet can do*. Keep both tight; revoke
  the on-chain grant (Option A `false`, or burn the Agent hat) to cut the bot off
  regardless of bot config.
- **Least privilege:** prefer Option B with a project-scoped mask over org-wide
  project-manager rights.
- **Auditability:** every write emits the usual `Task*` events, so the subgraph
  and any monitoring pick up bot actions with `_msgSender() == BOT`.
