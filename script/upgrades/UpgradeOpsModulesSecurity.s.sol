// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PaymentManager} from "../../src/PaymentManager.sol";
import {IPaymentManager} from "../../src/interfaces/IPaymentManager.sol";
import {EducationHub, IParticipationToken} from "../../src/EducationHub.sol";
import {ImplementationRegistry} from "../../src/ImplementationRegistry.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*
 * ============================================================================
 * Ops-modules security remediation upgrade — WS-E
 * PaymentManager + EducationHub + ImplementationRegistry beacon upgrades
 * (audit M-08, L-18, L-19, L-16, L-58)
 * ============================================================================
 *
 * SRC FIXES SHIPPED (all ride the three beacon impls):
 *   M-08  — PaymentManager.finalizeDistribution anchored the claim window to the (arbitrarily
 *          past) checkpointBlock, so `checkpointBlock + minClaimPeriodBlocks` could already be
 *          behind us at creation, letting finalize run before claimers ever had a real window.
 *          FIX: append `uint256 creationBlock` to the END of the Distribution struct (ERC-7201
 *          append-only — the Distribution lives as a value inside the `distributions` mapping in
 *          the namespaced Layout, so appending a trailing field is upgrade-safe and existing
 *          distributions read it as 0). Set creationBlock = block.number at creation and gate
 *          finalize on `creationBlock + minClaimPeriodBlocks`. BACKWARD-COMPAT: a pre-upgrade
 *          distribution has creationBlock == 0 and falls back to the OLD `checkpointBlock` anchor
 *          so in-flight distributions still finalize sanely.
 *   L-18  — finalizeDistribution gained `nonReentrant` (parity with the other value-movers:
 *          createDistribution / claimDistribution / claimMultiple / payERC20 / withdraw).
 *   L-19  — opt-out was enforced on the CLAIM path, letting an address that opts out AFTER being
 *          allocated in a distribution's merkle tree lose funds it was already owed (finalize
 *          returns the "unclaimed" funds to the executor — effectively confiscation). FIX: opt-out
 *          is removed from claimDistribution / claimMultiple. It now applies to FUTURE
 *          distributions only (honored off-chain when the executor builds the next merkle tree).
 *          Lower-risk than a per-distribution opt-out snapshot: no extra storage, no struct change
 *          beyond M-08, and it cannot strand allocated funds.
 *   L-16  — EducationHub.setToken did not verify the reverse minter wiring. completeModule mints
 *          via token.mint, which the token gates on its `educationHub` being this hub; pointing at
 *          a token that does not authorize this hub would silently brick every completion. FIX:
 *          add `educationHub()` to IParticipationToken (the getter already exists on the token) and
 *          require `newToken.educationHub() == address(this)` in setToken (reverts TokenNotWired).
 *   L-58  — ImplementationRegistry.registerImplementation, when called with setLatest=false for the
 *          FIRST version of a type, left `latest == bytes32(0)`, so getLatestImplementation reverted
 *          TypeUnknown despite a valid registered impl. FIX: the first version of a type ALWAYS
 *          becomes latest (event `latest` flag reflects this); subsequent registers keep honoring
 *          the caller's setLatest flag.
 *
 * STORAGE:
 *   PaymentManager — appends `uint256 creationBlock` to the END of the Distribution struct (a value
 *     inside the `distributions` mapping under slot keccak256("poa.paymentmanager.storage")).
 *     Existing distributions read it as 0 and finalize via the checkpointBlock fallback.
 *   EducationHub / ImplementationRegistry — no storage changes (new error / revised latest logic).
 *   Storage survival on live KUBI (Gnosis) / Poa (Arbitrum) proxies + the live per-chain
 *     ImplementationRegistry singleton is asserted in the sims below.
 *
 * ── IMPLEMENTATIONREGISTRY UPGRADE MECHANISM ──
 *   The ImplementationRegistry is NOT a fixed/immutable proxy: it is itself a BeaconProxy behind a
 *   PoaManager-owned UpgradeableBeacon, registered as the "ImplementationRegistry" contract type
 *   (see DeployInfrastructure.s.sol addContractType("ImplementationRegistry",...) +
 *   getBeaconById(keccak256("ImplementationRegistry"))). So it upgrades through the SAME beacon
 *   path as every other module — Satellite.upgradeBeaconDirect (Gnosis) /
 *   Hub.upgradeBeaconCrossChain (Arbitrum). No special mechanism required.
 *
 * ── VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer is CREATE3 → a given (type, version) is the SAME address on both chains.
 *
 *   PaymentManager:         registry count gnosis=2 arbitrum=2.
 *     v3 CREATE2 slot is OCCUPIED on Gnosis (bytecode registered historically under an earlier
 *     version) but FREE on Arbitrum; v4 FREE on BOTH surfaces on BOTH chains
 *     ⇒ pick v4 (0x5126A721d043fa3Cd86008137ee2CCD20d3cedfb)
 *   EducationHub:           registry count gnosis=1 arbitrum=1.
 *     v2 FREE on BOTH ⇒ pick v2 (0xfc19aDBc358e1A2B7f619584eCA7d50ae97048d0)
 *   ImplementationRegistry: registry count gnosis=1 arbitrum=1.
 *     v2 FREE on BOTH ⇒ pick v2 (0x7351Cb3a763287fA374e5045237be3B46D5a760f)
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
 *     script/upgrades/UpgradeOpsModulesSecurity.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeOpsModulesSecurity.s.sol:SimArbitrum --fork-url arbitrum -vvv
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

