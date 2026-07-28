// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";
import {ZkEmailProof} from "../../src/zkemail/IVerifier.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {Executor} from "../../src/Executor.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";

/*
 * ============================================================================
 * ARBITRUM — production ZK-Email rollout (protocol level)
 * ============================================================================
 *
 * Brings the Arbitrum side up to the Gnosis production state so FUTURE Arbitrum orgs deploy with the
 * ceremony stack. Probed live 2026-07-28: all five protocol beacons exist, but the Arbitrum OrgDeployer
 * is still wired to the VOID v-zkemail-1 DEV infra (forgeable dev verifiers + keccak registry), and
 * every impl predates the production waves.
 *
 *   1. DD-deploy (CREATE3) the CEREMONY verifiers + Poseidon-keyed PoaDKIMRegistry at v-zkemail-3 —
 *      the SAME addresses as Gnosis (0x82aF…, 0x159c…, 0xC2dd…), by construction.
 *   2. Seed the Poseidon-keyed DKIM keys (gmail + ku.edu; OPACITY_KEY_HASH optional).
 *   3. Re-wire the Arbitrum OrgDeployer's zk infra (hub.adminCall -> setZkEmailInfrastructure).
 *   4. Upgrade the five beacons to the production impls at v-zkemail-4 (hub.upgradeBeaconLocal):
 *      Executor (hats() for the H-03 gate), ZkEmailInvites (Blocker 2 + email-verified grant),
 *      EligibilityModule (third eligibility path), PaymasterHub (SUBJECT_TYPE_CLAIM + v0.7 gas-packing
 *      fix + SponsorshipLib extraction), OrgDeployer (auto CLAIM budget for new zk-email orgs).
 *
 * Per-org steps (allowlist activation, DKIM checks) happen when an Arbitrum org enables the module —
 * new orgs get rules + claim budget automatically from the upgraded OrgDeployer.
 *
 * ALSO in this file: BroadcastOrgDeployerUpgradeGnosis — the Gnosis OrgDeployer beacon was NOT part of
 * the earlier Gnosis waves, so future GNOSIS orgs don't get the automatic CLAIM budget until it runs.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/ArbitrumZkEmailRollout.s.sol:SimArbitrumZkEmailRollout --fork-url arbitrum -vvv
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/ArbitrumZkEmailRollout.s.sol:BroadcastArbitrumZkEmailRollout --rpc-url arbitrum --broadcast --slow
 *   forge script script/zkemail/ArbitrumZkEmailRollout.s.sol:VerifyArbitrumZkEmail --rpc-url arbitrum
 *
 *   # Gnosis addendum (OrgDeployer claim-budget impl):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/ArbitrumZkEmailRollout.s.sol:SimOrgDeployerUpgradeGnosis --fork-url gnosis -vvv
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/ArbitrumZkEmailRollout.s.sol:BroadcastOrgDeployerUpgradeGnosis --rpc-url gnosis --broadcast --slow
 * ============================================================================
 */

interface IHubA {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface ISatelliteA {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewA {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

abstract contract ArbitrumZkBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c; // same both chains
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;

    // DD infra pinned to the same version as Gnosis so CREATE3 yields IDENTICAL cross-chain addresses.
    string internal constant INFRA_VERSION = "v-zkemail-3";
    // Beacon impls at the current production wave (probed FREE on the Arbitrum registry).
    string internal constant IMPL_VERSION = "v-zkemail-4";

    // Expected CREATE3 addresses (== live Gnosis ceremony infra; asserted in the sim).
    address internal constant EXPECTED_DOMAIN_VERIFIER = 0x82aF8ee7F88130b954adB3f9Ac00B3dE1421eb3B;
    address internal constant EXPECTED_EMAIL_VERIFIER = 0x159cC476f4c3761D0753044F02cF3d965d769c3C;
    address internal constant EXPECTED_REGISTRY = 0xC2ddbc0A6fc4410eFE78904Bee48558eAd0dE112;

