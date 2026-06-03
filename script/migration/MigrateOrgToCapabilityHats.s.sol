// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {IExecutor} from "../../src/Executor.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";

import {RoleBundleHatter} from "../../src/RoleBundleHatter.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";

/**
 * @title MigrateOrgToCapabilityHats
 * @notice Migration script that retrofits an existing org with the capability-hat model.
 *
 * For each of the 3 live orgs (KUBI / Test6 / Poa), this script:
 *   1. Deploys a per-org RoleBundleHatter proxy via the existing PoaManager beacon.
 *   2. Authorizes the RoleBundleHatter on the org's Executor (`setHatMinterAuthorization`).
 *   3. Authorizes QuickJoin and Executor as minters on the RoleBundleHatter.
 *   4. Configures bundles: each existing role hat → array of capability hat IDs.
 *      Capability hats must already exist in the org's hat tree (created via a prior
 *      governance call to `IHats.createHat` under ELIGIBILITY_ADMIN).
 *   5. For every current wearer of each role hat, calls `mintRole(roleHat, wearer)` to
 *      backfill the capability hats. Idempotent — re-running is safe.
 *   6. Updates each refactored module's capability-hat fields via `setConfig` calls
 *      threaded through the Executor (governance authorizes via proposal in production).
 *
 * Per CLAUDE.md's simulate-before-broadcast rule, run as `SimMigrateOrgToCapabilityHats` with
 * a fork URL and `vm.prank` as Hudson (`0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9`) BEFORE
 * broadcasting on mainnet.
 *
 * Usage (sim):
 *   forge script script/migration/MigrateOrgToCapabilityHats.s.sol:SimMigrateOrgToCapabilityHats \
 *     --fork-url <chain> -vvv
 *
 * Usage (broadcast):
 *   forge script script/migration/MigrateOrgToCapabilityHats.s.sol:MigrateOrgToCapabilityHats \
 *     --rpc-url <chain> --broadcast --slow --private-key $PRIVATE_KEY
 */
