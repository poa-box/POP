// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {IEligibilityModule, IToggleModule} from "./interfaces/IHatsModules.sol";
import {OrgRegistry} from "./OrgRegistry.sol";
import {RoleConfigStructs} from "./libs/RoleConfigStructs.sol";

interface IUniversalAccountRegistry {
    function getUsername(address account) external view returns (string memory);
    function registerAccountBySig(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external;
}

/**
 * @title HatsTreeSetup
 * @notice Temporary contract for setting up Hats Protocol trees
 * @dev This contract is deployed temporarily to handle all Hats operations and reduce Deployer size
 */
contract HatsTreeSetup {
    /*════════════════  CONSTANTS  ════════════════*/

    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    /*════════════════  SETUP STRUCTS  ════════════════*/

    struct SetupResult {
        uint256 topHatId;
        uint256[] roleHatIds;
        uint256[] capabilityHatIds;
        address eligibilityModule;
        address toggleModule;
    }

    struct SetupParams {
        IHats hats;
        OrgRegistry orgRegistry;
        bytes32 orgId;
        address eligibilityModule;
        address toggleModule;
        address roleBundleHatter; // Per-org RoleBundleHatter (bundle config target)
        address deployer;
        address deployerAddress; // Address to receive ADMIN hat
        address executor;
        address accountRegistry; // UniversalAccountRegistry for username registration
        string orgName;
        string deployerUsername; // Optional username for deployer (empty string = skip registration)
        uint256 regDeadline; // EIP-712 signature deadline (0 = skip registration)
        uint256 regNonce; // User's current nonce on the registry
        bytes regSignature; // User's EIP-712 ECDSA signature for username registration
        RoleConfigStructs.RoleConfig[] roles; // Complete role configuration
        RoleConfigStructs.CapabilityHatConfig[] capabilityHats; // Capability hats (created under ELIGIBILITY_ADMIN)
        RoleConfigStructs.RoleBundleConfig[] roleBundles; // Role → capability index bundles
    }

    /**
     * @notice Sets up a complete Hats tree for an organization with custom hierarchy
     * @dev This function handles arbitrary tree structures, not just linear hierarchies
     * @dev Deployer must transfer superAdmin rights to this contract before calling
     * @param params Complete setup parameters including role configurations
     * @return result Setup result containing topHat, roleHatIds, and module addresses
     */
    function setupHatsTree(SetupParams memory params) external returns (SetupResult memory result) {
        // Register deployer username if requested (requires non-empty username AND valid signature data)
        if (
            params.accountRegistry != address(0) && bytes(params.deployerUsername).length > 0
                && params.regSignature.length > 0
        ) {
            IUniversalAccountRegistry registry = IUniversalAccountRegistry(params.accountRegistry);
            if (bytes(registry.getUsername(params.deployerAddress)).length == 0) {
                registry.registerAccountBySig(
                    params.deployerAddress,
                    params.deployerUsername,
                    params.regDeadline,
                    params.regNonce,
                    params.regSignature
                );
            }
        }

        result.eligibilityModule = params.eligibilityModule;
        result.toggleModule = params.toggleModule;

        // Configure module relationships
        IEligibilityModule(params.eligibilityModule).setToggleModule(params.toggleModule);
        IToggleModule(params.toggleModule).setEligibilityModule(params.eligibilityModule);

        // Create top hat - mint to this contract so it can create child hats
        result.topHatId = params.hats.mintTopHat(address(this), string(abi.encodePacked("ipfs://", params.orgName)), "");
        IEligibilityModule(params.eligibilityModule).setWearerEligibility(address(this), result.topHatId, true, true);
        IToggleModule(params.toggleModule).setHatStatus(result.topHatId, true);

        // Create eligibility admin hat - this hat can mint any role
        uint256 eligibilityAdminHatId = params.hats
            .createHat(
                result.topHatId,
                "ELIGIBILITY_ADMIN",
                1,
                params.eligibilityModule,
                params.toggleModule,
                true,
                "ELIGIBILITY_ADMIN"
            );
        IEligibilityModule(params.eligibilityModule)
            .setWearerEligibility(params.eligibilityModule, eligibilityAdminHatId, true, true);
        IToggleModule(params.toggleModule).setHatStatus(eligibilityAdminHatId, true);
        params.hats.mintHat(eligibilityAdminHatId, params.eligibilityModule);
        IEligibilityModule(params.eligibilityModule).setEligibilityModuleAdminHat(eligibilityAdminHatId);
        // Register hat creation for subgraph indexing
        IEligibilityModule(params.eligibilityModule)
            .registerHatCreation(eligibilityAdminHatId, result.topHatId, true, true);

        // Create role hats sequentially to properly handle hierarchies
        uint256 len = params.roles.length;
        result.roleHatIds = new uint256[](len);

        // Arrays for batch registration (collected during hat creation)
        uint256[] memory regHatIds = new uint256[](len);
        uint256[] memory regParentHatIds = new uint256[](len);
        bool[] memory regDefaultEligibles = new bool[](len);
        bool[] memory regDefaultStandings = new bool[](len);
        string[] memory regNames = new string[](len);
        bytes32[] memory regMetadataCIDs = new bytes32[](len);

        // Multi-pass: resolve dependencies and create hats in correct order
        bool[] memory created = new bool[](len);
        uint256 createdCount = 0;

        while (createdCount < len) {
            uint256 passCreatedCount = 0;

            for (uint256 i = 0; i < len; i++) {
                if (created[i]) continue;

                RoleConfigStructs.RoleConfig memory role = params.roles[i];

                // Determine admin hat ID
                uint256 adminHatId;
                bool canCreate = false;

                if (role.hierarchy.adminRoleIndex == type(uint256).max) {
                    adminHatId = eligibilityAdminHatId;
                    canCreate = true;
                } else if (created[role.hierarchy.adminRoleIndex]) {
                    adminHatId = result.roleHatIds[role.hierarchy.adminRoleIndex];
                    canCreate = true;
                }

                if (canCreate) {
                    // Create hat with configuration
                    uint32 maxSupply = role.hatConfig.maxSupply == 0 ? type(uint32).max : role.hatConfig.maxSupply;
                    string memory details = _formatHatDetails(role.name, role.metadataCID);
                    uint256 newHatId = params.hats
                        .createHat(
                            adminHatId,
                            details,
                            maxSupply,
                            params.eligibilityModule,
                            params.toggleModule,
                            role.hatConfig.mutableHat,
                            role.image
                        );
                    result.roleHatIds[i] = newHatId;

                    // Collect registration data for batch call later
                    regHatIds[i] = newHatId;
                    regParentHatIds[i] = adminHatId;
                    regDefaultEligibles[i] = role.defaults.eligible;
                    regDefaultStandings[i] = role.defaults.standing;
                    regNames[i] = role.name;
                    regMetadataCIDs[i] = role.metadataCID;

                    created[i] = true;
                    createdCount++;
                    passCreatedCount++;
                }
            }

            // Circular dependency check
            if (passCreatedCount == 0 && createdCount < len) {
                revert("Circular dependency in role hierarchy");
            }
        }

        // Batch register all hat creations with metadata for subgraph indexing (replaces N individual calls)
        IEligibilityModule(params.eligibilityModule)
            .batchRegisterHatCreationWithMetadata(
                regHatIds, regParentHatIds, regDefaultEligibles, regDefaultStandings, regNames, regMetadataCIDs
            );

        // Step 5: Collect all eligibility and toggle operations for batch execution
        // Count total eligibility entries needed: deployer (only if minting) + additional wearers
        uint256 eligibilityCount = 0;
        for (uint256 i = 0; i < len; i++) {
            // Deployer only eligible if they're receiving the hat (matches minting conditions)
            if (params.roles[i].canVote && params.roles[i].distribution.mintToDeployer) {
                eligibilityCount += 1;
            }
            eligibilityCount += params.roles[i].distribution.additionalWearers.length;
        }

        // Build arrays for batch eligibility call
        address[] memory eligWearers = new address[](eligibilityCount);
        uint256[] memory eligHatIds = new uint256[](eligibilityCount);
        uint256 eligIndex = 0;

        // Build arrays for batch toggle call
        uint256[] memory toggleHatIds = new uint256[](len);
        bool[] memory toggleActives = new bool[](len);

        // Build arrays for batch default eligibility call
        uint256[] memory defaultHatIds = new uint256[](len);
        bool[] memory defaultEligibles = new bool[](len);
        bool[] memory defaultStandings = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 hatId = result.roleHatIds[i];
            RoleConfigStructs.RoleConfig memory role = params.roles[i];

            // Deployer only eligible if they're receiving the hat (matches minting conditions)
            if (role.canVote && role.distribution.mintToDeployer) {
                eligWearers[eligIndex] = params.deployerAddress;
                eligHatIds[eligIndex] = hatId;
                eligIndex++;
            }

            // Collect additional wearers
            for (uint256 j = 0; j < role.distribution.additionalWearers.length; j++) {
                eligWearers[eligIndex] = role.distribution.additionalWearers[j];
                eligHatIds[eligIndex] = hatId;
                eligIndex++;
            }

            // Collect toggle status
            toggleHatIds[i] = hatId;
            toggleActives[i] = true;

            // Collect default eligibility
            defaultHatIds[i] = hatId;
            defaultEligibles[i] = role.defaults.eligible;
            defaultStandings[i] = role.defaults.standing;
        }

        // Execute batch operations (replaces N individual calls with 3 batch calls)
        IEligibilityModule(params.eligibilityModule)
            .batchSetWearerEligibilityMultiHat(eligWearers, eligHatIds, true, true);
        IToggleModule(params.toggleModule).batchSetHatStatus(toggleHatIds, toggleActives);
        IEligibilityModule(params.eligibilityModule)
            .batchSetDefaultEligibility(defaultHatIds, defaultEligibles, defaultStandings);

        // Step 6: Collect all minting operations for batch execution
        uint256 mintCount = 0;
        for (uint256 i = 0; i < len; i++) {
            RoleConfigStructs.RoleConfig memory role = params.roles[i];
            if (!role.canVote) continue;

            if (role.distribution.mintToDeployer) mintCount++;
            mintCount += role.distribution.additionalWearers.length;
        }

        if (mintCount > 0) {
            uint256[] memory hatIdsToMint = new uint256[](mintCount);
            address[] memory wearersToMint = new address[](mintCount);
            uint256 mintIndex = 0;

            for (uint256 i = 0; i < len; i++) {
                RoleConfigStructs.RoleConfig memory role = params.roles[i];
                if (!role.canVote) continue;

                uint256 hatId = result.roleHatIds[i];

                if (role.distribution.mintToDeployer) {
                    hatIdsToMint[mintIndex] = hatId;
                    wearersToMint[mintIndex] = params.deployerAddress;
                    mintIndex++;
                }

                for (uint256 j = 0; j < role.distribution.additionalWearers.length; j++) {
                    hatIdsToMint[mintIndex] = hatId;
                    wearersToMint[mintIndex] = role.distribution.additionalWearers[j];
                    mintIndex++;
                }
            }

            // Step 7: Batch mint all hats via single call (replaces N mintHatToAddress calls)
            IEligibilityModule(params.eligibilityModule).batchMintHats(hatIdsToMint, wearersToMint);
        }

        // Create capability hats under ELIGIBILITY_ADMIN. They're not minted to anyone here —
        // RoleBundleHatter.setBundle is called by OrgDeployer (which is the bundle hatter's
        // deployer) AFTER this returns, then mintRole picks them up on demand.
        result.capabilityHatIds = _createCapabilityHats(params, eligibilityAdminHatId);

        // Transfer top hat to executor
        params.hats.transferHat(result.topHatId, address(this), params.executor);

        // Set default eligibility for top hat
        IEligibilityModule(params.eligibilityModule).setDefaultEligibility(result.topHatId, true, true);

        // Transfer module admin rights to executor
        IEligibilityModule(params.eligibilityModule).transferSuperAdmin(params.executor);
        IToggleModule(params.toggleModule).transferAdmin(params.executor);

        return result;
    }

