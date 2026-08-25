// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";

/*
 * ============================================================================
 * OrgDeployer v19 — real ZkEmailInvites claim selectors in the auto-whitelist (issue #188)
 * ============================================================================
 *
 * ⚠ SUPERSEDED for post-v20 rollouts by UpgradePaymasterGlobalRules.s.sol (OrgDeployer v20):
 * the global-rulebook refactor DELETED _buildDefaultPaymasterRules entirely — sponsored
 * selectors (including the corrected zk-email ones, cross-checked against the ABI by
 * OrgDeployerPaymasterRules.t.sol / PaymasterGlobalRules.t.sol) now live in
 * script/helpers/DefaultGlobalRules.sol and ship via setGlobalRulesBatch. Broadcast THIS
 * script only if it lands BEFORE the v20 hub upgrade (the near-term protective fix); its
 * sims assume the pre-v20 hub ABI and the pre-v20 deployer sources, so on the rulebook
 * branch they will not pass — compile-only here, kept as the v19 broadcast record.
 *
 * `_appendZkEmailInvitesRules` derived its four selectors by hashing PRE-Blocker-2
 * signature strings whose `ZkEmailProof` tuple ended in `string`. The live struct ends in
 * `bytes32 fromDomainHash`, so every one of those four selectors was wrong:
 *
 *   stale 0xc8864f92 / 0x50b2f726 / 0xcc1866ac / 0xebd847f2   (no function answers these)
 *   live  0x24b5e3ba / 0x8c149bab / 0x6108482e / 0x998dc9d6
 *
 * Any org deployed with `autoWhitelistContracts: true` + zk-email enabled therefore got four
 * dead paymaster rules and ZERO sponsorship on the real claim entrypoints — gasless zk-email
 * claims fail rule validation. v19 replaces the strings with compiler-derived
 * `ZkEmailInvites.<fn>.selector`, so they can never drift from the ABI again.
 *
 *   Live impl: v18 (0xE328c6093e53cBafea8d4461e9bd4345786decC9, both chains)
 *   This PR:   v19
 *
 * Version selection (CLAUDE.md two-surface probe, both chains, 2026-08-04):
 *   Gnosis   registry count=16; v16/v17/v18 TAKEN (registry+CREATE2); v19 FREE on both surfaces.
 *   Arbitrum registry count=17; v16/v17/v18 TAKEN (registry+CREATE2); v19 FREE on both surfaces.
 *   Predicted v19 impl (identical on both chains): 0x90BAe532D26100a2106c3b16bEA1Ad27D2286b3A
 *
 * Forward-only. No live org needs a governance back-fill: `_appendZkEmailInvitesRules` has never
 * run on-chain (both existing ZkEmailInvites modules — Test6 and KUBI on Gnosis — are retrofits
 * whose rules were set by their own scripts, and Test6's ceremony already wrote the correct
 * selectors). But the zk infra IS wired on both chains (OrgDeployer layout +10/+11/+12 all
 * non-zero) and the ZkEmailInvites beacon IS registered on both, so the bug is armed for the very
 * next `deployFullOrgWithZkEmail` — land this BEFORE broadcasting script/org/DeployComfiestHouse.
 *
 * Uses the fee-free upgrade path (CLAUDE.md: prefer the destination chain over a Hyperlane
 * dispatch) — Satellite.upgradeBeaconDirect on Gnosis, Hub.upgradeBeaconLocal on Arbitrum. No
 * 0.005 ETH fee, no 5-minute relay, and both sides are fork-simulatable.
 *
 * RUN ORDER (all FOUNDRY_PROFILE=production)
 *   0. SimZkEmailRulesGnosis   --fork-url gnosis    (must PASS)
 *      SimZkEmailRulesArbitrum --fork-url arbitrum  (must PASS)
 *   1. Step1_UpgradeGnosis   --rpc-url gnosis   --broadcast --slow
 *   2. Step2_UpgradeArbitrum --rpc-url arbitrum --broadcast --slow
 *   3. Step3_Verify --fork-url gnosis ; Step3_Verify --fork-url arbitrum
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71; // PoaManagerHub (Arbitrum)
address constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // owner = Hudson
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
address constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c; // same both chains (CREATE3)

address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant GNOSIS_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

address constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
address constant ARB_ACCOUNT_REGISTRY = 0x01A13c92321E9CA2C02577b92A4F8d2FDC4d8513;
address constant ARB_PAYMASTER_HUB = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;

string constant VERSION = "v19";

/// @dev The four PRE-Blocker-2 selectors v18 and earlier wrote. Kept ONLY so the sim can prove
///      they are gone; never register these.
bytes4 constant STALE_CLAIM_DOMAIN = 0xc8864f92;
bytes4 constant STALE_CLAIM_EMAIL = 0x50b2f726;
bytes4 constant STALE_REG_CLAIM_DOMAIN = 0xcc1866ac;
bytes4 constant STALE_REG_CLAIM_EMAIL = 0xebd847f2;

interface ISatelliteZk {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IHubZk {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
    function paused() external view returns (bool);
}

abstract contract ZkEmailRulesBase is Script {
    /* ── deploy ── */

    function _predicted(DeterministicDeployer dd) internal view returns (address) {
        return dd.computeAddress(dd.computeSalt("OrgDeployer", VERSION));
    }

    /// @dev Idempotent CREATE3 deploy — skips a slot that already holds code. The two-surface probe
    ///      in the header confirmed v19 is free on both chains; a takeover between probe and
    ///      broadcast surfaces as the bytecode check below failing.
    function _deployImpl(DeterministicDeployer dd) internal returns (address impl) {
        impl = _predicted(dd);
        if (impl.code.length > 0) {
            console.log("OrgDeployer", VERSION, "already deployed:", impl);
        } else {
            address deployed = dd.deploy(dd.computeSalt("OrgDeployer", VERSION), type(OrgDeployer).creationCode);
            require(deployed == impl, "DD address mismatch");
            console.log("OrgDeployer", VERSION, "deployed:", deployed);
        }
        require(
            keccak256(impl.code) == keccak256(type(OrgDeployer).runtimeCode), "impl != this branch's OrgDeployer build"
        );
    }

    /* ── behavioural before/after on a real fork ── */

    /// @dev Deploys a throwaway org through the LIVE OrgDeployer proxy with
    ///      `autoWhitelistContracts: true` + zk-email enabled, then reports which claim selectors
    ///      the paymaster actually ended up sponsoring. This is the whole point of the sim: the
    ///      selectors are keccak-of-string-literal constants that the optimizer folds and
    ///      materialises arithmetically, so grepping the impl bytecode for them proves nothing —
    ///      only a real deploy shows which rules land.
    function _deployFixtureAndReadRules(bytes32 orgId, address accountRegistry, address paymasterHub)
        internal
        returns (bool[4] memory liveAllowed, uint32[4] memory liveHints, bool[4] memory staleAllowed)
    {
        vm.prank(HUDSON);
        OrgDeployer.DeploymentResult memory r = OrgDeployer(ORG_DEPLOYER)
            .deployFullOrgWithZkEmail(
                _fixtureParams(orgId, accountRegistry),
                ModulesFactory.ZkEmailConfig({enabled: true, initialRoot: bytes32(0), initialCid: bytes32(0)})
            );
        require(r.zkEmailInvites != address(0), "sim: zk module not deployed (infra/beacon missing on this chain)");

        PaymasterHub hub = PaymasterHub(payable(paymasterHub));
        bytes4[4] memory live = [
            ZkEmailInvites.claimRoleByDomain.selector,
            ZkEmailInvites.claimRoleByEmail.selector,
            ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector,
            ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector
        ];
        bytes4[4] memory stale = [STALE_CLAIM_DOMAIN, STALE_CLAIM_EMAIL, STALE_REG_CLAIM_DOMAIN, STALE_REG_CLAIM_EMAIL];

        for (uint256 i; i < 4; i++) {
            PaymasterHub.Rule memory ruleLive = hub.getRule(orgId, r.zkEmailInvites, live[i]);
            liveAllowed[i] = ruleLive.allowed;
            liveHints[i] = ruleLive.maxCallGasHint;
            staleAllowed[i] = hub.getRule(orgId, r.zkEmailInvites, stale[i]).allowed;
        }
    }

    /// @dev The v18 (pre-fix) expectation: dead rules registered, real entrypoints unsponsored.
    function _requireBuggyRules(bytes32 orgId, address accountRegistry, address paymasterHub) internal {
        (bool[4] memory liveAllowed,, bool[4] memory staleAllowed) =
            _deployFixtureAndReadRules(orgId, accountRegistry, paymasterHub);
        for (uint256 i; i < 4; i++) {
            require(!liveAllowed[i], "BEFORE: live selector already sponsored - is v19 already deployed?");
            require(staleAllowed[i], "BEFORE: expected the stale selector to be whitelisted on the old impl");
        }
        console.log("BEFORE (v18): 4/4 stale selectors sponsored, 0/4 real claim entrypoints sponsored");
    }

    /// @dev The v19 expectation: real entrypoints sponsored with their gas hints, no dead rules.
    function _requireFixedRules(bytes32 orgId, address accountRegistry, address paymasterHub) internal {
        (bool[4] memory liveAllowed, uint32[4] memory liveHints, bool[4] memory staleAllowed) =
            _deployFixtureAndReadRules(orgId, accountRegistry, paymasterHub);
        uint32[4] memory expectedHints = [uint32(800_000), 800_000, 1_200_000, 1_200_000];
        for (uint256 i; i < 4; i++) {
            require(liveAllowed[i], "AFTER: real claim selector not sponsored");
            require(liveHints[i] == expectedHints[i], "AFTER: gas hint mismatch");
            require(!staleAllowed[i], "AFTER: stale selector still whitelisted");
        }
        console.log("AFTER  (v19): 4/4 real claim entrypoints sponsored (800k/800k/1.2M/1.2M), 0/4 stale");
    }

    /* ── fixture org ── */

    function _fixtureParams(bytes32 orgId, address accountRegistry)
        internal
        pure
        returns (OrgDeployer.DeploymentParams memory)
    {
        return OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "ZkRules Fixture",
            metadataHash: bytes32(0),
            registryAddr: accountRegistry,
            deployerAddress: HUDSON,
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: _fixtureClasses(),
            ddInitialTargets: new address[](0),
            roles: _fixtureRoles(),
            groups: new RoleConfigStructs.GroupConfig[](0),
            roleAssignments: _fixtureAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: false}),
            bootstrap: OrgDeployer.BootstrapConfig({
                projects: new ITaskManagerBootstrap.BootstrapProjectConfig[](0),
                tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)
            }),
            // The knob under test: auto-whitelist writes the default rule batch, zk-email rules included.
            paymasterConfig: OrgDeployer.PaymasterConfig({
                operatorRoleIndex: type(uint256).max,
                autoWhitelistContracts: true,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                maxCallGas: 0,
                maxVerificationGas: 0,
                maxPreVerificationGas: 0,
                defaultBudgetCapPerEpoch: 0,
                defaultBudgetEpochLen: 0
            }),
            taskManagerPerms: OrgDeployer.TaskManagerPermConfig({roleIndices: new uint256[](0), masks: new uint8[](0)}),
            hybridQuorum: 2,
            ddQuorum: 2,
            tokenName: "ZkRules Shares",
            tokenSymbol: "ZKRF"
        });
    }

    function _fixtureRoles() private pure returns (RoleConfigStructs.RoleConfig[] memory roles) {
        roles = new RoleConfigStructs.RoleConfig[](1);
        roles[0] = RoleConfigStructs.RoleConfig({
            name: "MEMBER",
            image: "",
            metadataCID: bytes32(0),
            canVote: true,
            open: true,
            maxMembers: 0,
            vouching: RoleConfigStructs.RoleVouchingConfig({enabled: false, quorum: 0, voucherRoleIndex: 0}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: new address[](0)
            })
        });
    }

    function _fixtureAssignments() private pure returns (OrgDeployer.RoleAssignments memory) {
        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 1,
            tokenMemberRolesBitmap: 1,
            tokenApproverRolesBitmap: 1,
            taskCreatorRolesBitmap: 1,
            educationCreatorRolesBitmap: 0,
            educationMemberRolesBitmap: 0,
            hybridProposalCreatorRolesBitmap: 1,
            ddVotingRolesBitmap: 1,
            ddCreatorRolesBitmap: 1
        });
    }

    function _fixtureClasses() private pure returns (IHybridVotingInit.ClassConfig[] memory classes) {
        classes = new IHybridVotingInit.ClassConfig[](1);
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: new uint256[](0)
        });
    }

    /* ── shared verify ── */

    /// @dev Accepts EITHER env var. Do NOT collapse this to
    ///      `vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))` (the older upgrade scripts'
    ///      spelling): Solidity evaluates the default eagerly, so that form reverts when
    ///      DEPLOYER_PRIVATE_KEY is unset even if PRIVATE_KEY is set.
    function _signerKey() internal view returns (uint256 key) {
        key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _alreadyLive(address poaManager, address impl) internal view returns (bool live) {
        live = PoaManager(poaManager).getCurrentImplementationById(keccak256("OrgDeployer")) == impl;
        if (live) console.log("Beacon already points at", impl, "- skipping upgrade call");
    }

    function _requireLive(address poaManager) internal view {
        address expected = _predicted(DeterministicDeployer(DD));
        address current = PoaManager(poaManager).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Expected:", expected);
        console.log("Current: ", current);
        require(current == expected, "OrgDeployer v19 not live on this chain");
    }
}

