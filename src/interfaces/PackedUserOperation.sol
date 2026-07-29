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

library UserOpLib {
    /// @dev ERC-4337 v0.7 packing (EntryPoint UserOperationLib): the HIGH 128 bits carry
    ///      verificationGasLimit, the LOW 128 bits carry callGasLimit. NOTE: an earlier version of this
    ///      library had BOTH unpack/pack pairs reversed — internally consistent (tests round-tripped),
    ///      but misread real UserOps from the canonical EntryPoint, so rule gas hints and fee caps
    ///      silently constrained the WRONG fields (the deployed-hub accountGasLimits-swap bug).
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

    /// @notice Unpack gasFees into maxPriorityFeePerGas (HIGH 128 bits) and maxFeePerGas (LOW 128 bits)
    function unpackGasFees(bytes32 gasFees) internal pure returns (uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) {
        maxPriorityFeePerGas = uint128(uint256(gasFees >> 128));
        maxFeePerGas = uint128(uint256(gasFees));
    }

    /// @notice Pack maxPriorityFeePerGas and maxFeePerGas into gasFees (v0.7 layout)
    function packGasFees(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) internal pure returns (bytes32) {
        return bytes32((uint256(maxPriorityFeePerGas) << 128) | uint256(maxFeePerGas));
    }
}
