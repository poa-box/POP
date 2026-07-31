// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymasterGraceLib} from "../src/libs/PaymasterGraceLib.sol";
import {PaymasterPostOpLib} from "../src/libs/PaymasterPostOpLib.sol";
import {PaymasterCalldataLib} from "../src/libs/PaymasterCalldataLib.sol";

// ============ Wrapper Contracts ============
// Libraries with internal functions need wrappers so tests can call them externally.

contract GraceLibWrapper {
    function isInGracePeriod(uint40 registeredAt, uint32 initialGraceDays) external view returns (bool) {
        return PaymasterGraceLib.isInGracePeriod(registeredAt, initialGraceDays);
    }

    function calculateMatchAllowance(uint256 deposited, uint256 minDeposit) external pure returns (uint256) {
        return PaymasterGraceLib.calculateMatchAllowance(deposited, minDeposit);
    }
}

contract PostOpLibWrapper {
    function adjustBudget(uint128 usedInEpoch, uint256 reserved, uint256 actual) external pure returns (uint128) {
        return PaymasterPostOpLib.adjustBudget(usedInEpoch, reserved, actual);
    }

    function clampedDeduction(uint128 balance, uint256 cost)
        external
        pure
        returns (uint128 newBalance, uint128 deducted)
    {
        return PaymasterPostOpLib.clampedDeduction(balance, cost);
    }
}

contract CalldataLibWrapper {
    function parseExecuteCall(bytes calldata callData, address expectedTarget)
        external
        pure
        returns (bool valid, bytes4 innerSelector)
    {
        return PaymasterCalldataLib.parseExecuteCall(callData, expectedTarget);
    }
}

// ============ PaymasterGraceLib Tests ============