/*═══════════════════════════ SIMS (must PASS before broadcast) ═══════════════════════════*/

contract SimZkEmailRulesGnosis is ZkEmailRulesBase {
    function run() external {
        require(block.chainid == 100, "fork gnosis");
        console.log("\n=== SIM: OrgDeployer v19 zk-email rule fix (Gnosis fork) ===");
        require(ISatelliteZk(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        address before = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        // BEFORE: prove the live impl really does register the dead selectors.
        _requireBuggyRules(keccak256("zkrules-sim-before-gnosis"), GNOSIS_ACCOUNT_REGISTRY, GNOSIS_PAYMASTER_HUB);

        vm.startPrank(HUDSON);
        address impl = _deployImpl(DeterministicDeployer(DD));
        ISatelliteZk(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", impl, VERSION);
        vm.stopPrank();

        address after_ = PoaManager(GNOSIS_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));
        require(after_ == impl, "beacon not upgraded");
        require(before != after_, "impl did not change");
        console.log("New impl:", after_, "codesize:", after_.code.length);

        // AFTER: same deploy path, correct rules.
        _requireFixedRules(keccak256("zkrules-sim-after-gnosis"), GNOSIS_ACCOUNT_REGISTRY, GNOSIS_PAYMASTER_HUB);

        console.log("\n=== PASS: SimZkEmailRulesGnosis ===");
    }
}

contract SimZkEmailRulesArbitrum is ZkEmailRulesBase {
    function run() external {
        require(block.chainid == 42161, "fork arbitrum");
        console.log("\n=== SIM: OrgDeployer v19 zk-email rule fix (Arbitrum fork) ===");
        require(IHubZk(HUB).owner() == HUDSON, "Hub owner != Hudson");
        require(!IHubZk(HUB).paused(), "Hub is paused");

        address before = PoaManager(ARB_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));
        console.log("Current impl:", before);

        _requireBuggyRules(keccak256("zkrules-sim-before-arb"), ARB_ACCOUNT_REGISTRY, ARB_PAYMASTER_HUB);

        vm.startPrank(HUDSON);
        address impl = _deployImpl(DeterministicDeployer(DD));
        IHubZk(HUB).upgradeBeaconLocal("OrgDeployer", impl, VERSION);
        vm.stopPrank();

        address after_ = PoaManager(ARB_POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer"));
        require(after_ == impl, "beacon not upgraded");
        require(before != after_, "impl did not change");
        console.log("New impl:", after_, "codesize:", after_.code.length);

        _requireFixedRules(keccak256("zkrules-sim-after-arb"), ARB_ACCOUNT_REGISTRY, ARB_PAYMASTER_HUB);

        console.log("\n=== PASS: SimZkEmailRulesArbitrum ===");
    }
}

/*═══════════════════════════════════ BROADCASTS ═══════════════════════════════════*/

contract Step1_UpgradeGnosis is ZkEmailRulesBase {
    function run() external {
        require(block.chainid == 100, "run on gnosis");
        uint256 key = _signerKey();
        require(vm.addr(key) == ISatelliteZk(GNOSIS_SATELLITE).owner(), "signer must own the Satellite");

        console.log("\n=== Step 1: OrgDeployer v19 on Gnosis ===");
        vm.startBroadcast(key);
        address impl = _deployImpl(DeterministicDeployer(DD));
        // Idempotent: PoaManager.upgradeBeacon reverts SameImplementation() if the beacon already
        // points here, so a re-run would fail the whole broadcast. Skip instead.
        if (!_alreadyLive(GNOSIS_POA_MANAGER, impl)) {
            ISatelliteZk(GNOSIS_SATELLITE).upgradeBeaconDirect("OrgDeployer", impl, VERSION);
        }
        vm.stopBroadcast();

        _requireLive(GNOSIS_POA_MANAGER);
        console.log("Gnosis upgrade: PASS");
    }
}

contract Step2_UpgradeArbitrum is ZkEmailRulesBase {
    function run() external {
        require(block.chainid == 42161, "run on arbitrum");
        uint256 key = _signerKey();
        require(vm.addr(key) == IHubZk(HUB).owner(), "signer must own the Hub");
        require(!IHubZk(HUB).paused(), "Hub is paused");

        console.log("\n=== Step 2: OrgDeployer v19 on Arbitrum ===");
        vm.startBroadcast(key);
        address impl = _deployImpl(DeterministicDeployer(DD));
        if (!_alreadyLive(ARB_POA_MANAGER, impl)) {
            IHubZk(HUB).upgradeBeaconLocal("OrgDeployer", impl, VERSION);
        }
        vm.stopBroadcast();

        _requireLive(ARB_POA_MANAGER);
        console.log("Arbitrum upgrade: PASS");
    }
}

contract Step3_Verify is ZkEmailRulesBase {
    function run() external view {
        console.log("\n=== Verify OrgDeployer v19 (chainid", block.chainid, ") ===");
        _requireLive(block.chainid == 100 ? GNOSIS_POA_MANAGER : ARB_POA_MANAGER);
        console.log("PASS: new orgs auto-whitelist the real ZkEmailInvites claim selectors");
    }
}
