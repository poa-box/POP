// SPDX-License-Identifier: MIT
// ERC-7969: DomainKeys Identified Mail (DKIM) Registry — minimal interface
// https://eips.ethereum.org/EIPS/eip-7969
pragma solidity ^0.8.21;

interface IDKIMRegistry {
    /// @notice Returns true if `keyHash` is currently a valid DKIM public-key hash for `domainHash`.
    /// @param domainHash An opaque per-domain commitment. ERC-7969's example uses keccak256(domain), but
    ///        POP passes the ZK circuit's **Poseidon** `fromDomainHash` — seed `PoaDKIMRegistry` with that.
    /// @param keyHash    Hash of the DKIM RSA public key as published in DNS TXT (algorithm per impl).
    function isKeyHashValid(bytes32 domainHash, bytes32 keyHash) external view returns (bool);
}
