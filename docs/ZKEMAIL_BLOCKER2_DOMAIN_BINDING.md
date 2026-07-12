# Blocker 2 — bind the From-domain to the DKIM signer (design spec)

Closes the soundness-critical form of Blocker 2 (`docs/ZKEMAIL_PRODUCTION_READINESS.md`): today the
domain used for the on-chain DKIM lookup (`domainName`) is **caller-supplied** and never proven to be
the From-address's domain. The whole "@good.com membership" guarantee rests on the operational
invariant *a registered DKIM key signs mail only for its own domain* (strict DMARC). This spec removes
that trust by proving the From-domain **in-circuit**.

> Must land **before** the ceremony (it changes the `.r1cs`). It also changes domain-leaf semantics, so
> it invalidates any live root — see Migration.

## Implementation (built + validated)

Implemented in `circuits/from_domain.circom` (`FromAddrCommit`), used by both `PopRoleClaim.circom`
(V1) and `PopRoleClaimV2.circom` (V2). Both circuits compile (~992k constraints, under 2^20) and pass
witness + soundness validation with a real DKIM-signed email.

**Design note — why NOT a standalone domain regex.** An early spike (`circuits/spikes/DomainBindSpike.circom`)
used `EmailDomainRegex`, which turned out to reveal **every** `@domain` in the header (from:, to:,
message-id), so it is *not* From-anchored and can't bind the sender. The shipped design instead derives
the domain from the address that **`FromAddrRegex`** extracts (which anchors to the line-start `from:`,
the unique signed From field), then splits it at its single `@` in-circuit:

```
FromAddrRegex(WIN) → SelectRegexReveal → ToLower  ─┬─ PackBytes(192)→Poseidon(7) = emailHash      (full address)
                                                   └─ mask≤@, VarShiftLeft past @, PackBytes→Poseidon = fromDomainHash
```

The `@`-split is sound: `atIndex` (a prover hint) is constrained to be an `@` with no earlier `@`, so it
is forced to the real (only) `@`. `VarShiftLeft` is a *circular* rotate, so the local part is masked to
zero before the shift, leaving a clean `domain + trailing zeros` buffer.

Validated (reproduce from `~/pop-zk-work`, after compiling + `node scripts/gen-inputs.mjs`):
- **Correct + reproducible:** circuit `fromDomainHash` == off-chain `Poseidon(packBytes(lower(domain),192))`
  (the exact machinery `allowlist.js` uses for `emailHash`); `emailHash` still matches too; V1 and V2
  emit the **same** `fromDomainHash` for the same email.
- **Sound:** a wrong `atIndex` (mid-local-part, into the domain, or 0) is rejected by the `@` constraint.
- **From-anchored:** the domain comes from the From address, never a to:/message-id domain.
- **Cost:** ~992k non-linear constraints for both circuits (V1 grew because it now extracts the From
  address too; both still fit pot20/pot21).

## Full design — domain identity = `Poseidon(packBytes(lower(domain), 192))` everywhere

The caller-supplied `domainName` disappears; `fromDomainHash` (a proven public signal) replaces it as
the single domain identity used for BOTH the DKIM registry lookup and the domain merkle leaf.

### Circuits (DONE)
- **`PopRoleClaimV2.circom`**: expose `fromDomainHash` — public signals `4 → 5`:
  `[pubkeyHash, emailNullifier, claimerAddress, emailHash, fromDomainHash]`.
- **`PopRoleClaim.circom` (V1)**: extracted *no* domain before; now runs the shared `FromAddrCommit` and
  exposes `fromDomainHash` — public signals `3 → 4`:
  `[pubkeyHash, emailNullifier, claimerAddress, fromDomainHash]`. (The soundness-critical path.)
- New prover inputs (both): `fromWindowIndex`, `emailIndexInWindow`, `atIndex` (all From-field hints;
  `gen-inputs.mjs` emits them). V1 and V2 accept identical input JSON.

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
