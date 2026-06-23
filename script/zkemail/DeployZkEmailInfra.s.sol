// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";
import {ZkEmailProof, ZkEmailProofV2} from "../../src/zkemail/IVerifier.sol";

/*
 * ============================================================================
 * Deploy the ZK Email cryptographic infrastructure (per chain)
 * ============================================================================
 *
 * Deploys the three contracts the ZkEmailInvites module needs to verify email
 * proofs on-chain. None of these are deployed on Gnosis/Arbitrum today, so they
 * must be stood up fresh:
 *
 *   1. Groth16Verifier   — snarkjs-generated proof verifier (vendored verbatim) for the
 *      PopRoleClaim circuit (3 public signals). The module calls it for whole-domain claims.
 *   2. Groth16VerifierV2 — snarkjs-generated verifier for the PopRoleClaimV2 circuit
 *      (4 public signals; the 4th is `emailHash`). The module calls it for specific-address claims.
 *   3. PoaDKIMRegistry   — owner-managed ERC-7969 DKIM key-hash allowlist.
 *
 * Then (broadcast only) it seeds the DKIM key for INVITE_DOMAIN and wires the addresses into
 * the OrgDeployer via Satellite.adminCall(setZkEmailInfrastructure(domain, email, dkim)). The wire
 * step REQUIRES the OrgDeployer to already be on the ZK-aware impl — run UpgradeProtocolForZkEmail first.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/DeployZkEmailInfra.s.sol:SimDeployInfraGnosis --fork-url gnosis -vvv
 *
 *   INVITE_DOMAIN=gmail.com DKIM_KEY_HASH=0x<poseidon-key-hash> \
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/DeployZkEmailInfra.s.sol:BroadcastDeployInfraGnosis --rpc-url gnosis --broadcast --slow
 *
 * DKIM_KEY_HASH is the real publicKeyHash for the domain (from zk-email's DKIM registry / DNS) —
 * do NOT fabricate it; a wrong hash makes every proof for that domain fail.
 * ============================================================================
 */

interface ISatelliteInfra {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
}

abstract contract DeployInfraBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;

    function _deployInfra(address registryOwner)
        internal
        returns (Groth16Verifier domainVerifier, Groth16VerifierV2 emailVerifier, PoaDKIMRegistry registry)
    {
        domainVerifier = new Groth16Verifier();
        emailVerifier = new Groth16VerifierV2();
        registry = new PoaDKIMRegistry(registryOwner);
    }

    /// @dev A structurally-valid (all coords < field q) but cryptographically-bogus DOMAIN proof (3
    ///      signals). The real Groth16Verifier should run the full pairing check and return false —
    ///      proving the deployed verifier actually executes, not a stub.
    function _bogusDomainProof(string memory domain, bytes32 keyHash) internal pure returns (ZkEmailProof memory p) {
        p = ZkEmailProof({
            pA: [uint256(1), uint256(2)],
            pB: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            pC: [uint256(5), uint256(6)],
            pubkeyHash: keyHash,
            emailNullifier: bytes32(uint256(7)),
            domainName: domain
        });
    }

    /// @dev Bogus EMAIL proof (4 signals; adds emailHash) for the V2 verifier.
    function _bogusEmailProof(string memory domain, bytes32 keyHash) internal pure returns (ZkEmailProofV2 memory p) {
        p = ZkEmailProofV2({
            pA: [uint256(1), uint256(2)],
            pB: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            pC: [uint256(5), uint256(6)],
            pubkeyHash: keyHash,
            emailNullifier: bytes32(uint256(7)),
            domainName: domain,
            emailHash: bytes32(uint256(8))
        });
    }
}

