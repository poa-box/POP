# PopRoleClaim — client-side ZK Email role-claim circuit

`PopRoleClaim.circom` is the zero-knowledge circuit behind `ZkEmailInvites`. It lets a user prove —
**entirely in their browser, with no relayer** — that they control an email at an allowlisted domain,
and binds the claim to a specific Ethereum address. The on-chain verifier it generates is vendored at
[`src/zkemail/vendor/Groth16Verifier.sol`](../src/zkemail/vendor/Groth16Verifier.sol) and consumed by
[`ZkEmailInvites`](../src/ZkEmailInvites.sol).

## What it proves

Given a raw DKIM-signed email, the circuit proves:

1. The email header carries a valid **DKIM RSA-2048 / SHA-256 signature** (via zk-email's
   `@zk-email/circuits` `EmailVerifier`, header-only — body is ignored).
2. The signed header contains the command **`Claim POP role for 0x<40-hex>`**, and it decodes that
   address in-circuit.

### Public signals (`uint[3]`, in order)

| idx | signal           | meaning                                                                 |
|-----|------------------|-------------------------------------------------------------------------|
| 0   | `pubkeyHash`     | Poseidon hash of the sender's DKIM RSA pubkey. On-chain, `PoaDKIMRegistry` maps an allowlisted domain → this hash, so the domain is **not** extracted in-circuit. |
| 1   | `emailNullifier` | `poseidon(poseidon(signature))` — single-use replay guard.              |
| 2   | `claimerAddress` | the address parsed from the signed command. Supplied on-chain as `uint256(uint160(claimer))`, so a proof can only ever mint to the bound address. |

The domain string is passed to the contract by the submitter and bound to `pubkeyHash` via
`PoaDKIMRegistry.isKeyHashValid` — a forged domain fails that check even though the Groth16 proof
itself would verify.

Circuit size: **717,888 non-linear constraints** (fits a `2^20` Powers-of-Tau).

## Toolchain

- `circom` **2.2.3** (build from source: `git clone https://github.com/iden3/circom && cargo build --release`)
- `@zk-email/circuits` **6.3.4**, `circomlib` **2.0.5**
- `snarkjs` (via `npm`), `@zk-email/helpers` **6.4.2** + `nodemailer` (input generation / local test email)

```sh
cd circuits && npm install
```

## Build / rotate the verifier

```sh
CIRCOM=/path/to/circom/target/release/circom

# 1. compile
$CIRCOM PopRoleClaim.circom --r1cs --wasm --sym -l node_modules -o build/

# 2. Powers of Tau (2^20 is sufficient; ~1.1 GB — do NOT commit)
curl -L -o build/pot20.ptau https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau

# 3. Groth16 setup + phase-2 contribution + export the on-chain verifier
npx snarkjs groth16 setup build/PopRoleClaim.r1cs build/pot20.ptau build/pop_0000.zkey
npx snarkjs zkey contribute build/pop_0000.zkey build/pop_final.zkey --name=ceremony -e="<entropy>"
npx snarkjs zkey export verificationkey build/pop_final.zkey build/vkey.json
npx snarkjs zkey export solidityverifier build/pop_final.zkey ../src/zkemail/vendor/Groth16Verifier.sol

# 4. generate a witness + proof from a (locally signed) test email
node scripts/gen-inputs.mjs 0x<claimerAddress>          # -> build/input.json, build/test.eml
node build/PopRoleClaim_js/generate_witness.js build/PopRoleClaim_js/PopRoleClaim.wasm build/input.json build/witness.wtns
npx snarkjs groth16 prove build/pop_final.zkey build/witness.wtns build/proof.json build/public.json
npx snarkjs groth16 verify build/vkey.json build/public.json build/proof.json   # -> OK!
npx snarkjs zkey export soliditycalldata build/public.json build/proof.json     # -> calldata for the contract
```

> ⚠️ **Trusted setup.** The vendored `Groth16Verifier.sol` was produced with a **single-contributor
> dev phase-2 setup** — fine for testnet, **not** production. Before mainnet, run a proper multi-party
> ceremony, re-export `Groth16Verifier.sol`, redeploy it, and repoint the module via
> `ZkEmailInvites.setVerifier` (governance). Rotating the setup invalidates every previously generated
> proof and the fixtures below.

## Fixtures

[`fixtures/`](./fixtures) holds the exact artifacts the on-chain spike test
([`test/ZkEmailRealProof.t.sol`](../test/ZkEmailRealProof.t.sol)) hard-codes:

- `test.eml` — a locally DKIM-signed email, subject `Claim POP role for 0xA6F4…b2c9`, domain `poptest.example`.
- `proof.json` / `public.json` — the genuine Groth16 proof + its 3 public signals.
- `soliditycalldata.txt` — the same proof formatted for `Groth16Verifier.verifyProof` (G2 pairs swapped).

`gen-inputs.mjs` mints a throwaway DKIM keypair and monkeypatches zk-email's DoH resolver to return it,
so a genuine proof is produced fully offline (no live DNS, no real mailbox). For a real claim, the
sender's actual domain DKIM key must be seeded into `PoaDKIMRegistry`.

## Frontend

The static site proves in-browser with `snarkjs` + this circuit's `.wasm`/`.zkey` (host the `.zkey`
on IPFS/CDN; it is not committed). The browser submits the `ZkEmailProof` to `ZkEmailInvites.claimRoleByDomain`.
