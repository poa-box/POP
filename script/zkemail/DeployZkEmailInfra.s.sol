// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";
import {ZkEmailProof} from "../../src/zkemail/IVerifier.sol";

/*
 * ============================================================================
 * Deploy the ZK Email cryptographic infrastructure (per chain)
 * ============================================================================
 *
 * Deploys the two contracts the ZkEmailInvites module needs to verify email
 * proofs on-chain. None of these are deployed on Gnosis/Arbitrum today, so they
 * must be stood up fresh:
 *
 *   1. Groth16Verifier — snarkjs-generated proof verifier (vendored verbatim) for the
 *      PopRoleClaim circuit (3 public signals). The module calls it directly.
 *   2. PoaDKIMRegistry  — owner-managed ERC-7969 DKIM key-hash allowlist.
 *
 * Then (broadcast only) it seeds the DKIM key for INVITE_DOMAIN and wires the addresses into
 * the OrgDeployer via Satellite.adminCall(setZkEmailInfrastructure). The wire step REQUIRES the
 * OrgDeployer to already be on the ZK-aware impl — run UpgradeProtocolForZkEmail first.
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
        returns (Groth16Verifier verifier, PoaDKIMRegistry registry, address groth16)
    {
        verifier = new Groth16Verifier();
        groth16 = address(verifier);
        registry = new PoaDKIMRegistry(registryOwner);
    }

    /// @dev A structurally-valid (all coords < field q) but cryptographically-bogus proof. The real
    ///      Groth16 verifier should run the full pairing check and return false — proving the
    ///      deployed verifier actually executes, not a stub.
    function _bogusProof(string memory domain, bytes32 keyHash) internal pure returns (ZkEmailProof memory p) {
        p = ZkEmailProof({
            pA: [uint256(1), uint256(2)],
            pB: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            pC: [uint256(5), uint256(6)],
            pubkeyHash: keyHash,
            emailNullifier: bytes32(uint256(7)),
            domainName: domain
        });
    }
}

contract SimDeployInfraGnosis is DeployInfraBase {
    function run() public {
        console.log("\n=== SIM: Deploy ZK Email infra (Gnosis) ===");

        (Groth16Verifier verifier, PoaDKIMRegistry registry, address groth16) = _deployInfra(HUDSON);
        require(groth16.code.length > 0, "Groth16Verifier has no code");
        require(address(verifier).code.length > 0, "Verifier has no code");
        require(address(registry).code.length > 0, "Registry has no code");
        console.log("  Groth16Verifier:", groth16);
        console.log("  PoaDKIMRegistry:", address(registry));

        // The REAL verifier executes the pairing check and rejects a bogus proof (not a stub).
        bytes32 keyHash = keccak256("sim-dkim-key");
        ZkEmailProof memory bogus = _bogusProof("gmail.com", keyHash);
        uint256[3] memory signals =
            [uint256(bogus.pubkeyHash), uint256(bogus.emailNullifier), uint256(uint160(address(0)))];
        require(!verifier.verifyProof(bogus.pA, bogus.pB, bogus.pC, signals), "bogus proof accepted!");
        console.log("  Real Groth16 verifier rejected a bogus proof OK");

        // Registry: seeded key valid, everything else invalid.
        vm.prank(HUDSON);
        registry.setKeyForDomain("Gmail.com", keyHash, true);
        require(registry.isKeyHashValid(registry.domainHashOf("gmail.com"), keyHash), "seeded key not valid");
        require(!registry.isKeyHashValid(registry.domainHashOf("gmail.com"), keccak256("other")), "stray key valid");
        require(!registry.isKeyHashValid(registry.domainHashOf("evil.com"), keyHash), "wrong domain valid");
        console.log("  PoaDKIMRegistry seed + lookup OK (domain hashing matches module)");

        console.log("PASS: ZK Email infra deploys and the real verifier runs on a Gnosis fork.");
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
        (Groth16Verifier verifier, PoaDKIMRegistry registry, address groth16) = _deployInfra(registryOwner);
        // Seed the real DKIM key (works in-broadcast only if registryOwner == Hudson; else seed separately).
        if (registryOwner == HUDSON) {
            registry.setKeyForDomain(domain, keyHash, true);
        }
        // Wire into the OrgDeployer (REQUIRES UpgradeProtocolForZkEmail already broadcast).
        ISatelliteInfra(GNOSIS_SATELLITE)
            .adminCall(
                GNOSIS_ORG_DEPLOYER,
                abi.encodeWithSignature(
                    "setZkEmailInfrastructure(address,address)", address(verifier), address(registry)
                )
            );
        vm.stopBroadcast();

        console.log("Groth16Verifier:", groth16);
        console.log("ZK_VERIFIER:", address(verifier));
        console.log("ZK_DKIM_REGISTRY:", address(registry));
        console.log("Wired into OrgDeployer via setZkEmailInfrastructure.");
        if (registryOwner != HUDSON) {
            console.log("NOTE: registry owner != Hudson - seed DKIM keys separately via setKeyForDomain.");
        }
    }
}
