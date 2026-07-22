# Ceremony records (production phase-2)

Auditable summary of the multi-party trusted setup that produced the deployed verifiers. Full
re-verification (`verify-ceremony.sh`) also needs the final zkeys — those are 645 MB and live on IPFS,
not git; the pinned CIDs are in the frontend manifest.

- `vkey_*.json` — the verifying keys (nPublic 4 for domain, 5 for email).
- `*.transcript.txt` — the full chain: r1cs/ptau/0000 hashes, each contribution, the beacon.
- `../commitments/*.beacon-commit.txt` — the pre-block beacon commitments (posted publicly BEFORE the
  block; committed_at_block < beacon_block = the anti-grind proof).

**Contributors:** alice, bob, carol, dave, erin (5, independent). Beacon = Ethereum mainnet block
25576383 (v1) / 25576507 (v2) hash.

Both ceremonies are the FINAL, correct runs (v1 was re-run on the corrected circuit r1cs 173b6dd0…, beacon block 25589657; v2 on 23f94b368…, beacon 25576507). Both audits: AUDIT PASSED, and genuine proofs from both keys verify through the vendored verifiers + contract (test/ZkEmailRealProof.t.sol).