    /*════════════════  CAPABILITY HATS + BUNDLES  ════════════════*/

    /// @dev Creates each `CapabilityHatConfig` as a child of `eligibilityAdminHatId`, then
    ///      hands off to `_registerCapabilityHats` for the batch registration/toggle/eligibility
    ///      calls. Split into two functions to avoid stack-too-deep.
    function _createCapabilityHats(SetupParams memory params, uint256 eligibilityAdminHatId)
        internal
        returns (uint256[] memory capabilityHatIds)
    {
        uint256 capLen = params.capabilityHats.length;
        capabilityHatIds = new uint256[](capLen);
        if (capLen == 0) return capabilityHatIds;

        for (uint256 i; i < capLen; ++i) {
            RoleConfigStructs.CapabilityHatConfig memory cap = params.capabilityHats[i];
            uint32 maxSupply = cap.maxSupply == 0 ? type(uint32).max : cap.maxSupply;
            capabilityHatIds[i] = params.hats
                .createHat(
                    eligibilityAdminHatId,
                    _formatHatDetails(cap.name, cap.metadataCID),
                    maxSupply,
                    params.eligibilityModule,
                    params.toggleModule,
                    true, // mutable so admins can adjust metadata later
                    cap.image
                );
        }

        _registerCapabilityHats(params, eligibilityAdminHatId, capabilityHatIds);
    }

