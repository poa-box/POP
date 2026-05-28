// SPDX-License-Identifier: MIT
// Vendored verbatim from zkemail/email-tx-builder
// https://github.com/zkemail/email-tx-builder/blob/main/packages/contracts/src/interfaces/IVerifier.sol
pragma solidity ^0.8.21;

struct EmailProof {
    string domainName; // Domain name of the sender's email
    bytes32 publicKeyHash; // Hash of the DKIM public key used in email/proof
    uint256 timestamp; // Timestamp of the email
    string maskedCommand; // Masked command of the email
    bytes32 emailNullifier; // Nullifier of the email to prevent its reuse.
    bytes32 accountSalt; // Create2 salt of the account
    bool isCodeExist; // Check if the account code is exist
    bytes proof; // ZK Proof of Email
}

interface IVerifier {
    function commandBytes() external view returns (uint256);
    function verifyEmailProof(EmailProof memory proof) external view returns (bool);
}
