// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";
import {ZkEmailProof, ZkEmailProofV2} from "../../src/zkemail/IVerifier.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * Deploy the ZK Email cryptographic infrastructure — CROSS-CHAIN
 * ============================================================================
 *
 * Stands up the three contracts ZkEmailInvites needs to verify proofs, on BOTH chains, and wires them
 * into the OrgDeployer via one Hyperlane dispatch — following the canonical cross-chain pattern.
 *
 *   1. Groth16Verifier   — vendored snarkjs verifier for PopRoleClaim (3 signals, whole-domain claims).
 *   2. Groth16VerifierV2 — vendored verifier for PopRoleClaimV2 (4 signals, specific-address claims).
 *   3. PoaDKIMRegistry   — owner-managed (Hudson) ERC-7969 DKIM key-hash allowlist.
 *
 * All three are DD-deployed at the SAME address on both chains (verifiers argless; the registry's only
 * ctor arg is the owner = Hudson, identical on both chains). Then:
 *   - Hudson seeds the DKIM key hashes for gmail.com + ku.edu directly on EACH chain's registry (Hudson
 *     owns it on both — keeping rotation hands-on / monitor-driven, not gated behind governance).
 *   - hub.adminCallCrossChain(ORG_DEPLOYER, setZkEmailInfrastructure(dv, ev, dkim)) wires both chains
 *     (ORG_DEPLOYER + all three infra addrs are identical on both chains).
 *
 * REQUIRES UpgradeProtocolForZkEmail already landed (OrgDeployer must be on the ZK-aware impl for
 * setZkEmailInfrastructure to exist). DKIM_KEY_HASH values are the real circuit pubkeyHashes — a wrong
 * value silently fails every proof for that domain; ku.edu is RSA-1024 (weak but supported). Defaults
 * are the values validated 2026-06-24; override via env if a key rotated.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/DeployZkEmailInfra.s.sol:SimInfraArbitrum --fork-url arbitrum -vvv
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/DeployZkEmailInfra.s.sol:Step1_DeployInfraOnGnosis --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/DeployZkEmailInfra.s.sol:Step2_DeployInfraFromArbitrum --rpc-url arbitrum --broadcast --slow
 *   forge script script/zkemail/DeployZkEmailInfra.s.sol:Step3_VerifyInfraGnosis --rpc-url gnosis
 * ============================================================================
 */

abstract contract DeployInfraBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c; // same both chains
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;

    uint256 internal constant HYPERLANE_FEE = 0.005 ether;
    string internal constant VERSION = "v-zkemail-1";

    // DKIM key hashes (== circuit pubkeyHash). Validated 2026-06-24 (~/pop-zk-work/dkim-hash.mjs).
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    bytes32 internal constant KU_KEYHASH = 0x198aa490f98ff2e619b0f48d7cd1885d604a1753b6c46b5f45b5ae2a8e8bc45f;

    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    function _domainVerifierSlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 10);
    }

    function _emailVerifierSlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 11);
    }

    function _dkimRegistrySlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 12);
    }

    function _readAddr(address proxy, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    function _ddDeploy(string memory typeName, bytes memory creationCode) internal returns (address addr) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, creationCode);
            require(deployed == addr, "DD address mismatch");
        }
    }

    function _deployInfra() internal returns (address domainVerifier, address emailVerifier, address registry) {
        domainVerifier = _ddDeploy("ZkDomainVerifier", type(Groth16Verifier).creationCode);
        emailVerifier = _ddDeploy("ZkEmailVerifier", type(Groth16VerifierV2).creationCode);
        // PoaDKIMRegistry(owner) — bake Hudson into the creationCode so the address is identical on both chains.
        registry =
            _ddDeploy("PoaDKIMRegistry", abi.encodePacked(type(PoaDKIMRegistry).creationCode, abi.encode(HUDSON)));
    }

    /// @dev Seed gmail.com + ku.edu key hashes on a registry the caller (Hudson) owns. Env-overridable.
    function _seedKeys(PoaDKIMRegistry registry) internal {
        registry.setKeyForDomain("gmail.com", vm.envOr("GMAIL_KEY_HASH", GMAIL_KEYHASH), true);
        registry.setKeyForDomain("ku.edu", vm.envOr("KU_KEY_HASH", KU_KEYHASH), true);
    }

    function _setInfraCalldata(address dv, address ev, address dkim) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setZkEmailInfrastructure(address,address,address)", dv, ev, dkim);
    }

    /// @dev Bogus-but-structurally-valid proofs to prove the deployed verifiers actually run the pairing
    ///      check (reject) — not stubs.
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

