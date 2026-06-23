// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";

/*
 * ============================================================================
 * Upgrade the protocol orchestration layer for ZK Email (per chain)
 * ============================================================================
 *
 * Brings an ALREADY-DEPLOYED chain up to the ZkEmailInvites-aware code. Three
 * on-chain effects, all driven by the Hub (Arbitrum) / Satellite (Gnosis) owner:
 *
 *   1. Upgrade the OrgDeployer beacon to the new impl (adds deployFullOrgWithZkEmail,
 *      setZkEmailInfrastructure, setModulesFactory + the ZK wiring).
 *   2. Re-point the OrgDeployer at a freshly-deployed ModulesFactory (the new factory
 *      has the ZkEmailInvites deploy path; it is a plain contract, not a beacon proxy,
 *      so a beacon upgrade alone keeps the OLD factory in storage).
 *   3. Register the ZkEmailInvites beacon so per-org proxies can be deployed.
 *
 * NOT done here (separate steps, by design):
 *   - Deploying the zk-email verifier + DKIM registry (needs the vendored zk-email
 *     contracts / circuit) and calling setZkEmailInfrastructure — until that runs the
 *     ModulesFactory gate skips the module, so this upgrade is safe to land first.
 *   - The Executor upgrade (only needed to retrofit EXISTING orgs).
 *
 * HIGH BLAST RADIUS: this upgrades the contract that deploys every org. The sim
 * asserts the beacon swap, the factory re-point, and that the proxy still answers —
 * run it (and pick a free VERSION per CLAUDE.md) before broadcasting.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeProtocolForZkEmail.s.sol:SimUpgradeGnosis --fork-url gnosis -vvv
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeProtocolForZkEmail.s.sol:BroadcastUpgradeGnosis --rpc-url gnosis --broadcast --slow
 * ============================================================================
 */

interface ISatellite {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function addContractType(string calldata typeName, address impl) external;
    function owner() external view returns (address);
}

interface IHub {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function addContractType(string calldata typeName, address impl) external;
    function owner() external view returns (address);
}

interface IPoaManagerView {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

abstract contract UpgradeBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    // ── Gnosis (satellite) ──
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    // Verified live (2026-05-31): emitter of Test6's OrgDeployed event; VERSION()=="1.0.1";
    // namespace slot+4 (poaManager) == GNOSIS_POA_MANAGER above.
    address internal constant GNOSIS_ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;

    // ── Arbitrum (hub) ──
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant ARB_ORG_DEPLOYER = address(0); // TODO: fill before Arbitrum broadcast

    // CLAUDE.md: probe ImplementationRegistry + CREATE2 for a free (typeName,version) before broadcast.
    string internal constant VERSION = "v-zkemail-1";

    bytes32 internal constant ORG_DEPLOYER_ID = keccak256("OrgDeployer");
    bytes32 internal constant ZKEMAIL_INVITES_ID = keccak256("ZkEmailInvites");

    // OrgDeployer.Layout: governanceFactory(0), accessFactory(1), modulesFactory(2), orgRegistry(3),
    // poaManager(4), hatsTreeSetup(5), paymasterHub(6), universalPasskeyFactory(7), _status(8),
    // hatsV2(9), zkEmailDomainVerifier(10), zkEmailEmailVerifier(11), zkEmailDkimRegistry(12).
    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    function _modulesFactorySlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 2);
    }

    function _poaManagerSlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 4);
    }

    function _domainVerifierSlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 10);
    }

    function _emailVerifierSlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 11);
    }

    function _deployNewImpls()
        internal
        returns (address newModulesFactory, address newOrgDeployerImpl, address zkImpl)
    {
        newModulesFactory = address(new ModulesFactory());
        newOrgDeployerImpl = address(new OrgDeployer());
        zkImpl = address(new ZkEmailInvites());
    }

    function _readAddr(address proxy, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    /// @dev Arbitrum OrgDeployer proxy is not hardcoded (not yet probed on-chain like Gnosis was).
    ///      Override at runtime: `export ARB_ORG_DEPLOYER=0x...`. Discover it with the same method
    ///      used for Gnosis — the emitter of any org's OrgDeployed event on Arbitrum, e.g.:
    ///        cast logs --rpc-url arbitrum \
    ///          $(cast keccak "OrgDeployed(bytes32,address,address,address,address,address,address,address,address,address,address,uint256,uint256[])") \
    ///          0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069 --from-block <arb-infra-block>
    ///      (the `address:` field of the returned log is the OrgDeployer). Then verify its namespace
    ///      slot+4 == ARB_POA_MANAGER before broadcasting.
    function _arbOrgDeployer() internal view returns (address) {
        return vm.envOr("ARB_ORG_DEPLOYER", ARB_ORG_DEPLOYER);
    }
}

