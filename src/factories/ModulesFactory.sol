// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib} from "../libs/ModuleDeploymentLib.sol";
import {BeaconDeploymentLib} from "../libs/BeaconDeploymentLib.sol";
import {ModuleTypes} from "../libs/ModuleTypes.sol";
import {RoleResolver} from "../libs/RoleResolver.sol";
import {IPoaManager} from "../libs/ModuleDeploymentLib.sol";
import {ZkEmailInvites} from "../ZkEmailInvites.sol";

/*──────────────────── OrgDeployer interface ────────────────────*/
interface IOrgDeployer {
    function batchRegisterContracts(
        bytes32 orgId,
        OrgRegistry.ContractRegistration[] calldata registrations,
        bool autoUpgrade,
        bool lastRegister
    ) external;
}

/*────────────────────────────  Errors  ───────────────────────────────*/
error InvalidAddress();
error UnsupportedType();

/**
 * @title ModulesFactory
 * @notice Factory contract for deploying functional modules (TaskManager, EducationHub, etc.)
 * @dev Deploys BeaconProxy instances for all module types
 */
contract ModulesFactory {
    /*──────────────────── Role Assignments ────────────────────*/
    struct RoleAssignments {
        uint256 taskCreatorRolesBitmap; // Bit N set = Role N can create tasks
        uint256 educationCreatorRolesBitmap; // Bit N set = Role N can create education
        uint256 educationMemberRolesBitmap; // Bit N set = Role N can access education
    }

    /*──────────────────── EducationHub Configuration ────────────────────*/
    struct EducationHubConfig {
        bool enabled; // Whether to deploy EducationHub
    }

    /*──────────────────── ZkEmailInvites Configuration ────────────────────*/
    /// @notice Per-org opt-in + optional deploy-time allowlist activation for ZK Email role invites.
    /// @dev The allowlist (whole domains + specific emails -> role hat IDs) lives as a JSON file on IPFS,
    ///      committed on-chain by a single merkle root. A founder may activate it at genesis by passing a
    ///      non-zero `initialRoot` + `initialCid` (the tree is built off-chain over the org's genesis hat
    ///      IDs); otherwise the module deploys DORMANT and governance activates it later via
    ///      `setActiveAllowlist`. The module still only deploys if the chain has ZK Email infra wired AND
    ///      the beacon registered.
    struct ZkEmailConfig {
        bool enabled; // Whether to deploy ZkEmailInvites for this org
        bytes32 initialRoot; // Optional active allowlist merkle root at genesis (0 = dormant)
        bytes32 initialCid; // IPFS CID digest of the allowlist file `initialRoot` commits to (0 if dormant)
    }

    /*──────────────────── Modules Deployment Params ────────────────────*/
    struct ModulesParams {
        bytes32 orgId;
        string orgName;
        address poaManager;
        address orgRegistry;
        address hats;
        address executor;
        address deployer; // OrgDeployer address for registration callbacks
        address participationToken;
        uint256[] roleHatIds;
        bool autoUpgrade;
        RoleAssignments roleAssignments;
        EducationHubConfig educationHubConfig; // EducationHub deployment configuration
        // ZK Email Invites infra (deployed once per chain).
        // A per-org ZkEmailInvites proxy is deployed only if zkEmailConfig.enabled AND the chain
        // infra is present (verifier + DKIM + accountRegistry) AND the beacon is registered.
        // Otherwise the module is skipped (backwards-compatible for chains/orgs without it).
        address zkEmailDomainVerifier; // 3-signal PopRoleClaim verifier (domain claims)
        address zkEmailEmailVerifier; // 4-signal PopRoleClaimV2 verifier (specific-address claims)
        address zkEmailDkimRegistry;
        address accountRegistry; // UniversalAccountRegistry used by ZkEmailInvites combined-claim flow
        address universalFactory; // UniversalPasskeyAccountFactory used by combined-claim flow (may be 0)
        ZkEmailConfig zkEmailConfig; // Per-org opt-in + initial allowlist
    }

    /*──────────────────── Modules Deployment Result ────────────────────*/
    struct ModulesResult {
        address taskManager;
        address educationHub;
        address paymentManager;
        // address(0) when ZK Email infra is not wired on this chain — caller MUST handle this.
        address zkEmailInvites;
    }

    /*══════════════  MAIN DEPLOYMENT FUNCTION  ═════════════=*/

    /**
     * @notice Deploys complete functional module infrastructure for an organization
     * @param params Modules deployment parameters
     * @return result Addresses of deployed module components
     */
    function deployModules(ModulesParams memory params) external returns (ModulesResult memory result) {
        if (
            params.poaManager == address(0) || params.orgRegistry == address(0) || params.hats == address(0)
                || params.executor == address(0) || params.participationToken == address(0)
        ) {
            revert InvalidAddress();
        }

        address taskManagerBeacon;
        address educationHubBeacon;
        address paymentManagerBeacon;

        /* 1. Deploy TaskManager (without registration) */
        {
            // Get the role hat IDs for creator permissions
            uint256[] memory creatorHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.taskCreatorRolesBitmap
            );

            taskManagerBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.TASK_MANAGER_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: params.executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            result.taskManager = ModuleDeploymentLib.deployTaskManager(
                config, params.executor, params.participationToken, creatorHats, taskManagerBeacon, params.deployer
            );
        }

        /* 2. Deploy EducationHub if enabled (without registration) */
        if (params.educationHubConfig.enabled) {
            // Get the role hat IDs for creator and member permissions
            uint256[] memory creatorHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.educationCreatorRolesBitmap
            );

            uint256[] memory memberHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.educationMemberRolesBitmap
            );

            educationHubBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.EDUCATION_HUB_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: params.executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            result.educationHub = ModuleDeploymentLib.deployEducationHub(
                config, params.executor, params.participationToken, creatorHats, memberHats, educationHubBeacon
            );
        }

        /* 3. Deploy PaymentManager (without registration) */
        {
            paymentManagerBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.PAYMENT_MANAGER_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: params.executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            result.paymentManager = ModuleDeploymentLib.deployPaymentManager(
                config, params.executor, params.participationToken, paymentManagerBeacon
            );
        }

        /* 4. Deploy ZkEmailInvites if opted in and the protocol infra is wired (without registration) */
        // Four independent prerequisites must ALL hold for the module to be deployable:
        //   (a) the deployer opted in (zkEmailConfig.enabled),
        //   (b) verifier + DKIM registry infra addresses are set (via OrgDeployer.setZkEmailInfrastructure),
        //   (c) the UniversalAccountRegistry address is present, and
        //   (d) PoaManager has a ZkEmailInvites beacon registered on THIS chain.
        // (d) is checked with the non-reverting `beaconRegistered` probe: if the protocol type was
        // never registered here, the module is silently skipped instead of reverting the whole org
        // deploy with `TypeUnknown`. This keeps an optional feature from bricking the core path when
        // infra addresses are wired ahead of the beacon (e.g. on a fresh or satellite chain).
        address zkEmailInvitesBeacon;
        bool zkEmailEnabled = params.zkEmailConfig.enabled && params.zkEmailDomainVerifier != address(0)
            && params.zkEmailEmailVerifier != address(0) && params.zkEmailDkimRegistry != address(0)
            && params.accountRegistry != address(0)
            && BeaconDeploymentLib.beaconRegistered(ModuleTypes.ZKEMAIL_INVITES_ID, params.poaManager);
        if (zkEmailEnabled) {
            zkEmailInvitesBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.ZKEMAIL_INVITES_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: params.executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            // Deploy the proxy UNINITIALIZED here; initialize() runs in step 6 AFTER registration so the
            // subgraph's per-org template (created on ContractRegistered) catches its config + rule events.
            result.zkEmailInvites = ModuleDeploymentLib.deployUninitializedProxy(
                config, ModuleTypes.ZKEMAIL_INVITES_ID, zkEmailInvitesBeacon
            );
        }

        /* 5. Batch register contracts (variable count: TaskManager + PaymentManager + opt. EducationHub + opt. ZkEmailInvites) */
        {
            uint256 registrationCount = 2; // TaskManager + PaymentManager always
            if (params.educationHubConfig.enabled) registrationCount++;
            if (zkEmailEnabled) registrationCount++;

            OrgRegistry.ContractRegistration[] memory registrations =
                new OrgRegistry.ContractRegistration[](registrationCount);

            uint256 idx = 0;
            registrations[idx++] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.TASK_MANAGER_ID,
                proxy: result.taskManager,
                beacon: taskManagerBeacon,
                owner: params.executor
            });

            if (params.educationHubConfig.enabled) {
                registrations[idx++] = OrgRegistry.ContractRegistration({
                    typeId: ModuleTypes.EDUCATION_HUB_ID,
                    proxy: result.educationHub,
                    beacon: educationHubBeacon,
                    owner: params.executor
                });
            }

            registrations[idx++] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.PAYMENT_MANAGER_ID,
                proxy: result.paymentManager,
                beacon: paymentManagerBeacon,
                owner: params.executor
            });

            if (zkEmailEnabled) {
                registrations[idx++] = OrgRegistry.ContractRegistration({
                    typeId: ModuleTypes.ZKEMAIL_INVITES_ID,
                    proxy: result.zkEmailInvites,
                    beacon: zkEmailInvitesBeacon,
                    owner: params.executor
                });
            }

            // Call OrgDeployer to batch register (not the last batch)
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);
        }

        /* 6. Initialize ZkEmailInvites AFTER registration. Its config + ActiveAllowlistSet events thus fire
              after the module's ContractRegistered, so the subgraph's per-org template catches them (no
              eth_calls, deploy-time allowlist indexed). Same tx, before OrgDeployer renounces — see CLAUDE.md. */
        if (zkEmailEnabled) {
            _initZkEmailInvites(params, result.zkEmailInvites);
        }

        return result;
    }

    /// @dev Initializes the (already deployed + registered) ZkEmailInvites proxy: both verifiers, the DKIM
    ///      registry, the account-abstraction wiring, and any deploy-time active allowlist (root + cid).
    function _initZkEmailInvites(ModulesParams memory params, address proxy) private {
        ZkEmailInvites(proxy)
            .initialize(
                params.executor,
                params.zkEmailDomainVerifier,
                params.zkEmailEmailVerifier,
                params.zkEmailDkimRegistry,
                params.accountRegistry,
                params.universalFactory,
                params.zkEmailConfig.initialRoot,
                params.zkEmailConfig.initialCid
            );
    }
}
