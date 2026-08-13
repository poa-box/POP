// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";

/*
 * ============================================================================
 * Register the RoleManager module at the protocol level — PER-CHAIN, LOCAL
 * ============================================================================
 *
 * Makes "RoleManager" deployable by OrgDeployer on a chain. Unlike the ZK Email
 * rollout (which fanned out over Hyperlane and hit the relayer beacon-deploy gas
 * limit — see UpgradeProtocolForZkEmail.s.sol:227), this runs LOCALLY on each chain
 * via the destination-chain admin path (Satellite on Gnosis, Hub on Arbitrum). Both
 * owners are Hudson (0xA6F4…b2c9). Three on-chain effects per chain:
 *
 *   1. addContractType("RoleManager", impl) — deploys the global UpgradeableBeacon and
 *      auto-registers "v1" in the ImplementationRegistry (PoaManager.addContractType).
 *      Beacon deploy is heavy; the local path has ample gas (the reason we avoid Hyperlane).
 *   2. upgradeBeacon("OrgDeployer", odImpl, "v21") — the RoleManager-aware OrgDeployer
 *      (adds deployFullOrgWithRoleManager). Beacon upgrade alone keeps the OLD ModulesFactory
 *      in storage, hence step 3.
 *   3. adminCall(ORG_DEPLOYER, setModulesFactory(mf)) — re-point the deployer at the new
 *      ModulesFactory (plain contract) that has the RoleManager deploy path. adminCall
 *      forwards through the local PoaManager, so OrgDeployer.setModulesFactory sees
 *      msg.sender == poaManager (its gate, src/OrgDeployer.sol:249).
 *
 * The three impls are DD-deployed at the SAME deterministic address on both chains.
 *
 * NOT done here (separate, by design):
 *   - The EM/DD/HV/TM/PT/EduHub/QuickJoin beacon upgrade wave (PLAN §2.2 step 4) — EM's
 *     derived path is inert until setRoleManager, so Mirror orgs upgrade safely without adopting.
 *   - Paymaster global-rule seed for claimHat/claimHats — SyncRoleManagerGlobalRules.s.sol.
 *
 * Version selection (dual-surface probe, 2026-08-13, both chains):
 *   RoleManager  "v1"  — registry FREE + CREATE2 FREE (fresh type) → 0x176080…22C1
 *   OrgDeployer  "v21" — registry FREE + CREATE2 FREE (v19 zkemail, v20 rulebook both TAKEN)
 *   ModulesFactory "v21" — CREATE2 FREE (plain contract, registry-independent) → 0xBad57b…3d7C
 *   RE-PROBE both surfaces on both chains immediately before broadcast (CLAUDE.md loop).
 *
 * Usage:
 *   # Sims (run BOTH under production profile before any broadcast):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:SimGnosis  --fork-url gnosis   -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:SimArbitrum --fork-url arbitrum -vvv
 *
 *   # Broadcast (per chain: deploy impls, then register+wire):
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:Step1_DeployImplsGnosis   --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:Step2_RegisterAndWireGnosis --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:Step1b_DeployImplsArbitrum  --rpc-url arbitrum --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/RegisterRoleManagerProtocol.s.sol:Step2b_RegisterAndWireArbitrum --rpc-url arbitrum --broadcast --slow
 * ============================================================================
 */

interface IPoaManagerView {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IPoaAdmin {
    function owner() external view returns (address);
    function addContractType(string calldata typeName, address impl) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

interface ISatelliteAdmin is IPoaAdmin {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

interface IHubAdmin is IPoaAdmin {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
}

abstract contract RmRegisterBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;

    // Arbitrum (home / hub)
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    // Gnosis (satellite)
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;

    // OrgDeployer proxy — SAME deterministic address on both chains.
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;

    // addContractType hardcodes the version string "v1" for a fresh type (PoaManager.addContractType).
    string internal constant RM_VERSION = "v1";
    // Dual-surface probed FREE on BOTH chains (2026-08-13). v19 (zkemail) + v20 (rulebook) TAKEN.
    string internal constant OD_VERSION = "v21";
    // Plain contract — only the CREATE2 slot is a collision surface (no registry entry).
    string internal constant MF_VERSION = "v21";

    bytes32 internal constant ROLE_MANAGER_ID = ModuleTypes.ROLE_MANAGER_ID;
    bytes32 internal constant ORG_DEPLOYER_ID = keccak256("OrgDeployer");

    // OrgDeployer.Layout: governanceFactory(0), accessFactory(1), modulesFactory(2), …
    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    function _modulesFactorySlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 2);
    }

