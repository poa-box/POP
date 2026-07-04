// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Executor} from "../../src/Executor.sol";
import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
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
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/*
 * ============================================================================
 * WS-D-SEED — wire the QuickJoin claimable-hats allowlist seed into new-org
 * deployment (coordination item emergent from WS-D's H-03 fix)
 * ============================================================================
 *
 * WS-D (merged) made QuickJoin's H-03 claimable-hats allowlist default to
 * EMPTY = CLOSED — the secure default that instantly closes H-03 for live orgs.
 * Consequence: a freshly-deployed org would have an EMPTY allowlist, so members
 * could not claim ANY hat via the caller-specified QuickJoin claim paths
 * (claimHatsWithUser / registerAndClaimHats*) until it was seeded.
 *
 * This upgrade wires the seed into deployFullOrg:
 *
 *   Executor v5    — gains configureQuickJoinClaimable(quickJoin, hatIds), a
 *                    one-shot owner-gated passthrough to QuickJoin.setClaimableHatIds
 *                    (which is onlyExecutor). The Executor IS the QuickJoin's
 *                    executor, so OrgDeployer routes the seed through it while it
 *                    still owns the Executor (pre-renounce). Supersedes WS-A's
 *                    Executor v4 (v5 bytecode CONTAINS all of WS-A's Executor
 *                    fixes — configureParticipationToken, sweep L-11, L-60 cap —
 *                    PLUS this passthrough).
 *   OrgDeployer v17 — step 9b seeds the new org's QuickJoin allowlist with the
 *                    org's member-level auto-mint hats (memberHatIds, resolved
 *                    from quickJoinRolesBitmap). These are the base role(s)
 *                    QuickJoin was always meant to grant on join and are
 *                    non-privileged by construction (anyone who joins receives
 *                    them), so executive/admin hats stay non-claimable — H-03
 *                    stays closed. Supersedes WS-A's OrgDeployer v16 (v17 bytecode
 *                    CONTAINS WS-A's step-8 rewiring + L-53 PLUS this step-9b seed).
 *
 * PREREQUISITE (already covered by WS-D's UpgradeAccessSecurity.s.sol): the
 * QuickJoin beacon must be at v6 (the impl that has setClaimableHatIds). The sim
 * below upgrades QuickJoin -> v6 as a prerequisite so it exercises the whole
 * ordered chain end-to-end on a fresh org. In production, ship WS-D's QuickJoin
 * v6 upgrade first (or in the same batch) before flipping OrgDeployer to v17.
 *
 * NOTE on WS-A: because v5/v17 bundle WS-A's fixes, deploying this bundle makes
 * WS-A's separate Executor v4 / OrgDeployer v16 unnecessary — do NOT deploy both
 * (they would register two versions with the same effect). Coordinate: ship
 * v5/v17 in place of v4/v16, OR ship v4/v16 first then v5/v17 on top; both work
 * because upgrades are version-additive. The important invariant is that the
 * QuickJoin v6, Executor v5, and OrgDeployer v17 beacons are ALL current before
 * any new org is deployed, or a fresh deployFullOrg's step-9b seed reverts.
 *
 * ── VERSION SELECTION (CLAUDE.md two-surface probe, both chains, 2026-07-04) ──
 * Registry: Gnosis 0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
 *           Arbitrum 0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9.
 * DeterministicDeployer is CREATE3 (address is salt/version-only) → same (type,
 * version) resolves to the SAME address on both chains.
 *
 *   Executor:    WS-A picked v4; probed from v5.
 *     v5 gnosis:   registry=no create2=no → FREE
 *     v5 arbitrum: registry=no create2=no → FREE   ⇒ pick v5 (0xF6dac1A17d50bcD84A1c89CC6C8Bfdb79fC04425)
 *   OrgDeployer: WS-A picked v16; probed from v17.
 *     v17 gnosis:   registry=no create2=no → FREE
 *     v17 arbitrum: registry=no create2=no → FREE  ⇒ pick v17 (0xab8124C986Cf056dA23184913FA73352c8695615)
 *
 * ── UPGRADE PATH (destination-chain-direct, per CLAUDE.md) ──
 *   Gnosis:   Hudson (Satellite owner) → Satellite.upgradeBeaconDirect(type, impl, version).
 *   Arbitrum: Hudson (Hub owner)       → Hub.upgradeBeaconCrossChain(type, impl, version).
 *
 * ── SIM (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeQuickJoinSeedDeployer.s.sol:SimGnosis --fork-url gnosis -vvv
 *
 * ── BROADCAST (do NOT run in this workstream) ──
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step1_DeployOnGnosis      --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step2_UpgradeFromArbitrum --rpc-url arbitrum --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script .../:Step2b_UpgradeGnosis      --rpc-url gnosis   --broadcast --slow
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

string constant EXECUTOR_VERSION = "v5";
string constant DEPLOYER_VERSION = "v17";
string constant QJ_VERSION = "v6"; // WS-D prerequisite (setClaimableHatIds)

interface ISatellite {
    function owner() external view returns (address);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

/*═══════════════════════════════════════════════════════════════════════════
                                 BROADCAST STEPS
═══════════════════════════════════════════════════════════════════════════*/

