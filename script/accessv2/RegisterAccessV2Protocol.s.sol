// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MembershipAuthority} from "../../src/MembershipAuthority.sol";
import {AuthorityRouter} from "../../src/AuthorityRouter.sol";
import {IAuthorityRouter} from "../../src/interfaces/IAuthorityRouter.sol";
import {CutoverVerifier} from "../../src/CutoverVerifier.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * Register the Access-v2 protocol pieces — PER-CHAIN, LOCAL (SPEC §6 step 0 / 0.5)
 * ============================================================================
 *
 * Stands up the NEW chain-wide Access-v2 protocol surface so per-org migration
 * (a later wave) can bind authorities and repoint modules. Runs LOCALLY on each
 * chain via the destination-chain admin path (Satellite on Gnosis, Hub on Arbitrum) —
 * never the Hyperlane cross-chain path (avoids the relayer beacon-deploy gas limit and
 * the 0.005 ETH fee; same destination effect). Both admin owners are Hudson (0xA6F4…b2c9).
 *
 * On-chain effects per chain (ACCESS-V2-SPEC.md §6 step 0 items + step 0.5):
 *
 *   1. addContractType("MembershipAuthority", maImpl) — deploys the global UpgradeableBeacon
 *      and auto-registers "v1" (the per-org authority BeaconProxy impl; §6 step-0 item). maImpl is
 *      CREATE3-deployed; its external delegatecall libraries (MembershipAuthorityLogic /
 *      MembershipAuthoritySeed / EligibilityLogic) are auto-deployed+linked by forge, exactly like
 *      the PaymasterHub-with-libs precedent (UpgradePaymasterSecurity Step1).
 *   2. addContractType("AuthorityRouter", routerImpl) — registers the router IMPL for provenance
 *      (§6 step-0 item 1). The router is NOT a per-org BeaconProxy; the registered beacon is pure
 *      provenance (never used to mint instances).
 *   3. Deploy the AuthorityRouter SINGLETON (ERC1967Proxy over routerImpl, initialize(hats,
 *      orgRegistry, paymasterHub, admin=Hudson)) — §6 step-0 item 6: ZERO bindings at birth (pure
 *      passthrough to real Hats). CREATE3-deployed at the same address on both chains for a stable
 *      downstream reference (per-org cutover binds through it).
 *   4. upgradeBeacon("PaymasterHub", pmV20Impl, "v20") — the hub impl that CARRIES setHats + the
 *      type-keyed global rulebook (the live hub is still v19: getGlobalRuleCount reverts, no setHats
 *      wiring). Beacon upgrade is storage-preserving; asserted below on a live funded org.
 *   5. setHats(router) — §6 step 0.5, the one-time per-chain hub repoint (poaManager-gated, routed
 *      through Satellite/Hub adminCall). The router's UNBOUND legacy-id passthrough goes straight to
 *      real Hats, so this is BEHAVIOR-NEUTRAL for every unmigrated org — hard-asserted in the sim
 *      (a live hats read THROUGH the router equals the direct Hats read for a real org wearer).
 *   6. upgradeBeacon("OrgRegistry", orgRegV2Impl, "v2") + OrgRegistry.setHats(router) — the SECOND
 *      chain-wide reader. `updateOrgMetaAsAdmin` authorizes against `l.hats`, which was writable only
 *      at initialize; new-style orgs seed a metadata-admin SUBJECT id (< 2^224) that real Hats always
 *      resolves to balance 0, so that path is dead for them until the registry reads through the
 *      router too. v2 adds the poaManager/owner-gated `setHats`. Behaviour-neutral for legacy orgs —
 *      hard-asserted in the sims with a live `updateOrgMetaAsAdmin` by a REAL metadata-admin wearer.
 *
 * Version selection (dual-surface probed FREE on BOTH chains by the orchestrator, waveD-recon.md;
 * re-asserted cheaply in the sims rather than re-probed):
 *   MembershipAuthority "v1" — fresh type (registry count 0 both chains)
 *   AuthorityRouter     "v1" — fresh type
 *   PaymasterHub        "v20" — registry FREE + CREATE3 FREE (live is v19)
 *   OrgRegistry         "v2"  — registry FREE + CREATE3 FREE on BOTH chains (live is v1; probed
 *                               2026-08 — getVersionCount == 1, CREATE3 slot
 *                               0x72b453a3a8Bc71Dc1Ebc558014c08B6485824267 empty on both)
 *
 * Usage:
 *   # Sims (BOTH under production profile — broadcast uses production bytecode):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:SimGnosis  --fork-url gnosis-gateway -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:SimArbitrum --fork-url arbitrum     -vvv
 *
 *   # Broadcast (per chain: deploy impls, then register+wire+repoint):
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:Step1_DeployImplsGnosis      --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:Step2_RegisterAndWireGnosis  --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:Step1b_DeployImplsArbitrum   --rpc-url arbitrum --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/RegisterAccessV2Protocol.s.sol:Step2b_RegisterAndWireArbitrum --rpc-url arbitrum --broadcast --slow
 * ============================================================================
 */