string constant PM_VERSION = "v4";
string constant EH_VERSION = "v2";
string constant REG_VERSION = "v2";

/// @dev Satellite.upgradeBeaconDirect forwards to PoaManager.upgradeBeacon (onlyOwner=Satellite)
///      with the Satellite as msg.sender — the destination-chain emergency upgrade path (proven in
///      WS-A/WS-B/WS-D; adminCall is NOT usable for beacon upgrades).
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
        console.log("\n=== Step 1: Deploy ops-fix impls on Gnosis ===");
        vm.startBroadcast(key);
        _deploy(dd, "PaymentManager", PM_VERSION, type(PaymentManager).creationCode);
        _deploy(dd, "EducationHub", EH_VERSION, type(EducationHub).creationCode);
        _deploy(dd, "ImplementationRegistry", REG_VERSION, type(ImplementationRegistry).creationCode);
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
        _upgrade(hub, dd, "PaymentManager", PM_VERSION, type(PaymentManager).creationCode);
        _upgrade(hub, dd, "EducationHub", EH_VERSION, type(EducationHub).creationCode);
        _upgrade(hub, dd, "ImplementationRegistry", REG_VERSION, type(ImplementationRegistry).creationCode);
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
        _upgrade(dd, "PaymentManager", PM_VERSION);
        _upgrade(dd, "EducationHub", EH_VERSION);
        _upgrade(dd, "ImplementationRegistry", REG_VERSION);
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
        console.log("\n=== Step 3: Verify ops beacons ===");
        _verify(dd, poaManager, "PaymentManager", PM_VERSION);
        _verify(dd, poaManager, "EducationHub", EH_VERSION);
        _verify(dd, poaManager, "ImplementationRegistry", REG_VERSION);
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

/// @dev Snapshot of a live PaymentManager proxy's readable wiring + distribution ledger.
struct PMSnapshot {
    address revenueShareToken;
    uint256 distributionCounter;
    bytes32 distsHash; // keccak of every existing distribution's readable fields
}

/// @dev Snapshot of a live EducationHub proxy's readable wiring + module ledger.
struct EHSnapshot {
    address token;
    address hats;
    address executor;
    uint256 nextModuleId;
    bytes32 modulesHash; // keccak of every existing module's (payout, exists)
}

/// @dev Snapshot of a live ImplementationRegistry singleton's readable version ledger.
struct RegSnapshot {
    uint256 typeCount;
    bytes32 versionsHash; // keccak of every type's (versionCount, latestImpl)
}

/// @dev Minimal Hats mock for the EducationHub L-16 fixture.
contract SimMockHats {
    mapping(uint256 => mapping(address => bool)) public wears;

    function mintHat(uint256 hat, address who) external returns (bool) {
        wears[hat][who] = true;
        return true;
    }

    function isWearerOfHat(address user, uint256 hat) external view returns (bool) {
        return wears[hat][user];
    }
}

