// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {Executor, IExecutor} from "../../src/Executor.sol";
import {VotingErrors} from "../../src/libs/VotingErrors.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
// Fresh-org sub-sim stack (mirrors WS-A UpgradeTokenExecutorDeployerSecurity.s.sol):
import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {HatsTreeSetup} from "../../src/HatsTreeSetup.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {UniversalAccountRegistry} from "../../src/UniversalAccountRegistry.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*
 * ============================================================================
 * Governance security remediation upgrade — HybridVoting + DirectDemocracyVoting
 * + governance factory redeploy (WS-B: audit M-14, H-05(partial), H-06, L-02..L-05)
 * ============================================================================
 *
 * SRC FIXES SHIPPED (all ride the HybridVoting / DirectDemocracyVoting beacon impls,
 * plus the redeployed GovernanceFactory bytecode):
 *   M-14 — MAX_POLL_HATS = 100 cap enforced in BOTH _initProposal paths
 *          (DirectDemocracyVoting._initProposal + HybridVotingProposals._initProposal).
 *          vote() ABI unchanged; the cap only bounds the existing linear pollHatIds scan.
 *   H-05 (issue #140, partial) — the `executed` flag is now only latched true AFTER a
 *          successful executor call. A transiently-reverting batch leaves the proposal
 *          retryable instead of permanently bricked. DDV uses `nonReentrant` + set-after;
 *          HybridVotingCore (facade has no nonReentrant) sets executed as an in-flight lock
 *          then RESETS it to false in the catch branch. Event shapes unchanged.
 *   H-06 (comment-only) — prominent flash-loan / soulbound-asset invariant warning in
 *          HybridVotingCore's ERC20_BAL branch AND GovernanceFactory._updateClassesWithTokenAndHats.
 *   L-02 — TargetSelf guard: a winning/queued batch may never target the voting contract
 *          itself (both voting contracts, at creation AND execution time).
 *   L-03 — HybridVotingCore replaces the "Class raw overflow" require-string with
 *          VotingErrors.Overflow().
 *   L-04 — HybridVoting.MIN_DURATION reconciled 1 -> 10 to match the enforced library floor
 *          (HybridVotingProposals.MIN_DURATION). Doc table updated.
 *   L-05 — HybridVoting/DirectDemocracyVoting expose proposalEndTimestamp(id); the two lenses
 *          now back isProposalActive / getProposalEndTimestamp against it (were dead getters).
 *   (M-09 RoleResolver — WS-A src; rides the redeployed GovernanceFactory bytecode at link time.)
 *
 * STORAGE: the three HybridVoting libs share slot keccak256("poa.hybridvoting.v2.storage").
 * The Layout struct is defined ONCE in HybridVoting.sol and imported by all three libs — no
 * lib redefines it, so byte-identical field order is structural. This upgrade adds NO storage
 * fields (MAX_POLL_HATS / MIN_DURATION are compile-time constants). Storage survival on live
 * KUBI (Gnosis) / Poa (Arbitrum) voting proxies is asserted in the sims below.
 *
 * ── VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer is CREATE3 → a given (type, version) is the SAME address on both chains.
 *
 *   HybridVoting:          getVersionCount=6 on both chains; v7-v10 TAKEN (registry+create2),
 *     v11 gnosis:   registry=no create2=no → FREE
 *     v11 arbitrum: registry=no create2=no → FREE   ⇒ pick v11 (0x51A786160118961bdcEf033BaA7246Fb3512A780)
 *   DirectDemocracyVoting: getVersionCount=6 on both chains; v7-v10 TAKEN (registry+create2),
 *     v11 gnosis:   registry=no create2=no → FREE
 *     v11 arbitrum: registry=no create2=no → FREE   ⇒ pick v11 (0xc2346158449138B8474f09692af4aCb88c2383F9)
 *
 * ── FACTORY RE-POINT MECHANISM (investigated per WS-B brief) ──
 *   The 3 factories (GovernanceFactory / AccessFactory / ModulesFactory) are PLAIN contracts
 *   (`new GovernanceFactory()` in DeployInfrastructure.s.sol) — NOT beacon proxies, NOT
 *   registered in the ImplementationRegistry. The live OrgDeployer proxy stores their addresses
 *   in its ERC-7201 Layout, set ONCE at initialize() (OrgDeployer.sol:196-198). There is NO
 *   factory setter, and the addresses double as the msg.sender authorization allowlist for the
 *   factory→OrgDeployer registration callbacks (OrgDeployer.sol:750-751,781-782). Therefore the
 *   live OrgDeployer proxy CANNOT be re-pointed at fresh factories in place.
 *
 *   The established mechanism to run current-src factories with the current-src OrgDeployer v16
 *   is to stand up a FRESH, self-consistent stack: fresh GovernanceFactory + AccessFactory +
 *   ModulesFactory + a fresh OrgDeployer proxy on the OrgDeployer beacon (which MUST be running
 *   v16 — the current-src ModulesFactory's deployModules selector 0x7ae2c574 does not match the
 *   stale live OrgDeployer impl 0x606D…7BF2, so a fresh proxy on the un-flipped beacon reverts
 *   "unrecognized function selector"). Re-using the ABI-stable live singletons (PoaManager, Hats,
 *   PaymasterHub). The sim's _bootstrapFreshStack flips the ParticipationToken (v5) + Executor (v4)
 *   + OrgDeployer (v16) beacons on the fork FIRST (reproducing WS-A's live precondition — v16's
 *   step-8 wiring calls Executor.configureParticipationToken (v4) → PT.setTaskManager (v5), so all
 *   three must be live together), then deploys the fresh proxy — this is what
 *   WS-A's SimGnosis proved, and what _assertFreshOrg below re-proves with the voting beacons
 *   ALSO upgraded. Migrating EXISTING infra to the new
 *   factories additionally requires transferring OrgRegistry ownership (currently owned by the
 *   live OrgDeployer proxy 0x1Ad5…5d1c, no relinquish path) to the fresh proxy and re-running
 *   PaymasterHub.setOrgRegistrar / setOrgDeployConfig — that infra cut-over is an OrgDeployer
 *   (WS-A) concern and is called out as an OPEN CONCERN in the run report, not performed here.
 *   Existing orgs are unaffected: they never call OrgDeployer post-deploy.
 *
 * ── BROADCAST ORDER (do NOT run in this workstream) ──
 *   Depends on WS-A's beacon flips (ParticipationToken v5 / Executor v4 / OrgDeployer v16) being
 *   live FIRST, because the fresh-org path exercises v16 + current-src factories together.
 *
 *   1. Step1_DeployOnGnosis   --rpc-url gnosis   --broadcast --slow   (DD-deploy HV+DDV v11 impls)
 *   2. Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow (DD-deploy on Arbitrum +
 *        Hub.upgradeBeaconCrossChain HV+DDV → Arbitrum local + Gnosis cross-chain dispatch)
 *   3. Step2b_UpgradeGnosis   --rpc-url gnosis   --broadcast --slow   (Satellite.upgradeBeaconDirect
 *        HV+DDV — the destination-chain path, skips the ~5-min Hyperlane wait)
 *   4. Step3_Verify           --rpc-url gnosis / --rpc-url arbitrum   (read-only PASS check)
 *   (Factory redeploy + OrgDeployer proxy cut-over: separate, gated on WS-A OrgDeployer setter —
 *    see FACTORY RE-POINT MECHANISM above.)
 *
 * ── SIMS (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeGovernanceSecurity.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeGovernanceSecurity.s.sol:SimArbitrum --fork-url arbitrum -vvv
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

string constant HV_VERSION = "v11";
string constant DDV_VERSION = "v11";
// WS-A's beacon versions. The fresh-org sub-sim (c) exercises the current-src OrgDeployer v16 +
// current-src factories together, and v16's step-8 wiring calls Executor.configureParticipationToken
// (Executor v4) which in turn drives ParticipationToken.setTaskManager (PT v5). All three beacons
// must therefore be flipped before deployFullOrg. In a real broadcast WS-A flips them FIRST (see
// BROADCAST ORDER); the sim reproduces that precondition on the fork.
string constant DEPLOYER_VERSION = "v16";
string constant EXECUTOR_VERSION = "v4";
string constant TOKEN_VERSION = "v5";

/// @dev Satellite.upgradeBeaconDirect forwards to PoaManager.upgradeBeacon (onlyOwner=Satellite)
///      with the Satellite as msg.sender — the destination-chain emergency upgrade. adminCall is
///      NOT usable (it re-enters PoaManager as msg.sender==PoaManager, failing onlyOwner).
interface ISatellite {
    function owner() external view returns (address);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                 BROADCAST STEPS
═══════════════════════════════════════════════════════════════════════════*/

/// @title Step1_DeployOnGnosis — deploy the two v11 impls on Gnosis via DD (idempotent).
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 1: Deploy governance-fix impls on Gnosis ===");
        vm.startBroadcast(key);
        _deploy(dd, "HybridVoting", HV_VERSION, type(HybridVoting).creationCode);
        _deploy(dd, "DirectDemocracyVoting", DDV_VERSION, type(DirectDemocracyVoting).creationCode);
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
        require(deployed == predicted, "Step1: DD address mismatch");
        console.log("  deployed at:", deployed);
    }
}

/// @title Step2_UpgradeFromArbitrum — DD-deploy on Arbitrum + upgrade both beacons Arbitrum-local
///        AND cross-chain-dispatch to Gnosis via the Hub.
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        require(hub.owner() == vm.addr(key), "Step2: signer must own Hub");
        console.log("\n=== Step 2: Upgrade from Arbitrum (local + cross-chain to Gnosis) ===");
        vm.startBroadcast(key);
        _upgrade(hub, dd, "HybridVoting", HV_VERSION, type(HybridVoting).creationCode);
        _upgrade(hub, dd, "DirectDemocracyVoting", DDV_VERSION, type(DirectDemocracyVoting).creationCode);
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

/// @title Step2b_UpgradeGnosis — upgrade the two Gnosis beacons directly (no Hyperlane wait).
///        Requires Step1 impls already deployed on Gnosis.
contract Step2b_UpgradeGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 2b: Upgrade Gnosis beacons via Satellite.upgradeBeaconDirect ===");
        vm.startBroadcast(key);
        _upgrade(dd, "HybridVoting", HV_VERSION);
        _upgrade(dd, "DirectDemocracyVoting", DDV_VERSION);
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

/// @title Step3_Verify — confirm both beacons point at the new impls on the given chain.
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        // Resolve the PoaManager for whichever chain this is forked/run against.
        address poaManager;
        try PoaManagerHub(payable(HUB)).poaManager() returns (PoaManager pm) {
            poaManager = address(pm); // Arbitrum
        } catch {
            poaManager = GNOSIS_POA_MANAGER; // Gnosis
        }
        console.log("\n=== Step 3: Verify governance beacons ===");
        _verify(dd, poaManager, "HybridVoting", HV_VERSION);
        _verify(dd, poaManager, "DirectDemocracyVoting", DDV_VERSION);
    }

    function _verify(DeterministicDeployer dd, address poaManager, string memory typeName, string memory version)
        internal
        view
    {
        address expected = dd.computeAddress(dd.computeSalt(typeName, version));
        address current = PoaManager(poaManager).getCurrentImplementationById(keccak256(bytes(typeName)));
        console.log(typeName, current == expected ? "PASS" : "WAITING", current);
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                             SHARED SIM SCAFFOLDING
═══════════════════════════════════════════════════════════════════════════*/

/// @dev Snapshot of a live voting proxy's readable state, captured pre-upgrade and re-checked post.
struct VotingSnapshot {
    uint256 proposalCount;
    uint8 thresholdPct;
    uint32 quorum;
    uint256 creatorHatCount;
    bytes32 creatorHatsHash;
}

/// @dev Minimal Hats mock: the sim mints a creator hat to a chosen wearer.
contract SimMockHats {
    mapping(uint256 => mapping(address => bool)) public wears;

    function mint(uint256 hat, address who) external {
        wears[hat][who] = true;
    }

    function isWearerOfHat(address user, uint256 hat) external view returns (bool) {
        return wears[hat][user];
    }
}

/// @dev Executor mock that actually forwards batch calls so a target revert propagates (H-05).
contract SimForwardingExecutor is IExecutor {
    function execute(uint256, Call[] calldata batch) external override {
        for (uint256 i; i < batch.length; ++i) {
            (bool ok,) = batch[i].target.call{value: batch[i].value}(batch[i].data);
            require(ok, "SimForwardingExecutor: call failed");
        }
    }
}

/// @dev Toggleable execution target: reverts while `shouldRevert` is set (H-05 retry).
contract SimMutableTarget {
    bool public shouldRevert = true;
    uint256 public pokeCount;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function poke() external {
        if (shouldRevert) revert("SimMutableTarget: deliberate revert");
        pokeCount++;
    }
}

abstract contract GovernanceUpgradeSimBase is Script {
    function _poaManager() internal pure virtual returns (address);
    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal virtual;

    /*──────── beacon upgrades ────────*/
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

    function _upgradeVotingBeacons() internal returns (address hvImpl, address ddvImpl) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        hvImpl = _deployAndUpgrade(dd, "HybridVoting", HV_VERSION, type(HybridVoting).creationCode);
        ddvImpl = _deployAndUpgrade(dd, "DirectDemocracyVoting", DDV_VERSION, type(DirectDemocracyVoting).creationCode);
    }

    /*──────── storage survival ────────*/
    function _snapshotHV(address proxy) internal view returns (VotingSnapshot memory s) {
        HybridVoting v = HybridVoting(proxy);
        s.proposalCount = v.proposalsCount();
        s.thresholdPct = v.thresholdPct();
        s.quorum = v.quorum();
        uint256[] memory ch = v.creatorHats();
        s.creatorHatCount = ch.length;
        s.creatorHatsHash = keccak256(abi.encode(ch));
    }

    function _snapshotDDV(address proxy) internal view returns (VotingSnapshot memory s) {
        DirectDemocracyVoting v = DirectDemocracyVoting(proxy);
        s.proposalCount = v.proposalsCount();
        s.thresholdPct = v.thresholdPct();
        s.quorum = v.quorum();
        uint256[] memory ch = v.creatorHats();
        s.creatorHatCount = ch.length;
        s.creatorHatsHash = keccak256(abi.encode(ch));
    }

    function _requireSurvived(VotingSnapshot memory pre, VotingSnapshot memory post, string memory tag) internal pure {
        require(pre.proposalCount == post.proposalCount, string.concat(tag, ": proposalCount drifted"));
        require(pre.thresholdPct == post.thresholdPct, string.concat(tag, ": thresholdPct drifted"));
        require(pre.quorum == post.quorum, string.concat(tag, ": quorum drifted"));
        require(pre.creatorHatCount == post.creatorHatCount, string.concat(tag, ": creatorHatCount drifted"));
        require(pre.creatorHatsHash == post.creatorHatsHash, string.concat(tag, ": creator hat array drifted"));
    }

    /*──────── behavior: standalone HybridVoting against the upgraded beacon ────────*/
    /// @dev Deploys a fresh HybridVoting proxy on the just-upgraded beacon so we run EXACTLY the
    ///      new impl bytecode, then asserts M-14 (poll-hat cap) and H-05 (reverting-then-retryable
    ///      execution). A dedicated `actor` (not address(this) — forbidden in scripts) holds the
    ///      creator hat; a single un-gated DIRECT class gives every voter power so `actor` can vote.
    function _assertHybridBehavior(address hvBeacon) internal {
        SimMockHats hats = new SimMockHats();
        SimForwardingExecutor exec = new SimForwardingExecutor();
        uint256 creatorHat = 1;
        address actor = makeAddr("ws-b-gov-actor");
        hats.mint(creatorHat, actor);

        HybridVoting hv = _deployHybridProxy(hvBeacon, address(hats), address(exec), creatorHat);

        _assertM14PollHatCap(hv, actor);
        _assertH05Retryable(hv, actor);
    }

    function _deployHybridProxy(address beacon, address hats, address exec, uint256 creatorHat)
        internal
        returns (HybridVoting hv)
    {
        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = creatorHat;
        IHybridVotingInit.ClassConfig[] memory classes = new IHybridVotingInit.ClassConfig[](1);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: new uint256[](0) // un-gated → every voter (incl. this sim) gets DIRECT power
        });
        bytes memory init = abi.encodeWithSelector(
            HybridVoting.initialize.selector, hats, exec, creatorHats, new address[](0), uint8(50), classes
        );
        hv = HybridVoting(address(new BeaconProxy(beacon, init)));
    }

    function _assertM14PollHatCap(HybridVoting hv, address actor) internal {
        uint256 max = hv.MAX_POLL_HATS();

        // MAX_POLL_HATS + 1 poll hats reverts TooManyPollHats.
        uint256[] memory tooMany = new uint256[](max + 1);
        for (uint256 i; i < max + 1; ++i) {
            tooMany[i] = i + 1;
        }
        IExecutor.Call[][] memory noBatch = new IExecutor.Call[][](0);
        bool reverted;
        vm.prank(actor);
        try hv.createProposal(bytes("cap"), bytes32(0), 15, 2, noBatch, tooMany) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == VotingErrors.TooManyPollHats.selector;
        }
        require(reverted, "M-14: >MAX_POLL_HATS did not revert TooManyPollHats");

        // Exactly MAX_POLL_HATS is accepted.
        uint256[] memory okHats = new uint256[](max);
        for (uint256 i; i < max; ++i) {
            okHats[i] = i + 1;
        }
        vm.prank(actor);
        hv.createProposal(bytes("cap-ok"), bytes32(0), 15, 2, noBatch, okHats);
        console.log("(M-14) MAX_POLL_HATS cap enforced OK, cap =", max);
    }

    function _assertH05Retryable(HybridVoting hv, address actor) internal {
        SimMutableTarget target = new SimMutableTarget(); // starts reverting

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({
            target: address(target), value: 0, data: abi.encodeWithSelector(SimMutableTarget.poke.selector)
        });
        batches[1] = new IExecutor.Call[](0);

        vm.prank(actor);
        hv.createProposal(bytes("h05"), bytes32(0), 15, 2, batches, new uint256[](0));
        uint256 id = hv.proposalsCount() - 1;

        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(actor);
        hv.vote(id, idx, w);

        vm.warp(vm.getBlockTimestamp() + 16 minutes);

        // First finalize: execution reverts inside the executor; announceWinner does NOT revert.
        vm.prank(actor);
        (uint256 winner, bool valid) = hv.announceWinner(id);
        require(valid && winner == 0, "H-05: unexpected winner on first finalize");
        require(target.pokeCount() == 0, "H-05: target should not have been poked (reverted)");

        // Fix the target; the proposal is retryable because executed stayed false.
        target.setShouldRevert(false);
        vm.prank(actor);
        (uint256 winner2, bool valid2) = hv.announceWinner(id);
        require(valid2 && winner2 == 0, "H-05: unexpected winner on retry");
        require(target.pokeCount() == 1, "H-05: retry did not execute the batch");

        // Now terminal: a third finalize reverts AlreadyExecuted.
        bool reverted;
        vm.prank(actor);
        try hv.announceWinner(id) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == VotingErrors.AlreadyExecuted.selector;
        }
        require(reverted, "H-05: post-success finalize must revert AlreadyExecuted");
        console.log("(H-05) reverting execution retryable, then terminal after success OK");
    }
}

