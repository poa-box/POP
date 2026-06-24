// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * Upgrade the protocol orchestration layer for ZK Email — CROSS-CHAIN
 * ============================================================================
 *
 * Brings BOTH chains (Arbitrum hub + Gnosis satellite) up to the ZkEmailInvites-aware
 * code in one Hyperlane-driven flow, exactly like UpgradeOrgDeployerDeadlineRules.s.sol.
 * Three on-chain effects, each propagated to every active satellite by the Arbitrum Hub:
 *
 *   1. Upgrade the OrgDeployer beacon to the new impl (adds deployFullOrgWithZkEmail,
 *      setZkEmailInfrastructure, setModulesFactory + the ZK wiring)         [upgradeBeaconCrossChain]
 *   2. Register the ZkEmailInvites beacon so per-org proxies can be deployed [addContractTypeCrossChain]
 *   3. Re-point the OrgDeployer at the freshly-deployed ModulesFactory (the new factory has the
 *      ZkEmailInvites deploy path; it is a plain contract, not a beacon proxy, so a beacon upgrade
 *      alone keeps the OLD factory in storage)                               [adminCallCrossChain]
 *
 * Why this works cross-chain with a single dispatch each: the three impls are deployed via the
 * DeterministicDeployer at the SAME address on both chains (Step1 on Gnosis, Step2 on Arbitrum), and
 * the OrgDeployer proxy is already at the same deterministic address on both chains
 * (0x1Ad59E…, verified: its namespace slot+4 == each chain's PoaManager). So upgradeBeaconCrossChain /
 * addContractTypeCrossChain / adminCallCrossChain each do the Arbitrum-local write AND broadcast the
 * identical (typeName,impl) / (target,calldata) to Gnosis — both land the same result.
 *
 * NOT done here (separate steps, by design):
 *   - Deploying the verifiers + DKIM registry + setZkEmailInfrastructure (DeployZkEmailInfra) — until
 *     that runs the ModulesFactory gate skips the module, so this upgrade is safe to land first.
 *   - The Executor beacon upgrade (UpgradeExecutorForZkEmail) — only needed to retrofit EXISTING orgs.
 *
 * HIGH BLAST RADIUS: this upgrades the contract that deploys every org, on both chains. Sim on an
 * Arbitrum fork first (asserts the local hub effects; the Gnosis relay is verified by Step3 after
 * broadcast), and confirm VERSION is free on BOTH chains (CLAUDE.md probing recipe).
 *
 * Usage:
 *   # Sim (Arbitrum fork — prank Hudson, no env):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeProtocolForZkEmail.s.sol:SimUpgradeArbitrum --fork-url arbitrum -vvv
 *
 *   # Broadcast — Step1 deploys the impls on Gnosis so they exist when the relay lands:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeProtocolForZkEmail.s.sol:Step1_DeployImplsOnGnosis --rpc-url gnosis --broadcast --slow
 *   # Step2 deploys the impls on Arbitrum + dispatches all three upgrades cross-chain (needs ~0.015 ETH for
 *   # the 3 Hyperlane messages):
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeProtocolForZkEmail.s.sol:Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow
 *   # Step3 (after ~5 min relay) verifies Gnosis:
 *   forge script script/zkemail/UpgradeProtocolForZkEmail.s.sol:Step3_VerifyGnosis --rpc-url gnosis
 * ============================================================================
 */

interface IPoaManagerView {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

abstract contract UpgradeBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;

    // Arbitrum (home / hub)
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    // Gnosis (satellite)
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;

    // OrgDeployer proxy — SAME deterministic address on both chains (verified: namespace slot+4 ==
    // ARB_POA_MANAGER on Arbitrum and == GNOSIS_POA_MANAGER on Gnosis).
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;

    uint256 internal constant HYPERLANE_FEE = 0.005 ether; // per active satellite, per cross-chain call

    // CLAUDE.md: probe ImplementationRegistry + CREATE2 for a free (typeName,version) on BOTH chains.
    // Confirmed 2026-06-24: OrgDeployer/v-zkemail-1 FREE on Gnosis (registry + CREATE2) and Arbitrum;
    // ZkEmailInvites type unregistered on both. The Arbitrum sim re-checks against live state.
    string internal constant VERSION = "v-zkemail-1";

    bytes32 internal constant ORG_DEPLOYER_ID = keccak256("OrgDeployer");
    bytes32 internal constant ZKEMAIL_INVITES_ID = keccak256("ZkEmailInvites");

    // OrgDeployer.Layout: …, modulesFactory(2), …, poaManager(4), …
    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    function _modulesFactorySlot() internal pure returns (bytes32) {
        return bytes32(uint256(OD_SLOT) + 2);
    }

    function _readAddr(address proxy, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    /// @dev getBeaconById REVERTS TypeUnknown() for an unregistered type; treat that as "not registered".
    function _zkBeacon(address poaManager) internal view returns (address) {
        try IPoaManagerView(poaManager).getBeaconById(ZKEMAIL_INVITES_ID) returns (address b) {
            return b;
        } catch {
            return address(0);
        }
    }

    /// @dev DD-deploy `creationCode` at the deterministic (typeName,VERSION) address; no-op if already
    ///      present (idempotent across Step1/Step2 and re-runs). Returns the deterministic address.
    function _ddDeploy(string memory typeName, bytes memory creationCode) internal returns (address addr) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, creationCode);
            require(deployed == addr, "DD address mismatch");
        }
    }

    function _impls() internal returns (address orgDeployerImpl, address zkImpl, address modulesFactory) {
        orgDeployerImpl = _ddDeploy("OrgDeployer", type(OrgDeployer).creationCode);
        zkImpl = _ddDeploy("ZkEmailInvites", type(ZkEmailInvites).creationCode);
        modulesFactory = _ddDeploy("ModulesFactory", type(ModulesFactory).creationCode);
    }

    function _setModulesFactoryCalldata(address mf) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setModulesFactory(address)", mf);
    }

    /// @dev The three cross-chain dispatches (Arbitrum-local write + Gnosis broadcast each). Caller must
    ///      hold ≥ 3 * HYPERLANE_FEE. Used by both the broadcast (Step2) and the fork sim.
    function _dispatchCrossChain(PoaManagerHub hub, address orgDeployerImpl, address zkImpl, address mf) internal {
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("OrgDeployer", orgDeployerImpl, VERSION);
        hub.addContractTypeCrossChain{value: HYPERLANE_FEE}("ZkEmailInvites", zkImpl);
        hub.adminCallCrossChain{value: HYPERLANE_FEE}(ORG_DEPLOYER, _setModulesFactoryCalldata(mf));
    }

    function _assertArbitrumEffects(address orgDeployerImpl, address zkImpl, address mf) internal view {
        require(
            IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == orgDeployerImpl,
            "arb: OrgDeployer beacon not upgraded"
        );
        require(_zkBeacon(ARB_POA_MANAGER) != address(0), "arb: ZkEmailInvites beacon not registered");
        require(_readAddr(ORG_DEPLOYER, _modulesFactorySlot()) == mf, "arb: modulesFactory not repointed");
    }
}

