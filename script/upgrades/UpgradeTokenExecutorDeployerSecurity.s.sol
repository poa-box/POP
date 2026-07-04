// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {Executor} from "../../src/Executor.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {HatsTreeSetup} from "../../src/HatsTreeSetup.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {UniversalAccountRegistry} from "../../src/UniversalAccountRegistry.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*
 * ============================================================================
 * Security remediation upgrade — ParticipationToken + Executor + OrgDeployer
 * (WS-A: audit C-01, L-11, L-60, M-09, L-53)
 * ============================================================================
 *
 * Bundles three beacon upgrades that ship in lockstep so the C-01 fix is
 * atomic (the token's executor-only setters need the Executor's new bootstrap
 * hook AND the OrgDeployer's step-8 rewiring, or fresh deploys brick):
 *
 *   ParticipationToken v5 — setTaskManager / setEducationHub are now BOTH
 *     onlyExecutor (previously the first set, while the slot was 0, was open to
 *     ANY caller → an attacker could install a malicious minter). C-01.
 *   Executor v4 — gains configureParticipationToken(token, tm, eduHub) so the
 *     OrgDeployer can wire the token through the executor before renouncing
 *     (C-01 bootstrap); sweep() uses call{value} + reverts SweepFailed (L-11);
 *     mintHatsForUser caps hatIds at MAX_HATS_PER_MINT=20 (L-60).
 *   OrgDeployer v16 — step-8 wiring routes through Executor.configureParticipation
 *     Token (C-01); default paymaster rules register updateOrgMetaAsAdmin against
 *     the OrgRegistry, not the UniversalAccountRegistry (L-53).
 *   (libs/RoleResolver M-09 rides inside whichever module links it; no separate
 *    beacon — the impls above pick it up at compile time.)
 *
 * Factories are intentionally NOT redeployed here (WS-B owns their redeploy).
 *
 * ── VERSION SELECTION (CLAUDE.md probe recipe, both surfaces, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9 (via Hub.poaManager().registry()).
 * DeterministicDeployer is CREATE3 (address is salt/version-only), so a given
 * (type, version) resolves to the SAME address on both chains.
 *
 *   ParticipationToken: registry has 4 versions on both chains.
 *     v5  gnosis:   registry=no create2=no  → FREE
 *     v5  arbitrum: registry=no create2=no  → FREE   ⇒ pick v5 (0x634e7905f0B3c6a8e412FE183e26064418374bce)
 *
 *   Executor: registry has 2 versions on both chains.
 *     v3  gnosis:   registry=no create2=YES → TAKEN (old CREATE2 slot occupied)
 *     v4  gnosis:   registry=no create2=no  → FREE
 *     v3  arbitrum: registry=no create2=no  → FREE  (but Gnosis blocks v3)
 *     v4  arbitrum: registry=no create2=no  → FREE   ⇒ pick v4 (0x387DE39Ee52B5206C6342172EbC60D78525445AC)
 *                                                       (lowest FREE on EVERY chain)
 *
 *   OrgDeployer: registry has 12 (Gnosis) / 13 (Arbitrum) versions.
 *     v13-v15 gnosis:   TAKEN (registry+create2)
 *     v14-v15 arbitrum: TAKEN (registry+create2)
 *     v16 gnosis:   registry=no create2=no → FREE
 *     v16 arbitrum: registry=no create2=no → FREE     ⇒ pick v16 (0xBE6b2500204C8fa769E530F7B2869E5f9bC6Cb63)
 *
 * ── UPGRADE PATH (per CLAUDE.md: act on the destination chain directly rather than
 *    waiting on a Hyperlane relay) ──
 *   Gnosis:   Hudson (Satellite owner) → Satellite.upgradeBeaconDirect(type, impl, version),
 *             the "emergency local-only upgrade". It forwards to PoaManager.upgradeBeacon
 *             (which registers + upgrades atomically) with the Satellite as msg.sender, so
 *             the onlyOwner gate passes. (Satellite.adminCall does NOT work for a beacon
 *             upgrade — it re-enters the PoaManager as msg.sender==PoaManager, failing the
 *             onlyOwner check; adminCall is for sub-contracts gated on msg.sender==poaManager.)
 *   Arbitrum: Hudson (Hub owner) → Hub.upgradeBeaconCrossChain(type, impl, version)
 *             (Arbitrum-local upgrade + Gnosis cross-chain dispatch).
 *
 * ── SIMS (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTokenExecutorDeployerSecurity.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeTokenExecutorDeployerSecurity.s.sol:SimArbitrum --fork-url arbitrum -vvv
 *
 * ── BROADCAST (do NOT run in this workstream) ──
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step1_DeployOnGnosis  --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step2b_UpgradeGnosis    --rpc-url gnosis   --broadcast --slow
 *   FOUNDRY_PROFILE=production forge script .../:Step3_Verify --rpc-url gnosis
 * ============================================================================
 */

/*──────────────────────────── Shared addresses ───────────────────────────*/
address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // owner = Hudson
address constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815; // owned by the Hub
// Hudson — owner of PoaManagerHub (Arbitrum), PoaManagerSatellite (Gnosis), DeterministicDeployer.
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
uint256 constant HYPERLANE_FEE = 0.005 ether;

string constant TOKEN_VERSION = "v5";
string constant EXECUTOR_VERSION = "v4";
string constant DEPLOYER_VERSION = "v16";

/// @dev PoaManager.upgradeBeacon(typeName, newImpl, version) registers AND upgrades
///      atomically, and is onlyOwner (owner = the Satellite). The Satellite owner (Hudson)
///      drives it on the destination chain via Satellite.upgradeBeaconDirect(...) — the
///      "emergency local-only upgrade" that skips the Hyperlane round-trip. (adminCall is
///      NOT usable here: it re-enters the PoaManager as msg.sender==PoaManager, which fails
///      upgradeBeacon's onlyOwner check; adminCall is for sub-contracts gated on
///      msg.sender==poaManager, e.g. OrgDeployer/PaymasterHub.)
interface ISatellite {
    function owner() external view returns (address);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                 BROADCAST STEPS
═══════════════════════════════════════════════════════════════════════════*/

/// @title Step1_DeployOnGnosis — deploy the three v-bump impls on Gnosis via DD (idempotent).
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 1: Deploy security-fix impls on Gnosis ===");
        vm.startBroadcast(deployerKey);
        _deploy(dd, "ParticipationToken", TOKEN_VERSION, type(ParticipationToken).creationCode);
        _deploy(dd, "Executor", EXECUTOR_VERSION, type(Executor).creationCode);
        _deploy(dd, "OrgDeployer", DEPLOYER_VERSION, type(OrgDeployer).creationCode);
        vm.stopBroadcast();
        console.log("\nNext: Step2_UpgradeFromArbitrum on Arbitrum");
    }

    function _deploy(DeterministicDeployer dd, string memory typeName, string memory version, bytes memory code)
        internal
    {
        bytes32 salt = dd.computeSalt(typeName, version);
        address predicted = dd.computeAddress(salt);
        console.log(typeName, version, "predicted:", predicted);
        if (predicted.code.length > 0) {
            console.log("  already deployed, skipping");
            return;
        }
        address deployed = dd.deploy(salt, code);
        require(deployed == predicted, "address mismatch");
        console.log("  deployed:", deployed);
    }
}

/// @title Step2_UpgradeFromArbitrum — deploy impls on Arbitrum via DD + upgrade the three
///        Arbitrum beacons (and dispatch cross-chain to Gnosis) through the Hub.
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        console.log("\n=== Step 2: Upgrade from Arbitrum (local + cross-chain to Gnosis) ===");
        vm.startBroadcast(deployerKey);
        _upgrade(hub, dd, "ParticipationToken", TOKEN_VERSION, type(ParticipationToken).creationCode);
        _upgrade(hub, dd, "Executor", EXECUTOR_VERSION, type(Executor).creationCode);
        _upgrade(hub, dd, "OrgDeployer", DEPLOYER_VERSION, type(OrgDeployer).creationCode);
        vm.stopBroadcast();
        console.log("\nWait ~5 min for Hyperlane relay OR run Step2b_UpgradeGnosis to upgrade Gnosis directly.");
    }

    function _upgrade(
        PoaManagerHub hub,
        DeterministicDeployer dd,
        string memory typeName,
        string memory version,
        bytes memory code
    ) internal {
        bytes32 salt = dd.computeSalt(typeName, version);
        address impl = dd.computeAddress(salt);
        if (impl.code.length == 0) {
            address deployed = dd.deploy(salt, code);
            require(deployed == impl, "Address mismatch on Arbitrum");
        }
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, impl, version);
        console.log(typeName, "upgraded (Arbitrum local + Gnosis cross-chain):", impl);
    }
}