interface IPaymasterHubRegistrar {
    function setOrgRegistrar(address registrar) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-B governance upgrade on Gnosis.
 *
 * LIVE ORG (Gnosis subgraph poa-gnosis-v-1, org "KUBI"):
 *   hybridVoting          0x13cbd5ed47bf177968b24d84516a75879c23971e (19 proposals, threshold 35)
 *   directDemocracyVoting 0xe24cb844c73095569fa146d673d45c252894200f (2 proposals, threshold 50)
 *
 * Asserts (in order):
 *   (a) storage survival: proposalCount / thresholdPct / quorum / creator-hat array identical on
 *       BOTH KUBI voting proxies before and after the two beacon upgrades.
 *   (b) M-14 + H-05 behavior on a fresh HybridVoting proxy against the just-upgraded beacon.
 *   (c) fresh-org deployFullOrg through fresh current-src factories + a fresh OrgDeployer v16 proxy
 *       succeeds end-to-end and its HybridVoting is live with the new MIN_DURATION floor.
 */
contract SimGnosis is GovernanceUpgradeSimBase {
    address constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;
    address constant KUBI_DDV = 0xe24Cb844C73095569FA146D673D45c252894200f;

    // Live Gnosis wiring (read 2026-07-04).
    address constant HV_BEACON = 0x4E78755C3478631488be4feF422F6663c6A7d793;
    address constant DDV_BEACON = 0x283044D9da250a9A29DB49258212fBF604B0d6d8;
    address constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address constant ORG_DEPLOYER_BEACON = 0x2f48EB6Ed3D6C37bF8858c39a32262867ba67293;
    address constant ORG_REGISTRY_BEACON = 0x76402cE426b53F28467Aa67Dc4cE5bC2785cCFFE;
    address constant UAR_BEACON = 0x4f2a9d4cB62BEfBA35dAC2D3dE32c55413C65BB6;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-B governance upgrade on Gnosis fork ===\n");

        // (a) pre-upgrade snapshots on both live KUBI voting proxies.
        VotingSnapshot memory hvPre = _snapshotHV(KUBI_HV);
        VotingSnapshot memory ddvPre = _snapshotDDV(KUBI_DDV);
        console.log("KUBI HybridVoting proposals:", hvPre.proposalCount);
        console.log("KUBI DirectDemocracy proposals:", ddvPre.proposalCount);

        _upgradeVotingBeacons();

        // (a) post-upgrade survival.
        _requireSurvived(hvPre, _snapshotHV(KUBI_HV), "KUBI-HV");
        _requireSurvived(ddvPre, _snapshotDDV(KUBI_DDV), "KUBI-DDV");
        console.log("(a) storage survived both beacon upgrades OK");

        // (b) behavior: M-14 cap + H-05 retry against the upgraded HybridVoting beacon.
        _assertHybridBehavior(HV_BEACON);

        // (c) fresh-org deployFullOrg through fresh factories + v16 OrgDeployer proxy.
        _assertFreshOrg();

        console.log("\nPASS: WS-B governance upgrade validated against live Gnosis state.");
    }

