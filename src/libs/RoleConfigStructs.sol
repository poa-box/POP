// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title RoleConfigStructs
 * @notice Deploy-time description of an org's access shape, shared by OrgDeployer and the factories.
 * @dev Access v2: a role is a ROLE SUBJECT on the org's MembershipAuthority — there is no Hats tree,
 *      so the v1 hierarchy / eligibility-default / Hats-native (maxSupply, mutable) knobs are gone.
 *      What survives is what the authority actually stores: name/metadata, the per-subject default
 *      verdict, the member cap, and the vouch attestor.
 */
library RoleConfigStructs {
    /// @notice Vouch attestor for a role subject: `quorum` vouches from members of `voucherRoleIndex`
    ///         make a user eligible (ALLOW at the attestor tier; an explicit BAN still wins).
    struct RoleVouchingConfig {
        bool enabled;
        uint32 quorum;
        uint256 voucherRoleIndex; // index into the roles array
    }

    /// @notice Deploy-time membership. Seeded members get a governance GRANT rule in the same batch,
    ///         so every seeded membership carries an eligibility source.
    struct RoleDistributionConfig {
        bool mintToDeployer;
        address[] additionalWearers;
    }

    /// @notice One ROLE subject.
    struct RoleConfig {
        string name;
        string image; // IPFS hash or URI (subgraph metadata)
        bytes32 metadataCID; // IPFS CID of the extended role metadata JSON
        bool canVote; // included in the HybridVoting default class electorate
        bool open; // true = default-ALLOW (anyone may claim); false = deny-by-default (titled role)
        uint32 maxMembers; // 0 = unlimited
        RoleVouchingConfig vouching;
        RoleDistributionConfig distribution;
    }

    /// @notice One GROUP subject: membership is derived from its member roles (no acceptance of its
    ///         own, no cap). Groups are what restricted polls and manager delegation point at
    ///         ("Only Executives" = the Executives group subject).
    struct GroupConfig {
        string name;
        uint256[] memberRoleIndices; // indices into the roles array
    }
}