    function _readAddr(address proxy, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    /// @dev DD-deploy `code` at the deterministic (typeName,version) address; idempotent (no-op if
    ///      already present). Returns the deterministic address.
    function _ddDeploy(string memory typeName, string memory version, bytes memory code)
        internal
        returns (address addr)
    {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, version);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, code);
            require(deployed == addr, "DD address mismatch");
        }
    }

    function _deployImpls() internal returns (address rmImpl, address mf, address odImpl) {
        rmImpl = _ddDeploy("RoleManager", RM_VERSION, type(RoleManager).creationCode);
        mf = _ddDeploy("ModulesFactory", MF_VERSION, type(ModulesFactory).creationCode);
        odImpl = _ddDeploy("OrgDeployer", OD_VERSION, type(OrgDeployer).creationCode);
    }

    /// @dev getBeaconById REVERTS TypeUnknown() for an unregistered type; treat that as "not registered".
    function _roleManagerBeacon(address poaManager) internal view returns (address) {
        try IPoaManagerView(poaManager).getBeaconById(ROLE_MANAGER_ID) returns (address b) {
            return b;
        } catch {
            return address(0);
        }
    }

    function _setModulesFactoryCalldata(address mf) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setModulesFactory(address)", mf);
    }

    /// @dev The three register+wire calls on Gnosis (Satellite-local). Caller must be the Satellite owner.
    function _registerAndWireGnosis(address rmImpl, address mf, address odImpl) internal {
        ISatelliteAdmin sat = ISatelliteAdmin(GNOSIS_SATELLITE);
        sat.addContractType("RoleManager", rmImpl);
        sat.upgradeBeaconDirect("OrgDeployer", odImpl, OD_VERSION);
        sat.adminCall(ORG_DEPLOYER, _setModulesFactoryCalldata(mf));
    }

    /// @dev The three register+wire calls on Arbitrum (Hub-local). Caller must be the Hub owner.
    function _registerAndWireArbitrum(address rmImpl, address mf, address odImpl) internal {
        IHubAdmin hub = IHubAdmin(ARB_HUB);
        hub.addContractType("RoleManager", rmImpl);
        hub.upgradeBeaconLocal("OrgDeployer", odImpl, OD_VERSION);
        hub.adminCall(ORG_DEPLOYER, _setModulesFactoryCalldata(mf));
    }

    function _assertEffects(address poaManager, address rmImpl, address mf, address odImpl) internal view {
        require(_roleManagerBeacon(poaManager) != address(0), "RoleManager beacon not registered");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(ROLE_MANAGER_ID) == rmImpl,
            "RoleManager v1 impl mismatch"
        );
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(ORG_DEPLOYER_ID) == odImpl,
            "OrgDeployer beacon not upgraded"
        );
        require(_readAddr(ORG_DEPLOYER, _modulesFactorySlot()) == mf, "modulesFactory not repointed");
    }
}

/* ════════════════════════════ GNOSIS — broadcast ════════════════════════════ */

contract Step1_DeployImplsGnosis is RmRegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1 (Gnosis): DD-deploy RoleManager + ModulesFactory + OrgDeployer impls ===");
        vm.startBroadcast(key);
        (address rm, address mf, address od) = _deployImpls();
        vm.stopBroadcast();
        require(rm.code.length > 0 && mf.code.length > 0 && od.code.length > 0, "an impl has no code");
        console.log("  RoleManager impl:   ", rm);
        console.log("  ModulesFactory:     ", mf);
        console.log("  OrgDeployer impl:   ", od);
    }
}

contract Step2_RegisterAndWireGnosis is RmRegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(ISatelliteAdmin(GNOSIS_SATELLITE).owner() == vm.addr(key), "signer must own the Satellite");
        require(_roleManagerBeacon(GNOSIS_POA_MANAGER) == address(0), "RoleManager already registered on Gnosis");
        (address rm, address mf, address od) = _deployImpls();
        require(rm.code.length > 0 && mf.code.length > 0 && od.code.length > 0, "run Step1 first (impl missing)");

        vm.startBroadcast(key);
        _registerAndWireGnosis(rm, mf, od);
        vm.stopBroadcast();

        _assertEffects(GNOSIS_POA_MANAGER, rm, mf, od);
        console.log("Gnosis: RoleManager registered + OrgDeployer/ModulesFactory repointed. PASS.");
    }
}

/* ════════════════════════════ ARBITRUM — broadcast ════════════════════════════ */