contract PaymasterGraceLibTest is Test {
    GraceLibWrapper lib;

    // Use a realistic timestamp so arithmetic doesn't underflow
    uint256 constant START_TIME = 1_700_000_000; // Nov 2023

    function setUp() public {
        lib = new GraceLibWrapper();
        vm.warp(START_TIME);
    }

    // -------- isInGracePeriod --------

    function testIsInGracePeriod_DuringGrace() public view {
        uint40 registeredAt = uint40(block.timestamp);
        assertTrue(lib.isInGracePeriod(registeredAt, 90));
    }

    function testIsInGracePeriod_ExactlyAtExpiry() public view {
        uint40 registeredAt = uint40(block.timestamp - 90 days);
        // At exactly the boundary, grace has ended (not strictly less than)
        assertFalse(lib.isInGracePeriod(registeredAt, 90));
    }

    function testIsInGracePeriod_OneSecondBeforeExpiry() public view {
        uint40 registeredAt = uint40(block.timestamp - 90 days + 1);
        assertTrue(lib.isInGracePeriod(registeredAt, 90));
    }

    function testIsInGracePeriod_AfterExpiry() public view {
        uint40 registeredAt = uint40(block.timestamp - 91 days);
        assertFalse(lib.isInGracePeriod(registeredAt, 90));
    }

    function testIsInGracePeriod_ZeroGraceDays() public view {
        uint40 registeredAt = uint40(block.timestamp);
        // 0 grace days means grace ends immediately at registeredAt
        assertFalse(lib.isInGracePeriod(registeredAt, 0));
    }

    function testIsInGracePeriod_ZeroRegisteredAt() public view {
        // registeredAt=0 with 90 grace days: graceEnd = 90 days = 7,776,000
        // At realistic timestamp this is long expired
        assertFalse(lib.isInGracePeriod(0, 90));
    }

    function testIsInGracePeriod_ZeroBoth() public view {
        // registeredAt=0 + 0 days = 0, block.timestamp > 0
        assertFalse(lib.isInGracePeriod(0, 0));
    }

    function testIsInGracePeriod_MaxGraceDays() public view {
        uint40 registeredAt = uint40(block.timestamp);
        // Max uint32 days = ~11.7 million years, should be in grace
        assertTrue(lib.isInGracePeriod(registeredAt, type(uint32).max));
    }

    function testFuzz_IsInGracePeriod(uint40 registeredAt, uint32 graceDays) public view {
        // Skip if registeredAt is in the future (unrealistic)
        vm.assume(registeredAt <= block.timestamp);
        bool result = lib.isInGracePeriod(registeredAt, graceDays);
        uint256 graceEnd = uint256(registeredAt) + uint256(graceDays) * 1 days;
        assertEq(result, block.timestamp < graceEnd);
    }

    // NOTE (L-31): PaymasterGraceLib.solidarityFee was dead code (only referenced by these tests,
    // never by src) and has been removed; the hub inlines its fee calc where it is actually needed.

    // -------- calculateMatchAllowance --------

    function testMatchAllowance_ZeroMinDeposit() public pure {
        assertEq(PaymasterGraceLib.calculateMatchAllowance(1 ether, 0), 0);
    }

    function testMatchAllowance_BelowMinDeposit() public pure {
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.002 ether, 0.003 ether), 0);
    }

    function testMatchAllowance_ExactlyMinDeposit() public pure {
        // Tier 1: deposit == minDeposit → 2x match
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.003 ether, 0.003 ether), 0.006 ether);
    }

    function testMatchAllowance_BetweenMinAndTwoX() public pure {
        // Tier 2: minDeposit < deposit <= 2x minDeposit
        // First tier: 0.003 * 2 = 0.006; Second tier: (0.005 - 0.003) = 0.002
        // Total = 0.008
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.005 ether, 0.003 ether), 0.008 ether);
    }

    function testMatchAllowance_ExactlyTwoXMin() public pure {
        // Tier 2 boundary: deposit == 2x minDeposit
        // First tier: 0.003 * 2 = 0.006; Second tier: 0.003
        // Total = 0.009
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.006 ether, 0.003 ether), 0.009 ether);
    }

    function testMatchAllowance_BetweenTwoXAndFiveX() public pure {
        // Tier 3: 2x < deposit < 5x → capped at firstTier + secondTier
        // First tier: 0.003 * 2 = 0.006; Second tier: 0.003
        // Total = 0.009 (same cap)
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.01 ether, 0.003 ether), 0.009 ether);
    }

    function testMatchAllowance_ExactlyFiveXMin() public pure {
        // Tier 4: deposit >= 5x → self-sufficient, no match
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0.015 ether, 0.003 ether), 0);
    }

    function testMatchAllowance_AboveFiveXMin() public pure {
        assertEq(PaymasterGraceLib.calculateMatchAllowance(1 ether, 0.003 ether), 0);
    }

    function testMatchAllowance_ZeroDeposit() public pure {
        assertEq(PaymasterGraceLib.calculateMatchAllowance(0, 0.003 ether), 0);
    }

    function testFuzz_MatchAllowance_TierBoundaries(uint128 minDeposit) public pure {
        vm.assume(minDeposit > 0 && minDeposit < type(uint128).max / 5);

        uint256 min = uint256(minDeposit);

        // Below min → 0
        assertEq(PaymasterGraceLib.calculateMatchAllowance(min - 1, min), 0);

        // Exactly min → 2x
        assertEq(PaymasterGraceLib.calculateMatchAllowance(min, min), min * 2);

        // Exactly 2x min → 3x min (first tier 2x + second tier 1x)
        assertEq(PaymasterGraceLib.calculateMatchAllowance(min * 2, min), min * 3);

        // Between 2x and 5x → capped at 3x min
        assertEq(PaymasterGraceLib.calculateMatchAllowance(min * 3, min), min * 3);

        // Exactly 5x → no match
        assertEq(PaymasterGraceLib.calculateMatchAllowance(min * 5, min), 0);
    }

    function testFuzz_MatchAllowance_NeverExceedsCap(uint128 deposited, uint128 minDeposit) public pure {
        vm.assume(minDeposit > 0);
        uint256 result = PaymasterGraceLib.calculateMatchAllowance(deposited, minDeposit);
        // Match can never exceed 3x the minimum deposit
        assertTrue(result <= uint256(minDeposit) * 3);
    }
}

// ============ PaymasterPostOpLib Tests ============