/// @title Step2b_UpgradeGnosis — upgrade the three Gnosis beacons directly (no Hyperlane wait),
///        the destination-chain path CLAUDE.md prefers. Requires Step1 impls already deployed.
contract Step2b_UpgradeGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(ISatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 2b: Upgrade Gnosis beacons via Satellite.upgradeBeaconDirect ===");
        vm.startBroadcast(deployerKey);
        _upgrade(dd, "ParticipationToken", TOKEN_VERSION);
        _upgrade(dd, "Executor", EXECUTOR_VERSION);
        _upgrade(dd, "OrgDeployer", DEPLOYER_VERSION);
        vm.stopBroadcast();
        console.log("\nNext: Step3_Verify on Gnosis");
    }

    function _upgrade(DeterministicDeployer dd, string memory typeName, string memory version) internal {
        address impl = dd.computeAddress(dd.computeSalt(typeName, version));
        require(impl.code.length > 0, "impl not deployed on Gnosis (run Step1 first)");
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, impl, version);
        console.log(typeName, "upgraded on Gnosis:", impl);
    }
}

/// @title Step3_Verify — confirm all three Gnosis beacons point at the new impls.
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 3: Verify Gnosis beacons ===");
        _verify(dd, "ParticipationToken", TOKEN_VERSION);
        _verify(dd, "Executor", EXECUTOR_VERSION);
        _verify(dd, "OrgDeployer", DEPLOYER_VERSION);
    }

    function _verify(DeterministicDeployer dd, string memory typeName, string memory version) internal view {
        address expected = dd.computeAddress(dd.computeSalt(typeName, version));
        address current = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256(bytes(typeName)));
        console.log(typeName, current == expected ? "PASS" : "WAITING", current);
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                             SHARED SIM SCAFFOLDING
═══════════════════════════════════════════════════════════════════════════*/

