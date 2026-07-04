// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {CashOutRelay, IEscrowV2Minimal} from "../src/cashout/CashOutRelay.sol";

/// @dev Mock EscrowV2 that records depositTo calls
contract MockEscrow {
    struct DepositRecord {
        address depositor;
        uint256 amount;
        bytes32 paymentMethod;
        bytes32 payeeDetails;
        uint256 minIntent;
        uint256 maxIntent;
    }

    DepositRecord[] public deposits;
    bool public shouldRevert;
    string public revertReason;

    function setRevert(bool _shouldRevert, string memory _reason) external {
        shouldRevert = _shouldRevert;
        revertReason = _reason;
    }

    function depositTo(address _depositor, CashOutRelay.CreateDepositParams calldata _params) external {
        if (shouldRevert) revert(revertReason);

        // Pull USDC from caller (same as real escrow)
        _params.token.transferFrom(msg.sender, address(this), _params.amount);

        deposits.push(
            DepositRecord({
                depositor: _depositor,
                amount: _params.amount,
                paymentMethod: _params.paymentMethods[0],
                payeeDetails: _params.paymentMethodData[0].payeeDetails,
                minIntent: _params.intentAmountRange.min,
                maxIntent: _params.intentAmountRange.max
            })
        );
    }

    function depositCount() external view returns (uint256) {
        return deposits.length;
    }
}

/// @dev Mock USDC token
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Mock CCTP MessageTransmitter — mints USDC to the relay on receiveMessage
contract MockMessageTransmitter {
    MockUSDC public usdc;
    address public relay;
    bool public shouldRevert;
    mapping(bytes32 => bool) public used; // replay protection

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function setRelay(address _relay) external {
        relay = _relay;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        if (shouldRevert) revert("CCTP: invalid attestation");
        bytes32 msgHash = keccak256(message);
        require(!used[msgHash], "CCTP: already received");
        used[msgHash] = true;

        // Decode amount from the message (we encode it simply for testing)
        uint256 amount = abi.decode(message, (uint256));
        usdc.mint(relay, amount);
        return true;
    }
}

