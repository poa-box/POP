// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {Executor} from "../../src/Executor.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * Upgrade the Access-v2 DUAL-PATH module beacons — PER-CHAIN, LOCAL (SPEC §4/§6)
 * ============================================================================
 *
 * Registers new impls + upgrades the PoaManager global beacons for the seven dual-path modules
 * changed on this branch (git diff main..HEAD over src/: DirectDemocracyVoting, HybridVoting +
 * its libs, TaskManager, ParticipationToken, EducationHub, QuickJoin, Executor). Runs LOCALLY on
 * each chain (Satellite on Gnosis, Hub on Arbitrum); both owners are Hudson.
 *
 * DUAL-PATH INVARIANT (§4): every module keeps its legacy Hats-based storage and, while
 * `membershipAuthority == address(0)` (Executor: `l.hats` unrepointed), reads the legacy path
 * BYTE-IDENTICALLY. Beacon waves are fleet-instant for Mirror-mode orgs, so the bump MUST be
 * neutral for every unmigrated org. The sims PROVE this: for a live org (Test6 on Gnosis, Poa on
 * Arbitrum) they snapshot each module's legacy read surface (hats / executor / the exact hat arrays
 * the membership check consults) PRE-upgrade, upgrade the beacons, and assert the snapshot is
 * IDENTICAL post-upgrade — then assert every module's new `membershipAuthority()` reads address(0)
 * (which also proves the org is Mirror-mode and now runs the new dual-path impl).
 *
 * Version selection (dual-surface probed FREE on BOTH chains by the orchestrator, waveD-recon.md;
 * re-asserted cheaply in the sims via the registry rather than re-probed):
 *   DirectDemocracyVoting v13 · HybridVoting v13 · TaskManager v8 · ParticipationToken v8 ·
 *   EducationHub v4 (Arb first-free was v3 but v3 is TAKEN on Gnosis → v4 on both) ·
 *   QuickJoin v8 · Executor v5
 *
 * Usage:
 *   # Sims (BOTH under production profile):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:SimGnosis  --fork-url gnosis-gateway -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:SimArbitrum --fork-url arbitrum     -vvv
 *
 *   # Broadcast (per chain: deploy impls, then upgrade beacons):
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:Step1_DeployImplsGnosis   --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:Step2_UpgradeBeaconsGnosis --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:Step1b_DeployImplsArbitrum   --rpc-url arbitrum --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/UpgradeAccessV2Modules.s.sol:Step2b_UpgradeBeaconsArbitrum --rpc-url arbitrum --broadcast --slow
 * ============================================================================
 */

interface IPoaManagerView {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

interface IImplRegistryView {
    function getImplementation(string calldata typeName, string calldata version) external view returns (address);
}

interface IPoaAdmin {
    function owner() external view returns (address);
}

interface ISatelliteAdmin is IPoaAdmin {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

interface IHubAdmin is IPoaAdmin {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
}

/*──────────── Minimal legacy read surfaces (present on OLD + NEW impls) ────────────*/
interface IDDRead {
    function hats() external view returns (address);
    function executor() external view returns (address);
    function votingHats() external view returns (uint256[] memory);
    function creatorHats() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
}

interface IHVRead {
    function hats() external view returns (address);
    function executor() external view returns (address);
    function creatorHats() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
}

interface ITMRead {
    // getLensData(t): 3=hats, 4=executor, 5=creatorHats, 6=permissionHats, 12=membershipAuthority.
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

interface IPTRead {
    function hats() external view returns (address);
    function executor() external view returns (address);
    function memberHatIds() external view returns (uint256[] memory);
    function approverHatIds() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
}

interface IEDURead {
    function hats() external view returns (address);
    function executor() external view returns (address);
    function creatorHatIds() external view returns (uint256[] memory);
    function memberHatIds() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
}

interface IQJRead {
    function hats() external view returns (address);
    function executor() external view returns (address);
    function memberHatIds() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
}

interface IExecRead {
    function hats() external view returns (address);
    function allowedCaller() external view returns (address);
    function membershipAuthority() external view returns (address);
}

abstract contract AccessV2ModuleBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;

    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant ARB_REGISTRY = 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant GNOSIS_REGISTRY = 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63;

    // ── Type names + probed-FREE versions (waveD-recon.md) ──
    string internal constant T_DD = "DirectDemocracyVoting";
    string internal constant T_HV = "HybridVoting";
    string internal constant T_TM = "TaskManager";
    string internal constant T_PT = "ParticipationToken";
    string internal constant T_EDU = "EducationHub";
    string internal constant T_QJ = "QuickJoin";
    string internal constant T_EXEC = "Executor";

