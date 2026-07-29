# circuits/spikes

Compile-tested proofs-of-concept that de-risk a design before the full change. Not part of the build.

## DomainBindSpike.circom

Proves the **Blocker 2** approach (`docs/ZKEMAIL_BLOCKER2_DOMAIN_BINDING.md`): the From-address domain
can be extracted in-circuit and committed with Poseidon so the on-chain DKIM lookup + domain leaf bind
to the *proven* domain instead of a caller-supplied string.

Reproduce (from `~/pop-zk-work`, where the circom binary + node_modules live):

```sh
CIRCOM=circom-src/target/release/circom
$CIRCOM spike/DomainBindSpike.circom --r1cs --wasm -l node_modules -o spike/
node spike/check.mjs   # → "✅ MATCH — in-circuit domain extraction == off-chain commitment"
```

(The repo copies here are the source of truth; the `~/pop-zk-work/spike` copies are the scratch build
location.) Result on record: ~52.6k non-linear constraints (~7% over V2), and the circuit's
`fromDomainHash` equals `Poseidon(packBytes(lower(domain),192))` — the exact machinery `allowlist.js`
uses for `emailHash` — for a mixed-case, display-name From header.