interface IPoaManagerView {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IImplRegistryView {
    function getImplementation(string calldata typeName, string calldata version) external view returns (address);
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

interface IHatsView {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
    // Real Hats v1 has NO getWearerStatus(address,uint256) selector — the router COMPOSES it from
    // isEligible + isInGoodStanding, so the neutrality check composes the same way for its comparison.
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
    function isInGoodStanding(address wearer, uint256 hatId) external view returns (bool);
}

interface IPaymasterView {
    function HATS() external view returns (address);
}

abstract contract AccessV2RegisterBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137; // Hats v1, same address both chains

    // Arbitrum (home / hub)
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant ARB_PAYMASTER = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;
    address internal constant ARB_ORG_REGISTRY = 0x7B023B9566b96616D54935AE8De80579c93f62aC;
    address internal constant ARB_REGISTRY = 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9; // ImplementationRegistry

    // Gnosis (satellite)
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant GNOSIS_ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    address internal constant GNOSIS_REGISTRY = 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63; // ImplementationRegistry

    // addContractType hardcodes "v1" for a fresh type; PaymasterHub is an existing type → explicit version.
    string internal constant MA_VERSION = "v1";
    string internal constant ROUTER_VERSION = "v1";
    string internal constant PM_VERSION = "v20";
    string internal constant ORG_REGISTRY_VERSION = "v2";
    // Router singleton (ERC1967Proxy) CREATE3 salt — its own (typeName,version) namespace, distinct
    // from the router IMPL type. CREATE3 ignores initcode, so the same address lands on both chains
    // even though each chain's init data differs (orgRegistry / paymasterHub).
    string internal constant ROUTER_SINGLETON_TYPE = "AuthorityRouterProxy";
    string internal constant ROUTER_SINGLETON_VERSION = "v1";
    // CutoverVerifier — stateless per-chain singleton (immutable hats + orgRegistry baked in). Its own
    // (typeName,version) CREATE3 namespace; deterministic address is chain-independent (salt-only) even
    // though each chain's constructor pins that chain's orgRegistry.
    string internal constant CUTOVER_VERIFIER_TYPE = "CutoverVerifier";
    string internal constant CUTOVER_VERIFIER_VERSION = "v1";

    bytes32 internal constant MEMBERSHIP_AUTHORITY_ID = keccak256("MembershipAuthority");
    bytes32 internal constant AUTHORITY_ROUTER_ID = keccak256("AuthorityRouter");
    bytes32 internal constant CUTOVER_VERIFIER_ID = keccak256("CutoverVerifier");
    bytes32 internal constant PAYMASTER_HUB_ID = keccak256("PaymasterHub");
    bytes32 internal constant ORG_REGISTRY_ID = keccak256("OrgRegistry");

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

