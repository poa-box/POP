// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title CommandUtils
/// @notice Minimal helpers for parsing the `maskedCommand` field of a ZK Email proof.
/// @dev Upstream zkemail/email-tx-builder ships a full template engine
///      (computeExpectedCommand + {string}/{uint}/{int}/{decimals}/{ethAddr} matchers).
///      This module only needs to bind the proof to a claimer address, so we parse
///      the trailing "0x…" hex address directly. Saves ~200 lines and ~1 OZ import.
library CommandUtils {
    error InvalidCommand();

    /// @notice Extract an Ethereum address from the trailing 42 chars of `cmd`.
    /// @dev Expected template: any prefix followed by "0xHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH".
    ///      Case-insensitive on hex digits. Reverts `InvalidCommand` if the trailing 42 chars
    ///      are not a valid "0x"-prefixed hex address.
    function extractTrailingEthAddr(string memory cmd) internal pure returns (address) {
        bytes memory b = bytes(cmd);
        if (b.length < 42) revert InvalidCommand();

        uint256 start = b.length - 42;
        if (b[start] != bytes1("0") || (b[start + 1] != bytes1("x") && b[start + 1] != bytes1("X"))) {
            revert InvalidCommand();
        }

        uint256 acc;
        for (uint256 i = start + 2; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            uint256 digit;
            if (c >= 0x30 && c <= 0x39) {
                digit = c - 0x30; // 0-9
            } else if (c >= 0x41 && c <= 0x46) {
                digit = c - 0x41 + 10; // A-F
            } else if (c >= 0x61 && c <= 0x66) {
                digit = c - 0x61 + 10; // a-f
            } else {
                revert InvalidCommand();
            }
            acc = (acc << 4) | digit;
        }
        return address(uint160(acc));
    }
}
