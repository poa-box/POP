# ⚠️ v1 (PopRoleClaim / domain) ceremony is VOID — being re-run

The first v1 ceremony ran on a **stale circuit**: `build/PopRoleClaim.r1cs` had not been recompiled
after the Blocker-2 mask fix, so the domain circuit produced a **corrupted `fromDomainHash`** (the
circular-shift wrapped the email local-part into the domain bytes). Effect: `fromDomainHash` depended
on the local-part, so a domain-allowlist entry could not match multiple users — domain claims would
fail on-chain. Proven: a proof from the v1 ceremony key gives `fromDomainHash = 4922473972…` whereas the
correct value (matching v2 + the off-chain builder) is `14160378885…`.

- **v2 (email) is UNAFFECTED** — its ceremony ran on the correct circuit (r1cs `23f94b368…`, verified
  three ways) and its `fromDomainHash` is correct. Keep it.
- The stale v1 artifacts are preserved at `~/pop-zk-work/ceremony-out/v1-VOID-stale-circuit/`.
- v1 is being re-run on the CORRECT circuit (r1cs `173b6dd0…`, 992416 constraints). After the redo:
  re-vendor `Groth16Verifier.sol`, replace `records/vkey_PopRoleClaim.json` +
  `PopRoleClaim.transcript.txt` + `commitments/PopRoleClaim.beacon-commit.txt`, and delete this note.

**Do not deploy the current `src/zkemail/vendor/Groth16Verifier.sol` until the redo completes.**
