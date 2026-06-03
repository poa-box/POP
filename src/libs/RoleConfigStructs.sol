// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title RoleConfigStructs
 * @notice Shared struct definitions for role configuration
 * @dev Used across OrgDeployer, GovernanceFactory, and HatsTreeSetup to avoid duplication
 *      and eliminate the need for type conversion functions
 */
library RoleConfigStructs {
    /// @notice Vouching configuration for a role
    /// @dev Allows roles to require vouches before claiming/minting
    struct RoleVouchingConfig {
        bool enabled; // Enable vouching for this role
        uint32 quorum; // Number of vouches required
        uint256 voucherRoleIndex; // Index of role that can vouch (in roles array)
        bool combineWithHierarchy; // Allow child hats to vouch too
    }

    /// @notice Default eligibility settings for a role
    /// @dev Controls whether new wearers are eligible/in good standing by default
    struct RoleEligibilityDefaults {
        bool eligible; // Default eligibility status
        bool standing; // Default standing status
    }

    /// @notice Hierarchy configuration for a role
    /// @dev Controls the parent-child relationship in the Hats tree
    struct RoleHierarchyConfig {
        uint256 adminRoleIndex; // Index of parent/admin role (type(uint256).max = use ELIGIBILITY_ADMIN or auto)
    }

    /// @notice Initial distribution configuration for a role
    /// @dev Controls who gets the role minted to them initially
    struct RoleDistributionConfig {
        bool mintToDeployer; // Mint to deployer address
        address[] additionalWearers; // Additional addresses to mint to
    }

    /// @notice Hat-specific configuration from Hats Protocol
    /// @dev Controls Hats Protocol native features
    struct HatConfig {
        uint32 maxSupply; // Maximum number of wearers (0 = unlimited, default: type(uint32).max)
        bool mutableHat; // Whether hat properties can be changed after creation (default: true)
    }

    /// @notice Complete configuration for a single role
    /// @dev Encompasses all aspects of role setup: metadata, hierarchy, vouching, distribution
    struct RoleConfig {
        string name; // Role name (e.g., "MEMBER", "ADMIN")
        string image; // IPFS hash or URI for role image
        bytes32 metadataCID; // IPFS CID for extended role metadata JSON
        bool canVote; // Whether this role can participate in voting
        RoleVouchingConfig vouching; // Vouching configuration
        RoleEligibilityDefaults defaults; // Default eligibility settings
        RoleHierarchyConfig hierarchy; // Parent-child relationship
        RoleDistributionConfig distribution; // Initial hat distribution
        HatConfig hatConfig; // Hats Protocol configuration
    }

    /// @notice Configuration for a single capability hat
    /// @dev Capability hats are atomic permission units; one per gated action in any contract.
    ///      Created as children of ELIGIBILITY_ADMIN during org deployment.
    struct CapabilityHatConfig {
        string name; // Capability name (e.g., "task.create", "vote.executive")
        string image; // IPFS hash or URI for capability hat image
        bytes32 metadataCID; // IPFS CID for extended metadata
        uint32 maxSupply; // Maximum wearers (0 = unlimited, default: type(uint32).max)
    }

    /// @notice Configuration for a role → capability bundle
    /// @dev When the role hat at `roleIndex` is granted via RoleBundleHatter.mintRole,
    ///      every capability hat at the indices listed in `capabilityHatIndices` is also minted.
    ///      "Permission sets" in the UI map 1:1 to these bundles.
    struct RoleBundleConfig {
        uint256 roleIndex; // Index into the roles[] array
        uint256[] capabilityHatIndices; // Indices into the capabilityHats[] array
    }
}
