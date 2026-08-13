// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {Executor} from "../../src/Executor.sol";

import {PoaManager} from "../../src/PoaManager.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * RoleManager module beacon-upgrade wave (W8) — 8 impls
 * ============================================================================
 *
 * Upgrades the SEVEN per-org module impls whose bytecode changed for the
 * RoleManager feature, PLUS the Executor (new configureModule bootstrap relay):
 *   EligibilityModule     — derived group-eligibility path, roleManager auth slot,
 *                           setGroupEligibility/getGroupMemberHats, claimHat(s),
 *                           updateHatConfig, expectedHatId guard.
 *   DirectDemocracyVoting — createProposalV2 (quorumOverride) + configAdmin.
 *   HybridVoting          — createProposalV2 (quorumOverride, equalWeight),
 *                           add/removeHatFromClass + configAdmin.
 *   TaskManager           — configAdmin field + executor||configAdmin gate.
 *   ParticipationToken    — configAdmin field + executor||configAdmin gate.
 *   EducationHub          — configAdmin field + executor||configAdmin gate.
 *   QuickJoin             — configAdmin field + executor||configAdmin gate.
 *   Executor              — configureModule(target,data) onlyOwner bootstrap relay.
 *
 * ── EXTERNAL LIBRARY LINKING ────────────────────────────────────────────────
 * Two of the eight impls carry DEPLOY-LINKED external libraries (verified via
 * out/<C>.sol/<C>.json `bytecode.linkReferences`):
 *   EligibilityModule -> src/libs/EligibilityLogic.sol:EligibilityLogic  (6 refs)
 *   HybridVoting      -> src/libs/HybridVotingConfig.sol:HybridVotingConfig,
 *                        src/libs/HybridVotingCore.sol:HybridVotingCore,
 *                        src/libs/HybridVotingProposals.sol:HybridVotingProposals
 * The other six impls have EMPTY linkReferences (no external libs).
 *
 * Linking mechanism — same convention as script/upgrades/UpgradeGovernanceSecurity.s.sol
 * (the prior HybridVoting beacon wave): the scripts reference `type(C).creationCode`
 * and Foundry AUTO-DEPLOYS every required library FIRST and links its address into
 * the returned creation bytecode before it is handed to DeterministicDeployer. So
 * "libs before impls" ordering is satisfied structurally — the library-deploy txns
 * are emitted ahead of the impl deploy in any --broadcast. Because DeterministicDeployer
 * is CREATE3, the impl's deterministic address depends ONLY on (type, version) salt,
 * NOT on the embedded (chain-local) library addresses — so the same impl address is
 * reproduced on both chains even though each chain links its own library instances.
 *
 * ── VERSION SELECTION (CLAUDE.md dual-surface probe, both chains, 2026-08-13) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer (CREATE3): a given (type, version) is the SAME address on both.
 * Probed getVersionCount then BOTH surfaces (registry getImplementation + CREATE2
 * cast code) upward. Lowest version FREE on EVERY target chain chosen:
 *
 *   EligibilityModule:     count g=6 a=7; v7 gnosis-free but arb-taken -> pick v8
 *     v8 gnosis reg=no create2=no; v8 arb reg=no create2=no  => v8  (0x8E0C07f5fCDc69b9B20fc67F70096ab18a411c9F)
 *   DirectDemocracyVoting: count g=8 a=8; v9-v12 TAKEN both     => v13 (0x4760Ce74546271606E53D30F888Ca52Ef82345a9)
 *   HybridVoting:          count g=8 a=8; v9-v12 TAKEN both     => v13 (0x81157A79d2555EB57E0b1e921a84A293Dac4338d)
 *   TaskManager:           count g=6 a=6; v7 TAKEN both         => v8  (0x0C92D294BdadBBb8FcFBe32166C570E68b60540b)
 *   ParticipationToken:    count g=5 a=5; v6-v7 TAKEN both      => v8  (0x3b4D5274DB134557B1545d3e20536cc6A8d9A042)
 *   EducationHub:          count g=2 a=2; v3 gnosis create2-TAKEN => v4 (0xAa5a77DcC567A0A34A131724E233f850e4cdCb6C)
 *   QuickJoin:             count g=5 a=6; v6-v7 TAKEN           => v8  (0x3292E163Dc75F09Ac90aaa421752226419079449)
 *   Executor:              count g=4 a=4; v4 TAKEN both         => v5  (0xF6dac1A17d50bcD84A1c89CC6C8Bfdb79fC04425)
 *   (predicted CREATE3 addresses identical on Gnosis + Arbitrum.)
 *
 * ── BROADCAST ORDER (do NOT run in this workstream) ──
 *   1. Step1_DeployOnGnosis     --rpc-url gnosis   --broadcast --slow  (DD-deploy 8 impls + libs)
 *   2. Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow (DD-deploy on Arbitrum +
 *        Hub.upgradeBeaconCrossChain per type → Arbitrum-local + Gnosis cross-chain dispatch)
 *   3. Step2b_UpgradeGnosis     --rpc-url gnosis   --broadcast --slow  (Satellite.upgradeBeaconDirect
 *        per type — destination-chain path, skips the ~5-min Hyperlane wait & the 0.005 ETH fee)
 *   4. Step3_Verify             --rpc-url gnosis / --rpc-url arbitrum  (read-only PASS check)
 *
 * ── SIMS (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/UpgradeModulesForRoleManager.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/UpgradeModulesForRoleManager.s.sol:SimArbitrum --fork-url arbitrum -vvv
 * ============================================================================
 */

/*──────────────────────────── Shared addresses ───────────────────────────*/
address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // owner = Hudson
address constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815; // owned by the Hub
address constant HUDSON_ADMIN = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
uint256 constant HYPERLANE_FEE = 0.005 ether;

// ERC-1967 beacon slot: bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)
bytes32 constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

// Chosen versions (see VERSION SELECTION above).
string constant EM_VERSION = "v8";
string constant DDV_VERSION = "v13";
string constant HV_VERSION = "v13";
string constant TM_VERSION = "v8";
string constant PT_VERSION = "v8";
string constant EDU_VERSION = "v4";
string constant QJ_VERSION = "v8";
string constant EXEC_VERSION = "v5";

/// @dev Satellite.upgradeBeaconDirect forwards to PoaManager.upgradeBeacon (onlyOwner=Satellite)
///      with the Satellite as msg.sender — the destination-chain emergency upgrade path.
interface ISatellite {
    function owner() external view returns (address);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

interface IBeaconRead {
    function implementation() external view returns (address);
}

/*═══════════════════════════════════════════════════════════════════════════
                              SHARED TYPE TABLE
═══════════════════════════════════════════════════════════════════════════*/

/// @dev One row per upgraded type: the registry typeName, its chosen version, and the
///      linked creationCode (Foundry pre-links external libs into these).
struct TypeRow {
    string typeName;
    string version;
    bytes code;
}

library ModuleTypeTable {
    function rows() internal pure returns (TypeRow[] memory t) {
        t = new TypeRow[](8);
        t[0] = TypeRow("EligibilityModule", EM_VERSION, type(EligibilityModule).creationCode);
        t[1] = TypeRow("DirectDemocracyVoting", DDV_VERSION, type(DirectDemocracyVoting).creationCode);
        t[2] = TypeRow("HybridVoting", HV_VERSION, type(HybridVoting).creationCode);
        t[3] = TypeRow("TaskManager", TM_VERSION, type(TaskManager).creationCode);
        t[4] = TypeRow("ParticipationToken", PT_VERSION, type(ParticipationToken).creationCode);
        t[5] = TypeRow("EducationHub", EDU_VERSION, type(EducationHub).creationCode);
        t[6] = TypeRow("QuickJoin", QJ_VERSION, type(QuickJoin).creationCode);
        t[7] = TypeRow("Executor", EXEC_VERSION, type(Executor).creationCode);
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                 BROADCAST STEPS
═══════════════════════════════════════════════════════════════════════════*/

/// @title Step1_DeployOnGnosis — deploy all 8 impls (+ their libs, auto-linked) on Gnosis (idempotent).
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        TypeRow[] memory t = ModuleTypeTable.rows();
        console.log("\n=== Step 1: Deploy RoleManager-wave module impls on Gnosis ===");
        vm.startBroadcast(key);
        for (uint256 i; i < t.length; ++i) {
            _deploy(dd, t[i].typeName, t[i].version, t[i].code);
        }
        vm.stopBroadcast();
        console.log("\nNext: Step2_UpgradeFromArbitrum on Arbitrum");
    }

    function _deploy(DeterministicDeployer dd, string memory typeName, string memory version, bytes memory code)
        internal
    {
        bytes32 salt = dd.computeSalt(typeName, version);
        address predicted = dd.computeAddress(salt);
        console.log(typeName, version, predicted);
        if (predicted.code.length > 0) {
            console.log("  already deployed, skipping");
            return;
        }
        address deployed = dd.deploy(salt, code);
        require(deployed == predicted, "Step1: DD address mismatch");
        console.log("  deployed at:", deployed);
    }
}

/// @title Step2_UpgradeFromArbitrum — DD-deploy on Arbitrum + upgrade each beacon Arbitrum-local
///        AND cross-chain-dispatch to Gnosis via the Hub.
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        require(hub.owner() == vm.addr(key), "Step2: signer must own Hub");
        TypeRow[] memory t = ModuleTypeTable.rows();
        console.log("\n=== Step 2: Upgrade from Arbitrum (local + cross-chain to Gnosis) ===");
        vm.startBroadcast(key);
        for (uint256 i; i < t.length; ++i) {
            _upgrade(hub, dd, t[i].typeName, t[i].version, t[i].code);
        }
        vm.stopBroadcast();
        console.log("\nWait ~5 min for Hyperlane OR run Step2b_UpgradeGnosis to upgrade Gnosis directly.");
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
        if (impl.code.length == 0) impl = dd.deploy(salt, code);
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, impl, version);
        console.log(typeName, "upgraded (Arbitrum local + Gnosis dispatch):", impl);
    }
}