    /// @dev The predicted router-singleton address (deterministic, chain-independent).
    function _routerSingletonAddress() internal view returns (address) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        return dd.computeAddress(dd.computeSalt(ROUTER_SINGLETON_TYPE, ROUTER_SINGLETON_VERSION));
    }

    /// @dev The predicted CutoverVerifier address (deterministic, chain-independent — salt-only).
    function _cutoverVerifierAddress() internal view returns (address) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        return dd.computeAddress(dd.computeSalt(CUTOVER_VERIFIER_TYPE, CUTOVER_VERIFIER_VERSION));
    }

    /// @dev CREATE3-deploy (idempotently) the CutoverVerifier for this chain, pinning `hats` (canonical)
    ///      + this chain's `orgRegistry` + `paymasterHub` as immutables (the hub pin makes the router
    ///      canonicality check on-chain).
    function _deployCutoverVerifier(address orgRegistry, address paymasterHub) internal returns (address verifier) {
        bytes memory code =
            abi.encodePacked(type(CutoverVerifier).creationCode, abi.encode(HATS, orgRegistry, paymasterHub));
        verifier = _ddDeploy(CUTOVER_VERIFIER_TYPE, CUTOVER_VERIFIER_VERSION, code);
    }

    /// @dev Deploy (idempotently) the AuthorityRouter singleton ERC1967Proxy at its CREATE3 address,
    ///      initialized with this chain's (hats, orgRegistry, paymasterHub, admin=Hudson).
    function _deployRouterSingleton(address routerImpl, address orgRegistry, address paymasterHub)
        internal
        returns (address proxy)
    {
        bytes memory initData = abi.encodeCall(AuthorityRouter.initialize, (HATS, orgRegistry, paymasterHub, HUDSON));
        bytes memory code = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(routerImpl, initData));
        proxy = _ddDeploy(ROUTER_SINGLETON_TYPE, ROUTER_SINGLETON_VERSION, code);
    }

    /// @dev CREATE3-deploy the four impls (MembershipAuthority + AuthorityRouter + PaymasterHub v20
    ///      + OrgRegistry v2).
    /// @dev PREDICT the four impl addresses and REQUIRE code — the Step2 pre-broadcast check. Never
    ///      calls the deploying path: a missing artifact must fail with THIS message, not with the
    ///      DD owner-gate revert from an unpranked deploy in forge's simulation (the exact foot-gun
    ///      hit when Step1 is run without --broadcast: a dry-run prints success and deploys nothing).
    function _requireImpls()
        internal
        view
        returns (address maImpl, address routerImpl, address pmImpl, address orgRegImpl)
    {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        maImpl = dd.computeAddress(dd.computeSalt("MembershipAuthority", MA_VERSION));
        routerImpl = dd.computeAddress(dd.computeSalt("AuthorityRouter", ROUTER_VERSION));
        pmImpl = dd.computeAddress(dd.computeSalt("PaymasterHub", PM_VERSION));
        orgRegImpl = dd.computeAddress(dd.computeSalt("OrgRegistry", ORG_REGISTRY_VERSION));
        require(
            maImpl.code.length > 0 && routerImpl.code.length > 0 && pmImpl.code.length > 0
                && orgRegImpl.code.length > 0,
            "impls missing on-chain: run Step1 WITH --broadcast first (a dry-run deploys nothing)"
        );
    }

    function _deployImpls() internal returns (address maImpl, address routerImpl, address pmImpl, address orgRegImpl) {
        maImpl = _ddDeploy("MembershipAuthority", MA_VERSION, type(MembershipAuthority).creationCode);
        routerImpl = _ddDeploy("AuthorityRouter", ROUTER_VERSION, type(AuthorityRouter).creationCode);
        pmImpl = _ddDeploy("PaymasterHub", PM_VERSION, type(PaymasterHub).creationCode);
        orgRegImpl = _ddDeploy("OrgRegistry", ORG_REGISTRY_VERSION, type(OrgRegistry).creationCode);
        require(pmImpl.code.length <= 24576, "PaymasterHub v20 impl exceeds EIP-170");
        require(orgRegImpl.code.length <= 24576, "OrgRegistry v2 impl exceeds EIP-170");
    }

    /// @dev getBeaconById REVERTS TypeUnknown() for an unregistered type; treat that as "not registered".
    function _beacon(address poaManager, bytes32 typeId) internal view returns (address) {
        try IPoaManagerView(poaManager).getBeaconById(typeId) returns (address b) {
            return b;
        } catch {
            return address(0);
        }
    }

    /// @dev A registry (typeName,version) is FREE iff getImplementation reverts VersionUnknown.
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

    function _setHatsCalldata(address router) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setHats(address)", router);
    }

    /// @dev The full Gnosis register+wire batch (Satellite-local). Caller must be the Satellite owner.
    ///      The OrgRegistry beacon upgrade MUST precede its repoint — `setHats` ships in v2.
    function _registerAndWireGnosis(address maImpl, address routerImpl, address pmImpl, address orgRegImpl)
        internal
        returns (address routerProxy)
    {
        ISatelliteAdmin sat = ISatelliteAdmin(GNOSIS_SATELLITE);
        sat.addContractType("MembershipAuthority", maImpl);
        sat.addContractType("AuthorityRouter", routerImpl);
        sat.addContractType("CutoverVerifier", _deployCutoverVerifier(GNOSIS_ORG_REGISTRY, GNOSIS_PAYMASTER));
        routerProxy = _deployRouterSingleton(routerImpl, GNOSIS_ORG_REGISTRY, GNOSIS_PAYMASTER);
        sat.upgradeBeaconDirect("PaymasterHub", pmImpl, PM_VERSION);
        sat.adminCall(GNOSIS_PAYMASTER, _setHatsCalldata(routerProxy));
        sat.upgradeBeaconDirect("OrgRegistry", orgRegImpl, ORG_REGISTRY_VERSION);
        sat.adminCall(GNOSIS_ORG_REGISTRY, _setHatsCalldata(routerProxy));
    }

    /// @dev The full Arbitrum register+wire batch (Hub-local). Caller must be the Hub owner.
    function _registerAndWireArbitrum(address maImpl, address routerImpl, address pmImpl, address orgRegImpl)
        internal
        returns (address routerProxy)
    {
        IHubAdmin hub = IHubAdmin(ARB_HUB);
        hub.addContractType("MembershipAuthority", maImpl);
        hub.addContractType("AuthorityRouter", routerImpl);
        hub.addContractType("CutoverVerifier", _deployCutoverVerifier(ARB_ORG_REGISTRY, ARB_PAYMASTER));
        routerProxy = _deployRouterSingleton(routerImpl, ARB_ORG_REGISTRY, ARB_PAYMASTER);
        hub.upgradeBeaconLocal("PaymasterHub", pmImpl, PM_VERSION);
        hub.adminCall(ARB_PAYMASTER, _setHatsCalldata(routerProxy));
        hub.upgradeBeaconLocal("OrgRegistry", orgRegImpl, ORG_REGISTRY_VERSION);
        hub.adminCall(ARB_ORG_REGISTRY, _setHatsCalldata(routerProxy));
    }

    function _assertEffects(
        address poaManager,
        address paymaster,
        address orgRegistry,
        address maImpl,
        address routerImpl,
        address pmImpl,
        address routerProxy
    ) internal view {
        // Beacons registered + impls match.
        require(_beacon(poaManager, MEMBERSHIP_AUTHORITY_ID) != address(0), "MA beacon not registered");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(MEMBERSHIP_AUTHORITY_ID) == maImpl,
            "MA v1 impl mismatch"
        );
        require(_beacon(poaManager, AUTHORITY_ROUTER_ID) != address(0), "Router beacon not registered");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(AUTHORITY_ROUTER_ID) == routerImpl,
            "Router v1 impl mismatch"
        );
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(PAYMASTER_HUB_ID) == pmImpl,
            "PaymasterHub beacon not upgraded to v20"
        );

        // CutoverVerifier registered at its deterministic address, pinning THIS chain's deps.
        address verifier = _cutoverVerifierAddress();
        require(_beacon(poaManager, CUTOVER_VERIFIER_ID) != address(0), "CutoverVerifier beacon not registered");
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(CUTOVER_VERIFIER_ID) == verifier,
            "CutoverVerifier v1 impl mismatch"
        );
        require(verifier.code.length > 0, "CutoverVerifier has no code");
        require(CutoverVerifier(verifier).hats() == HATS, "CutoverVerifier hats mismatch");
        require(CutoverVerifier(verifier).orgRegistry() == orgRegistry, "CutoverVerifier orgRegistry mismatch");

        // Router singleton wired to this chain's dependencies (zero bindings at birth).
        require(routerProxy.code.length > 0, "router singleton has no code");
        require(IAuthorityRouter(routerProxy).hats() == HATS, "router hats mismatch");
        require(IAuthorityRouter(routerProxy).orgRegistry() == orgRegistry, "router orgRegistry mismatch");
        require(IAuthorityRouter(routerProxy).paymasterHub() == paymaster, "router paymasterHub mismatch");
        require(IAuthorityRouter(routerProxy).admin() == HUDSON, "router admin mismatch");

        // The one-time hub repoint landed.
        require(IPaymasterView(paymaster).HATS() == routerProxy, "PaymasterHub.setHats(router) did not land");
    }

    /// @dev The OrgRegistry arm of §6 step 0.5: beacon on v2 (the impl that CARRIES setHats) and the
    ///      registry's own hats pointer moved to the router.
    function _assertOrgRegistryRepoint(address poaManager, address orgRegistry, address orgRegImpl, address routerProxy)
        internal
        view
    {
        require(
            IPoaManagerView(poaManager).getCurrentImplementationById(ORG_REGISTRY_ID) == orgRegImpl,
            "OrgRegistry beacon not upgraded to v2"
        );
        require(OrgRegistry(orgRegistry).getHats() == routerProxy, "OrgRegistry.setHats(router) did not land");
    }

    /// @dev BEHAVIOR-NEUTRAL proof for the OrgRegistry arm: a REAL metadata-admin wearer can still
    ///      drive `updateOrgMetaAsAdmin` once the registry reads through the router (legacy hat ids
    ///      pass straight through), and a stranger still cannot. Emits only — no state is mutated.
    function _assertOrgMetaResolves(address orgRegistry, bytes32 orgId, address realAdmin, bytes memory name) internal {
        vm.prank(realAdmin);
        OrgRegistry(orgRegistry).updateOrgMetaAsAdmin(orgId, name, bytes32(0));

        vm.prank(address(0xDEADBEEF));
        (bool ok,) =
            orgRegistry.call(abi.encodeWithSelector(OrgRegistry.updateOrgMetaAsAdmin.selector, orgId, name, bytes32(0)));
        require(!ok, "stranger unexpectedly passed the metadata-admin gate through the router");
    }

    /// @dev BEHAVIOR-NEUTRAL proof for unmigrated orgs (§6 step 0.5): the router's UNBOUND legacy-id
    ///      passthrough MUST equal a direct Hats read. Uses a REAL (wearer, hatId) pair on the fork
    ///      (both true) plus a non-wearer (both false) so the check is not trivially both-false.
    function _assertRouterNeutral(address routerProxy, address realWearer, uint256 realHatId) internal view {
        IAuthorityRouter r = IAuthorityRouter(routerProxy);
        // Real wearer: router passthrough == direct Hats == true.
        bool routerWears = r.isWearerOfHat(realWearer, realHatId);
        bool hatsWears = IHatsView(HATS).isWearerOfHat(realWearer, realHatId);
        require(routerWears == hatsWears, "router isWearerOfHat drifted from Hats (real wearer)");
        require(routerWears, "expected a REAL wearer on this fork (both should be true)");
        require(
            r.balanceOf(realWearer, realHatId) == IHatsView(HATS).balanceOf(realWearer, realHatId),
            "router balanceOf drifted from Hats"
        );
        (bool rElig, bool rStand) = r.getWearerStatus(realWearer, realHatId);
        bool hElig = IHatsView(HATS).isEligible(realWearer, realHatId);
        bool hStand = IHatsView(HATS).isInGoodStanding(realWearer, realHatId);
        require(rElig == hElig && rStand == hStand, "router getWearerStatus drifted from Hats");

        // Non-wearer: router passthrough == direct Hats == false.
        address stranger = address(0xDEADBEEF);
        require(
            r.isWearerOfHat(stranger, realHatId) == IHatsView(HATS).isWearerOfHat(stranger, realHatId),
            "router isWearerOfHat drifted from Hats (non-wearer)"
        );
        require(!r.isWearerOfHat(stranger, realHatId), "stranger unexpectedly a wearer");
    }
}