    string internal constant V_DD = "v13";
    string internal constant V_HV = "v13";
    string internal constant V_TM = "v8";
    string internal constant V_PT = "v8";
    string internal constant V_EDU = "v4";
    string internal constant V_QJ = "v8";
    string internal constant V_EXEC = "v5";

    struct Impls {
        address dd;
        address hv;
        address tm;
        address pt;
        address edu;
        address qj;
        address exec;
    }

    struct OrgModules {
        address dd;
        address hv;
        address tm;
        address pt;
        address edu;
        address qj;
        address exec;
    }

    /// @dev CREATE3-deploy `code` at the deterministic (typeName,version) address; idempotent.
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

    function _deployImpls() internal returns (Impls memory im) {
        im.dd = _ddDeploy(T_DD, V_DD, type(DirectDemocracyVoting).creationCode);
        im.hv = _ddDeploy(T_HV, V_HV, type(HybridVoting).creationCode);
        im.tm = _ddDeploy(T_TM, V_TM, type(TaskManager).creationCode);
        im.pt = _ddDeploy(T_PT, V_PT, type(ParticipationToken).creationCode);
        im.edu = _ddDeploy(T_EDU, V_EDU, type(EducationHub).creationCode);
        im.qj = _ddDeploy(T_QJ, V_QJ, type(QuickJoin).creationCode);
        im.exec = _ddDeploy(T_EXEC, V_EXEC, type(Executor).creationCode);
        require(im.dd.code.length <= 24576, "DD impl exceeds EIP-170");
        require(im.hv.code.length <= 24576, "HV impl exceeds EIP-170");
        require(im.tm.code.length <= 24576, "TM impl exceeds EIP-170");
        require(im.pt.code.length <= 24576, "PT impl exceeds EIP-170");
        require(im.edu.code.length <= 24576, "EDU impl exceeds EIP-170");
        require(im.qj.code.length <= 24576, "QJ impl exceeds EIP-170");
        require(im.exec.code.length <= 24576, "Executor impl exceeds EIP-170");
    }

    function _versionFree(address registry, string memory typeName, string memory version)
        internal
        view
        returns (bool)
    {
        try IImplRegistryView(registry).getImplementation(typeName, version) returns (address) {
            return false;
        } catch {
            return true;
        }
    }

    /// @dev Cheap re-assertion of the orchestrator's freeness probe (CLAUDE.md point 6).
    function _assertVersionsFree(address registry) internal view {
        require(_versionFree(registry, T_DD, V_DD), "DD v13 already taken");
        require(_versionFree(registry, T_HV, V_HV), "HV v13 already taken");
        require(_versionFree(registry, T_TM, V_TM), "TM v8 already taken");
        require(_versionFree(registry, T_PT, V_PT), "PT v8 already taken");
        require(_versionFree(registry, T_EDU, V_EDU), "EDU v4 already taken");
        require(_versionFree(registry, T_QJ, V_QJ), "QJ v8 already taken");
        require(_versionFree(registry, T_EXEC, V_EXEC), "Executor v5 already taken");
    }

    function _upgradeGnosis(Impls memory im) internal {
        ISatelliteAdmin s = ISatelliteAdmin(GNOSIS_SATELLITE);
        s.upgradeBeaconDirect(T_DD, im.dd, V_DD);
        s.upgradeBeaconDirect(T_HV, im.hv, V_HV);
        s.upgradeBeaconDirect(T_TM, im.tm, V_TM);
        s.upgradeBeaconDirect(T_PT, im.pt, V_PT);
        s.upgradeBeaconDirect(T_EDU, im.edu, V_EDU);
        s.upgradeBeaconDirect(T_QJ, im.qj, V_QJ);
        s.upgradeBeaconDirect(T_EXEC, im.exec, V_EXEC);
    }

    function _upgradeArbitrum(Impls memory im) internal {
        IHubAdmin h = IHubAdmin(ARB_HUB);
        h.upgradeBeaconLocal(T_DD, im.dd, V_DD);
        h.upgradeBeaconLocal(T_HV, im.hv, V_HV);
        h.upgradeBeaconLocal(T_TM, im.tm, V_TM);
        h.upgradeBeaconLocal(T_PT, im.pt, V_PT);
        h.upgradeBeaconLocal(T_EDU, im.edu, V_EDU);
        h.upgradeBeaconLocal(T_QJ, im.qj, V_QJ);
        h.upgradeBeaconLocal(T_EXEC, im.exec, V_EXEC);
    }