/// @title Step2b_UpgradeGnosis — upgrade all 8 Gnosis beacons directly (no Hyperlane wait/fee).
///        Requires Step1 impls already deployed on Gnosis.
contract Step2b_UpgradeGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        TypeRow[] memory t = ModuleTypeTable.rows();
        console.log("\n=== Step 2b: Upgrade Gnosis beacons via Satellite.upgradeBeaconDirect ===");
        vm.startBroadcast(key);
        for (uint256 i; i < t.length; ++i) {
            _upgrade(dd, t[i].typeName, t[i].version);
        }
        vm.stopBroadcast();
        console.log("\nNext: Step3_Verify on Gnosis");
    }

    function _upgrade(DeterministicDeployer dd, string memory typeName, string memory version) internal {
        address impl = dd.computeAddress(dd.computeSalt(typeName, version));
        require(impl.code.length > 0, "Step2b: impl not deployed on Gnosis (run Step1 first)");
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, impl, version);
        console.log(typeName, "upgraded on Gnosis:", impl);
    }
}

/// @title Step3_Verify — confirm every beacon points at the new impl on the given chain.
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address poaManager;
        try PoaManagerHub(payable(HUB)).poaManager() returns (PoaManager pm) {
            poaManager = address(pm); // Arbitrum
        } catch {
            poaManager = GNOSIS_POA_MANAGER; // Gnosis
        }
        TypeRow[] memory t = ModuleTypeTable.rows();
        console.log("\n=== Step 3: Verify RoleManager-wave beacons ===");
        for (uint256 i; i < t.length; ++i) {
            address expected = dd.computeAddress(dd.computeSalt(t[i].typeName, t[i].version));
            address current = PoaManager(poaManager).getCurrentImplementationById(keccak256(bytes(t[i].typeName)));
            console.log(t[i].typeName, current == expected ? "PASS" : "WAITING", current);
        }
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                             SHARED SIM SCAFFOLDING
═══════════════════════════════════════════════════════════════════════════*/