/* ════════════════════════════ GNOSIS ════════════════════════════ */

contract SimUpgradeGnosis is UpgradeBase {
    function run() public {
        console.log("\n=== SIM: Upgrade protocol for ZK Email (Gnosis) ===");
        require(ISatellite(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        (address newMF, address newOD, address zkImpl) = _deployNewImpls();
        console.log("  new ModulesFactory:", newMF);
        console.log("  new OrgDeployer impl:", newOD);
        console.log("  new ZkEmailInvites impl:", zkImpl);

        address implBefore = IPoaManagerView(GNOSIS_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID);
        require(implBefore != newOD, "already on new impl?");

        // 1. Upgrade the OrgDeployer beacon.
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", newOD, VERSION);
        require(
            IPoaManagerView(GNOSIS_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == newOD,
            "OrgDeployer beacon not upgraded"
        );
        console.log("  OrgDeployer beacon -> new impl OK");

        // 2. Re-point the deployer at the new ModulesFactory.
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE)
            .adminCall(GNOSIS_ORG_DEPLOYER, abi.encodeWithSignature("setModulesFactory(address)", newMF));
        require(_readAddr(GNOSIS_ORG_DEPLOYER, _modulesFactorySlot()) == newMF, "modulesFactory not repointed");
        console.log("  OrgDeployer.modulesFactory -> new factory OK");

        // 3. Register the ZkEmailInvites beacon.
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE).addContractType("ZkEmailInvites", zkImpl);
        require(
            IPoaManagerView(GNOSIS_POA_MANAGER).getBeaconById(ZKEMAIL_INVITES_ID) != address(0),
            "ZkEmailInvites beacon not registered"
        );
        console.log("  ZkEmailInvites beacon registered OK");

        // 4. Sanity: proxy still answers, and the new setZkEmailInfrastructure writes (placeholder addrs).
        require(
            address(OrgDeployer(payable(GNOSIS_ORG_DEPLOYER)).hats()) != address(0), "proxy view broke after upgrade"
        );
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE)
            .adminCall(
                GNOSIS_ORG_DEPLOYER,
                abi.encodeWithSignature(
                    "setZkEmailInfrastructure(address,address,address)",
                    address(0xA11CE),
                    address(0xE11A11),
                    address(0xDC1)
                )
            );
        require(
            _readAddr(GNOSIS_ORG_DEPLOYER, _domainVerifierSlot()) == address(0xA11CE),
            "setZkEmailInfrastructure domain verifier failed"
        );
        require(
            _readAddr(GNOSIS_ORG_DEPLOYER, _emailVerifierSlot()) == address(0xE11A11),
            "setZkEmailInfrastructure email verifier failed"
        );
        console.log("  setZkEmailInfrastructure writes OK (placeholder addrs)");

        console.log("PASS: Gnosis protocol upgrade verified end-to-end on fork.");
    }
}

contract BroadcastUpgradeGnosis is UpgradeBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");

        vm.startBroadcast(key);
        (address newMF, address newOD, address zkImpl) = _deployNewImpls();
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", newOD, VERSION);
        ISatellite(GNOSIS_SATELLITE)
            .adminCall(GNOSIS_ORG_DEPLOYER, abi.encodeWithSignature("setModulesFactory(address)", newMF));
        ISatellite(GNOSIS_SATELLITE).addContractType("ZkEmailInvites", zkImpl);
        vm.stopBroadcast();

        require(
            IPoaManagerView(GNOSIS_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == newOD,
            "upgrade did not stick"
        );
        require(_readAddr(GNOSIS_ORG_DEPLOYER, _modulesFactorySlot()) == newMF, "repoint did not stick");
        console.log("Gnosis upgraded. new ModulesFactory:", newMF);
        console.log("new OrgDeployer impl:", newOD, " ZkEmailInvites impl:", zkImpl);
        console.log(
            "NEXT: deploy verifiers/DKIM, then adminCall setZkEmailInfrastructure(domainVerifier, emailVerifier, dkim)."
        );
    }
}

/* ════════════════════════════ ARBITRUM ════════════════════════════ */

