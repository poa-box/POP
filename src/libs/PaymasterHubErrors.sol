// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/// @title PaymasterHubErrors
/// @author POA Engineering
/// @notice Shared errors and events for PaymasterHub and PaymasterHubLens
library PaymasterHubErrors {
    // ============ Access Control Errors ============

    /// @notice Caller is not the ERC-4337 EntryPoint
    error EPOnly();

    /// @notice Organization is paused by its admin
    error Paused();

    /// @notice Caller does not wear the org admin hat
    error NotAdmin();

    /// @notice Caller does not wear the org operator hat
    error NotOperator();

    /// @notice Caller is not the PoaManager contract
    error NotPoaManager();

    // ============ Validation Errors ============

    /// @notice Target + selector combination is not in the org's allowlist
    error RuleDenied(address target, bytes4 selector);

    /// @notice Gas fee exceeds the org's configured fee cap
    error FeeTooHigh();

    /// @notice Gas limit exceeds the org's configured gas cap
    error GasTooHigh();

    /// @notice Sender is not eligible for the specified subject (hat or account)
    error Ineligible();

    /// @notice Subject's per-epoch budget would be exceeded
    error BudgetExceeded();

    /// @notice Rule ID is not a recognized rule type
    error InvalidRuleId();

    /// @notice Subject type byte is not a recognized type (0x00, 0x01, 0x03, 0x04, 0x05)
    error InvalidSubjectType();

    /// @notice Paymaster data version does not match expected version
    error InvalidVersion();

    /// @notice Paymaster data is malformed or too short
    error InvalidPaymasterData();

    /// @notice Address parameter must not be zero
    error ZeroAddress();

    /// @notice Epoch length is outside the allowed range
    error InvalidEpochLength();

    /// @notice Expected contract at address has no code deployed
    error ContractNotDeployed();

    /// @notice Array parameters have mismatched lengths
    error ArrayLengthMismatch();

    // ============ Organization Errors ============

    /// @notice Organization is not registered in the PaymasterHub
    error OrgNotRegistered();

    /// @notice Organization is already registered
    error OrgAlreadyRegistered();

    /// @notice Organization ID is invalid (zero)
    error InvalidOrgId();

    // ============ Solidarity & Grace Period Errors ============

    /// @notice Org has exceeded its grace period spending limit
    error GracePeriodSpendLimitReached();

    /// @notice Org's deposit is below the minimum required to access solidarity
    error InsufficientDepositForSolidarity();

    /// @notice Org has exceeded its tier-based solidarity match allowance
    error SolidarityLimitExceeded();

    /// @notice Org's available deposit balance is insufficient
    error InsufficientOrgBalance();

    /// @notice Organization is banned from using the solidarity fund
    error OrgIsBanned();

    /// @notice Solidarity fund or org balance has insufficient funds
    error InsufficientFunds();

    /// @notice Solidarity fund distribution is currently paused
    error SolidarityDistributionIsPaused();

    /// @notice Arithmetic overflow detected
    error Overflow();

    /// @notice Amount parameter must not be zero
    error ZeroAmount();

    // ============ Onboarding Errors ============

    /// @notice Onboarding sponsorship feature is disabled
    error OnboardingDisabled();

    /// @notice Account has reached its lifetime onboarding sponsorship limit
    error OnboardingLimitExceeded();

    /// @notice Global daily onboarding creation limit has been reached
    error OnboardingDailyLimitExceeded();

    /// @notice Onboarding request is malformed (bad calldata, missing initCode, etc.)
    error InvalidOnboardingRequest();

    // ============ Org Deploy Errors ============

    /// @notice Org deployment sponsorship feature is disabled
    error OrgDeployDisabled();

    /// @notice Account has reached its lifetime org deployment limit
    error OrgDeployLimitExceeded();

    /// @notice Global daily org deployment limit has been reached
    error OrgDeployDailyLimitExceeded();

    /// @notice Org deploy request is malformed (bad calldata, has initCode, etc.)
    error InvalidOrgDeployRequest();

    // ============ Events ============

    /// @notice Emitted when the PaymasterHub is initialized
    event PaymasterInitialized(address indexed entryPoint, address indexed hats, address indexed poaManager);

    /// @notice Emitted when a new organization is registered
    event OrgRegistered(bytes32 indexed orgId, uint256 adminHatId, uint256 operatorHatId);

    /// @notice Emitted when a rule is set or updated for an org
    event RuleSet(
        bytes32 indexed orgId, address indexed target, bytes4 indexed selector, bool allowed, uint32 maxCallGasHint
    );

    /// @notice Emitted when a per-subject budget is configured
    event BudgetSet(bytes32 indexed orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen, uint32 epochStart);

    /// @notice Emitted when an org's fee caps are updated
    event FeeCapsSet(
        bytes32 indexed orgId,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint32 maxCallGas,
        uint32 maxVerificationGas,
        uint32 maxPreVerificationGas
    );

    /// @notice Emitted when an org's pause state changes
    event PauseSet(bytes32 indexed orgId, bool paused);

    /// @notice Emitted when an org's operator hat is updated
    event OperatorHatSet(bytes32 indexed orgId, uint256 operatorHatId);

    /// @notice Emitted when ETH is deposited to the EntryPoint
    event DepositIncrease(uint256 amount, uint256 newDeposit);

    /// @notice Emitted when a subject's budget usage increases
    event UsageIncreased(
        bytes32 indexed orgId, bytes32 subjectKey, uint256 delta, uint128 usedInEpoch, uint32 epochStart
    );

    /// @notice Emitted when ETH is deposited for a specific org
    event OrgDepositReceived(bytes32 indexed orgId, address indexed from, uint256 amount);

    /// @notice Emitted when solidarity fee is collected from an org's operation
    event SolidarityFeeCollected(bytes32 indexed orgId, uint256 amount);

    /// @notice Emitted when an org operation is processed, showing the funding breakdown
    event OrgSpendingRecorded(
        bytes32 indexed orgId, uint256 fromDeposits, uint256 fromSolidarity, uint256 solidarityFee
    );

    /// @notice Emitted when a direct donation is made to the solidarity fund
    event SolidarityDonationReceived(address indexed from, uint256 amount);

    /// @notice Emitted when grace period configuration is updated
    event GracePeriodConfigUpdated(uint32 initialGraceDays, uint128 maxSpendDuringGrace, uint128 minDepositRequired);

    /// @notice Emitted when an org's solidarity ban status changes
    event OrgBannedFromSolidarity(bytes32 indexed orgId, bool banned);

    /// @notice Emitted when onboarding configuration is updated
    event OnboardingConfigUpdated(
        uint128 maxGasPerCreation,
        uint128 dailyCreationLimit,
        uint8 maxOnboardingsPerAccount,
        bool enabled,
        address accountRegistry
    );

    /// @notice Emitted when a new account is created via onboarding sponsorship
    event OnboardingAccountCreated(address indexed account, uint256 gasCost);

    /// @notice Emitted when org deployment configuration is updated
    event OrgDeployConfigUpdated(
        uint128 maxGasPerDeploy, uint128 dailyDeployLimit, uint8 maxDeploysPerAccount, bool enabled, address orgDeployer
    );

    /// @notice Emitted when an org deployment is sponsored
    event OrgDeploymentSponsored(address indexed account, uint256 gasCost);

    /// @notice Emitted when solidarity fund distribution is paused
    event SolidarityDistributionPaused();

    /// @notice Emitted when solidarity fund distribution is unpaused
    event SolidarityDistributionUnpaused();
}
