// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../src/PasskeyAccountFactory.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*
 * ============================================================================
 * Passkey recovery security remediation upgrade — WS-G
 * PasskeyAccount + PasskeyAccountFactory beacon upgrades (audit H-04, M-06)
 * ============================================================================
 *
 * SRC FIXES SHIPPED (both ride their global beacons):
 *   H-04 (#177) — single global guardian was a SPOF. PasskeyAccount now implements FULL M-of-N
 *          threshold multi-guardian recovery. The ERC-7201 Layout APPENDS a per-account guardian
 *          set (address[] guardians + isGuardianMap), a uint256 recoveryThreshold, and per-proposal
 *          approval accounting. Owner self-calls manage the set: addGuardian / removeGuardian /
 *          setRecoveryThreshold (zero/dup checks; threshold <= guardian count invariant; removing a
 *          guardian auto-lowers an over-large threshold). Recovery is now two-phase: guardians call
 *          approveRecovery(credId,x,y); only once `recoveryThreshold` DISTINCT guardians approve the
 *          same proposal is the request STAGED (delay timer started). completeRecovery + cancelRecovery
 *          + the existing time delay are retained. A guardian cannot approve twice to fake quorum.
 *          The legacy single-guardian path is REMOVED/inert: setGuardian and the guardian-only
 *          initiateRecovery are gone; the onlyGuardian modifier now checks the M-of-N set. The legacy
 *          `guardian` storage field is retained (append-only) but grants NO recovery power.
 *   H-04 hardening — the staged recovery public key is validated on-curve via
 *          P256Verifier.isValidPublicKey(x,y) before staging (reverts InvalidPublicKey off-curve).
 *   M-06 — the counterfactual account address must NOT depend on mutable factory config. The
 *          factory NO LONGER bakes config.poaGuardian / config.recoveryDelay into the BeaconProxy
 *          init calldata (the CREATE2 preimage). PasskeyAccount.initialize dropped those two params:
 *          new signature is initialize(factory, credentialId, pubKeyX, pubKeyY). getAddress /
 *          createAccount build identical init data, so getAddress is a pure function of
 *          (credentialId, x, y, salt) + the immutable factory/beacon. Accounts initialize with NO
 *          guardian/delay baked in; recovery config is set per-account, lazily.
 *
 * LEGACY / IN-FLIGHT ACCOUNT BEHAVIOR (append-only correctness):
 *   Existing deployed accounts read the appended slots as ZERO — guardians == [] and
 *   recoveryThreshold == 0. By design that means recovery is DISABLED (no quorum can be reached)
 *   until the account owner configures a guardian set + threshold via owner self-calls. This is the
 *   safe meaning: the old single global guardian can no longer unilaterally recover (SPOF closed),
 *   and the inert legacy `guardian` field is not a bypass. Owners opt back into recovery explicitly.
 *
 * STORAGE:
 *   PasskeyAccount — APPENDS `address[] guardians`, `mapping isGuardianMap`, `uint256
 *     recoveryThreshold`, `mapping recoveryApprovals`, `mapping recoveryApprovedBy` to the END of
 *     its ERC-7201 Layout (slot keccak256("poa.passkeyaccount.storage")). Existing proxies read them
 *     as empty/zero. The legacy prefix (factory, credentials, credentialIds, guardian, recoveryDelay,
 *     recoveryRequests, pendingRecoveryIds) is byte-identical to baseline.
 *   PasskeyAccountFactory — NO storage changes (logic-only M-06 fix to init-calldata construction).
 *   Storage survival on a fresh account minted through the LIVE beacon/factory is asserted in the
 *   sims below (no pre-existing on-fork account is required).
 *
 * WHERE THE FACTORY IS REFERENCED (M-06 coordination):
 *   The universal PasskeyAccountFactory is a beacon-upgradeable singleton, referenced by QuickJoin
 *   (universalFactory) and UniversalAccountRegistry (passkeyFactory) purely by ADDRESS. Both the
 *   factory and the account are upgraded IN PLACE via their global beacons — the factory proxy
 *   address does NOT change, so NO re-point of QuickJoin / UniversalAccountRegistry is required.
 *   No files outside WS-G are touched by this remediation.
 *
 * ── VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer is CREATE3 → a given (type, version) is the SAME address on both chains.
 *
 *   PasskeyAccount:        registry count gnosis=1 arbitrum=1. v1 registered on both.
 *     v2 FREE on BOTH (registry=no create2=no) ⇒ pick v2 (0xC16FCdFD434e333A6C53d7212531c5Bd55E5aD52)
 *     (v3 is rejected: its CREATE2 slot is occupied on Gnosis — the classic old-slot collision.)
 *   PasskeyAccountFactory: registry count gnosis=1 arbitrum=1. v1 registered on both.
 *     v2 FREE on BOTH ⇒ pick v2 (0xf281151f969265A01754F136813160856408037D)
 *     (v3 also has a Gnosis CREATE2 collision.)
 *
 * ── BROADCAST ORDER (do NOT run in this workstream) ──
 *   1. Step1_DeployOnGnosis      --rpc-url gnosis   --broadcast --slow  (DD-deploy 2 impls on Gnosis)
 *   2. Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow  (DD-deploy on Arbitrum +
 *        Hub.upgradeBeaconCrossChain for both → Arbitrum local + Gnosis cross-chain dispatch)
 *   3. Step2b_UpgradeGnosis      --rpc-url gnosis   --broadcast --slow  (Satellite.upgradeBeaconDirect
 *        for both — destination-chain path, skips the ~5-min Hyperlane wait)
 *   4. Step3_Verify              --rpc-url gnosis / --rpc-url arbitrum  (read-only PASS check)
 *
 * ── SIMS (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradePasskeyRecoverySecurity.s.sol:SimGnosis  --fork-url gnosis  -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradePasskeyRecoverySecurity.s.sol:SimArbitrum --fork-url arbitrum -vvv
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

string constant ACCT_VERSION = "v2";
string constant FACTORY_VERSION = "v2";

// Real on-curve NIST P-256 public key (recovery now requires isValidPublicKey).
bytes32 constant CURVE_X = 0x1ccbe91c075fc7f4f033bfa248db8fccd3565de94bbfb12f3c59ff46c271bf83;
bytes32 constant CURVE_Y = 0xce4014c68811f9a21a1fdb2c0e6113e06db7ca93b7404e78dc7ccd5ca89a4ca9;

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

/// @title Step1_DeployOnGnosis — deploy the two impls on Gnosis via DD (idempotent).
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 1: Deploy passkey-fix impls on Gnosis ===");
        vm.startBroadcast(key);
        _deploy(dd, "PasskeyAccount", ACCT_VERSION, type(PasskeyAccount).creationCode);
        _deploy(dd, "PasskeyAccountFactory", FACTORY_VERSION, type(PasskeyAccountFactory).creationCode);
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

/// @title Step2_UpgradeFromArbitrum — DD-deploy on Arbitrum + upgrade both beacons
///        Arbitrum-local AND cross-chain-dispatch to Gnosis via the Hub.
contract Step2_UpgradeFromArbitrum is Script {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        require(hub.owner() == vm.addr(key), "Step2: signer must own Hub");
        console.log("\n=== Step 2: Upgrade from Arbitrum (local + cross-chain to Gnosis) ===");
        vm.startBroadcast(key);
        _upgrade(hub, dd, "PasskeyAccount", ACCT_VERSION, type(PasskeyAccount).creationCode);
        _upgrade(hub, dd, "PasskeyAccountFactory", FACTORY_VERSION, type(PasskeyAccountFactory).creationCode);
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
        _upgrade(dd, "PasskeyAccount", ACCT_VERSION);
        _upgrade(dd, "PasskeyAccountFactory", FACTORY_VERSION);
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
        address poaManager;
        try PoaManagerHub(payable(HUB)).poaManager() returns (PoaManager pm) {
            poaManager = address(pm); // Arbitrum
        } catch {
            poaManager = GNOSIS_POA_MANAGER; // Gnosis
        }
        console.log("\n=== Step 3: Verify passkey beacons ===");
        _verify(dd, poaManager, "PasskeyAccount", ACCT_VERSION);
        _verify(dd, poaManager, "PasskeyAccountFactory", FACTORY_VERSION);
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

/// @dev Snapshot of a passkey account's readable state, captured pre-upgrade / re-checked post.
struct AccountSnapshot {
    address factory;
    address legacyGuardian;
    uint48 recoveryDelay;
    uint256 credCount;
    bytes32 firstCredId;
    bytes32 firstCredX;
    bytes32 firstCredY;
}

abstract contract PasskeyUpgradeSimBase is Script {
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

    function _upgradeAccountBeacon() internal returns (address impl) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        impl = _deployAndUpgrade(dd, "PasskeyAccount", ACCT_VERSION, type(PasskeyAccount).creationCode);
    }

    function _upgradeFactoryBeacon() internal returns (address impl) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        impl = _deployAndUpgrade(dd, "PasskeyAccountFactory", FACTORY_VERSION, type(PasskeyAccountFactory).creationCode);
    }

    /*──────── storage survival ────────*/
    function _snapshotAccount(address account) internal view returns (AccountSnapshot memory s) {
        PasskeyAccount a = PasskeyAccount(payable(account));
        s.factory = a.factory();
        s.legacyGuardian = a.guardian();
        s.recoveryDelay = a.recoveryDelay();
        bytes32[] memory ids = a.getCredentialIds();
        s.credCount = ids.length;
        if (ids.length > 0) {
            s.firstCredId = ids[0];
            IPasskeyAccount.PasskeyCredential memory c = a.getCredential(ids[0]);
            s.firstCredX = c.publicKeyX;
            s.firstCredY = c.publicKeyY;
        }
    }

    function _requireAccountSurvived(AccountSnapshot memory pre, AccountSnapshot memory post) internal pure {
        require(pre.factory == post.factory, "survival: factory drifted");
        require(pre.legacyGuardian == post.legacyGuardian, "survival: legacy guardian drifted");
        require(pre.recoveryDelay == post.recoveryDelay, "survival: recoveryDelay drifted");
        require(pre.credCount == post.credCount, "survival: credCount drifted");
        require(pre.firstCredId == post.firstCredId, "survival: credId drifted");
        require(pre.firstCredX == post.firstCredX, "survival: credX drifted");
        require(pre.firstCredY == post.firstCredY, "survival: credY drifted");
    }

    /*──────── (a) storage survival on a fresh account minted through the LIVE beacon/factory ────────*/
    /// @dev Deploy an account through the CURRENTLY-LIVE factory (old bytecode: guardian baked in),
    ///      snapshot it, upgrade the ACCOUNT beacon to v2, then assert credential/factory/legacy
    ///      guardian survive and the appended M-of-N fields read as DISABLED (legacy behavior).
    function _assertStorageSurvival(address factoryProxy) internal returns (address account) {
        bytes32 credId = keccak256("ws-g-survival-cred");
        vm.prank(HUDSON_ADMIN);
        account = PasskeyAccountFactory(factoryProxy).createAccount(credId, CURVE_X, CURVE_Y, 12_345);
        require(account.code.length > 0, "survival: account not deployed through live factory");

        AccountSnapshot memory pre = _snapshotAccount(account);
        require(pre.credCount == 1, "survival: fresh account should have 1 credential");

        _upgradeAccountBeacon();

        AccountSnapshot memory post = _snapshotAccount(account);
        _requireAccountSurvived(pre, post);

        // Legacy-account behavior: appended M-of-N fields read as empty ⇒ recovery DISABLED.
        PasskeyAccount a = PasskeyAccount(payable(account));
        require(a.getGuardians().length == 0, "survival: legacy account must read empty guardian set");
        require(a.recoveryThreshold() == 0, "survival: legacy account threshold must be 0 (disabled)");
        // Even a would-be guardian cannot start recovery until the owner opts in.
        vm.prank(HUDSON_ADMIN);
        try a.approveRecovery(keccak256("x"), CURVE_X, CURVE_Y) {
            revert("survival: recovery must be DISABLED on legacy account");
        } catch (bytes memory reason) {
            require(
                bytes4(reason) == IPasskeyAccount.NotAGuardian.selector, "survival: expected NotAGuardian (disabled)"
            );
        }
        console.log("(a) fresh-account storage survived account-beacon upgrade; recovery starts DISABLED OK");
    }

    /*──────── (b) H-04 M-of-N on a fresh account against the upgraded account beacon ────────*/
    /// @dev Deploys a fresh account proxy directly on the upgraded ACCOUNT beacon (new bytecode),
    ///      configures 2-of-3, and proves: a single approval cannot complete; two distinct can stage
    ///      then finalize after the delay; a guardian cannot approve twice to fake quorum.
    function _assertH04(address acctBeacon) internal {
        bytes32 initCred = keccak256("ws-g-h04-init");
        // Factory placeholder: any EOA works — the account only calls getGlobalConfig() on it and
        // falls back to MAX_CREDENTIALS on revert. (address(this) is disallowed in forge scripts.)
        bytes memory init =
            abi.encodeWithSelector(PasskeyAccount.initialize.selector, HUDSON_ADMIN, initCred, CURVE_X, CURVE_Y);
        PasskeyAccount a = PasskeyAccount(payable(address(new BeaconProxy(acctBeacon, init))));

        address gA = makeAddr("ws-g-guardianA");
        address gB = makeAddr("ws-g-guardianB");
        address gC = makeAddr("ws-g-guardianC");

        // Configure 2-of-3 via self-calls.
        vm.startPrank(address(a));
        a.addGuardian(gA);
        a.addGuardian(gB);
        a.addGuardian(gC);
        a.setRecoveryThreshold(2);
        vm.stopPrank();
        require(a.recoveryThreshold() == 2, "H-04: threshold not set");
        require(a.getGuardians().length == 3, "H-04: guardian count wrong");

        bytes32 recCred = keccak256("ws-g-h04-recovery");
        bytes32 proposalId = a.computeRecoveryProposalId(recCred, CURVE_X, CURVE_Y);

        // (b1) single guardian approval must NOT stage the recovery.
        vm.prank(gA);
        a.approveRecovery(recCred, CURVE_X, CURVE_Y);
        require(a.recoveryApprovalCount(proposalId) == 1, "H-04: single approval count wrong");
        bytes32 wouldBeId = keccak256(abi.encodePacked(proposalId, vm.getBlockTimestamp()));
        require(a.getRecoveryRequest(wouldBeId).executeAfter == 0, "H-04: single approval must not stage");
        console.log("(b1) single guardian approval does not stage recovery OK");

        // (b2) same guardian cannot approve twice to fake quorum.
        vm.prank(gA);
        bool reverted;
        try a.approveRecovery(recCred, CURVE_X, CURVE_Y) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == IPasskeyAccount.AlreadyApproved.selector;
        }
        require(reverted, "H-04: double approval by same guardian must revert AlreadyApproved");
        require(a.recoveryApprovalCount(proposalId) == 1, "H-04: double approval must not increment");
        console.log("(b2) guardian cannot approve twice to fake quorum OK");

        // (b3) a SECOND distinct guardian reaches quorum and stages the recovery.
        vm.prank(gB);
        a.approveRecovery(recCred, CURVE_X, CURVE_Y);
        bytes32 recoveryId = keccak256(abi.encodePacked(proposalId, vm.getBlockTimestamp()));
        require(a.getRecoveryRequest(recoveryId).executeAfter > 0, "H-04: quorum must stage recovery");
        // Approvals reset after staging.
        require(a.recoveryApprovalCount(proposalId) == 0, "H-04: approvals must reset after staging");
        console.log("(b3) two distinct guardians stage the recovery OK");

        // (b4) cannot complete before delay; after delay it finalizes.
        reverted = false;
        try a.completeRecovery(recoveryId) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == IPasskeyAccount.RecoveryDelayNotPassed.selector;
        }
        require(reverted, "H-04: completing before delay must revert");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        a.completeRecovery(recoveryId);
        IPasskeyAccount.PasskeyCredential memory nc = a.getCredential(recCred);
        require(nc.publicKeyX == CURVE_X && nc.publicKeyY == CURVE_Y && nc.active, "H-04: recovery credential not set");
        console.log("(b4) after delay the quorum recovery finalizes OK");
    }

    /*──────── (c) H-04 hardening: off-curve recovery key reverts ────────*/
    function _assertOnCurveHardening(address acctBeacon) internal {
        bytes32 initCred = keccak256("ws-g-curve-init");
        bytes memory init =
            abi.encodeWithSelector(PasskeyAccount.initialize.selector, HUDSON_ADMIN, initCred, CURVE_X, CURVE_Y);
        PasskeyAccount a = PasskeyAccount(payable(address(new BeaconProxy(acctBeacon, init))));

        address gA = makeAddr("ws-g-curve-gA");
        address gB = makeAddr("ws-g-curve-gB");
        vm.startPrank(address(a));
        a.addGuardian(gA);
        a.addGuardian(gB);
        a.setRecoveryThreshold(1);
        vm.stopPrank();

        // keccak-derived coordinates are (almost surely) not on the P-256 curve.
        bool reverted;
        vm.prank(gA);
        try a.approveRecovery(keccak256("off_cred"), keccak256("off_x"), keccak256("off_y")) {}
        catch (bytes memory reason) {
            reverted = bytes4(reason) == IPasskeyAccount.InvalidPublicKey.selector;
        }
        require(reverted, "hardening: off-curve recovery key must revert InvalidPublicKey");
        console.log("(c) off-curve recovery public key is rejected OK");
    }

    /*──────── (d) M-06: getAddress is independent of mutable factory config ────────*/
    /// @dev Upgrade the FACTORY beacon to v2, then prove getAddress(credId,x,y,salt) is byte-identical
    ///      before and after a change to the factory's guardian AND recovery-delay config.
    function _assertM06(address factoryProxy) internal {
        _upgradeFactoryBeacon();
        PasskeyAccountFactory f = PasskeyAccountFactory(factoryProxy);

        bytes32 credId = keccak256("ws-g-m06-cred");
        address before = f.getAddress(credId, CURVE_X, CURVE_Y, 777);

        // Mutate the factory's mutable global config (guardian + delay) as the PoaManager.
        address poaMgr = f.poaManager();
        vm.startPrank(poaMgr);
        f.setPoaGuardian(makeAddr("ws-g-new-guardian"));
        f.setRecoveryDelay(uint48(30 days));
        vm.stopPrank();

        address afterAddr = f.getAddress(credId, CURVE_X, CURVE_Y, 777);
        require(before == afterAddr, "M-06: getAddress must not depend on mutable factory config");

        // And a freshly-created account still lands at the pre-change predicted address.
        vm.prank(HUDSON_ADMIN);
        address created = f.createAccount(credId, CURVE_X, CURVE_Y, 777);
        require(created == before, "M-06: createAccount must match config-independent getAddress");
        console.log("(d) getAddress is byte-identical across guardian/delay config changes OK");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-G passkey upgrade on Gnosis.
 *
 * LIVE universal PasskeyAccountFactory proxy (Gnosis): 0x6B5E116688A0903a80d9eb9E0CbBDbd3aD3ce025
 *   (read from KUBI QuickJoin.universalFactory, 2026-07-04)
 * LIVE account beacon (PoaManager.getBeaconById(PasskeyAccount)): 0x2AED32b1f3D297669aB547beafdC58F67FA0DE8c
 */
contract SimGnosis is PasskeyUpgradeSimBase {
    address constant GNOSIS_FACTORY = 0x6B5E116688A0903a80d9eb9E0CbBDbd3aD3ce025;
    address constant GNOSIS_ACCT_BEACON = 0x2AED32b1f3D297669aB547beafdC58F67FA0DE8c;

    function _poaManager() internal pure override returns (address) {
        return GNOSIS_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-G passkey upgrade on Gnosis fork ===\n");
        vm.deal(HUDSON_ADMIN, 1 ether);

        // (a) storage survival: mint a fresh account through the LIVE factory, upgrade account beacon.
        _assertStorageSurvival(GNOSIS_FACTORY);

        // (b) H-04 M-of-N behavior against the upgraded account beacon.
        _assertH04(GNOSIS_ACCT_BEACON);

        // (c) H-04 hardening: off-curve recovery key rejected.
        _assertOnCurveHardening(GNOSIS_ACCT_BEACON);

        // (d) M-06: getAddress independent of mutable factory config (upgrades factory beacon).
        _assertM06(GNOSIS_FACTORY);

        console.log("\nPASS: WS-G passkey upgrade validated against live Gnosis state.");
    }
}

/*═══════════════════════════════════════════════════════════════════════════
                                  SIM: ARBITRUM
═══════════════════════════════════════════════════════════════════════════*/

/**
 * @title SimArbitrum
 * @notice Arbitrum counterpart: upgrades both beacons via the Hub-owned Arbitrum PoaManager
 *         (destination effect of upgradeBeaconCrossChain) and asserts storage survival + H-04 + M-06.
 *
 * LIVE universal PasskeyAccountFactory proxy (Arbitrum): 0xbd3DE10FD95F398e8a02c98c4026d6f5661CdbE5
 *   (read from Poa-org QuickJoin.universalFactory, 2026-07-04)
 * LIVE account beacon (PoaManager.getBeaconById(PasskeyAccount)): 0xBF54737C86bd3C17a502447e736fc49741fe02a0
 */
contract SimArbitrum is PasskeyUpgradeSimBase {
    address constant ARB_FACTORY = 0xbd3DE10FD95F398e8a02c98c4026d6f5661CdbE5;
    address constant ARB_ACCT_BEACON = 0xBF54737C86bd3C17a502447e736fc49741fe02a0;

    function _poaManager() internal pure override returns (address) {
        return ARB_POA_MANAGER;
    }

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal override {
        vm.deal(HUDSON_ADMIN, 1 ether);
        vm.prank(HUDSON_ADMIN);
        PoaManagerHub(payable(HUB)).upgradeBeaconCrossChain{value: HYPERLANE_FEE}(typeName, newImpl, version);
    }

    function run() public {
        console.log("\n=== SIM: WS-G passkey upgrade on Arbitrum fork ===\n");
        vm.deal(HUDSON_ADMIN, 2 ether);

        // (a) storage survival: mint a fresh account through the LIVE factory, upgrade account beacon.
        _assertStorageSurvival(ARB_FACTORY);

        // (b) H-04 M-of-N behavior against the upgraded account beacon.
        _assertH04(ARB_ACCT_BEACON);

        // (c) H-04 hardening: off-curve recovery key rejected.
        _assertOnCurveHardening(ARB_ACCT_BEACON);

        // (d) M-06: getAddress independent of mutable factory config (upgrades factory beacon).
        _assertM06(ARB_FACTORY);

        console.log("\nPASS: WS-G passkey upgrade validated against live Arbitrum state.");
    }
}
