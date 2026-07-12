# POP zk-email — phase-2 trusted-setup ceremony

Closes **Blocker 1** (`docs/ZKEMAIL_PRODUCTION_READINESS.md`): the deployed Groth16 verifiers hold a
single-contributor DEV key (confirmed live — the toxic waste can forge proofs). This runbook produces
a **multi-party** key so no single party can forge, and is safe to run once for mainnet.

Groth16 needs a per-circuit **phase 2** on top of a universal **phase 1** (Powers of Tau). Phase 1 is
the public perpetual Hermez ceremony — we only download + verify it. Phase 2 is what *we* run, once
per circuit (`PopRoleClaim` = domain, `PopRoleClaimV2` = email), with N independent contributors.

**Security property:** the setup is sound as long as **at least one** contributor is honest and
destroys their entropy. More independent contributors = stronger. 3–5 unaffiliated people is typical.

> ⚠️ Run this **after** the Blocker 2 circuit change lands. A circuit edit changes the `.r1cs`, which
> invalidates any earlier phase-2 contribution — running the ceremony first wastes it.

## The tooling (rehearsed, works end-to-end)

| Script | Who runs it | What it does |
|--------|-------------|--------------|
| `phase2-begin.sh` | coordinator, once/circuit | `groth16 setup` → initial `_0000.zkey` + starts the transcript |
| `phase2-contribute.sh` | each contributor, own machine | one `zkey contribute` of private entropy; prints + logs the contribution hash |
| `phase2-finalize.sh` | coordinator, once/circuit | public beacon → `zkey verify` (OK) → export vkey + solidity verifier |
| `rehearse.sh` | anyone | runs the **entire** flow on a tiny circuit with a locally-generated ptau (no download) — prove the mechanics before the real run |
| `verify-ceremony.sh` | anyone (contributor / outsider) | **independent audit** — re-derives everything and confirms the final key is an untampered product of the recorded ceremony (+ optionally that the on-chain verifier and beacon match). Exit 0 = trustworthy, 1 = do not deploy |

Verify the mechanics any time: `./rehearse.sh` → must print `REHEARSAL PASSED`.

## Prerequisites for the real run

1. **Finalized circuits** (post Blocker 2) compiled to `.r1cs`:
   ```sh
   cd ~/pop-zk-work
   CIRCOM=circom-src/target/release/circom   # circom 2.2.3
   $CIRCOM circuits/PopRoleClaim.circom   --r1cs -l circuits/node_modules -o build/
   $CIRCOM circuits/PopRoleClaimV2.circom --r1cs -l circuits/node_modules -o build/
   ```
