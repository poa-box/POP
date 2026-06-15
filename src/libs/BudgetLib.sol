// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title BudgetLib
 * @notice Library for budget management operations
 * @dev Reduces bytecode by extracting common budget logic into reusable functions
 */
library BudgetLib {
    /* ─────────── Errors ─────────── */
    error BudgetExceeded();
    error SpentUnderflow();

    /* ─────────── Constants ─────────── */
    /// @notice Sentinel value meaning "unlimited budget" (no cap enforced).
    /// cap = 0 means DISABLED (no spending allowed); cap = UNLIMITED means no limit.
    uint128 internal constant UNLIMITED = type(uint128).max;

    /* ─────────── Data Types ─────────── */
    struct Budget {
        uint128 cap; // 16 bytes  (0 = disabled, UNLIMITED = no limit, other = capped)
        uint128 spent; // 16 bytes (total 32 bytes)
    }

    /* ─────────── Core Functions ─────────── */

    /**
     * @notice Add spent amount to budget with cap checking
     * @param budget The budget struct to modify
     * @param delta Amount to add to spent
     * @param cap The budget cap (0 = disabled, UNLIMITED = no limit)
     */
    function addSpent(Budget storage budget, uint256 delta, uint256 cap) internal {
        uint256 newSpent = budget.spent + delta;
        if (newSpent > type(uint128).max) revert BudgetExceeded();
        if (cap != UNLIMITED && newSpent > cap) revert BudgetExceeded();
        budget.spent = uint128(newSpent);
    }

    /**
     * @notice Add spent amount to budget using budget's own cap
     * @param budget The budget struct to modify
     * @param delta Amount to add to spent
     */
    function addSpent(Budget storage budget, uint256 delta) internal {
        addSpent(budget, delta, budget.cap);
    }

    /**
     * @notice Subtract spent amount from budget with underflow protection
     * @param budget The budget struct to modify
     * @param delta Amount to subtract from spent
     */
    function subtractSpent(Budget storage budget, uint256 delta) internal {
        if (budget.spent < delta) revert SpentUnderflow();
        unchecked {
            budget.spent -= uint128(delta);
        }
    }
}
