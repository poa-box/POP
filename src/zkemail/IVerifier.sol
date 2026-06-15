// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @notice Groth16 verifier interface matching the snarkjs-generated `Groth16Verifier` for the
///         `PopRoleClaim` circuit (3 public signals). The deployed verifier is the vendored
///         `vendor/Groth16Verifier.sol`.
/// @dev Public signal order is fixed by the circuit: [pubkeyHash, emailNullifier, claimerAddress].
interface IZkEmailGroth16Verifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[3] calldata pubSignals
    ) external view returns (bool);
}

/// @notice A client-side ZK Email role-claim proof for the `PopRoleClaim` circuit.
/// @dev `pA/pB/pC` are the Groth16 proof points. `pubkeyHash` and `emailNullifier` are two of the
///      circuit's three public outputs; the third (the claimer address) is supplied by the caller
///      as `uint256(uint160(claimer))`, so it is NOT carried in this struct — that is exactly what
///      binds the proof to a specific recipient.
///      `domainName` is NOT a circuit signal: it is the submitter-provided sending domain whose DKIM
///      key hash is `pubkeyHash`. The on-chain DKIM registry binds the two (`isKeyHashValid(
///      keccak256(lower(domainName)), pubkeyHash)`), so a forged domain string fails the registry
///      check even though the Groth16 proof would still verify.
struct ZkEmailProof {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    bytes32 pubkeyHash;
    bytes32 emailNullifier;
    string domainName;
}