/* ════════════════════════════ STEP 1 — Gnosis (deploy impls) ════════════════════════════ */

contract Step1_DeployImplsOnGnosis is UpgradeBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        console.log("\n=== Step 1: DD-deploy the 3 impls on Gnosis (so they exist when the relay lands) ===");
        vm.startBroadcast(key);
        (address od, address zk, address mf) = _impls();
        vm.stopBroadcast();
        require(od.code.length > 0 && zk.code.length > 0 && mf.code.length > 0, "an impl has no code");
        console.log("  OrgDeployer impl:   ", od);
        console.log("  ZkEmailInvites impl:", zk);
        console.log("  ModulesFactory:     ", mf);
        console.log("\nNext: Step2_UpgradeFromArbitrum (deploys the same addresses on Arbitrum + dispatches).");
    }
}

/* ════════════════════════════ STEP 2 — Arbitrum (deploy + dispatch) ════════════════════════════ */

contract Step2_UpgradeFromArbitrum is UpgradeBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(key);
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        require(hub.owner() == sender, "Sender must own the Hub");
        require(!hub.paused(), "Hub is paused");
        require(sender.balance >= 3 * HYPERLANE_FEE, "need >= 0.015 ETH on Arbitrum for 3 Hyperlane msgs");

        console.log("\n=== Step 2: deploy impls on Arbitrum + dispatch all 3 upgrades cross-chain ===");
        vm.startBroadcast(key);
        (address od, address zk, address mf) = _impls();
        _dispatchCrossChain(hub, od, zk, mf);
        vm.stopBroadcast();

        _assertArbitrumEffects(od, zk, mf);
        console.log("  OrgDeployer impl:   ", od);
        console.log("  ZkEmailInvites impl:", zk);
        console.log("  ModulesFactory:     ", mf);
        console.log("Arbitrum upgrade: PASS. Wait ~5 min for the Hyperlane relay, then run Step3_VerifyGnosis.");
    }
}

