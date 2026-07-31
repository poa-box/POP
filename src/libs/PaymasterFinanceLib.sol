// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {PaymasterHubErrors} from "./PaymasterHubErrors.sol";
import {PaymasterGraceLib} from "./PaymasterGraceLib.sol";
import {PaymasterPostOpLib} from "./PaymasterPostOpLib.sol";

/// @title PaymasterFinanceLib
/// @author POA Engineering
/// @notice Delegatecall library holding PaymasterHub's solidarity-accounting hot paths:
///         the validation-time solidarity access check WITH per-org reservation (M-05), and
///         the two postOp reconciliation paths (`updateOrgFinancials`, `postOpFallback`).
/// @dev Moved out of PaymasterHub so the hub stays under the EIP-170 limit (24,576 B). These
///      are external library functions, so PaymasterHub invokes them via `delegatecall` and
///      they read/write the HUB's ERC-7201 storage. All slot constants and struct layouts MUST
///      stay byte-for-byte in sync with PaymasterHub.
///
///      M-05 (solidarity reservation): `checkSolidarityAccessAndReserve` now RESERVES the
///      solidarity a UserOp would draw by incrementing the org's `solidarityUsedThisPeriod` at
///      validation time — mirroring the budget (`_checkBudget`) and deposit (`_checkOrgBalance`)
///      reservation pattern. A second same-org grace/tier UserOp in the same bundle therefore
///      sees the inflated counter and is bounded by `maxSpendDuringGrace` / the tier allowance,
///      instead of both validating against a stale value and overspending. Reservation is
///      PER-ORG (not the shared global `solidarity.balance`), so it introduces no cross-org
///      contention. The reserved amount is threaded through postOp context and unreserved
///      before the actual draw is applied.
library PaymasterFinanceLib {
    // ── ERC-7201 storage locations (must match PaymasterHub exactly) ──
    bytes32 private constant ORGS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgs")) - 1));
    bytes32 private constant BUDGETS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.budgets")) - 1));
    bytes32 private constant FINANCIALS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.financials")) - 1));
    bytes32 private constant SOLIDARITY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.solidarity")) - 1));
    bytes32 private constant GRACEPERIOD_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.graceperiod")) - 1));

    // ── Storage structs (must match PaymasterHub exactly) ──
    struct OrgConfig {
        uint256 adminHatId;
        uint256 operatorHatId;
        bool paused;
        uint40 registeredAt;
        bool bannedFromSolidarity;
    }

    struct OrgFinancials {
        uint128 deposited;
        uint128 spent;
        uint128 solidarityUsedThisPeriod;
        uint32 periodStart;
    }

    struct SolidarityFund {
        uint128 balance;
        uint32 numActiveOrgs;
        uint16 feePercentageBps;
        bool distributionPaused;
    }

    struct GracePeriodConfig {
        uint32 initialGraceDays;
        uint128 maxSpendDuringGrace;
        uint128 minDepositRequired;
    }

    struct Budget {
        uint128 capPerEpoch;
        uint128 usedInEpoch;
        uint32 epochLen;
        uint32 epochStart;
    }

    // ── Events (re-declared so they emit from the hub's context; must match PaymasterHubErrors) ──
    event UsageIncreased(
        bytes32 indexed orgId, bytes32 subjectKey, uint256 delta, uint128 usedInEpoch, uint32 epochStart
    );
    event SolidarityFeeCollected(bytes32 indexed orgId, uint256 amount);
    event OrgSpendingRecorded(
        bytes32 indexed orgId, uint256 fromDeposits, uint256 fromSolidarity, uint256 solidarityFee
    );

    // ─────────────────────────────────────────────────────────────────────────
    // M-05 — Validation: solidarity access check + per-org reservation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Check solidarity access for an org and reserve the solidarity this op would draw.
    /// @dev Replaces the old view-only `_checkSolidarityAccess`. Same access rules, but it now
    ///      increments `org.solidarityUsedThisPeriod` by the reserved amount so a second same-org
    ///      op in the bundle cannot exceed the grace/tier allowance (M-05). The reservation is
    ///      reconciled (unreserved) in postOp before the actual draw is applied.
    /// @param orgId The organization identifier
    /// @param maxCost Maximum cost of the operation
    /// @return reservedSolidarity Amount of solidarity reserved (threaded to postOp; 0 when
    ///         distribution is paused or the op draws nothing from solidarity)
    function checkSolidarityAccessAndReserve(bytes32 orgId, uint256 maxCost)
        external
        returns (uint256 reservedSolidarity)
    {
        SolidarityFund storage solidarity = _solidarity();

        // If distribution is paused, orgs pay 100% from deposits — nothing to reserve.
        if (solidarity.distributionPaused) return 0;

        OrgConfig storage config = _orgs()[orgId];
        OrgFinancials storage org = _financials()[orgId];
        GracePeriodConfig storage grace = _grace();

        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        if (config.bannedFromSolidarity) revert PaymasterHubErrors.OrgIsBanned();

        bool inInitialGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        if (inInitialGrace && depositAvailable < grace.minDepositRequired) {
            // Grace subsidy: unfunded orgs draw up to maxSpendDuringGrace entirely from solidarity.
            if (org.solidarityUsedThisPeriod + maxCost > grace.maxSpendDuringGrace) {
                revert PaymasterHubErrors.GracePeriodSpendLimitReached();
            }
            if (solidarity.balance < maxCost) revert PaymasterHubErrors.InsufficientFunds();
            reservedSolidarity = maxCost;
        } else {
            // Tier-based matching for funded grace orgs AND all post-grace orgs.
            if (depositAvailable < grace.minDepositRequired) {
                revert PaymasterHubErrors.InsufficientDepositForSolidarity();
            }

            uint256 matchAllowance =
                PaymasterGraceLib.calculateMatchAllowance(depositAvailable, grace.minDepositRequired);
            uint256 solidarityRemaining =
                matchAllowance > org.solidarityUsedThisPeriod ? matchAllowance - org.solidarityUsedThisPeriod : 0;

            uint256 requiredSolidarity = maxCost > depositAvailable ? maxCost - depositAvailable : 0;
            if (requiredSolidarity > solidarityRemaining) {
                revert PaymasterHubErrors.SolidarityLimitExceeded();
            }
            if (solidarity.balance < requiredSolidarity) revert PaymasterHubErrors.InsufficientFunds();
            reservedSolidarity = requiredSolidarity;
        }

        // Reserve per-org for bundle safety (unreserved in postOp before the actual draw).
        if (reservedSolidarity > 0) {
            org.solidarityUsedThisPeriod += uint128(reservedSolidarity);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PostOp — regular org accounting (unreserve budget/deposit/solidarity, apply actual)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Regular postOp accounting: adjust budget, then apply the org financial split.
    /// @dev Combines the hub's `_updateUsage` + `_updateOrgFinancials`. Unreserves the solidarity
    ///      reservation made at validation (M-05) before computing the actual draw.
    function updateUsageAndFinancials(
        bytes32 orgId,
        bytes32 subjectKey,
        uint32 epochStart,
        uint256 actualGasCost,
        uint256 reservedBudget,
        uint256 reservedOrgBalance,
        uint256 reservedSolidarity
    ) external {
        // 1. Budget: replace reservation with actual.
        Budget storage budget = _budgets()[orgId][subjectKey];
        if (budget.epochStart == epochStart) {
            budget.usedInEpoch = PaymasterPostOpLib.adjustBudget(budget.usedInEpoch, reservedBudget, actualGasCost);
            emit UsageIncreased(orgId, subjectKey, actualGasCost, budget.usedInEpoch, epochStart);
        }

        // 2. Org financials.
        _applyFinancials(orgId, actualGasCost, reservedOrgBalance, reservedSolidarity);
    }

    /// @dev Mirrors the hub's `_updateOrgFinancials`, plus unreserving the M-05 solidarity reservation.
    function _applyFinancials(
        bytes32 orgId,
        uint256 actualGasCost,
        uint256 reservedOrgBalance,
        uint256 reservedSolidarity
    ) private {
        OrgConfig storage config = _orgs()[orgId];
        OrgFinancials storage org = _financials()[orgId];
        GracePeriodConfig storage grace = _grace();
        SolidarityFund storage solidarity = _solidarity();

        // Unreserve the org deposit reservation and the solidarity reservation (M-05) made at
        // validation. Saturating: in normal ERC-4337 flow postOp follows validation with no
        // interleaved deposit, so the counters always hold the reservation. The saturating floor
        // only guards the pathological case where a period reset (via depositForOrg) landed between
        // validation and postOp — it must never underflow-revert on the accounting path.
        org.spent = _sub(org.spent, reservedOrgBalance);
        org.solidarityUsedThisPeriod = _sub(org.solidarityUsedThisPeriod, reservedSolidarity);

        uint256 solidarityFee = (actualGasCost * uint256(solidarity.feePercentageBps)) / 10000;

        // Distribution paused: 100% from deposits, still collect the fee.
        if (solidarity.distributionPaused) {
            // L-30: never let the fee push spend past the available deposit — cap it.
            uint256 avail = org.deposited > org.spent ? org.deposited - org.spent : 0;
            uint256 charge = actualGasCost + solidarityFee;
            if (charge > avail) {
                // Actual cost is already covered by the reservation invariant; clamp only the fee.
                solidarityFee = avail > actualGasCost ? avail - actualGasCost : 0;
                charge = actualGasCost + solidarityFee;
            }
            org.spent += uint128(charge);
            solidarity.balance += uint128(solidarityFee);
            if (solidarityFee > 0) emit SolidarityFeeCollected(orgId, solidarityFee);
            return;
        }

        bool inInitialGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        uint256 fromDeposits = 0;
        uint256 fromSolidarity = 0;
        uint256 solidarityLiquidity = solidarity.balance;
        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        if (inInitialGrace && depositAvailable < grace.minDepositRequired) {
            // Grace subsidy: 100% from solidarity, no fee.
            if (solidarityLiquidity < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
            fromSolidarity = actualGasCost;
            solidarityFee = 0;
        } else {
            uint256 matchAllowance =
                PaymasterGraceLib.calculateMatchAllowance(depositAvailable, grace.minDepositRequired);
            uint256 solidarityRemaining =
                matchAllowance > org.solidarityUsedThisPeriod ? matchAllowance - org.solidarityUsedThisPeriod : 0;
            if (solidarityRemaining > solidarityLiquidity) {
                solidarityRemaining = solidarityLiquidity;
            }

            uint256 halfCost = actualGasCost / 2;
            fromDeposits = halfCost < depositAvailable ? halfCost : depositAvailable;
            fromSolidarity = halfCost < solidarityRemaining ? halfCost : solidarityRemaining;

            uint256 covered = fromDeposits + fromSolidarity;
            if (covered < actualGasCost) {
                uint256 shortfall = actualGasCost - covered;
                uint256 depositExtra = depositAvailable - fromDeposits;
                if (depositExtra > 0) {
                    uint256 additional = shortfall < depositExtra ? shortfall : depositExtra;
                    fromDeposits += additional;
                    shortfall -= additional;
                }
                if (shortfall > 0) {
                    uint256 solidarityExtra = solidarityRemaining - fromSolidarity;
                    if (solidarityExtra > 0) {
                        uint256 additional = shortfall < solidarityExtra ? shortfall : solidarityExtra;
                        fromSolidarity += additional;
                        shortfall -= additional;
                    }
                }
                if (shortfall > 0) revert PaymasterHubErrors.InsufficientFunds();
            }
        }

        org.spent += uint128(fromDeposits + solidarityFee);
        org.solidarityUsedThisPeriod += uint128(fromSolidarity);
        solidarity.balance -= uint128(fromSolidarity);
        solidarity.balance += uint128(solidarityFee);

        if (solidarityFee > 0) emit SolidarityFeeCollected(orgId, solidarityFee);
        emit OrgSpendingRecorded(orgId, fromDeposits, fromSolidarity, solidarityFee);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PostOp — fallback accounting (must not revert)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Fallback accounting when the first postOp call reverted (PostOpMode.postOpReverted).
    /// @dev Must not revert. Charges 100% from deposits where possible, absorbing the rest from
    ///      solidarity. Unreserves the budget, deposit, and M-05 solidarity reservations first.
    function postOpFallback(
        bytes32 orgId,
        bytes32 subjectKey,
        uint32 epochStart,
        uint256 actualGasCost,
        uint256 reservedBudget,
        uint256 reservedOrgBalance,
        uint256 reservedSolidarity
    ) external {
        Budget storage budget = _budgets()[orgId][subjectKey];
        if (budget.epochStart == epochStart) {
            budget.usedInEpoch = PaymasterPostOpLib.adjustBudget(budget.usedInEpoch, reservedBudget, actualGasCost);
            emit UsageIncreased(orgId, subjectKey, actualGasCost, budget.usedInEpoch, epochStart);
        }

        OrgFinancials storage org = _financials()[orgId];
        // Unreserve deposit and the M-05 solidarity reservation (saturating — this path MUST NOT revert).
        org.spent = _sub(org.spent, reservedOrgBalance);
        org.solidarityUsedThisPeriod = _sub(org.solidarityUsedThisPeriod, reservedSolidarity);

        SolidarityFund storage solidarity = _solidarity();
        GracePeriodConfig storage grace = _grace();
        OrgConfig storage config = _orgs()[orgId];
        bool inGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        // L-28: funded grace orgs still owe the solidarity fee (they self-fund; not circular).
        // Only genuinely UNFUNDED grace orgs (which draw the grace subsidy) skip the fee.
        bool unfundedGrace = inGrace && depositAvailable < grace.minDepositRequired;
        uint256 solidarityFee = unfundedGrace ? 0 : (actualGasCost * uint256(solidarity.feePercentageBps)) / 10000;

        uint256 fallbackFromDeposits;
        uint256 fallbackFromSolidarity;

        if (depositAvailable >= actualGasCost + solidarityFee) {
            org.spent += uint128(actualGasCost + solidarityFee);
            solidarity.balance += uint128(solidarityFee);
            fallbackFromDeposits = actualGasCost;
        } else if (depositAvailable > 0) {
            // L-30: cap the fee at whatever deposit remains after covering the actual cost.
            fallbackFromDeposits = depositAvailable < actualGasCost ? depositAvailable : actualGasCost;
            fallbackFromSolidarity = actualGasCost - fallbackFromDeposits;
            uint256 feeRoom = depositAvailable - fallbackFromDeposits;
            if (solidarityFee > feeRoom) solidarityFee = feeRoom;
            org.spent += uint128(fallbackFromDeposits + solidarityFee);
            (solidarity.balance,) = PaymasterPostOpLib.clampedDeduction(solidarity.balance, fallbackFromSolidarity);
            // L-32: increment solidarityUsedThisPeriod by the amount actually drawn.
            org.solidarityUsedThisPeriod += uint128(fallbackFromSolidarity);
            solidarity.balance += uint128(solidarityFee);
        } else {
            // Unfunded: 100% solidarity, no fee.
            uint128 deducted;
            (solidarity.balance, deducted) = PaymasterPostOpLib.clampedDeduction(solidarity.balance, actualGasCost);
            // L-32: increment by the actual deducted amount (clamped), not the requested cost.
            org.solidarityUsedThisPeriod += deducted;
            fallbackFromSolidarity = actualGasCost;
            solidarityFee = 0;
        }

        if (solidarityFee > 0) emit SolidarityFeeCollected(orgId, solidarityFee);
        emit OrgSpendingRecorded(orgId, fallbackFromDeposits, fallbackFromSolidarity, solidarityFee);
    }

    /// @dev Saturating uint128 subtraction: returns a - b, or 0 if b > a. Used to unreserve
    ///      validation-time reservations without ever underflow-reverting on the accounting path.
    function _sub(uint128 a, uint256 b) private pure returns (uint128) {
        return uint256(a) > b ? a - uint128(b) : 0;
    }

    // ── Storage accessors ──
    function _orgs() private pure returns (mapping(bytes32 => OrgConfig) storage $) {
        bytes32 slot = ORGS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _budgets() private pure returns (mapping(bytes32 => mapping(bytes32 => Budget)) storage $) {
        bytes32 slot = BUDGETS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _financials() private pure returns (mapping(bytes32 => OrgFinancials) storage $) {
        bytes32 slot = FINANCIALS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _solidarity() private pure returns (SolidarityFund storage $) {
        bytes32 slot = SOLIDARITY_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _grace() private pure returns (GracePeriodConfig storage $) {
        bytes32 slot = GRACEPERIOD_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }
}
