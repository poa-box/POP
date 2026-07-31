// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {ToggleModule} from "../../src/ToggleModule.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*
 * ============================================================================
 * Access / Eligibility security remediation upgrade — WS-D
 * EligibilityModule + QuickJoin + ToggleModule beacon upgrades (audit H-03, M-03, L-26)
 * ============================================================================
 *
 * SRC FIXES SHIPPED (all ride the three beacon impls):
 *   H-03(a) — QuickJoin's caller-specified claim paths (claimHatsWithUser / registerAndClaimHats /
 *          registerAndClaimHatsWithPasskey) now REJECT any hat that is OPEN-TO-EVERYONE (default-
 *          eligible for an arbitrary address) — that is exactly the H-03 self-mint escalation (e.g. the
 *          org's ELIGIBILITY_ADMIN hat, which is open by default). Openness is detected by probing
 *          `hats.isEligible(SENTINEL, hatId)` for a fixed domain-separated sentinel that can never be a
 *          legitimate wearer: if the org's eligibility module reports the sentinel eligible, the hat is
 *          open → revert HatOpenlyClaimable (FAIL CLOSED: a reverting probe is also rejected). GATED
 *          role hats (Delegate/Agent, defaults.eligible=false + vouching) pass this gate and are then
 *          subject to the per-user check inside Hats.mintHat (reverts NotEligible unless the caller was
 *          actually vouched) — so the main vouched-onboarding flow keeps working with NO allowlist and
 *          NO deploy-time seeding. This supersedes the earlier allowlist design (which broke vouched
 *          onboarding for existing orgs). The memberHatIds auto-mint join paths (quickJoinWithUser /
 *          registerAndQuickJoin / master-deploy) are UNAFFECTED — those IDs come from storage, not the
 *          caller — and open base roles (Neighbor) are auto-minted there, never claimed.
 *   H-03(b) — org-config JSON templates: privileged/voting roles now ship defaults.eligible=false
 *          + vouching.enabled=true (applied by the existing HatsTreeSetup.batchSetDefaultEligibility
 *          + OrgDeployer.batchConfigureVouching paths). Config-only; no bytecode impact.
 *   M-03  — EligibilityModule now reverts DefaultEligibilityConflictsWithVouch when the combination
 *          (defaultEligible=true) + (vouching enabled AND combineWithHierarchy) would be created in
 *          either order — that combination silently bypasses the vouch quorum (getWearerStatus ORs
 *          the hierarchy path in). The guard is enforced in EVERY superAdmin writer of defaultRules /
 *          vouchConfigs, not just setDefaultEligibility / configureVouching: the batch/creation
 *          entrypoints (batchSetDefaultEligibility, batchConfigureVouching, registerHatCreation,
 *          batchRegisterHatCreation(WithMetadata), createHatWithEligibility) are ALSO guarded. This
 *          matters because the production org-deploy path (HatsTreeSetup.batchSetDefaultEligibility ->
 *          OrgDeployer.batchConfigureVouching) uses ONLY the batch functions — a misconfigured JSON
 *          now fails loudly at deploy instead of silently shipping the bypass.
 *   H-03(c) — QuickJoin: an EMPTY claimHatIds array is a backward-compatible no-op (registers /
 *          creates account without minting, no revert), preserving the pre-upgrade register-only
 *          behavior of registerAndClaimHats*. The open-hat gate only inspects non-empty claims.
 *   L-26  — ToggleModule.setEligibilityModule gained a zero-address check, an EligibilityModuleSet
 *          event, and an eligibilityModule() getter.
 *
 * STORAGE:
 *   QuickJoin — NO storage change. The open-hat gate is stateless (it probes the org's live
 *     eligibility module at call time via hats.isEligible), so the ERC-7201 Layout
 *     (slot keccak256("poa.quickjoin.storage")) is byte-for-byte the pre-existing v5 layout —
 *     upgrade-safe against upgrades/baseline/QuickJoin.sol.
 *   EligibilityModule / ToggleModule — no storage changes (new error/event/getter + a revert guard).
 *   Storage survival on live KUBI (Gnosis) / Poa (Arbitrum) proxies is asserted in the sims below.
 *
 * ── VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer is CREATE3 → a given (type, version) is the SAME address on both chains.
 *
 *   EligibilityModule: registry count gnosis=4 arbitrum=5.
 *     v5 gnosis FREE but arbitrum TAKEN; v6 FREE on BOTH ⇒ pick v6 (0xB138504a06d1eD636EA2C485a7F055Ce79f9D37E)
 *   QuickJoin:         registry count gnosis=4 arbitrum=5.
 *     v5 gnosis FREE but arbitrum TAKEN; v6 FREE on BOTH ⇒ pick v6 (0x8c6b86E291272dC48F8A0679fa538e64e5b6bf0D)
 *   ToggleModule:      registry count gnosis=1 arbitrum=1.
 *     v2 FREE on BOTH ⇒ pick v2 (0x808c9F60415CF6C4740F876362B3393A7917Fd50)
 *
 * ── BROADCAST ORDER (do NOT run in this workstream) ──
 *   1. Step1_DeployOnGnosis      --rpc-url gnosis   --broadcast --slow  (DD-deploy 3 impls on Gnosis)
 *   2. Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow  (DD-deploy on Arbitrum +
 *        Hub.upgradeBeaconCrossChain for all 3 → Arbitrum local + Gnosis cross-chain dispatch)
 *   3. Step2b_UpgradeGnosis      --rpc-url gnosis   --broadcast --slow  (Satellite.upgradeBeaconDirect
 *        for all 3 — destination-chain path, skips the ~5-min Hyperlane wait)
 *   4. Step3_Verify              --rpc-url gnosis / --rpc-url arbitrum  (read-only PASS check)
 *
 * ── SIMS (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeAccessSecurity.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeAccessSecurity.s.sol:SimArbitrum --fork-url arbitrum -vvv
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

string constant QJ_VERSION = "v6";
string constant ELIG_VERSION = "v6";
string constant TOGGLE_VERSION = "v2";

/// @dev Satellite.upgradeBeaconDirect forwards to PoaManager.upgradeBeacon (onlyOwner=Satellite)
///      with the Satellite as msg.sender — the destination-chain emergency upgrade path (proven in
///      WS-A/WS-B; adminCall is NOT usable for beacon upgrades).
interface ISatellite {
    function owner() external view returns (address);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                 BROADCAST STEPS
═══════════════════════════════════════════════════════════════════════════*/

/// @title Step1_DeployOnGnosis — deploy the three impls on Gnosis via DD (idempotent).
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 1: Deploy access-fix impls on Gnosis ===");
        vm.startBroadcast(key);
        _deploy(dd, "EligibilityModule", ELIG_VERSION, type(EligibilityModule).creationCode);
        _deploy(dd, "QuickJoin", QJ_VERSION, type(QuickJoin).creationCode);
        _deploy(dd, "ToggleModule", TOGGLE_VERSION, type(ToggleModule).creationCode);
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

/// @title Step2_UpgradeFromArbitrum — DD-deploy on Arbitrum + upgrade all three beacons
///        Arbitrum-local AND cross-chain-dispatch to Gnosis via the Hub.
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        require(hub.owner() == vm.addr(key), "Step2: signer must own Hub");
        console.log("\n=== Step 2: Upgrade from Arbitrum (local + cross-chain to Gnosis) ===");
        vm.startBroadcast(key);
        _upgrade(hub, dd, "EligibilityModule", ELIG_VERSION, type(EligibilityModule).creationCode);
        _upgrade(hub, dd, "QuickJoin", QJ_VERSION, type(QuickJoin).creationCode);
        _upgrade(hub, dd, "ToggleModule", TOGGLE_VERSION, type(ToggleModule).creationCode);
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

/// @title Step2b_UpgradeGnosis — upgrade the three Gnosis beacons directly (no Hyperlane wait).
///        Requires Step1 impls already deployed on Gnosis.
contract Step2b_UpgradeGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 2b: Upgrade Gnosis beacons via Satellite.upgradeBeaconDirect ===");
        vm.startBroadcast(key);
        _upgrade(dd, "EligibilityModule", ELIG_VERSION);
        _upgrade(dd, "QuickJoin", QJ_VERSION);
        _upgrade(dd, "ToggleModule", TOGGLE_VERSION);
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

/// @title Step3_Verify — confirm all three beacons point at the new impls on the given chain.
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address poaManager;
        try PoaManagerHub(payable(HUB)).poaManager() returns (PoaManager pm) {
            poaManager = address(pm); // Arbitrum
        } catch {
            poaManager = GNOSIS_POA_MANAGER; // Gnosis
        }
        console.log("\n=== Step 3: Verify access beacons ===");
        _verify(dd, poaManager, "EligibilityModule", ELIG_VERSION);
        _verify(dd, poaManager, "QuickJoin", QJ_VERSION);
        _verify(dd, poaManager, "ToggleModule", TOGGLE_VERSION);
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

/// @dev Snapshot of a live QuickJoin proxy's readable wiring, captured pre-upgrade / re-checked post.
struct QuickJoinSnapshot {
    address hats;
    address registry;
    address master;
    address executor;
    uint256 memberHatCount;
    bytes32 memberHatsHash;
}

/// @dev Snapshot of a live EligibilityModule proxy's readable state on a chosen hat.
struct EligSnapshot {
    address superAdmin;
    address toggleModule;
    uint256 sampleHat;
    bool sampleDefaultEligible;
    bool sampleDefaultStanding;
    bool sampleVouchEnabled;
    bool sampleVouchCombine;
    uint32 sampleVouchQuorum;
}

/// @dev Minimal Hats mock: mints hats and always reports the wearer.
contract SimMockHats {
    mapping(uint256 => mapping(address => bool)) public wears;

    function mintHat(uint256 hat, address who) external returns (bool) {
        wears[hat][who] = true;
        return true;
    }

    function isWearerOfHat(address user, uint256 hat) external view returns (bool) {
        return wears[hat][user];
    }

    function isAdminOfHat(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Executor mock: substitutes for QuickJoin's `executor`, recording the mint request. The H-03
///      gate under test lives inside QuickJoin (the open-hat rejection) and runs BEFORE this call, so
///      recording the call is enough to prove a claim passed the gate. The real per-user NotEligible
///      gate is Hats.mintHat — exercised implicitly because the fresh QuickJoin proxy is wired to the
///      LIVE Hats contract for the eligibility probe (see _assertH03).
contract SimMintingExecutor {
    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        for (uint256 i; i < hatIds.length; ++i) {
            minted[user][hatIds[i]] = true;
        }
    }

    mapping(address => mapping(uint256 => bool)) public minted;
}

/// @dev Registry mock: lets the sim assign usernames without signature verification.
contract SimMockRegistry {
    mapping(address => string) public names;

    function getUsername(address a) external view returns (string memory) {
        return names[a];
    }

    function setUsername(address a, string calldata n) external {
        names[a] = n;
    }
}

abstract contract AccessUpgradeSimBase is Script {
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

    function _upgradeAccessBeacons() internal {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        _deployAndUpgrade(dd, "EligibilityModule", ELIG_VERSION, type(EligibilityModule).creationCode);
        _deployAndUpgrade(dd, "QuickJoin", QJ_VERSION, type(QuickJoin).creationCode);
        _deployAndUpgrade(dd, "ToggleModule", TOGGLE_VERSION, type(ToggleModule).creationCode);
    }

    /*──────── storage survival: QuickJoin ────────*/
    function _snapshotQJ(address proxy) internal view returns (QuickJoinSnapshot memory s) {
        QuickJoin q = QuickJoin(proxy);
        s.hats = address(q.hats());
        s.registry = address(q.accountRegistry());
        s.master = q.masterDeployAddress();
        s.executor = q.executor();
        uint256[] memory mh = q.memberHatIds();
        s.memberHatCount = mh.length;
        s.memberHatsHash = keccak256(abi.encode(mh));
    }

    function _requireQJSurvived(QuickJoinSnapshot memory pre, QuickJoinSnapshot memory post, string memory tag)
        internal
        pure
    {
        require(pre.hats == post.hats, string.concat(tag, ": QJ hats drifted"));
        require(pre.registry == post.registry, string.concat(tag, ": QJ registry drifted"));
        require(pre.master == post.master, string.concat(tag, ": QJ master drifted"));
        require(pre.executor == post.executor, string.concat(tag, ": QJ executor drifted"));
        require(pre.memberHatCount == post.memberHatCount, string.concat(tag, ": QJ memberHatCount drifted"));
        require(pre.memberHatsHash == post.memberHatsHash, string.concat(tag, ": QJ memberHats drifted"));
    }

    /*──────── storage survival: EligibilityModule ────────*/
    function _snapshotElig(address proxy, uint256 sampleHat) internal view returns (EligSnapshot memory s) {
        EligibilityModule e = EligibilityModule(proxy);
        s.superAdmin = e.superAdmin();
        s.toggleModule = e.toggleModule();
        s.sampleHat = sampleHat;
        (s.sampleDefaultEligible, s.sampleDefaultStanding) = e.getDefaultRules(sampleHat);
        EligibilityModule.VouchConfig memory vc = e.getVouchConfig(sampleHat);
        s.sampleVouchEnabled = e.isVouchingEnabled(sampleHat);
        s.sampleVouchCombine = e.combinesWithHierarchy(sampleHat);
        s.sampleVouchQuorum = vc.quorum;
    }

    function _requireEligSurvived(EligSnapshot memory pre, EligSnapshot memory post, string memory tag) internal pure {
        require(pre.superAdmin == post.superAdmin, string.concat(tag, ": elig superAdmin drifted"));
        require(pre.toggleModule == post.toggleModule, string.concat(tag, ": elig toggleModule drifted"));
        require(pre.sampleDefaultEligible == post.sampleDefaultEligible, string.concat(tag, ": elig default eligible"));
        require(pre.sampleDefaultStanding == post.sampleDefaultStanding, string.concat(tag, ": elig default standing"));
        require(pre.sampleVouchEnabled == post.sampleVouchEnabled, string.concat(tag, ": elig vouch enabled"));
        require(pre.sampleVouchCombine == post.sampleVouchCombine, string.concat(tag, ": elig vouch combine"));
        require(pre.sampleVouchQuorum == post.sampleVouchQuorum, string.concat(tag, ": elig vouch quorum"));
    }

    /*──────── (b) H-03 eligibility gate against the just-upgraded QuickJoin beacon ────────*/
    /// @dev NEW H-03 model (no allowlist): the caller-specified claim paths reject any hat that is
    ///      OPEN-TO-EVERYONE (default-eligible for an arbitrary address — the self-mint escalation),
    ///      and rely on Hats.mintHat's NotEligible for per-user gating of the remaining GATED hats.
    ///
    ///      This is proven against the LIVE org's real EligibilityModule: the fresh QuickJoin proxy is
    ///      wired to the LIVE Hats contract, so `hats.isEligible(SENTINEL, hatId)` routes through the
    ///      exact production eligibility module. Given:
    ///        - `openHat`  : an open-to-everyone hat (e.g. the org's ELIGIBILITY_ADMIN hat — the H-03
    ///                       escalation) for which the eligibility module reports the sentinel eligible;
    ///        - `gatedHat` : a vouch-gated role hat (e.g. Delegate) for which the sentinel is NOT
    ///                       eligible;
    ///      it proves:
    ///        (b1) claiming `openHat` REVERTS HatOpenlyClaimable (blocked because open),
    ///        (b2) claiming `gatedHat` is NOT blocked-as-open (the mint proceeds — the mock executor
    ///             stands in for the real minter; the real per-user NotEligible gate is Hats.mintHat),
    ///        (b3) an EMPTY claim array is a backward-compatible no-op (registers-only, no revert).
    function _assertH03(address qjBeacon, address liveHats, uint256 openHat, uint256 gatedHat) internal {
        SimMintingExecutor exec = new SimMintingExecutor();
        SimMockRegistry reg = new SimMockRegistry();

        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = 1;

        // Wire the proxy to the LIVE Hats contract so the eligibility probe is genuine (real module).
        bytes memory init = abi.encodeWithSelector(
            QuickJoin.initialize.selector, address(exec), liveHats, address(reg), address(exec), memberHats
        );
        QuickJoin qj = QuickJoin(address(new BeaconProxy(qjBeacon, init)));

        address claimer = makeAddr("ws-d-claimer");
        reg.setUsername(claimer, "alice");

        // (b1) claiming the OPEN hat (ELIGIBILITY_ADMIN — the H-03 self-mint escalation) reverts.
        uint256[] memory openClaim = new uint256[](1);
        openClaim[0] = openHat;
        bool reverted;
        vm.prank(claimer);
        try qj.claimHatsWithUser(openClaim) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == QuickJoin.HatOpenlyClaimable.selector;
        }
        require(reverted, "H-03: open (default-eligible) hat must be blocked from the claim path");
        require(!exec.minted(claimer, openHat), "H-03: open hat must not be minted");
        console.log("(b1) OPEN hat (ELIGIBILITY_ADMIN) blocked by the eligibility gate OK");

        // (b2) claiming the GATED hat (Delegate) is NOT blocked-as-open — it passes the gate and the
        // mint proceeds. (In production the real Hats.mintHat then gates per-user with NotEligible; here
        // the mock executor stands in for the minter, so a completed mint == "passed the open-hat gate".)
        uint256[] memory gatedClaim = new uint256[](1);
        gatedClaim[0] = gatedHat;
        bool blockedAsOpen;
        vm.prank(claimer);
        try qj.claimHatsWithUser(gatedClaim) {}
        catch (bytes memory reason) {
            blockedAsOpen = bytes4(reason) == QuickJoin.HatOpenlyClaimable.selector;
        }
        require(!blockedAsOpen, "H-03: gated hat must NOT be rejected as open-to-everyone");
        require(exec.minted(claimer, gatedHat), "H-03: gated hat passed the gate and should reach the minter");
        console.log("(b2) GATED hat (Delegate) NOT blocked-as-open; per-user gate is Hats.mintHat OK");

        // (b3) Backward-compat: an EMPTY claim array is a no-op (no revert, no mint) — preserves the
        // pre-upgrade register-only behavior of the register+claim paths.
        address emptyClaimer = makeAddr("ws-d-empty-claimer");
        reg.setUsername(emptyClaimer, "carol");
        uint256[] memory none = new uint256[](0);
        vm.prank(emptyClaimer);
        qj.claimHatsWithUser(none); // must NOT revert
        require(!exec.minted(emptyClaimer, gatedHat), "H-03: empty claim must mint nothing");
        console.log("(b3) empty claim array is a backward-compatible no-op OK");
    }

    /*──────── (c) M-03 against the just-upgraded EligibilityModule beacon ────────*/
    /// @dev Deploys a fresh EligibilityModule proxy on the upgraded beacon and, as its superAdmin,
    ///      proves the conflict guard fires in BOTH orderings.
    function _assertM03(address eligBeacon) internal {
        address superAdmin = makeAddr("ws-d-elig-admin");
        SimMockHats hats = new SimMockHats();
        bytes memory init =
            abi.encodeWithSelector(EligibilityModule.initialize.selector, superAdmin, address(hats), address(0));
        EligibilityModule elig = EligibilityModule(address(new BeaconProxy(eligBeacon, init)));

        uint256 hat = 12_345;
        uint256 voucherHat = 6_789;

        // Direction 1: vouch+combine first, then setDefaultEligibility(true) must revert.
        vm.prank(superAdmin);
        elig.configureVouching(hat, 2, voucherHat, true);
        bool reverted;
        vm.prank(superAdmin);
        try elig.setDefaultEligibility(hat, true, true) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EligibilityModule.DefaultEligibilityConflictsWithVouch.selector;
        }
        require(reverted, "M-03: setDefaultEligibility(true) on vouch+combine must revert");

        // Direction 2: default-eligible first, then configureVouching(combine) must revert.
        uint256 hat2 = 54_321;
        vm.prank(superAdmin);
        elig.setDefaultEligibility(hat2, true, true);
        reverted = false;
        vm.prank(superAdmin);
        try elig.configureVouching(hat2, 2, voucherHat, true) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EligibilityModule.DefaultEligibilityConflictsWithVouch.selector;
        }
        require(reverted, "M-03: configureVouching(combine) on default-eligible must revert");

        // Sanity: the non-combining config is still allowed.
        vm.prank(superAdmin);
        elig.configureVouching(hat2, 2, voucherHat, false);
        require(elig.isVouchingEnabled(hat2), "M-03: non-combining vouch must still be settable");
        console.log("(c) M-03 conflict guard fires in both directions OK");

        // Direction 3 (M-03 COMPLETENESS): the batch entrypoints used by the production org-deploy
        // path must ALSO enforce the guard. batchConfigureVouching(combine) on a default-eligible hat
        // must revert — this is the exact HatsTreeSetup->OrgDeployer deploy path.
        uint256 hat3 = 99_001;
        vm.prank(superAdmin);
        elig.setDefaultEligibility(hat3, true, true);

        uint256[] memory bHats = new uint256[](1);
        bHats[0] = hat3;
        uint32[] memory bQuorums = new uint32[](1);
        bQuorums[0] = 2;
        uint256[] memory bMembership = new uint256[](1);
        bMembership[0] = voucherHat;
        bool[] memory bCombine = new bool[](1);
        bCombine[0] = true;

        reverted = false;
        vm.prank(superAdmin);
        try elig.batchConfigureVouching(bHats, bQuorums, bMembership, bCombine) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EligibilityModule.DefaultEligibilityConflictsWithVouch.selector;
        }
        require(reverted, "M-03: batchConfigureVouching(combine) on default-eligible must revert");

        // And batchSetDefaultEligibility(true) on a vouch+combine hat must revert.
        uint256 hat4 = 99_002;
        vm.prank(superAdmin);
        elig.configureVouching(hat4, 2, voucherHat, true);
        uint256[] memory dHats = new uint256[](1);
        dHats[0] = hat4;
        bool[] memory dElig = new bool[](1);
        dElig[0] = true;
        bool[] memory dStand = new bool[](1);
        dStand[0] = true;

        reverted = false;
        vm.prank(superAdmin);
        try elig.batchSetDefaultEligibility(dHats, dElig, dStand) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EligibilityModule.DefaultEligibilityConflictsWithVouch.selector;
        }
        require(reverted, "M-03: batchSetDefaultEligibility(true) on vouch+combine must revert");
        console.log("(c2) M-03 guard fires in the batch (deploy-path) entrypoints too OK");
    }

    /*──────── (d) L-26 against the just-upgraded ToggleModule beacon ────────*/
    function _assertL26(address toggleBeacon) internal {
        address admin = makeAddr("ws-d-toggle-admin");
        bytes memory init = abi.encodeWithSelector(ToggleModule.initialize.selector, admin);
        ToggleModule tog = ToggleModule(address(new BeaconProxy(toggleBeacon, init)));

        // zero-address reverts.
        bool reverted;
        vm.prank(admin);
        try tog.setEligibilityModule(address(0)) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == ToggleModule.ZeroAddress.selector;
        }
        require(reverted, "L-26: setEligibilityModule(0) must revert ZeroAddress");

        // valid set stores + getter returns + event.
        address elig = makeAddr("ws-d-toggle-elig");
        vm.expectEmit(true, true, false, false, address(tog));
        emit ToggleModule.EligibilityModuleSet(address(0), elig);
        vm.prank(admin);
        tog.setEligibilityModule(elig);
        require(tog.eligibilityModule() == elig, "L-26: getter did not return the set module");
        console.log("(d) L-26 zero-check + event + getter OK");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-D access upgrade on Gnosis.
 *
 * LIVE ORG (Gnosis subgraph poa-gnosis-v-1, org "KUBI"):
 *   quickJoin         0x5dbda3649b7044c8fdd0e540e86e536dda7926cf
 *   executor          0x23f90b3859818a843c3a848627a304bc53947342
 *   eligibilityModule 0x27114cb757bedf77e30eeb0ca635e3368d8c2914
 *   toggleModule      0xb4da98791573ddf15bb811d497a4212904eba3ed
 */
