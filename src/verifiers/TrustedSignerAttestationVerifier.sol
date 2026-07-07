// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ITEEAttestationVerifier} from "../interfaces/ITEEAttestationVerifier.sol";

/**
 * @title TrustedSignerAttestationVerifier
 * @notice A pragmatic {ITEEAttestationVerifier}: an off-chain notary service
 *         runs the real DCAP/TDX quote verification and signs the resulting
 *         `(subject, measurement, expiry)` triple. This contract recovers and
 *         checks that signature.
 *
 * @dev Trust reduces to the notary `signer`. This is honest about its
 *      assumption and ships today; a trustless on-chain DCAP verifier can
 *      replace it later via `TEEAgentEligibilityModule.setVerifier` without any
 *      change to the eligibility module. The signed digest is bound to this
 *      verifier's address and chain id, so a signature cannot be replayed across
 *      chains or verifier deployments.
 *
 *      Attestation encoding (ABI):
 *        abi.encode(address subject, bytes32 measurement, uint64 expiry, bytes signature)
 */
contract TrustedSignerAttestationVerifier is ITEEAttestationVerifier {
    using ECDSA for bytes32;

    /// @notice Domain tag mixed into the signed digest.
    bytes32 public constant DOMAIN = keccak256("POA_TEE_ATTESTATION_V1");

    /// @notice Caller is not the governor.
    error NotGovernor();
    /// @notice A required address was zero.
    error ZeroAddress();
    /// @notice The recovered signer is not the trusted notary.
    error BadSignature();

    /// @notice Governance address that can rotate the signer.
    address public governor;
    /// @notice The trusted notary whose signature authenticates attestations.
    address public signer;

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);

    constructor(address governor_, address signer_) {
        if (governor_ == address(0) || signer_ == address(0)) revert ZeroAddress();
        governor = governor_;
        signer = signer_;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// @notice Rotate the trusted notary signer.
    function setSigner(address newSigner) external onlyGovernor {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Transfer governance.
    function transferGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        emit GovernorTransferred(governor, newGovernor);
        governor = newGovernor;
    }

    /**
     * @notice The digest the notary must sign for a given attestation triple,
     *         bound to this verifier and chain. Exposed so the off-chain signer
     *         and integration tests can reproduce it exactly.
     */
    function digest(address subject, bytes32 measurement, uint64 expiry) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, block.chainid, address(this), subject, measurement, expiry));
    }

    /// @inheritdoc ITEEAttestationVerifier
    function verifyAttestation(bytes calldata attestation)
        external
        view
        override
        returns (address subject, bytes32 measurement, uint64 expiry)
    {
        bytes memory signature;
        (subject, measurement, expiry, signature) = abi.decode(attestation, (address, bytes32, uint64, bytes));

        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(digest(subject, measurement, expiry));
        address recovered = ethHash.recover(signature);
        if (recovered != signer) revert BadSignature();
    }
}
