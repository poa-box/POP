// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/// @title PaymasterGraceLib
/// @author POA Engineering
/// @notice Grace period calculations and solidarity tier matching for PaymasterHub
/// @dev All functions are internal (inlined at compile time) for zero gas overhead
library PaymasterGraceLib {
    /// @notice Check if an organization is currently in its initial grace period
    /// @param registeredAt Timestamp when the org was registered (uint40)
    /// @param initialGraceDays Configured grace period duration in days (uint32)
    /// @return True if the current block is before the grace period end
    function isInGracePeriod(uint40 registeredAt, uint32 initialGraceDays) internal view returns (bool) {
        return block.timestamp < uint256(registeredAt) + (uint256(initialGraceDays) * 1 days);
    }

    /// @notice Calculate solidarity match allowance based on deposit tier
    /// @dev Progressive tier system with declining marginal match rates:
    ///      - Tier 1: deposit <= 1x min -> 2x match (total 3x)
    ///      - Tier 2: deposit <= 2x min -> 3x match total (total 5x)
    ///      - Tier 3: deposit < 5x min  -> capped at 3x min match
    ///      - Tier 4: deposit >= 5x min -> no match (self-funded)
    /// @param deposited Current available deposit balance
    /// @param minDeposit Minimum deposit requirement from grace period config
    /// @return matchAllowance Maximum solidarity usage per 90-day period
    function calculateMatchAllowance(uint256 deposited, uint256 minDeposit) internal pure returns (uint256) {
        if (minDeposit == 0 || deposited < minDeposit) {
            return 0;
        }
        // Tier 1: deposit <= 1x minimum -> 2x match
        if (deposited <= minDeposit) {
            return deposited * 2;
        }
        // Tier 2: deposit <= 2x minimum -> first tier at 2x, remainder at 1x
        if (deposited <= minDeposit * 2) {
            uint256 firstTierMatch = minDeposit * 2;
            uint256 secondTierMatch = deposited - minDeposit;
            return firstTierMatch + secondTierMatch;
        }
        // Tier 3: deposit < 5x minimum -> capped match from first two tiers
        if (deposited < minDeposit * 5) {
            uint256 firstTierMatch = minDeposit * 2;
            uint256 secondTierMatch = minDeposit;
            return firstTierMatch + secondTierMatch;
        }
        // Tier 4: >= 5x minimum -> self-sufficient, no match
        return 0;
    }
}