interface IParticipationTokenSetters {
    function setTaskManager(address tm) external;
    function setEducationHub(address eh) external;
}

/// @dev Snapshot of a live ParticipationToken + Executor, captured pre-upgrade and re-checked post.
struct TokenSnapshot {
    string name;
    string symbol;
    uint256 totalSupply;
    address taskManager;
    address educationHub;
    address executor;
    address executorAllowedCaller;
}

/// @notice Deploys the three impls via DD (pranking Hudson) and re-checks idempotency.
abstract contract SecurityUpgradeSimBase is Script {
    function _poaManager() internal pure virtual returns (address);
    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal virtual;

    /// @dev Deploy an impl via DD (skip if code already present) and return its address.
    function _deployImpl(DeterministicDeployer dd, string memory typeName, string memory version, bytes memory code)
        internal
        returns (address impl)
    {
        bytes32 salt = dd.computeSalt(typeName, version);
        impl = dd.computeAddress(salt);
        if (impl.code.length == 0) {
            vm.prank(HUDSON_ADMIN);
            address deployed = dd.deploy(salt, code);
            require(deployed == impl, "Sim: DD address mismatch");
        }
        require(impl.code.length > 0, "Sim: impl code missing");
    }

    /// @dev Deploy + upgrade one beacon and assert the PoaManager now reports the new impl.
    function _deployAndUpgrade(
        DeterministicDeployer dd,
        string memory typeName,
        string memory version,
        bytes memory code
    ) internal returns (address impl) {
        impl = _deployImpl(dd, typeName, version, code);
        _upgradeBeacon(typeName, impl, version);
        address current = PoaManager(_poaManager()).getCurrentImplementationById(keccak256(bytes(typeName)));
        require(current == impl, "Sim: beacon upgrade did not stick");
        console.log(typeName, "beacon upgraded ->", impl);
    }

    /// @dev Run all three upgrades. Returns nothing; assertions inside.
    function _upgradeAll() internal {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        _deployAndUpgrade(dd, "ParticipationToken", TOKEN_VERSION, type(ParticipationToken).creationCode);
        _deployAndUpgrade(dd, "Executor", EXECUTOR_VERSION, type(Executor).creationCode);
        _deployAndUpgrade(dd, "OrgDeployer", DEPLOYER_VERSION, type(OrgDeployer).creationCode);
    }

    /// @dev Snapshot a live token + its executor's readable state.
    function _snapshot(address token) internal view returns (TokenSnapshot memory s) {
        ParticipationToken t = ParticipationToken(token);
        s.name = t.name();
        s.symbol = t.symbol();
        s.totalSupply = t.totalSupply();
        s.taskManager = t.taskManager();
        s.educationHub = t.educationHub();
        s.executor = t.executor();
        s.executorAllowedCaller = Executor(payable(s.executor)).allowedCaller();
    }

    /// @dev Require two snapshots identical (storage survived the impl swap).
    function _requireSurvived(TokenSnapshot memory pre, TokenSnapshot memory post) internal pure {
        require(keccak256(bytes(pre.name)) == keccak256(bytes(post.name)), "Sim: token name drifted");
        require(keccak256(bytes(pre.symbol)) == keccak256(bytes(post.symbol)), "Sim: token symbol drifted");
        require(pre.totalSupply == post.totalSupply, "Sim: totalSupply drifted");
        require(pre.taskManager == post.taskManager, "Sim: taskManager drifted");
        require(pre.educationHub == post.educationHub, "Sim: educationHub drifted");
        require(pre.executor == post.executor, "Sim: token executor drifted");
        require(pre.executorAllowedCaller == post.executorAllowedCaller, "Sim: executor allowedCaller drifted");
    }
}