    /* Poseidon domain commitments + DKIM key hashes (same wiring as the live Gnosis registry). */
    bytes32 internal constant GMAIL_POSEIDON = 0x14d46e073cbff5944a738ea295de6c7447606fa5a270571229d8a4b1e7ca77e5;
    bytes32 internal constant KU_POSEIDON = 0x256f370d0033263e95a6c486e2a0280c7843b2e0d586e92e6557382f776d6c58;
    bytes32 internal constant OPACITYLABS_POSEIDON = 0x29e7dedcdb5e509c3f276fb5d689700f0eaaa74bfaa75259b4c545cd2241a5c2;
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    bytes32 internal constant KU_KEYHASH = 0x198aa490f98ff2e619b0f48d7cd1885d604a1753b6c46b5f45b5ae2a8e8bc45f;

    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    function _ddDeploy(string memory typeName, bytes memory creationCode) internal returns (address addr) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, INFRA_VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, creationCode);
            require(deployed == addr, "DD address mismatch");
        }
    }

    function _deployInfra() internal returns (address dv, address ev, address reg) {
        dv = _ddDeploy("ZkDomainVerifier", type(Groth16Verifier).creationCode);
        ev = _ddDeploy("ZkEmailVerifier", type(Groth16VerifierV2).creationCode);
        // Owner baked into creationCode -> identical CREATE3 address on every chain.
        reg = _ddDeploy("PoaDKIMRegistry", abi.encodePacked(type(PoaDKIMRegistry).creationCode, abi.encode(HUDSON)));
    }

    /// @dev Poseidon-keyed seeding via setKeyHash — never setKeyForDomain (keccak, pre-Blocker-2).
    function _seedKeysPoseidon(PoaDKIMRegistry registry) internal {
        registry.setKeyHash(GMAIL_POSEIDON, vm.envOr("GMAIL_KEY_HASH", GMAIL_KEYHASH), true);
        registry.setKeyHash(KU_POSEIDON, vm.envOr("KU_KEY_HASH", KU_KEYHASH), true);
        bytes32 opacityKey = vm.envOr("OPACITY_KEY_HASH", bytes32(0));
        if (opacityKey != bytes32(0)) registry.setKeyHash(OPACITYLABS_POSEIDON, opacityKey, true);
    }

    function _odAddr(uint256 slotOffset) internal view returns (address) {
        return address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_SLOT) + slotOffset)))));
    }

    function _implOf(address poaManager, string memory typeName) internal view returns (address) {
        return IPoaManagerViewA(poaManager).getCurrentImplementationById(keccak256(bytes(typeName)));
    }

    /// @dev Deploy the five production impls (BEFORE any prank/broadcast context switches).
    function _deployImpls()
        internal
        returns (address execImpl, address zkImpl, address eligImpl, address hubImpl, address odImpl)
    {
        execImpl = address(new Executor());
        zkImpl = address(new ZkEmailInvites());
        eligImpl = address(new EligibilityModule());
        hubImpl = address(new PaymasterHub());
        odImpl = address(new OrgDeployer());
    }

    function _upgradeAllBeacons(
        IHubA hub,
        address execImpl,
        address zkImpl,
        address eligImpl,
        address hubImpl,
        address odImpl
    ) internal {
        hub.upgradeBeaconLocal("Executor", execImpl, IMPL_VERSION);
        hub.upgradeBeaconLocal("ZkEmailInvites", zkImpl, IMPL_VERSION);
        hub.upgradeBeaconLocal("EligibilityModule", eligImpl, IMPL_VERSION);
        hub.upgradeBeaconLocal("PaymasterHub", hubImpl, IMPL_VERSION);
        hub.upgradeBeaconLocal("OrgDeployer", odImpl, IMPL_VERSION);
    }

    function _assertWiredAndUpgraded(
        address dv,
        address ev,
        address reg,
        address execImpl,
        address zkImpl,
        address eligImpl,
        address hubImpl,
        address odImpl
    ) internal view {
        require(_odAddr(10) == dv, "OrgDeployer domain verifier not wired");
        require(_odAddr(11) == ev, "OrgDeployer email verifier not wired");
        require(_odAddr(12) == reg, "OrgDeployer dkim registry not wired");
        require(_implOf(ARB_POA_MANAGER, "Executor") == execImpl, "Executor beacon not upgraded");
        require(_implOf(ARB_POA_MANAGER, "ZkEmailInvites") == zkImpl, "ZkEmailInvites beacon not upgraded");
        require(_implOf(ARB_POA_MANAGER, "EligibilityModule") == eligImpl, "EligibilityModule beacon not upgraded");
        require(_implOf(ARB_POA_MANAGER, "PaymasterHub") == hubImpl, "PaymasterHub beacon not upgraded");
        require(_implOf(ARB_POA_MANAGER, "OrgDeployer") == odImpl, "OrgDeployer beacon not upgraded");
    }
}

