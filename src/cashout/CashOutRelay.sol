// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
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
contract CashOutRelay is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
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

    /*══════════════════════════════════ EVENTS ══════════════════════════════════*/

    event CashOutDeposited(
        address indexed depositor, bytes32 indexed requestHash, uint256 amount, bytes32 paymentMethod
    );
    event CashOutFailed(address indexed depositor, bytes32 indexed requestHash, uint256 amount, bytes reason);
    event TokensRecovered(address indexed to, address indexed token, uint256 amount);

    /*══════════════════════════════════ STORAGE ══════════════════════════════════*/

    /// @dev EscrowV2 on Base
    address public escrow;

    /// @dev USDC on Base
    address public usdc;

    /// @dev Contract owner (for upgrades + emergency)
    address public owner;

    /// @dev CCTP MessageTransmitter on Base (for receiving CCTP messages)
    address public cctpMessageTransmitter;

    /// @dev Tracks failed deposits for user recovery: requestHash → (depositor, amount)
    mapping(bytes32 => address) public failedDepositor;
    mapping(bytes32 => uint256) public failedAmount;

    /// @dev Total USDC held for failed deposit recovery. Prevents emergencyRecover from
    ///      draining user funds and prevents executeData from using held funds.
    uint256 public totalFailedAmount;

    /*══════════════════════════════════ INTERFACE ══════════════════════════════════*/

    /// @dev IBungeeExecutor interface. Called by Bungee after bridge completes.
    ///      Verifies actual USDC delivery via balance snapshot to prevent theft.
    function executeData(
        bytes32 requestHash,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes calldata callData
    ) external payable nonReentrant {
        if (amounts.length == 0 || amounts[0] == 0) revert ZeroAmount();
        if (tokens.length == 0 || tokens[0] != usdc) {
            revert WrongToken(tokens.length > 0 ? tokens[0] : address(0), usdc);
        }

        CashOutParams memory params = abi.decode(callData, (CashOutParams));
        if (params.depositor == address(0)) revert ZeroDepositor();

        uint256 expectedAmount = amounts[0];

        // Verify actual USDC delivery: only use freshly-delivered funds, not held recovery funds.
        // Available = total balance minus what's reserved for failed deposit recoveries.
        uint256 available = IERC20(usdc).balanceOf(address(this)) - totalFailedAmount;
        if (available < expectedAmount) revert InsufficientDelivery(expectedAmount, available);

        // Use the actual available amount (in case bridge delivered slightly more/less)
        uint256 amount = expectedAmount;

        // Try to create ZKP2P deposit owned by the user
        try this.createZkp2pDeposit(params, amount) {
            emit CashOutDeposited(params.depositor, requestHash, amount, params.paymentMethod);
        } catch (bytes memory reason) {
            // Prevent requestHash collision — don't overwrite prior failed deposit
            if (failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();

            // Hold USDC for recovery — don't let Bungee execution revert
            failedDepositor[requestHash] = params.depositor;
            failedAmount[requestHash] = amount;
            totalFailedAmount += amount;
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
        require(msg.sender == address(this), "only self");

        IERC20 token = IERC20(usdc);

        // Approve escrow to pull USDC
        token.forceApprove(escrow, amount);

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
        IEscrowV2Minimal(escrow).depositTo(params.depositor, depositParams);
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
    {
        if (msg.sender != owner) revert NotOwner();
        if (params.depositor == address(0)) revert ZeroDepositor();

        uint256 balanceBefore = IERC20(usdc).balanceOf(address(this));

        // Receive CCTP message — mints USDC to this contract
        IMessageTransmitter(cctpMessageTransmitter).receiveMessage(cctpMessage, attestation);

        uint256 balanceAfter = IERC20(usdc).balanceOf(address(this));
        uint256 minted = balanceAfter - balanceBefore;
        if (minted == 0) revert ZeroAmount();

        // Create ZKP2P deposit with the minted USDC
        bytes32 requestHash = keccak256(cctpMessage);
        try this.createZkp2pDeposit(params, minted) {
            emit CashOutDeposited(params.depositor, requestHash, minted, params.paymentMethod);
        } catch (bytes memory reason) {
            if (failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();
            failedDepositor[requestHash] = params.depositor;
            failedAmount[requestHash] = minted;
            totalFailedAmount += minted;
            emit CashOutFailed(params.depositor, requestHash, minted, reason);
        }
    }

    /*══════════════════════════════════ MANUAL TRIGGER ══════════════════════════════════*/

    /// @notice Create a ZKP2P deposit using USDC already in the relay.
    ///         Used when bridge delivers USDC without calling executeData
    ///         (e.g., Bungee depositRoute, direct transfer, or CCTP mint).
    ///         Owner-only to prevent unauthorized deposit creation.
    function createDepositFromBalance(CashOutParams calldata params) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        if (params.depositor == address(0)) revert ZeroDepositor();

        uint256 available = IERC20(usdc).balanceOf(address(this)) - totalFailedAmount;
        if (available == 0) revert ZeroAmount();

        bytes32 requestHash = keccak256(abi.encode(params.depositor, block.timestamp));
        try this.createZkp2pDeposit(params, available) {
            emit CashOutDeposited(params.depositor, requestHash, available, params.paymentMethod);
        } catch (bytes memory reason) {
            if (failedDepositor[requestHash] != address(0)) revert RequestHashAlreadyFailed();
            failedDepositor[requestHash] = params.depositor;
            failedAmount[requestHash] = available;
            totalFailedAmount += available;
            emit CashOutFailed(params.depositor, requestHash, available, reason);
        }
    }

    /*══════════════════════════════════ RECOVERY ══════════════════════════════════*/

    /// @notice Recover USDC from a failed deposit. Only the original depositor can call.
    function recoverFailed(bytes32 requestHash) external nonReentrant {
        address depositor = failedDepositor[requestHash];
        uint256 amount = failedAmount[requestHash];

        if (depositor == address(0) || amount == 0) revert NoPendingRecovery();
        if (msg.sender != depositor) revert NotOwner();

        delete failedDepositor[requestHash];
        delete failedAmount[requestHash];
        totalFailedAmount -= amount;

        IERC20(usdc).safeTransfer(depositor, amount);
        emit TokensRecovered(depositor, usdc, amount);
    }

    /*══════════════════════════════════ ADMIN ══════════════════════════════════*/

    function initialize(address _escrow, address _usdc, address _cctpMessageTransmitter, address _owner)
        external
        initializer
    {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        escrow = _escrow;
        usdc = _usdc;
        cctpMessageTransmitter = _cctpMessageTransmitter;
        owner = _owner;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @notice Emergency: recover tokens accidentally sent to this contract.
    ///         For USDC, enforces that user recovery funds are not drained.
    function emergencyRecover(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();

        // Protect user recovery funds: owner cannot withdraw USDC below totalFailedAmount
        if (token == usdc) {
            uint256 balance = IERC20(usdc).balanceOf(address(this));
            require(balance >= amount && balance - amount >= totalFailedAmount, "would drain recovery funds");
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Withdraw any ETH accidentally sent (e.g., by Bungee with the executor call)
    function withdrawETH(address to) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok);
    }

    /// @notice Accept ETH — some bridges send dust ETH with executor callbacks
    receive() external payable {}

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;
}

/// @dev Minimal interface for EscrowV2.depositTo
interface IEscrowV2Minimal {
    function depositTo(address _depositor, CashOutRelay.CreateDepositParams calldata _params) external;
}

/// @dev Minimal interface for CCTP MessageTransmitter
interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}
