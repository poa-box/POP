// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {PaymasterHubErrors} from "./PaymasterHubErrors.sol";
import {PaymasterCalldataLib} from "./PaymasterCalldataLib.sol";
import {PaymasterGraceLib} from "./PaymasterGraceLib.sol";

/**
 * @title PaymasterSponsorshipLib
 * @author POA Engineering
 * @notice The solidarity-funded sponsorship flows (POA onboarding + free org deploy): validation-time
 *         eligibility/rate-limit checks and postOp usage settlement. Extracted from PaymasterHub as an
 *         EXTERNAL (delegatecall) library purely to reclaim EIP-170 bytecode headroom — the hub was at
 *         the 24,576-byte ceiling. Mirrors the HybridVoting core/config/proposals pattern.
 *
 * @dev STORAGE: operates on the HUB's own ERC-7201 namespaced slots via delegatecall — the struct
 *      definitions and slot derivations below MUST stay byte-identical to PaymasterHub's. Never
 *      reorder/remove fields (append-only, same rule as the hub). Events emitted here surface with the
 *      hub as `address` (delegatecall), so subgraph indexing is unchanged.
 */
library PaymasterSponsorshipLib {
    // ============ Constants (mirror PaymasterHub) ============
    uint8 private constant SUBJECT_TYPE_POA_ONBOARDING = 0x03;
    uint8 private constant SUBJECT_TYPE_ORG_DEPLOY = 0x04;

    // ============ Storage structs (byte-identical mirrors of PaymasterHub's) ============
    struct OnboardingConfig {
        uint128 maxGasPerCreation;
        uint128 dailyCreationLimit;
        uint128 attemptsToday;
        uint32 currentDay;
        bool enabled;
        address accountRegistry;
        uint8 maxOnboardingsPerAccount; // appended field — packs with accountRegistry
    }

    struct OrgDeployConfig {
        uint128 maxGasPerDeploy;
        uint128 dailyDeployLimit;
        uint128 attemptsToday;
        uint32 currentDay;
        uint8 maxDeploysPerAccount;
        bool enabled;
        address orgDeployer;
    }

    struct SolidarityFund {
        uint128 balance;
        uint32 numActiveOrgs;
        uint16 feePercentageBps;
        bool distributionPaused;
    }

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

    struct GracePeriodConfig {
        uint32 initialGraceDays;
        uint128 maxSpendDuringGrace;
        uint128 minDepositRequired;
    }

    // ============ ERC-7201 slots (identical derivations to PaymasterHub) ============
    bytes32 private constant ORGS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgs")) - 1));
    bytes32 private constant FINANCIALS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.financials")) - 1));
    bytes32 private constant GRACEPERIOD_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.graceperiod")) - 1));
    bytes32 private constant SOLIDARITY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.solidarity")) - 1));
    bytes32 private constant ONBOARDING_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.onboarding")) - 1));
    bytes32 private constant ORG_DEPLOY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgdeploy")) - 1));
    bytes32 private constant ORG_DEPLOY_COUNTS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgdeploy.counts")) - 1));
    bytes32 private constant ONBOARDING_COUNTS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.onboarding.counts")) - 1));

    function _getSolidarityStorage() private pure returns (SolidarityFund storage $) {
        bytes32 slot = SOLIDARITY_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getOrgsStorage() private pure returns (mapping(bytes32 => OrgConfig) storage $) {
        bytes32 slot = ORGS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getFinancialsStorage() private pure returns (mapping(bytes32 => OrgFinancials) storage $) {
        bytes32 slot = FINANCIALS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getGracePeriodStorage() private pure returns (GracePeriodConfig storage $) {
        bytes32 slot = GRACEPERIOD_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getOnboardingStorage() private pure returns (OnboardingConfig storage $) {
        bytes32 slot = ONBOARDING_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getOrgDeployStorage() private pure returns (OrgDeployConfig storage $) {
        bytes32 slot = ORG_DEPLOY_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getOrgDeployCountsStorage() private pure returns (mapping(address => uint8) storage $) {
        bytes32 slot = ORG_DEPLOY_COUNTS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getOnboardingCountsStorage() private pure returns (mapping(address => uint8) storage $) {
        bytes32 slot = ONBOARDING_COUNTS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // ============ Validation (moved verbatim from PaymasterHub) ============

    /// @notice Validate POA onboarding eligibility (solidarity-funded account creation / profile update).
    function validateOnboardingEligibility(PackedUserOperation calldata userOp, uint256 maxCost)
        external
        returns (bytes32 subjectKey)
    {
        address account = userOp.sender;
        OnboardingConfig storage onboarding = _getOnboardingStorage();

        // Check onboarding is enabled
        if (!onboarding.enabled) revert PaymasterHubErrors.OnboardingDisabled();

        // Validate callData targets the account registry with an allowed function.
        // Allowed: registerAccount (account creation) or setProfileMetadata (profile update).
        bytes4 innerSelector;
        if (userOp.callData.length != 0) {
            innerSelector = _validateOnboardingCallData(userOp.callData, onboarding.accountRegistry);
        }

        // Account creation (registerAccount) requires initCode for deploying the smart account.
        // Profile updates (setProfileMetadata) do NOT require initCode — account already exists.
        bool isProfileUpdate = innerSelector == bytes4(0xde6808b6);
        if (!isProfileUpdate && userOp.initCode.length == 0) {
            revert PaymasterHubErrors.InvalidOnboardingRequest();
        }

        // Onboarding is paid from solidarity fund, so block when distribution is paused
        SolidarityFund storage solidarity = _getSolidarityStorage();
        if (solidarity.distributionPaused) revert PaymasterHubErrors.SolidarityDistributionIsPaused();

        // Check gas cost limit
        if (maxCost > onboarding.maxGasPerCreation) revert PaymasterHubErrors.GasTooHigh();

        // Check per-account lifetime limit. Unlike the daily counter, this is NOT refunded in postOp on failure:
        // a failed onboarding op still charges the solidarity fund (updateOnboardingUsage deducts actualGasCost
        // regardless of success), so every solidarity-charging attempt must consume the cap — otherwise repeated
        // failing ops would drain the fund while keeping the count at zero. (Validation state only persists when the
        // op is actually included on-chain, at which point postOp always runs and charges, so count and spend stay
        // in lockstep.) maxOnboardingsPerAccount == 0 means unlimited; in that mode we skip counting entirely to avoid
        // uint8 overflow on heavy senders and to keep already-deployed hubs (where the appended field reads 0) working.
        if (onboarding.maxOnboardingsPerAccount != 0) {
            mapping(address => uint8) storage counts = _getOnboardingCountsStorage();
            if (counts[account] >= onboarding.maxOnboardingsPerAccount) {
                revert PaymasterHubErrors.OnboardingLimitExceeded();
            }
            counts[account]++;
        }

        // Check daily rate limit
        uint32 today = uint32(block.timestamp / 1 days);
        if (today != onboarding.currentDay) {
            onboarding.currentDay = today;
            onboarding.attemptsToday = 0;
        }
        if (onboarding.attemptsToday >= onboarding.dailyCreationLimit) {
            revert PaymasterHubErrors.OnboardingDailyLimitExceeded();
        }
        onboarding.attemptsToday++;

        // Check solidarity fund has sufficient balance
        if (solidarity.balance < maxCost) revert PaymasterHubErrors.InsufficientFunds();

        // Subject key for onboarding is based on the account address (natural nonce)
        subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_POA_ONBOARDING, bytes20(account)));
    }

    /// @dev Validates that onboarding callData is execute(registryAddress, 0, registerAccount(...) | setProfileMetadata(...)).
    /// @return innerSelector The validated inner function selector.
    function _validateOnboardingCallData(bytes calldata callData, address registry)
        private
        pure
        returns (bytes4 innerSelector)
    {
        if (registry == address(0)) revert PaymasterHubErrors.InvalidOnboardingRequest();
        bool valid;
        (valid, innerSelector) = PaymasterCalldataLib.parseExecuteCall(callData, registry);
        if (!valid) revert PaymasterHubErrors.InvalidOnboardingRequest();
        // Must call registerAccount(string) = 0xbff6de20 OR setProfileMetadata(bytes32) = 0xde6808b6
        if (innerSelector != bytes4(0xbff6de20) && innerSelector != bytes4(0xde6808b6)) {
            revert PaymasterHubErrors.InvalidOnboardingRequest();
        }
    }

    /// @notice Validate free org deployment eligibility (deploy config, lifetime + daily rate limits).
    function validateOrgDeployEligibility(PackedUserOperation calldata userOp, uint256 maxCost)
        external
        returns (bytes32 subjectKey)
    {
        address account = userOp.sender;
        OrgDeployConfig storage deployConfig = _getOrgDeployStorage();

        // Check feature is enabled
        if (!deployConfig.enabled) revert PaymasterHubErrors.OrgDeployDisabled();

        // No initCode for org deployment (account must already exist)
        if (userOp.initCode.length != 0) revert PaymasterHubErrors.InvalidOrgDeployRequest();

        // Validate calldata: must be execute(orgDeployerAddress, 0, ...)
        _validateOrgDeployCallData(userOp.callData, deployConfig.orgDeployer);

        // Org deploy is paid from solidarity fund, so block when distribution is paused
        SolidarityFund storage solidarity = _getSolidarityStorage();
        if (solidarity.distributionPaused) revert PaymasterHubErrors.SolidarityDistributionIsPaused();

        // Check gas cost limit
        if (maxCost > deployConfig.maxGasPerDeploy) revert PaymasterHubErrors.GasTooHigh();

        // Check per-account lifetime limit (optimistic increment for bundle safety)
        mapping(address => uint8) storage counts = _getOrgDeployCountsStorage();
        if (counts[account] >= deployConfig.maxDeploysPerAccount) revert PaymasterHubErrors.OrgDeployLimitExceeded();
        counts[account]++;

        // Check daily rate limit (same pattern as onboarding)
        uint32 today = uint32(block.timestamp / 1 days);
        if (today != deployConfig.currentDay) {
            deployConfig.currentDay = today;
            deployConfig.attemptsToday = 0;
        }
        if (deployConfig.attemptsToday >= deployConfig.dailyDeployLimit) {
            revert PaymasterHubErrors.OrgDeployDailyLimitExceeded();
        }
        deployConfig.attemptsToday++;

        // Check solidarity fund has sufficient balance
        if (solidarity.balance < maxCost) revert PaymasterHubErrors.InsufficientFunds();

        // Subject key based on account address
        subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ORG_DEPLOY, bytes20(account)));
    }

    /// @dev Validates that org deploy callData is execute(orgDeployerAddress, 0, ...).
    ///      Does NOT parse inner deployFullOrg params because the struct is complex and may change.
    function _validateOrgDeployCallData(bytes calldata callData, address orgDeployer) private pure {
        if (orgDeployer == address(0)) revert PaymasterHubErrors.InvalidOrgDeployRequest();
        (bool valid,) = PaymasterCalldataLib.parseExecuteCall(callData, orgDeployer);
        if (!valid) revert PaymasterHubErrors.InvalidOrgDeployRequest();
    }

    // ============ postOp settlement (moved verbatim from PaymasterHub) ============

    /// @notice Update onboarding usage and deduct from solidarity fund (postOp).
    function updateOnboardingUsage(uint256 actualGasCost, bool countAsCreation) external {
        SolidarityFund storage solidarity = _getSolidarityStorage();

        if (countAsCreation) {
            emit PaymasterHubErrors.OnboardingAccountCreated(address(0), actualGasCost);
        } else {
            // Refund the daily counter slot for failed operations (incremented during validation for bundle safety)
            OnboardingConfig storage onboarding = _getOnboardingStorage();
            if (onboarding.attemptsToday > 0) {
                onboarding.attemptsToday--;
            }
        }

        // Deduct from solidarity fund (validated during validateOnboardingEligibility)
        if (solidarity.balance < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
        solidarity.balance -= uint128(actualGasCost);
    }

    /// @notice Update org deploy usage and deduct from solidarity fund (postOp).
    function updateOrgDeployUsage(address sender, uint256 actualGasCost, bool countAsDeployment) external {
        SolidarityFund storage solidarity = _getSolidarityStorage();

        if (countAsDeployment) {
            // Per-account counter already incremented during validation (bundle safety).
            // Just emit the event.
            emit PaymasterHubErrors.OrgDeploymentSponsored(sender, actualGasCost);
        } else {
            // Refund both counters for failed operations (incremented during validation for bundle safety)
            mapping(address => uint8) storage counts = _getOrgDeployCountsStorage();
            if (counts[sender] > 0) {
                counts[sender]--;
            }
            OrgDeployConfig storage deployConfig = _getOrgDeployStorage();
            if (deployConfig.attemptsToday > 0) {
                deployConfig.attemptsToday--;
            }
        }

        // Deduct from solidarity fund (validated during validateOrgDeployEligibility)
        if (solidarity.balance < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
        solidarity.balance -= uint128(actualGasCost);
    }

    /// @notice Settle an org-billed op in postOp: unreserve, split cost between org deposits and the
    ///         solidarity fund (tier/grace rules), collect the solidarity fee. Moved verbatim from
    ///         PaymasterHub._updateOrgFinancials.
    function updateOrgFinancials(bytes32 orgId, uint256 actualGasCost, uint256 reservedOrgBalance) external {
        mapping(bytes32 => OrgConfig) storage orgs = _getOrgsStorage();
        mapping(bytes32 => OrgFinancials) storage financials = _getFinancialsStorage();

        OrgConfig storage config = orgs[orgId];
        OrgFinancials storage org = financials[orgId];
        GracePeriodConfig storage grace = _getGracePeriodStorage();
        SolidarityFund storage solidarity = _getSolidarityStorage();

        // Unreserve the org deposit amount that was reserved during validation
        org.spent -= uint128(reservedOrgBalance);

        // Calculate 1% solidarity fee (always collected, even when distribution is paused)
        uint256 solidarityFee = (actualGasCost * uint256(solidarity.feePercentageBps)) / 10000;

        // If distribution is paused, pay 100% from org deposits, still collect fee
        if (solidarity.distributionPaused) {
            org.spent += uint128(actualGasCost + solidarityFee);
            solidarity.balance += uint128(solidarityFee);
            emit PaymasterHubErrors.SolidarityFeeCollected(orgId, solidarityFee);
            return;
        }

        // Check if in initial grace period
        bool inInitialGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        // Determine how much comes from org's deposits vs solidarity
        uint256 fromDeposits = 0;
        uint256 fromSolidarity = 0;
        uint256 solidarityLiquidity = solidarity.balance;

        // Calculate deposit available (after unreserving)
        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        if (inInitialGrace && depositAvailable < grace.minDepositRequired) {
            // Grace subsidy: unfunded orgs get 100% from solidarity, no fee.
            if (solidarityLiquidity < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
            fromSolidarity = actualGasCost;
            solidarityFee = 0;
        } else {
            // Tier-based split: funded grace orgs AND all post-grace orgs.
            // Fee is collected from deposits — not circular since org is self-funding.

            // Match allowance based on CURRENT BALANCE, not lifetime deposits
            uint256 matchAllowance =
                PaymasterGraceLib.calculateMatchAllowance(depositAvailable, grace.minDepositRequired);
            uint256 solidarityRemaining =
                matchAllowance > org.solidarityUsedThisPeriod ? matchAllowance - org.solidarityUsedThisPeriod : 0;
            if (solidarityRemaining > solidarityLiquidity) {
                solidarityRemaining = solidarityLiquidity;
            }

            uint256 halfCost = actualGasCost / 2;

            // Try 50/50 split
            fromDeposits = halfCost < depositAvailable ? halfCost : depositAvailable;
            fromSolidarity = halfCost < solidarityRemaining ? halfCost : solidarityRemaining;

            // If one pool is short, try to make up from the other
            uint256 covered = fromDeposits + fromSolidarity;
            if (covered < actualGasCost) {
                uint256 shortfall = actualGasCost - covered;

                // Try deposits first
                uint256 depositExtra = depositAvailable - fromDeposits;
                if (depositExtra > 0) {
                    uint256 additional = shortfall < depositExtra ? shortfall : depositExtra;
                    fromDeposits += additional;
                    shortfall -= additional;
                }

                // Then try solidarity
                if (shortfall > 0) {
                    uint256 solidarityExtra = solidarityRemaining - fromSolidarity;
                    if (solidarityExtra > 0) {
                        uint256 additional = shortfall < solidarityExtra ? shortfall : solidarityExtra;
                        fromSolidarity += additional;
                        shortfall -= additional;
                    }
                }

                // If still can't cover, revert
                if (shortfall > 0) {
                    revert PaymasterHubErrors.InsufficientFunds();
                }
            }
        }

        // Update org spending (include solidarity fee so it is deducted from org balance)
        org.spent += uint128(fromDeposits + solidarityFee);
        org.solidarityUsedThisPeriod += uint128(fromSolidarity);

        // Update solidarity fund
        solidarity.balance -= uint128(fromSolidarity);
        solidarity.balance += uint128(solidarityFee);

        if (solidarityFee > 0) {
            emit PaymasterHubErrors.SolidarityFeeCollected(orgId, solidarityFee);
        }

        emit PaymasterHubErrors.OrgSpendingRecorded(orgId, fromDeposits, fromSolidarity, solidarityFee);
    }
}
