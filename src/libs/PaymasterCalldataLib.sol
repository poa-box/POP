// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/// @title PaymasterCalldataLib
/// @author POA Engineering
/// @notice Calldata parsing for ERC-4337 execute(address,uint256,bytes) envelope validation
/// @dev Extracts and validates the target, value, and inner selector from a UserOp's callData
///      when it follows the standard SimpleAccount/PasskeyAccount execute pattern.
///      All functions are internal pure (inlined at compile time) for zero gas overhead.
library PaymasterCalldataLib {
    /// @notice Selector for execute(address,uint256,bytes)
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;

    /// @notice Parse and validate an execute(address,uint256,bytes) calldata envelope
    /// @dev Checks: callData >= 4 bytes, outer selector = EXECUTE_SELECTOR, callData >= 0x64 bytes,
    ///      target matches expectedTarget, and value == 0. The inner bytes parameter's ABI offset
    ///      MUST be the canonical 0x60 (L-33/L-34): a non-standard offset can point the "inner data"
    ///      at arbitrary calldata, so it is rejected as invalid rather than silently parsed as a
    ///      selector-0 call. When the inner payload has fewer than 4 bytes, innerSelector is left as
    ///      bytes4(0) (an empty-data / raw-value inner call), which is a real, distinguishable case.
    /// @param callData The full callData from the UserOperation
    /// @param expectedTarget The required target address in the execute call
    /// @return valid True if all structural checks pass (selector, length, target, value, offset)
    /// @return innerSelector First 4 bytes of the inner data payload (bytes4(0) if inner data < 4 bytes)
    function parseExecuteCall(bytes calldata callData, address expectedTarget)
        internal
        pure
        returns (bool valid, bytes4 innerSelector)
    {
        // Must have at least a 4-byte selector
        if (callData.length < 4) return (false, bytes4(0));

        // Outer selector must be execute(address,uint256,bytes)
        if (bytes4(callData[0:4]) != EXECUTE_SELECTOR) return (false, bytes4(0));

        // Need at least 0x64 bytes for execute(address, uint256, bytes offset)
        if (callData.length < 0x64) return (false, bytes4(0));

        address target;
        uint256 value;
        uint256 dataOffset;
        assembly {
            target := calldataload(add(callData.offset, 0x04))
            value := calldataload(add(callData.offset, 0x24))
            // Inner bytes ABI offset (relative to the start of the args at 0x04).
            dataOffset := calldataload(add(callData.offset, 0x44))
        }

        // Target must match and value must be zero.
        if (target != expectedTarget || value != 0) return (false, bytes4(0));

        // Reject any non-canonical ABI offset — the only valid layout for the 3rd dynamic
        // param is 0x60. Anything else is a crafted envelope trying to misdirect the parse.
        if (dataOffset != 0x60) return (false, bytes4(0));

        // The inner data length word sits at 0x04 + 0x60 = 0x64; its bytes start at 0x84.
        // Require the length word itself to be in bounds (callData >= 0x84).
        if (callData.length < 0x84) return (false, bytes4(0));

        uint256 innerLen;
        assembly {
            innerLen := calldataload(add(callData.offset, 0x64))
        }
        // Extract the inner selector only when the declared inner data actually holds 4 bytes
        // that are present in calldata. Otherwise it is an empty/short inner call (selector 0).
        if (innerLen >= 4 && callData.length >= 0x84 + 4) {
            bytes4 sel;
            assembly {
                sel := calldataload(add(callData.offset, 0x84))
            }
            innerSelector = sel;
        }

        valid = true;
    }
}