    /*──────── (c) fresh org via re-pointed factories + OrgDeployer v16 ────────*/
    function _assertFreshOrg() internal {
        vm.deal(HUDSON_ADMIN, 10 ether);
        (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) = _bootstrapFreshStack();

        bytes32 orgId = keccak256(abi.encodePacked("ws-b-sim-org", vm.getBlockTimestamp(), block.number));
        OrgDeployer.DeploymentParams memory params = _buildParams(orgId, uar);

        vm.prank(HUDSON_ADMIN);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        require(result.hybridVoting != address(0), "(c) fresh org HybridVoting not deployed");
        require(result.directDemocracyVoting != address(0), "(c) fresh org DDV not deployed");

        // The fresh HybridVoting runs the just-upgraded impl: MIN_DURATION floor is 10.
        require(HybridVoting(result.hybridVoting).MIN_DURATION() == 10, "(c) fresh HV MIN_DURATION != 10 (L-04)");
        require(HybridVoting(result.hybridVoting).MAX_POLL_HATS() == 100, "(c) fresh HV MAX_POLL_HATS != 100 (M-14)");
        // Token wired to its own TaskManager through the executor-only setter (WS-A C-01 rides here).
        require(
            ParticipationToken(result.participationToken).taskManager() == result.taskManager,
            "(c) fresh org token.taskManager() mismatch"
        );
        console.log("(c) fresh deployFullOrg via re-pointed factories + v16 OrgDeployer OK:", result.hybridVoting);
    }

