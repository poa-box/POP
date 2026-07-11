# Blocker 2 — bind the From-domain to the DKIM signer (design spec)

Closes the soundness-critical form of Blocker 2 (`docs/ZKEMAIL_PRODUCTION_READINESS.md`): today the
domain used for the on-chain DKIM lookup (`domainName`) is **caller-supplied** and never proven to be
the From-address's domain. The whole "@good.com membership" guarantee rests on the operational
invariant *a registered DKIM key signs mail only for its own domain* (strict DMARC). This spec removes
that trust by proving the From-domain **in-circuit**.

> Must land **before** the ceremony (it changes the `.r1cs`). It also changes domain-leaf semantics, so
> it invalidates any live root — see Migration.

## Proven approach (spike)

`circuits/spikes/DomainBindSpike.circom` (+ `check.mjs`) is a compiled, witness-tested proof of the
core mechanism — mirroring V2's existing email-address extraction, but for the domain:

```
EmailDomainRegex(WIN)  →  SelectRegexReveal(WIN, DMAX)  →  ToLower  →  PackBytes(192)  →  Poseidon(7)  =  fromDomainHash
```

Result (reproduce: `cd ~/pop-zk-work && node spike/check.mjs`):
- **Correct + reproducible:** for `from:Alice <ALICE@Example.COM>` the circuit outputs
  `fromDomainHash` == the off-chain `Poseidon(packBytes(lower("example.com"), 192))` (the exact
  machinery `allowlist.js` already uses for `emailHash`). Mixed case + a display name are handled.
- **Cheap:** ~52.6k non-linear constraints — ≈7% on top of V2's ~1.2M. Acceptable.

So the domain identity can be a **Poseidon commitment the circuit proves**, consumed identically
on-chain and by the off-chain allowlist builder.

## Full design — domain identity = `Poseidon(packBytes(lower(domain), 192))` everywhere

The caller-supplied `domainName` disappears; `fromDomainHash` (a proven public signal) replaces it as
the single domain identity used for BOTH the DKIM registry lookup and the domain merkle leaf.

### Circuits
- **`PopRoleClaimV2.circom`**: add the extraction above; expose `fromDomainHash` as a new public
  signal. Public signals `4 → 5`: `[pubkeyHash, emailNullifier, claimerAddress, emailHash, fromDomainHash]`.
- **`PopRoleClaim.circom` (V1)**: today extracts *no* domain. Add the same From-window + EmailDomainRegex
  extraction and expose `fromDomainHash`. Public signals `3 → 4`:
  `[pubkeyHash, emailNullifier, claimerAddress, fromDomainHash]`. (This is the soundness-critical path.)
- New prover inputs: the From window + `domainIndexInWindow` (same shape as V2's existing From hints).

### Verifiers / ABI (rides the ceremony)
- `IZkEmailGroth16Verifier.verifyProof(..., uint256[3])` → `uint256[4]`; V2 `uint256[4]` → `uint256[5]`.
- `ZkEmailProof` / `ZkEmailProofV2`: drop `domainName` (string), add `bytes32 fromDomainHash`.
- New nPublic ⇒ new verifier bytecode + vkey ⇒ new trusted setup (the ceremony).

### `ZkEmailInvites.sol`
- `_commonPreChecks`: replace `dh = keccak256(_lower(domainName))` with `dh = proof.fromDomainHash`
  (the proven value); keep `dkimRegistry.isKeyHashValid(dh, pubkeyHash)`.
- `_claimDomain`: the domain leaf id becomes `proof.fromDomainHash` (was `keccak(domainName)`), so the
  leaf commits the *proven* domain. Add `signals[3] = uint256(proof.fromDomainHash)` to the domain
  verifier call; V2 gets `signals[4]`.
- Delete `_lower` and the `domainName` plumbing. Net effect: a domain claim can only mint for the domain
  the signed email is actually *from*.

### `PoaDKIMRegistry.sol`
- Key the registry by the **Poseidon** domain hash instead of `keccak256`. `domainHashOf(domain)` (the
  on-chain keccak helper) is removed from the hot path; seeding passes the **pre-computed**
  `Poseidon(packBytes(lower(domain),192))` (on-chain Poseidon is impractical; the frontend/scripts have
  circomlibjs). Keep the rotation/expiry API from the committed Advisory-5 change unchanged.

### Off-chain (`poa-app/src/lib/zkemail/allowlist.js` + gen-inputs + prover)
- `domainHash(domain)` switches from `keccak256(stringToBytes(norm(domain)))` to the **Poseidon**
  commitment (reuse the `emailHash` packing with the domain string). The merkle domain-leaf id is then
  the same value the circuit proves.
- `prover.js`: build the domain proof with the From window + `domainIndexInWindow`; drop `domainName`.
- `gen-inputs.mjs`: emit the new domain-window inputs.

### Merkle leaf
- Leaf tuple is unchanged in *shape* (`[kind, id, hatIds]`); only the domain `id` derivation changes
  (keccak → Poseidon). Email leaves are already `emailHash` (Poseidon) — unchanged.

## Migration

Changing the domain-leaf id changes every domain root. **Live allowlists with domain entries (Test6)
must be re-staged + re-activated** after this ships (part of the v2 wave). Email-only allowlists are
unaffected. Sequence: land circuit + contracts → ceremony → deploy verifiers + new registry → re-stage
roots → governance repoint. (See the wave in `ZKEMAIL_PRODUCTION_READINESS.md`.)

## Why not ship it independently now

It changes the verifier ABI (needs the ceremony's new keys to even produce a valid proof) and breaks
Test6's root. Shipping it before the ceremony would leave an unprovable circuit; shipping it without the
re-stage would brick Test6. It is correct to stage it as the first step of the single coordinated wave —
which this spec + the ceremony tooling make turnkey. The interim mitigation (only strict-DMARC domains
registered — currently gmail.com + ku.edu) holds until then.
