// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @title AccessV2Ids — subject-id namespace arithmetic (§1). Pure, no storage.
library AccessV2Ids {
    /// @notice Hats-namespace floor: every real Hats id embeds a nonzero tophat domain in bits
    ///         224–255 (Hats.sol:123 `uint256(++lastTopHatId) << 224`), so every legacy id >= 2^224.
    uint256 internal constant HATS_NAMESPACE_FLOOR = 1 << 224; // 2^224

    /// @notice New v2 id shape: `(uint256(uint160(authority)) << 64) | localSeq`. The authority
    ///         address occupies bits 64..223; the top 32 bits are zero => every new id < 2^224,
    ///         disjoint from all Hats ids, globally unique (address uniqueness), self-routing.
    uint256 internal constant AUTHORITY_ADDR_SHIFT = 64;

    /// @notice Compose a new subject id owned by `authority` with local sequence `localSeq`.
    function newSubjectId(address authority, uint64 localSeq) internal pure returns (uint256) {
        return (uint256(uint160(authority)) << AUTHORITY_ADDR_SHIFT) | uint256(localSeq);
    }

    /// @notice Extract the embedded authority address from a v2-namespace id (bits 64..223).
    function embeddedAuthority(uint256 id) internal pure returns (address) {
        return address(uint160(id >> AUTHORITY_ADDR_SHIFT));
    }

    /// @notice True for the legacy/Hats namespace (id >= 2^224).
    function isLegacyNamespace(uint256 id) internal pure returns (bool) {
        return id >= HATS_NAMESPACE_FLOOR;
    }
}
