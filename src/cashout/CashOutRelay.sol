// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/// @title CashOutRelay
/// @notice Receives USDC from Bungee bridge on Base and creates a ZKP2P deposit
///         owned by the user. One-click cashout: user sends USDC on Arbitrum,
///         relay creates a P2P sell order on Base, user receives fiat to Venmo.
/// @dev Implements IBungeeExecutor interface for destination payload execution.
///      Uses EscrowV2.depositTo() so the user owns the deposit directly.
///      Security: verifies actual USDC delivery via balance snapshot to prevent
///      theft of held funds from failed deposits.
///
///      Storage: migrated from sequential slots + `uint256[44] __gap` to ERC-7201
///      namespaced storage (audit L-45). Ownership migrated from a hand-rolled
///      `address public owner` to OZ `Ownable2StepUpgradeable` (audit L-46).
///      The upgrade that first introduces this layout MUST call `migrateToV2`
///      (reinitializer(2)) so live proxy state is copied from the old sequential
///      slots into the new namespace — see the OLD-SLOT -> NEW-FIELD table below.
contract CashOutRelay is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /*══════════════════════════════════ STRUCTS ══════════════════════════════════*/

    /// @dev Mirrors IEscrowV2.Range
    struct Range {
        uint256 min;
        uint256 max;
    }

    /// @dev Mirrors IEscrowV2.OracleRateConfig
    struct OracleRateConfig {
        address adapter;
        bytes adapterConfig;
        int16 spreadBps;
        uint32 maxStaleness;
    }

    /// @dev Mirrors IEscrowV2.Currency
    struct Currency {
        bytes32 code;
        uint256 minConversionRate;
        OracleRateConfig oracleRateConfig;
    }

    /// @dev Mirrors IEscrowV2.DepositPaymentMethodData
    struct DepositPaymentMethodData {
        address intentGatingService;
        bytes32 payeeDetails;
        bytes data;
    }

    /// @dev Mirrors IEscrowV2.CreateDepositParams
    struct CreateDepositParams {
        IERC20 token;
        uint256 amount;
        Range intentAmountRange;
        bytes32[] paymentMethods;
        DepositPaymentMethodData[] paymentMethodData;
        Currency[][] currencies;
        address delegate;
        address intentGuardian;
        bool retainOnEmpty;
    }

    /// @dev Decoded from the Bungee destination payload
    struct CashOutParams {
        address depositor;
        bytes32 paymentMethod;
        bytes32 payeeDetailsHash;
        bytes32 fiatCurrency;
        uint256 conversionRate;
        uint256 minIntentAmount;
        uint256 maxIntentAmount;
    }

    /*══════════════════════════════════ ERRORS ══════════════════════════════════*/

    error WrongToken(address received, address expected);
    error ZeroAmount();
    error ZeroDepositor();
    error NoPendingRecovery();
    error NotOwner();
    error InsufficientDelivery(uint256 expected, uint256 received);
    error RequestHashAlreadyFailed();
    error ZeroAddress();
    error NotAuthorizedExecutor();
    error WouldDrainRecoveryFunds();
    error ETHTransferFailed();
    error OnlySelf();

    /*══════════════════════════════════ EVENTS ══════════════════════════════════*/

    event CashOutDeposited(
        address indexed depositor, bytes32 indexed requestHash, uint256 amount, bytes32 paymentMethod
    );
    event CashOutFailed(address indexed depositor, bytes32 indexed requestHash, uint256 amount, bytes reason);
    event TokensRecovered(address indexed to, address indexed token, uint256 amount);
    event BungeeExecutorSet(address indexed previousExecutor, address indexed newExecutor);

    /*══════════════════════════════════ ERC-7201 STORAGE ══════════════════════════════════*/

    /// @custom:storage-location erc7201:poa.cashoutrelay.storage
    struct Layout {
        // EscrowV2 on Base
        address escrow;
        // USDC on Base
        address usdc;
        // CCTP MessageTransmitter on Base (for receiving CCTP messages)
        address cctpMessageTransmitter;
        // Trusted Bungee executor/inbox address permitted to call executeData (audit H-01)
        address bungeeExecutor;
        // Monotonic per-contract nonce backing createDepositFromBalance requestHash (audit M-16)
        uint256 depositNonce;
        // Tracks failed deposits for user recovery: requestHash → (depositor, amount)
        mapping(bytes32 => address) failedDepositor;
        mapping(bytes32 => uint256) failedAmount;
        // Total USDC held for failed deposit recovery. Prevents emergencyRecover from
        // draining user funds and prevents executeData from using held funds.
        uint256 totalFailedAmount;
    }

    // keccak256("poa.cashoutrelay.storage")
    bytes32 private constant _STORAGE_SLOT = 0x5e1d474c2191273291863dae5eebbfef4e74420e222e3e07d1ee3a5353725436;

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*══════════════════════════════════ OLD-SLOT -> NEW-FIELD MIGRATION MAP ══════════════════════════════════*/
    //
    // Pre-migration (sequential) layout of the LIVE Base proxy
    // 0xA65414A21dc114199cAfD7c6c3ed99488Eb9eFE5, verified via `cast storage`:
    //
    //   OLD SLOT | OLD FIELD                        | NEW DESTINATION
    //   ---------+---------------------------------+----------------------------------------------
    //   slot 0   | address escrow                   | Layout.escrow
    //   slot 1   | address usdc                     | Layout.usdc
    //   slot 2   | address owner (hand-rolled)      | OwnableUpgradeable namespace via _transferOwnership
    //   slot 3   | address cctpMessageTransmitter   | Layout.cctpMessageTransmitter
    //   slot 4   | mapping failedDepositor (base)   | Layout.failedDepositor  (*see note)
    //   slot 5   | mapping failedAmount (base)      | Layout.failedAmount     (*see note)
    //   slot 6   | uint256 totalFailedAmount        | Layout.totalFailedAmount
    //   slot 7   | uint256[44] __gap                | (dropped — reclaimed by ERC-7201 namespace)
    //
    //   New fields (start empty, no old source): Layout.bungeeExecutor, Layout.depositNonce.
    //
    //   (*) MAPPINGS: mapping VALUES live at keccak256(key . mappingBaseSlot). Moving the base
    //   slot (4/5 -> new namespaced offsets) rehomes every entry, so live failed-deposit records
    //   would NOT follow automatically. This is SAFE for this specific migration because the live
    //   proxy has ZERO failed-deposit entries: `totalFailedAmount == 0` and NO `CashOutFailed`
    //   event has ever been emitted (verified on Base, 2026-07-04). migrateToV2 therefore requires
    //   totalFailedAmount == 0 at migration time and reverts otherwise, so no depositor's recovery
    //   funds can ever be orphaned by the rehome. If a future upgrade must migrate with live failed
    //   deposits, it has to enumerate and re-key them explicitly — this guard makes that impossible
    //   to forget.

    /*══════════════════════════════════ VIEWS (ABI-compatible getters) ══════════════════════════════════*/

    /// @notice EscrowV2 on Base
    function escrow() external view returns (address) {
        return _layout().escrow;
    }

    /// @notice USDC on Base
    function usdc() external view returns (address) {
        return _layout().usdc;
    }

    /// @notice CCTP MessageTransmitter on Base
    function cctpMessageTransmitter() external view returns (address) {
        return _layout().cctpMessageTransmitter;
    }

    /// @notice Trusted Bungee executor address permitted to call executeData (audit H-01)
    function bungeeExecutor() external view returns (address) {
        return _layout().bungeeExecutor;
    }

    /// @notice Monotonic deposit nonce backing createDepositFromBalance requestHash (audit M-16)
    function depositNonce() external view returns (uint256) {
        return _layout().depositNonce;
    }

    /// @notice Depositor address recorded for a failed request hash
    function failedDepositor(bytes32 requestHash) external view returns (address) {
        return _layout().failedDepositor[requestHash];
    }

    /// @notice USDC amount held for recovery for a failed request hash
    function failedAmount(bytes32 requestHash) external view returns (uint256) {
        return _layout().failedAmount[requestHash];
    }

    /// @notice Total USDC held across all failed-deposit recoveries
    function totalFailedAmount() external view returns (uint256) {
        return _layout().totalFailedAmount;
    }

    /*══════════════════════════════════ INTERFACE ══════════════════════════════════*/

    /// @dev IBungeeExecutor interface. Called by Bungee after bridge completes.
    ///      Gated to the trusted Bungee executor (or owner) so an attacker cannot
    ///      redirect freshly-bridged, not-yet-assigned USDC to an attacker-owned
    ///      ZKP2P deposit (audit H-01). Verifies actual USDC delivery via balance
    ///      snapshot and reconciles against the real received amount (audit L-47).
    ///      ASSUMPTION: bridge delivery and this call are atomic (Bungee delivers
    ///      and calls executeData in the same transaction). If USDC ever lands
    ///      between two calls (e.g. a manual transfer), the sweep below absorbs it
    ///      into the in-flight deposit — do not adopt a non-atomic delivery flow.
    function executeData(
        bytes32 requestHash,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes calldata callData
    ) external payable nonReentrant {
        Layout storage l = _layout();

        // H-01: only the trusted Bungee executor (or owner) may drive deposit creation.
        if (msg.sender != l.bungeeExecutor && msg.sender != owner()) revert NotAuthorizedExecutor();

        if (amounts.length == 0 || amounts[0] == 0) revert ZeroAmount();
        if (tokens.length == 0 || tokens[0] != l.usdc) {
            revert WrongToken(tokens.length > 0 ? tokens[0] : address(0), l.usdc);
        }

        CashOutParams memory params = abi.decode(callData, (CashOutParams));
        if (params.depositor == address(0)) revert ZeroDepositor();

        uint256 expectedAmount = amounts[0];

        // Verify actual USDC delivery: only use freshly-delivered funds, not held recovery funds.
        // Available = total balance minus what's reserved for failed deposit recoveries.
        uint256 available = IERC20(l.usdc).balanceOf(address(this)) - l.totalFailedAmount;
        if (available < expectedAmount) revert InsufficientDelivery(expectedAmount, available);

        // L-47: reconcile the claimed amount against the actual delivered balance. The bridge
        // may over-deliver (slippage buffer); depositing only `amounts[0]` would leave the surplus
        // untracked and drainable. Use the full freshly-delivered balance so nothing is stranded.
        uint256 amount = available;

        // Try to create ZKP2P deposit owned by the user
        try this.createZkp2pDeposit(params, amount) {
            emit CashOutDeposited(params.depositor, requestHash, amount, params.paymentMethod);
        } catch (bytes memory reason) {
            // Prevent requestHash collision — don't overwrite prior failed deposit
            if (l.failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();

            // Hold USDC for recovery — don't let Bungee execution revert
            l.failedDepositor[requestHash] = params.depositor;
            l.failedAmount[requestHash] = amount;
            l.totalFailedAmount += amount;
            emit CashOutFailed(params.depositor, requestHash, amount, reason);
        }
    }

    /// @notice Called via try/catch from executeData. External so try/catch works.
    /// @dev Not intended for direct calls — guarded by msg.sender == address(this).
    ///      Pins `intentAmountRange.min == max == amount` so the deposit can only
    ///      be filled in full. Prevents partial fills from leaving sub-min dust
    ///      that no taker is incentivized to clear (gas + per-Venmo-tx overhead
    ///      makes <$1 fills uneconomical and the residue gets stuck until the
    ///      depositor manually withdraws it).
    ///      `params.minIntentAmount` and `params.maxIntentAmount` are deliberately
    ///      ignored here — the relay is the only thing that knows the actual
    ///      delivered amount post-bridge slippage and is the only place that can
    ///      pin the range correctly. The fields remain in CashOutParams for ABI
    ///      compatibility with frontends that haven't redeployed yet.
    function createZkp2pDeposit(CashOutParams calldata params, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();

        Layout storage l = _layout();
        IERC20 token = IERC20(l.usdc);

        // Approve escrow to pull USDC
        token.forceApprove(l.escrow, amount);

        // Build the deposit params
        bytes32[] memory paymentMethods = new bytes32[](1);
        paymentMethods[0] = params.paymentMethod;

        DepositPaymentMethodData[] memory paymentMethodData = new DepositPaymentMethodData[](1);
        paymentMethodData[0] = DepositPaymentMethodData({
            intentGatingService: address(0), // no gating
            payeeDetails: params.payeeDetailsHash,
            data: "" // no additional verification data
        });

        // No oracle — fixed rate
        OracleRateConfig memory noOracle =
            OracleRateConfig({adapter: address(0), adapterConfig: "", spreadBps: 0, maxStaleness: 0});

        Currency[][] memory currencies = new Currency[][](1);
        currencies[0] = new Currency[](1);
        currencies[0][0] =
            Currency({code: params.fiatCurrency, minConversionRate: params.conversionRate, oracleRateConfig: noOracle});

        CreateDepositParams memory depositParams = CreateDepositParams({
            token: token,
            amount: amount,
            intentAmountRange: Range({min: amount, max: amount}), // full-fill only — see fn-level dev note
            paymentMethods: paymentMethods,
            paymentMethodData: paymentMethodData,
            currencies: currencies,
            delegate: address(0),
            intentGuardian: address(0),
            retainOnEmpty: false
        });

        // Create deposit owned by the user — escrow pulls USDC from this contract
        IEscrowV2Minimal(l.escrow).depositTo(params.depositor, depositParams);
    }

    /*══════════════════════════════════ CCTP ENTRY ══════════════════════════════════*/

    /// @notice Complete a cashout initiated via CCTP. Owner-only to prevent front-running
    ///         attacks where an attacker substitutes CashOutParams for a valid CCTP message.
    ///         The CCTP message specifies mintRecipient but not the Venmo details, so the
    ///         params must be supplied by a trusted caller.
    /// @param cctpMessage  The CCTP message bytes from the source chain burn
    /// @param attestation  Circle's attestation signature for the message
    /// @param params       Cashout parameters (depositor, Venmo details, rate, etc.)
    function completeCashOut(bytes calldata cctpMessage, bytes calldata attestation, CashOutParams calldata params)
        external
        nonReentrant
        onlyOwner
    {
        if (params.depositor == address(0)) revert ZeroDepositor();

        Layout storage l = _layout();
        uint256 balanceBefore = IERC20(l.usdc).balanceOf(address(this));

        // Receive CCTP message — mints USDC to this contract
        IMessageTransmitter(l.cctpMessageTransmitter).receiveMessage(cctpMessage, attestation);

        uint256 balanceAfter = IERC20(l.usdc).balanceOf(address(this));
        uint256 minted = balanceAfter - balanceBefore;
        if (minted == 0) revert ZeroAmount();

        // Create ZKP2P deposit with the minted USDC
        bytes32 requestHash = keccak256(cctpMessage);
        try this.createZkp2pDeposit(params, minted) {
            emit CashOutDeposited(params.depositor, requestHash, minted, params.paymentMethod);
        } catch (bytes memory reason) {
            if (l.failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();
            l.failedDepositor[requestHash] = params.depositor;
            l.failedAmount[requestHash] = minted;
            l.totalFailedAmount += minted;
            emit CashOutFailed(params.depositor, requestHash, minted, reason);
        }
    }

    /*══════════════════════════════════ MANUAL TRIGGER ══════════════════════════════════*/

    /// @notice Create a ZKP2P deposit using USDC already in the relay.
    ///         Used when bridge delivers USDC without calling executeData
    ///         (e.g., Bungee depositRoute, direct transfer, or CCTP mint).
    ///         Owner-only to prevent unauthorized deposit creation.
    /// @dev M-16: requestHash is derived from a monotonic per-contract nonce rather than
    ///      `block.timestamp` — two same-block owner calls now get distinct hashes and the
    ///      weak, collidable `keccak256(depositor, block.timestamp)` preimage is retired.
    function createDepositFromBalance(CashOutParams calldata params) external nonReentrant onlyOwner {
        if (params.depositor == address(0)) revert ZeroDepositor();

        Layout storage l = _layout();
        uint256 available = IERC20(l.usdc).balanceOf(address(this)) - l.totalFailedAmount;
        if (available == 0) revert ZeroAmount();

        // M-16: monotonic nonce → collision-free requestHash, bound to this contract.
        uint256 nonce = l.depositNonce;
        l.depositNonce = nonce + 1;
        bytes32 requestHash = keccak256(abi.encode(address(this), params.depositor, nonce));

        try this.createZkp2pDeposit(params, available) {
            emit CashOutDeposited(params.depositor, requestHash, available, params.paymentMethod);
        } catch (bytes memory reason) {
            if (l.failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();
            l.failedDepositor[requestHash] = params.depositor;
            l.failedAmount[requestHash] = available;
            l.totalFailedAmount += available;
            emit CashOutFailed(params.depositor, requestHash, available, reason);
        }
    }

    /*══════════════════════════════════ RECOVERY ══════════════════════════════════*/

    /// @notice Recover USDC from a failed deposit. Only the original depositor can call.
    function recoverFailed(bytes32 requestHash) external nonReentrant {
        Layout storage l = _layout();
        address depositor = l.failedDepositor[requestHash];
        uint256 amount = l.failedAmount[requestHash];

        if (depositor == address(0) || amount == 0) revert NoPendingRecovery();
        if (msg.sender != depositor) revert NotOwner();

        delete l.failedDepositor[requestHash];
        delete l.failedAmount[requestHash];
        l.totalFailedAmount -= amount;

        IERC20(l.usdc).safeTransfer(depositor, amount);
        emit TokensRecovered(depositor, l.usdc, amount);
    }

    /*══════════════════════════════════ ADMIN ══════════════════════════════════*/

    /// @notice One-time initializer for fresh deployments. Live proxies use `migrateToV2`.
    function initialize(address _escrow, address _usdc, address _cctpMessageTransmitter, address _owner)
        external
        initializer
    {
        if (_owner == address(0)) revert ZeroAddress();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        Layout storage l = _layout();
        l.escrow = _escrow;
        l.usdc = _usdc;
        l.cctpMessageTransmitter = _cctpMessageTransmitter;
    }

    /// @notice Upgrade migration for the LIVE Base proxy (pre-ERC-7201, hand-rolled owner).
    ///         Copies every live field from its OLD sequential slot into the new ERC-7201
    ///         Layout and hands ownership to Ownable2StepUpgradeable. Runs exactly once via
    ///         `upgradeToAndCall(newImpl, abi.encodeCall(CashOutRelay.migrateToV2, ()))`, so
    ///         the proxy is never left half-migrated. Guarded by reinitializer(2) — the live
    ///         proxy's `_initialized` is 1 (verified on Base), so N=2 is the next free slot
    ///         and re-running the migration reverts (InvalidInitialization).
    /// @dev See the OLD-SLOT -> NEW-FIELD MIGRATION MAP above. Requires totalFailedAmount == 0
    ///      so no live failed-deposit mapping entries are orphaned by the base-slot rehome.
    function migrateToV2() external reinitializer(2) {
        // Raw reads from the OLD sequential storage slots (pre-migration layout).
        address oldEscrow = StorageSlot.getAddressSlot(bytes32(uint256(0))).value;
        address oldUsdc = StorageSlot.getAddressSlot(bytes32(uint256(1))).value;
        address oldOwner = StorageSlot.getAddressSlot(bytes32(uint256(2))).value;
        address oldCctp = StorageSlot.getAddressSlot(bytes32(uint256(3))).value;
        uint256 oldTotalFailed = StorageSlot.getUint256Slot(bytes32(uint256(6))).value;

        if (oldOwner == address(0)) revert ZeroAddress();
        // Refuse to migrate if any recovery funds are outstanding — the mapping base-slot rehome
        // would orphan them (see MIGRATION MAP note). The live proxy has none (verified).
        if (oldTotalFailed != 0) revert WouldDrainRecoveryFunds();

        // Initialize the new-layout OZ mixins (their namespaces are disjoint from slots 0-7).
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Ownable_init(oldOwner); // L-46: hand-rolled owner -> Ownable2Step, preserving the same owner

        // Copy scalar state into the ERC-7201 Layout.
        Layout storage l = _layout();
        l.escrow = oldEscrow;
        l.usdc = oldUsdc;
        l.cctpMessageTransmitter = oldCctp;
        l.totalFailedAmount = oldTotalFailed; // == 0 by the guard above
        // l.bungeeExecutor and l.depositNonce intentionally start at their zero defaults;
        // the owner must call setBungeeExecutor post-upgrade to enable executeData.

        // Zero the stale hand-rolled owner slot (slot 2) so the old getter can't report a
        // ghost owner if anything still reads it before the ABI getter takes over.
        StorageSlot.getAddressSlot(bytes32(uint256(2))).value = address(0);
    }

    /// @notice Set the trusted Bungee executor permitted to call executeData (audit H-01).
    /// @param _bungeeExecutor The Bungee destination executor/inbox address. Non-zero.
    function setBungeeExecutor(address _bungeeExecutor) external onlyOwner {
        if (_bungeeExecutor == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        emit BungeeExecutorSet(l.bungeeExecutor, _bungeeExecutor);
        l.bungeeExecutor = _bungeeExecutor;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Emergency: recover tokens accidentally sent to this contract.
    ///         For USDC, enforces that user recovery funds are not drained.
    function emergencyRecover(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        Layout storage l = _layout();

        // Protect user recovery funds: owner cannot withdraw USDC below totalFailedAmount
        if (token == l.usdc) {
            uint256 balance = IERC20(l.usdc).balanceOf(address(this));
            if (balance < amount || balance - amount < l.totalFailedAmount) revert WouldDrainRecoveryFunds();
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Withdraw any ETH accidentally sent (e.g., by Bungee with the executor call)
    function withdrawETH(address to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert ETHTransferFailed();
    }

    /// @notice Accept ETH — some bridges send dust ETH with executor callbacks
    receive() external payable {}

    constructor() {
        _disableInitializers();
    }
}

/// @dev Minimal interface for EscrowV2.depositTo
interface IEscrowV2Minimal {
    function depositTo(address _depositor, CashOutRelay.CreateDepositParams calldata _params) external;
}

/// @dev Minimal interface for CCTP MessageTransmitter
interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}
