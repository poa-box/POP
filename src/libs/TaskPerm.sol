// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @dev Bit-mask helpers for granular task permissions.
 * Flags may be OR-combined (e.g. CREATE | ASSIGN).
 */
library TaskPerm {
    uint8 internal constant CREATE = 1 << 0;
    uint8 internal constant CLAIM = 1 << 1;
    uint8 internal constant REVIEW = 1 << 2;
    uint8 internal constant ASSIGN = 1 << 3;
    uint8 internal constant SELF_REVIEW = 1 << 4;
    uint8 internal constant BUDGET = 1 << 5;

    function has(uint8 mask, uint8 flag) internal pure returns (bool) {
        return mask & flag != 0;
    }
}