contract SimGnosis is AccessUpgradeSimBase {
    address constant KUBI_QJ = 0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf;
    address constant KUBI_ELIG = 0x27114Cb757BeDF77E30EeB0Ca635e3368d8C2914;

    // Live Gnosis global beacons (PoaManager.getBeaconById, read 2026-07-04).
    address constant QJ_BEACON = 0x0a164962bDc5A05457CE646aBE4521dc08E48a9B;
    address constant ELIG_BEACON = 0x5AB541aAe2653f448a08177ab64383c312e8A8fb;
    address constant TOGGLE_BEACON = 0x87e52D9509F03DF5BD2aA7B84D0dd9caB86E20b2;

    // H-03 live evidence — the "Decentral Park" org on Gnosis (org id
    // 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78). Its EligibilityModule
    // (0xe4a02f20b8282a272879e31479ee070dab07b015) reports the fixed claim-probe sentinel eligible for
    // the OPEN ELIGIBILITY_ADMIN hat (the H-03 escalation) and NOT eligible for the vouch-gated Delegate
    // hat — validated on-fork 2026-07-04. The eligibility probe routes through the shared live Hats
    // contract that every Gnosis org uses.
    address constant LIVE_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    uint256 constant DPARK_ELIG_ADMIN_HAT = 36180248838692297934744644785522640003358674060733414678036010791600128; // OPEN → must be blocked
    uint256 constant DPARK_DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024; // GATED → not blocked-as-open

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-D access upgrade on Gnosis fork ===\n");

        // (a) pre-upgrade snapshots on live KUBI proxies. Sample the eligibility admin hat.
        uint256 sampleHat = EligibilityModule(KUBI_ELIG).eligibilityModuleAdminHat();
        QuickJoinSnapshot memory qjPre = _snapshotQJ(KUBI_QJ);
        EligSnapshot memory eligPre = _snapshotElig(KUBI_ELIG, sampleHat);
        console.log("KUBI QuickJoin memberHatCount:", qjPre.memberHatCount);
        console.log("KUBI Elig sample hat:", sampleHat);

        _upgradeAccessBeacons();

        // (a) post-upgrade survival.
        _requireQJSurvived(qjPre, _snapshotQJ(KUBI_QJ), "KUBI-QJ");
        _requireEligSurvived(eligPre, _snapshotElig(KUBI_ELIG, sampleHat), "KUBI-ELIG");
        console.log("(a) storage survived all three beacon upgrades OK");

        // (b) H-03 eligibility gate on a fresh QuickJoin proxy (upgraded beacon) wired to the LIVE Hats
        //     contract, using the real Decentral Park OPEN (ELIGIBILITY_ADMIN) vs GATED (Delegate) hats.
        _assertH03(QJ_BEACON, LIVE_HATS, DPARK_ELIG_ADMIN_HAT, DPARK_DELEGATE_HAT);

        // (c) M-03 behavior on a fresh EligibilityModule proxy against the upgraded beacon.
        _assertM03(ELIG_BEACON);

        // (d) L-26 behavior on a fresh ToggleModule proxy against the upgraded beacon.
        _assertL26(TOGGLE_BEACON);

        console.log("\nPASS: WS-D access upgrade validated against live Gnosis state.");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                  SIM: ARBITRUM
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimArbitrum
 * @notice Arbitrum counterpart: upgrades all three beacons via the Hub-owned Arbitrum PoaManager
 *         (destination effect of upgradeBeaconCrossChain) and asserts storage survival on the live
 *         "Poa" org plus the H-03 / M-03 / L-26 behavior on the upgraded beacons.
 *
 * LIVE ORG (Arbitrum subgraph poa-arb-v-1, org "Poa"):
 *   quickJoin         0x366c605a3064a680fb5c05bf9eeda512fddbf03a
 *   executor          0xb1ff2bd0231770ccc91801aa1fae4b3226e1fe41
 *   eligibilityModule 0xe4f9cb9c843d0a5bd5d52e3266138b13a635743b
 *   toggleModule      0x14aced4f1b6fb1ef4030e7e7e19a3e6ab0b931a1
 */
contract SimArbitrum is AccessUpgradeSimBase {
    address constant POA_QJ = 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a;
    address constant POA_ELIG = 0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b;

    // Live Arbitrum global beacons (PoaManager.getBeaconById, read 2026-07-04).
    address constant QJ_BEACON = 0x3e22880F8Dd9aA473A3D92088d9d38fb29FfA840;
    address constant ELIG_BEACON = 0xF02b1a7326688ECa194A6F5c5049B058fC825157;
    address constant TOGGLE_BEACON = 0xAa2Af12401A9d4AdA8485Bb1A757f6d7D3df5B47;

    // H-03 live evidence — the "Poa" org on Arbitrum. Its EligibilityModule reports the fixed
    // claim-probe sentinel eligible for the OPEN ELIGIBILITY_ADMIN hat (the H-03 escalation) and NOT
    // eligible for the vouch-gated MEMBER hat — validated on-fork 2026-07-04. Same shared live Hats
    // contract as Gnosis (CREATE3 → identical address cross-chain).
    address constant LIVE_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    uint256 constant POA_ELIG_ADMIN_HAT = 2507275451421148831205542941835121291985880676980239649137601590329344; // OPEN → must be blocked
    uint256 constant POA_MEMBER_HAT = 2507275451427425932940929622598957081409088343396342004582065624842240; // GATED → not blocked-as-open

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-D access upgrade on Arbitrum fork ===\n");

        uint256 sampleHat = EligibilityModule(POA_ELIG).eligibilityModuleAdminHat();
        QuickJoinSnapshot memory qjPre = _snapshotQJ(POA_QJ);
        EligSnapshot memory eligPre = _snapshotElig(POA_ELIG, sampleHat);
        console.log("Poa QuickJoin memberHatCount:", qjPre.memberHatCount);
        console.log("Poa Elig sample hat:", sampleHat);

        _upgradeAccessBeacons();

        _requireQJSurvived(qjPre, _snapshotQJ(POA_QJ), "Poa-QJ");
        _requireEligSurvived(eligPre, _snapshotElig(POA_ELIG, sampleHat), "Poa-ELIG");
        console.log("(a) storage survived all three beacon upgrades OK");

        _assertH03(QJ_BEACON, LIVE_HATS, POA_ELIG_ADMIN_HAT, POA_MEMBER_HAT);
        _assertM03(ELIG_BEACON);
        _assertL26(TOGGLE_BEACON);

        console.log("\nPASS: WS-D access upgrade validated against live Arbitrum state.");
    }
}