/* ════════════════════════════ SIMULATION (Arbitrum) ════════════════════════════ */

contract SimArbitrumZkEmailRollout is ArbitrumZkBase {
    function run() public {
        console.log("\n=== SIM: Arbitrum production ZK-Email rollout ===");
        IHubA hub = IHubA(ARB_HUB);
        require(hub.owner() == HUDSON, "Hub owner != Hudson");

        // Impls BEFORE prank (`new` would consume it).
        (address execImpl, address zkImpl, address eligImpl, address hubImpl, address odImpl) = _deployImpls();

        vm.startPrank(HUDSON);
        // 1-2. Ceremony infra at the SAME cross-chain addresses + Poseidon DKIM seeding.
        (address dv, address ev, address reg) = _deployInfra();
        require(dv == EXPECTED_DOMAIN_VERIFIER, "domain verifier address != Gnosis (CREATE3 parity broken)");
        require(ev == EXPECTED_EMAIL_VERIFIER, "email verifier address != Gnosis");
        require(reg == EXPECTED_REGISTRY, "registry address != Gnosis");
        _seedKeysPoseidon(PoaDKIMRegistry(reg));
        require(PoaDKIMRegistry(reg).isKeyHashValid(GMAIL_POSEIDON, GMAIL_KEYHASH), "gmail key not seeded");
        require(PoaDKIMRegistry(reg).isKeyHashValid(KU_POSEIDON, KU_KEYHASH), "ku key not seeded");

        // 3. Re-wire the OrgDeployer off the VOID dev infra.
        hub.adminCall(
            ORG_DEPLOYER, abi.encodeWithSignature("setZkEmailInfrastructure(address,address,address)", dv, ev, reg)
        );

        // 4. All five beacons to the production impls.
        _upgradeAllBeacons(hub, execImpl, zkImpl, eligImpl, hubImpl, odImpl);
        vm.stopPrank();

        _assertWiredAndUpgraded(dv, ev, reg, execImpl, zkImpl, eligImpl, hubImpl, odImpl);
        console.log("[1] Infra at cross-chain parity addresses; Poseidon keys seeded; OrgDeployer re-wired.");
        console.log("[2] All five beacons upgraded to production impls (v-zkemail-4).");

        // 5. The REAL ceremony verifier must run its pairing check (reject a bogus proof).
        ZkEmailProof memory bogus;
        bogus.pA = [uint256(1), 2];
        bogus.pB = [[uint256(1), 2], [uint256(3), 4]];
        bogus.pC = [uint256(5), 6];
        uint256[4] memory sig = [uint256(0xAA), uint256(7), uint256(uint160(address(0))), uint256(GMAIL_POSEIDON)];
        require(
            !Groth16Verifier(dv).verifyProof{gas: 10_000_000}(bogus.pA, bogus.pB, bogus.pC, sig),
            "ceremony verifier accepted a bogus proof!"
        );
        console.log("[3] Ceremony verifier live on Arbitrum and rejecting bogus proofs.");

        console.log("\nPASS: Arbitrum ZK-Email rollout verified end-to-end on a real Arbitrum fork.");
    }
}

/* ════════════════════════════ BROADCAST (Arbitrum) ════════════════════════════ */

