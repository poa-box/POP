// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {ITEEAttestationVerifier} from "../../src/interfaces/ITEEAttestationVerifier.sol";

/**
 * @notice Test verifier that trusts the attestation payload verbatim (no crypto).
 *         The attestation is `abi.encode(address subject, bytes32 measurement,
 *         uint64 expiry)`. Lets tests exercise the eligibility module's logic in
 *         isolation from any signature scheme. Set `shouldRevert` to simulate an
 *         invalid attestation.
 */
contract MockTEEAttestationVerifier is ITEEAttestationVerifier {
    bool public shouldRevert;

    error MockRejected();

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    /// @notice Helper to build a mock attestation blob.
    function encode(address subject, bytes32 measurement, uint64 expiry) external pure returns (bytes memory) {
        return abi.encode(subject, measurement, expiry);
    }

    function verifyAttestation(bytes calldata attestation)
        external
        view
        override
        returns (address subject, bytes32 measurement, uint64 expiry)
    {
        if (shouldRevert) revert MockRejected();
        (subject, measurement, expiry) = abi.decode(attestation, (address, bytes32, uint64));
    }
}
