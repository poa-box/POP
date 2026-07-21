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

**Note on the v1 transcript:** `alice` appears three times — she retried twice during early
prompt friction, so her first two outputs were overwritten before `bob` built on the third. This is
purely a log of attempts; the authoritative `snarkjs zkey verify` (see `verify-ceremony.sh`) confirms
the final key contains exactly **5** contributions (one alice), and erin's last contribution
(`c6f9198f…`) matches the beacon commitment. Both audits: **AUDIT PASSED**.
