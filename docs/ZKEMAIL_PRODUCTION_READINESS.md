# ZK Email Invites — Production Readiness

Status of the gates that must close before a **production/mainnet** org activates a real
`ZkEmailInvites` allowlist. Testnet (Test6 on Gnosis) is fine to keep running.

Last updated: 2026-07-11. Owner: see git blame. This supersedes the ad-hoc "fix list" — where they
disagree, this doc reflects verified ground truth (each claim below was checked against live chain,
source, or a local proof, not assumed).

---

## TL;DR

| # | Item | Severity | Status |
|---|------|----------|--------|
| 1 | Groth16 verifiers hold a **DEV single-contributor** trusted setup | 🔴 Blocker | **OPEN** — confirmed live on-chain; needs a multi-party ceremony (human) |
| 2 | Circuit does not bind the From-address domain to the DKIM signer | 🔴 Blocker (reframed) | **OPEN** — mitigated in practice; circuit fix rides the ceremony |
| 3 | Email-claim path bypassed the H-03 open-hat gate | 🟠 Should-fix | ✅ **DONE** (this branch) |
| 4 | One-domain-per-keyHash assumption undocumented | 🟡 Advisory | Subsumed by #2; documented below |
| 5 | No DKIM key rotation / staleness handling | 🟡 Advisory | ✅ **DONE** (this branch) |
| 6 | Allowlist builder lowercase parity (frontend) | 🟡 Advisory | ✅ **DONE** (frontend branch) |

**Bottom line:** two blockers remain, and both are closed by the *same coordinated deploy wave*
(finalize circuits → run the ceremony → redeploy verifiers → governance repoint). Neither can be
fully closed by an agent alone — the ceremony requires multiple independent human contributors.
Until then: **keep zk-email testnet-only; do not activate a real merkleRoot on a production org.**

---

## Blocker 1 — DEV trusted setup (CONFIRMED LIVE)

**Claim:** the deployed verifiers hold a single-contributor Groth16 phase-2 key, so whoever generated
the `.zkey` holds the toxic waste and can forge a valid proof for arbitrary public signals (any
claimer / emailHash) → mint any allowlisted hat to anyone, with no email.

**Verification (done, not assumed):** exported the verifying key from the local dev zkey
(`~/pop-zk-work/build/PopRoleClaim.zkey`, sha256 `7eb1f80d…`, which equals the served v1 manifest
sha) and confirmed **6/6 phase-2 constants are embedded in the live domainVerifier bytecode** on
Gnosis:

- domainVerifier `0x7698c3234E1f76221Dd0619cdEa0FC0D6fF8045D` — delta (both G2 coords) + all 4 IC
  points of the local dev zkey match the on-chain constants exactly.
- emailVerifier `0x0Ba1ab7A148Ad78e84B4f7c28e27BE295A499f66` — distinct contract; both verifiers'
  source headers self-document as "DEV single-contributor trusted setup".

Both v1 (domain) and v2 (email) zkeys were produced by a single `snarkjs zkey contribute` with
timestamp entropy (`~/pop-zk-work/run-setups.sh`, `run-v2-setup.sh`). **This is exploitable today** —
it is the one crypto gate and it is forgeable. The only reason it is not currently a live loss is
that no production org has an active root (Test6 is testnet).

### Fix — multi-party phase-2 ceremony (HUMAN, must run LAST on the final circuits)

Run **after** the Blocker 2 circuit change lands (a circuit edit changes the r1cs, which invalidates
any earlier phase-2 contribution — running the ceremony first would waste it).

Per circuit (v1 domain, v2 email), the sequence is the standard snarkjs Groth16 phase-2:

1. Re-download the Powers-of-Tau file and **hash-verify** it against the published Hermez/snarkjs
   table (v1 uses `powersOfTau28_hez_final_20.ptau`, v2 needs `…_21.ptau` — v2 has 1.2M constraints,
   over 2^20). Keep the hash in the transcript.
2. `snarkjs groth16 setup <circuit>.r1cs pot<N>.ptau <circuit>_0000.zkey`.
3. **N independent contributors**, each on their own machine: `snarkjs zkey contribute <in> <out>
   --name="<contributor id>"` with fresh entropy they alone provide, publishing the resulting hash.
   The setup is secure as long as **at least one** contributor is honest and discards their entropy.