/// @dev A live proxy snapshot: which beacon it points at, and a hash of a stable storage-backed read.
struct ProxySnapshot {
    address beacon;
    bytes32 readHash;
}

abstract contract ModuleWaveSimBase is Script {
    function _poaManager() internal pure virtual returns (address);
    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal virtual;

    /*──────── deploy + beacon upgrade (libs auto-linked into creationCode by Foundry) ────────*/
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

    function _deployAndUpgrade(TypeRow memory row) internal returns (address impl) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        impl = _deployImpl(dd, row.typeName, row.version, row.code);
        _upgradeBeacon(row.typeName, impl, row.version);
        address current = PoaManager(_poaManager()).getCurrentImplementationById(keccak256(bytes(row.typeName)));
        require(current == impl, string.concat(row.typeName, ": beacon upgrade did not stick"));
        console.log(row.typeName, "beacon ->", impl);
    }

    /*──────── live-proxy read snapshots (storage-backed, stable getters) ────────*/
    function _snapshot(address proxy, bytes4 selector) internal view returns (ProxySnapshot memory s) {
        s.beacon = address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeWithSelector(selector));
        require(ok, "Sim: snapshot read reverted");
        s.readHash = keccak256(ret);
    }

    /// @dev After the wave: (1) the Mirror beacon now resolves to the new impl (wave reached the
    ///      live org), and (2) the storage-backed read is byte-identical (behavior preserved /
    ///      inert-until-configured).
    function _requireFollowedAndStable(
        address proxy,
        bytes4 selector,
        ProxySnapshot memory pre,
        address newImpl,
        string memory tag
    ) internal view {
        require(
            pre.beacon == address(uint160(uint256(vm.load(proxy, BEACON_SLOT)))),
            string.concat(tag, ": beacon slot moved")
        );
        address resolved = IBeaconRead(pre.beacon).implementation();
        require(resolved == newImpl, string.concat(tag, ": Mirror beacon did not follow to new impl"));
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeWithSelector(selector));
        require(ok, string.concat(tag, ": post-read reverted"));
        require(keccak256(ret) == pre.readHash, string.concat(tag, ": storage-backed read drifted"));
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Production-profile fork sim of the W8 module wave on Gnosis.
 *
 * LIVE ORG (Gnosis subgraph poa-gnosis-v-1, org "Test6", all modules Mirror mode):
 *   eligibilityModule     0xf01f2bdd5c86e7b676117cb0d6e2c07aa36e8c8b (superAdmin = executor)
 *   directDemocracyVoting 0xd2667117ed47ad259fef73f54f31a3ef9a5d889f
 *   hybridVoting          0xf642dde77848dc195c8089f4042a311ed650d7a6
 *   taskManager           0x3d93f0d090356d25e7a1614f0f8764b103ca99bc
 *   participationToken    0x6083c52b2f5861f327526bd646eaa754eddd5ccf
 *   educationHub          0x6a29222e29fdc0000aba55329dff0a50d9a8e8f9
 *   quickJoin             0x09d7006724c2ba9bf9084ad9db6dbb09b990843d
 *   executor              0xa09f1035ff97d17cca40048f027c654b66b83183
 *
 * Asserts, for each of the 8 types:
 *   (a) getCurrentImplementationById flips to the CREATE3-predicted new impl (protocol level);
 *   (b) Test6's Mirror-mode proxy beacon now resolves to that new impl (wave reached the org);
 *   (c) a storage-backed read is byte-identical before/after (behavior preserved).
 *   Plus EligibilityModule inert-until-configured deep check: roleManager()==0, superAdmin
 *   unchanged, getWearerStatus(superAdmin, adminHat) unchanged across the upgrade.
 */