/* ════════════════════════════ GNOSIS — broadcast ════════════════════════════ */

contract Step1_DeployImplsGnosis is AccessV2RegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1 (Gnosis): DD-deploy MA + AuthorityRouter + PaymasterHub v20 + OrgRegistry v2 ===");
        vm.startBroadcast(key);
        (address ma, address router, address pm, address orgReg) = _deployImpls();
        vm.stopBroadcast();
        require(
            ma.code.length > 0 && router.code.length > 0 && pm.code.length > 0 && orgReg.code.length > 0,
            "an impl has no code"
        );
        console.log("  MembershipAuthority impl:", ma);
        console.log("  AuthorityRouter impl:    ", router);
        console.log("  PaymasterHub v20 impl:   ", pm);
        console.log("  OrgRegistry v2 impl:     ", orgReg);
    }
}

contract Step2_RegisterAndWireGnosis is AccessV2RegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(ISatelliteAdmin(GNOSIS_SATELLITE).owner() == vm.addr(key), "signer must own the Satellite");
        require(_beacon(GNOSIS_POA_MANAGER, MEMBERSHIP_AUTHORITY_ID) == address(0), "MA already registered on Gnosis");
        (address ma, address router, address pm, address orgReg) = _requireImpls();
        vm.startBroadcast(key);
        address routerProxy = _registerAndWireGnosis(ma, router, pm, orgReg);
        vm.stopBroadcast();

        _assertEffects(GNOSIS_POA_MANAGER, GNOSIS_PAYMASTER, GNOSIS_ORG_REGISTRY, ma, router, pm, routerProxy);
        _assertOrgRegistryRepoint(GNOSIS_POA_MANAGER, GNOSIS_ORG_REGISTRY, orgReg, routerProxy);
        console.log("Gnosis: Access-v2 protocol registered + hub/registry repointed to router:", routerProxy);
    }
}