    function _bootstrapFreshStack() internal returns (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) {
        // Precondition (WS-A dependency): flip the ParticipationToken (v5), Executor (v4) and
        // OrgDeployer (v16) beacons so the fresh current-src stack is internally consistent —
        // v16.deployFullOrg's step-8 wiring calls Executor.configureParticipationToken (v4), which
        // drives ParticipationToken.setTaskManager (v5), and deployModules must match v16's ABI.
        // In a real broadcast WS-A flips these first; here we reproduce it on the fork.
        DeterministicDeployer ddc = DeterministicDeployer(DD);
        _deployAndUpgrade(ddc, "ParticipationToken", TOKEN_VERSION, type(ParticipationToken).creationCode);
        _deployAndUpgrade(ddc, "Executor", EXECUTOR_VERSION, type(Executor).creationCode);
        _deployAndUpgrade(ddc, "OrgDeployer", DEPLOYER_VERSION, type(OrgDeployer).creationCode);

        GovernanceFactory gov = new GovernanceFactory();
        AccessFactory acc = new AccessFactory();
        ModulesFactory mods = new ModulesFactory();
        HatsTreeSetup hatsTree = new HatsTreeSetup();

        uar = address(
            new BeaconProxy(
                UAR_BEACON, abi.encodeWithSelector(UniversalAccountRegistry.initialize.selector, HUDSON_ADMIN)
            )
        );

        orgRegistry = OrgRegistry(
            address(
                new BeaconProxy(
                    ORG_REGISTRY_BEACON, abi.encodeWithSelector(OrgRegistry.initialize.selector, HUDSON_ADMIN, HATS)
                )
            )
        );

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

        vm.prank(HUDSON_ADMIN);
        orgRegistry.transferOwnership(address(deployer));

        vm.prank(GNOSIS_POA_MANAGER);
        IPaymasterHubRegistrar(GNOSIS_PAYMASTER).setOrgRegistrar(address(deployer));
    }