/* ════════════════════════════ STEP 3 — Gnosis (verify after relay) ════════════════════════════ */

contract Step3_VerifyGnosis is UpgradeBase {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address od = dd.computeAddress(dd.computeSalt("OrgDeployer", VERSION));
        address mf = dd.computeAddress(dd.computeSalt("ModulesFactory", VERSION));

        bool beaconOk = IPoaManagerView(GNOSIS_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID) == od;
        bool zkOk = _zkBeacon(GNOSIS_POA_MANAGER) != address(0);
        bool mfOk = _readAddr(ORG_DEPLOYER, _modulesFactorySlot()) == mf;

        console.log("\n=== Verify Gnosis protocol upgrade ===");
        console.log("  OrgDeployer beacon -> v-zkemail-1 impl:", beaconOk);
        console.log("  ZkEmailInvites beacon registered:      ", zkOk);
        console.log("  OrgDeployer.modulesFactory repointed:  ", mfOk);
        if (beaconOk && zkOk && mfOk) {
            console.log("PASS: Gnosis is on the ZkEmailInvites-aware protocol code.");
        } else {
            console.log("WAITING: one or more Hyperlane messages not yet relayed (retry in a few min).");
        }
    }
}

/* ════════════════════════════ SIM — Arbitrum fork ════════════════════════════ */

/// @notice Fork-sim the whole flow on Arbitrum: DD-deploy the impls, dispatch the 3 cross-chain upgrades
///         as Hudson (the Hub owner), and assert the Arbitrum-LOCAL effects. The Gnosis relay isn't
///         fork-simulatable; Step3 verifies it after broadcast. Behavior of the new OrgDeployer/
///         ModulesFactory ZK path is covered by test/ZkEmailOrgFlow.t.sol.
contract SimUpgradeArbitrum is UpgradeBase {
    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        console.log("\n=== SIM: ZK Email protocol upgrade (Arbitrum fork, cross-chain) ===");

        address odBefore = IPoaManagerView(ARB_POA_MANAGER).getCurrentImplementationById(ORG_DEPLOYER_ID);
        console.log("  OrgDeployer impl before:", odBefore);
        require(_zkBeacon(ARB_POA_MANAGER) == address(0), "sim: ZkEmailInvites already registered on Arbitrum");

        vm.deal(HUDSON, 1 ether);
        vm.startPrank(HUDSON);
        (address od, address zk, address mf) = _impls();
        require(od != odBefore, "sim: OrgDeployer v-zkemail-1 already live");
        _dispatchCrossChain(hub, od, zk, mf);
        vm.stopPrank();

        _assertArbitrumEffects(od, zk, mf);
        console.log("  OrgDeployer impl after: ", od);
        console.log("  ZkEmailInvites impl:    ", zk);
        console.log("  ModulesFactory:         ", mf);
        console.log("PASS: cross-chain protocol upgrade verified on an Arbitrum fork (local hub effects).");
    }
}
