// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/// @notice Targets ERC-4337 v0.7 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

/// @dev ERC-4337 v0.7 canonical packing (mirrors eth-infinitism UserOperationLib): the HIGH
///      128 bits hold verificationGasLimit / maxPriorityFeePerGas, the LOW 128 bits hold
///      callGasLimit / maxFeePerGas. This MUST match what the real EntryPoint (and viem/Pimlico/
///      every bundler) puts on the wire — an earlier revision had all four helpers reversed, which
///      made org rule gas hints and fee caps compare against the wrong field. Never validate this
///      encode/decode pair only against its own inverse; the tests carry hardcoded canonical
///      reference vectors so a re-introduced swap cannot round-trip its way to green.
library UserOpLib {
    function unpackAccountGasLimits(bytes32 accountGasLimits)
        internal
        pure
        returns (uint128 verificationGasLimit, uint128 callGasLimit)
    {
        verificationGasLimit = uint128(uint256(accountGasLimits >> 128));
        callGasLimit = uint128(uint256(accountGasLimits));
    }

    function packAccountGasLimits(uint128 verificationGasLimit, uint128 callGasLimit) internal pure returns (bytes32) {
        return bytes32((uint256(verificationGasLimit) << 128) | uint256(callGasLimit));
    }

    /// @notice Unpack gasFees into maxPriorityFeePerGas (high 128) and maxFeePerGas (low 128)
    function unpackGasFees(bytes32 gasFees) internal pure returns (uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) {
        maxPriorityFeePerGas = uint128(uint256(gasFees >> 128));
        maxFeePerGas = uint128(uint256(gasFees));
    }

    /// @notice Pack maxPriorityFeePerGas (high 128) and maxFeePerGas (low 128) into gasFees
    function packGasFees(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) internal pure returns (bytes32) {
        return bytes32((uint256(maxPriorityFeePerGas) << 128) | uint256(maxFeePerGas));
    }
}