contract SimDeployInfraGnosis is DeployInfraBase {
    function run() public {
        console.log("\n=== SIM: Deploy ZK Email infra (Gnosis) ===");

        (Groth16Verifier domainVerifier, Groth16VerifierV2 emailVerifier, PoaDKIMRegistry registry) =
            _deployInfra(HUDSON);
        require(address(domainVerifier).code.length > 0, "Domain verifier has no code");
        require(address(emailVerifier).code.length > 0, "Email verifier has no code");
        require(address(registry).code.length > 0, "Registry has no code");
        console.log("  Groth16Verifier (domain):", address(domainVerifier));
        console.log("  Groth16VerifierV2 (email):", address(emailVerifier));
        console.log("  PoaDKIMRegistry:", address(registry));

        // Both REAL verifiers execute the pairing check and reject a bogus proof (not stubs).
        bytes32 keyHash = keccak256("sim-dkim-key");

        ZkEmailProof memory bogusDomain = _bogusDomainProof("gmail.com", keyHash);
        uint256[3] memory dSignals =
            [uint256(bogusDomain.pubkeyHash), uint256(bogusDomain.emailNullifier), uint256(uint160(address(0)))];
        require(
            !domainVerifier.verifyProof(bogusDomain.pA, bogusDomain.pB, bogusDomain.pC, dSignals),
            "bogus domain proof accepted!"
        );
        console.log("  Real domain verifier (uint[3]) rejected a bogus proof OK");

        ZkEmailProofV2 memory bogusEmail = _bogusEmailProof("gmail.com", keyHash);
        uint256[4] memory eSignals = [
            uint256(bogusEmail.pubkeyHash),
            uint256(bogusEmail.emailNullifier),
            uint256(uint160(address(0))),
            uint256(bogusEmail.emailHash)
        ];
        require(
            !emailVerifier.verifyProof(bogusEmail.pA, bogusEmail.pB, bogusEmail.pC, eSignals),
            "bogus email proof accepted!"
        );
        console.log("  Real email verifier (uint[4]) rejected a bogus proof OK");

        // Registry: seeded key valid, everything else invalid.
        vm.prank(HUDSON);
        registry.setKeyForDomain("Gmail.com", keyHash, true);
        require(registry.isKeyHashValid(registry.domainHashOf("gmail.com"), keyHash), "seeded key not valid");
        require(!registry.isKeyHashValid(registry.domainHashOf("gmail.com"), keccak256("other")), "stray key valid");
        require(!registry.isKeyHashValid(registry.domainHashOf("evil.com"), keyHash), "wrong domain valid");
        console.log("  PoaDKIMRegistry seed + lookup OK (domain hashing matches module)");

        console.log("PASS: ZK Email infra deploys and both real verifiers run on a Gnosis fork.");
    }
}

contract BroadcastDeployInfraGnosis is DeployInfraBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson");
        string memory domain = vm.envOr("INVITE_DOMAIN", string("gmail.com"));
        bytes32 keyHash = vm.envBytes32("DKIM_KEY_HASH"); // real publicKeyHash; reverts if unset
        address registryOwner = vm.envOr("REGISTRY_OWNER", HUDSON);

        vm.startBroadcast(key);
        (Groth16Verifier domainVerifier, Groth16VerifierV2 emailVerifier, PoaDKIMRegistry registry) =
            _deployInfra(registryOwner);
        // Seed the real DKIM key (works in-broadcast only if registryOwner == Hudson; else seed separately).
        if (registryOwner == HUDSON) {
            registry.setKeyForDomain(domain, keyHash, true);
        }
        // Wire BOTH verifiers + the registry into the OrgDeployer
        // (REQUIRES UpgradeProtocolForZkEmail already broadcast).
        ISatelliteInfra(GNOSIS_SATELLITE)
            .adminCall(
                GNOSIS_ORG_DEPLOYER,
                abi.encodeWithSignature(
                    "setZkEmailInfrastructure(address,address,address)",
                    address(domainVerifier),
                    address(emailVerifier),
                    address(registry)
                )
            );
        vm.stopBroadcast();

        console.log("ZK_DOMAIN_VERIFIER:", address(domainVerifier));
        console.log("ZK_EMAIL_VERIFIER:", address(emailVerifier));
        console.log("ZK_DKIM_REGISTRY:", address(registry));
        console.log("Wired into OrgDeployer via setZkEmailInfrastructure(domain, email, dkim).");
        if (registryOwner != HUDSON) {
            console.log("NOTE: registry owner != Hudson - seed DKIM keys separately via setKeyForDomain.");
        }
    }
}