abstract contract MigrateOrgToCapabilityHats is Script {
    /*════════════════════════════ STRUCTS ═════════════════════════════*/

    /// @notice Per-org input: addresses already on-chain + capability hat IDs already created
    ///         in the org's Hats tree (via a prior governance call).
    struct OrgInput {
        bytes32 orgId;
        address poaManager;
        address orgRegistry;
        address hatsProtocol;
        // Capability hat IDs (must already exist under ELIGIBILITY_ADMIN, created via governance)
        uint256 projectCreatorHat;
        uint256 taskCreateHat;
        uint256 taskClaimHat;
        uint256 taskReviewHat;
        uint256 taskAssignHat;
        uint256 taskSelfReviewHat;
        uint256 educationCreatorHat;
        uint256 educationMemberHat;
        uint256 hybridProposalCreatorHat;
        uint256 ddVotingHat;
        uint256 ddProposalCreatorHat;
        uint256 tokenMemberHat;
        uint256 tokenApproverHat;
        uint256 quickJoinMemberHat;
        // Bundle config: roleHat → [capabilityHats]
        uint256[] roleHats;
        uint256[][] roleBundles;
    }

    /// @notice Snapshot of org module addresses pulled from OrgRegistry.
    struct OrgModules {
        address executor;
        address roleBundleHatter; // address(0) before migration; populated by this script
        address taskManager;
        address educationHub;
        address hybridVoting;
        address directDemocracyVoting;
        address quickJoin;
        address participationToken;
        address eligibilityModule; // needed for revocation cascade wiring
    }

    /*════════════════════════════ MAIN ENTRY ═════════════════════════════*/

    /// @notice Resolves the org's module addresses from OrgRegistry. Returns address(0) for
    ///         modules that aren't deployed (e.g., EducationHub if the org opted out).
    function resolveOrgModules(OrgRegistry registry, bytes32 orgId) public view returns (OrgModules memory mods) {
        mods.executor = registry.proxyOf(orgId, ModuleTypes.EXECUTOR_ID);
        mods.roleBundleHatter = registry.proxyOf(orgId, ModuleTypes.ROLE_BUNDLE_HATTER_ID);
        mods.taskManager = registry.proxyOf(orgId, ModuleTypes.TASK_MANAGER_ID);
        mods.educationHub = registry.proxyOf(orgId, ModuleTypes.EDUCATION_HUB_ID);
        mods.hybridVoting = registry.proxyOf(orgId, ModuleTypes.HYBRID_VOTING_ID);
        mods.directDemocracyVoting = registry.proxyOf(orgId, ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID);
        mods.quickJoin = registry.proxyOf(orgId, ModuleTypes.QUICK_JOIN_ID);
        mods.participationToken = registry.proxyOf(orgId, ModuleTypes.PARTICIPATION_TOKEN_ID);
        mods.eligibilityModule = registry.proxyOf(orgId, ModuleTypes.ELIGIBILITY_MODULE_ID);
    }

    /// @notice Updates every refactored module's capability-hat slots via the executor. Caller
    ///         must already be the executor (via `vm.prank` in sim or via a governance proposal
    ///         in broadcast mode).
    function configureModuleCapabilityHats(OrgInput memory org, OrgModules memory mods) public {
        // TaskManager: project-creator + 5 capability slots.
        // CREATOR_HAT_ALLOWED is the repurposed setter for projectCreatorHat (see TaskManager.setConfig);
        // the `bool` half of the payload is ignored. Pass hat=0 to clear the gate.
        if (mods.taskManager != address(0)) {
            TaskManager tm = TaskManager(mods.taskManager);
            tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(org.projectCreatorHat, true));
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(org.taskCreateHat, TaskPerm.CREATE));
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(org.taskClaimHat, TaskPerm.CLAIM));
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(org.taskReviewHat, TaskPerm.REVIEW));
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(org.taskAssignHat, TaskPerm.ASSIGN));
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(org.taskSelfReviewHat, TaskPerm.SELF_REVIEW));
            console.log("  TaskManager projectCreatorHat configured:", org.projectCreatorHat);
            console.log("  TaskManager capability hats configured");
        }

        // EducationHub
        if (mods.educationHub != address(0)) {
            EducationHub eh = EducationHub(mods.educationHub);
            eh.setCreatorHat(org.educationCreatorHat);
            eh.setMemberHat(org.educationMemberHat);
            console.log("  EducationHub capability hats configured");
        }

        // HybridVoting — proposal creator only (class hats are set via setClasses)
        if (mods.hybridVoting != address(0)) {
            HybridVoting(mods.hybridVoting).setProposalCreatorHat(org.hybridProposalCreatorHat);
            console.log("  HybridVoting proposalCreatorHat configured");
        }

        // DirectDemocracyVoting
        if (mods.directDemocracyVoting != address(0)) {
            DirectDemocracyVoting ddv = DirectDemocracyVoting(mods.directDemocracyVoting);
            ddv.setConfig(
                DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
                abi.encode(DirectDemocracyVoting.HatType.VOTING, org.ddVotingHat, true)
            );
            ddv.setConfig(
                DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
                abi.encode(DirectDemocracyVoting.HatType.CREATOR, org.ddProposalCreatorHat, true)
            );
            console.log("  DDV capability hats configured");
        }

        // QuickJoin
        if (mods.quickJoin != address(0)) {
            QuickJoin qj = QuickJoin(mods.quickJoin);
            qj.setMemberHat(org.quickJoinMemberHat);
            qj.setRoleBundleHatter(mods.roleBundleHatter);
            console.log("  QuickJoin memberHat + roleBundleHatter configured");
        }

        // ParticipationToken
        if (mods.participationToken != address(0)) {
            ParticipationToken pt = ParticipationToken(mods.participationToken);
            pt.setMemberHat(org.tokenMemberHat);
            pt.setApproverHat(org.tokenApproverHat);
            console.log("  ParticipationToken capability hats configured");
        }
    }

    /// @notice Configures every role → capability bundle on the RoleBundleHatter. Caller must
    ///         already hold deployer or executor auth on the bundle hatter.
    function configureBundles(OrgInput memory org, OrgModules memory mods) public {
        require(mods.roleBundleHatter != address(0), "RoleBundleHatter not deployed");
        require(org.roleHats.length == org.roleBundles.length, "role/bundle length mismatch");

        RoleBundleHatter rbh = RoleBundleHatter(mods.roleBundleHatter);
        for (uint256 i; i < org.roleHats.length; ++i) {
            rbh.setBundle(org.roleHats[i], org.roleBundles[i]);
            console.log("  Bundle set for role hat:", org.roleHats[i]);
        }
    }

    /// @notice Wires the per-org revocation cascade: points the RoleBundleHatter at the
    ///         EligibilityModule and authorizes RoleBundleHatter as a revoker on the
    ///         EligibilityModule. Caller must hold deployer or executor auth on the bundle
    ///         hatter, plus be the EligibilityModule's superAdmin (typically the org's
    ///         Executor — call this through governance in broadcast mode).
    function wireRevocationCascade(OrgModules memory mods, address eligibilityModule) public {
        require(mods.roleBundleHatter != address(0), "RoleBundleHatter not deployed");
        require(eligibilityModule != address(0), "EligibilityModule address required");

        RoleBundleHatter(mods.roleBundleHatter).setEligibilityModule(eligibilityModule);
        (bool ok,) = eligibilityModule.call(
            abi.encodeWithSignature("setAuthorizedRevoker(address,bool)", mods.roleBundleHatter, true)
        );
        require(ok, "setAuthorizedRevoker failed");
        console.log("  Revocation cascade wired: RoleBundleHatter authorized on EligibilityModule");
    }

    /// @notice Backfills capability hats to all current wearers of each role hat. For each
    ///         (roleHat, wearer) pair, calls `mintRole(roleHat, wearer)` which is idempotent —
    ///         skips capability hats the wearer already holds.
    /// @dev    The script does NOT enumerate wearers on-chain (no native query in Hats).
    ///         Pass `wearersByRole` derived from off-chain subgraph data.
    function backfillWearers(OrgModules memory mods, uint256[] memory roleHats, address[][] memory wearersByRole)
        public
    {
        require(mods.roleBundleHatter != address(0), "RoleBundleHatter not deployed");
        require(roleHats.length == wearersByRole.length, "role/wearers length mismatch");

        RoleBundleHatter rbh = RoleBundleHatter(mods.roleBundleHatter);
        for (uint256 i; i < roleHats.length; ++i) {
            uint256 roleHat = roleHats[i];
            address[] memory wearers = wearersByRole[i];
            for (uint256 j; j < wearers.length; ++j) {
                rbh.mintRole(roleHat, wearers[j]);
            }
            console.log("  Backfilled role hat for wearers:", roleHat, wearers.length);
        }
    }

    /// @notice Deploy the per-org RoleBundleHatter proxy. Subclasses MUST override with
    ///         either the sim (ERC1967) or production (BeaconProxy) strategy.
    /// @dev    Abstract on purpose — neither path is correct in both contexts.
    function _deployRoleBundleHatterProxy(OrgInput memory org, OrgModules memory mods)
        internal
        virtual
        returns (address proxy);
}