2. **Powers of Tau**, downloaded and **hash-verified** against the published snarkjs/Hermez table
   (https://github.com/iden3/snarkjs#7-prepare-phase-2 and the perpetual-powers-of-tau attestations):
   - v1 domain (~90k constraints): `powersOfTau28_hez_final_20.ptau` (2^20)
   - v2 email (~1.2M constraints): `powersOfTau28_hez_final_21.ptau` (2^21) — v2 exceeds 2^20
   ```sh
   curl -LO https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_21.ptau
   shasum -a 256 powersOfTau28_hez_final_21.ptau   # compare to the published value; record in the transcript
   ```
   Record the ptau sha256 in the transcript (the scripts do this automatically).

## Running it (per circuit — do v1 and v2 separately)

Coordinator, e.g. for v2:
```sh
CER=circuits/ceremony
$CER/phase2-begin.sh PopRoleClaimV2 build/PopRoleClaimV2.r1cs \
    ptau/powersOfTau28_hez_final_21.ptau ceremony-out/v2
# → ceremony-out/v2/PopRoleClaimV2_0000.zkey + PopRoleClaimV2.transcript.txt
```

Each contributor, on their **own** machine, in sequence (pass the zkey along):
```sh
# leave CEREMONY_ENTROPY UNSET so snarkjs prompts — nothing hits shell history / process listing
circuits/ceremony/phase2-contribute.sh PopRoleClaimV2 \
    PopRoleClaimV2_0000.zkey PopRoleClaimV2_0001.zkey "alice@org" \
    PopRoleClaimV2.transcript.txt
# publish the printed "alice@org -> <hash>" so anyone can confirm it's in the final transcript
```
Contributor #2 builds on `_0001.zkey` → `_0002.zkey`, etc. Contributors should verify the file they
received before contributing: `snarkjs zkey verify build/PopRoleClaimV2.r1cs <ptau> <received.zkey>`.

Coordinator finalizes with a **public** beacon (choose a future randomness source — e.g. a specified
future Ethereum block hash — and publish which one *before* the ceremony ends):
```sh
$CER/phase2-finalize.sh PopRoleClaimV2 \
    ceremony-out/v2/PopRoleClaimV2_0003.zkey build/PopRoleClaimV2.r1cs \
    ptau/powersOfTau28_hez_final_21.ptau ceremony-out/v2 <BEACON_HEX> 10
# → PopRoleClaimV2_final.zkey, vkey_PopRoleClaimV2.json, Groth16VerifierV2.sol; transcript appended
```

## After the ceremony — integrate (the v2 deploy wave)

1. **Commit the vkey JSONs + full transcripts** (none exist on disk today; they're needed to audit the
   on-chain key forever).
2. **Re-vendor** the exported `Groth16Verifier{,V2}.sol` into `src/zkemail/vendor/`.
3. **Re-chunk + re-pin** each `_final.zkey`: `circuits/scripts/split-zkey.mjs`, then `~/pop-zk-work/host2.mjs`
   (NOT `host.mjs` — it UTF-8-mangles binary). Verify the sha256 round-trip.
4. **Bump** `NEXT_PUBLIC_ZKEMAIL_V{1,2}_MANIFEST` / `prover.js` manifest CIDs (frontend).
5. **Deploy** the new verifiers (DeterministicDeployer, fresh version string) and **repoint** via
   `ZkEmailInvites.setDomainVerifier` / `setEmailVerifier` (onlyExecutor = governance; remember the
   `announceWinner --gas-limit 3000000` gotcha). Update `OrgDeployer`'s zk-config verifier addresses so
   future org deploys use the ceremony keys.
## Auditing (anyone, anytime) — `verify-ceremony.sh`

The point of a ceremony is that you don't have to *trust* the coordinator — you *verify*. After the
run, publish `ceremony-out/*/` (final zkey + verifier + transcript) and let anyone re-check it:

```sh
circuits/ceremony/verify-ceremony.sh PopRoleClaimV2 \
    build/PopRoleClaimV2.r1cs ptau/powersOfTau28_hez_final_21.ptau \
    ceremony-out/v2/PopRoleClaimV2_final.zkey ceremony-out/v2/PopRoleClaimV2.transcript.txt \
    --expect-ptau-sha256 <the-hash-you-cross-checked>
```

What it checks (exit 0 = trustworthy, 1 = do NOT deploy):
- **ptau** hashes to the value you cross-checked against the published table, and matches the transcript.
- **`snarkjs zkey verify`** independently re-validates the ENTIRE contribution chain + beacon against
  the r1cs + ptau — the load-bearing cryptographic check.
- the **final zkey** matches the sha256 the transcript recorded (nothing swapped after finalize).

Optional flags:
- `--my-hash <hex>` — a contributor pastes the hash snarkjs printed for THEIR step; confirms it's in
  the final key (their contribution was actually included).
- `--onchain <verifier-addr> --rpc <url>` — confirms the DEPLOYED verifier's bytecode embeds this
  ceremony's verifying key (delta + IC points) — i.e. what's live on-chain IS this ceremony's output.
- `--beacon-block <N> --rpc <url>` — confirms the transcript's beacon == Ethereum block N's hash.

It's tamper-tested: it PASSES a clean run and FAILS a corrupted zkey, a swapped transcript hash, or a
contributor hash that isn't really in the ceremony.