interface IPaymasterHubRule {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function getRule(bytes32 orgId, address target, bytes4 selector) external view returns (Rule memory);
}

interface IPaymasterHubRegistrar {
    function setOrgRegistrar(address registrar) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-A security upgrade on Gnosis.
 *
 * LIVE ORG (Gnosis subgraph poa-gnosis-v-1, org "KUBI"):
 *   orgId            0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b (NB: KUBI's own id below)
 *   KUBI orgId       0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e
 *   participationToken 0x23641b4b54e1bf63fd519b242407b9314093b33c ("KU Blockchain Institute Reputation Token" / KUBIX)
 *   executor           0x23f90B3859818A843C3a848627A304Bc53947342
 *   taskManager        0xF57024fC77915Fce8f2608afdd027941bCEE3336
 *   educationHub       0x83C7Aa49C0C5a55E22640AC164abA838E6f1f7ae
 *
 * Asserts (in order):
 *   (a) storage survival: token name/symbol/totalSupply/taskManager/educationHub/executor and
 *       the executor's allowedCaller are identical before and after the three beacon upgrades.
 *   (b) C-01 regression post-upgrade: an attacker calling setEducationHub/setTaskManager reverts;
 *       the org's real executor CAN call setEducationHub (then it is restored so (a)'s post-check
 *       — which runs BEFORE (b) — is unaffected).
 *   (c) fresh-org deploy on the upgraded OrgDeployer proxy: token.taskManager() == its TaskManager.
 *   (d) L-53: for the fresh org, PaymasterHub.getRule reports updateOrgMetaAsAdmin allowed against
 *       the OrgRegistry target and NOT allowed against the UniversalAccountRegistry target.
 */
contract SimGnosis is SecurityUpgradeSimBase {
    address constant KUBI_TOKEN = 0x23641B4b54E1bf63FD519b242407b9314093B33C;
    address constant KUBI_EXECUTOR = 0x23f90B3859818A843C3a848627A304Bc53947342;
    address constant KUBI_TASK_MANAGER = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
    address constant KUBI_EDU_HUB = 0x83C7Aa49C0C5a55E22640AC164abA838E6f1f7ae;

    // Live Gnosis wiring (read from chain 2026-07-04).
    // NB: the live OrgDeployer proxy (0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c) cannot be used
    // for the fresh-org sub-sim because the on-chain factories it points at have drifted from
    // current src (see _assertFreshOrg); we deploy a fresh v16 proxy instead.
    address constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    // Live UniversalAccountRegistry (used as the fresh-org registryAddr AND the L-53 negative
    // target — updateOrgMetaAsAdmin must NOT be registered against it).
    address constant UNIVERSAL_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;

    // Live beacons (read from PoaManager.getBeaconById). The fresh-org sub-sim creates fresh
    // proxies against these so it exercises the just-upgraded OrgDeployer v16 impl end-to-end.
    address constant ORG_DEPLOYER_BEACON = 0x2f48EB6Ed3D6C37bF8858c39a32262867ba67293;
    address constant ORG_REGISTRY_BEACON = 0x76402cE426b53F28467Aa67Dc4cE5bC2785cCFFE;
    address constant UAR_BEACON = 0x4f2a9d4cB62BEfBA35dAC2D3dE32c55413C65BB6;
    // Live Hats singleton on Gnosis.
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    bytes4 constant UPDATE_ORG_META_SEL = 0x3d2d2382; // updateOrgMetaAsAdmin(bytes32,bytes,bytes32)

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        // Destination-chain path CLAUDE.md prefers: Satellite owner (Hudson) drives the
        // local PoaManager directly (no Hyperlane round-trip). upgradeBeaconDirect keeps
        // the Satellite as msg.sender to PoaManager.upgradeBeacon (which is onlyOwner).
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-A security upgrade on Gnosis fork ===\n");

        // (a) pre-upgrade snapshot.
        TokenSnapshot memory pre = _snapshot(KUBI_TOKEN);
        console.log("KUBI token:", pre.name);
        console.log("  taskManager:", pre.taskManager);
        console.log("  educationHub:", pre.educationHub);
        console.log("  executor:", pre.executor);

        // Deploy + upgrade all three beacons.
        _upgradeAll();

        // (a) post-upgrade survival check.
        TokenSnapshot memory post = _snapshot(KUBI_TOKEN);
        _requireSurvived(pre, post);
        console.log("(a) storage survived the three beacon upgrades OK");

        // (b) C-01 regression (runs AFTER the survival check so it can't pollute it).
        _assertC01(pre);

        // (c) + (d) fresh org on the upgraded OrgDeployer.
        _assertFreshOrg();

        console.log("\nPASS: WS-A security upgrade validated against live Gnosis state.");
    }