/* ════════════════════════════ ARBITRUM — broadcast ════════════════════════════ */

contract Step1b_DeployImplsArbitrum is AccessV2RegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1b (Arbitrum): DD-deploy MA + AuthorityRouter + PaymasterHub v20 + OrgRegistry v2 ===");
        vm.startBroadcast(key);
        (address ma, address router, address pm, address orgReg) = _deployImpls();
        vm.stopBroadcast();
        require(
            ma.code.length > 0 && router.code.length > 0 && pm.code.length > 0 && orgReg.code.length > 0,
            "an impl has no code"
        );
        console.log("  MembershipAuthority impl:", ma);
        console.log("  AuthorityRouter impl:    ", router);
        console.log("  PaymasterHub v20 impl:   ", pm);
        console.log("  OrgRegistry v2 impl:     ", orgReg);
    }
}

contract Step2b_RegisterAndWireArbitrum is AccessV2RegisterBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IHubAdmin(ARB_HUB).owner() == vm.addr(key), "signer must own the Hub");
        require(_beacon(ARB_POA_MANAGER, MEMBERSHIP_AUTHORITY_ID) == address(0), "MA already registered on Arbitrum");
        (address ma, address router, address pm, address orgReg) = _requireImpls();
        require(
            ma.code.length > 0 && router.code.length > 0 && pm.code.length > 0 && orgReg.code.length > 0,
            "run Step1b first (impl missing)"
        );

        vm.startBroadcast(key);
        address routerProxy = _registerAndWireArbitrum(ma, router, pm, orgReg);
        vm.stopBroadcast();

        _assertEffects(ARB_POA_MANAGER, ARB_PAYMASTER, ARB_ORG_REGISTRY, ma, router, pm, routerProxy);
        _assertOrgRegistryRepoint(ARB_POA_MANAGER, ARB_ORG_REGISTRY, orgReg, routerProxy);
        console.log("Arbitrum: Access-v2 protocol registered + hub/registry repointed to router:", routerProxy);
    }
}

