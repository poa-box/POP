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
    }

    /*──────────────────── Modules Deployment Result ────────────────────*/
    struct ModulesResult {
        address taskManager;
        address educationHub;
        address paymentManager;
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

            // TEMPORARY SHIM (Task #5): TaskManager now takes a single project-creator capability hat.
            // Pick the first resolved role hat until capability-hat config indexing lands.
            uint256 tmCreatorHat = creatorHats.length > 0 ? creatorHats[0] : 0;

            result.taskManager = ModuleDeploymentLib.deployTaskManager(
                config, params.executor, params.participationToken, tmCreatorHat, taskManagerBeacon, params.deployer
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

            // TEMPORARY SHIM (Task #5): factory still receives role-bitmap arrays, but EducationHub
            // now takes single capability hats. Picks the first resolved hat from each bitmap.
            // Full migration to capability-hat config indexes lands with the factory threading work.
            uint256 educationCreatorHat = creatorHats.length > 0 ? creatorHats[0] : 0;
            uint256 educationMemberHat = memberHats.length > 0 ? memberHats[0] : 0;

            result.educationHub = ModuleDeploymentLib.deployEducationHub(
                config,
                params.executor,
                params.participationToken,
                educationCreatorHat,
                educationMemberHat,
                educationHubBeacon
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

        /* 4. Batch register contracts (2 or 3 depending on EducationHub) */
        {
            uint256 registrationCount = params.educationHubConfig.enabled ? 3 : 2;
            OrgRegistry.ContractRegistration[] memory registrations =
                new OrgRegistry.ContractRegistration[](registrationCount);

            registrations[0] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.TASK_MANAGER_ID,
                proxy: result.taskManager,
                beacon: taskManagerBeacon,
                owner: params.executor
            });

            if (params.educationHubConfig.enabled) {
                registrations[1] = OrgRegistry.ContractRegistration({
                    typeId: ModuleTypes.EDUCATION_HUB_ID,
                    proxy: result.educationHub,
                    beacon: educationHubBeacon,
                    owner: params.executor
                });

                registrations[2] = OrgRegistry.ContractRegistration({
                    typeId: ModuleTypes.PAYMENT_MANAGER_ID,
                    proxy: result.paymentManager,
                    beacon: paymentManagerBeacon,
                    owner: params.executor
                });
            } else {
                registrations[1] = OrgRegistry.ContractRegistration({
                    typeId: ModuleTypes.PAYMENT_MANAGER_ID,
                    proxy: result.paymentManager,
                    beacon: paymentManagerBeacon,
                    owner: params.executor
                });
            }

            // Call OrgDeployer to batch register (not the last batch)
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);
        }

        return result;
    }
}