    function _assertBeacons(address poaManager, Impls memory im) internal view {
        require(IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_DD))) == im.dd, "DD beacon");
        require(IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_HV))) == im.hv, "HV beacon");
        require(IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_TM))) == im.tm, "TM beacon");
        require(IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_PT))) == im.pt, "PT beacon");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_EDU))) == im.edu, "EDU beacon"
        );
        require(IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_QJ))) == im.qj, "QJ beacon");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(keccak256(bytes(T_EXEC))) == im.exec, "Exec beacon"
        );
    }

    /*──────── Neutrality snapshot: legacy reads only (present on OLD + NEW impls) ────────*/
    // Per-module encoders keep each abi.encode shallow — the 24-field single encode overflows the
    // default-profile stack (osaka, optimizer OFF), so hash a tuple of per-module sub-blobs instead.

    function _snapDD(address a) private view returns (bytes memory) {
        return abi.encode(IDDRead(a).hats(), IDDRead(a).executor(), IDDRead(a).votingHats(), IDDRead(a).creatorHats());
    }

    function _snapHV(address a) private view returns (bytes memory) {
        return abi.encode(IHVRead(a).hats(), IHVRead(a).executor(), IHVRead(a).creatorHats());
    }

    function _snapTM(address a) private view returns (bytes memory) {
        // Raw lens blobs: 3=hats, 4=executor, 5=creatorHats, 6=permissionHats.
        return abi.encode(
            ITMRead(a).getLensData(3, ""),
            ITMRead(a).getLensData(4, ""),
            ITMRead(a).getLensData(5, ""),
            ITMRead(a).getLensData(6, "")
        );
    }

    function _snapPT(address a) private view returns (bytes memory) {
        return
            abi.encode(IPTRead(a).hats(), IPTRead(a).executor(), IPTRead(a).memberHatIds(), IPTRead(a).approverHatIds());
    }

    function _snapEDU(address a) private view returns (bytes memory) {
        return
            abi.encode(
                IEDURead(a).hats(), IEDURead(a).executor(), IEDURead(a).creatorHatIds(), IEDURead(a).memberHatIds()
            );
    }

    function _snapQJ(address a) private view returns (bytes memory) {
        return abi.encode(IQJRead(a).hats(), IQJRead(a).executor(), IQJRead(a).memberHatIds());
    }

    function _snapExec(address a) private view returns (bytes memory) {
        // Executor.hats() returns legacy Hats while unrepointed.
        return abi.encode(IExecRead(a).hats(), IExecRead(a).allowedCaller());
    }

    function _legacySnapshot(OrgModules memory m) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _snapDD(m.dd),
                _snapHV(m.hv),
                _snapTM(m.tm),
                _snapPT(m.pt),
                _snapEDU(m.edu),
                _snapQJ(m.qj),
                _snapExec(m.exec)
            )
        );
    }

    /// @dev POST-upgrade: every module's NEW dual-path pointer reads address(0) for an unmigrated org
    ///      (proves the legacy branch is taken AND — since the getter only exists on the new impl —
    ///      that the org is Mirror-mode and now runs the upgraded code).
    function _assertAuthoritiesZero(OrgModules memory m) internal view {
        require(IDDRead(m.dd).membershipAuthority() == address(0), "DD authority not zero");
        require(IHVRead(m.hv).membershipAuthority() == address(0), "HV authority not zero");
        require(abi.decode(ITMRead(m.tm).getLensData(12, ""), (address)) == address(0), "TM authority not zero");
        require(IPTRead(m.pt).membershipAuthority() == address(0), "PT authority not zero");
        require(IEDURead(m.edu).membershipAuthority() == address(0), "EDU authority not zero");
        require(IQJRead(m.qj).membershipAuthority() == address(0), "QJ authority not zero");
        require(IExecRead(m.exec).membershipAuthority() == address(0), "Exec authority not zero");
    }

    function _runSim(bool gnosis, address poaManager, address registry, OrgModules memory m) internal {
        _assertVersionsFree(registry);
        bytes32 pre = _legacySnapshot(m);
        console.log("  legacy read snapshot (pre-upgrade) captured for live org.");

        vm.startPrank(HUDSON);
        Impls memory im = _deployImpls();
        if (gnosis) _upgradeGnosis(im);
        else _upgradeArbitrum(im);
        vm.stopPrank();

        _assertBeacons(poaManager, im);
        bytes32 post = _legacySnapshot(m);
        require(pre == post, "NEUTRALITY VIOLATED: legacy read surface changed across the beacon upgrade");
        _assertAuthoritiesZero(m);

        console.log("  DD impl: ", im.dd);
        console.log("  HV impl: ", im.hv);
        console.log("  TM impl: ", im.tm);
        console.log("  PT impl: ", im.pt);
        console.log("  EDU impl:", im.edu);
        console.log("  QJ impl: ", im.qj);
        console.log("  Exec impl:", im.exec);
        console.log("  legacy snapshot IDENTICAL pre/post; all module authorities == 0 (dual-path neutral).");
    }
}

