// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation, UserOpLib} from "./interfaces/PackedUserOperation.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PaymasterHubErrors} from "./libs/PaymasterHubErrors.sol";
import {PaymasterGraceLib} from "./libs/PaymasterGraceLib.sol";
import {PaymasterPostOpLib} from "./libs/PaymasterPostOpLib.sol";
import {PaymasterCalldataLib} from "./libs/PaymasterCalldataLib.sol";

/**
 * @title PaymasterHub
 * @author POA Engineering
 * @notice Production-grade ERC-4337 paymaster shared across all POA organizations
 * @dev Implements ERC-7201 storage pattern with org-scoped configuration and budgets
 * @dev Upgradeable via UUPS pattern, governed by PoaManager
 * @custom:security-contact security@poa.org
 */
contract PaymasterHub is IPaymaster, Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IERC165 {
    // ============ Constants ============
    uint8 private constant PAYMASTER_DATA_VERSION = 1;
    uint8 private constant SUBJECT_TYPE_ACCOUNT = 0x00;
    uint8 private constant SUBJECT_TYPE_HAT = 0x01;
    uint8 private constant SUBJECT_TYPE_POA_ONBOARDING = 0x03;
    uint8 private constant SUBJECT_TYPE_ORG_DEPLOY = 0x04;

    // Sponsorship type flags for context encoding
    uint8 private constant SPONSORSHIP_NONE = 0;
    uint8 private constant SPONSORSHIP_ONBOARDING = 1;
    uint8 private constant SPONSORSHIP_ORG_DEPLOY = 2;

    uint32 private constant RULE_ID_GENERIC = 0x00000000;
    uint32 private constant RULE_ID_COARSE = 0x000000FF;

    uint32 private constant MIN_EPOCH_LENGTH = 1 hours;
    uint32 private constant MAX_EPOCH_LENGTH = 365 days;

    // ============ Storage Variables ============
    /// @custom:storage-location erc7201:poa.paymasterhub.main
    struct MainStorage {
        address entryPoint;
        address hats;
        address poaManager;
        address orgRegistrar; // authorized contract that can register orgs (e.g. OrgDeployer)
        address protocolAdmin; // protocol-level admin for cross-chain rule management
    }

    bytes32 private constant MAIN_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.main")) - 1));

    // ============ Storage Structs ============

    /**
     * @dev Organization configuration
     * Storage optimization: registeredAt packed with paused to save gas
     */
    struct OrgConfig {
        uint256 adminHatId;
        uint256 operatorHatId; // Optional role for budget/rule management
        bool paused;
        uint40 registeredAt; // UNIX timestamp, good until year 36812
        bool bannedFromSolidarity;
    }

    /**
     * @dev Per-org financial tracking for solidarity fund accounting
     */
    struct OrgFinancials {
        uint128 deposited; // Current balance deposited by org
        uint128 spent; // Total spent from org's own deposits
        uint128 solidarityUsedThisPeriod; // Solidarity used in current 90-day period
        uint32 periodStart; // Timestamp when current 90-day period started
    }

    /**
     * @dev Global solidarity fund state
     */
    struct SolidarityFund {
        uint128 balance; // Current solidarity fund balance
        uint32 numActiveOrgs; // Number of orgs with deposits > 0
        uint16 feePercentageBps; // Fee as basis points (100 = 1%)
        bool distributionPaused; // When true, only collect fees, no payouts
    }

    /**
     * @dev Grace period configuration for unfunded orgs
     */
    struct GracePeriodConfig {
        uint32 initialGraceDays; // Startup period with zero deposits (default 90)
        uint128 maxSpendDuringGrace; // Max spending during grace period (default 0.01 ETH ~$30)
        uint128 minDepositRequired; // Minimum balance to maintain after grace (default 0.003 ETH ~$10)
    }

    /**
     * @dev POA onboarding configuration for account creation from solidarity fund
     */
    struct OnboardingConfig {
        uint128 maxGasPerCreation; // Max gas per account creation (~200k)
        uint128 dailyCreationLimit; // Max accounts globally per day
        uint128 attemptsToday; // Validation attempts in current day window
        uint32 currentDay; // Day tracker (timestamp / 1 days)
        bool enabled; // Whether onboarding sponsorship is active
        address accountRegistry; // UniversalAccountRegistry — only allowed callData target during onboarding
        // Appended (v-next): lifetime cap on sponsored onboardings per sender (0 == unlimited).
        // Packs into the same slot as `accountRegistry` (160 + 8 bits) — no existing field moves.
        uint8 maxOnboardingsPerAccount;
    }

    /**
     * @dev Free org deployment configuration for solidarity-funded deployments
     */
    struct OrgDeployConfig {
        uint128 maxGasPerDeploy; // Max gas cost (in wei) per deployment
        uint128 dailyDeployLimit; // Max deployments globally per day
        uint128 attemptsToday; // Validation attempts in current day window
        uint32 currentDay; // Day tracker (timestamp / 1 days)
        uint8 maxDeploysPerAccount; // Lifetime cap per sender address (e.g. 2)
        bool enabled; // Whether org deploy sponsorship is active
        address orgDeployer; // Authorized OrgDeployer contract address
    }

    struct FeeCaps {
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
    }

    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    struct Budget {
        uint128 capPerEpoch;
        uint128 usedInEpoch;
        uint32 epochLen;
        uint32 epochStart;
    }

    // ============ ERC-7201 Storage Locations ============
    bytes32 private constant ORGS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgs")) - 1));
    bytes32 private constant FEECAPS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.feeCaps")) - 1));
    bytes32 private constant RULES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.rules")) - 1));
    bytes32 private constant BUDGETS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.budgets")) - 1));
    bytes32 private constant FINANCIALS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.financials")) - 1));
    bytes32 private constant SOLIDARITY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.solidarity")) - 1));
    bytes32 private constant GRACEPERIOD_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.graceperiod")) - 1));
    bytes32 private constant ONBOARDING_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.onboarding")) - 1));
    bytes32 private constant ORG_DEPLOY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgdeploy")) - 1));
    bytes32 private constant ORG_DEPLOY_COUNTS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgdeploy.counts")) - 1));
    bytes32 private constant ONBOARDING_COUNTS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.onboarding.counts")) - 1));

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    /**
     * @notice Initialize the PaymasterHub
     * @dev Called once during proxy deployment
     * @param _entryPoint ERC-4337 EntryPoint address
     * @param _hats Hats Protocol address
     * @param _poaManager PoaManager address for upgrade authorization
     */
    function initialize(address _entryPoint, address _hats, address _poaManager) public initializer {
        if (_entryPoint == address(0)) revert PaymasterHubErrors.ZeroAddress();
        if (_hats == address(0)) revert PaymasterHubErrors.ZeroAddress();
        if (_poaManager == address(0)) revert PaymasterHubErrors.ZeroAddress();

        // Verify entryPoint is a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_entryPoint)
        }
        if (codeSize == 0) revert PaymasterHubErrors.ContractNotDeployed();

        // Initialize upgradeable contracts
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Store main config
        MainStorage storage main = _getMainStorage();
        main.entryPoint = _entryPoint;
        main.hats = _hats;
        main.poaManager = _poaManager;

        // Initialize solidarity fund with 1% fee, distribution paused (collection-only mode)
        SolidarityFund storage solidarity = _getSolidarityStorage();
        solidarity.feePercentageBps = 100; // 1%
        solidarity.distributionPaused = true;

        // Initialize grace period with defaults (90 days, 0.01 ETH ~$30 spend, 0.003 ETH ~$10 deposit)
        GracePeriodConfig storage grace = _getGracePeriodStorage();
        grace.initialGraceDays = 90;
        grace.maxSpendDuringGrace = 0.01 ether; // ~$30 worth of gas (~3000 tx on cheap L2s)
        grace.minDepositRequired = 0.003 ether; // ~$10 minimum deposit

        // Initialize onboarding config (enabled, max cost per creation, 1000 accounts/day)
        // NOTE: maxGasPerCreation is compared against maxCost (in wei) from the EntryPoint,
        // so the value must be denominated in wei, not gas units.
        OnboardingConfig storage onboarding = _getOnboardingStorage();
        onboarding.maxGasPerCreation = 0.01 ether; // ~$30 worth of gas at typical L1 prices
        onboarding.dailyCreationLimit = 1000; // 1000 accounts per day
        onboarding.maxOnboardingsPerAccount = 3; // lifetime sponsored onboardings per sender: register + profile + 1 retry (0 == unlimited)
        onboarding.enabled = true;

        // Initialize org deploy config (enabled, max cost per deploy, 100 deployments/day, 2 per account)
        OrgDeployConfig storage orgDeploy = _getOrgDeployStorage();
        orgDeploy.maxGasPerDeploy = 0.05 ether; // Org deployment is more expensive than account creation
        orgDeploy.dailyDeployLimit = 100; // 100 free org deployments per day
        orgDeploy.maxDeploysPerAccount = 2; // 2 free deployments per account lifetime
        orgDeploy.enabled = false; // Requires explicit setOrgDeployConfig to activate

        emit PaymasterHubErrors.PaymasterInitialized(_entryPoint, _hats, _poaManager);
    }

    /// @notice Set protocol admin (one-time v2 reinitializer).
    function reinitializeProtocolAdmin(address _admin) external reinitializer(2) {
        _getMainStorage().protocolAdmin = _admin;
    }

    // ============ Deploy Config Struct ============

    /**
     * @notice Configuration passed by OrgDeployer during org creation
     * @dev Allows initial paymaster setup in the same transaction as org deployment
     */
    struct DeployConfig {
        uint256 operatorHatId;
        // Fee caps (all zeros = skip)
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        // Rules batch (empty arrays = skip)
        address[] ruleTargets;
        bytes4[] ruleSelectors;
        bool[] ruleAllowed;
        uint32[] ruleMaxCallGasHints;
        // Budgets batch (empty arrays = skip)
        bytes32[] budgetSubjectKeys;
        uint128[] budgetCapsPerEpoch;
        uint32[] budgetEpochLens;
    }

    // ============ Org Registration ============

    /**
     * @notice Register a new organization with the paymaster
     * @dev Called by OrgDeployer during org creation
     * @param orgId Unique organization identifier
     * @param adminHatId Hat ID for org admin (topHat)
     * @param operatorHatId Optional hat ID for operators (0 if none)
     */
    function registerOrg(bytes32 orgId, uint256 adminHatId, uint256 operatorHatId) external {
        _onlyRegistrar();
        _registerOrg(orgId, adminHatId, operatorHatId);
    }

    /**
     * @notice Register and configure an org with paymaster in one call
     * @dev Called by OrgDeployer to register, configure rules/fee caps, and optionally deposit ETH
     * @param orgId Unique organization identifier
     * @param adminHatId Hat ID for org admin (topHat)
     * @param config Initial paymaster configuration (operator hat, fee caps, rules)
     */
    function registerAndConfigureOrg(bytes32 orgId, uint256 adminHatId, DeployConfig calldata config) external payable {
        _onlyRegistrar();
        _registerOrg(orgId, adminHatId, config.operatorHatId);

        // Set fee caps if any non-zero
        if (
            config.maxFeePerGas != 0 || config.maxPriorityFeePerGas != 0 || config.maxCallGas != 0
                || config.maxVerificationGas != 0 || config.maxPreVerificationGas != 0
        ) {
            FeeCaps storage feeCaps = _getFeeCapsStorage()[orgId];
            feeCaps.maxFeePerGas = config.maxFeePerGas;
            feeCaps.maxPriorityFeePerGas = config.maxPriorityFeePerGas;
            feeCaps.maxCallGas = config.maxCallGas;
            feeCaps.maxVerificationGas = config.maxVerificationGas;
            feeCaps.maxPreVerificationGas = config.maxPreVerificationGas;

            emit PaymasterHubErrors.FeeCapsSet(
                orgId,
                config.maxFeePerGas,
                config.maxPriorityFeePerGas,
                config.maxCallGas,
                config.maxVerificationGas,
                config.maxPreVerificationGas
            );
        }

        // Set rules if arrays provided
        if (config.ruleTargets.length > 0) {
            _setRulesBatch(
                orgId, config.ruleTargets, config.ruleSelectors, config.ruleAllowed, config.ruleMaxCallGasHints
            );
        }

        // Set budgets if arrays provided
        if (config.budgetSubjectKeys.length > 0) {
            uint256 budgetLen = config.budgetSubjectKeys.length;
            if (budgetLen != config.budgetCapsPerEpoch.length || budgetLen != config.budgetEpochLens.length) {
                revert PaymasterHubErrors.ArrayLengthMismatch();
            }

            mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];

            for (uint256 j; j < budgetLen;) {
                uint32 epochLen = config.budgetEpochLens[j];
                if (epochLen < MIN_EPOCH_LENGTH || epochLen > MAX_EPOCH_LENGTH) {
                    revert PaymasterHubErrors.InvalidEpochLength();
                }

                Budget storage budget = budgets[config.budgetSubjectKeys[j]];
                budget.capPerEpoch = config.budgetCapsPerEpoch[j];
                budget.epochLen = epochLen;
                budget.epochStart = uint32(block.timestamp);

                emit PaymasterHubErrors.BudgetSet(
                    orgId, config.budgetSubjectKeys[j], config.budgetCapsPerEpoch[j], epochLen, uint32(block.timestamp)
                );

                unchecked {
                    ++j;
                }
            }
        }

        // Deposit ETH if sent
        if (msg.value > 0) {
            _depositForOrg(orgId, msg.value);
        }
    }

    function _onlyRegistrar() internal view {
        MainStorage storage main = _getMainStorage();
        if (msg.sender != main.poaManager && msg.sender != main.orgRegistrar) {
            revert PaymasterHubErrors.NotPoaManager();
        }
    }

    function _registerOrg(bytes32 orgId, uint256 adminHatId, uint256 operatorHatId) internal {
        if (orgId == bytes32(0)) revert PaymasterHubErrors.InvalidOrgId();
        if (adminHatId == 0) revert PaymasterHubErrors.ZeroAddress();

        mapping(bytes32 => OrgConfig) storage orgs = _getOrgsStorage();
        if (orgs[orgId].adminHatId != 0) revert PaymasterHubErrors.OrgAlreadyRegistered();

        orgs[orgId] = OrgConfig({
            adminHatId: adminHatId,
            operatorHatId: operatorHatId,
            paused: false,
            registeredAt: uint40(block.timestamp),
            bannedFromSolidarity: false
        });

        emit PaymasterHubErrors.OrgRegistered(orgId, adminHatId, operatorHatId);
    }

    // ============ Modifiers ============
    modifier onlyEntryPoint() {
        if (msg.sender != _getMainStorage().entryPoint) revert PaymasterHubErrors.EPOnly();
        _;
    }

    modifier onlyOrgAdmin(bytes32 orgId) {
        OrgConfig storage org = _getOrgsStorage()[orgId];
        if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();
        if (!IHats(_getMainStorage().hats).isWearerOfHat(msg.sender, org.adminHatId)) {
            revert PaymasterHubErrors.NotAdmin();
        }
        _;
    }

    modifier onlyOrgOperator(bytes32 orgId) {
        OrgConfig storage org = _getOrgsStorage()[orgId];
        if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();

        // PoaManager can manage any org's config (enables adminCall for migrations)
        if (msg.sender != _getMainStorage().poaManager) {
            bool isAdmin = IHats(_getMainStorage().hats).isWearerOfHat(msg.sender, org.adminHatId);
            bool isOperator =
                org.operatorHatId != 0 && IHats(_getMainStorage().hats).isWearerOfHat(msg.sender, org.operatorHatId);
            if (!isAdmin && !isOperator) revert PaymasterHubErrors.NotOperator();
        }
        _;
    }

    modifier whenOrgNotPaused(bytes32 orgId) {
        if (_getOrgsStorage()[orgId].paused) revert PaymasterHubErrors.Paused();
        _;
    }

    // ============ ERC-165 Support ============
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IPaymaster).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ============ Solidarity Fund Functions ============

    /**
     * @notice Check if org can access solidarity fund based on grace period and deposit requirements
     * @dev Implements "maintain minimum" model - checks current balance (deposited)
     *
     * Grace period model:
     * - First 90 days: Free solidarity access with transaction limit (3000 tx on L2)
     * - After 90 days: Must maintain minimum deposit (~$10) to access solidarity
     *
     * Gas overhead:
     * - Funded orgs (deposited >= minDepositRequired): ~100 gas
     * - Unfunded orgs in initial grace: ~220 gas
     * - Unfunded orgs after grace without sufficient balance: Reverts immediately
     *
     * @param orgId The organization identifier
     * @param maxCost Maximum cost of the operation (for solidarity limit check)
     */
    function _checkSolidarityAccess(bytes32 orgId, uint256 maxCost) internal view {
        SolidarityFund storage solidarity = _getSolidarityStorage();

        // If distribution is paused, skip solidarity checks entirely
        // Orgs pay 100% from deposits when distribution is paused
        if (solidarity.distributionPaused) return;

        mapping(bytes32 => OrgConfig) storage orgs = _getOrgsStorage();
        mapping(bytes32 => OrgFinancials) storage financials = _getFinancialsStorage();
        GracePeriodConfig storage grace = _getGracePeriodStorage();

        OrgConfig storage config = orgs[orgId];
        OrgFinancials storage org = financials[orgId];
        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        // Check if org is banned from solidarity
        if (config.bannedFromSolidarity) revert PaymasterHubErrors.OrgIsBanned();

        // Check grace period
        bool inInitialGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        if (inInitialGrace && depositAvailable < grace.minDepositRequired) {
            // Grace subsidy: unfunded orgs can use solidarity up to maxSpendDuringGrace.
            // Only applies during the initial grace period when org hasn't deposited
            // the minimum. Once they deposit enough, they use the tier system below.
            if (org.solidarityUsedThisPeriod + maxCost > grace.maxSpendDuringGrace) {
                revert PaymasterHubErrors.GracePeriodSpendLimitReached();
            }
            if (solidarity.balance < maxCost) revert PaymasterHubErrors.InsufficientFunds();
        } else {
            // Tier-based matching: applies to funded grace orgs AND all post-grace orgs.
            // Funded orgs use deposits first; solidarity provides tier-based matching.
            // Self-funded orgs (tier 4, deposit >= 5x min) need zero solidarity.
            if (depositAvailable < grace.minDepositRequired) {
                revert PaymasterHubErrors.InsufficientDepositForSolidarity();
            }

            uint256 matchAllowance =
                PaymasterGraceLib.calculateMatchAllowance(depositAvailable, grace.minDepositRequired);
            uint256 solidarityRemaining =
                matchAllowance > org.solidarityUsedThisPeriod ? matchAllowance - org.solidarityUsedThisPeriod : 0;

            // Minimum solidarity needed after using available deposits.
            uint256 requiredSolidarity = maxCost > depositAvailable ? maxCost - depositAvailable : 0;
            if (requiredSolidarity > solidarityRemaining) {
                revert PaymasterHubErrors.SolidarityLimitExceeded();
            }
            if (solidarity.balance < requiredSolidarity) revert PaymasterHubErrors.InsufficientFunds();
        }
    }

    /**
     * @notice Deposit funds for a specific org (permissionless)
     * @dev Anyone can deposit to any org to support them
     *
     * Deposit-to-Reset Model:
     * - When org crosses minimum threshold (was below, now above), resets solidarity allowance
     * - This creates natural monthly/periodic commitment without epoch tracking
     *
     * @param orgId The organization to deposit for
     */
    function depositForOrg(bytes32 orgId) external payable {
        if (msg.value == 0) revert PaymasterHubErrors.ZeroAmount();

        // Verify org exists
        if (_getOrgsStorage()[orgId].adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();

        _depositForOrg(orgId, msg.value);
    }

    /**
     * @dev Internal deposit logic shared by depositForOrg and registerAndConfigureOrg
     * @param orgId The organization to deposit for
     * @param amount Amount of ETH to deposit (must equal msg.value available)
     */
    function _depositForOrg(bytes32 orgId, uint256 amount) internal {
        mapping(bytes32 => OrgFinancials) storage financials = _getFinancialsStorage();
        GracePeriodConfig storage grace = _getGracePeriodStorage();

        OrgFinancials storage org = financials[orgId];

        // Check if period should reset (dual trigger)
        bool shouldResetPeriod = false;

        // Trigger 1: Time-based (90 days elapsed)
        if (org.periodStart > 0 && block.timestamp >= org.periodStart + 90 days) {
            shouldResetPeriod = true;
        }

        // Trigger 2: Crossing minimum threshold (based on available balance, not lifetime deposits,
        // to stay consistent with _checkSolidarityAccess and _updateOrgFinancials)
        uint256 availableBefore = org.deposited > org.spent ? org.deposited - org.spent : 0;
        uint256 availableAfter = availableBefore + amount;
        bool wasBelowMinimum = availableBefore < grace.minDepositRequired;
        bool willBeAboveMinimum = availableAfter >= grace.minDepositRequired;
        if (wasBelowMinimum && willBeAboveMinimum) {
            shouldResetPeriod = true;
        }

        // Track if this is first deposit (for numActiveOrgs counter and period init)
        bool wasUnfunded = org.deposited == 0;

        // Safe cast check
        if (amount > type(uint128).max) revert PaymasterHubErrors.Overflow();

        // Update org financials
        org.deposited += uint128(amount);

        // Reset period when triggered
        if (shouldResetPeriod) {
            org.solidarityUsedThisPeriod = 0;
            org.periodStart = uint32(block.timestamp);
        } else if (wasUnfunded) {
            // Initialize period start on first deposit
            org.periodStart = uint32(block.timestamp);
        }

        // Update active org count if this is first deposit
        if (wasUnfunded && amount > 0) {
            SolidarityFund storage solidarity = _getSolidarityStorage();
            solidarity.numActiveOrgs++;
        }

        // Deposit to EntryPoint
        IEntryPoint(_getMainStorage().entryPoint).depositTo{value: amount}(address(this));

        emit PaymasterHubErrors.OrgDepositReceived(orgId, msg.sender, amount);
    }

    /**
     * @notice Donate to solidarity fund (permissionless)
     * @dev Anyone can donate to support all orgs
     */
    function donateToSolidarity() external payable {
        if (msg.value == 0) revert PaymasterHubErrors.ZeroAmount();
        if (msg.value > type(uint128).max) revert PaymasterHubErrors.Overflow();

        SolidarityFund storage solidarity = _getSolidarityStorage();
        solidarity.balance += uint128(msg.value);

        // Deposit to EntryPoint
        IEntryPoint(_getMainStorage().entryPoint).depositTo{value: msg.value}(address(this));

        emit PaymasterHubErrors.SolidarityDonationReceived(msg.sender, msg.value);
    }

    // ============ ERC-4337 Paymaster Functions ============

    /**
     * @notice Validates a UserOperation for sponsorship
     * @dev Called by EntryPoint during simulation and execution
     * @param userOp The user operation to validate
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost that will be reimbursed
     * @return context Encoded context for postOp
     * @return validationData Packed validation data (sigFailed, validUntil, validAfter)
     */
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        // Decode and validate paymasterAndData
        (uint8 version, bytes32 orgId, uint8 subjectType, bytes32 subjectId, uint32 ruleId) =
            _decodePaymasterData(userOp.paymasterAndData);

        if (version != PAYMASTER_DATA_VERSION) revert PaymasterHubErrors.InvalidVersion();

        bytes32 subjectKey;
        uint32 currentEpochStart;
        bytes32 contextOrgId = orgId;
        uint256 reservedOrgBalance;

        uint8 sponsorshipType = SPONSORSHIP_NONE;

        // Handle solidarity-funded sponsorship paths (no org required)
        if (subjectType == SUBJECT_TYPE_POA_ONBOARDING) {
            sponsorshipType = SPONSORSHIP_ONBOARDING;
            // Global-only onboarding path: never org-scoped billing.
            if (orgId != bytes32(0) || subjectId != bytes32(0) || ruleId != RULE_ID_GENERIC) {
                revert PaymasterHubErrors.InvalidOnboardingRequest();
            }

            // Validate POA onboarding eligibility
            subjectKey = _validateOnboardingEligibility(userOp, maxCost);
            currentEpochStart = uint32(block.timestamp);
            contextOrgId = bytes32(0);

            // For onboarding, we don't validate org rules/caps/budgets
            // The onboarding config has its own limits
        } else if (subjectType == SUBJECT_TYPE_ORG_DEPLOY) {
            sponsorshipType = SPONSORSHIP_ORG_DEPLOY;
            // Global-only org deploy path: never org-scoped billing.
            if (orgId != bytes32(0) || subjectId != bytes32(0) || ruleId != RULE_ID_GENERIC) {
                revert PaymasterHubErrors.InvalidOrgDeployRequest();
            }

            // Validate free org deployment eligibility
            subjectKey = _validateOrgDeployEligibility(userOp, maxCost);
            currentEpochStart = uint32(block.timestamp);
            contextOrgId = bytes32(0);
        } else {
            // Validate org is registered and not paused
            OrgConfig storage org = _getOrgsStorage()[orgId];
            if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();
            if (org.paused) revert PaymasterHubErrors.Paused();

            // Validate subject eligibility
            subjectKey = _validateSubjectEligibility(userOp.sender, subjectType, subjectId);

            // Validate target/selector rules
            _validateRules(userOp, ruleId, orgId);

            // Validate fee and gas caps
            _validateFeeCaps(userOp, orgId);

            // Check per-subject budget (existing functionality)
            currentEpochStart = _checkBudget(orgId, subjectKey, maxCost);

            // Check solidarity fund access BEFORE reserving org balance.
            // _checkSolidarityAccess reads depositAvailable for tier calculation and
            // minDepositRequired checks — the reservation would deflate depositAvailable.
            _checkSolidarityAccess(orgId, maxCost);

            // Reserve maxCost from org deposits (after solidarity check)
            reservedOrgBalance = _checkOrgBalance(orgId, maxCost);
        }

        // Prepare context for postOp
        // maxCost = budget reservation (always reserved), reservedOrgBalance = org deposit reservation (0 during grace)
        // sender is needed for org deploy path to increment per-account counter in postOp
        context = abi.encode(
            sponsorshipType, contextOrgId, subjectKey, currentEpochStart, maxCost, reservedOrgBalance, userOp.sender
        );

        // Return 0 for no signature failure and no time restrictions
        validationData = 0;
    }

    /**
     * @notice Check if org has sufficient balance to cover operation and reserve maxCost
     * @dev Prevents org from spending more than deposited + solidarity allocation.
     *      Reserves maxCost by incrementing org.spent (unreserved in postOp).
     *      This ensures bundle safety: multiple UserOps for the same org in one bundle
     *      cannot bypass the balance check because each validation sees the reserved amounts.
     * @param orgId The organization identifier
     * @param maxCost Maximum cost of the operation
     */
    function _checkOrgBalance(bytes32 orgId, uint256 maxCost) internal returns (uint256 reserved) {
        mapping(bytes32 => OrgFinancials) storage financials = _getFinancialsStorage();
        OrgFinancials storage org = financials[orgId];

        uint256 depositAvailable =
            uint256(org.deposited) > uint256(org.spent) ? uint256(org.deposited) - uint256(org.spent) : 0;

        SolidarityFund storage solidarity = _getSolidarityStorage();

        if (solidarity.distributionPaused) {
            // When distribution is paused, org must cover 100% from deposits
            if (depositAvailable < maxCost) {
                revert PaymasterHubErrors.InsufficientOrgBalance();
            }
            org.spent += uint128(maxCost); // Reserve for bundle safety
            return maxCost;
        }

        // Deposits are fully exhausted — check if grace period allows solidarity-only coverage
        if (depositAvailable == 0) {
            OrgConfig storage config = _getOrgsStorage()[orgId];
            GracePeriodConfig storage grace = _getGracePeriodStorage();
            if (PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays)) {
                return 0; // Grace period with zero deposits: no reservation needed
            }
            revert PaymasterHubErrors.InsufficientOrgBalance();
        }

        // Deposits cover fully or partially — solidarity covers the rest
        // Reserve maxCost from org deposits (unreserved in postOp)
        org.spent += uint128(maxCost);
        return maxCost;
    }

    /**
     * @notice Post-operation hook called after UserOperation execution
     * @dev Updates budget usage, collects solidarity fee, and processes bounties
     * @param mode Execution mode (success/revert/postOpRevert)
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost to be reimbursed
     */
    function postOp(
        IPaymaster.PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    )
        external
        override
        onlyEntryPoint
        nonReentrant
    {
        (
            uint8 sponsorshipType,
            bytes32 orgId,
            bytes32 subjectKey,
            uint32 epochStart,
            uint256 reservedBudget,
            uint256 reservedOrgBalance,
            address sender
        ) = abi.decode(context, (uint8, bytes32, bytes32, uint32, uint256, uint256, address));

        // Solidarity-funded sponsorship paths
        if (sponsorshipType == SPONSORSHIP_ONBOARDING) {
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                _sponsorshipPostOpFallback(sponsorshipType, sender, actualGasCost);
                return;
            }
            _updateOnboardingUsage(actualGasCost, mode == IPaymaster.PostOpMode.opSucceeded);
        } else if (sponsorshipType == SPONSORSHIP_ORG_DEPLOY) {
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                _sponsorshipPostOpFallback(sponsorshipType, sender, actualGasCost);
                return;
            }
            _updateOrgDeployUsage(sender, actualGasCost, mode == IPaymaster.PostOpMode.opSucceeded);
        } else {
            // If the first postOp call reverted, EntryPoint calls again with postOpReverted.
            // Use a fallback that cannot revert: charge 100% from deposits, skip solidarity.
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                _postOpFallback(orgId, subjectKey, epochStart, actualGasCost, reservedBudget, reservedOrgBalance);
                return;
            }

            // Regular org operation
            // Update per-subject budget usage
            _updateUsage(orgId, subjectKey, epochStart, actualGasCost, reservedBudget);

            // Update per-org financial tracking and collect solidarity fee
            _updateOrgFinancials(orgId, actualGasCost, reservedOrgBalance);
        }
    }

    /**
     * @notice Fallback accounting when the first postOp call reverts
     * @dev Called with PostOpMode.postOpReverted. Must not revert — if this reverts too,
     *      the paymaster is charged by EntryPoint with no accounting update.
     *      Charges 100% from org deposits (skips solidarity to avoid the revert path).
     */
    function _postOpFallback(
        bytes32 orgId,
        bytes32 subjectKey,
        uint32 epochStart,
        uint256 actualGasCost,
        uint256 reservedBudget,
        uint256 reservedOrgBalance
    ) private {
        // Adjust budget: replace reservation with actual cost
        mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];
        Budget storage budget = budgets[subjectKey];
        if (budget.epochStart == epochStart) {
            budget.usedInEpoch = PaymasterPostOpLib.adjustBudget(budget.usedInEpoch, reservedBudget, actualGasCost);
            emit PaymasterHubErrors.UsageIncreased(orgId, subjectKey, actualGasCost, budget.usedInEpoch, epochStart);
        }

        // Unreserve org balance reserved during validation
        mapping(bytes32 => OrgFinancials) storage financials = _getFinancialsStorage();
        OrgFinancials storage org = financials[orgId];
        org.spent -= uint128(reservedOrgBalance);

        SolidarityFund storage solidarity = _getSolidarityStorage();
        GracePeriodConfig storage grace = _getGracePeriodStorage();
        OrgConfig storage config = _getOrgsStorage()[orgId];
        bool inGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        // No fee during grace (would be circular — solidarity pays itself)
        uint256 solidarityFee = inGrace ? 0 : (actualGasCost * uint256(solidarity.feePercentageBps)) / 10000;

        uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;

        uint256 fallbackFromDeposits;
        uint256 fallbackFromSolidarity;

        if (depositAvailable >= actualGasCost + solidarityFee) {
            // Fully funded: charge actualGasCost + fee from deposits, credit fee to solidarity.
            org.spent += uint128(actualGasCost + solidarityFee);
            solidarity.balance += uint128(solidarityFee);
            fallbackFromDeposits = actualGasCost;
            fallbackFromSolidarity = 0;
        } else if (depositAvailable > 0) {
            // Partially funded: deposits cover what they can, solidarity absorbs the rest.
            fallbackFromDeposits = depositAvailable < actualGasCost ? depositAvailable : actualGasCost;
            fallbackFromSolidarity = actualGasCost - fallbackFromDeposits;
            org.spent += uint128(fallbackFromDeposits);
            (solidarity.balance,) = PaymasterPostOpLib.clampedDeduction(solidarity.balance, fallbackFromSolidarity);
            org.solidarityUsedThisPeriod += uint128(fallbackFromSolidarity);
            solidarityFee = 0;
        } else {
            // Unfunded: 100% solidarity.
            (solidarity.balance,) = PaymasterPostOpLib.clampedDeduction(solidarity.balance, actualGasCost);
            org.solidarityUsedThisPeriod += uint128(actualGasCost);
            fallbackFromDeposits = 0;
            fallbackFromSolidarity = actualGasCost;
        }

        if (solidarityFee > 0) {
            emit PaymasterHubErrors.SolidarityFeeCollected(orgId, solidarityFee);
        }

        emit PaymasterHubErrors.OrgSpendingRecorded(orgId, fallbackFromDeposits, fallbackFromSolidarity, solidarityFee);
    }

    /**
     * @notice Fallback accounting for solidarity-funded sponsorship when postOp reverts
     * @dev Called with PostOpMode.postOpReverted for onboarding and org deploy paths.
     *      MUST NOT revert — if this reverts, the paymaster is charged by EntryPoint
     *      with zero accounting update, creating permanent balance drift.
     *
     *      Unlike the regular org fallback, there are no org deposits to charge.
     *      Deducts min(solidarity.balance, actualGasCost) and refunds optimistic counters.
     *
     * @param sponsorshipType SPONSORSHIP_ONBOARDING or SPONSORSHIP_ORG_DEPLOY
     * @param sender The account address (needed for org deploy per-account counter)
     * @param actualGasCost Actual gas cost charged by EntryPoint
     */
    function _sponsorshipPostOpFallback(uint8 sponsorshipType, address sender, uint256 actualGasCost) private {
        // Deduct from solidarity (clamped to available balance — never revert)
        SolidarityFund storage solidarity = _getSolidarityStorage();
        (solidarity.balance,) = PaymasterPostOpLib.clampedDeduction(solidarity.balance, actualGasCost);

        // Refund optimistic counters. The first postOp's refunds were rolled back by EntryPoint,
        // so counters are still at their validation-incremented values.
        if (sponsorshipType == SPONSORSHIP_ONBOARDING) {
            OnboardingConfig storage onboarding = _getOnboardingStorage();
            if (onboarding.attemptsToday > 0) {
                onboarding.attemptsToday--;
            }
        } else {
            // SPONSORSHIP_ORG_DEPLOY
            mapping(address => uint8) storage counts = _getOrgDeployCountsStorage();
            if (counts[sender] > 0) {
                counts[sender]--;
            }
            OrgDeployConfig storage deployConfig = _getOrgDeployStorage();
            if (deployConfig.attemptsToday > 0) {
                deployConfig.attemptsToday--;
            }
        }
    }

    /**
     * @notice Update org's financial tracking and collect 1% solidarity fee
     * @dev Called in postOp after actual gas cost is known
     *
     * Payment Priority:
     * - Unfunded grace orgs (deposit < minRequired): 100% from solidarity (grace subsidy)
     * - Funded grace orgs (deposit >= minRequired): tier-based split, no solidarity fee
     * - After grace period: tier-based 50/50 split between deposits and solidarity
     *
     * @param orgId The organization identifier
     * @param actualGasCost Actual gas cost paid
     * @param reservedOrgBalance The org deposit amount reserved during validation (to be unreserved)
     */
    function _updateOrgFinancials(bytes32 orgId, uint256 actualGasCost, uint256 reservedOrgBalance) internal {
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

    // ============ Admin Functions ============

    /**
     * @notice Set a rule for target/selector combination
     * @dev Only callable by org admin or operator
     */
    function setRule(bytes32 orgId, address target, bytes4 selector, bool allowed, uint32 maxCallGasHint)
        external
        onlyOrgOperator(orgId)
    {
        if (target == address(0)) revert PaymasterHubErrors.ZeroAddress();

        mapping(address => mapping(bytes4 => Rule)) storage rules = _getRulesStorage()[orgId];
        rules[target][selector] = Rule({allowed: allowed, maxCallGasHint: maxCallGasHint});
        emit PaymasterHubErrors.RuleSet(orgId, target, selector, allowed, maxCallGasHint);
    }

    /**
     * @notice Batch set rules for multiple target/selector combinations
     */
    function setRulesBatch(
        bytes32 orgId,
        address[] calldata targets,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) external onlyOrgOperator(orgId) {
        _setRulesBatch(orgId, targets, selectors, allowed, maxCallGasHints);
    }

    /// @notice Batch-add rules across orgs. Skips unregistered orgs.
    function adminBatchAddRules(bytes32[] calldata orgIds, address[] calldata targets, bytes4[] calldata selectors)
        external
    {
        MainStorage storage m = _getMainStorage();
        if (msg.sender != m.poaManager && msg.sender != m.protocolAdmin) revert PaymasterHubErrors.NotOperator();
        for (uint256 i; i < orgIds.length;) {
            if (_getOrgsStorage()[orgIds[i]].adminHatId != 0) {
                _getRulesStorage()[orgIds[i]][targets[i]][selectors[i]] = Rule({allowed: true, maxCallGasHint: 0});
            }
            unchecked {
                ++i;
            }
        }
    }

    function _setRulesBatch(
        bytes32 orgId,
        address[] calldata targets,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) internal {
        uint256 length = targets.length;
        if (length != selectors.length || length != allowed.length || length != maxCallGasHints.length) {
            revert PaymasterHubErrors.ArrayLengthMismatch();
        }

        mapping(address => mapping(bytes4 => Rule)) storage rules = _getRulesStorage()[orgId];

        for (uint256 i; i < length;) {
            if (targets[i] == address(0)) revert PaymasterHubErrors.ZeroAddress();

            rules[targets[i]][selectors[i]] = Rule({allowed: allowed[i], maxCallGasHint: maxCallGasHints[i]});

            emit PaymasterHubErrors.RuleSet(orgId, targets[i], selectors[i], allowed[i], maxCallGasHints[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Clear a rule for target/selector combination
     */
    function clearRule(bytes32 orgId, address target, bytes4 selector) external onlyOrgOperator(orgId) {
        mapping(address => mapping(bytes4 => Rule)) storage rules = _getRulesStorage()[orgId];
        delete rules[target][selector];
        emit PaymasterHubErrors.RuleSet(orgId, target, selector, false, 0);
    }

    /**
     * @notice Set budget for a subject
     * @dev Validates epoch length and initializes epoch start
     */
    function setBudget(bytes32 orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen)
        external
        onlyOrgOperator(orgId)
    {
        if (epochLen < MIN_EPOCH_LENGTH || epochLen > MAX_EPOCH_LENGTH) {
            revert PaymasterHubErrors.InvalidEpochLength();
        }

        mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];
        Budget storage budget = budgets[subjectKey];

        // If changing epoch length, reset usage
        if (budget.epochLen != epochLen && budget.epochLen != 0) {
            budget.usedInEpoch = 0;
        }

        budget.capPerEpoch = capPerEpoch;
        budget.epochLen = epochLen;

        // Initialize epoch start if not set
        if (budget.epochStart == 0) {
            budget.epochStart = uint32(block.timestamp);
        }

        emit PaymasterHubErrors.BudgetSet(orgId, subjectKey, capPerEpoch, epochLen, budget.epochStart);
    }

    /**
     * @notice Manually set epoch start for a subject
     */
    function setEpochStart(bytes32 orgId, bytes32 subjectKey, uint32 epochStart) external onlyOrgOperator(orgId) {
        mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];
        Budget storage budget = budgets[subjectKey];

        budget.epochStart = epochStart;
        budget.usedInEpoch = 0; // Reset usage when manually setting epoch

        emit PaymasterHubErrors.BudgetSet(orgId, subjectKey, budget.capPerEpoch, budget.epochLen, epochStart);
    }

    /**
     * @notice Set fee and gas caps
     */
    function setFeeCaps(
        bytes32 orgId,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint32 maxCallGas,
        uint32 maxVerificationGas,
        uint32 maxPreVerificationGas
    ) external onlyOrgOperator(orgId) {
        FeeCaps storage feeCaps = _getFeeCapsStorage()[orgId];

        feeCaps.maxFeePerGas = maxFeePerGas;
        feeCaps.maxPriorityFeePerGas = maxPriorityFeePerGas;
        feeCaps.maxCallGas = maxCallGas;
        feeCaps.maxVerificationGas = maxVerificationGas;
        feeCaps.maxPreVerificationGas = maxPreVerificationGas;

        emit PaymasterHubErrors.FeeCapsSet(
            orgId, maxFeePerGas, maxPriorityFeePerGas, maxCallGas, maxVerificationGas, maxPreVerificationGas
        );
    }

    /**
     * @notice Pause or unpause the paymaster for an org
     * @dev Only org admin can pause/unpause
     */
    function setPause(bytes32 orgId, bool paused) external onlyOrgAdmin(orgId) {
        _getOrgsStorage()[orgId].paused = paused;
        emit PaymasterHubErrors.PauseSet(orgId, paused);
    }

    /**
     * @notice Set optional operator hat for delegated management
     */
    function setOperatorHat(bytes32 orgId, uint256 operatorHatId) external onlyOrgAdmin(orgId) {
        _getOrgsStorage()[orgId].operatorHatId = operatorHatId;
        emit PaymasterHubErrors.OperatorHatSet(orgId, operatorHatId);
    }

    /**
     * @notice Deposit funds to EntryPoint for gas reimbursement (shared pool)
     * @dev Any org operator can deposit to shared pool
     */
    function depositToEntryPoint(bytes32 orgId) external payable onlyOrgOperator(orgId) {
        address entryPoint = _getMainStorage().entryPoint;
        IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));

        uint256 newDeposit = IEntryPoint(entryPoint).balanceOf(address(this));
        emit PaymasterHubErrors.DepositIncrease(msg.value, newDeposit);
    }

    /**
     * @notice Set grace period configuration (global setting)
     * @dev Only PoaManager can modify grace period parameters
     * @param _initialGraceDays Number of days for initial grace period (default 90)
     * @param _maxSpendDuringGrace Maximum spending during grace period (default 0.01 ETH ~$30, represents ~3000 tx)
     * @param _minDepositRequired Minimum balance to maintain after grace (default 0.003 ETH ~$10)
     */
    function setGracePeriodConfig(uint32 _initialGraceDays, uint128 _maxSpendDuringGrace, uint128 _minDepositRequired)
        external
    {
        if (msg.sender != _getMainStorage().poaManager) revert PaymasterHubErrors.NotPoaManager();
        if (_initialGraceDays == 0) revert PaymasterHubErrors.InvalidEpochLength();
        if (_maxSpendDuringGrace == 0) revert PaymasterHubErrors.InvalidEpochLength();
        if (_minDepositRequired == 0) revert PaymasterHubErrors.InvalidEpochLength();

        GracePeriodConfig storage grace = _getGracePeriodStorage();
        grace.initialGraceDays = _initialGraceDays;
        grace.maxSpendDuringGrace = _maxSpendDuringGrace;
        grace.minDepositRequired = _minDepositRequired;

        emit PaymasterHubErrors.GracePeriodConfigUpdated(_initialGraceDays, _maxSpendDuringGrace, _minDepositRequired);
    }

    /**
     * @notice Set the authorized org registrar (e.g. OrgDeployer)
     * @dev Only PoaManager can set the registrar
     * @param registrar Address authorized to call registerOrg
     */
    function setOrgRegistrar(address registrar) external {
        if (msg.sender != _getMainStorage().poaManager) revert PaymasterHubErrors.NotPoaManager();
        _getMainStorage().orgRegistrar = registrar;
    }

    /**
     * @notice Ban or unban an org from accessing solidarity fund
     * @dev Only PoaManager can ban orgs for malicious behavior
     * @param orgId The organization to ban/unban
     * @param banned True to ban, false to unban
     */
    function setBanFromSolidarity(bytes32 orgId, bool banned) external {
        if (msg.sender != _getMainStorage().poaManager) revert PaymasterHubErrors.NotPoaManager();

        mapping(bytes32 => OrgConfig) storage orgs = _getOrgsStorage();
        if (orgs[orgId].adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();

        orgs[orgId].bannedFromSolidarity = banned;

        emit PaymasterHubErrors.OrgBannedFromSolidarity(orgId, banned);
    }

    /**
     * @notice Set solidarity fund fee percentage
     * @dev Only PoaManager can modify the fee (default 1%)
     * @param feePercentageBps Fee as basis points (100 = 1%)
     */
    function setSolidarityFee(uint16 feePercentageBps) external {
        MainStorage storage m = _getMainStorage();
        if (msg.sender != m.poaManager && msg.sender != m.protocolAdmin) revert PaymasterHubErrors.NotPoaManager();
        if (feePercentageBps > 1000) revert PaymasterHubErrors.FeeTooHigh(); // Cap at 10%

        SolidarityFund storage solidarity = _getSolidarityStorage();
        solidarity.feePercentageBps = feePercentageBps;
    }

    /**
     * @notice Pause solidarity fund distribution (collection-only mode)
     * @dev When paused: 1% fees still collected, but no distribution to orgs.
     *      Orgs must fund 100% of gas costs from their own deposits.
     *      Only PoaManager can pause/unpause.
     */
    function pauseSolidarityDistribution() external {
        if (msg.sender != _getMainStorage().poaManager) revert PaymasterHubErrors.NotPoaManager();
        SolidarityFund storage solidarity = _getSolidarityStorage();
        if (!solidarity.distributionPaused) {
            solidarity.distributionPaused = true;
            emit PaymasterHubErrors.SolidarityDistributionPaused();
        }
    }

    /**
     * @notice Unpause solidarity fund distribution
     * @dev When unpaused: normal grace period + tier matching resumes.
     *      Only PoaManager can pause/unpause.
     */
    function unpauseSolidarityDistribution() external {
        if (msg.sender != _getMainStorage().poaManager) revert PaymasterHubErrors.NotPoaManager();
        SolidarityFund storage solidarity = _getSolidarityStorage();
        if (solidarity.distributionPaused) {
            solidarity.distributionPaused = false;
            emit PaymasterHubErrors.SolidarityDistributionUnpaused();
        }
    }

    /**
     * @notice Configure POA onboarding for account creation from solidarity fund
     * @dev Only PoaManager can modify onboarding parameters
     * @param _maxGasPerCreation Maximum cost in wei allowed per account creation
     * @param _dailyCreationLimit Maximum accounts that can be created per day globally
     * @param _maxOnboardingsPerAccount Lifetime cap on sponsored onboardings per sender (0 == unlimited)
     * @param _enabled Whether onboarding sponsorship is active
     * @param _accountRegistry UniversalAccountRegistry address (only allowed callData target)
     */
    function setOnboardingConfig(
        uint128 _maxGasPerCreation,
        uint128 _dailyCreationLimit,
        uint8 _maxOnboardingsPerAccount,
        bool _enabled,
        address _accountRegistry
    ) external {
        if (msg.sender != _getMainStorage().poaManager) {
            revert PaymasterHubErrors.NotPoaManager();
        }

        OnboardingConfig storage onboarding = _getOnboardingStorage();
        onboarding.maxGasPerCreation = _maxGasPerCreation;
        onboarding.dailyCreationLimit = _dailyCreationLimit;
        onboarding.maxOnboardingsPerAccount = _maxOnboardingsPerAccount;
        onboarding.enabled = _enabled;
        onboarding.accountRegistry = _accountRegistry;

        emit PaymasterHubErrors.OnboardingConfigUpdated(
            _maxGasPerCreation, _dailyCreationLimit, _maxOnboardingsPerAccount, _enabled, _accountRegistry
        );
    }

    /**
     * @notice Configure free org deployment sponsorship from solidarity fund
     * @dev Only PoaManager can modify org deploy parameters
     * @param _maxGasPerDeploy Maximum cost in wei allowed per org deployment
     * @param _dailyDeployLimit Maximum deployments that can be sponsored per day globally
     * @param _maxDeploysPerAccount Lifetime cap per sender address
     * @param _enabled Whether org deploy sponsorship is active
     * @param _orgDeployer Authorized OrgDeployer contract address
     */
    function setOrgDeployConfig(
        uint128 _maxGasPerDeploy,
        uint128 _dailyDeployLimit,
        uint8 _maxDeploysPerAccount,
        bool _enabled,
        address _orgDeployer
    ) external {
        if (msg.sender != _getMainStorage().poaManager) {
            revert PaymasterHubErrors.NotPoaManager();
        }

        OrgDeployConfig storage deployConfig = _getOrgDeployStorage();
        deployConfig.maxGasPerDeploy = _maxGasPerDeploy;
        deployConfig.dailyDeployLimit = _dailyDeployLimit;
        deployConfig.maxDeploysPerAccount = _maxDeploysPerAccount;
        deployConfig.enabled = _enabled;
        deployConfig.orgDeployer = _orgDeployer;

        emit PaymasterHubErrors.OrgDeployConfigUpdated(
            _maxGasPerDeploy, _dailyDeployLimit, _maxDeploysPerAccount, _enabled, _orgDeployer
        );
    }

    // ============ Storage Getters (for Lens) ============

    /**
     * @notice Get the configuration for an org
     * @return The OrgConfig struct
     */
    function getOrgConfig(bytes32 orgId) external view returns (OrgConfig memory) {
        return _getOrgsStorage()[orgId];
    }

    /**
     * @notice Get budget for a specific subject within an org
     * @param orgId Organization identifier
     * @param key The subject key (user, role, or org)
     * @return The Budget struct
     */
    function getBudget(bytes32 orgId, bytes32 key) external view returns (Budget memory) {
        return _getBudgetsStorage()[orgId][key];
    }

    /**
     * @notice Get rule for a specific target and selector within an org
     * @param orgId Organization identifier
     * @param target The target contract address
     * @param selector The function selector
     * @return The Rule struct
     */
    function getRule(bytes32 orgId, address target, bytes4 selector) external view returns (Rule memory) {
        return _getRulesStorage()[orgId][target][selector];
    }

    /**
     * @notice Get the fee caps for an org
     * @param orgId Organization identifier
     * @return The FeeCaps struct
     */
    function getFeeCaps(bytes32 orgId) external view returns (FeeCaps memory) {
        return _getFeeCapsStorage()[orgId];
    }

    /**
     * @notice Get org's financial tracking data
     * @param orgId Organization identifier
     * @return The OrgFinancials struct
     */
    function getOrgFinancials(bytes32 orgId) external view returns (OrgFinancials memory) {
        return _getFinancialsStorage()[orgId];
    }

    /**
     * @notice Get global solidarity fund state
     * @return The SolidarityFund struct
     */
    function getSolidarityFund() external view returns (SolidarityFund memory) {
        return _getSolidarityStorage();
    }

    /**
     * @notice Get grace period configuration
     * @return The GracePeriodConfig struct
     */
    function getGracePeriodConfig() external view returns (GracePeriodConfig memory) {
        return _getGracePeriodStorage();
    }

    /**
     * @notice Get onboarding configuration for POA account creation
     * @return The OnboardingConfig struct
     */
    function getOnboardingConfig() external view returns (OnboardingConfig memory) {
        return _getOnboardingStorage();
    }

    /**
     * @notice Get org deploy sponsorship configuration
     * @return The OrgDeployConfig struct
     */
    function getOrgDeployConfig() external view returns (OrgDeployConfig memory) {
        return _getOrgDeployStorage();
    }

    /**
     * @notice Get number of sponsored deployments for a specific account
     * @param account The account address to query
     * @return Number of sponsored deployments used
     */
    function getOrgDeployCount(address account) external view returns (uint8) {
        return _getOrgDeployCountsStorage()[account];
    }

    // ============ Storage Accessors ============
    function _getMainStorage() private pure returns (MainStorage storage $) {
        bytes32 slot = MAIN_STORAGE_LOCATION;
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

    function _getFeeCapsStorage() private pure returns (mapping(bytes32 => FeeCaps) storage $) {
        bytes32 slot = FEECAPS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getRulesStorage()
        private
        pure
        returns (mapping(bytes32 => mapping(address => mapping(bytes4 => Rule))) storage $)
    {
        bytes32 slot = RULES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getBudgetsStorage() private pure returns (mapping(bytes32 => mapping(bytes32 => Budget)) storage $) {
        bytes32 slot = BUDGETS_STORAGE_LOCATION;
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

    function _getSolidarityStorage() private pure returns (SolidarityFund storage $) {
        bytes32 slot = SOLIDARITY_STORAGE_LOCATION;
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

    function _getOnboardingCountsStorage() private pure returns (mapping(address => uint8) storage $) {
        bytes32 slot = ONBOARDING_COUNTS_STORAGE_LOCATION;
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

    // ============ Public Getters ============

    /**
     * @notice Get the EntryPoint address
     * @return The ERC-4337 EntryPoint address
     */
    function ENTRY_POINT() public view returns (address) {
        return _getMainStorage().entryPoint;
    }

    /**
     * @notice Get the Hats Protocol address
     * @return The Hats Protocol address
     */
    function HATS() public view returns (address) {
        return _getMainStorage().hats;
    }

    /**
     * @notice Get the PoaManager address
     * @return The PoaManager address
     */
    function POA_MANAGER() public view returns (address) {
        return _getMainStorage().poaManager;
    }

    // ============ Upgrade Authorization ============

    /**
     * @notice Authorize contract upgrade
     * @dev Only PoaManager can authorize upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        MainStorage storage main = _getMainStorage();
        if (msg.sender != main.poaManager) revert PaymasterHubErrors.NotPoaManager();
        if (newImplementation == address(0)) revert PaymasterHubErrors.ZeroAddress();
        if (newImplementation.code.length == 0) revert PaymasterHubErrors.ContractNotDeployed();
    }

    // ============ Internal Functions ============

    function _decodePaymasterData(bytes calldata paymasterAndData)
        private
        pure
        returns (uint8 version, bytes32 orgId, uint8 subjectType, bytes32 subjectId, uint32 ruleId)
    {
        // ERC-4337 v0.7 packed format:
        // [paymaster(20) | verificationGasLimit(16) | postOpGasLimit(16) | version(1) | orgId(32) | subjectType(1) | subjectId(32) | ruleId(4)]
        // = 122 bytes total. Custom data starts at offset 52.
        if (paymasterAndData.length < 122) revert PaymasterHubErrors.InvalidPaymasterData();

        // Skip first 52 bytes (paymaster address + v0.7 gas limits) and decode the rest
        version = uint8(paymasterAndData[52]);
        orgId = bytes32(paymasterAndData[53:85]);
        subjectType = uint8(paymasterAndData[85]);

        // Extract bytes32 subjectId from bytes 86-117
        assembly {
            subjectId := calldataload(add(paymasterAndData.offset, 86))
        }

        // Extract ruleId from bytes 118-121
        ruleId = uint32(bytes4(paymasterAndData[118:122]));
    }

    function _validateSubjectEligibility(address sender, uint8 subjectType, bytes32 subjectId)
        private
        view
        returns (bytes32 subjectKey)
    {
        if (subjectType == SUBJECT_TYPE_ACCOUNT) {
            if (address(uint160(uint256(subjectId))) != sender) revert PaymasterHubErrors.Ineligible();
            subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
        } else if (subjectType == SUBJECT_TYPE_HAT) {
            uint256 hatId = uint256(subjectId);
            IHats hatsContract = IHats(_getMainStorage().hats);
            if (!hatsContract.isEligible(sender, hatId)) {
                revert PaymasterHubErrors.Ineligible();
            }
            // Ensure the hat itself is still active (toggle module check)
            (,,,,,,,, bool active) = hatsContract.viewHat(hatId);
            if (!active) {
                revert PaymasterHubErrors.Ineligible();
            }
            subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
        } else {
            revert PaymasterHubErrors.InvalidSubjectType();
        }
    }

    /**
     * @notice Validate POA onboarding eligibility for gasless account creation
     * @dev Checks onboarding config and daily rate limits
     * @param userOp The user operation being validated
     * @param maxCost Maximum gas cost for the operation
     * @return subjectKey The subject key for tracking
     */
    function _validateOnboardingEligibility(PackedUserOperation calldata userOp, uint256 maxCost)
        private
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
        // a failed onboarding op still charges the solidarity fund (_updateOnboardingUsage deducts actualGasCost
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

    /**
     * @notice Validate free org deployment eligibility
     * @dev Checks deploy config, per-account lifetime limit, and daily rate limits
     * @param userOp The user operation being validated
     * @param maxCost Maximum gas cost for the operation
     * @return subjectKey The subject key for tracking
     */
    function _validateOrgDeployEligibility(PackedUserOperation calldata userOp, uint256 maxCost)
        private
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

    function _validateRules(PackedUserOperation calldata userOp, uint32 ruleId, bytes32 orgId) private view {
        bytes calldata callData = userOp.callData;
        if (callData.length < 4) revert PaymasterHubErrors.InvalidPaymasterData();

        // For RULE_ID_GENERIC, executeBatch needs per-inner-call validation
        if (ruleId == RULE_ID_GENERIC) {
            bytes4 outerSelector = bytes4(callData[0:4]);
            // executeBatch(address[],uint256[],bytes[]) or executeBatch(address[],bytes[])
            if (outerSelector == bytes4(0x47e1da2a) || outerSelector == bytes4(0x18dfb3c7)) {
                _validateBatchRules(callData, outerSelector, orgId);
                return;
            }
        }

        // Single-call path (existing logic)
        (address target, bytes4 selector) = _extractTargetSelector(userOp, ruleId);

        mapping(address => mapping(bytes4 => Rule)) storage rules = _getRulesStorage()[orgId];
        Rule storage rule = rules[target][selector];

        if (!rule.allowed) revert PaymasterHubErrors.RuleDenied(target, selector);

        // Check gas hint if set
        if (rule.maxCallGasHint > 0) {
            (, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);
            if (callGasLimit > rule.maxCallGasHint) revert PaymasterHubErrors.GasTooHigh();
        }
    }

    /// @dev Validates that every inner call in an executeBatch is allowed by org rules.
    ///      Decodes the batch targets and datas, then checks each (target, selector) pair.
    ///      Gas hints are not checked per-call (total callGasLimit still applies via FeeCaps).
    ///      Inner calls with < 4 bytes of data use selector bytes4(0) (treated as raw ETH transfer / fallback).
    function _validateBatchRules(bytes calldata callData, bytes4 outerSelector, bytes32 orgId) private view {
        mapping(address => mapping(bytes4 => Rule)) storage rules = _getRulesStorage()[orgId];

        // Decode targets and datas from either batch format
        address[] memory targets;
        bytes[] memory datas;
        if (outerSelector == bytes4(0x47e1da2a)) {
            // executeBatch(address[],uint256[],bytes[]) — PasskeyAccount pattern
            (targets,, datas) = abi.decode(callData[4:], (address[], uint256[], bytes[]));
        } else {
            // executeBatch(address[],bytes[]) — SimpleAccount pattern (0x18dfb3c7)
            (targets, datas) = abi.decode(callData[4:], (address[], bytes[]));
        }

        if (targets.length != datas.length) revert PaymasterHubErrors.ArrayLengthMismatch();
        for (uint256 i = 0; i < targets.length;) {
            bytes4 innerSelector;
            if (datas[i].length >= 4) {
                bytes memory d = datas[i];
                assembly {
                    innerSelector := mload(add(d, 0x20))
                }
            }
            Rule storage rule = rules[targets[i]][innerSelector];
            if (!rule.allowed) revert PaymasterHubErrors.RuleDenied(targets[i], innerSelector);
            unchecked {
                ++i;
            }
        }
    }

    function _extractTargetSelector(PackedUserOperation calldata userOp, uint32 ruleId)
        private
        pure
        returns (address target, bytes4 selector)
    {
        bytes calldata callData = userOp.callData;

        if (callData.length < 4) revert PaymasterHubErrors.InvalidPaymasterData();

        if (ruleId == RULE_ID_GENERIC) {
            // ERC-4337 account execute patterns (SimpleAccount, PasskeyAccount, etc.)
            selector = bytes4(callData[0:4]);

            // Check for execute(address,uint256,bytes) - 0xb61d27f6
            // Used by SimpleAccount, PasskeyAccount, and most ERC-4337 wallets
            if (selector == 0xb61d27f6 && callData.length >= 0x64) {
                assembly {
                    // Extract target address at offset 0x04
                    target := calldataload(add(callData.offset, 0x04))

                    // Read the bytes data offset pointer at position 0x44
                    // This offset is relative to the start of params (0x04)
                    let dataOffset := calldataload(add(callData.offset, 0x44))

                    // Only extract inner selector if dataOffset is the standard 0x60
                    // (3rd dynamic param in ABI encoding). A non-standard offset could
                    // allow an attacker to point at arbitrary calldata.
                    if eq(dataOffset, 0x60) {
                        let dataStart := add(add(0x04, dataOffset), 0x20)
                        if lt(dataStart, callData.length) {
                            selector := calldataload(add(callData.offset, dataStart))
                        }
                    }
                }
                selector = bytes4(selector);
            }
            // For RULE_ID_GENERIC, executeBatch selectors (0x47e1da2a, 0x18dfb3c7) are
            // intercepted by _validateRules → _validateBatchRules before reaching here.
            // Any other outer selector (including non-execute custom functions) falls through.
            else {
                target = userOp.sender;
            }
        } else if (ruleId == RULE_ID_COARSE) {
            // Coarse mode: only check account's selector
            target = userOp.sender;
            selector = bytes4(callData[0:4]);
        } else {
            revert PaymasterHubErrors.InvalidRuleId();
        }
    }

    function _validateFeeCaps(PackedUserOperation calldata userOp, bytes32 orgId) private view {
        FeeCaps storage caps = _getFeeCapsStorage()[orgId];

        (uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) = UserOpLib.unpackGasFees(userOp.gasFees);
        if (caps.maxFeePerGas > 0 && maxFeePerGas > caps.maxFeePerGas) {
            revert PaymasterHubErrors.FeeTooHigh();
        }
        if (caps.maxPriorityFeePerGas > 0 && maxPriorityFeePerGas > caps.maxPriorityFeePerGas) {
            revert PaymasterHubErrors.FeeTooHigh();
        }

        (uint128 verificationGasLimit, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);

        if (caps.maxCallGas > 0 && callGasLimit > caps.maxCallGas) {
            revert PaymasterHubErrors.GasTooHigh();
        }
        if (caps.maxVerificationGas > 0 && verificationGasLimit > caps.maxVerificationGas) {
            revert PaymasterHubErrors.GasTooHigh();
        }
        if (caps.maxPreVerificationGas > 0 && userOp.preVerificationGas > caps.maxPreVerificationGas) {
            revert PaymasterHubErrors.GasTooHigh();
        }
    }

    function _checkBudget(bytes32 orgId, bytes32 subjectKey, uint256 maxCost)
        private
        returns (uint32 currentEpochStart)
    {
        mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];
        Budget storage budget = budgets[subjectKey];

        // Check if epoch needs rolling
        uint256 currentTime = block.timestamp;
        if (budget.epochLen > 0 && currentTime >= budget.epochStart + budget.epochLen) {
            // Calculate number of complete epochs passed
            uint32 epochsPassed = uint32((currentTime - budget.epochStart) / budget.epochLen);
            budget.epochStart = budget.epochStart + (epochsPassed * budget.epochLen);
            budget.usedInEpoch = 0;
        }

        // Check budget capacity (safe conversion as maxCost is bounded by EntryPoint)
        if (budget.usedInEpoch + uint128(maxCost) > budget.capPerEpoch) {
            revert PaymasterHubErrors.BudgetExceeded();
        }

        // Reserve maxCost for bundle safety — ensures a second UserOp for the same
        // subject in the same bundle sees the updated usedInEpoch. Adjusted to actual
        // cost in _updateUsage during postOp.
        budget.usedInEpoch += uint128(maxCost);

        currentEpochStart = budget.epochStart;
    }

    function _updateUsage(
        bytes32 orgId,
        bytes32 subjectKey,
        uint32 epochStart,
        uint256 actualGasCost,
        uint256 reservedMaxCost
    ) private {
        mapping(bytes32 => Budget) storage budgets = _getBudgetsStorage()[orgId];
        Budget storage budget = budgets[subjectKey];

        // Only update if we're still in the same epoch
        if (budget.epochStart == epochStart) {
            // Replace reservation (maxCost) with actual cost (actualGasCost <= maxCost)
            budget.usedInEpoch = PaymasterPostOpLib.adjustBudget(budget.usedInEpoch, reservedMaxCost, actualGasCost);
            emit PaymasterHubErrors.UsageIncreased(orgId, subjectKey, actualGasCost, budget.usedInEpoch, epochStart);
        }
        // If epoch rolled since validation, reservation was already cleared by epoch reset
    }

    /**
     * @notice Update onboarding usage and deduct from solidarity fund
     * @dev Called in postOp for POA onboarding operations
     * @param actualGasCost Actual gas cost to deduct
     * @param countAsCreation Whether to emit creation event (true when op succeeded)
     */
    function _updateOnboardingUsage(uint256 actualGasCost, bool countAsCreation) private {
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

        // Deduct from solidarity fund (validated during _validateOnboardingEligibility)
        if (solidarity.balance < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
        solidarity.balance -= uint128(actualGasCost);
    }

    /**
     * @notice Update org deploy usage and deduct from solidarity fund
     * @dev Called in postOp for free org deployment operations
     * @param sender The account that deployed the org
     * @param actualGasCost Actual gas cost to deduct
     * @param countAsDeployment Whether to count as successful deployment (true when op succeeded)
     */
    function _updateOrgDeployUsage(address sender, uint256 actualGasCost, bool countAsDeployment) private {
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

        // Deduct from solidarity fund (validated during _validateOrgDeployEligibility)
        if (solidarity.balance < actualGasCost) revert PaymasterHubErrors.InsufficientFunds();
        solidarity.balance -= uint128(actualGasCost);
    }
}