    /*──────── (b) C-01 regression ────────*/
    function _assertC01(TokenSnapshot memory pre) internal {
        IParticipationTokenSetters token = IParticipationTokenSetters(KUBI_TOKEN);
        address attacker = makeAddr("c01-attacker");

        // Attacker cannot set the education hub.
        vm.prank(attacker);
        (bool okEdu,) = KUBI_TOKEN.call(abi.encodeCall(IParticipationTokenSetters.setEducationHub, (attacker)));
        require(!okEdu, "C-01: attacker setEducationHub must revert");

        // Attacker cannot set the task manager either.
        vm.prank(attacker);
        (bool okTm,) = KUBI_TOKEN.call(abi.encodeCall(IParticipationTokenSetters.setTaskManager, (attacker)));
        require(!okTm, "C-01: attacker setTaskManager must revert");

        // The org's real executor CAN set the education hub.
        vm.prank(pre.executor);
        token.setEducationHub(attacker);
        require(ParticipationToken(KUBI_TOKEN).educationHub() == attacker, "C-01: executor setEducationHub failed");

        // Restore the original hub so we leave state clean.
        vm.prank(pre.executor);
        token.setEducationHub(pre.educationHub);
        require(ParticipationToken(KUBI_TOKEN).educationHub() == pre.educationHub, "C-01: educationHub restore failed");
        console.log("(b) C-01: attacker blocked, executor allowed, state restored OK");
    }

