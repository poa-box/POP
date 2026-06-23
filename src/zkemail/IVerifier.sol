// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @notice Groth16 verifier interface for the `PopRoleClaim` (domain) circuit — 3 public signals.
/// @dev Signal order: [pubkeyHash, emailNullifier, claimerAddress]. Deployed verifier:
///      `vendor/Groth16Verifier.sol`.
interface IZkEmailGroth16Verifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[3] calldata pubSignals
    ) external view returns (bool);
}

/// @notice Groth16 verifier interface for the `PopRoleClaimV2` (specific-email) circuit — 4 public
///         signals (adds `emailHash`, a Poseidon commitment to the sender's From address).
/// @dev Signal order: [pubkeyHash, emailNullifier, claimerAddress, emailHash]. Deployed verifier:
///      `vendor/Groth16VerifierV2.sol`.
interface IZkEmailGroth16VerifierV2 {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[4] calldata pubSignals
    ) external view returns (bool);
}

/// @notice A client-side ZK Email proof for the `PopRoleClaim` (domain) circuit.
/// @dev `pubkeyHash`/`emailNullifier` are two of the three public outputs; the third (claimer address)
///      is supplied by the caller as `uint256(uint160(claimer))`, binding the proof to one recipient.
///      `domainName` is NOT a circuit signal — it is the submitter-provided sending domain whose DKIM
///      key hash is `pubkeyHash`; the on-chain DKIM registry binds the two.
struct ZkEmailProof {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    bytes32 pubkeyHash;
    bytes32 emailNullifier;
    string domainName;
}

/// @notice A client-side ZK Email proof for the `PopRoleClaimV2` (specific-email) circuit.
/// @dev Same as `ZkEmailProof` plus `emailHash` — the in-circuit Poseidon commitment to the (lowercased)
///      From email address, supplied on-chain as the fourth public signal and used as the merkle-leaf
///      identity for specific-address allowlist entries.
struct ZkEmailProofV2 {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    bytes32 pubkeyHash;
    bytes32 emailNullifier;
    string domainName;
    bytes32 emailHash;
}