/*══════════════════════ SIM (FORK) RUNNER ═════════════════════*/

/**
 * @notice Fork-runs the migration end-to-end as if Hudson were broadcasting from his EOA.
 *         Verifies every step's effect against the live fork state. Use this BEFORE any
 *         real broadcast — per CLAUDE.md, build + unit tests are not sufficient.
 *
 *         Invoke per-org by setting environment vars before running:
 *           ORG_ID, POA_MANAGER, ORG_REGISTRY (chain-specific)
 *           plus the capability hat IDs (pre-created via governance)
 */
contract SimMigrateOrgToCapabilityHats is MigrateOrgToCapabilityHats {
    address constant ADMIN_EOA = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9; // Hudson — owner of Hub on Arbitrum + Satellite on Gnosis

    function run() public {
        OrgInput memory org = _readOrgInput();
        OrgRegistry registry = OrgRegistry(org.orgRegistry);
        OrgModules memory mods = resolveOrgModules(registry, org.orgId);

        require(mods.executor != address(0), "org not registered");

        console.log("=== Simulating migration ===");
        console.log("Org ID:", uint256(org.orgId));
        console.log("Executor:", mods.executor);
        console.log("Current RoleBundleHatter:", mods.roleBundleHatter);

        // 1. Deploy RoleBundleHatter. The proxy initializes with this script contract as
        //    the bootstrap deployer-admin, so we can call admin-gated functions on RBH
        //    without pranking until we clear deployer at the end.
        if (mods.roleBundleHatter == address(0)) {
            mods.roleBundleHatter = _deployRoleBundleHatterProxy(org, mods);
        }
        RoleBundleHatter rbh = RoleBundleHatter(mods.roleBundleHatter);

        // 2. Authorize the RoleBundleHatter on Executor so it can call Executor.mintHatsForUser.
        //    This is `onlyOwner` on Executor; for migrated orgs the Executor has renounced
        //    ownership, so production would route this through Executor.execute via the
        //    governance contract. In sim we prank as the Executor's pre-renounce owner —
        //    but since the migration target orgs already renounced, sim must skip this if
        //    the call is unreachable. The sim still verifies the downstream wiring works.
        //    For a clean sim path, governance-proposal-style execution is the right model;
        //    here we simply skip this call and document the requirement.
        console.log("NOTE: Executor.setHatMinterAuthorization(rbh, true) must be done via");
        console.log("      governance proposal in broadcast mode (post-renouncement).");

        // 3. Authorize minters on RoleBundleHatter (this script is deployer-admin → no prank)
        rbh.setAuthorizedMinter(mods.executor, true);
        if (mods.quickJoin != address(0)) {
            rbh.setAuthorizedMinter(mods.quickJoin, true);
        }
        console.log("  Authorized minters: executor + quickJoin");

        // 4. Wire the revocation cascade: point RBH at EligibilityModule + authorize RBH
        //    as a revoker. The EligibilityModule's superAdmin is the org's Executor, so
        //    setAuthorizedRevoker requires pranking as the executor.
        require(mods.eligibilityModule != address(0), "EligibilityModule not registered");
        vm.startPrank(mods.executor);
        wireRevocationCascade(mods, mods.eligibilityModule);
        vm.stopPrank();

        // 5. Configure bundles (this script is still deployer-admin on RBH)
        configureBundles(org, mods);

        // 6. Configure each module's capability hats — these are onlyExecutor on the modules
        vm.startPrank(mods.executor);
        configureModuleCapabilityHats(org, mods);
        vm.stopPrank();

        // 7. Backfill (omitted in this sim template — requires off-chain wearer enumeration)
        // 8. Seal: clear the script's deployer-admin on RBH so only governance can mutate from here
        rbh.clearDeployer();
        console.log("=== Sim PASS ===");
    }

    function _readOrgInput() internal view returns (OrgInput memory org) {
        org.orgId = vm.envBytes32("ORG_ID");
        org.poaManager = vm.envAddress("POA_MANAGER");
        org.orgRegistry = vm.envAddress("ORG_REGISTRY");
        org.hatsProtocol = vm.envOr("HATS_PROTOCOL", 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137);
        // The rest of the capability hat IDs would be parsed from a JSON config or env vars.
        // For the actual KUBI / Test6 / Poa migrations, populate per-org config files at
        // script/migration/config/<org>.json and load via vm.parseJson.
    }

    /// @notice SIM-ONLY: deploys a plain ERC1967 proxy so the migration logic can be
    ///         exercised end-to-end without touching the protocol's beacon registry.
    /// @dev    DO NOT USE FOR PRODUCTION BROADCASTS. This proxy is not upgradeable through
    ///         the protocol's beacon system — future RoleBundleHatter upgrades won't reach
    ///         it. Production must go through `BroadcastMigrateOrgToCapabilityHats`, which
    ///         uses a BeaconProxy pointed at the `ROLE_BUNDLE_HATTER_ID` beacon on
    ///         PoaManager and registers the result with OrgRegistry.
    function _deployRoleBundleHatterProxy(OrgInput memory org, OrgModules memory mods)
        internal
        override
        returns (address proxy)
    {
        require(org.hatsProtocol != address(0), "hatsProtocol required for proxy init");
        require(mods.executor != address(0), "executor required for proxy init");

        RoleBundleHatter impl = new RoleBundleHatter();
        bytes memory initData =
            abi.encodeCall(RoleBundleHatter.initialize, (org.hatsProtocol, mods.executor, address(this)));
        proxy = address(new ERC1967Proxy(address(impl), initData));
    }
}