    /*──────── (c)+(d) fresh org deploy + L-53 ────────*/
    /// @dev The OrgDeployer's step-8 rewiring (C-01) and the L-53 rule-target fix are BOTH
    ///      internal to the current-src OrgDeployer + factory stack, and the current-src
    ///      ModulesFactory ABI has drifted from the STALE factory deployed on Gnosis (its
    ///      deployModules selector no longer matches — a pre-existing condition that WS-B's
    ///      factory redeploy resolves). So a deployFullOrg on the LIVE OrgDeployer proxy would
    ///      revert inside the stale factory. To exercise the JUST-UPGRADED OrgDeployer v16 impl
    ///      end-to-end we spin up a fresh, self-consistent current-src stack: fresh factories +
    ///      a fresh OrgRegistry proxy + a fresh OrgDeployer proxy on the live (upgraded) beacon,
    ///      reusing the ABI-stable live singletons (PoaManager, Hats, PaymasterHub). The fresh
    ///      OrgDeployer runs the SAME v16 bytecode the beacon now points at, so C-01 + L-53 are
    ///      validated against exactly the code this script upgrades to.
    function _assertFreshOrg() internal {
        vm.deal(HUDSON_ADMIN, 10 ether);
        (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) = _bootstrapFreshStack();

        bytes32 orgId = keccak256(abi.encodePacked("ws-a-sim-org", vm.getBlockTimestamp(), block.number));
        OrgDeployer.DeploymentParams memory params = _buildParams(orgId, uar);

        vm.prank(HUDSON_ADMIN);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        // (c) the new token is wired to its own TaskManager through the executor-only setter.
        address newTm = ParticipationToken(result.participationToken).taskManager();
        require(newTm == result.taskManager, "(c) fresh org token.taskManager() != its TaskManager");
        console.log("(c) fresh org token wired to TaskManager OK:", newTm);

        // (d) L-53: updateOrgMetaAsAdmin rule points at the OrgRegistry, not the account registry.
        IPaymasterHubRule pm = IPaymasterHubRule(GNOSIS_PAYMASTER);
        IPaymasterHubRule.Rule memory onOrgReg = pm.getRule(orgId, address(orgRegistry), UPDATE_ORG_META_SEL);
        IPaymasterHubRule.Rule memory onAcctReg = pm.getRule(orgId, uar, UPDATE_ORG_META_SEL);
        require(onOrgReg.allowed, "(d) L-53: updateOrgMetaAsAdmin not allowed against OrgRegistry");
        require(!onAcctReg.allowed, "(d) L-53: updateOrgMetaAsAdmin wrongly allowed against account registry");
        console.log("(d) L-53: updateOrgMetaAsAdmin allowed on OrgRegistry, disallowed on account registry OK");

        // (b2) C-01 unset-slot regression: this fresh org has educationHub == 0 (education
        // disabled) — the exact precondition the old open-first-set bug exposed. An attacker
        // must NOT be able to claim the slot; only KUBI's already-set slots were probed in (b).
        address freshAttacker = makeAddr("c01-fresh-attacker");
        vm.prank(freshAttacker);
        (bool okFresh,) =
            result.participationToken.call(abi.encodeCall(IParticipationTokenSetters.setEducationHub, (freshAttacker)));
        require(!okFresh, "(b2) C-01: attacker claimed unset educationHub on fresh org");
        require(
            ParticipationToken(result.participationToken).educationHub() == address(0),
            "(b2) C-01: fresh org educationHub mutated"
        );
        console.log("(b2) C-01: attacker blocked on UNSET educationHub slot OK");
    }