/// @dev Mirror of SimUpgradeGnosis for the Hub (Arbitrum) path. Requires ARB_ORG_DEPLOYER to be set
///      (env or constant) — see _arbOrgDeployer(). Run once the address is probed + verified:
///        ARB_ORG_DEPLOYER=0x... FOUNDRY_PROFILE=production forge script \
///          script/zkemail/UpgradeProtocolForZkEmail.s.sol:SimUpgradeArbitrum --fork-url arbitrum -vvv
contract SimUpgradeArbitrum is UpgradeBase {
    function run() public {
        address orgDeployer = _arbOrgDeployer();
        require(orgDeployer != address(0), "Set ARB_ORG_DEPLOYER (see _arbOrgDeployer doc)");
        require(orgDeployer.code.length > 0, "ARB_ORG_DEPLOYER has no code on Arbitrum");
        require(
            _readAddr(orgDeployer, _poaManagerSlot()) == ARB_POA_MANAGER, "OrgDeployer.poaManager != ARB_POA_MANAGER"
        );

        console.log("\n=== SIM: Upgrade protocol for ZK Email (Arbitrum) ===");
        require(IHub(ARB_HUB).owner() == HUDSON, "Hub owner != Hudson");

        (address newMF, address newOD, address zkImpl) = _deployNewImpls();
        console.log("  new ModulesFactory:", newMF);
        console.log("  new OrgDeployer impl:", newOD);
        console.log("  new ZkEmailInvites impl:", zkImpl);

        require(
            IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) != newOD,
            "already on new impl?"
        );

        vm.prank(HUDSON);
        IHub(ARB_HUB).upgradeBeaconLocal("OrgDeployer", newOD, VERSION);
        require(
            IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == newOD,
            "OrgDeployer beacon not upgraded"
        );
        console.log("  OrgDeployer beacon -> new impl OK");

        vm.prank(HUDSON);
        IHub(ARB_HUB).adminCall(orgDeployer, abi.encodeWithSignature("setModulesFactory(address)", newMF));
        require(_readAddr(orgDeployer, _modulesFactorySlot()) == newMF, "modulesFactory not repointed");
        console.log("  OrgDeployer.modulesFactory -> new factory OK");

        vm.prank(HUDSON);
        IHub(ARB_HUB).addContractType("ZkEmailInvites", zkImpl);
        require(
            IPoaManagerView(ARB_POA_MANAGER).getBeaconById(ZKEMAIL_INVITES_ID) != address(0),
            "ZkEmailInvites beacon not registered"
        );
        console.log("  ZkEmailInvites beacon registered OK");

        require(address(OrgDeployer(payable(orgDeployer)).hats()) != address(0), "proxy view broke after upgrade");
        vm.prank(HUDSON);
        IHub(ARB_HUB)
            .adminCall(
                orgDeployer,
                abi.encodeWithSignature(
                    "setZkEmailInfrastructure(address,address,address)",
                    address(0xA11CE),
                    address(0xE11A11),
                    address(0xDC1)
                )
            );
        require(
            _readAddr(orgDeployer, _domainVerifierSlot()) == address(0xA11CE),
            "setZkEmailInfrastructure domain verifier failed"
        );
        require(
            _readAddr(orgDeployer, _emailVerifierSlot()) == address(0xE11A11),
            "setZkEmailInfrastructure email verifier failed"
        );
        console.log("  setZkEmailInfrastructure writes OK (placeholder addrs)");

        console.log("PASS: Arbitrum protocol upgrade verified end-to-end on fork.");
    }
}

contract BroadcastUpgradeArbitrum is UpgradeBase {
    function run() public {
        address orgDeployer = _arbOrgDeployer();
        require(orgDeployer != address(0), "Set ARB_ORG_DEPLOYER (see _arbOrgDeployer doc)");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Hub owner)");

        vm.startBroadcast(key);
        (address newMF, address newOD, address zkImpl) = _deployNewImpls();
        IHub(ARB_HUB).upgradeBeaconLocal("OrgDeployer", newOD, VERSION);
        IHub(ARB_HUB).adminCall(orgDeployer, abi.encodeWithSignature("setModulesFactory(address)", newMF));
        IHub(ARB_HUB).addContractType("ZkEmailInvites", zkImpl);
        vm.stopBroadcast();

        require(
            IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == newOD,
            "upgrade did not stick"
        );
        require(_readAddr(orgDeployer, _modulesFactorySlot()) == newMF, "repoint did not stick");
        console.log("Arbitrum upgraded. new ModulesFactory:", newMF, " OrgDeployer impl:", newOD);
        console.log(
            "NEXT: deploy verifiers/DKIM, then adminCall setZkEmailInfrastructure(domainVerifier, emailVerifier, dkim)."
        );
    }
}