contract SimGnosis is ModuleWaveSimBase {
    address constant T6_EM = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    address constant T6_DDV = 0xd2667117ED47aD259fEf73F54f31a3eF9A5D889F;
    address constant T6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
    address constant T6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
    address constant T6_PT = 0x6083c52b2F5861F327526bD646EaA754edDD5cCf;
    address constant T6_EDU = 0x6a29222E29FDc0000AbA55329DfF0a50D9a8e8F9;
    address constant T6_QJ = 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d;
    address constant T6_EXEC = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: W8 module wave on Gnosis fork (org Test6) ===\n");
        TypeRow[] memory t = ModuleTypeTable.rows();
        address[8] memory proxies = [T6_EM, T6_DDV, T6_HV, T6_TM, T6_PT, T6_EDU, T6_QJ, T6_EXEC];
        bytes4[8] memory reads = _reads();

        // Pre-upgrade snapshots on all 8 live Test6 proxies.
        ProxySnapshot[8] memory pre;
        for (uint256 i; i < 8; ++i) {
            pre[i] = _snapshot(proxies[i], reads[i]);
        }

        // EligibilityModule inert-until-configured deep pre-read.
        // NOTE: roleManager() is a NEW getter that does not exist on the live (old) impl, so it can
        // only be read AFTER the upgrade. superAdmin()/getWearerStatus() pre-date the wave.
        EligibilityModule em = EligibilityModule(T6_EM);
        address emSuperPre = em.superAdmin();
        uint256 adminHat = em.eligibilityModuleAdminHat();
        (bool ePre, bool sPre) = em.getWearerStatus(emSuperPre, adminHat);

        // Run the full wave.
        address[8] memory newImpls;
        for (uint256 i; i < 8; ++i) {
            newImpls[i] = _deployAndUpgrade(t[i]);
        }

        // Post-upgrade: each Mirror proxy followed + reads stable.
        for (uint256 i; i < 8; ++i) {
            _requireFollowedAndStable(proxies[i], reads[i], pre[i], newImpls[i], t[i].typeName);
        }
        console.log("(a/b/c) all 8 beacons flipped, Test6 Mirror proxies followed, reads stable");

        // EligibilityModule inert-until-configured deep post-read.
        require(em.superAdmin() == emSuperPre, "EM: superAdmin drifted");
        require(em.roleManager() == address(0), "EM: roleManager became non-zero after upgrade");
        (bool ePost, bool sPost) = em.getWearerStatus(emSuperPre, adminHat);
        require(ePost == ePre && sPost == sPre, "EM: getWearerStatus drifted (derived path not inert)");
        console.log("(EM) derived-eligibility path inert-until-configured: getWearerStatus unchanged");

        console.log("\nPASS: W8 module wave validated against live Gnosis (Test6) state.");
    }

    /// @dev Stable storage-backed zero-arg getter per type, in the fixed table order.
    function _reads() internal pure returns (bytes4[8] memory r) {
        r[0] = EligibilityModule.superAdmin.selector;
        r[1] = DirectDemocracyVoting.executor.selector;
        r[2] = HybridVoting.executor.selector;
        r[3] = bytes4(0xed2f21f5); // TaskManager.MODULE_ID()
        r[4] = ParticipationToken.executor.selector;
        r[5] = EducationHub.executor.selector;
        r[6] = QuickJoin.executor.selector;
        r[7] = bytes4(0x8da5cb5b); // Executor.owner()
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                  SIM: ARBITRUM
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimArbitrum
 * @notice Arbitrum counterpart: upgrades all 8 beacons via the Hub-owned Arbitrum PoaManager
 *         (destination effect of upgradeBeaconCrossChain) and asserts the same (a/b/c) properties
 *         on the live "Poa" org.
 *
 * LIVE ORG (Arbitrum subgraph poa-arb-v-1, org "Poa"):
 *   eligibilityModule     0xe4f9cb9c843d0a5bd5d52e3266138b13a635743b
 *   directDemocracyVoting 0xc82b179f5b4e325ac1b77a423fdb266aebfca5e8
 *   hybridVoting          0x34aa1bd79a3a5eb5d2b208eb4f091ccf6b1081d5
 *   taskManager           0x681f29751724d2bed331d3eb35e0c9b1c57af9f0
 *   participationToken    0x33cd0b9ae54c43c11fd05fe00afd3dbc71d9603e
 *   educationHub          0xe37db8ccd295c9e4febb19a91efe13ace24ca596
 *   quickJoin             0x366c605a3064a680fb5c05bf9eeda512fddbf03a
 *   executor              0xb1ff2bd0231770ccc91801aa1fae4b3226e1fe41
 */
contract SimArbitrum is ModuleWaveSimBase {
    address constant P_EM = 0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b;
    address constant P_DDV = 0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8;
    address constant P_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;
    address constant P_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
    address constant P_PT = 0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E;
    address constant P_EDU = 0xe37Db8cCD295C9E4fEbb19a91efe13aCe24ca596;
    address constant P_QJ = 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a;
    address constant P_EXEC = 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41;

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: W8 module wave on Arbitrum fork (org Poa) ===\n");
        TypeRow[] memory t = ModuleTypeTable.rows();
        address[8] memory proxies = [P_EM, P_DDV, P_HV, P_TM, P_PT, P_EDU, P_QJ, P_EXEC];
        bytes4[8] memory reads = _reads();

        ProxySnapshot[8] memory pre;
        for (uint256 i; i < 8; ++i) {
            pre[i] = _snapshot(proxies[i], reads[i]);
        }

        // roleManager() is a NEW getter absent from the live (old) impl — read only post-upgrade.
        EligibilityModule em = EligibilityModule(P_EM);
        address emSuperPre = em.superAdmin();
        uint256 adminHat = em.eligibilityModuleAdminHat();
        (bool ePre, bool sPre) = em.getWearerStatus(emSuperPre, adminHat);

        address[8] memory newImpls;
        for (uint256 i; i < 8; ++i) {
            newImpls[i] = _deployAndUpgrade(t[i]);
        }

        for (uint256 i; i < 8; ++i) {
            _requireFollowedAndStable(proxies[i], reads[i], pre[i], newImpls[i], t[i].typeName);
        }
        console.log("(a/b/c) all 8 beacons flipped, Poa Mirror proxies followed, reads stable");

        require(em.superAdmin() == emSuperPre, "EM: superAdmin drifted");
        require(em.roleManager() == address(0), "EM: roleManager became non-zero after upgrade");
        (bool ePost, bool sPost) = em.getWearerStatus(emSuperPre, adminHat);
        require(ePost == ePre && sPost == sPre, "EM: getWearerStatus drifted (derived path not inert)");
        console.log("(EM) derived-eligibility path inert-until-configured: getWearerStatus unchanged");

        console.log("\nPASS: W8 module wave validated against live Arbitrum (Poa) state.");
    }

    function _reads() internal pure returns (bytes4[8] memory r) {
        r[0] = EligibilityModule.superAdmin.selector;
        r[1] = DirectDemocracyVoting.executor.selector;
        r[2] = HybridVoting.executor.selector;
        r[3] = bytes4(0xed2f21f5); // TaskManager.MODULE_ID()
        r[4] = ParticipationToken.executor.selector;
        r[5] = EducationHub.executor.selector;
        r[6] = QuickJoin.executor.selector;
        r[7] = bytes4(0x8da5cb5b); // Executor.owner()
    }
}