    /// @dev Deploy a fresh, internally-consistent current-src OrgDeployer stack on the fork.
    function _bootstrapFreshStack() internal returns (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) {
        // Fresh factories + hats-tree helper (current src, matched to the v16 OrgDeployer).
        GovernanceFactory gov = new GovernanceFactory();
        AccessFactory acc = new AccessFactory();
        ModulesFactory mods = new ModulesFactory();
        HatsTreeSetup hatsTree = new HatsTreeSetup();

        // Fresh UniversalAccountRegistry proxy (its own bootstrap owner).
        uar = address(
            new BeaconProxy(
                UAR_BEACON, abi.encodeWithSelector(UniversalAccountRegistry.initialize.selector, HUDSON_ADMIN)
            )
        );

        // Fresh OrgRegistry proxy, initially owned by HUDSON_ADMIN so we can hand it to the deployer.
        orgRegistry = OrgRegistry(
            address(
                new BeaconProxy(
                    ORG_REGISTRY_BEACON, abi.encodeWithSelector(OrgRegistry.initialize.selector, HUDSON_ADMIN, HATS)
                )
            )
        );

        // Fresh OrgDeployer proxy on the live (upgraded to v16) beacon.
        deployer = OrgDeployer(
            address(
                new BeaconProxy(
                    ORG_DEPLOYER_BEACON,
                    abi.encodeWithSelector(
                        OrgDeployer.initialize.selector,
                        address(gov),
                        address(acc),
                        address(mods),
                        GNOSIS_POA_MANAGER,
                        address(orgRegistry),
                        HATS,
                        address(hatsTree),
                        GNOSIS_PAYMASTER
                    )
                )
            )
        );

        // The deployer must own the OrgRegistry (createOrgBootstrap/setOrgExecutor are onlyOwner).
        vm.prank(HUDSON_ADMIN);
        orgRegistry.transferOwnership(address(deployer));

        // Authorize the fresh deployer as the PaymasterHub org registrar (onlyPoaManager gate).
        vm.prank(GNOSIS_POA_MANAGER);
        IPaymasterHubRegistrar(GNOSIS_PAYMASTER).setOrgRegistrar(address(deployer));
    }

    /*──────── minimal-config builders (split out to dodge stack-too-deep) ────────*/
    function _buildParams(bytes32 orgId, address uar)
        internal
        pure
        returns (OrgDeployer.DeploymentParams memory params)
    {
        params.orgId = orgId;
        params.orgName = "WS-A Sim Org";
        params.metadataHash = bytes32(0);
        params.registryAddr = uar;
        params.deployerAddress = HUDSON_ADMIN;
        params.deployerUsername = "";
        params.regDeadline = 0;
        params.regNonce = 0;
        params.regSignature = "";
        params.autoUpgrade = true;
        params.hybridThresholdPct = 50;
        params.ddThresholdPct = 50;
        params.hybridClasses = _buildClasses();
        params.ddInitialTargets = new address[](0);
        params.roles = _buildRoles();
        params.roleAssignments = _buildRoleAssignments();
        params.metadataAdminRoleIndex = type(uint256).max;
        params.passkeyEnabled = false;
        params.educationHubConfig = ModulesFactory.EducationHubConfig({enabled: false});
        params.bootstrap = _emptyBootstrap();
        params.paymasterConfig = _paymasterConfig();
        params.taskManagerPerms = _emptyPerms();
    }

