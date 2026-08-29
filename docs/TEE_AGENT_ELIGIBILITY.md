# TEE agent eligibility (attestation-pinned hats)

`TEEAgentEligibilityModule` lets an org grant a Hats Protocol role **to an
enclave image rather than to an address** — the endgame of the sigstack-bot
integration. A wallet may wear the agent hat only while it holds a fresh
attestation binding it to a TEE measurement that governance has explicitly
allowed. Upgrading the agent's code becomes a governance event; retiring or
rotating a measurement de-authorizes every wallet on that image instantly.

This closes the loop left open by the base integration
([`SIGSTACK_BOT_INTEGRATION.md`](SIGSTACK_BOT_INTEGRATION.md)): there, governance
grants a hat to the bot's address and trusts *off-band* that the running TDX
quote matches the intended code. Here, the grant is *conditional on the
measurement*.

## Contracts

| File | Role |
|------|------|
| `src/TEEAgentEligibilityModule.sol` | Hats `IHatsEligibility` module; pins a hat to allowed measurements + live bindings. |
| `src/interfaces/ITEEAttestationVerifier.sol` | Pluggable verifier: raw attestation → `(subject, measurement, expiry)`. |
| `src/verifiers/TrustedSignerAttestationVerifier.sol` | Ships-today verifier: an off-chain notary runs DCAP and signs the triple. |
| `test/mocks/MockTEEAttestationVerifier.sol` | Test verifier (no crypto). |

## How it works

1. **Governance allows a measurement.** The org Executor (the module's
   `governor`) calls `setMeasurementAllowed(hatId, measurement, true)`. The
   `measurement` identifies the attested enclave image (e.g. a hash of the TDX
   RTMRs / mrtd of the sigstack-bot build).
2. **The agent attests.** Anyone (typically the bot) calls
   `submitAttestation(hatId, attestation)`. The pluggable verifier authenticates
   the blob and returns `(subject, measurement, expiry)`; if the measurement is
   allowed and unexpired, the module records a binding `subject → (measurement,
   expiry)`.
3. **Hats checks eligibility live.** `getWearerStatus(wearer, hatId)` returns
   eligible iff the binding is active, unexpired, **and** its measurement is
   still allowed. So three levers each drop the hat immediately:
   - measurement retired by governance (`setMeasurementAllowed(..., false)`),
   - attestation freshness lapses (bindings carry an `expiry`; the agent
     re-attests periodically),
   - explicit `revokeBinding(wearer, hatId)` (emergency kill for one wallet).

Wire it into an org exactly like the existing `EligibilityModule`: create the
agent hat with this module as its eligibility module, then run steps above via
governance. Combined with a `TaskManager` role grant (see
[`SIGSTACK_BOT_INTEGRATION.md`](SIGSTACK_BOT_INTEGRATION.md)) and PaymasterHub gas
sponsorship, the bot is a governance-hired, attestation-gated org member.

## The verifier is the trust seam

`ITEEAttestationVerifier` is deliberately the only trusted component, and it is
swappable via `setVerifier` without touching the module:

- **`TrustedSignerAttestationVerifier` (today).** An off-chain notary service
  runs the real DCAP/TDX quote verification and ECDSA-signs the
  `(subject, measurement, expiry)` triple, bound to the verifier address + chain
  id (no cross-chain replay). Trust reduces to that signer, which governance can
  rotate. Honest and deployable now.
- **On-chain DCAP verification (later).** A verifier that checks the TDX quote
  and Intel PCS collateral entirely on-chain would make the system trustless. It
  is a large separate effort; the interface exists so it can be slotted in with a
  single `setVerifier` call.

## Testing

```sh
forge test --match-contract TEEAgentEligibilityModuleTest -vv
```

Covers the happy path, every rejection (disallowed measurement, expiry, verifier
revert), the three live-revocation levers, verifier swap, and the notary-signer
verifier end-to-end (valid + forged signature).

## Deployment note

`TEEAgentEligibilityModule` is upgradeable (ERC-7201 namespaced storage, no
`__gap`, `_disableInitializers()` in the constructor) — deploy behind a proxy and
call `initialize(governor, verifier)`. A production rollout should pair a
`BroadcastX`/`SimX` script per the repo's "simulate before declaring done" rule;
that script is left for the deploying operator since it depends on the target
org's Executor address and chain.