contract BroadcastArbitrumZkEmailRollout is ArbitrumZkBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Hub owner)");
        console.log("\n=== Broadcast: Arbitrum production ZK-Email rollout ===");
        IHubA hub = IHubA(ARB_HUB);

        vm.startBroadcast(key);
        (address execImpl, address zkImpl, address eligImpl, address hubImpl, address odImpl) = _deployImpls();
        (address dv, address ev, address reg) = _deployInfra();
        _seedKeysPoseidon(PoaDKIMRegistry(reg));
        hub.adminCall(
            ORG_DEPLOYER, abi.encodeWithSignature("setZkEmailInfrastructure(address,address,address)", dv, ev, reg)
        );
        _upgradeAllBeacons(hub, execImpl, zkImpl, eligImpl, hubImpl, odImpl);
        vm.stopBroadcast();

        _assertWiredAndUpgraded(dv, ev, reg, execImpl, zkImpl, eligImpl, hubImpl, odImpl);
        console.log("  ZK_DOMAIN_VERIFIER:", dv);
        console.log("  ZK_EMAIL_VERIFIER: ", ev);
        console.log("  ZK_DKIM_REGISTRY:  ", reg);
        if (vm.envOr("OPACITY_KEY_HASH", bytes32(0)) == bytes32(0)) {
            console.log("  NOTE: opacitylabs.com NOT seeded (no OPACITY_KEY_HASH).");
        }
        console.log("Done. Future Arbitrum orgs deploy with the production zk-email stack.");
    }
}

/// @notice Read-only: confirm the Arbitrum wiring.
contract VerifyArbitrumZkEmail is ArbitrumZkBase {
    function run() public view {
        bool infraOk = _odAddr(10) == EXPECTED_DOMAIN_VERIFIER && _odAddr(11) == EXPECTED_EMAIL_VERIFIER
            && _odAddr(12) == EXPECTED_REGISTRY;
        bool keysOk = EXPECTED_REGISTRY.code.length > 0
            && PoaDKIMRegistry(EXPECTED_REGISTRY).isKeyHashValid(GMAIL_POSEIDON, GMAIL_KEYHASH);
        console.log("\n=== Verify Arbitrum ZK-Email ===");
        console.log("  OrgDeployer wired to ceremony infra:", infraOk);
        console.log("  Poseidon DKIM keys live:            ", keysOk);
        if (infraOk && keysOk) {
            console.log("PASS (beacon impls asserted by the broadcast run).");
        } else {
            console.log("INCOMPLETE: run BroadcastArbitrumZkEmailRollout.");
        }
    }
}

/* ════════════════ GNOSIS ADDENDUM: OrgDeployer claim-budget impl ════════════════ */

contract SimOrgDeployerUpgradeGnosis is ArbitrumZkBase {
    function run() public {
        console.log("\n=== SIM: Gnosis OrgDeployer upgrade (auto CLAIM budget for new orgs) ===");
        require(ISatelliteA(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");
        address odImpl = address(new OrgDeployer());
        vm.prank(HUDSON);
        ISatelliteA(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", odImpl, IMPL_VERSION);
        require(_implOf(GNOSIS_POA_MANAGER, "OrgDeployer") == odImpl, "OrgDeployer beacon not upgraded");
        // The zk infra wiring must survive the impl swap (storage lives in the proxy).
        require(_odAddr(10) == EXPECTED_DOMAIN_VERIFIER, "zk wiring lost after upgrade");
        console.log("PASS: Gnosis OrgDeployer upgraded; zk wiring intact.");
    }
}

contract BroadcastOrgDeployerUpgradeGnosis is ArbitrumZkBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        vm.startBroadcast(key);
        address odImpl = address(new OrgDeployer());
        ISatelliteA(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", odImpl, IMPL_VERSION);
        vm.stopBroadcast();
        require(_implOf(GNOSIS_POA_MANAGER, "OrgDeployer") == odImpl, "OrgDeployer beacon not upgraded");
        require(_odAddr(10) == EXPECTED_DOMAIN_VERIFIER, "zk wiring lost after upgrade");
        console.log("Done: new Gnosis orgs now get the automatic CLAIM budget.");
    }
}