/* ════════════════════════════ GNOSIS — broadcast ════════════════════════════ */

contract Step1_DeployImplsGnosis is AccessV2ModuleBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1 (Gnosis): DD-deploy the 7 dual-path module impls ===");
        vm.startBroadcast(key);
        Impls memory im = _deployImpls();
        vm.stopBroadcast();
        console.log("  DD/HV/TM/PT/EDU/QJ/Exec:", im.dd, im.hv, im.tm);
        console.log("  ...", im.pt, im.edu, im.qj);
        console.log("  ...", im.exec);
    }
}

contract Step2_UpgradeBeaconsGnosis is AccessV2ModuleBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(ISatelliteAdmin(GNOSIS_SATELLITE).owner() == vm.addr(key), "signer must own the Satellite");
        Impls memory im = _deployImpls();
        vm.startBroadcast(key);
        _upgradeGnosis(im);
        vm.stopBroadcast();
        _assertBeacons(GNOSIS_POA_MANAGER, im);
        console.log("Gnosis: 7 dual-path module beacons upgraded. PASS.");
    }
}

/* ════════════════════════════ ARBITRUM — broadcast ════════════════════════════ */

contract Step1b_DeployImplsArbitrum is AccessV2ModuleBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1b (Arbitrum): DD-deploy the 7 dual-path module impls ===");
        vm.startBroadcast(key);
        Impls memory im = _deployImpls();
        vm.stopBroadcast();
        console.log("  DD/HV/TM/PT/EDU/QJ/Exec:", im.dd, im.hv, im.tm);
        console.log("  ...", im.pt, im.edu, im.qj);
        console.log("  ...", im.exec);
    }
}

contract Step2b_UpgradeBeaconsArbitrum is AccessV2ModuleBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IHubAdmin(ARB_HUB).owner() == vm.addr(key), "signer must own the Hub");
        Impls memory im = _deployImpls();
        vm.startBroadcast(key);
        _upgradeArbitrum(im);
        vm.stopBroadcast();
        _assertBeacons(ARB_POA_MANAGER, im);
        console.log("Arbitrum: 7 dual-path module beacons upgraded. PASS.");
    }
}

/* ════════════════════════════ SIMS — real forks, prank Hudson ════════════════════════════ */

/// @notice Gnosis fork-sim (Satellite-local). Neutrality proven against the live Test6 org.
contract SimGnosis is AccessV2ModuleBase {
    function run() public {
        console.log("\n=== SIM: dual-path module beacon upgrade (Gnosis fork, Test6 neutrality) ===");
        OrgModules memory m = OrgModules({
            dd: 0xd2667117ED47aD259fEf73F54f31a3eF9A5D889F,
            hv: 0xF642DdE77848dC195c8089F4042A311Ed650d7a6,
            tm: 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc,
            pt: 0x6083c52b2F5861F327526bD646EaA754edDD5cCf,
            edu: 0x6a29222E29FDc0000AbA55329DfF0a50D9a8e8F9,
            qj: 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d,
            exec: 0xA09F1035Ff97d17ccA40048F027c654b66B83183
        });
        _runSim(true, GNOSIS_POA_MANAGER, GNOSIS_REGISTRY, m);
        console.log("PASS: SimGnosis - 7 module beacons upgraded; byte-identical legacy behavior for Test6.");
    }
}

/// @notice Arbitrum fork-sim (Hub-local). Neutrality proven against the live Poa org.
contract SimArbitrum is AccessV2ModuleBase {
    function run() public {
        console.log("\n=== SIM: dual-path module beacon upgrade (Arbitrum fork, Poa neutrality) ===");
        OrgModules memory m = OrgModules({
            dd: 0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8,
            hv: 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5,
            tm: 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0,
            pt: 0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E,
            edu: 0xe37Db8cCD295C9E4fEbb19a91efe13aCe24ca596,
            qj: 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a,
            exec: 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41
        });
        _runSim(false, ARB_POA_MANAGER, ARB_REGISTRY, m);
        console.log("PASS: SimArbitrum - 7 module beacons upgraded; byte-identical legacy behavior for Poa.");
    }
}