/* ════════════════════════════ SIMS — real forks, prank Hudson ════════════════════════════ */

/// @notice Gnosis fork-sim (Satellite-local). Registers MA + router beacons, deploys the router
///         singleton, upgrades PaymasterHub to v20, and repoints the hub to the router — then proves
///         the repoint is behavior-neutral for the unmigrated Test6 org (a real topHat wearer read
///         THROUGH the router equals the direct Hats read).
contract SimGnosis is AccessV2RegisterBase {
    // Test6 (Gnosis): its Executor wears the org topHat (domain 1077) — a real (wearer, hatId) pair.
    address constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    uint256 constant TEST6_TOPHAT = uint256(1077) << 224;
    // Test6's OrgRegistry entry + a REAL wearer of its metadata-admin hat (Hudson) — the live probe
    // for the OrgRegistry arm of the repoint.
    bytes32 constant TEST6_ORG_ID = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;

    function run() public {
        console.log("\n=== SIM: Access-v2 protocol registration (Gnosis fork, Satellite-local) ===");
        require(_beacon(GNOSIS_POA_MANAGER, MEMBERSHIP_AUTHORITY_ID) == address(0), "sim: MA already registered");
        require(
            _versionFree(GNOSIS_REGISTRY, "PaymasterHub", PM_VERSION), "sim: PaymasterHub v20 already taken (Gnosis)"
        );
        require(
            _versionFree(GNOSIS_REGISTRY, "OrgRegistry", ORG_REGISTRY_VERSION),
            "sim: OrgRegistry v2 already taken (Gnosis)"
        );
        address hatsBefore = IPaymasterView(GNOSIS_PAYMASTER).HATS();
        address regHatsBefore = OrgRegistry(GNOSIS_ORG_REGISTRY).getHats();
        console.log("  PaymasterHub.HATS before:", hatsBefore);
        console.log("  OrgRegistry.getHats before:", regHatsBefore);
        // Baseline: the live metadata-admin path works TODAY against real Hats.
        _assertOrgMetaResolves(GNOSIS_ORG_REGISTRY, TEST6_ORG_ID, HUDSON, "Test6");

        vm.startPrank(HUDSON);
        (address ma, address router, address pm, address orgReg) = _deployImpls();
        address routerProxy = _registerAndWireGnosis(ma, router, pm, orgReg);
        vm.stopPrank();

        _assertEffects(GNOSIS_POA_MANAGER, GNOSIS_PAYMASTER, GNOSIS_ORG_REGISTRY, ma, router, pm, routerProxy);
        _assertOrgRegistryRepoint(GNOSIS_POA_MANAGER, GNOSIS_ORG_REGISTRY, orgReg, routerProxy);
        require(hatsBefore == HATS, "sim: expected live hub pointing at real Hats pre-repoint");
        require(regHatsBefore == HATS, "sim: expected live registry pointing at real Hats pre-repoint");
        require(routerProxy != hatsBefore, "sim: router must differ from prior hats");
        _assertRouterNeutral(routerProxy, TEST6_EXECUTOR, TEST6_TOPHAT);
        // The same live metadata-admin call STILL resolves, now routed through the AuthorityRouter.
        _assertOrgMetaResolves(GNOSIS_ORG_REGISTRY, TEST6_ORG_ID, HUDSON, "Test6");

        console.log("  MembershipAuthority impl:", ma);
        console.log("  AuthorityRouter impl:    ", router);
        console.log("  AuthorityRouter singleton:", routerProxy);
        console.log("  PaymasterHub v20 impl:   ", pm);
        console.log("  OrgRegistry v2 impl:     ", orgReg);
        console.log("  PaymasterHub.HATS after: ", IPaymasterView(GNOSIS_PAYMASTER).HATS());
        console.log("  OrgRegistry.getHats after:", OrgRegistry(GNOSIS_ORG_REGISTRY).getHats());
        console.log("PASS: SimGnosis - Access-v2 protocol registered; hub+registry->router repoint neutral for Test6.");
    }
}

