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
    /// @dev Edit a task's title / metadataHash after it has been claimed or submitted.
    uint8 internal constant EDIT_META = 1 << 6;
    /// @dev Edit a task's payout / bounty fields (and metadata) after it has been claimed or submitted.
    ///      Strict superset of EDIT_META.
    uint8 internal constant EDIT_FULL = 1 << 7;
    // NOTE: uint8 is now saturated. Adding a 9th flag requires widening the value type of
    //       TaskManager.Layout.rolePermGlobal / rolePermProj and bumping the RolePermSet /
    //       ProjectRolePermSet event ABIs — a Layout-breaking change plus a subgraph v2.

    function has(uint8 mask, uint8 flag) internal pure returns (bool) {
        return mask & flag != 0;
    }
}