4. `snarkjs zkey beacon` (public randomness beacon) to finalize.
5. `snarkjs zkey verify <circuit>.r1cs pot<N>.ptau <final>.zkey` → must report OK.
6. Export: `snarkjs zkey export verificationkey` (commit the vkey JSON — **none exists on disk today**,
   they were cleaned up) and `snarkjs zkey export solidityverifier` → re-vendor
   `src/zkemail/vendor/Groth16Verifier{,V2}.sol`.
7. Re-chunk (`circuits/scripts/split-zkey.mjs`), re-pin to IPFS via `~/pop-zk-work/host2.mjs`
   (**not** `host.mjs` — it UTF-8-mangles binary), bump `NEXT_PUBLIC_ZKEMAIL_V{1,2}_MANIFEST` /
   `prover.js` manifest CIDs, and verify the sha256 round-trip.
8. Deploy the new verifiers (DeterministicDeployer, fresh version string) and repoint via
   `ZkEmailInvites.setDomainVerifier` / `setEmailVerifier` (onlyExecutor = governance).
9. **Keep the full transcript** (ptau hash, every contribution hash, beacon value) so the on-chain
   vkey is auditable against the ceremony forever.

Rotation is atomic-sensitive: the verifier vendoring, the on-chain verifier, all fixtures, and the
pinned artifacts must move together — a drift here already caused a live `InvalidProof` incident
(commit `4ed1288c`). Also update `OrgDeployer`'s zk-config verifier addresses so *future* org deploys
point at the ceremony verifiers, not the stale dev ones.

---

## Blocker 2 — From-domain not bound to the DKIM signer (reframed)

**The fix list's framing overstated the V2 case.** Verified against the circuits:

- **V1 (domain path, `PopRoleClaim.circom`)** exposes public signals `[pubkeyHash, emailNullifier,
  claimerAddress]` — it extracts **no domain at all**. The domain↔key binding is entirely on-chain:
  `registry[keccak(domainName)] == pubkeyHash`, where `domainName` is a **caller-supplied** string and
  the merkle leaf id is also `keccak(domainName)`. Security rests entirely on the assumption *a
  registered DKIM keyHash signs mail only for its own domain's From address.*
- **V2 (specific-email path, `PopRoleClaimV2.circom`)** adds `emailHash` = Poseidon(lowercase full
  From address). The leaf is keyed by `emailHash`, which pins the **entire** address (incl. domain).
  So V2's missing `domainName`↔From-domain constraint is **defense-in-depth, not direct
  impersonation** — an attacker cannot claim `victim@good.com`'s entry without an email actually
  `From: victim@good.com` signed by good.com's key.

**The soundness-critical form is the shared assumption** (affects V1 at least as much as V2): if a
registered domain's DKIM key will sign an email carrying an attacker-chosen `From` (an open
forwarder / lax ESP / self-hosted domain), an attacker can mint that domain's role — or, on V2,
someone else's specific-address role.

### Interim mitigation (ALREADY in place)

Only register DKIM keys for domains that enforce strict DMARC / From-alignment; never seed
forwarders / mailing lists / lax providers. The live registry holds only `gmail.com` + `ku.edu`,
both strict. **Keep this invariant until the circuit fix ships.** (Advisory 4 — one-domain-per-keyHash
— is the same rule stated for the registry; enforce/document it, or let the circuit fix subsume it.)

### Fix — bind the From-domain in-circuit (rides the ceremony)