contract Step1_DeployInfraOnGnosis is DeployInfraBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (registry owner)");
        console.log("\n=== Step 1: DD-deploy ZK infra on Gnosis + seed gmail/ku.edu keys ===");
        vm.startBroadcast(key);
        (address dv, address ev, address reg) = _deployInfra();
        _seedKeys(PoaDKIMRegistry(reg));
        vm.stopBroadcast();
        console.log("  ZK_DOMAIN_VERIFIER:", dv);
        console.log("  ZK_EMAIL_VERIFIER: ", ev);
        console.log("  ZK_DKIM_REGISTRY:  ", reg);
        console.log("\nNext: Step2_DeployInfraFromArbitrum (same addresses + cross-chain wiring).");
    }
}

contract Step2_DeployInfraFromArbitrum is DeployInfraBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        require(hub.owner() == sender, "Sender must own the Hub");
        require(sender.balance >= HYPERLANE_FEE, "need >= 0.005 ETH on Arbitrum for the Hyperlane msg");

        console.log("\n=== Step 2: DD-deploy ZK infra on Arbitrum + seed keys + wire both chains ===");
        vm.startBroadcast(key);
        (address dv, address ev, address reg) = _deployInfra();
        _seedKeys(PoaDKIMRegistry(reg));
        hub.adminCallCrossChain{value: HYPERLANE_FEE}(ORG_DEPLOYER, _setInfraCalldata(dv, ev, reg));
        vm.stopBroadcast();

        require(_readAddr(ORG_DEPLOYER, _domainVerifierSlot()) == dv, "arb: domain verifier not wired");
        require(_readAddr(ORG_DEPLOYER, _emailVerifierSlot()) == ev, "arb: email verifier not wired");
        require(_readAddr(ORG_DEPLOYER, _dkimRegistrySlot()) == reg, "arb: dkim registry not wired");
        console.log("  ZK_DOMAIN_VERIFIER:", dv);
        console.log("  ZK_EMAIL_VERIFIER: ", ev);
        console.log("  ZK_DKIM_REGISTRY:  ", reg);
        console.log("Arbitrum wired. Wait ~5 min for relay, then Step3_VerifyInfraGnosis.");
    }
}

contract Step3_VerifyInfraGnosis is DeployInfraBase {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address dv = dd.computeAddress(dd.computeSalt("ZkDomainVerifier", VERSION));
        address ev = dd.computeAddress(dd.computeSalt("ZkEmailVerifier", VERSION));
        address reg = dd.computeAddress(dd.computeSalt("PoaDKIMRegistry", VERSION));
        bool dvOk = _readAddr(ORG_DEPLOYER, _domainVerifierSlot()) == dv;
        bool evOk = _readAddr(ORG_DEPLOYER, _emailVerifierSlot()) == ev;
        bool regOk = _readAddr(ORG_DEPLOYER, _dkimRegistrySlot()) == reg;

        console.log("\n=== Verify Gnosis ZK infra wiring ===");
        console.log("  domain verifier wired:", dvOk);
        console.log("  email verifier wired: ", evOk);
        console.log("  dkim registry wired:  ", regOk);
        bool keysOk = PoaDKIMRegistry(reg).isKeyHashValid(PoaDKIMRegistry(reg).domainHashOf("gmail.com"), GMAIL_KEYHASH)
            && PoaDKIMRegistry(reg).isKeyHashValid(PoaDKIMRegistry(reg).domainHashOf("ku.edu"), KU_KEYHASH);
        console.log("  gmail+ku.edu keys seeded on Gnosis:", keysOk);
        if (dvOk && evOk && regOk && keysOk) {
            console.log("PASS: Gnosis ZK infra deployed, seeded, and wired.");
        } else {
            console.log("WAITING: Hyperlane wiring not yet relayed (keys are seeded directly in Step1).");
        }
    }
}

