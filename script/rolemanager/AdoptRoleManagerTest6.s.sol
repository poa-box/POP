// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {IRoleManager} from "../../src/interfaces/IRoleManager.sol";

// Module impls — deployed fresh in-sim and pushed onto the protocol beacons so Test6's
// Mirror-mode proxies pick up the RoleManager-feature code (setConfigAdmin / setRoleManager /
// derived eligibility / addHatToClass). NOT used by the broadcast contracts.
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";

/*
 * ============================================================================
 * W9 — Adopt the RoleManager module into the live Test6 org (Gnosis canary)
 * ============================================================================
 *
 * Test6 was deployed long before RoleManager existed, so it has no per-org proxy and
 * its EligibilityModule / voting / task / token / edu / quickjoin modules run the
 * pre-RoleManager code. Retrofitting it takes, per PLAN §2.3 (adoption recipe) and
 * deploy-flow.md §3:
 *
 *   PROTOCOL (once per chain, ops, NOT in this script's broadcasts — see W-protocol
 *   registration + beacon-wave scripts): register the "RoleManager" type on the Gnosis
 *   Satellite (creates the global beacon) and land the Mirror-mode beacon wave upgrading
 *   EM / DD / HV / TM / PT / EduHub / QuickJoin to the RoleManager-feature impls. The SIM
 *   below performs BOTH of those in-fork (pranked as the real Satellite owner) so the
 *   adoption path is exercised end-to-end even though protocol registration is a separate
 *   broadcast.
 *
 *   1. PredeployTest6 (EOA, broadcastable): new SwitchableBeacon(executor, protocolBeacon,
 *      0, Mirror) + new BeaconProxy(sb, "") left UNINITIALIZED. Prints the two addresses.
 *   2. BroadcastAdoptTest6 (governance): ONE HybridVoting proposal whose winning batch, in
 *      order, ① registers the proxy in OrgRegistry (ContractRegistered -> subgraph template),
 *      ② initialize()s it (config events follow registration), ③ EM.setRoleManager(proxy),
 *      ④ setConfigAdmin(proxy) on DD/HV/TM/PT/EduHub/QuickJoin. Nine calls, no Executor
 *      self-target (RoleManager mints hats via the EligibilityModule, not Executor, so no
 *      setHatMinterAuthorization / Executor upgrade is needed — unlike the ZkEmail retrofit).
 *      Includes the C1 pre-flight guard (PLAN §2.3): staticcall the proxy's modules() getter
 *      and abort if it is already initialized (front-run) — redeploy a fresh proxy and re-run.
 *   3. SimAdoptTest6: full Gnosis fork sim — protocol prereqs in-fork, predeploy, create the
 *      adoption proposal as a REAL Test6 creator-hat wearer, vote, warp, announceWinner with an
 *      explicit measured gas limit (asserts didExecute via post-state, NOT proposal validity
 *      alone — CLAUDE.md announceWinner try/catch gotcha), then a second governance proposal
 *      that smoke-tests RoleManager.createRole("Canary").
 *
 * Usage (sim — run under production profile, the profile broadcast uses):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/AdoptRoleManagerTest6.s.sol:SimAdoptTest6 --fork-url gnosis -vvv
 *
 * Broadcast (after the protocol registration + beacon wave land on Gnosis):
 *   # step 1 (Hudson EOA):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/AdoptRoleManagerTest6.s.sol:PredeployTest6 --rpc-url gnosis --broadcast
 *   # step 2 (a Test6 creator-hat holder), passing the predeploy addresses:
 *   RM_PROXY=0x... RM_BEACON=0x... FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/AdoptRoleManagerTest6.s.sol:BroadcastAdoptTest6 --rpc-url gnosis --broadcast
 *   # then a creator-hat holder finalizes with an explicit gas limit (see measured sim value):
 *   cast send <HV> 'announceWinner(uint256)' <id> --gas-limit 3000000
 * ============================================================================
 */

/* ─────────────────────── Minimal interfaces ─────────────────────── */
interface ISatellite {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function addContractType(string calldata typeName, address impl) external;
    function owner() external view returns (address);
}