contract CashOutRelayTest is Test {
    CashOutRelay public relay;
    MockEscrow public escrow;
    MockUSDC public usdc;
    MockMessageTransmitter public mockTransmitter;

    address constant BUNGEE = address(0xB009EE);
    address constant USER = address(0xCAFE);
    address constant OWNER = address(0x0A0E);

    bytes32 constant VENMO_METHOD = keccak256("venmo");
    bytes32 constant USD_CURRENCY = keccak256("USD");
    bytes32 constant PAYEE_HASH = keccak256("venmouser123");
    uint256 constant CONVERSION_RATE = 1e18; // 1:1

    function setUp() public {
        escrow = new MockEscrow();
        usdc = new MockUSDC();
        mockTransmitter = new MockMessageTransmitter(usdc);

        // Deploy relay behind UUPS proxy
        CashOutRelay impl = new CashOutRelay();
        bytes memory initData = abi.encodeWithSelector(
            CashOutRelay.initialize.selector, address(escrow), address(usdc), address(mockTransmitter), OWNER
        );
        relay = CashOutRelay(payable(address(new ERC1967Proxy(address(impl), initData))));

        // H-01: register the trusted Bungee executor that is allowed to call executeData.
        vm.prank(OWNER);
        relay.setBungeeExecutor(BUNGEE);

        // Tell mock transmitter where the relay is (so it mints USDC there)
        mockTransmitter.setRelay(address(relay));
    }

    /*═══════════════════════ HELPERS ═══════════════════════*/

    function _encodeCashOutParams(address depositor, uint256 amount) internal pure returns (bytes memory) {
        return _encodeCashOutParamsWithRange(depositor, 1e6, amount);
    }

    /// @dev Encode CashOutParams with a caller-specified intent range. Used by tests
    ///      that verify the relay ignores the range fields and pins min==max==delivered.
    function _encodeCashOutParamsWithRange(address depositor, uint256 minIntent, uint256 maxIntent)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            CashOutRelay.CashOutParams({
                depositor: depositor,
                paymentMethod: VENMO_METHOD,
                payeeDetailsHash: PAYEE_HASH,
                fiatCurrency: USD_CURRENCY,
                conversionRate: CONVERSION_RATE,
                minIntentAmount: minIntent,
                maxIntentAmount: maxIntent
            })
        );
    }

    function _mintAndDeliver(uint256 amount) internal {
        // Simulate Bungee delivering USDC to the relay
        usdc.mint(address(relay), amount);
    }

    function _callExecuteData(bytes32 requestHash, uint256 amount, bytes memory callData) internal {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        relay.executeData(requestHash, amounts, tokens, callData);
    }

    /*═══════════════════════ HAPPY PATH ═══════════════════════*/

    function testHappyPath_DepositCreatedAndOwnedByUser() public {
        uint256 amount = 50e6; // $50 USDC
        _mintAndDeliver(amount);

        bytes memory callData = _encodeCashOutParams(USER, amount);
        _callExecuteData(keccak256("req1"), amount, callData);

        // Verify: escrow received the deposit
        assertEq(escrow.depositCount(), 1, "Should have 1 deposit");
        (address depositor, uint256 depAmount, bytes32 method, bytes32 payee, uint256 minIntent, uint256 maxIntent) =
            escrow.deposits(0);
        assertEq(depositor, USER, "Deposit should be owned by user");
        assertEq(depAmount, amount, "Deposit amount should match");
        assertEq(method, VENMO_METHOD, "Payment method should be venmo");
        assertEq(payee, PAYEE_HASH, "Payee hash should match");

        // Full-fill only: intent range is pinned to the deposit amount so partial
        // fills are impossible (no sub-min dust can be left stranded).
        assertEq(minIntent, amount, "min intent should equal full deposit amount");
        assertEq(maxIntent, amount, "max intent should equal full deposit amount");

        // Verify: relay has no remaining USDC
        assertEq(usdc.balanceOf(address(relay)), 0, "Relay should have 0 USDC after deposit");
    }

    function testHappyPath_EmitsEvent() public {
        uint256 amount = 25e6;
        _mintAndDeliver(amount);

        bytes memory callData = _encodeCashOutParams(USER, amount);

        vm.expectEmit(true, true, false, true);
        emit CashOutRelay.CashOutDeposited(USER, keccak256("req1"), amount, VENMO_METHOD);

        _callExecuteData(keccak256("req1"), amount, callData);
    }

    function testHappyPath_MultipleConcurrentUsers() public {
        address user2 = address(0xBEEF);
        uint256 amount1 = 50e6;
        uint256 amount2 = 100e6;

        // User 1
        _mintAndDeliver(amount1);
        _callExecuteData(keccak256("req1"), amount1, _encodeCashOutParams(USER, amount1));

        // User 2
        _mintAndDeliver(amount2);
        _callExecuteData(keccak256("req2"), amount2, _encodeCashOutParams(user2, amount2));

        assertEq(escrow.depositCount(), 2, "Should have 2 deposits");
        assertEq(usdc.balanceOf(address(relay)), 0, "Relay should be empty");
    }

    /*═══════════════════════ FULL-FILL ONLY ═══════════════════════*/

    /// @notice Even when params carry a wide intent range, the relay pins the
    ///         deposit's intent range to the actually-delivered amount. ZKP2P
    ///         then enforces full-fill-only at intent time, so dust can't be
    ///         left behind by a partial fill.
    function testFullFill_RangePinnedToDeliveredAmount_IgnoresParams() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        // Caller asks for a wide range $1..$50; relay must override.
        bytes memory callData = _encodeCashOutParamsWithRange(USER, 1e6, 50e6);
        _callExecuteData(keccak256("wide-range"), amount, callData);

        (,,,, uint256 minIntent, uint256 maxIntent) = escrow.deposits(0);
        assertEq(minIntent, amount, "min must be pinned to delivered amount, not params.min");
        assertEq(maxIntent, amount, "max must be pinned to delivered amount, not params.max");
    }

    /// @notice Adversarial range params (zero min, type(uint256).max max) must
    ///         not weaken the on-deposit constraint — relay overrides regardless.
    function testFullFill_RangePinned_AdversarialParams() public {
        uint256 amount = 25e6;
        _mintAndDeliver(amount);

        bytes memory callData = _encodeCashOutParamsWithRange(USER, 0, type(uint256).max);
        _callExecuteData(keccak256("adversarial-range"), amount, callData);

        (,,,, uint256 minIntent, uint256 maxIntent) = escrow.deposits(0);
        assertEq(minIntent, amount, "min must be pinned to delivered, not 0");
        assertEq(maxIntent, amount, "max must be pinned to delivered, not uint256.max");
    }

    /// @notice Bungee solvers in production deliver `minOutputAmount`, which is
    ///         lower than the user's `inputAmount` due to slippage. The deposit
    ///         range must reflect what actually arrived, not what the user asked
    ///         for in CashOutParams.maxIntentAmount.
    function testFullFill_DeliveredAmountMatchesActualBridgeSlippage() public {
        uint256 inputAmount = 7_000_000; // $7.00 — what the user submitted on Arb
        uint256 deliveredAmount = 6_948_895; // ~0.73% slippage — real fill from prod

        _mintAndDeliver(deliveredAmount);

        // Frontend encoded params with maxIntentAmount = inputAmount (what user
        // asked for), but relay sees only deliveredAmount on the destination side.
        bytes memory callData = _encodeCashOutParamsWithRange(USER, 1e6, inputAmount);
        _callExecuteData(keccak256("post-slippage"), deliveredAmount, callData);

        (, uint256 depAmount,,, uint256 minIntent, uint256 maxIntent) = escrow.deposits(0);
        assertEq(depAmount, deliveredAmount, "deposit funded with delivered, not requested");
        assertEq(minIntent, deliveredAmount, "min tracks actual delivery (post-slippage)");
        assertEq(maxIntent, deliveredAmount, "max tracks actual delivery (post-slippage)");
    }

    /*═══════════════════════ FAILURE & RECOVERY ═══════════════════════*/

    function testEscrowReverts_HoldsUSDCForRecovery() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        // Make escrow revert
        escrow.setRevert(true, "ZKP2P paused");

        bytes32 reqHash = keccak256("req_fail");
        bytes memory callData = _encodeCashOutParams(USER, amount);

        // Should NOT revert — relay catches it
        _callExecuteData(reqHash, amount, callData);

        // USDC should be held in relay
        assertEq(usdc.balanceOf(address(relay)), amount, "Relay should hold USDC after failure");
        assertEq(relay.failedDepositor(reqHash), USER, "Failed depositor should be tracked");
        assertEq(relay.failedAmount(reqHash), amount, "Failed amount should be tracked");

        // Escrow should have 0 deposits
        assertEq(escrow.depositCount(), 0, "Escrow should have no deposits");
    }

    function testRecovery_UserCanRecoverFailedDeposit() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        escrow.setRevert(true, "paused");
        bytes32 reqHash = keccak256("req_recover");
        _callExecuteData(reqHash, amount, _encodeCashOutParams(USER, amount));

        // User recovers
        vm.prank(USER);
        relay.recoverFailed(reqHash);

        assertEq(usdc.balanceOf(USER), amount, "User should receive USDC back");
        assertEq(usdc.balanceOf(address(relay)), 0, "Relay should be empty");
        assertEq(relay.failedDepositor(reqHash), address(0), "Failed record should be cleared");
    }

    function testRecovery_NonDepositorCannotRecover() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        escrow.setRevert(true, "paused");
        bytes32 reqHash = keccak256("req_steal");
        _callExecuteData(reqHash, amount, _encodeCashOutParams(USER, amount));

        // Attacker tries to recover
        vm.prank(address(0xA77AC6));
        vm.expectRevert(CashOutRelay.NotOwner.selector);
        relay.recoverFailed(reqHash);
    }

    function testRecovery_DoubleRecoverReverts() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        escrow.setRevert(true, "paused");
        bytes32 reqHash = keccak256("req_double");
        _callExecuteData(reqHash, amount, _encodeCashOutParams(USER, amount));

        vm.prank(USER);
        relay.recoverFailed(reqHash);

        vm.prank(USER);
        vm.expectRevert(CashOutRelay.NoPendingRecovery.selector);
        relay.recoverFailed(reqHash);
    }

    /*═══════════════════════ EDGE CASES ═══════════════════════*/

    function testEdge_WrongToken_Reverts() public {
        address wrongToken = address(0xBAD);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory tokens = new address[](1);
        tokens[0] = wrongToken;

        bytes memory callData = _encodeCashOutParams(USER, 50e6);

        vm.prank(BUNGEE);
        vm.expectRevert(abi.encodeWithSelector(CashOutRelay.WrongToken.selector, wrongToken, address(usdc)));
        relay.executeData(keccak256("req_wrong"), amounts, tokens, callData);
    }

    function testEdge_ZeroAmount_Reverts() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        vm.expectRevert(CashOutRelay.ZeroAmount.selector);
        relay.executeData(keccak256("req_zero"), amounts, tokens, _encodeCashOutParams(USER, 0));
    }

    function testEdge_ZeroDepositor_Reverts() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        bytes memory callData = _encodeCashOutParams(address(0), amount);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        vm.expectRevert(CashOutRelay.ZeroDepositor.selector);
        relay.executeData(keccak256("req_zero_dep"), amounts, tokens, callData);
    }

    function testEdge_EmptyAmounts_Reverts() public {
        vm.prank(BUNGEE);
        vm.expectRevert(CashOutRelay.ZeroAmount.selector);
        relay.executeData(keccak256("req_empty"), new uint256[](0), new address[](0), _encodeCashOutParams(USER, 50e6));
    }

    /*═══════════════════════ ADMIN ═══════════════════════*/

    function testAdmin_EmergencyRecover() public {
        usdc.mint(address(relay), 100e6);

        vm.prank(OWNER);
        relay.emergencyRecover(address(usdc), OWNER, 100e6);

        assertEq(usdc.balanceOf(OWNER), 100e6, "Owner should receive tokens");
    }

    function testAdmin_NonOwnerCannotEmergencyRecover() public {
        usdc.mint(address(relay), 100e6);

        address attacker = address(0xA77AC6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        relay.emergencyRecover(address(usdc), attacker, 100e6);
    }

    function testAdmin_NonOwnerCannotUpgrade() public {
        CashOutRelay newImpl = new CashOutRelay();

        vm.prank(address(0xA77AC6));
        vm.expectRevert();
        relay.upgradeToAndCall(address(newImpl), "");
    }

    function testAdmin_OwnerCanUpgrade() public {
        CashOutRelay newImpl = new CashOutRelay();

        vm.prank(OWNER);
        relay.upgradeToAndCall(address(newImpl), "");

        // Still works after upgrade
        assertEq(relay.escrow(), address(escrow), "Config preserved after upgrade");
    }

    /*═══════════════════════ INITIALIZATION ═══════════════════════*/

    function testInit_ConfigSetCorrectly() public view {
        assertEq(relay.escrow(), address(escrow), "Escrow should be set");
        assertEq(relay.usdc(), address(usdc), "USDC should be set");
        assertEq(relay.owner(), OWNER, "Owner should be set");
    }

    function testInit_CannotReinitialize() public {
        vm.expectRevert();
        relay.initialize(address(0), address(0), address(0), address(0));
    }

    /*═══════════════════════ SECURITY: FUND THEFT PREVENTION ═══════════════════════*/

    function testSecurity_AttackerCannotStealFailedDeposits() public {
        // User's deposit fails — 50 USDC held in relay
        uint256 amount = 50e6;
        _mintAndDeliver(amount);
        escrow.setRevert(true, "paused");
        _callExecuteData(keccak256("req_victim"), amount, _encodeCashOutParams(USER, amount));

        assertEq(usdc.balanceOf(address(relay)), amount, "Relay holds user's USDC");

        // Attacker calls executeData directly (no bridge, no USDC delivered)
        // with amounts[0] = 50e6 claiming the held USDC
        escrow.setRevert(false, "");
        address attacker = address(0xBAD1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(attacker);
        // H-01: executeData is now gated to the trusted Bungee executor, so an unauthorized
        // caller is rejected before the balance check even runs — defense in depth over the
        // prior `available == 0` guard (which alone protected only already-reserved funds).
        vm.expectRevert(CashOutRelay.NotAuthorizedExecutor.selector);
        relay.executeData(keccak256("req_attack"), amounts, tokens, _encodeCashOutParams(attacker, amount));

        // User's recovery is still intact
        vm.prank(USER);
        relay.recoverFailed(keccak256("req_victim"));
        assertEq(usdc.balanceOf(USER), amount, "User recovered their USDC");
    }

    function testSecurity_EmergencyRecoverCannotDrainUserFunds() public {
        // User's deposit fails — 50 USDC held
        uint256 amount = 50e6;
        _mintAndDeliver(amount);
        escrow.setRevert(true, "paused");
        _callExecuteData(keccak256("req_held"), amount, _encodeCashOutParams(USER, amount));

        // Extra 20 USDC accidentally sent to relay
        usdc.mint(address(relay), 20e6);

        // Owner can recover the extra 20, but NOT the held 50
        vm.prank(OWNER);
        relay.emergencyRecover(address(usdc), OWNER, 20e6);
        assertEq(usdc.balanceOf(OWNER), 20e6, "Owner recovers surplus");

        // Owner tries to drain held funds — should fail
        vm.prank(OWNER);
        vm.expectRevert(CashOutRelay.WouldDrainRecoveryFunds.selector);
        relay.emergencyRecover(address(usdc), OWNER, 1);

        // User can still recover
        vm.prank(USER);
        relay.recoverFailed(keccak256("req_held"));
        assertEq(usdc.balanceOf(USER), amount, "User still recovers");
    }

    function testSecurity_RequestHashCollisionBlocked() public {
        // Two deposits fail with the same requestHash
        _mintAndDeliver(50e6);
        escrow.setRevert(true, "paused");
        _callExecuteData(keccak256("collision"), 50e6, _encodeCashOutParams(USER, 50e6));

        // Second call with same hash — should revert
        _mintAndDeliver(30e6);
        vm.expectRevert(CashOutRelay.RequestHashAlreadyFailed.selector);
        _callExecuteData(keccak256("collision"), 30e6, _encodeCashOutParams(address(0xBEEF), 30e6));

        // First user's recovery is intact
        assertEq(relay.failedAmount(keccak256("collision")), 50e6, "First user amount preserved");
        assertEq(relay.failedDepositor(keccak256("collision")), USER, "First user address preserved");
    }

    function testSecurity_CreateZkp2pDepositCannotBeCalledExternally() public {
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: 50e6
        });

        vm.prank(address(0xBAD1));
        vm.expectRevert(CashOutRelay.OnlySelf.selector);
        relay.createZkp2pDeposit(params, 50e6);
    }

    /*═══════════════════════ BALANCE VERIFICATION ═══════════════════════*/

    function testBalance_InsufficientDeliveryReverts() public {
        // Don't deliver any USDC — just call executeData
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        vm.expectRevert(abi.encodeWithSelector(CashOutRelay.InsufficientDelivery.selector, 50e6, 0));
        relay.executeData(keccak256("no_delivery"), amounts, tokens, _encodeCashOutParams(USER, 50e6));
    }

    function testBalance_PartialDeliveryReverts() public {
        // Deliver less than claimed
        usdc.mint(address(relay), 30e6);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        vm.expectRevert(abi.encodeWithSelector(CashOutRelay.InsufficientDelivery.selector, 50e6, 30e6));
        relay.executeData(keccak256("partial"), amounts, tokens, _encodeCashOutParams(USER, 50e6));
    }

    function testBalance_SuccessiveCallsOnlyUseFreshFunds() public {
        // First call: deliver and deposit 50 USDC
        _mintAndDeliver(50e6);
        _callExecuteData(keccak256("req1"), 50e6, _encodeCashOutParams(USER, 50e6));

        // Relay should be empty
        assertEq(usdc.balanceOf(address(relay)), 0, "Empty after first deposit");

        // Second call: deliver fresh 30 USDC
        _mintAndDeliver(30e6);
        _callExecuteData(keccak256("req2"), 30e6, _encodeCashOutParams(address(0xBEEF), 30e6));

        assertEq(escrow.depositCount(), 2, "Two deposits created");
    }

    /*═══════════════════════ TRACKING ═══════════════════════*/

    function testTracking_TotalFailedAmountAccurate() public {
        escrow.setRevert(true, "paused");

        // Two failures
        _mintAndDeliver(50e6);
        _callExecuteData(keccak256("f1"), 50e6, _encodeCashOutParams(USER, 50e6));
        _mintAndDeliver(30e6);
        _callExecuteData(keccak256("f2"), 30e6, _encodeCashOutParams(address(0xBEEF), 30e6));

        assertEq(relay.totalFailedAmount(), 80e6, "Total failed = 80 USDC");

        // User recovers one
        vm.prank(USER);
        relay.recoverFailed(keccak256("f1"));
        assertEq(relay.totalFailedAmount(), 30e6, "Total failed = 30 after recovery");

        // Second user recovers
        vm.prank(address(0xBEEF));
        relay.recoverFailed(keccak256("f2"));
        assertEq(relay.totalFailedAmount(), 0, "Total failed = 0 after all recovered");
    }

    /*═══════════════════════ ETH HANDLING ═══════════════════════*/

    function testETH_AcceptsAndOwnerCanWithdraw() public {
        // Send ETH to relay
        vm.deal(BUNGEE, 1 ether);
        vm.prank(BUNGEE);
        (bool ok,) = address(relay).call{value: 0.01 ether}("");
        assertTrue(ok, "Should accept ETH");

        assertEq(address(relay).balance, 0.01 ether, "Relay holds ETH");

        // Owner withdraws
        vm.prank(OWNER);
        relay.withdrawETH(OWNER);
        assertEq(OWNER.balance, 0.01 ether, "Owner received ETH");
    }

    function testETH_NonOwnerCannotWithdraw() public {
        vm.deal(address(relay), 0.01 ether);

        address attacker = address(0xA77AC6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        relay.withdrawETH(attacker);
    }

    /*═══════════════════════ CCTP completeCashOut TESTS ═══════════════════════*/

    function _buildCctpMessage(uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(amount);
    }

    function testCCTP_HappyPath_DepositCreated() public {
        uint256 amount = 50e6;
        bytes memory message = _buildCctpMessage(amount);
        bytes memory attestation = hex"CAFE";

        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: amount
        });

        vm.prank(OWNER);
        relay.completeCashOut(message, attestation, params);

        // Escrow should have the deposit, owned by USER
        assertEq(escrow.depositCount(), 1, "Deposit created");
        (address depositor, uint256 depAmount,,, uint256 minIntent, uint256 maxIntent) = escrow.deposits(0);
        assertEq(depositor, USER, "Owned by user");
        assertEq(depAmount, amount, "Correct amount");
        // CCTP path also pins range to delivered (full-fill only)
        assertEq(minIntent, amount, "min pinned to delivered (CCTP)");
        assertEq(maxIntent, amount, "max pinned to delivered (CCTP)");
    }

    function testCCTP_NonOwnerReverts() public {
        bytes memory message = _buildCctpMessage(10e6);
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: 10e6
        });

        address attacker = address(0xBAD1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        relay.completeCashOut(message, hex"CAFE", params);
    }

    function testCCTP_TransmitterReverts_FailsCleanly() public {
        mockTransmitter.setRevert(true);
        bytes memory message = _buildCctpMessage(10e6);
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: 10e6
        });

        vm.prank(OWNER);
        vm.expectRevert("CCTP: invalid attestation");
        relay.completeCashOut(message, hex"CAFE", params);
    }

    function testCCTP_ReplayBlocked() public {
        uint256 amount = 10e6;
        bytes memory message = _buildCctpMessage(amount);
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: amount
        });

        // First call succeeds
        vm.prank(OWNER);
        relay.completeCashOut(message, hex"CAFE", params);

        // Replay reverts (mock has nonce tracking)
        vm.prank(OWNER);
        vm.expectRevert("CCTP: already received");
        relay.completeCashOut(message, hex"CAFE", params);
    }

    function testCCTP_EscrowFails_RecoveryWorks() public {
        escrow.setRevert(true, "ZKP2P paused");
        uint256 amount = 25e6;
        bytes memory message = _buildCctpMessage(amount);
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: amount
        });

        vm.prank(OWNER);
        relay.completeCashOut(message, hex"CAFE", params);

        // USDC held in relay, tracked for recovery
        bytes32 reqHash = keccak256(message);
        assertEq(relay.failedAmount(reqHash), amount, "Failed amount tracked");
        assertEq(relay.failedDepositor(reqHash), USER, "Failed depositor tracked");
        assertEq(relay.totalFailedAmount(), amount, "Total failed updated");

        // User recovers
        vm.prank(USER);
        relay.recoverFailed(reqHash);
        assertEq(usdc.balanceOf(USER), amount, "User recovered USDC");
        assertEq(relay.totalFailedAmount(), 0, "Total failed zeroed");
    }

    function testCCTP_BalanceMathCorrectWithExistingFailedDeposits() public {
        // First: create a failed deposit via Bungee path (50 USDC held)
        _mintAndDeliver(50e6);
        escrow.setRevert(true, "paused");
        _callExecuteData(keccak256("bungee_fail"), 50e6, _encodeCashOutParams(address(0xBEEF), 50e6));
        assertEq(relay.totalFailedAmount(), 50e6);

        // Now: CCTP cashout should succeed independently (no interference from held funds)
        escrow.setRevert(false, "");
        uint256 cctpAmount = 10e6;
        bytes memory message = _buildCctpMessage(cctpAmount);
        CashOutRelay.CashOutParams memory params = CashOutRelay.CashOutParams({
            depositor: USER,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: cctpAmount
        });

        vm.prank(OWNER);
        relay.completeCashOut(message, hex"CAFE", params);

        // CCTP deposit should work, Bungee recovery still intact
        assertEq(escrow.depositCount(), 1, "CCTP deposit created");
        assertEq(relay.totalFailedAmount(), 50e6, "Bungee failed amount unchanged");
        assertEq(relay.failedDepositor(keccak256("bungee_fail")), address(0xBEEF), "Bungee recovery intact");
    }

    /*═══════════════════════ H-01: executeData ACCESS CONTROL ═══════════════════════*/

    /// @notice H-01: an arbitrary caller (not the trusted Bungee executor, not the owner)
    ///         cannot call executeData and redirect freshly-bridged USDC.
    function testH01_AttackerCannotCallExecuteData() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount); // fresh, not-yet-assigned USDC sits in the relay

        address attacker = address(0xA77AC6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        // Attacker tries to mint the deposit to themselves — rejected by the executor gate.
        vm.prank(attacker);
        vm.expectRevert(CashOutRelay.NotAuthorizedExecutor.selector);
        relay.executeData(keccak256("req_attack"), amounts, tokens, _encodeCashOutParams(attacker, amount));

        // Funds untouched, no deposit created.
        assertEq(escrow.depositCount(), 0, "No deposit created by attacker");
        assertEq(usdc.balanceOf(address(relay)), amount, "USDC still held");
    }

    /// @notice H-01: the trusted Bungee executor can call executeData (happy path).
    function testH01_BungeeExecutorCanCallExecuteData() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        // BUNGEE is the registered executor (set in setUp).
        _callExecuteData(keccak256("req_bungee"), amount, _encodeCashOutParams(USER, amount));

        assertEq(escrow.depositCount(), 1, "Deposit created by bungee executor");
        (address depositor,,,,,) = escrow.deposits(0);
        assertEq(depositor, USER, "Deposit owned by intended user");
    }

    /// @notice H-01: the owner is also authorized to call executeData (operational fallback).
    function testH01_OwnerCanCallExecuteData() public {
        uint256 amount = 50e6;
        _mintAndDeliver(amount);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(OWNER);
        relay.executeData(keccak256("req_owner"), amounts, tokens, _encodeCashOutParams(USER, amount));

        assertEq(escrow.depositCount(), 1, "Owner can drive executeData");
    }

    /// @notice H-01: setBungeeExecutor is owner-gated and rejects the zero address.
    function testH01_SetBungeeExecutorAuth() public {
        address newExec = address(0xB00B00);

        // Non-owner cannot set.
        address attacker = address(0xA77AC6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        relay.setBungeeExecutor(newExec);

        // Zero address rejected.
        vm.prank(OWNER);
        vm.expectRevert(CashOutRelay.ZeroAddress.selector);
        relay.setBungeeExecutor(address(0));

        // Owner can rotate, event fires, old executor loses access.
        vm.expectEmit(true, true, false, true);
        emit CashOutRelay.BungeeExecutorSet(BUNGEE, newExec);
        vm.prank(OWNER);
        relay.setBungeeExecutor(newExec);
        assertEq(relay.bungeeExecutor(), newExec, "Executor rotated");

        // Old executor is now unauthorized.
        _mintAndDeliver(10e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(BUNGEE);
        vm.expectRevert(CashOutRelay.NotAuthorizedExecutor.selector);
        relay.executeData(keccak256("stale"), amounts, tokens, _encodeCashOutParams(USER, 10e6));
    }

    /*═══════════════════════ L-47: AMOUNT RECONCILIATION ═══════════════════════*/

    /// @notice L-47: when the bridge over-delivers, executeData deposits the FULL freshly
    ///         delivered balance (not just the claimed amounts[0]), so no surplus is left
    ///         untracked/drainable.
    function testL47_OverDeliveryReconciledToActualBalance() public {
        uint256 claimed = 50e6; // what Bungee reports in amounts[0]
        uint256 delivered = 52e6; // what actually landed (surplus buffer)
        _mintAndDeliver(delivered);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimed;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(BUNGEE);
        relay.executeData(keccak256("over"), amounts, tokens, _encodeCashOutParams(USER, claimed));

        // Deposit funded with the actual delivered balance, not the claimed amount.
        (, uint256 depAmount,,, uint256 minIntent, uint256 maxIntent) = escrow.deposits(0);
        assertEq(depAmount, delivered, "Deposit uses actual delivered balance");
        assertEq(minIntent, delivered, "Intent range pinned to delivered");
        assertEq(maxIntent, delivered, "Intent range pinned to delivered");
        // No surplus stranded in the relay.
        assertEq(usdc.balanceOf(address(relay)), 0, "No untracked surplus left behind");
    }

    /// @notice L-47: reconciliation only touches FRESH funds — held recovery funds are
    ///         excluded from the deposited amount even when they inflate the raw balance.
    function testL47_ReconciliationExcludesHeldRecoveryFunds() public {
        // Seed a held failed deposit (30 USDC reserved for recovery).
        _mintAndDeliver(30e6);
        escrow.setRevert(true, "paused");
        _callExecuteData(keccak256("held"), 30e6, _encodeCashOutParams(address(0xBEEF), 30e6));
        assertEq(relay.totalFailedAmount(), 30e6);

        // Now a fresh delivery of 50 arrives; escrow works again.
        escrow.setRevert(false, "");
        _mintAndDeliver(50e6); // relay balance now 80, but only 50 is fresh

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(BUNGEE);
        relay.executeData(keccak256("fresh"), amounts, tokens, _encodeCashOutParams(USER, 50e6));

        // Only the fresh 50 was deposited; the 30 held for recovery is untouched.
        (, uint256 depAmount,,,,) = escrow.deposits(0);
        assertEq(depAmount, 50e6, "Only fresh funds deposited");
        assertEq(relay.totalFailedAmount(), 30e6, "Held recovery funds preserved");
        assertEq(usdc.balanceOf(address(relay)), 30e6, "Relay still holds recovery funds");
    }

    /*═══════════════════════ M-16: NONCE-BASED requestHash ═══════════════════════*/

    /// @notice M-16: two identical createDepositFromBalance calls (same depositor, same block)
    ///         produce DISTINCT requestHashes thanks to the monotonic nonce — the old
    ///         keccak256(depositor, block.timestamp) preimage would have collided.
    function testM16_NonceMonotonicity_DistinctRequestHashes() public {
        escrow.setRevert(true, "paused"); // force the failure path so requestHash is recorded

        // First delivery + deposit-from-balance (nonce 0).
        _mintAndDeliver(20e6);
        vm.prank(OWNER);
        relay.createDepositFromBalance(_decodeParams(USER));
        bytes32 hash0 = keccak256(abi.encode(address(relay), USER, uint256(0)));
        assertEq(relay.failedDepositor(hash0), USER, "First failure recorded under nonce-0 hash");
        assertEq(relay.depositNonce(), 1, "Nonce incremented to 1");

        // Second identical call in the SAME block, same depositor (nonce 1).
        _mintAndDeliver(20e6);
        vm.prank(OWNER);
        relay.createDepositFromBalance(_decodeParams(USER));
        bytes32 hash1 = keccak256(abi.encode(address(relay), USER, uint256(1)));

        assertTrue(hash0 != hash1, "Identical deposits yield distinct requestHashes");
        assertEq(relay.failedDepositor(hash1), USER, "Second failure recorded under nonce-1 hash");
        assertEq(relay.failedAmount(hash1), 20e6, "Second failure amount recorded");
        assertEq(relay.depositNonce(), 2, "Nonce incremented to 2");
        assertEq(relay.totalFailedAmount(), 40e6, "Both failures tracked - no collision revert");
    }

    /// @notice M-16: nonce advances on the SUCCESS path too, so a later failure can't collide
    ///         with a prior success's hash.
    function testM16_NonceAdvancesOnSuccess() public {
        _mintAndDeliver(20e6);
        vm.prank(OWNER);
        relay.createDepositFromBalance(_decodeParams(USER));
        assertEq(escrow.depositCount(), 1, "Success path ran");
        assertEq(relay.depositNonce(), 1, "Nonce advanced on success");
    }

    function _decodeParams(address depositor) internal pure returns (CashOutRelay.CashOutParams memory) {
        return CashOutRelay.CashOutParams({
            depositor: depositor,
            paymentMethod: VENMO_METHOD,
            payeeDetailsHash: PAYEE_HASH,
            fiatCurrency: USD_CURRENCY,
            conversionRate: CONVERSION_RATE,
            minIntentAmount: 1e6,
            maxIntentAmount: 20e6
        });
    }

    /*═══════════════════════ L-46: 2-STEP OWNERSHIP ═══════════════════════*/

    /// @notice L-46: ownership uses Ownable2Step — transfer requires the new owner to accept,
    ///         so a fat-fingered transfer to a wrong/dead address does not brick the contract.
    function testL46_TwoStepOwnershipHandover() public {
        address newOwner = address(0x0E0E);

        // Step 1: current owner proposes. Ownership does NOT change yet.
        vm.prank(OWNER);
        relay.transferOwnership(newOwner);
        assertEq(relay.owner(), OWNER, "Owner unchanged until accepted");
        assertEq(relay.pendingOwner(), newOwner, "Pending owner set");

        // Old owner still fully in control mid-handover.
        vm.prank(OWNER);
        relay.setBungeeExecutor(address(0xBEEF));
        assertEq(relay.bungeeExecutor(), address(0xBEEF), "Old owner still acts pre-acceptance");

        // A random address cannot accept.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        relay.acceptOwnership();

        // Step 2: pending owner accepts → ownership transfers.
        vm.prank(newOwner);
        relay.acceptOwnership();
        assertEq(relay.owner(), newOwner, "New owner active after acceptance");
        assertEq(relay.pendingOwner(), address(0), "Pending owner cleared");

        // Old owner is now powerless.
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, OWNER));
        relay.setBungeeExecutor(address(0xCAFE));

        // New owner can act.
        vm.prank(newOwner);
        relay.setBungeeExecutor(address(0xCAFE));
        assertEq(relay.bungeeExecutor(), address(0xCAFE), "New owner in control");
    }

    /// @notice L-46: only the owner can authorize a UUPS upgrade (now via Ownable).
    function testL46_OnlyOwnerCanUpgrade() public {
        CashOutRelay newImpl = new CashOutRelay();

        address attacker = address(0xA77AC6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        relay.upgradeToAndCall(address(newImpl), "");

        vm.prank(OWNER);
        relay.upgradeToAndCall(address(newImpl), "");
        assertEq(relay.escrow(), address(escrow), "Config preserved after upgrade");
    }
}
