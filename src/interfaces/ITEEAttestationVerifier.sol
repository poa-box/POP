// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title ITEEAttestationVerifier
 * @notice Pluggable verifier that turns a raw TEE attestation into a
 *         `(subject, measurement, expiry)` triple usable for on-chain
 *         authorization.
 *
 * @dev The verifier is the trust seam of the TEE-agent eligibility system.
 *      Implementations range in strength:
 *        - A trusted-notary signer (an off-chain service that itself runs DCAP
 *          quote verification and signs the result) — cheap, ships today, trust
 *          reduces to that signer. See `TrustedSignerAttestationVerifier`.
 *        - Full on-chain DCAP / TDX quote verification — trustless, expensive,
 *          a separate effort. It can be slotted in later via
 *          `TEEAgentEligibilityModule.setVerifier` without touching the module.
 *
 *      `verifyAttestation` MUST revert if the attestation is invalid, forged,
 *      or expired so callers can treat any successful return as authoritative.
 */
interface ITEEAttestationVerifier {
    /**
     * @notice Verify a raw attestation blob.
     * @param attestation Opaque, implementation-defined attestation bytes.
     * @return subject      The address the attestation binds (the enclave-derived wallet).
     * @return measurement  Identifier of the attested enclave image (e.g. a hash of TDX RTMRs/mrtd).
     * @return expiry       Unix timestamp after which this attestation is no longer valid.
     */
    function verifyAttestation(bytes calldata attestation)
        external
        view
        returns (address subject, bytes32 measurement, uint64 expiry);
}
