// SPDX-License-Identifier: MIT
// ERC-7969: DomainKeys Identified Mail (DKIM) Registry — minimal interface
// https://eips.ethereum.org/EIPS/eip-7969
pragma solidity ^0.8.21;

interface IDKIMRegistry {
    /// @notice Returns true if `keyHash` is currently a valid DKIM public-key hash for `domainHash`.
    /// @param domainHash keccak256 of the lowercase ASCII domain (e.g. keccak256("anthropic.com"))
    /// @param keyHash    Hash of the DKIM RSA public key as published in DNS TXT (algorithm per impl).
    function isKeyHashValid(bytes32 domainHash, bytes32 keyHash) external view returns (bool);
}