/// @title Step1_DeployOnGnosis — deploy the Executor v5 + OrgDeployer v17 impls on Gnosis (idempotent).
///        (QuickJoin v6 ships via WS-D's UpgradeAccessSecurity.s.sol; not re-deployed here.)
contract Step1_DeployOnGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 1: Deploy WS-D-SEED impls on Gnosis ===");
        vm.startBroadcast(deployerKey);
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

/// @title Step2_UpgradeFromArbitrum — deploy impls on Arbitrum + upgrade both Arbitrum beacons
///        (and dispatch cross-chain to Gnosis) through the Hub.
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

/// @title Step2b_UpgradeGnosis — upgrade both Gnosis beacons directly (no Hyperlane wait).
///        Requires Step1 impls already deployed on Gnosis.
contract Step2b_UpgradeGnosis is Script {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(ISatellite(GNOSIS_SATELLITE).owner() == vm.addr(deployerKey), "signer must own the Satellite");
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 2b: Upgrade Gnosis beacons via Satellite.upgradeBeaconDirect ===");
        vm.startBroadcast(deployerKey);
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

/// @title Step3_Verify — confirm both Gnosis beacons point at the new impls.
contract Step3_Verify is Script {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 3: Verify Gnosis beacons ===");
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
                                   SIM: GNOSIS
═══════════════════════════════════════════════════════════════════════════*/

interface IPaymasterHubRegistrar {
    function setOrgRegistrar(address registrar) external;
}

/**
 * @title SimGnosis
 * @notice Full production-profile fork sim of the WS-D-SEED upgrade on Gnosis.
 *
 * Upgrades (in order) the QuickJoin (WS-D v6 prerequisite), Executor (v5) and
 * OrgDeployer (v17) beacons on the live Gnosis PoaManager via the Satellite,
 * then deploys a FRESH, internally-consistent current-src OrgDeployer stack on
 * the live (upgraded) beacons — mirroring WS-A's SimGnosis fresh-org approach,
 * because the on-chain factories the LIVE OrgDeployer proxy points at have
 * drifted from current src (a deployFullOrg on the live proxy would revert
 * inside the stale factory). The fresh OrgDeployer runs the SAME v17 bytecode
 * the beacon now points at, so step-9b's seed is validated against exactly the
 * code this script upgrades to.
 *
 * Asserts (in order):
 *   (1) fresh org's QuickJoin claimable allowlist == exactly the DEFAULT member
 *       hat (role 0, the quickJoinRolesBitmap set) and NOTHING else; the seed
 *       equals the org's memberHatIds auto-mint set.
 *   (2) the privileged EXECUTIVE hat (role 1) is NOT claimable (H-03 stays closed).
 *   (3) a member (username registered, default-eligible) CAN claim the seeded
 *       DEFAULT hat via claimHatsWithUser — fresh orgs onboard normally.
 *   (4) an attacker CANNOT claim the non-seeded EXECUTIVE hat (reverts HatNotClaimable).
 */
contract SimGnosis is Script {
    // Live Gnosis beacons (read from PoaManager.getBeaconById). The fresh-org sub-sim creates
    // fresh proxies against these so it exercises the just-upgraded impls end-to-end.
    address constant ORG_DEPLOYER_BEACON = 0x2f48EB6Ed3D6C37bF8858c39a32262867ba67293;
    address constant ORG_REGISTRY_BEACON = 0x76402cE426b53F28467Aa67Dc4cE5bC2785cCFFE;
    address constant UAR_BEACON = 0x4f2a9d4cB62BEfBA35dAC2D3dE32c55413C65BB6;
    address constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    function _upgradeBeacon(string memory typeName, address newImpl, string memory version) internal {
        vm.prank(HUDSON_ADMIN);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect(typeName, newImpl, version);
    }

    function _deployAndUpgrade(string memory typeName, string memory version, bytes memory code) internal {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, version);
        address impl = dd.computeAddress(salt);
        if (impl.code.length == 0) {
            vm.prank(HUDSON_ADMIN);
            address deployed = dd.deploy(salt, code);
            require(deployed == impl, "Sim: DD address mismatch");
        }
        require(impl.code.length > 0, "Sim: impl code missing");
        _upgradeBeacon(typeName, impl, version);
        address current = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256(bytes(typeName)));
        require(current == impl, "Sim: beacon upgrade did not stick");
        console.log(typeName, "beacon upgraded ->", impl);
    }

    function run() public {
        console.log("\n=== SIM: WS-D-SEED upgrade on Gnosis fork ===\n");

        // Upgrade the three beacons in dependency order (QuickJoin v6 first so setClaimableHatIds
        // exists, then the Executor passthrough + the OrgDeployer step-9b seed).
        _deployAndUpgrade("QuickJoin", QJ_VERSION, type(QuickJoin).creationCode);
        _deployAndUpgrade("Executor", EXECUTOR_VERSION, type(Executor).creationCode);
        _deployAndUpgrade("OrgDeployer", DEPLOYER_VERSION, type(OrgDeployer).creationCode);

        _assertFreshOrgSeed();

        console.log("\nPASS: WS-D-SEED upgrade validated against live Gnosis state.");
    }

    function _assertFreshOrgSeed() internal {
        vm.deal(HUDSON_ADMIN, 10 ether);
        (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) = _bootstrapFreshStack();

        bytes32 orgId = keccak256(abi.encodePacked("ws-d-seed-sim-org", vm.getBlockTimestamp(), block.number));
        OrgDeployer.DeploymentParams memory params = _buildParams(orgId, uar);

        vm.prank(HUDSON_ADMIN);
        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);

        uint256 defaultHat = orgRegistry.getRoleHat(orgId, 0);
        uint256 executiveHat = orgRegistry.getRoleHat(orgId, 1);
        QuickJoin qj = QuickJoin(result.quickJoin);

        // (1) allowlist == exactly the DEFAULT member hat.
        uint256[] memory claimable = qj.claimableHatIds();
        require(claimable.length == 1, "(1) claimable allowlist must have exactly one hat");
        require(claimable[0] == defaultHat, "(1) seeded hat must be the DEFAULT member hat");
        // The seed must equal the org's auto-mint member set.
        uint256[] memory memberHats = qj.memberHatIds();
        require(memberHats.length == 1 && memberHats[0] == defaultHat, "(1) seed must equal memberHatIds");
        require(qj.isClaimableHat(defaultHat), "(1) DEFAULT hat must be claimable");
        console.log("(1) fresh org QuickJoin seeded with DEFAULT member hat only OK:", defaultHat);

        // (2) EXECUTIVE hat is NOT claimable — H-03 stays closed.
        require(!qj.isClaimableHat(executiveHat), "(2) EXECUTIVE hat must NOT be claimable");
        console.log("(2) EXECUTIVE hat NOT claimable (H-03 stays closed) OK:", executiveHat);

        // (3) a member can claim the seeded DEFAULT hat via the H-03-gated claim path.
        address member = makeAddr("ws-d-seed-member");
        vm.prank(member);
        UniversalAccountRegistry(uar).registerAccount("ws-d-seed-member");
        uint256[] memory claim = new uint256[](1);
        claim[0] = defaultHat;
        vm.prank(member);
        qj.claimHatsWithUser(claim);
        require(IHats(HATS).isWearerOfHat(member, defaultHat), "(3) member should wear DEFAULT hat after claim");
        console.log("(3) member claimed seeded DEFAULT hat via claimHatsWithUser OK");

        // (4) an attacker CANNOT claim the non-seeded EXECUTIVE hat.
        address attacker = makeAddr("ws-d-seed-attacker");
        vm.prank(attacker);
        UniversalAccountRegistry(uar).registerAccount("ws-d-seed-attacker");
        uint256[] memory badClaim = new uint256[](1);
        badClaim[0] = executiveHat;
        vm.prank(attacker);
        (bool ok,) = address(qj).call(abi.encodeCall(QuickJoin.claimHatsWithUser, (badClaim)));
        require(!ok, "(4) attacker EXECUTIVE claim must revert");
        require(!IHats(HATS).isWearerOfHat(attacker, executiveHat), "(4) attacker must not wear EXECUTIVE hat");
        console.log("(4) attacker BLOCKED from claiming EXECUTIVE hat (H-03 closed) OK");
    }

    /// @dev Deploy a fresh, internally-consistent current-src OrgDeployer stack on the fork.
    function _bootstrapFreshStack() internal returns (OrgDeployer deployer, OrgRegistry orgRegistry, address uar) {
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

    /*──────── minimal-config builders (split out to dodge stack-too-deep) ────────*/
    function _buildParams(bytes32 orgId, address uar)
        internal
        pure
        returns (OrgDeployer.DeploymentParams memory params)
    {
        params.orgId = orgId;
        params.orgName = "WS-D-SEED Sim Org";
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
            quickJoinRolesBitmap: 1, // Role 0 (DEFAULT) is the member/base hat granted on join
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
