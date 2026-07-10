// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UserOpLib} from "../src/interfaces/PackedUserOperation.sol";

/// @title PaymasterHubGasUnpackTest
/// @notice Reference-vector unit tests for UserOpLib's ERC-4337 v0.7 gas-word (de)packing.
/// @dev Reference: ERC-4337 v0.7 canonical packing as implemented by eth-infinitism's
///      `UserOperationLib` (account-abstraction repo). Canonical layout:
///        - accountGasLimits: verificationGasLimit in the HIGH 128 bits, callGasLimit in the LOW.
///        - gasFees: maxPriorityFeePerGas in the HIGH 128 bits, maxFeePerGas in the LOW.
///      pack: (uint256(hi) << 128) | lo. unpack: hi = x >> 128, lo = uint128(x).
///
///      These vectors are HARDCODED as raw bytes32 words (constructed WITHOUT UserOpLib) with
///      ASYMMETRIC halves. This is deliberate: an earlier revision of UserOpLib had all four
///      helpers reversed, and because the round-trip pack→unpack cancels a symmetric swap, a test
///      built with the library's own pack helper could not detect it. Asymmetric hardcoded words
///      make a re-introduced swap observable — the WRONG mapping is asserted false.
contract PaymasterHubGasUnpackTest is Test {
    // ─── Canonical reference vectors (raw words, NOT built via UserOpLib) ───
    // accountGasLimits: HIGH = verificationGasLimit = 1_500_000 (0x16E360),
    //                   LOW  = callGasLimit        =   500_000 (0x07A120).
    uint128 constant VERIFICATION_GAS = 1_500_000;
    uint128 constant CALL_GAS = 500_000;
    bytes32 constant ACCOUNT_GAS_LIMITS_CANONICAL = bytes32((uint256(VERIFICATION_GAS) << 128) | uint256(CALL_GAS));

    // gasFees: HIGH = maxPriorityFeePerGas = 2 gwei, LOW = maxFeePerGas = 50 gwei.
    uint128 constant MAX_PRIORITY_FEE = 2 gwei;
    uint128 constant MAX_FEE = 50 gwei;
    bytes32 constant GAS_FEES_CANONICAL = bytes32((uint256(MAX_PRIORITY_FEE) << 128) | uint256(MAX_FEE));

    /*═══════════════════ unpackAccountGasLimits ═══════════════════*/

    function test_unpackAccountGasLimits_canonicalMapping() public pure {
        (uint128 verification, uint128 call) = UserOpLib.unpackAccountGasLimits(ACCOUNT_GAS_LIMITS_CANONICAL);
        // HIGH half → verificationGasLimit, LOW half → callGasLimit (ERC-4337 v0.7).
        assertEq(verification, VERIFICATION_GAS, "verificationGasLimit must be the HIGH 128 bits (1.5M)");
        assertEq(call, CALL_GAS, "callGasLimit must be the LOW 128 bits (500k)");
    }

    /// @dev The reversed mapping — what the pre-fix (swapped) lib produced — must be FALSE.
    function test_unpackAccountGasLimits_reversedMappingIsWrong() public pure {
        (uint128 verification, uint128 call) = UserOpLib.unpackAccountGasLimits(ACCOUNT_GAS_LIMITS_CANONICAL);
        assertTrue(verification != CALL_GAS, "verification must NOT decode to the LOW half (would be the swap bug)");
        assertTrue(call != VERIFICATION_GAS, "call must NOT decode to the HIGH half (would be the swap bug)");
    }

    /*═══════════════════ unpackGasFees ═══════════════════*/

    function test_unpackGasFees_canonicalMapping() public pure {
        (uint128 priority, uint128 maxFee) = UserOpLib.unpackGasFees(GAS_FEES_CANONICAL);
        // HIGH half → maxPriorityFeePerGas, LOW half → maxFeePerGas (ERC-4337 v0.7).
        assertEq(priority, MAX_PRIORITY_FEE, "maxPriorityFeePerGas must be the HIGH 128 bits (2 gwei)");
        assertEq(maxFee, MAX_FEE, "maxFeePerGas must be the LOW 128 bits (50 gwei)");
    }

    /// @dev The reversed mapping must be FALSE.
    function test_unpackGasFees_reversedMappingIsWrong() public pure {
        (uint128 priority, uint128 maxFee) = UserOpLib.unpackGasFees(GAS_FEES_CANONICAL);
        assertTrue(priority != MAX_FEE, "priority must NOT decode to the LOW half (would be the swap bug)");
        assertTrue(maxFee != MAX_PRIORITY_FEE, "maxFee must NOT decode to the HIGH half (would be the swap bug)");
    }

    /*═══════════════════ pack matches the hardcoded canonical word ═══════════════════*/

    function test_packAccountGasLimits_equalsCanonicalWord() public pure {
        bytes32 packed = UserOpLib.packAccountGasLimits(VERIFICATION_GAS, CALL_GAS);
        assertEq(packed, ACCOUNT_GAS_LIMITS_CANONICAL, "packAccountGasLimits must produce the canonical raw word");
    }

    function test_packGasFees_equalsCanonicalWord() public pure {
        bytes32 packed = UserOpLib.packGasFees(MAX_PRIORITY_FEE, MAX_FEE);
        assertEq(packed, GAS_FEES_CANONICAL, "packGasFees must produce the canonical raw word");
    }

    /*═══════════════════ round-trip through the raw word ═══════════════════*/

    function test_accountGasLimits_roundTripThroughRawWord() public pure {
        (uint128 verification, uint128 call) = UserOpLib.unpackAccountGasLimits(ACCOUNT_GAS_LIMITS_CANONICAL);
        assertEq(UserOpLib.packAccountGasLimits(verification, call), ACCOUNT_GAS_LIMITS_CANONICAL, "round-trip drift");
    }

    function test_gasFees_roundTripThroughRawWord() public pure {
        (uint128 priority, uint128 maxFee) = UserOpLib.unpackGasFees(GAS_FEES_CANONICAL);
        assertEq(UserOpLib.packGasFees(priority, maxFee), GAS_FEES_CANONICAL, "round-trip drift");
    }
}