    function _buildClasses() internal pure returns (IHybridVotingInit.ClassConfig[] memory classes) {
        uint256[] memory emptyHats = new uint256[](0);
        classes = new IHybridVotingInit.ClassConfig[](2);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 50,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: emptyHats
        });
        classes[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: 50,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: emptyHats
        });
    }

    function _buildRoles() internal pure returns (RoleConfigStructs.RoleConfig[] memory roles) {
        roles = new RoleConfigStructs.RoleConfig[](2);
        roles[0] = _role("DEFAULT", false, 1); // adminRoleIndex 1 (governed by EXECUTIVE)
        roles[1] = _role("EXECUTIVE", true, type(uint256).max); // top of hierarchy, minted to deployer
    }

    function _role(string memory name, bool isTop, uint256 adminRoleIndex)
        internal
        pure
        returns (RoleConfigStructs.RoleConfig memory r)
    {
        r.name = name;
        r.image = "ipfs://role";
        r.metadataCID = bytes32(0);
        r.canVote = true;
        r.vouching = RoleConfigStructs.RoleVouchingConfig({
            enabled: false, quorum: 0, voucherRoleIndex: 0, combineWithHierarchy: false
        });
        r.defaults = RoleConfigStructs.RoleEligibilityDefaults({eligible: true, standing: true});
        r.hierarchy = RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: adminRoleIndex});
        r.distribution =
            RoleConfigStructs.RoleDistributionConfig({mintToDeployer: isTop, additionalWearers: new address[](0)});
        r.hatConfig = RoleConfigStructs.HatConfig({maxSupply: type(uint32).max, mutableHat: true});
    }

    function _buildRoleAssignments() internal pure returns (OrgDeployer.RoleAssignments memory) {
        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 1,
            tokenMemberRolesBitmap: 1,
            tokenApproverRolesBitmap: 2,
            taskCreatorRolesBitmap: 2,
            educationCreatorRolesBitmap: 2,
            educationMemberRolesBitmap: 1,
            hybridProposalCreatorRolesBitmap: 2,
            ddVotingRolesBitmap: 1,
            ddCreatorRolesBitmap: 2
        });
    }

    function _paymasterConfig() internal pure returns (OrgDeployer.PaymasterConfig memory) {
        // autoWhitelistContracts=true → _buildDefaultPaymasterRules runs → L-53 rule is emitted.
        return OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: true,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });
    }

    function _emptyBootstrap() internal pure returns (OrgDeployer.BootstrapConfig memory) {
        return OrgDeployer.BootstrapConfig({
            projects: new ITaskManagerBootstrap.BootstrapProjectConfig[](0),
            tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)
        });
    }

    function _emptyPerms() internal pure returns (OrgDeployer.TaskManagerPermConfig memory) {
        return OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)});
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                  SIM: ARBITRUM
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimArbitrum
 * @notice Arbitrum counterpart: upgrades the three beacons through the Hub-owned Arbitrum
 *         PoaManager (destination effect of upgradeBeaconCrossChain, no Hyperlane fee/wait)
 *         and asserts storage survival on the live "Poa" org. Behavior asserts (b)-(d) are
 *         Gnosis-only per the workstream spec.
 *
 * LIVE ORG (Arbitrum subgraph poa-arb-v-1, org "Poa"):
 *   participationToken 0x33cd0b9ae54c43c11fd05fe00afd3dbc71d9603e ("Poa Token" / PT)
 *   executor           0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41
 *   taskManager        0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0
 */
contract SimArbitrum is SecurityUpgradeSimBase {
    address constant POA_TOKEN = 0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E;

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        // Destination effect of Hub.upgradeBeaconCrossChain: the Hub owns the Arbitrum PoaManager.
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-A security upgrade on Arbitrum fork ===\n");

        TokenSnapshot memory pre = _snapshot(POA_TOKEN);
        console.log("Poa token:", pre.name);
        console.log("  taskManager:", pre.taskManager);
        console.log("  executor:", pre.executor);

        _upgradeAll();

        TokenSnapshot memory post = _snapshot(POA_TOKEN);
        _requireSurvived(pre, post);
        console.log("Storage survived the three beacon upgrades OK");

        console.log("\nPASS: WS-A security upgrade validated against live Arbitrum state.");
    }
}
