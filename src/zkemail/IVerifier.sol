// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @notice Groth16 verifier interface for the `PopRoleClaim` (domain) circuit — 4 public signals.
/// @dev Signal order: [pubkeyHash, emailNullifier, claimerAddress, fromDomainHash]. Deployed verifier:
///      `vendor/Groth16Verifier.sol`.
interface IZkEmailGroth16Verifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[4] calldata pubSignals
    ) external view returns (bool);
}

/// @notice Groth16 verifier interface for the `PopRoleClaimV2` (specific-email) circuit — 5 public
///         signals (adds `emailHash` + `fromDomainHash`, Poseidon commitments to the sender's From
///         address and its domain).
/// @dev Signal order: [pubkeyHash, emailNullifier, claimerAddress, emailHash, fromDomainHash]. Deployed
///      verifier: `vendor/Groth16VerifierV2.sol`.
interface IZkEmailGroth16VerifierV2 {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[5] calldata pubSignals
    ) external view returns (bool);
}

/// @notice A client-side ZK Email proof for the `PopRoleClaim` (domain) circuit.
/// @dev `pubkeyHash`/`emailNullifier`/`fromDomainHash` are three of the four public outputs; the third
///      (claimer address) is supplied by the caller as `uint256(uint160(claimer))`, binding the proof to
///      one recipient. `fromDomainHash` is the in-circuit Poseidon commitment to the PROVEN From-address
///      domain (Blocker 2) — the contract binds the DKIM registry lookup + the domain merkle leaf to it,
///      so the sending domain is no longer caller-supplied.
struct ZkEmailProof {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    bytes32 pubkeyHash;
    bytes32 emailNullifier;
    bytes32 fromDomainHash;
}

/// @notice A client-side ZK Email proof for the `PopRoleClaimV2` (specific-email) circuit.
/// @dev Same as `ZkEmailProof` plus `emailHash` — the in-circuit Poseidon commitment to the (lowercased)
///      From email address, supplied on-chain as the fourth public signal and used as the merkle-leaf
///      identity for specific-address allowlist entries. `fromDomainHash` is the fifth signal.
struct ZkEmailProofV2 {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    bytes32 pubkeyHash;
    bytes32 emailNullifier;
    bytes32 emailHash;
    bytes32 fromDomainHash;
}
