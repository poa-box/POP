// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

/**
 * @title HatManager
 * @notice Generic library for managing Hats Protocol permissions
 * @dev Storage-agnostic functions that work with any hat array structure
 */
library LegacyHatManager {
    /* ─────────── Events ─────────── */
    event HatToggled(uint256 indexed hatId, bool allowed);

    /* ─────────── Core Functions ─────────── */

    /**
     * @notice Add or remove a hat from an array
     * @param hatArray The array of hat IDs to modify
     * @param hatId The hat ID to add/remove
     * @param allowed Whether to add (true) or remove (false) the hat
     * @return modified Whether the array was actually modified
     */
    function setHatInArray(uint256[] storage hatArray, uint256 hatId, bool allowed) internal returns (bool modified) {
        uint256 existingIndex = findHatIndex(hatArray, hatId);
        bool exists = existingIndex != type(uint256).max;

        if (allowed && !exists) {
            // Add new hat
            hatArray.push(hatId);
            emit HatToggled(hatId, true);
            return true;
        } else if (!allowed && exists) {
            // Remove existing hat (swap with last element and pop)
            hatArray[existingIndex] = hatArray[hatArray.length - 1];
            hatArray.pop();
            emit HatToggled(hatId, false);
            return true;
        }

        return false; // No change needed
    }

    /**
     * @notice Check if a user wears any hat from an array
     * @param hats The Hats Protocol contract
     * @param hatArray Array of hat IDs to check
     * @param user The user address to check
     * @return bool True if user wears any hat from the array
     */
    function hasAnyHat(IHats hats, uint256[] storage hatArray, address user) internal view returns (bool) {
        uint256 len = hatArray.length;
        if (len == 0) return false;
        if (len == 1) return hats.isWearerOfHat(user, hatArray[0]);

        // Batch check for efficiency
        return _checkHatsBatch(hats, hatArray, user);
    }

    /**
     * @notice Check if a specific hat is in an array
     * @param hatArray Array of hat IDs to search
     * @param hatId The hat ID to find
     * @return bool True if the hat is in the array
     */
    function isHatInArray(uint256[] storage hatArray, uint256 hatId) internal view returns (bool) {
        return findHatIndex(hatArray, hatId) != type(uint256).max;
    }

    /**
     * @notice Find the index of a hat in an array
     * @param hatArray Array of hat IDs to search
     * @param hatId The hat ID to find
     * @return uint256 Index of the hat, or type(uint256).max if not found
     */
    function findHatIndex(uint256[] storage hatArray, uint256 hatId) internal view returns (uint256) {
        for (uint256 i; i < hatArray.length;) {
            if (hatArray[i] == hatId) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    /**
     * @notice Get a copy of the hat array
     * @param hatArray Array of hat IDs
     * @return uint256[] Memory copy of the array
     */
    function getHatArray(uint256[] storage hatArray) internal view returns (uint256[] memory) {
        return hatArray;
    }

    /**
     * @notice Get the count of hats in an array
     * @param hatArray Array of hat IDs
     * @return uint256 Number of hats in the array
     */
    function getHatCount(uint256[] storage hatArray) internal view returns (uint256) {
        return hatArray.length;
    }

    /**
     * @notice Remove all hats from an array
     * @param hatArray Array of hat IDs to clear
     * @return removedCount Number of hats that were removed
     */
    function clearHatArray(uint256[] storage hatArray) internal returns (uint256 removedCount) {
        removedCount = hatArray.length;
        // Clear the array by setting length to 0
        assembly {
            sstore(hatArray.slot, 0)
        }
        return removedCount;
    }

    /* ─────────── Internal Helpers ─────────── */

    /**
     * @dev Efficient batch checking using Hats Protocol's balanceOfBatch
     */
    function _checkHatsBatch(IHats hats, uint256[] storage hatArray, address user) private view returns (bool) {
        uint256 len = hatArray.length;

        // Build arrays for batch call
        address[] memory wearers = new address[](len);
        uint256[] memory hatIds = new uint256[](len);

        for (uint256 i; i < len;) {
            wearers[i] = user;
            hatIds[i] = hatArray[i];
            unchecked {
                ++i;
            }
        }

        // Single batch call to check all hats
        uint256[] memory balances = hats.balanceOfBatch(wearers, hatIds);

        // Check if any balance > 0
        for (uint256 i; i < len;) {
            if (balances[i] > 0) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }
}