    /// @dev Batch-registers capability hats with the eligibility module + toggle, and seeds
    ///      default-eligible/in-good-standing for every capability hat (the gate IS the hat).
    function _registerCapabilityHats(
        SetupParams memory params,
        uint256 eligibilityAdminHatId,
        uint256[] memory capabilityHatIds
    ) internal {
        uint256 capLen = capabilityHatIds.length;
        uint256[] memory parents = new uint256[](capLen);
        bool[] memory trues = new bool[](capLen);
        string[] memory names = new string[](capLen);
        bytes32[] memory cids = new bytes32[](capLen);
        for (uint256 i; i < capLen; ++i) {
            parents[i] = eligibilityAdminHatId;
            trues[i] = true;
            names[i] = params.capabilityHats[i].name;
            cids[i] = params.capabilityHats[i].metadataCID;
        }
        IEligibilityModule(params.eligibilityModule)
            .batchRegisterHatCreationWithMetadata(capabilityHatIds, parents, trues, trues, names, cids);
        IToggleModule(params.toggleModule).batchSetHatStatus(capabilityHatIds, trues);
        IEligibilityModule(params.eligibilityModule).batchSetDefaultEligibility(capabilityHatIds, trues, trues);
    }

    /*════════════════  INTERNAL HELPERS  ════════════════*/

    /**
     * @notice Format hat details string - uses CID if provided, otherwise name
     * @param name The role name (fallback if no CID)
     * @param metadataCID The IPFS CID for extended metadata (bytes32(0) if none)
     * @return The formatted details string
     */
    function _formatHatDetails(string memory name, bytes32 metadataCID) internal pure returns (string memory) {
        if (metadataCID == bytes32(0)) {
            return name;
        }
        return _bytes32ToHexString(metadataCID);
    }

    /**
     * @notice Convert bytes32 to hex string with 0x prefix
     * @param value The bytes32 value to convert
     * @return The hex string representation
     */
    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory buffer = new bytes(66); // 2 for "0x" + 64 for hex chars
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            buffer[2 + i * 2] = HEX_DIGITS[uint8(value[i] >> 4)];
            buffer[3 + i * 2] = HEX_DIGITS[uint8(value[i] & 0x0f)];
        }
        return string(buffer);
    }
}