    /*──────── minimal-config builders (split to dodge stack-too-deep) ────────*/
    function _buildParams(bytes32 orgId, address uar)
        internal
        pure
        returns (OrgDeployer.DeploymentParams memory params)
    {
        params.orgId = orgId;
        params.orgName = "WS-B Sim Org";
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
            asset: address(0), // backfilled to the soulbound PT by GovernanceFactory (H-06 safe path)
            hatIds: emptyHats
        });
    }

    function _buildRoles() internal pure returns (RoleConfigStructs.RoleConfig[] memory roles) {
        roles = new RoleConfigStructs.RoleConfig[](2);
        roles[0] = _role("DEFAULT", false, 1);
        roles[1] = _role("EXECUTIVE", true, type(uint256).max);
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
 * @notice Arbitrum counterpart: upgrades both voting beacons via the Hub-owned Arbitrum PoaManager
 *         (destination effect of upgradeBeaconCrossChain) and asserts storage survival on the live
 *         "Poa" org plus the M-14 / H-05 behavior on the upgraded HybridVoting beacon. The fresh-org
 *         sub-sim is Gnosis-only per the workstream convention.
 *
 * LIVE ORG (Arbitrum subgraph poa-arb-v-1, org "Poa"):
 *   hybridVoting          0x34aa1bd79a3a5eb5d2b208eb4f091ccf6b1081d5 (3 proposals, threshold 50)
 *   directDemocracyVoting 0xc82b179f5b4e325ac1b77a423fdb266aebfca5e8 (0 proposals, threshold 50)
 */
contract SimArbitrum is GovernanceUpgradeSimBase {
    address constant POA_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;
    address constant POA_DDV = 0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8;

    address constant HV_BEACON = 0x58FD83d52f6c278965b4A185a5F3546dC013c842;
    address constant DDV_BEACON = 0xF00094f28c45e4e3516732df10ce84D98F437FBB;

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-B governance upgrade on Arbitrum fork ===\n");

        VotingSnapshot memory hvPre = _snapshotHV(POA_HV);
        VotingSnapshot memory ddvPre = _snapshotDDV(POA_DDV);
        console.log("Poa HybridVoting proposals:", hvPre.proposalCount);
        console.log("Poa DirectDemocracy proposals:", ddvPre.proposalCount);

        _upgradeVotingBeacons();

        _requireSurvived(hvPre, _snapshotHV(POA_HV), "Poa-HV");
        _requireSurvived(ddvPre, _snapshotDDV(POA_DDV), "Poa-DDV");
        console.log("(a) storage survived both beacon upgrades OK");

        _assertHybridBehavior(HV_BEACON);

        console.log("\nPASS: WS-B governance upgrade validated against live Arbitrum state.");
    }
}