Neither circuit extracts the domain today, so the fix must **add** From-domain extraction (the fix
list's "reuse V1's extraction" is a misnomer — V1 has none). Recommended shape:

- Add `EmailDomainRegex` (a small ~4-state DFA from `@zk-email/zk-regex-circom`) over the From reveal,
  then `SelectRegexReveal` → `ToLower` → `PackBytes` → Poseidon, and expose a **`fromDomainCommit`**
  public signal.
- Derive the on-chain DKIM registry lookup key from the proven `fromDomainCommit` instead of the
  caller-supplied `domainName`, so `registry[fromDomain] == pubkeyHash` is enforced against the
  *proven* From-domain.
- Apply to **both** V1 and V2 (V1 is the soundness-critical path).

**Blast radius (why this rides the ceremony):** changing public signals means new nPublic → new
verifier bytecode + vkey → new trusted setup. It also changes `IZkEmailGroth16Verifier*.verifyProof`
arity, the `ZkEmailProof{,V2}` structs, `ZkEmailInvites._claim*`/`_commonPreChecks` signal wiring and
`dh` derivation, `~/pop-zk-work/gen-inputs*.mjs`, and the frontend `prover.js` proof assembly. Do the
circuit change, prove it locally with real `.eml` fixtures, **then** run the ceremony on the final
r1cs.

---

## Blocker 3 — open-hat gate on the email-claim path — ✅ DONE

`ZkEmailInvites._claimDomain`/`_claimEmail` minted allowlisted hats with no open-hat check — the same
self-mint escalation the audit closed on QuickJoin (H-03), on this parallel path. An org whose
allowlist granted an open-to-everyone hat (e.g. `ELIGIBILITY_ADMIN`, default-eligible on live Gnosis
orgs) let anyone in the domain self-mint it → org takeover.

**Fix (committed):** mirror QuickJoin's fail-closed probe — for each hat, `hats.isEligible(SENTINEL,
hatId)`; eligible ⇒ open ⇒ revert `HatOpenlyClaimable`; a reverting probe ⇒ reject (fail closed). The
Hats reference is read from the Executor via a new `Executor.hats()` view getter, **not** a new
`ZkEmailInvites` storage field — so it ships as a pure impl upgrade with **no migration** of the
already-deployed Test6 proxy. Verified on live Gnosis that the real Test6 Member hat reports the
sentinel *not* eligible, so real claims still pass; only open hats are rejected. 8 new tests.

---

## Advisory 5 — DKIM key rotation — ✅ DONE

`PoaDKIMRegistry` stored keys as a bare bool, so a leaked, rotated-out key stayed valid forever. Each
key now carries an expiry (`0` = revoked, `NO_EXPIRY` = permanent, else a unix cut-off);
`isKeyHashValid` enforces it. Added `setKeyHashWithExpiry` / `setKeyForDomainWithExpiry`,
`revokeKeyHash` + `revokeKeyHashes` (owner bulk-revoke), and a `keyValidUntil` view. Boolean setters
are backward-compatible (`true → NO_EXPIRY`, `false → revoked`). Non-upgradeable contract → ships as a
fresh deploy + governance repoint in the v2 wave. 11 new tests.

---

## Advisory 6 — allowlist lowercase parity (frontend) — ✅ DONE

The fix list's premise ("contract lowercases the registry lookup only") is **wrong** — `ZkEmailInvites`
uses the lowercased hash for the merkle **leaf** too, and the system was already lowercase-consistent
for ASCII at every layer. The one real gap: the builder used JS Unicode `.toLowerCase()` while the
circuit/contract lowercase ASCII-only, so a non-ASCII identifier could build an unclaimable leaf
(fail-closed, no security risk). **Fix (committed, frontend):** ASCII-only `norm`, a build-time guard
that rejects non-ASCII identifiers for *all* callers, canonical (normalized) stored identifiers, and a
tightened editor email regex. Test6's live root is unaffected (its entries are already lowercase
ASCII).

---

## The coordinated v2 deploy wave (dependency order)

Everything below moves together; do not activate a production org until it is complete.

1. **Circuit change (Blocker 2)** — edit `PopRoleClaim{,V2}.circom`, prove locally with real `.eml`
   fixtures, finalize the r1cs.
2. **Contract changes** — Blocker 2 signal wiring in `ZkEmailInvites` (+ the already-committed H-03
   gate and DKIM rotation). Land + fork-sim per `CLAUDE.md`.
3. **Ceremony (Blocker 1)** — multi-party phase-2 on the final circuits; export + re-vendor verifiers;
   commit vkeys + transcript.
4. **Deploy** — new verifiers + `PoaDKIMRegistry` + `ZkEmailInvites` impl; re-pin artifacts + bump
   manifest CIDs; update `OrgDeployer` zk-config addresses.
5. **Governance repoint** — `setDomainVerifier` / `setEmailVerifier` / `setDKIMRegistry` on each live
   module (remember the `announceWinner --gas-limit 3000000` gotcha for non-trivial batches).
6. **Frontend** — ship the Advisory 6 lowercase fix + new manifest CIDs.

## Go / no-go checklist to activate a production org

- [ ] Ceremony transcript exists and the on-chain vkey verifies against it (Blocker 1).
- [ ] Circuit binds the From-domain to the DKIM signer, or **every** registered domain enforces strict
      DMARC/From-alignment (Blocker 2 — fix or documented mitigation).
- [x] Open-hat gate live on the claim path (Blocker 3).
- [x] DKIM registry supports rotation/revocation (Advisory 5).
- [x] Allowlist builder guarantees on-chain-reproducible leaves (Advisory 6).
- [ ] The org's allowlist grants only **gated** role hats (verified via the sentinel probe), never an
      open/administrative hat.