/// @notice Arbitrum counterpart (Hub-local), neutral-checked against the live Poa org (domain 93).
contract SimArbitrum is AccessV2RegisterBase {
    address constant POA_EXECUTOR = 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41;
    uint256 constant POA_TOPHAT = uint256(93) << 224;
    bytes32 constant POA_ORG_ID = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;

    function run() public {
        console.log("\n=== SIM: Access-v2 protocol registration (Arbitrum fork, Hub-local) ===");
        require(_beacon(ARB_POA_MANAGER, MEMBERSHIP_AUTHORITY_ID) == address(0), "sim: MA already registered");
        require(
            _versionFree(ARB_REGISTRY, "PaymasterHub", PM_VERSION), "sim: PaymasterHub v20 already taken (Arbitrum)"
        );
        require(
            _versionFree(ARB_REGISTRY, "OrgRegistry", ORG_REGISTRY_VERSION),
            "sim: OrgRegistry v2 already taken (Arbitrum)"
        );
        address hatsBefore = IPaymasterView(ARB_PAYMASTER).HATS();
        address regHatsBefore = OrgRegistry(ARB_ORG_REGISTRY).getHats();
        console.log("  PaymasterHub.HATS before:", hatsBefore);
        console.log("  OrgRegistry.getHats before:", regHatsBefore);
        _assertOrgMetaResolves(ARB_ORG_REGISTRY, POA_ORG_ID, HUDSON, "Poa");

        vm.startPrank(HUDSON);
        (address ma, address router, address pm, address orgReg) = _deployImpls();
        address routerProxy = _registerAndWireArbitrum(ma, router, pm, orgReg);
        vm.stopPrank();

        _assertEffects(ARB_POA_MANAGER, ARB_PAYMASTER, ARB_ORG_REGISTRY, ma, router, pm, routerProxy);
        _assertOrgRegistryRepoint(ARB_POA_MANAGER, ARB_ORG_REGISTRY, orgReg, routerProxy);
        require(hatsBefore == HATS, "sim: expected live hub pointing at real Hats pre-repoint");
        require(regHatsBefore == HATS, "sim: expected live registry pointing at real Hats pre-repoint");
        require(routerProxy != hatsBefore, "sim: router must differ from prior hats");
        _assertRouterNeutral(routerProxy, POA_EXECUTOR, POA_TOPHAT);
        _assertOrgMetaResolves(ARB_ORG_REGISTRY, POA_ORG_ID, HUDSON, "Poa");

        console.log("  MembershipAuthority impl:", ma);
        console.log("  AuthorityRouter impl:    ", router);
        console.log("  AuthorityRouter singleton:", routerProxy);
        console.log("  PaymasterHub v20 impl:   ", pm);
        console.log("  OrgRegistry v2 impl:     ", orgReg);
        console.log("  PaymasterHub.HATS after: ", IPaymasterView(ARB_PAYMASTER).HATS());
        console.log("  OrgRegistry.getHats after:", OrgRegistry(ARB_ORG_REGISTRY).getHats());
        console.log("PASS: SimArbitrum - Access-v2 protocol registered; hub+registry->router repoint neutral for Poa.");
    }
}
