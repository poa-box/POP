// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib} from "../libs/ModuleDeploymentLib.sol";
import {BeaconDeploymentLib} from "../libs/BeaconDeploymentLib.sol";
import {ModuleTypes} from "../libs/ModuleTypes.sol";
import {RoleResolver} from "../libs/RoleResolver.sol";
import {IPoaManager} from "../libs/ModuleDeploymentLib.sol";

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
        // If `zkEmailVerifier` AND `zkEmailDkimRegistry` are both non-zero, a per-org
        // ZkEmailInvites proxy is deployed; otherwise this module is skipped (backwards-compatible
        // for chains where the protocol infra hasn't been wired yet via PoaManager).
        address zkEmailVerifier;
        address zkEmailDkimRegistry;
        address accountRegistry; // UniversalAccountRegistry used by ZkEmailInvites combined-claim flow
        address universalFactory; // UniversalPasskeyAccountFactory used by combined-claim flow (may be 0)
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

        /* 4. Deploy ZkEmailInvites if the protocol infra is wired (conditional, without registration) */
        // Three independent prerequisites must ALL hold for the module to be deployable:
        //   (a) verifier + DKIM registry infra addresses are set (via OrgDeployer.setZkEmailInfrastructure),
        //   (b) the UniversalAccountRegistry address is present, and
        //   (c) PoaManager has a ZkEmailInvites beacon registered on THIS chain.
        // (c) is checked with the non-reverting `beaconRegistered` probe: if the protocol type was
        // never registered here, the module is silently skipped instead of reverting the whole org
        // deploy with `TypeUnknown`. This keeps an optional feature from bricking the core path when
        // infra addresses are wired ahead of the beacon (e.g. on a fresh or satellite chain).
        address zkEmailInvitesBeacon;
        bool zkEmailEnabled = params.zkEmailVerifier != address(0) && params.zkEmailDkimRegistry != address(0)
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

            result.zkEmailInvites = ModuleDeploymentLib.deployZkEmailInvites(
                config,
                params.executor,
                params.zkEmailVerifier,
                params.zkEmailDkimRegistry,
                params.accountRegistry,
                params.universalFactory,
                zkEmailInvitesBeacon
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

        return result;
    }
}
