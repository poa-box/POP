// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TEEAgentEligibilityModule} from "../src/TEEAgentEligibilityModule.sol";
import {TrustedSignerAttestationVerifier} from "../src/verifiers/TrustedSignerAttestationVerifier.sol";
import {MockTEEAttestationVerifier} from "./mocks/MockTEEAttestationVerifier.sol";

contract TEEAgentEligibilityModuleTest is Test {
    TEEAgentEligibilityModule internal module;
    MockTEEAttestationVerifier internal mock;

    address internal governor = address(0x6047);
    address internal agent = address(0xA9E7);
    uint256 internal constant HAT = 42;
    bytes32 internal constant IMAGE_A = keccak256("enclave-image-A");
    bytes32 internal constant IMAGE_B = keccak256("enclave-image-B");

    function setUp() public {
        mock = new MockTEEAttestationVerifier();
        TEEAgentEligibilityModule impl = new TEEAgentEligibilityModule();
        bytes memory data = abi.encodeCall(TEEAgentEligibilityModule.initialize, (governor, address(mock)));
        module = TEEAgentEligibilityModule(address(new ERC1967Proxy(address(impl), data)));
    }

    function _attest(address subject, bytes32 measurement, uint64 expiry) internal view returns (bytes memory) {
        return abi.encode(subject, measurement, expiry);
    }

    function _status(address who) internal view returns (bool eligible, bool standing) {
        return module.getWearerStatus(who, HAT);
    }

    /*──────────────── init / access ────────────────*/

    function testInitState() public view {
        assertEq(module.governor(), governor);
        assertEq(module.verifier(), address(mock));
    }

    function testImplInitializerDisabled() public {
        TEEAgentEligibilityModule impl = new TEEAgentEligibilityModule();
        vm.expectRevert();
        impl.initialize(governor, address(mock));
    }

    function testOnlyGovernorGates() public {
        vm.expectRevert(TEEAgentEligibilityModule.NotGovernor.selector);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);

        vm.expectRevert(TEEAgentEligibilityModule.NotGovernor.selector);
        module.setVerifier(address(mock));

        vm.expectRevert(TEEAgentEligibilityModule.NotGovernor.selector);
        module.transferGovernor(agent);
    }

    /*──────────────── happy path ────────────────*/

    function testAttestGrantsEligibility() public {
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);

        (bool e0,) = _status(agent);
        assertFalse(e0, "not eligible before attestation");

        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));

        (bool eligible, bool standing) = _status(agent);
        assertTrue(eligible, "eligible after attestation");
        assertTrue(standing, "standing tracks eligibility");

        (bytes32 m, uint64 exp, bool active) = module.bindingOf(agent, HAT);
        assertEq(m, IMAGE_A);
        assertEq(exp, uint64(block.timestamp + 1 days));
        assertTrue(active);
    }

    /*──────────────── rejections ────────────────*/

    function testDisallowedMeasurementReverts() public {
        vm.expectRevert(TEEAgentEligibilityModule.MeasurementNotAllowed.selector);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));
    }

    function testExpiredAttestationReverts() public {
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        vm.warp(1000);
        vm.expectRevert(TEEAgentEligibilityModule.AttestationExpired.selector);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(999)));
    }

    function testVerifierRevertPropagates() public {
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        mock.setShouldRevert(true);
        vm.expectRevert(MockTEEAttestationVerifier.MockRejected.selector);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));
    }

    /*──────────────── live revocation semantics ────────────────*/

    function testDisallowingMeasurementRevokesLive() public {
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));
        (bool before,) = _status(agent);
        assertTrue(before);

        // Governance retires image A (e.g. bumping the agent to image B):
        // every wallet on A loses the hat immediately, no per-wallet bookkeeping.
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, false);

        (bool afterFlag,) = _status(agent);
        assertFalse(afterFlag, "eligibility gone once measurement retired");
    }

    function testExpiryLapsesEligibility() public {
        vm.warp(1000);
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(1000 + 100)));

        (bool live,) = _status(agent);
        assertTrue(live);

        vm.warp(1000 + 101);
        (bool lapsed,) = _status(agent);
        assertFalse(lapsed, "stale attestation is not eligible");
    }

    function testRevokeBinding() public {
        vm.prank(governor);
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));

        vm.prank(governor);
        module.revokeBinding(agent, HAT);
        (bool eligible,) = _status(agent);
        assertFalse(eligible);

        // Re-attesting restores eligibility (image still allowed).
        module.submitAttestation(HAT, _attest(agent, IMAGE_A, uint64(block.timestamp + 1 days)));
        (bool eligible2,) = _status(agent);
        assertTrue(eligible2);
    }

    function testRevokeUnknownBindingReverts() public {
        vm.prank(governor);
        vm.expectRevert(TEEAgentEligibilityModule.NoBinding.selector);
        module.revokeBinding(agent, HAT);
    }

    function testSwapVerifier() public {
        MockTEEAttestationVerifier mock2 = new MockTEEAttestationVerifier();
        vm.prank(governor);
        module.setVerifier(address(mock2));
        assertEq(module.verifier(), address(mock2));
    }

    /*──────────────── real notary-signer verifier ────────────────*/

    function testTrustedSignerVerifierEndToEnd() public {
        (address notary, uint256 notaryPk) = makeAddrAndKey("notary");
        TrustedSignerAttestationVerifier v = new TrustedSignerAttestationVerifier(governor, notary);

        // Point the module at the real verifier and allow image A.
        vm.startPrank(governor);
        module.setVerifier(address(v));
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 dig = v.digest(agent, IMAGE_A, expiry);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(dig);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(notaryPk, ethHash);
        bytes memory sig = abi.encodePacked(sr, ss, sv);
        bytes memory attestation = abi.encode(agent, IMAGE_A, expiry, sig);

        module.submitAttestation(HAT, attestation);
        (bool eligible,) = _status(agent);
        assertTrue(eligible, "notary-signed attestation grants eligibility");
    }

    function testTrustedSignerRejectsForgedSignature() public {
        (address notary,) = makeAddrAndKey("notary");
        (, uint256 impostorPk) = makeAddrAndKey("impostor");
        TrustedSignerAttestationVerifier v = new TrustedSignerAttestationVerifier(governor, notary);

        vm.startPrank(governor);
        module.setVerifier(address(v));
        module.setMeasurementAllowed(HAT, IMAGE_A, true);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(v.digest(agent, IMAGE_A, expiry));
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(impostorPk, ethHash);
        bytes memory sig = abi.encodePacked(sr, ss, sv);

        vm.expectRevert(TrustedSignerAttestationVerifier.BadSignature.selector);
        module.submitAttestation(HAT, abi.encode(agent, IMAGE_A, expiry, sig));
    }
}