contract PaymasterPostOpLibTest is Test {
    PostOpLibWrapper lib;

    function setUp() public {
        lib = new PostOpLibWrapper();
    }

    // -------- adjustBudget --------

    function testAdjustBudget_BasicReplacement() public view {
        // Reserved 1000, actual 700 → usage drops by 300
        uint128 result = lib.adjustBudget(5000, 1000, 700);
        assertEq(result, 4700); // 5000 - 1000 + 700
    }

    function testAdjustBudget_ActualEqualsReserved() public view {
        // No change when actual == reserved
        uint128 result = lib.adjustBudget(5000, 1000, 1000);
        assertEq(result, 5000);
    }

    function testAdjustBudget_ActualIsZero() public view {
        // UserOp used no gas (edge case)
        uint128 result = lib.adjustBudget(5000, 1000, 0);
        assertEq(result, 4000); // 5000 - 1000 + 0
    }

    function testAdjustBudget_ExactlyReservedEqualsUsed() public view {
        // All usage was from this single reservation
        uint128 result = lib.adjustBudget(1000, 1000, 500);
        assertEq(result, 500);
    }

    function testFuzz_AdjustBudget(uint128 usedInEpoch, uint128 reserved, uint128 actual) public view {
        // reserved <= usedInEpoch (reservation was included in used)
        // actual <= reserved (ERC-4337 guarantee)
        vm.assume(reserved <= usedInEpoch);
        vm.assume(actual <= reserved);

        uint128 result = lib.adjustBudget(usedInEpoch, reserved, actual);
        assertEq(result, usedInEpoch - reserved + actual);
        // Result should always be <= original
        assertTrue(result <= usedInEpoch);
    }

    // -------- clampedDeduction --------

    function testClampedDeduction_SufficientBalance() public view {
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(1 ether, 0.5 ether);
        assertEq(newBal, 0.5 ether);
        assertEq(deducted, 0.5 ether);
    }

    function testClampedDeduction_ExactBalance() public view {
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(1 ether, 1 ether);
        assertEq(newBal, 0);
        assertEq(deducted, 1 ether);
    }

    function testClampedDeduction_InsufficientBalance() public view {
        // Deduction clamped to available balance
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(0.3 ether, 1 ether);
        assertEq(newBal, 0);
        assertEq(deducted, 0.3 ether);
    }

    function testClampedDeduction_ZeroBalance() public view {
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(0, 1 ether);
        assertEq(newBal, 0);
        assertEq(deducted, 0);
    }

    function testClampedDeduction_ZeroCost() public view {
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(1 ether, 0);
        assertEq(newBal, 1 ether);
        assertEq(deducted, 0);
    }

    function testFuzz_ClampedDeduction_NeverUnderflows(uint128 balance, uint128 cost) public view {
        (uint128 newBal, uint128 deducted) = lib.clampedDeduction(balance, cost);
        // Balance never goes negative
        assertTrue(newBal <= balance);
        // Deducted never exceeds balance or cost
        assertTrue(deducted <= balance);
        assertTrue(deducted <= cost);
        // Conservation: newBal + deducted == balance
        assertEq(uint256(newBal) + uint256(deducted), uint256(balance));
    }
}

// ============ PaymasterCalldataLib Tests ============