interface IPoaManagerView {
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IOrgRegistry {
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external;
    function getOrgContract(bytes32 orgId, bytes32 typeId) external view returns (address proxy);
    function getRoleHat(bytes32 orgId, uint256 roleIndex) external view returns (uint256);
}

interface IRoleManagerModules {
    // C1 guard + post-assert: an uninitialized proxy returns all-zero; an initialized one returns
    // the real wired addresses (initialize requires cfg.hats != 0, so hats_ != 0 == initialized).
    function modules() external view returns (address, address, address, address, address, address, address, address);
}

interface IEMAdmin {
    function setRoleManager(address rm) external;
    function roleManager() external view returns (address);
    function superAdmin() external view returns (address);
}

interface IConfigAdminSetter {
    function setConfigAdmin(address admin) external;
}

interface IQuickJoinCfg {
    function updateMemberHatIds(uint256[] calldata memberHatIds_) external;
    function memberHatIds() external view returns (uint256[] memory);
}

interface IPTCfg {
    function setMemberHatAllowed(uint256 h, bool ok) external;
}

interface IEduCfg {
    function setCreatorHatAllowed(uint256 h, bool ok) external;
}

interface ITMCfg {
    // setConfig(ConfigKey,bytes) — enums ABI-encode as uint8, so this shares the selector.
    function setConfig(uint8 key, bytes calldata value) external;
}

interface IHatsView {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
    function getHatMaxSupply(uint256 hatId) external view returns (uint32);
}

/* ───────────────────────── Shared base ───────────────────────── */
abstract contract Test6RMBase is Script {
    /* Protocol / chain singletons (Gnosis) — verified on-chain 2026-08-13 */
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address internal constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    /* Test6 org + per-org module proxies (subgraph poa-gnosis, verified on-chain 2026-08-13) */
    bytes32 internal constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
    address internal constant TEST6_DD = 0xd2667117ED47aD259fEf73F54f31a3eF9A5D889F;
    address internal constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
    address internal constant TEST6_PT = 0x6083c52b2F5861F327526bD646EaA754edDD5cCf;
    address internal constant TEST6_EDU = 0x6a29222E29FDc0000AbA55329DfF0a50D9a8e8F9;
    address internal constant TEST6_QJ = 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d;
    address internal constant TEST6_EM = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;

    // A REAL Test6 wearer of the entry (member) role hat — hat0 is BOTH a HybridVoting creator hat
    // and a DIRECT class-0 voting hat, so this single address can create AND carry a passing vote
    // (quorum=1 voter, threshold=25%, class-0 slice=80%). Verified wearer on-chain 2026-08-13.
    address internal constant TEST6_CREATOR = 0x181222dDFb8e059D50B3b225002746057f6C3F37;

    bytes32 internal constant ROLE_MANAGER_ID = keccak256("RoleManager");
    uint32 internal constant VOTE_MINUTES = 30;

    /// @dev Enumerate Test6's genesis role hats from OrgRegistry (getRoleHat probing, 0-indexed until
    ///      the first unset slot). These seed RoleManager.orgHats[] (the isInOrg membership set).
    function _existingRoleHats() internal view returns (uint256[] memory hats, string[] memory names) {
        uint256 n;
        while (IOrgRegistry(ORG_REGISTRY).getRoleHat(TEST6_ORG, n) != 0) {
            unchecked {
                ++n;
            }
        }
        hats = new uint256[](n);
        names = new string[](n);
        for (uint256 i; i < n; ++i) {
            hats[i] = IOrgRegistry(ORG_REGISTRY).getRoleHat(TEST6_ORG, i);
            names[i] = string.concat("Genesis Role #", vm.toString(i));
        }
    }

    /// @dev The frozen RoleManager.initialize config for Test6.
    function _initConfig() internal view returns (IRoleManager.InitConfig memory cfg) {
        (uint256[] memory hats, string[] memory names) = _existingRoleHats();
        cfg = IRoleManager.InitConfig({
            executor: TEST6_EXECUTOR,
            eligibilityModule: TEST6_EM,
            hats: HATS,
            ddVoting: TEST6_DD,
            hybridVoting: TEST6_HV,
            taskManager: TEST6_TM,
            participationToken: TEST6_PT,
            educationHub: TEST6_EDU,
            quickJoin: TEST6_QJ,
            paymasterHub: GNOSIS_PAYMASTER,
            orgId: TEST6_ORG,
            existingOrgHats: hats,
            existingOrgHatNames: names
        });
    }

    /// @dev The 9-call adoption governance batch (deploy-flow §3 / PLAN §2.3 ordering).
    function _adoptionBatch(address proxy, address beacon) internal view returns (IExecutor.Call[] memory batch) {
        batch = new IExecutor.Call[](9);
        // ① register the proxy (ContractRegistered -> subgraph per-org template)
        batch[0] = IExecutor.Call({
            target: ORG_REGISTRY,
            value: 0,
            data: abi.encodeWithSignature(
                "registerOrgContract(bytes32,bytes32,address,address,bool,address,bool)",
                TEST6_ORG,
                ROLE_MANAGER_ID,
                proxy,
                beacon,
                true,
                TEST6_EXECUTOR,
                false
            )
        });
        // ② initialize (config events follow ContractRegistered)
        batch[1] =
            IExecutor.Call({target: proxy, value: 0, data: abi.encodeCall(RoleManager.initialize, (_initConfig()))});
        // ③ authorize the scoped RoleManager on the EligibilityModule
        batch[2] = IExecutor.Call({target: TEST6_EM, value: 0, data: abi.encodeCall(IEMAdmin.setRoleManager, (proxy))});
        // ④ configAdmin(proxy) on the six sibling modules
        batch[3] = IExecutor.Call({
            target: TEST6_DD, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
        batch[4] = IExecutor.Call({
            target: TEST6_HV, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
        batch[5] = IExecutor.Call({
            target: TEST6_TM, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
        batch[6] = IExecutor.Call({
            target: TEST6_PT, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
        batch[7] = IExecutor.Call({
            target: TEST6_EDU, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
        batch[8] = IExecutor.Call({
            target: TEST6_QJ, value: 0, data: abi.encodeCall(IConfigAdminSetter.setConfigAdmin, (proxy))
        });
    }

    /// @dev C1 pre-flight (PLAN §2.3): the pre-deployed proxy must still be UNINITIALIZED right before
    ///      the adoption vote lands. An uninitialized RoleManager returns all-zero from modules(); an
    ///      initialize-front-run one returns the wired hats address. If front-run, redeploy + re-run.
    function _requireUninitialized(address proxy) internal view {
        (,,,,,,, address hats_) = IRoleManagerModules(proxy).modules();
        require(
            hats_ == address(0),
            "C1: RoleManager proxy already initialized (front-run) - redeploy a fresh proxy and rebuild the proposal"
        );
    }
}

/* ════════════════════════════ 1. PREDEPLOY (EOA) ════════════════════════════ */

/// @notice Step 1 (Hudson EOA): deploy Test6's RoleManager SwitchableBeacon (Mirror) + an
///         UNINITIALIZED BeaconProxy. The governance vote (step 2) registers then initializes it.
contract PredeployTest6 is Test6RMBase {
    function run() public {
        address protocolBeacon = IPoaManagerView(GNOSIS_POA_MANAGER).getBeaconById(ROLE_MANAGER_ID);
        require(
            protocolBeacon != address(0), "RoleManager type not registered on Gnosis - run protocol registration first"
        );

        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vm.startBroadcast(key);
        SwitchableBeacon sb =
            new SwitchableBeacon(TEST6_EXECUTOR, protocolBeacon, address(0), SwitchableBeacon.Mode.Mirror);
        BeaconProxy proxy = new BeaconProxy(address(sb), "");
        vm.stopBroadcast();

        console.log("Test6 RoleManager SwitchableBeacon (Mirror):", address(sb));
        console.log("Test6 RoleManager BeaconProxy (UNINITIALIZED):", address(proxy));
        console.log("NEXT: BroadcastAdoptTest6 with RM_PROXY=%s RM_BEACON=%s", address(proxy), address(sb));
    }
}

/* ════════════════════════════ 2. GOVERNANCE (creator hat) ════════════════════════════ */

/// @notice Step 2 (a Test6 creator-hat wearer): create the single adoption proposal.
contract BroadcastAdoptTest6 is Test6RMBase {
    function run() public {
        address proxy = vm.envAddress("RM_PROXY");
        address beacon = vm.envAddress("RM_BEACON");

        // C1 guard: abort before spending a proposal if the proxy was initialize-front-run.
        _requireUninitialized(proxy);

        IExecutor.Call[] memory batch = _adoptionBatch(proxy, beacon);
        require(batch.length <= 20, "batch exceeds Executor MAX_CALLS_PER_BATCH");
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 idBefore = HybridVoting(TEST6_HV).proposalsCount();
        vm.startBroadcast(key);
        HybridVoting(TEST6_HV)
            .createProposal(
                bytes("Adopt RoleManager module"),
                bytes32(0),
                uint32(vm.envOr("VOTE_MINUTES", uint256(VOTE_MINUTES))),
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        require(HybridVoting(TEST6_HV).proposalsCount() == idBefore + 1, "proposal not created");
        console.log("Adoption proposal #%s created on Test6 HybridVoting.", idBefore);
        console.log(
            "Members vote; finalize with: cast send %s 'announceWinner(uint256)' %s --gas-limit 3000000",
            TEST6_HV,
            idBefore
        );
    }
}

/* ════════════════════════════ 3. SIMULATION ════════════════════════════ */

contract SimAdoptTest6 is Test6RMBase {
    // sim-only unique version tag for the in-fork beacon wave
    string internal constant SIM_VER = "v-rm-w9-sim";

    function run() public {
        console.log("\n=== SIM: Adopt RoleManager into Test6 (Gnosis fork) ===");
        require(ISatellite(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");
        require(IEMAdmin(TEST6_EM).superAdmin() == TEST6_EXECUTOR, "EM superAdmin != Test6 executor");

        address protocolBeacon = _protocolPrereqs();
        (address proxy, address beacon) = _predeploy(protocolBeacon);

        // C1 guard on the fresh proxy.
        _requireUninitialized(proxy);
        console.log("[C1] Pre-flight: proxy is uninitialized (modules().hats == 0).");

        // ── Adoption proposal (create + vote + warp + announceWinner) ──
        IExecutor.Call[] memory batch = _adoptionBatch(proxy, beacon);
        require(batch.length <= 20, "batch > 20 calls");
        (uint256 id, uint256 gasUsed, bool valid) = _createVoteAnnounce(_wrap(batch), "Adopt RoleManager module");
        require(valid, "adoption proposal did not pass");
        console.log("[gov] Adoption proposal #%s finalized. announceWinner gas used:", id);
        console.log("       ", gasUsed);

        // ── Post-assert: didExecute via POST-STATE (not proposal validity — announceWinner try/catch) ──
        require(
            IOrgRegistry(ORG_REGISTRY).getOrgContract(TEST6_ORG, ROLE_MANAGER_ID) == proxy, "RegisteredContract missing"
        );
        _assertModulesMatch(proxy);
        require(IEMAdmin(TEST6_EM).roleManager() == proxy, "EM.roleManager != proxy");
        require(HybridVoting(TEST6_HV).configAdmin() == proxy, "HV.configAdmin != proxy");
        require(DirectDemocracyVoting(TEST6_DD).configAdmin() == proxy, "DD.configAdmin != proxy");
        _assertConfigAdminFunctional(proxy);
        console.log("[post] RegisteredContract present; modules() matches; EM.roleManager + 6 configAdmins == proxy.");

        // ── Smoke: create a "Canary" role via a second governance proposal ──
        _smokeCreateRole(proxy);

        console.log("\nPASS: RoleManager adopted into Test6 end-to-end on Gnosis fork.");
    }

    /* ---- protocol prerequisites (in-fork, pranked as the real Satellite owner) ---- */
    function _protocolPrereqs() internal returns (address protocolBeacon) {
        // (a) Register the RoleManager type (creates the global beacon + registers v1).
        address rmImpl = address(new RoleManager());
        vm.prank(HUDSON);
        try ISatellite(GNOSIS_SATELLITE).addContractType("RoleManager", rmImpl) {}
            catch { /* already registered on a prior run/chain state */ }
        protocolBeacon = IPoaManagerView(GNOSIS_POA_MANAGER).getBeaconById(ROLE_MANAGER_ID);
        require(protocolBeacon != address(0), "RoleManager beacon not created");
        console.log("[proto] RoleManager type registered; protocol beacon:", protocolBeacon);

        // (b) Mirror-mode beacon wave: push RoleManager-feature impls onto the protocol beacons so
        //     Test6's Mirror proxies (verified mode==0) inherit setConfigAdmin / setRoleManager /
        //     derived eligibility / addHatToClass.
        _upgrade("EligibilityModule", address(new EligibilityModule()));
        _upgrade("DirectDemocracyVoting", address(new DirectDemocracyVoting()));
        _upgrade("HybridVoting", address(new HybridVoting()));
        _upgrade("TaskManager", address(new TaskManager()));
        _upgrade("ParticipationToken", address(new ParticipationToken()));
        _upgrade("EducationHub", address(new EducationHub()));
        _upgrade("QuickJoin", address(new QuickJoin()));

        // Propagation check: the new EM code exposes roleManager() (reverts on the old impl).
        require(IEMAdmin(TEST6_EM).roleManager() == address(0), "beacon wave did not reach Test6 EM (Static?)");
        console.log("[proto] Beacon wave landed on all 7 Test6 modules (Mirror).");
    }

    function _upgrade(string memory typeName, address impl) internal {
        vm.prank(HUDSON);
        try ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, impl, SIM_VER) {}
        catch {
            // version already used on this fork state — pin a fresh one
            vm.prank(HUDSON);
            ISatellite(GNOSIS_SATELLITE)
                .upgradeBeaconDirect(typeName, impl, string.concat(SIM_VER, "-", vm.toString(impl)));
        }
    }

    function _predeploy(address protocolBeacon) internal returns (address proxy, address beacon) {
        SwitchableBeacon sb =
            new SwitchableBeacon(TEST6_EXECUTOR, protocolBeacon, address(0), SwitchableBeacon.Mode.Mirror);
        beacon = address(sb);
        proxy = address(new BeaconProxy(beacon, ""));
        console.log("[pre] Predeployed SwitchableBeacon:", beacon);
        console.log("[pre] Predeployed uninitialized proxy:", proxy);
    }

    function _wrap(IExecutor.Call[] memory batch) internal pure returns (IExecutor.Call[][] memory batches) {
        batches = new IExecutor.Call[][](1);
        batches[0] = batch;
    }

    /// @dev Drive the REAL HybridVoting path: a creator-hat wearer creates a 1-option executable
    ///      proposal, votes it through (DIRECT class-0), we warp past close and announceWinner with an
    ///      explicit gas stipend (measured). Returns (id, gasUsed, valid).
    function _createVoteAnnounce(IExecutor.Call[][] memory batches, bytes memory title)
        internal
        returns (uint256 id, uint256 gasUsed, bool valid)
    {
        id = HybridVoting(TEST6_HV).proposalsCount();
        vm.prank(TEST6_CREATOR);
        HybridVoting(TEST6_HV).createProposal(title, bytes32(0), VOTE_MINUTES, 1, batches, new uint256[](0));

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(TEST6_CREATOR);
        HybridVoting(TEST6_HV).vote(id, idxs, weights);

        vm.warp(vm.getBlockTimestamp() + uint256(VOTE_MINUTES) * 60 + 60);

        // Explicit gas stipend mirrors the broadcast --gas-limit; measure real consumption so ops can
        // size the live call (CLAUDE.md: announceWinner try/catch under-funds via eth_estimateGas).
        uint256 g0 = gasleft();
        (, valid) = HybridVoting(TEST6_HV).announceWinner{gas: 8_000_000}(id);
        gasUsed = g0 - gasleft();
    }

    function _assertModulesMatch(address proxy) internal view {
        (address dd, address hv, address tm, address pt, address edu, address qj, address pm, address hats_) =
            IRoleManagerModules(proxy).modules();
        require(dd == TEST6_DD, "modules.dd");
        require(hv == TEST6_HV, "modules.hv");
        require(tm == TEST6_TM, "modules.tm");
        require(pt == TEST6_PT, "modules.pt");
        require(edu == TEST6_EDU, "modules.edu");
        require(qj == TEST6_QJ, "modules.qj");
        require(pm == GNOSIS_PAYMASTER, "modules.paymaster");
        require(hats_ == HATS, "modules.hats");
    }

    /// @dev TM/PT/EduHub/QuickJoin expose no configAdmin() getter — prove the wire functionally by
    ///      calling a configAdmin-gated setter AS the proxy (reverts if configAdmin != proxy). Values
    ///      are benign/idempotent. HV+DD are already asserted via their getters in run().
    function _assertConfigAdminFunctional(address proxy) internal {
        uint256 probeHat = IOrgRegistry(ORG_REGISTRY).getRoleHat(TEST6_ORG, 0);

        // Fetch args BEFORE prank — an inline read-call would otherwise consume the single-shot prank.
        uint256[] memory currentQjHats = IQuickJoinCfg(TEST6_QJ).memberHatIds();
        vm.prank(proxy);
        IQuickJoinCfg(TEST6_QJ).updateMemberHatIds(currentQjHats); // re-set to current (idempotent)

        vm.prank(proxy);
        IPTCfg(TEST6_PT).setMemberHatAllowed(probeHat, true);

        vm.prank(proxy);
        IEduCfg(TEST6_EDU).setCreatorHatAllowed(probeHat, false);

        vm.prank(proxy);
        ITMCfg(TEST6_TM)
            .setConfig(
                2,
                /* ROLE_PERM */
                abi.encode(probeHat, uint8(0))
            );
    }

    /// @dev Second governance proposal: RoleManager.createRole("Canary"). Proves EM.roleManager wiring
    ///      (createHatWithEligibility) and the configAdmin fan-out onto DD/HV/TM/PT/EduHub as the proxy.
    function _smokeCreateRole(address proxy) internal {
        uint256 roleCountBefore = RoleManager(proxy).roleCount();

        IRoleManager.RoleWiring memory w;
        w.setTaskPerm = true; // exercise TM.setConfig(ROLE_PERM) via the configAdmin path
        w.taskPermMask = 1; // CREATE
        // everything else default (false / empty / 0) — no vouch, no autoMint, no paymaster budget

        IRoleManager.RoleParams memory p = IRoleManager.RoleParams({
            name: "Canary",
            metadataCID: bytes32(0),
            imageURI: "",
            maxSupply: 10,
            mutableHat: true,
            groupIds: new uint256[](0),
            wiring: w,
            initialGrants: new address[](0)
        });

        IExecutor.Call[] memory batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({target: proxy, value: 0, data: abi.encodeCall(RoleManager.createRole, (p))});

        (uint256 id,, bool valid) = _createVoteAnnounce(_wrap(batch), "Smoke: create Canary role");
        require(valid, "createRole proposal did not pass");

        uint256 newRoleId = RoleManager(proxy).roleCount();
        require(newRoleId == roleCountBefore + 1, "roleCount did not increment (createRole no-op'd)");
        IRoleManager.RoleInfo memory r = RoleManager(proxy).getRole(newRoleId);
        require(r.exists && r.hatId != 0, "Canary role not stored");
        require(keccak256(bytes(r.name)) == keccak256(bytes("Canary")), "Canary role name mismatch");
        require(IHatsView(HATS).getHatMaxSupply(r.hatId) == 10, "Canary hat not created in Hats");
        require(RoleManager(proxy).roleIdOfHat(r.hatId) == newRoleId, "reverse index missing");
        console.log("[smoke] createRole('Canary') proposal #%s executed -> roleId %s hatId:", id, newRoleId);
        console.log("        ", r.hatId);
    }
}