/// @dev A ParticipationToken stand-in whose educationHub() is configurable, for the L-16 fixture.
contract SimMockPT {
    address public educationHub;

    function setEducationHub(address eh) external {
        educationHub = eh;
    }

    function mint(address, uint256) external {}

    // Unused IERC20 surface (EducationHub only calls mint + educationHub on setToken/complete).
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

abstract contract OpsUpgradeSimBase is Script {
    // keccak256("poa.paymentmanager.storage")
    bytes32 constant PM_STORAGE_SLOT = keccak256("poa.paymentmanager.storage");

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

    function _upgradeOpsBeacons() internal {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        _deployAndUpgrade(dd, "PaymentManager", PM_VERSION, type(PaymentManager).creationCode);
        _deployAndUpgrade(dd, "EducationHub", EH_VERSION, type(EducationHub).creationCode);
        _deployAndUpgrade(dd, "ImplementationRegistry", REG_VERSION, type(ImplementationRegistry).creationCode);
    }

    /*──────── storage survival: PaymentManager ────────*/
    function _snapshotPM(address proxy) internal view returns (PMSnapshot memory s) {
        PaymentManager pm = PaymentManager(payable(proxy));
        s.revenueShareToken = pm.revenueShareToken();
        s.distributionCounter = pm.distributionCounter();
        bytes memory acc;
        for (uint256 id = 1; id <= s.distributionCounter; ++id) {
            (
                address payoutToken,
                uint256 totalAmount,
                uint256 checkpointBlock,
                bytes32 merkleRoot,
                uint256 totalClaimed,
                bool finalized
            ) = pm.getDistribution(id);
            acc = abi.encode(acc, payoutToken, totalAmount, checkpointBlock, merkleRoot, totalClaimed, finalized);
        }
        s.distsHash = keccak256(acc);
    }

    function _requirePMSurvived(PMSnapshot memory pre, PMSnapshot memory post, string memory tag) internal pure {
        require(pre.revenueShareToken == post.revenueShareToken, string.concat(tag, ": PM revenueShareToken drifted"));
        require(pre.distributionCounter == post.distributionCounter, string.concat(tag, ": PM counter drifted"));
        require(pre.distsHash == post.distsHash, string.concat(tag, ": PM distributions drifted"));
    }

    /*──────── storage survival: EducationHub ────────*/
    function _snapshotEH(address proxy) internal view returns (EHSnapshot memory s) {
        EducationHub eh = EducationHub(proxy);
        s.token = address(eh.token());
        s.hats = address(eh.hats());
        s.executor = eh.executor();
        s.nextModuleId = eh.nextModuleId();
        bytes memory acc;
        for (uint256 id = 0; id < s.nextModuleId; ++id) {
            // getModule reverts on removed modules; tolerate that and fold a sentinel.
            try eh.getModule(id) returns (uint256 payout, bool exists) {
                acc = abi.encode(acc, id, payout, exists);
            } catch {
                acc = abi.encode(acc, id, uint256(0), false);
            }
        }
        s.modulesHash = keccak256(acc);
    }

    function _requireEHSurvived(EHSnapshot memory pre, EHSnapshot memory post, string memory tag) internal pure {
        require(pre.token == post.token, string.concat(tag, ": EH token drifted"));
        require(pre.hats == post.hats, string.concat(tag, ": EH hats drifted"));
        require(pre.executor == post.executor, string.concat(tag, ": EH executor drifted"));
        require(pre.nextModuleId == post.nextModuleId, string.concat(tag, ": EH nextModuleId drifted"));
        require(pre.modulesHash == post.modulesHash, string.concat(tag, ": EH modules drifted"));
    }

    /*──────── storage survival: ImplementationRegistry singleton ────────*/
    function _snapshotReg(address registry) internal view returns (RegSnapshot memory s) {
        ImplementationRegistry reg = ImplementationRegistry(registry);
        s.typeCount = reg.typeCount();
        bytes memory acc;
        for (uint256 i = 0; i < s.typeCount; ++i) {
            bytes32 tId = reg.typeIds(i);
            acc = abi.encode(acc, tId);
        }
        s.versionsHash = keccak256(acc);
    }

    function _requireRegSurvived(RegSnapshot memory pre, RegSnapshot memory post, string memory tag) internal pure {
        require(pre.typeCount == post.typeCount, string.concat(tag, ": Reg typeCount drifted"));
        require(pre.versionsHash == post.versionsHash, string.concat(tag, ": Reg typeIds drifted"));
    }

    /*──────── (b) M-08 against the just-upgraded PaymentManager beacon ────────*/
    /// @dev Fresh PM proxy on the upgraded beacon. Proves:
    ///      (1) a distribution created post-upgrade cannot finalize before
    ///          creationBlock + minClaimPeriodBlocks (even with a far-past checkpoint), then can
    ///          finalize exactly at the window;
    ///      (2) a pre-upgrade distribution (creationBlock == 0, emulated via vm.store) still
    ///          finalizes via the checkpointBlock fallback;
    ///      (3) L-19: an opted-out claimer can still claim already-allocated funds.
    function _assertM08_L18_L19(address pmBeacon) internal {
        address executor = makeAddr("ws-e-pm-exec");
        bytes memory init = abi.encodeWithSelector(PaymentManager.initialize.selector, executor, address(0xBEEF));
        PaymentManager pm = PaymentManager(payable(address(new BeaconProxy(pmBeacon, init))));
        vm.deal(address(pm), 100 ether);

        // (1) M-08: far-past checkpoint must NOT let finalize run early.
        vm.roll(vm.getBlockNumber() + 10_000);
        uint256 creation = vm.getBlockNumber();
        uint256 staleCheckpoint = creation - 9_000; // far in the past but valid (< block.number)
        uint256 minPeriod = 500;

        address alice = makeAddr("ws-e-alice");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(5 ether)))));
        vm.prank(executor);
        uint256 distId = pm.createDistribution(address(0), 5 ether, leaf, staleCheckpoint);

        // Just-before the creation window -> revert.
        vm.roll(creation + minPeriod - 1);
        bool reverted;
        vm.prank(executor);
        try pm.finalizeDistribution(distId, minPeriod) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == IPaymentManager.ClaimPeriodNotExpired.selector;
        }
        require(reverted, "M-08: finalize before creation window must revert");

        // Just-after -> success.
        vm.roll(creation + minPeriod);
        vm.prank(executor);
        pm.finalizeDistribution(distId, minPeriod);
        (,,,,, bool finalized) = pm.getDistribution(distId);
        require(finalized, "M-08: finalize at creation window must succeed");
        console.log("(b1) M-08 creation-anchored finalize window OK");

        // (2) BACKWARD-COMPAT: emulate a pre-upgrade distribution (creationBlock == 0).
        vm.roll(vm.getBlockNumber() + 1);
        uint256 legacyCheckpoint = vm.getBlockNumber() - 100;
        address bob = makeAddr("ws-e-bob");
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(3 ether)))));
        vm.prank(executor);
        uint256 legacyId = pm.createDistribution(address(0), 3 ether, leaf2, legacyCheckpoint);
        _zeroCreationBlock(address(pm), legacyId);

        uint256 fallbackAnchor = legacyCheckpoint + minPeriod;
        // Before fallback window -> revert.
        vm.roll(fallbackAnchor - 1);
        reverted = false;
        vm.prank(executor);
        try pm.finalizeDistribution(legacyId, minPeriod) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == IPaymentManager.ClaimPeriodNotExpired.selector;
        }
        require(reverted, "M-08: legacy finalize before checkpoint fallback must revert");
        // At fallback window -> success.
        vm.roll(fallbackAnchor);
        vm.prank(executor);
        pm.finalizeDistribution(legacyId, minPeriod);
        (,,,,, bool legacyFinalized) = pm.getDistribution(legacyId);
        require(legacyFinalized, "M-08: legacy distribution must finalize via checkpoint fallback");
        console.log("(b2) M-08 creationBlock==0 checkpoint fallback OK");

        // (3) L-19: opted-out claimer can still claim already-allocated funds.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 cp3 = vm.getBlockNumber() - 1;
        address carol = makeAddr("ws-e-carol");
        bytes32 leaf3 = keccak256(bytes.concat(keccak256(abi.encode(carol, uint256(2 ether)))));
        vm.prank(executor);
        uint256 d3 = pm.createDistribution(address(0), 2 ether, leaf3, cp3);
        vm.prank(carol);
        pm.optOut(true);
        require(pm.isOptedOut(carol), "L-19: opt-out flag must be recorded");
        bytes32[] memory proof = new bytes32[](0);
        uint256 balBefore = carol.balance;
        vm.prank(carol);
        pm.claimDistribution(d3, 2 ether, proof);
        require(carol.balance == balBefore + 2 ether, "L-19: opted-out claimer must still receive allocated funds");
        console.log("(b3) L-19 opt-out no longer blocks allocated claims OK");
    }

    /// @dev creationBlock is field index 7 within Distribution (payoutToken0, totalAmount1,
    ///      checkpointBlock2, merkleRoot3, totalClaimed4, finalized5, claimed-mapping6,
    ///      creationBlock7). distributions is Layout field index 2 (revenueShareToken0,
    ///      optedOut1, distributions2). Base slot = keccak(id, PM_STORAGE_SLOT+2).
    function _zeroCreationBlock(address pm, uint256 distId) internal {
        uint256 mappingSlot = uint256(PM_STORAGE_SLOT) + 2;
        uint256 base = uint256(keccak256(abi.encode(distId, mappingSlot)));
        vm.store(pm, bytes32(base + 7), bytes32(0));
    }

    /*──────── (c) L-16 against the just-upgraded EducationHub beacon ────────*/
    /// @dev Fresh EH proxy on the upgraded beacon. Proves setToken to a token whose
    ///      educationHub() != the hub reverts, and a correctly-wired token succeeds.
    function _assertL16(address ehBeacon) internal {
        address executor = makeAddr("ws-e-eh-exec");
        SimMockHats hats = new SimMockHats();
        SimMockPT initialToken = new SimMockPT();

        uint256[] memory creatorHats = new uint256[](0);
        uint256[] memory memberHats = new uint256[](0);
        bytes memory init = abi.encodeWithSelector(
            EducationHub.initialize.selector, address(initialToken), address(hats), executor, creatorHats, memberHats
        );
        EducationHub eh = EducationHub(address(new BeaconProxy(ehBeacon, init)));

        // (1) a token NOT wired to this hub must be rejected.
        SimMockPT unwired = new SimMockPT(); // educationHub() == address(0)
        bool reverted;
        vm.prank(executor);
        try eh.setToken(address(unwired)) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EducationHub.TokenNotWired.selector;
        }
        require(reverted, "L-16: setToken to a non-wired token must revert TokenNotWired");

        // (2) a token wired to a DIFFERENT hub must be rejected.
        SimMockPT wrong = new SimMockPT();
        wrong.setEducationHub(address(0xDEAD));
        reverted = false;
        vm.prank(executor);
        try eh.setToken(address(wrong)) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == EducationHub.TokenNotWired.selector;
        }
        require(reverted, "L-16: setToken to a mis-wired token must revert TokenNotWired");

        // (3) a correctly-wired token succeeds.
        SimMockPT wired = new SimMockPT();
        wired.setEducationHub(address(eh));
        vm.prank(executor);
        eh.setToken(address(wired));
        require(address(eh.token()) == address(wired), "L-16: setToken to a wired token must stick");
        console.log("(c) L-16 setToken minter-wiring check OK");
    }

    /*──────── (d) L-58 against the just-upgraded ImplementationRegistry beacon ────────*/
    /// @dev Fresh registry proxy on the upgraded beacon. Proves the FIRST register of a type sets
    ///      latest even with setLatest=false.
    function _assertL58(address regBeacon) internal {
        address owner = makeAddr("ws-e-reg-owner");
        bytes memory init = abi.encodeWithSelector(ImplementationRegistry.initialize.selector, owner);
        ImplementationRegistry reg = ImplementationRegistry(address(new BeaconProxy(regBeacon, init)));

        // First register with setLatest=false must still resolve via getLatestImplementation.
        vm.prank(owner);
        reg.registerImplementation("WSE_Type", "v1", address(0xABCD), false);
        require(
            reg.getLatestImplementation("WSE_Type") == address(0xABCD),
            "L-58: first register must set latest even with setLatest=false"
        );

        // A subsequent register with setLatest=false must NOT move latest.
        vm.prank(owner);
        reg.registerImplementation("WSE_Type", "v2", address(0xBEEF), false);
        require(
            reg.getLatestImplementation("WSE_Type") == address(0xABCD),
            "L-58: subsequent setLatest=false register must not move latest"
        );
        console.log("(d) L-58 first-register latest fix OK");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-E ops upgrade on Gnosis.
 *
 * LIVE ORG (Gnosis subgraph poa-gnosis-v-1, org "KUBI"):
 *   paymentManager 0x4009c825b38fb0ebb6391d5fabe4faf90e178df1
 *   educationHub   0x83c7aa49c0c5a55e22640ac164aba838e6f1f7ae
 * LIVE SINGLETON:
 *   ImplementationRegistry 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63
 */
contract SimGnosis is OpsUpgradeSimBase {
    address constant KUBI_PM = 0x4009c825b38Fb0ebB6391d5FABe4FAf90e178dF1;
    address constant KUBI_EH = 0x83C7Aa49C0C5a55E22640AC164abA838E6f1f7ae;
    address constant GNOSIS_REGISTRY = 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63;

    // Live Gnosis global beacons (PoaManager.getBeaconById, read 2026-07-04).
    address constant PM_BEACON = 0x720Da342dDB2cEE0dC288599dD3eAa76BD1D309B;
    address constant EH_BEACON = 0xB48B2df2a5D93Eef3900A8f4208D4980F0dCe2e5;
    address constant REG_BEACON = 0x1Db2a05A5E019300cD0dcba91185c488e3C01b4d;

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-E ops upgrade on Gnosis fork ===\n");

        PMSnapshot memory pmPre = _snapshotPM(KUBI_PM);
        EHSnapshot memory ehPre = _snapshotEH(KUBI_EH);
        RegSnapshot memory regPre = _snapshotReg(GNOSIS_REGISTRY);
        console.log("KUBI PM distributionCounter:", pmPre.distributionCounter);
        console.log("KUBI EH nextModuleId:", ehPre.nextModuleId);
        console.log("Gnosis registry typeCount:", regPre.typeCount);

        _upgradeOpsBeacons();

        _requirePMSurvived(pmPre, _snapshotPM(KUBI_PM), "KUBI-PM");
        _requireEHSurvived(ehPre, _snapshotEH(KUBI_EH), "KUBI-EH");
        _requireRegSurvived(regPre, _snapshotReg(GNOSIS_REGISTRY), "Gnosis-REG");
        console.log("(a) storage survived all three beacon upgrades OK");

        _assertM08_L18_L19(PM_BEACON);
        _assertL16(EH_BEACON);
        _assertL58(REG_BEACON);

        console.log("\nPASS: WS-E ops upgrade validated against live Gnosis state.");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                  SIM: ARBITRUM
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimArbitrum
 * @notice Arbitrum counterpart: upgrades all three beacons via the Hub-owned Arbitrum PoaManager
 *         (destination effect of upgradeBeaconCrossChain) and asserts storage survival on the live
 *         "Poa" org + the Arbitrum ImplementationRegistry singleton, plus M-08/L-18/L-19/L-16/L-58
 *         behavior on the upgraded beacons.
 *
 * LIVE ORG (Arbitrum subgraph poa-arb-v-1, org "Poa"):
 *   paymentManager 0xae470b8366af331f52d9ea26efd7cb2d276878b3
 *   educationHub   0xe37db8ccd295c9e4febb19a91efe13ace24ca596
 * LIVE SINGLETON:
 *   ImplementationRegistry 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9
 */
contract SimArbitrum is OpsUpgradeSimBase {
    address constant POA_PM = 0xAe470B8366AF331F52D9eA26efD7Cb2d276878B3;
    address constant POA_EH = 0xe37Db8cCD295C9E4fEbb19a91efe13aCe24ca596;
    address constant ARB_REGISTRY = 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9;

    // Live Arbitrum global beacons (PoaManager.getBeaconById, read 2026-07-04).
    address constant PM_BEACON = 0xA3e217aB718D6B657649200e0B2E2C6cbcE3Dc85;
    address constant EH_BEACON = 0x4c62D85098769578fF106Fd7Ef14c50F6D9EDE37;
    address constant REG_BEACON = 0xE9918784B0D7dAe8317E46FaD21c6E68bA1ec3Ea;

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-E ops upgrade on Arbitrum fork ===\n");

        PMSnapshot memory pmPre = _snapshotPM(POA_PM);
        EHSnapshot memory ehPre = _snapshotEH(POA_EH);
        RegSnapshot memory regPre = _snapshotReg(ARB_REGISTRY);
        console.log("Poa PM distributionCounter:", pmPre.distributionCounter);
        console.log("Poa EH nextModuleId:", ehPre.nextModuleId);
        console.log("Arb registry typeCount:", regPre.typeCount);

        _upgradeOpsBeacons();

        _requirePMSurvived(pmPre, _snapshotPM(POA_PM), "Poa-PM");
        _requireEHSurvived(ehPre, _snapshotEH(POA_EH), "Poa-EH");
        _requireRegSurvived(regPre, _snapshotReg(ARB_REGISTRY), "Arb-REG");
        console.log("(a) storage survived all three beacon upgrades OK");

        _assertM08_L18_L19(PM_BEACON);
        _assertL16(EH_BEACON);
        _assertL58(REG_BEACON);

        console.log("\nPASS: WS-E ops upgrade validated against live Arbitrum state.");
    }
}