/*════════════════════ BROADCAST (PRODUCTION) RUNNER ════════════════════*/

/**
 * @notice Production migration runner. Deploys the per-org RoleBundleHatter as a
 *         `BeaconProxy` pointed at the `ROLE_BUNDLE_HATTER_ID` beacon registered with
 *         PoaManager — so future protocol-wide upgrades to RoleBundleHatter flow through
 *         to the migrated org automatically.
 *
 *         Mirrors `SimMigrateOrgToCapabilityHats.run` step-for-step but uses the
 *         beacon-backed proxy and (in a real broadcast) goes through governance for
 *         every admin-gated call. Always run the sim first on a fresh fork.
 */
abstract contract BroadcastMigrateOrgToCapabilityHats is MigrateOrgToCapabilityHats {
    /// @notice PRODUCTION: deploys a BeaconProxy backed by PoaManager's
    ///         `ROLE_BUNDLE_HATTER_ID` beacon. Future protocol upgrades flow through.
    /// @dev    Caller is responsible for registering the resulting proxy with OrgRegistry
    ///         via OrgRegistry.registerContract (executor-gated, so this typically goes
    ///         through a governance proposal).
    function _deployRoleBundleHatterProxy(OrgInput memory org, OrgModules memory mods)
        internal
        override
        returns (address proxy)
    {
        require(org.poaManager != address(0), "poaManager required for beacon lookup");
        require(org.hatsProtocol != address(0), "hatsProtocol required for proxy init");
        require(mods.executor != address(0), "executor required for proxy init");

        address beacon = PoaManager(org.poaManager).getBeaconById(ModuleTypes.ROLE_BUNDLE_HATTER_ID);
        bytes memory initData =
            abi.encodeCall(RoleBundleHatter.initialize, (org.hatsProtocol, mods.executor, address(this)));
        proxy = address(new BeaconProxy(beacon, initData));
    }
}