/// @notice Fork-sim on Arbitrum: DD-deploy infra, prove both real verifiers reject a bogus proof, seed
///         keys, wire cross-chain, and assert the Arbitrum OrgDeployer is wired. Gnosis relay verified by
///         Step3 after broadcast.
contract SimInfraArbitrum is DeployInfraBase {
    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        console.log("\n=== SIM: ZK Email infra (Arbitrum fork, cross-chain) ===");

        vm.deal(HUDSON, 1 ether);
        vm.startPrank(HUDSON);

        // Prereq: setZkEmailInfrastructure only exists on the ZK-aware OrgDeployer impl — the protocol
        // upgrade runs first in the real sequence, so apply it in-sim (DD impl + cross-chain beacon swap).
        address odImpl = _ddDeploy("OrgDeployer", type(OrgDeployer).creationCode);
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", odImpl, VERSION);

        (address dv, address ev, address reg) = _deployInfra();

        // Real verifiers must run the pairing check and reject a bogus proof (not stubs).
        bytes32 kh = keccak256("sim-key");
        ZkEmailProof memory bd = _bogusDomainProof("gmail.com", kh);
        require(
            !Groth16Verifier(dv)
                .verifyProof(
                    bd.pA,
                    bd.pB,
                    bd.pC,
                    [uint256(bd.pubkeyHash), uint256(bd.emailNullifier), uint256(uint160(address(0)))]
                ),
            "domain verifier accepted bogus proof"
        );
        ZkEmailProofV2 memory be = _bogusEmailProof("gmail.com", kh);
        require(
            !Groth16VerifierV2(ev)
                .verifyProof(
                    be.pA,
                    be.pB,
                    be.pC,
                    [
                        uint256(be.pubkeyHash),
                        uint256(be.emailNullifier),
                        uint256(uint160(address(0))),
                        uint256(be.emailHash)
                    ]
                ),
            "email verifier accepted bogus proof"
        );

        _seedKeys(PoaDKIMRegistry(reg));
        require(
            PoaDKIMRegistry(reg).isKeyHashValid(PoaDKIMRegistry(reg).domainHashOf("gmail.com"), GMAIL_KEYHASH),
            "gmail key not seeded"
        );
        require(
            PoaDKIMRegistry(reg).isKeyHashValid(PoaDKIMRegistry(reg).domainHashOf("ku.edu"), KU_KEYHASH),
            "ku.edu key not seeded"
        );

        hub.adminCallCrossChain{value: HYPERLANE_FEE}(ORG_DEPLOYER, _setInfraCalldata(dv, ev, reg));
        vm.stopPrank();

        require(_readAddr(ORG_DEPLOYER, _domainVerifierSlot()) == dv, "domain verifier not wired");
        require(_readAddr(ORG_DEPLOYER, _emailVerifierSlot()) == ev, "email verifier not wired");
        require(_readAddr(ORG_DEPLOYER, _dkimRegistrySlot()) == reg, "dkim registry not wired");
        console.log("  ZK_DOMAIN_VERIFIER:", dv);
        console.log("  ZK_EMAIL_VERIFIER: ", ev);
        console.log("  ZK_DKIM_REGISTRY:  ", reg);
        console.log("PASS: infra deploys, both real verifiers reject bogus proofs, keys seeded, wired cross-chain.");
    }
}