contract Step1b_DeployImplsArbitrum is RmRegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1b (Arbitrum): DD-deploy RoleManager + ModulesFactory + OrgDeployer impls ===");
        vm.startBroadcast(key);
        (address rm, address mf, address od) = _deployImpls();
        vm.stopBroadcast();
        require(rm.code.length > 0 && mf.code.length > 0 && od.code.length > 0, "an impl has no code");
        console.log("  RoleManager impl:   ", rm);
        console.log("  ModulesFactory:     ", mf);
        console.log("  OrgDeployer impl:   ", od);
    }
}

contract Step2b_RegisterAndWireArbitrum is RmRegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IHubAdmin(ARB_HUB).owner() == vm.addr(key), "signer must own the Hub");
        require(_roleManagerBeacon(ARB_POA_MANAGER) == address(0), "RoleManager already registered on Arbitrum");
        (address rm, address mf, address od) = _deployImpls();
        require(rm.code.length > 0 && mf.code.length > 0 && od.code.length > 0, "run Step1b first (impl missing)");

        vm.startBroadcast(key);
        _registerAndWireArbitrum(rm, mf, od);
        vm.stopBroadcast();

        _assertEffects(ARB_POA_MANAGER, rm, mf, od);
        console.log("Arbitrum: RoleManager registered + OrgDeployer/ModulesFactory repointed. PASS.");
    }
}

/* ════════════════════════════ SIMS — real forks, prank Hudson ════════════════════════════ */

/// @notice Fork-sim on Gnosis: as the Satellite/DD owner (Hudson), DD-deploy the three impls, register
///         the RoleManager type + upgrade the OrgDeployer beacon + repoint the ModulesFactory, and
///         assert getBeaconById / getCurrentImplementationById / modulesFactory-slot BEFORE and AFTER.
contract SimGnosis is RmRegisterBase {
    function run() public {
        console.log("\n=== SIM: RoleManager protocol registration (Gnosis fork, Satellite-local) ===");

        require(_roleManagerBeacon(GNOSIS_POA_MANAGER) == address(0), "sim: RoleManager already registered on Gnosis");
        address odBefore = IPoaManagerView(GNOSIS_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID);
        address mfBefore = _readAddr(ORG_DEPLOYER, _modulesFactorySlot());
        console.log("  RoleManager beacon before: (unregistered / 0)");
        console.log("  OrgDeployer impl before:  ", odBefore);
        console.log("  ModulesFactory before:    ", mfBefore);

        vm.startPrank(HUDSON);
        (address rm, address mf, address od) = _deployImpls();
        require(od != odBefore, "sim: OrgDeployer v21 already live");
        require(mf != mfBefore, "sim: ModulesFactory already repointed");
        _registerAndWireGnosis(rm, mf, od);
        vm.stopPrank();

        _assertEffects(GNOSIS_POA_MANAGER, rm, mf, od);
        console.log("  RoleManager beacon after: ", _roleManagerBeacon(GNOSIS_POA_MANAGER));
        console.log("  RoleManager v1 impl:      ", rm);
        console.log("  OrgDeployer impl after:   ", od);
        console.log("  ModulesFactory after:     ", mf);
        console.log("PASS: SimGnosis - RoleManager registered + deploy path repointed on live Gnosis state.");
    }
}

/// @notice Same on an Arbitrum fork (Hub-local).
contract SimArbitrum is RmRegisterBase {
    function run() public {
        console.log("\n=== SIM: RoleManager protocol registration (Arbitrum fork, Hub-local) ===");

        require(_roleManagerBeacon(ARB_POA_MANAGER) == address(0), "sim: RoleManager already registered on Arbitrum");
        address odBefore = IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID);
        address mfBefore = _readAddr(ORG_DEPLOYER, _modulesFactorySlot());
        console.log("  RoleManager beacon before: (unregistered / 0)");
        console.log("  OrgDeployer impl before:  ", odBefore);
        console.log("  ModulesFactory before:    ", mfBefore);

        vm.startPrank(HUDSON);
        (address rm, address mf, address od) = _deployImpls();
        require(od != odBefore, "sim: OrgDeployer v21 already live");
        require(mf != mfBefore, "sim: ModulesFactory already repointed");
        _registerAndWireArbitrum(rm, mf, od);
        vm.stopPrank();

        _assertEffects(ARB_POA_MANAGER, rm, mf, od);
        console.log("  RoleManager beacon after: ", _roleManagerBeacon(ARB_POA_MANAGER));
        console.log("  RoleManager v1 impl:      ", rm);
        console.log("  OrgDeployer impl after:   ", od);
        console.log("  ModulesFactory after:     ", mf);
        console.log("PASS: SimArbitrum - RoleManager registered + deploy path repointed on live Arbitrum state.");
    }
}
