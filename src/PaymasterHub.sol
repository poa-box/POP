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
import {PaymasterAdminLib} from "./libs/PaymasterAdminLib.sol";
import {PaymasterFinanceLib} from "./libs/PaymasterFinanceLib.sol";
import {PaymasterSponsorshipLib} from "./libs/PaymasterSponsorshipLib.sol";
import {PaymasterRuleLib} from "./libs/PaymasterRuleLib.sol";

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
    /// @dev Sponsors calls TO an org-designated claim contract (subjectId = its address) with NO
    ///      validation-time wearer-eligibility pre-check — the claim contract itself is the gate
    ///      (e.g. ZkEmailInvites: ZK email proof + allowlist + open-hat guard, granting eligibility
    ///      during execution). Spend is bounded by the org's Budget for keccak(0x05, subjectId) and
    ///      by target/selector Rules; callData MUST be execute(subjectId, 0, ...) (batch rejected).
    uint8 private constant SUBJECT_TYPE_CLAIM = 0x05;

    // Sponsorship type flags for context encoding
    uint8 private constant SPONSORSHIP_NONE = 0;
    uint8 private constant SPONSORSHIP_ONBOARDING = 1;
    uint8 private constant SPONSORSHIP_ORG_DEPLOY = 2;

    uint32 private constant RULE_ID_GENERIC = 0x00000000;

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
    // Global rulebook namespaces — written exclusively via PaymasterRuleLib (delegatecall);
    // mirrored here only for the read-only getters. Slot derivations MUST match the lib.
    bytes32 private constant GLOBAL_RULES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalrules")) - 1));
    bytes32 private constant GLOBAL_RULE_KEYS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalrulekeys")) - 1));
    bytes32 private constant TARGET_TYPES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.targettypes")) - 1));
    bytes32 private constant RULES_MODES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.rulesmodes")) - 1));
    bytes32 private constant GLOBAL_RULE_BLOCKS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalruleblocks")) - 1));

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

    /// @notice Set the protocol-level admin, gated to the PoaManager (M-10).
    /// @dev Replaces the unauthenticated `reinitializeProtocolAdmin(address)` reinitializer,
    ///      which any address could front-run once a new impl was live but the reinit was
    ///      unconsumed, permanently seizing `protocolAdmin`. This is an ordinary
    ///      poaManager-gated setter (no reinitializer) delegated to PaymasterAdminLib to keep
    ///      the hub under the EIP-170 limit. `protocolAdmin` bypasses the poaManager gate in
    ///      `adminBatchAddRules`/`setSolidarityFee`, so it must stay poaManager-controlled.
    /// @param newAdmin The new protocolAdmin (may be zero to disable the protocol-admin path).
    function setProtocolAdmin(address newAdmin) external {
        PaymasterAdminLib.setProtocolAdmin(newAdmin);
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
     * @dev Called by OrgDeployer to register, configure rules/fee caps/target types/rules mode,
     *      and optionally deposit ETH. Config application is delegated to PaymasterRuleLib
     *      (EIP-170 headroom); the registrar gate and org registration stay here.
     * @param orgId Unique organization identifier
     * @param adminHatId Hat ID for org admin (topHat)
     * @param config Initial paymaster configuration (operator hat, fee caps, rules, target types)
     */
    function registerAndConfigureOrg(bytes32 orgId, uint256 adminHatId, PaymasterRuleLib.DeployConfig calldata config)
        external
        payable
    {
        _onlyRegistrar();
        _registerOrg(orgId, adminHatId, config.operatorHatId);

        PaymasterRuleLib.applyDeployConfig(orgId, config);

        // Deposit ETH if sent
        if (msg.value > 0) {
            _depositForOrg(orgId, msg.value);
        }
    }

    /**
     * @notice Legacy-ABI overload of registerAndConfigureOrg (pre-rulebook 13-field DeployConfig)
     * @dev Retains the function selector the LIVE OrgDeployer proxies call, so the hub upgrade
     *      needs NO lockstep OrgDeployer upgrade: orgs deployed through an un-upgraded deployer
     *      get fee caps + address-keyed local rules + budgets exactly as before (no target types,
     *      default Mirror mode — inert until types are mapped). Remove once every chain's
     *      OrgDeployer speaks the new ABI.
     */
    function registerAndConfigureOrg(
        bytes32 orgId,
        uint256 adminHatId,
        PaymasterRuleLib.LegacyDeployConfig calldata config
    ) external payable {
        _onlyRegistrar();
        _registerOrg(orgId, adminHatId, config.operatorHatId);

        PaymasterRuleLib.applyLegacyDeployConfig(orgId, config);

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

    // NOTE (M-05): the solidarity access check + per-org reservation moved to
    // PaymasterFinanceLib.checkSolidarityAccessAndReserve (delegatecall) to keep the hub under
    // the EIP-170 size limit and to add validation-time reservation of solidarityUsedThisPeriod.

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
        // to stay consistent with PaymasterFinanceLib.checkSolidarityAccessAndReserve and its
        // _applyFinancials postOp split — both key the solidarity tier off deposited - spent)
        // KNOWN LIMITATION (audit WS-C follow-up): withdrawOrgDeposit (M-04) lets an org admin
        // drop available below minDepositRequired and re-deposit across it to zero
        // solidarityUsedThisPeriod without burning real spend, cheapening the per-period
        // solidarity throttle (bannedFromSolidarity remains the backstop). A proper fix
        // (time-gate this reset or suppress it after a same-period withdrawal) needs a Layout
        // append + accounting change and is tracked separately, not folded into this pass.
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
        uint256 reservedSolidarity;

        uint8 sponsorshipType = SPONSORSHIP_NONE;

        // Handle solidarity-funded sponsorship paths (no org required)
        if (subjectType == SUBJECT_TYPE_POA_ONBOARDING) {
            sponsorshipType = SPONSORSHIP_ONBOARDING;
            // Global-only onboarding path: never org-scoped billing.
            if (orgId != bytes32(0) || subjectId != bytes32(0) || ruleId != RULE_ID_GENERIC) {
                revert PaymasterHubErrors.InvalidOnboardingRequest();
            }

            // Validate POA onboarding eligibility (external delegatecall lib — EIP-170 headroom)
            subjectKey = PaymasterSponsorshipLib.validateOnboardingEligibility(userOp, maxCost);
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

            // Validate free org deployment eligibility (external delegatecall lib — EIP-170 headroom)
            subjectKey = PaymasterSponsorshipLib.validateOrgDeployEligibility(userOp, maxCost);
            currentEpochStart = uint32(block.timestamp);
            contextOrgId = bytes32(0);
        } else {
            // Validate org is registered and not paused
            OrgConfig storage org = _getOrgsStorage()[orgId];
            if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();
            if (org.paused) revert PaymasterHubErrors.Paused();

            // Validate subject eligibility. CLAIM (0x05) deliberately has NO wearer-eligibility
            // pre-check — the claim contract grants eligibility DURING execution (its own proof +
            // allowlist gates are the authorization). Instead, bind the sponsorship to the claim
            // contract itself: callData must be exactly execute(subjectId, 0, ...) (fail-closed;
            // batch rejected). Rules below still gate the inner selector, and the org's Budget for
            // keccak(0x05, subjectId) caps spend — an unset budget blocks the path entirely.
            if (subjectType == SUBJECT_TYPE_CLAIM) {
                (bool validClaim,) =
                    PaymasterCalldataLib.parseExecuteCall(userOp.callData, address(uint160(uint256(subjectId))));
                if (!validClaim) revert PaymasterHubErrors.Ineligible();
                subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
            } else {
                subjectKey = _validateSubjectEligibility(userOp.sender, subjectType, subjectId);
            }

            // Validate target/selector rules (local org rules with global rulebook fallback for
            // Mirror-mode orgs — delegatecall lib, hub's own storage only, ERC-7562 safe)
            PaymasterRuleLib.validateRules(userOp, ruleId, orgId);

            // Validate fee and gas caps
            _validateFeeCaps(userOp, orgId);

            // Check per-subject budget (existing functionality)
            currentEpochStart = _checkBudget(orgId, subjectKey, maxCost);

            // Check solidarity fund access AND reserve the solidarity this op would draw (M-05),
            // BEFORE reserving org balance. The reservation reads depositAvailable for tier
            // calculation and minDepositRequired checks — the org-balance reservation would
            // deflate depositAvailable, so it must run after. Reserving into the per-org
            // solidarityUsedThisPeriod makes a second same-org op in the bundle see the updated
            // counter and be bounded by the grace/tier allowance.
            reservedSolidarity = PaymasterFinanceLib.checkSolidarityAccessAndReserve(orgId, maxCost);

            // Reserve maxCost from org deposits (after solidarity check)
            reservedOrgBalance = _checkOrgBalance(orgId, maxCost);
        }

        // Prepare context for postOp
        // maxCost = budget reservation (always reserved), reservedOrgBalance = org deposit reservation (0 during grace),
        // reservedSolidarity = per-org solidarity reservation (M-05, unreserved in postOp).
        // sender is needed for org deploy path to increment per-account counter in postOp
        context = abi.encode(
            sponsorshipType,
            contextOrgId,
            subjectKey,
            currentEpochStart,
            maxCost,
            reservedOrgBalance,
            userOp.sender,
            reservedSolidarity
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
            address sender,
            uint256 reservedSolidarity
        ) = abi.decode(context, (uint8, bytes32, bytes32, uint32, uint256, uint256, address, uint256));

        // Solidarity-funded sponsorship paths
        if (sponsorshipType == SPONSORSHIP_ONBOARDING) {
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                _sponsorshipPostOpFallback(sponsorshipType, sender, actualGasCost);
                return;
            }
            PaymasterSponsorshipLib.updateOnboardingUsage(actualGasCost, mode == IPaymaster.PostOpMode.opSucceeded);
        } else if (sponsorshipType == SPONSORSHIP_ORG_DEPLOY) {
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                _sponsorshipPostOpFallback(sponsorshipType, sender, actualGasCost);
                return;
            }
            PaymasterSponsorshipLib.updateOrgDeployUsage(
                sender, actualGasCost, mode == IPaymaster.PostOpMode.opSucceeded
            );
        } else {
            // If the first postOp call reverted, EntryPoint calls again with postOpReverted.
            // Use a fallback that cannot revert: charge from deposits first, absorb the rest
            // from solidarity. Unreserves the budget/deposit/solidarity reservations (M-05).
            if (mode == IPaymaster.PostOpMode.postOpReverted) {
                PaymasterFinanceLib.postOpFallback(
                    orgId, subjectKey, epochStart, actualGasCost, reservedBudget, reservedOrgBalance, reservedSolidarity
                );
                return;
            }

            // Regular org operation (also covers SUBJECT_TYPE_CLAIM 0x05, which shares this
            // org-billed path): adjust budget, unreserve deposit + solidarity, apply the actual
            // funding split and collect the solidarity fee. This single call subsumes the budget
            // adjust (_updateUsage) AND the org-financials split (updateOrgFinancials) AND the M-05
            // solidarity unreservation — so those must NOT also run here or spend double-counts.
            PaymasterFinanceLib.updateUsageAndFinancials(
                orgId, subjectKey, epochStart, actualGasCost, reservedBudget, reservedOrgBalance, reservedSolidarity
            );
        }
    }

    // NOTE (M-05/L-28/L-30/L-32): the regular-org postOp fallback moved to
    // PaymasterFinanceLib.postOpFallback (delegatecall) — see the postOp dispatch above.

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

    // ============ Admin Functions ============

    /**
     * @notice Set a rule for target/selector combination
     * @dev Only callable by org admin or operator
     */
    function setRule(bytes32 orgId, address target, bytes4 selector, bool allowed, uint32 maxCallGasHint)
        external
        onlyOrgOperator(orgId)
    {
        // allowed=false is an EXPLICIT DENY (also blocks the global fallback for Mirror orgs);
        // clearRule resets the pair to the protocol default instead. See PaymasterRuleLib.
        PaymasterRuleLib.writeLocalRule(orgId, target, selector, allowed, maxCallGasHint);
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
        PaymasterRuleLib.writeLocalRulesBatch(orgId, targets, selectors, allowed, maxCallGasHints);
    }

    // ============ Global Rulebook (see PaymasterRuleLib) ============

    /// @notice Set or remove protocol-wide rulebook entries keyed by (module typeId, selector)
    /// @dev poaManager/protocolAdmin gated (inside the lib). One entry covers the matching module
    ///      of every Mirror-mode org — replaces per-org adminBatchAddRules fan-outs.
    function setGlobalRulesBatch(
        bytes32[] calldata typeIds,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) external {
        PaymasterRuleLib.setGlobalRulesBatch(typeIds, selectors, allowed, maxCallGasHints);
    }

    /// @notice Map an org's target addresses to module typeIds for global rule resolution
    /// @dev Org admin/operator/poaManager gated (inside the lib); bytes32(0) clears an entry
    function setTargetTypesBatch(bytes32 orgId, address[] calldata targets, bytes32[] calldata typeIds) external {
        PaymasterRuleLib.setTargetTypesBatch(orgId, targets, typeIds);
    }

    /// @notice Switch an org between Mirror (0, follow global rulebook) and Static (1, local only)
    /// @dev Org admin/operator/poaManager gated (inside the lib)
    function setRulesMode(bytes32 orgId, uint8 mode) external {
        PaymasterRuleLib.setRulesMode(orgId, mode);
    }

    /// @notice Block or unblock a single global rule for an org without leaving Mirror mode
    /// @dev Org admin/operator/poaManager gated (inside the lib)
    function setGlobalRuleBlock(bytes32 orgId, address target, bytes4 selector, bool blocked) external {
        PaymasterRuleLib.setGlobalRuleBlock(orgId, target, selector, blocked);
    }

    /// @notice Copy specific current global rulebook entries into the org's local rules
    /// @dev Org admin/operator/poaManager gated (inside the lib)
    function adoptGlobalRules(bytes32 orgId, address[] calldata targets, bytes4[] calldata selectors) external {
        PaymasterRuleLib.adoptGlobalRules(orgId, targets, selectors);
    }

    /// @notice Copy all applicable global rulebook entries into the org's local rules
    /// @dev Org admin/operator/poaManager gated (inside the lib)
    function snapshotGlobalRules(bytes32 orgId, address[] calldata targets) external {
        PaymasterRuleLib.snapshotGlobalRules(orgId, targets);
    }

    /// @notice Batch-add rules across orgs. Skips unregistered orgs.
    /// @dev L-29: enforce equal array lengths (mismatched inputs would silently pair the wrong
    ///      (target, selector) with an org or panic on OOB) and reject a zero target (which would
    ///      register a sponsorship rule for address(0)). protocolAdmin==0 (the appended-field
    ///      default on orgs that never set it) can never authorize because msg.sender is nonzero.
    function adminBatchAddRules(bytes32[] calldata orgIds, address[] calldata targets, bytes4[] calldata selectors)
        external
    {
        MainStorage storage m = _getMainStorage();
        if (msg.sender != m.poaManager && msg.sender != m.protocolAdmin) revert PaymasterHubErrors.NotOperator();
        uint256 len = orgIds.length;
        if (len != targets.length || len != selectors.length) revert PaymasterHubErrors.ArrayLengthMismatch();
        for (uint256 i; i < len;) {
            if (targets[i] == address(0)) revert PaymasterHubErrors.ZeroAddress();
            if (_getOrgsStorage()[orgIds[i]].adminHatId != 0) {
                // Routed through the lib writer so the write EMITS RuleSet (the old inline write
                // was event-less — subgraph-invisible state) and shares the allow semantics
                // (a fresh allow clears any standing global-rule block for the pair).
                PaymasterRuleLib.writeLocalRule(orgIds[i], targets[i], selectors[i], true, 0);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Clear a rule for target/selector combination
     */
    function clearRule(bytes32 orgId, address target, bytes4 selector) external onlyOrgOperator(orgId) {
        // Resets the pair to the protocol default: deletes the local rule AND any standing
        // block, so a Mirror org falls back to the global rulebook afterwards.
        PaymasterRuleLib.clearLocalRule(orgId, target, selector);
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
     * @notice Deposit funds to the EntryPoint and credit the org's tracked balance (M-12)
     * @dev Previously this forwarded to `EntryPoint.depositTo` without ever crediting the org,
     *      so the ETH silently joined the shared pool and could not be withdrawn or matched to
     *      the org that funded it. It now routes through `_depositForOrg`, so the deposit is
     *      tracked under `orgId` (increments `deposited`, runs the period-reset logic) and is
     *      recoverable via `withdrawOrgDeposit`. Any org operator can top up their own org.
     */
    function depositToEntryPoint(bytes32 orgId) external payable onlyOrgOperator(orgId) {
        if (msg.value == 0) revert PaymasterHubErrors.ZeroAmount();
        _depositForOrg(orgId, msg.value);
    }

    /**
     * @notice Withdraw an org's unspent deposit back out of the EntryPoint (M-04)
     * @dev Org-admin gated, bounded by `deposited - spent`, reentrancy-guarded. Delegates to
     *      PaymasterAdminLib to keep the hub under the EIP-170 size limit. The library updates
     *      `deposited` before calling `EntryPoint.withdrawTo`, so state is settled before the
     *      external transfer.
     * @param orgId The organization whose deposit is being withdrawn
     * @param to Recipient of the withdrawn ETH
     * @param amount Amount to withdraw (must not exceed `deposited - spent`)
     */
    function withdrawOrgDeposit(bytes32 orgId, address payable to, uint256 amount) external nonReentrant {
        PaymasterAdminLib.withdrawOrgDeposit(orgId, to, amount);
    }

    /**
     * @notice Emergency/solidarity withdraw from the EntryPoint deposit (M-04)
     * @dev PoaManager-gated, bounded by the solidarity fund balance so it can never touch an
     *      org's tracked deposit. Reentrancy-guarded. Delegates to PaymasterAdminLib. A future
     *      governance upgrade can re-gate this to the DAO.
     * @param to Recipient of the withdrawn ETH
     * @param amount Amount to withdraw (must not exceed the solidarity balance)
     */
    function withdrawSolidarity(address payable to, uint256 amount) external nonReentrant {
        PaymasterAdminLib.withdrawSolidarity(to, amount);
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
     * @notice Repoint the hub's hats pointer to the AuthorityRouter (Access v2 §4.8 / §6 step 0.3).
     * @dev The `hats` slot is written only at {initialize} today (no setter) — without this, the
     *      router bind is unexecutable. Validation semantics stay byte-identical: the existing
     *      `IHats(hats).isWearerOfHat(...)` / `isEligible` / `viewHat` calls simply resolve through
     *      the router once repointed. poaManager/protocolAdmin gated (mirrors {setSolidarityFee}).
     *      Emits HatsSet.
     * @param newHats The new hats surface (the AuthorityRouter, or a legacy Hats address for rollback).
     */
    function setHats(address newHats) external {
        MainStorage storage m = _getMainStorage();
        if (msg.sender != m.poaManager && msg.sender != m.protocolAdmin) revert PaymasterHubErrors.NotOperator();
        if (newHats == address(0)) revert PaymasterHubErrors.ZeroAddress();
        m.hats = newHats;
        emit PaymasterHubErrors.HatsSet(newHats);
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
     * @notice Get a global rulebook entry for a (module typeId, selector) pair
     * @param typeId Module type identifier (keccak256 of the type name, per ModuleTypes)
     * @param selector The function selector
     * @return The Rule struct
     */
    function getGlobalRule(bytes32 typeId, bytes4 selector) external view returns (Rule memory) {
        return _getGlobalRulesStorage()[typeId][selector];
    }

    /**
     * @notice Number of entries currently in the global rulebook
     */
    function getGlobalRuleCount() external view returns (uint256) {
        return _getGlobalRuleKeysStorage().keys.length;
    }

    /**
     * @notice Enumerate the global rulebook
     * @param index Position in the enumeration (0-based, unordered, changes on removal)
     * @return typeId Module type identifier
     * @return selector Function selector
     * @return rule The Rule struct for the entry
     */
    function getGlobalRuleAt(uint256 index) external view returns (bytes32 typeId, bytes4 selector, Rule memory rule) {
        PaymasterRuleLib.GlobalRuleKey storage key = _getGlobalRuleKeysStorage().keys[index];
        typeId = key.typeId;
        selector = key.selector;
        rule = _getGlobalRulesStorage()[typeId][selector];
    }

    /**
     * @notice Get the module typeId registered for an org's target address (bytes32(0) = none)
     */
    function getTargetType(bytes32 orgId, address target) external view returns (bytes32) {
        return _getTargetTypesStorage()[orgId][target];
    }

    /**
     * @notice Get an org's rules mode (0 = Mirror: local + global rulebook; 1 = Static: local only)
     */
    function getRulesMode(bytes32 orgId) external view returns (uint8) {
        return _getRulesModesStorage()[orgId];
    }

    /**
     * @notice Whether an org has vetoed the global rule for (target, selector)
     */
    function isGlobalRuleBlocked(bytes32 orgId, address target, bytes4 selector) external view returns (bool) {
        return _getGlobalRuleBlocksStorage()[orgId][target][selector];
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

    function _getGlobalRulesStorage() private pure returns (mapping(bytes32 => mapping(bytes4 => Rule)) storage $) {
        bytes32 slot = GLOBAL_RULES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getGlobalRuleKeysStorage() private pure returns (PaymasterRuleLib.GlobalRulesEnum storage $) {
        bytes32 slot = GLOBAL_RULE_KEYS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getTargetTypesStorage() private pure returns (mapping(bytes32 => mapping(address => bytes32)) storage $) {
        bytes32 slot = TARGET_TYPES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getRulesModesStorage() private pure returns (mapping(bytes32 => uint8) storage $) {
        bytes32 slot = RULES_MODES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _getGlobalRuleBlocksStorage()
        private
        pure
        returns (mapping(bytes32 => mapping(address => mapping(bytes4 => bool))) storage $)
    {
        bytes32 slot = GLOBAL_RULE_BLOCKS_STORAGE_LOCATION;
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

    // NOTE: rule validation (_validateRules / _validateBatchRules / _extractTargetSelector)
    // moved to PaymasterRuleLib (delegatecall) together with the new global-rulebook fallback
    // resolution — see PaymasterRuleLib.validateRules. Keeping hub copies would be dead code.

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
        // cost in PaymasterFinanceLib.updateUsageAndFinancials during postOp.
        budget.usedInEpoch += uint128(maxCost);

        currentEpochStart = budget.epochStart;
    }

    // NOTE (M-05 / zk-email merge): all three postOp accounting helpers moved into delegatecall
    // libraries for EIP-170 headroom, and the merged postOp dispatches to them directly:
    //   - regular org op (and SUBJECT_TYPE_CLAIM 0x05) -> PaymasterFinanceLib.updateUsageAndFinancials
    //     (per-subject budget adjust + org financial split + M-05 solidarity unreservation)
    //   - POA onboarding  -> PaymasterSponsorshipLib.updateOnboardingUsage
    //   - free org deploy -> PaymasterSponsorshipLib.updateOrgDeployUsage
    // The former hub-local _updateUsage / _updateOnboardingUsage / _updateOrgDeployUsage now live in
    // those libraries; keeping hub copies would be dead code (and re-adding a second accounting call
    // on any path would double-count spend).
}
