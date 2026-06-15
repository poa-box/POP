// SPDX-License-Identifier: MIT
// Adapted from zkemail/email-tx-builder
// https://github.com/zkemail/email-tx-builder/blob/main/packages/contracts/src/utils/Verifier.sol
//
// Difference from upstream: upstream is UUPS/Ownable-upgradeable and binds the Groth16Verifier via
// initialize(). To avoid pulling zk-email's OpenZeppelin-upgradeable dependency tree (whose import
// paths differ from POP's remappings), this is a minimal NON-upgradeable wrapper that takes the
// Groth16Verifier as an immutable constructor arg. The security-critical logic — verifyEmailProof,
// _packBytes2Fields, and the circuit public-signal constants — is copied VERBATIM from upstream, so
// the public-signal layout handed to the Groth16 verifier is byte-for-byte identical.
//
// If the circuit/verifying key ever changes, deploy a fresh Verifier and repoint via
// ZkEmailInvites.setVerifier (governance) — same effect as upstream's updateGroth16Verifier.
pragma solidity ^0.8.21;

import {IVerifier, EmailProof} from "../IVerifier.sol";
import {IGroth16Verifier} from "./IGroth16Verifier.sol";

contract Verifier is IVerifier {
    IGroth16Verifier public immutable groth16Verifier;

    uint256 public constant DOMAIN_FIELDS = 9;
    uint256 public constant DOMAIN_BYTES = 255;
    uint256 public constant COMMAND_FIELDS = 20;
    uint256 public constant COMMAND_BYTES = 605;

    // Base field size
    uint256 constant q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    error InvalidGroth16Verifier();

    constructor(address _groth16Verifier) {
        if (_groth16Verifier == address(0)) revert InvalidGroth16Verifier();
        groth16Verifier = IGroth16Verifier(_groth16Verifier);
    }

    function commandBytes() external pure returns (uint256) {
        return COMMAND_BYTES;
    }

    function verifyEmailProof(EmailProof memory proof) public view returns (bool) {
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC) =
            abi.decode(proof.proof, (uint256[2], uint256[2][2], uint256[2]));
        require(pA[0] < q && pA[1] < q, "invalid format of pA");
        require(pB[0][0] < q && pB[0][1] < q && pB[1][0] < q && pB[1][1] < q, "invalid format of pB");
        require(pC[0] < q && pC[1] < q, "invalid format of pC");
        uint256[DOMAIN_FIELDS + COMMAND_FIELDS + 5] memory pubSignals;
        uint256[] memory stringFields;
        stringFields = _packBytes2Fields(bytes(proof.domainName), DOMAIN_BYTES);
        for (uint256 i = 0; i < DOMAIN_FIELDS; i++) {
            pubSignals[i] = stringFields[i];
        }
        pubSignals[DOMAIN_FIELDS] = uint256(proof.publicKeyHash);
        pubSignals[DOMAIN_FIELDS + 1] = uint256(proof.emailNullifier);
        pubSignals[DOMAIN_FIELDS + 2] = uint256(proof.timestamp);
        stringFields = _packBytes2Fields(bytes(proof.maskedCommand), COMMAND_BYTES);
        for (uint256 i = 0; i < COMMAND_FIELDS; i++) {
            pubSignals[DOMAIN_FIELDS + 3 + i] = stringFields[i];
        }
        pubSignals[DOMAIN_FIELDS + 3 + COMMAND_FIELDS] = uint256(proof.accountSalt);
        pubSignals[DOMAIN_FIELDS + 3 + COMMAND_FIELDS + 1] = proof.isCodeExist ? 1 : 0;

        return groth16Verifier.verifyProof(pA, pB, pC, pubSignals);
    }

    function _packBytes2Fields(bytes memory _bytes, uint256 _paddedSize) private pure returns (uint256[] memory) {
        uint256 remain = _paddedSize % 31;
        uint256 numFields = (_paddedSize - remain) / 31;
        if (remain > 0) {
            numFields += 1;
        }
        uint256[] memory fields = new uint256[](numFields);
        uint256 idx = 0;
        uint256 byteVal = 0;
        for (uint256 i = 0; i < numFields; i++) {
            for (uint256 j = 0; j < 31; j++) {
                idx = i * 31 + j;
                if (idx >= _paddedSize) {
                    break;
                }
                if (idx >= _bytes.length) {
                    byteVal = 0;
                } else {
                    byteVal = uint256(uint8(_bytes[idx]));
                }
                if (j == 0) {
                    fields[i] = byteVal;
                } else {
                    fields[i] += (byteVal << (8 * j));
                }
            }
        }
        return fields;
    }
}
