// SPDX-License-Identifier: MIT
// Vendored from zkemail/email-tx-builder
// https://github.com/zkemail/email-tx-builder/blob/main/packages/contracts/src/interfaces/IGroth16Verifier.sol
pragma solidity ^0.8.21;

interface IGroth16Verifier {
    function verifyProof(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[34] calldata _pubSignals
    ) external view returns (bool);
}
