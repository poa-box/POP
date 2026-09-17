# Wave G: authority-only protocol release

**Production deployment completed on both chains; independently verified 2026-09-17.**
Gnosis completed at block 48,285,487 and Arbitrum at block 505,999,798. The production
subgraphs and frontend are live. No further Wave G upgrade broadcasts are required.
The separate authority-only CLI/package release remained pending at verification.

Wave G removed V1 authorization after Kansas Blockchain/KUBI, Decentral Park, Poa and
Test6 completed Access-v2 cutover. Hudson's 2026-09-06 decision retired Test,
Test2, Test3, tkrjehbcuebc, Test5 and Argus. Do not pin or migrate those six orgs.
Survivors retain their V1-era history; retirement does not delete indexed records.

**Do not rerun `UpgradeWaveG.s.sol` against current production state.** Its one-off
`Sim*` and `Broadcast*` entry points require unoccupied versions and deployment slots;
those slots are now occupied on both chains. Verify the installed deployment with
read-only checks or a fork of the installed contracts, without repeating the ceremony.
Any future upgrade needs its own reviewed versions, inventory and rehearsals.

The durable public record is [WAVE-G-VERIFICATION.json](WAVE-G-VERIFICATION.json), including
all 50 transaction hashes, block ranges, deployed addresses, runtime hashes and verification
results. The full local evidence is in `.context/wave-g/live-status-2026-09-17/`.

## What changes

- DD/HV/TM/PT/EDU/QuickJoin/Executor authorize through MembershipAuthority only.
  Authority-zero rollback, legacy config-admin powers, Hats permission setters and
  caller-specified QuickJoin hat claims are removed. Old numeric config keys remain
  reserved and reject writes instead of changing meaning.
- Historical storage fields, proposal structs, subject IDs and read getters remain.
  HV proposal snapshots still resolve adopted subject IDs; proposals with a zero
  historical creation anchor continue to require active membership.
- OrgDeployer and all three factories move to the shorter current module initializers.
  The external native `DeploymentParams` tuple stays unchanged. Runtime project creation
  requires empty retired permission arrays; governance configures `TM_PERMS` on the
  authority with project context `projectId + 1` (zero is the global context).
- All 56 retained global paymaster rule structs are unchanged: 10 MembershipAuthority
  rules are allowed and 46 other slots remain unset/disabled. This release did not enable
  all defaults. Eleven retired QuickJoin/EM selectors are explicitly disabled with zero
  gas hints. AuthorityRouter and PaymasterHub implementations stay as-is.
- The subgraph retains V1 templates, ABIs, deployment start blocks and event entities.
  Late legacy EM events must not overwrite current authority-derived members or roles.
  The frontend and authority-only CLI require indexed authority + router binding + cutover readiness,
  and retain survivors' full task/proposal/member histories without a cutover-time filter.

## Implementations

The following versions are registered, latest and current on both Gnosis and Arbitrum.
Registry and deterministic deployment slots were probed independently before release;
the completed ceremony now occupies them.

| Type | Version |
| --- | --- |
| DirectDemocracyVoting | v14 |
| HybridVoting | v14 |
| TaskManager | v9 |
| ParticipationToken | v9 |
| EducationHub | v5 |
| QuickJoin | v10 |
| Executor | v6 |
| OrgDeployer | v21 |

GovernanceFactory, AccessFactory and ModulesFactory were freshly deployed and all three
pointers updated. Reusing pre-Wave-G factory bytecode would call removed initializers.

## Production verification (2026-09-17)

| Chain | Successful upgrade receipts | First–last upgrade block | Runtime / fork-smoke verification block |
| --- | --- | --- | --- |
| Gnosis (100) | 25 / 25 | 48,285,463–48,285,487 | 48,299,831 |
| Arbitrum (42161) | 25 / 25 | 505,999,602–505,999,798 | 506,162,819 |

- All 50 mined receipts succeeded, with sender, calldata, nonce, target and receipt block
  checked against the recorded broadcasts. Gnosis completed on September 16 UTC and
  Arbitrum on September 17 UTC. Verification itself sent no live transactions.
- On each chain, all eight implementations, three factories and three linked libraries
  matched the reviewed production build byte-for-byte after library linking and immutable
  substitution: Solidity 0.8.33, optimizer 200 runs, via IR, Cancun EVM. All 86 artifact
  source hashes matched the checkout; the deployment script hash is preserved in the record.
- All 72 existing proxy beacon bindings resolve to the expected implementations. The 294
  state assertions passed, including ownership, factory pointers and authority/router
  bindings. The four survivors remain authority-bound; retired orgs have zero authority
  and their checked member-operation gates revert.
- All 56 retained rule structs per chain are byte-identical to the block immediately
  before that chain's first upgrade receipt (10 allowed, 46 unset/disabled). All eleven
  retired selectors are disabled with zero gas hints.
- Production-profile fork smoke checks used the already-deployed implementations and
  factories, successfully deployed a native org and performed an authorized EducationHub
  write on each chain. These checks did not rerun the upgrade ceremony or read a signer key.
- Both production subgraph gateways served the reviewed deployments, indexed beyond the
  final upgrade receipts and reported no indexing errors. Original source addresses,
  start blocks and historical templates are intact. No compared user, proposal, task or
  project IDs were missing across all ten orgs relative to the September 6 and 16 snapshots;
  vote IDs were also retained relative to the previous deployment. This includes survivors'
  pre-cutover records.
- Public browser checks of `poa.box` confirmed Kansas Blockchain, Decentral Park, Poa and
  Test6 histories load, while all six retired direct routes are hidden. The public directory
  lists Poa, Kansas Blockchain and Decentral Park. Arbitrum's Studio `latest` alias was stale
  at verification; the production frontend uses the correct decentralized gateway.

No history pruning or reindexing from a later block was part of this release. Verification
of live application behavior was read-only; authenticated writes and new-org deployment
were exercised on local forks rather than sent to production.

## Release sequence and remaining work

Subgraph history validation/publication, the authority-only frontend, production-profile
fork rehearsals, default-profile tests and both per-chain upgrade broadcasts are complete.
Each chain used its local Hub/Satellite; no Hyperlane relay was required. The multi-transaction
maintenance window is over and factory pointers match the new beacons.

The remaining separate release is the authority-only CLI/packages: npm `@poa-box/core`,
`@poa-box/cli` and `@poa-box/agent` still reported `0.1.0` at the September 17 check. Before
publishing that release, check read-only discovery excludes retired orgs and native deployment
dry runs produce the current tuple without signing, uploading metadata or sending a transaction.
This is not a further smart-contract upgrade and does not block merging the deployed contracts.

## Completed rehearsal (2026-09-06)

The final script passed under `FOUNDRY_PROFILE=production` on Gnosis block
48,105,609 and Arbitrum block 502,240,658. Gnosis checked all nine organizations,
including full migrated task/applicant and proposal/tally histories and the six
retired organizations' zero-authority gates. Arbitrum checked Poa. Both checked
all 56 retained rule structs, eleven disabled tombstones, eight registered/current
implementations and three fresh factories, then successfully deployed a native org
and exercised an authority-gated EducationHub write.

The default-profile suite passed 2,048 tests. All 29 existing structs across the
eight upgraded contracts are unchanged. Every production implementation/factory
passes EIP-170; OrgDeployer is the largest at 23,862 bytes (714 bytes remaining).
No live transaction was broadcast during these rehearsals. These historical rehearsal
results preceded the production broadcasts recorded above; the one-off ceremony is not
a post-deployment health check.
