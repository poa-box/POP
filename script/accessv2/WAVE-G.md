# Wave G: authority-only protocol release

Wave G removes V1 authorization after Kansas Blockchain/KUBI, Decentral Park, Poa and
Test6 have completed Access-v2 cutover. Hudson's 2026-09-06 decision retires Test,
Test2, Test3, tkrjehbcuebc, Test5 and Argus. Do not pin or migrate those six orgs.
The original sequencing and scope are captured in `.context/rolemanager/WAVE-G-BRIEF.md`.

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
- The 56 current global paymaster defaults remain. Eleven retired QuickJoin/EM selectors
  are explicitly disabled. AuthorityRouter and PaymasterHub implementations stay as-is.
- The subgraph retains V1 templates, ABIs, deployment start blocks and event entities.
  Late legacy EM events must not overwrite current authority-derived members or roles.
  The frontend and CLI require indexed authority + router binding + cutover readiness,
  and retain survivors' full task/proposal/member histories without a cutover-time filter.

## Implementations

Registry and deterministic deployment slots were probed independently on both Gnosis
and Arbitrum. The ceremony rechecks both before any mutation, refusing occupied versions.

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

GovernanceFactory, AccessFactory and ModulesFactory are freshly deployed and their
pointers updated. Reusing pre-Wave-G factory bytecode would call removed initializers.

## Release sequence

1. Complete subgraph history-continuity validation and publish its mappings with all
   existing historical sources intact. Check both chains finish indexing without errors.
2. Release the authority-only frontend. It supports the already-migrated authority paths
   and hides retired orgs before their module beacons change. Confirm Kansas Blockchain,
   Decentral Park, Poa and Test6 direct links and old task/proposal history still load.
3. Execute both production-profile fork rehearsals from this checkout:

   ```sh
   FOUNDRY_PROFILE=production forge script script/accessv2/UpgradeWaveG.s.sol:SimGnosis --fork-url gnosis-gateway -vvv
   FOUNDRY_PROFILE=production forge script script/accessv2/UpgradeWaveG.s.sol:SimArbitrum --fork-url arbitrum -vvv
   ```

   The one-off release scripts check the four known migrated authorities explicitly and fail
   closed if the fleet changes; refresh the reviewed inventory before releasing in that case.
   Require PASS for both, matching module read snapshots and authority/router bindings
   for every migrated org, current implementation pointers, fresh factory pointers and
   explicit disabled retired rules. Also require `forge test` under the default profile.
4. Broadcast the matching per-chain ceremony using the Hudson admin signer only after
   the rehearsal and release review. Each chain uses its local Hub/Satellite; no Hyperlane
   relay is required. This is a multi-transaction maintenance window: new org creation
   can fail while factory pointers and module beacons are temporarily on different versions.
   Resume normal deployment after all final checks pass. A partial run requires inspecting
   receipts/current versions before recovery; do not choose new versions blindly.
5. Publish the authority-only CLI after verification. Check read-only discovery excludes
   retired orgs and native deployment dry runs produce the current tuple without signing,
   uploading metadata or sending a transaction.

The printed gas estimate of a `Sim*` entry point covers Forge's auto-linked library
transactions, not the entire pranked ceremony. Use a `Broadcast*` entry point without
`--broadcast` for a reviewed release transaction/gas preview; simulation does not send
transactions.

No history pruning or reindexing from a later block is part of this release. Removing
legacy functionality does not mean deleting the surviving orgs' V1-era records.

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
No live transaction was broadcast during these rehearsals.