contract PaymasterCalldataLibTest is Test {
    CalldataLibWrapper lib;

    address constant TARGET = address(0xBEEF);
    bytes4 constant EXECUTE_SELECTOR = 0xb61d27f6;

    function setUp() public {
        lib = new CalldataLibWrapper();
    }

    // -------- parseExecuteCall --------

    function testParseExecute_ValidCallWithInnerSelector() public view {
        // Build valid execute(address,uint256,bytes) calldata
        bytes memory innerData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(42));
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, TARGET, uint256(0), innerData);

        (bool valid, bytes4 innerSelector) = lib.parseExecuteCall(callData, TARGET);
        assertTrue(valid);
        assertEq(innerSelector, bytes4(0xdeadbeef));
    }

    function testParseExecute_ValidCallEmptyInnerData() public view {
        // execute(target, 0, "") — empty inner data
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, TARGET, uint256(0), bytes(""));

        (bool valid, bytes4 innerSelector) = lib.parseExecuteCall(callData, TARGET);
        assertTrue(valid);
        assertEq(innerSelector, bytes4(0)); // No inner selector
    }

    function testParseExecute_WrongOuterSelector() public view {
        bytes memory callData = abi.encodeWithSelector(bytes4(0x12345678), TARGET, uint256(0), bytes(""));

        (bool valid,) = lib.parseExecuteCall(callData, TARGET);
        assertFalse(valid);
    }

    function testParseExecute_TargetMismatch() public view {
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0xDEAD), uint256(0), bytes(""));

        (bool valid,) = lib.parseExecuteCall(callData, TARGET);
        assertFalse(valid);
    }

    function testParseExecute_NonZeroValue() public view {
        // value must be 0 for sponsored calls
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, TARGET, uint256(1), bytes(""));

        (bool valid,) = lib.parseExecuteCall(callData, TARGET);
        assertFalse(valid);
    }

    function testParseExecute_TooShortCalldata_LessThan4() public view {
        (bool valid,) = lib.parseExecuteCall(hex"b61d27", TARGET);
        assertFalse(valid);
    }

    function testParseExecute_TooShortCalldata_LessThan0x64() public view {
        // 4-byte selector + some data but not enough for full execute args
        bytes memory callData = abi.encodePacked(EXECUTE_SELECTOR, bytes32(0));
        (bool valid,) = lib.parseExecuteCall(callData, TARGET);
        assertFalse(valid);
    }

    function testParseExecute_EmptyCalldata() public view {
        (bool valid,) = lib.parseExecuteCall(hex"", TARGET);
        assertFalse(valid);
    }

    function testParseExecute_RegisterAccountSelector() public view {
        // This is the real-world scenario: execute(registry, 0, registerAccount(bytes32,bytes))
        bytes4 registerAccount = bytes4(0xbff6de20);
        bytes memory innerData = abi.encodeWithSelector(registerAccount, bytes32(uint256(1)), bytes("pubkey"));
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, TARGET, uint256(0), innerData);

        (bool valid, bytes4 innerSelector) = lib.parseExecuteCall(callData, TARGET);
        assertTrue(valid);
        assertEq(innerSelector, registerAccount);
    }

    /// @dev L-33/L-34: a crafted non-canonical inner-bytes offset (not 0x60) must be REJECTED,
    ///      not silently parsed as a selector-0 call pointing at attacker-chosen calldata.
    function testParseExecute_NonStandardOffsetRejected() public view {
        // Hand-build execute(TARGET, 0, <offset=0x80>) then a length + payload. Offset 0x80 != 0x60.
        bytes memory callData = abi.encodePacked(
            EXECUTE_SELECTOR,
            bytes32(uint256(uint160(TARGET))), // target
            bytes32(uint256(0)), // value
            bytes32(uint256(0x80)), // non-standard bytes offset (should be 0x60)
            bytes32(uint256(0)), // filler word where the standard length would sit
            bytes32(uint256(4)), // inner length
            bytes4(0xdeadbeef), // inner selector the attacker hoped to smuggle
            bytes28(0)
        );
        (bool valid, bytes4 innerSelector) = lib.parseExecuteCall(callData, TARGET);
        assertFalse(valid, "non-standard offset must be rejected");
        assertEq(innerSelector, bytes4(0));
    }

    /// @dev L-33: a standard 0x60 offset with a declared inner length < 4 yields selector 0 but
    ///      still validates structurally (empty/short inner data is a legitimate case).
    function testParseExecute_ShortInnerDataYieldsZeroSelector() public view {
        bytes memory callData = abi.encodePacked(
            EXECUTE_SELECTOR,
            bytes32(uint256(uint160(TARGET))),
            bytes32(uint256(0)),
            bytes32(uint256(0x60)), // canonical offset
            bytes32(uint256(2)), // inner length = 2 (< 4)
            bytes2(0xaabb),
            bytes30(0)
        );
        (bool valid, bytes4 innerSelector) = lib.parseExecuteCall(callData, TARGET);
        assertTrue(valid, "short-inner-data envelope is structurally valid");
        assertEq(innerSelector, bytes4(0));
    }

    function testFuzz_ParseExecute_CorrectTarget(address target) public view {
        vm.assume(target != address(0));
        bytes memory innerData = abi.encodeWithSelector(bytes4(0xaabbccdd));
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, target, uint256(0), innerData);

        (bool valid,) = lib.parseExecuteCall(callData, target);
        assertTrue(valid);

        // Wrong target should fail
        if (target != address(1)) {
            (bool valid2,) = lib.parseExecuteCall(callData, address(1));
            assertFalse(valid2);
        }
    }
}
