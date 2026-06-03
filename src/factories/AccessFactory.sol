// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib} from "../libs/ModuleDeploymentLib.sol";
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

/*──────────────────── QuickJoin passkey configuration ────────────────────*/
interface IQuickJoinPasskeyConfig {
    function setUniversalFactory(address factory) external;
}

/*────────────────────────────  Errors  ───────────────────────────────*/

error InvalidAddress();
error UnsupportedType();

/**
 * @title AccessFactory
 * @notice Factory contract for deploying access control and token infrastructure
 * @dev Deploys BeaconProxy instances for QuickJoin and ParticipationToken
 */
contract AccessFactory {
    /*──────────────────── Role Assignments ────────────────────*/
    struct RoleAssignments {
        uint256 quickJoinRolesBitmap; // Bit N set = Role N assigned on join
        uint256 tokenMemberRolesBitmap; // Bit N set = Role N can hold tokens
        uint256 tokenApproverRolesBitmap; // Bit N set = Role N can approve transfers
    }

    /*──────────────────── Passkey Configuration ────────────────────*/
    struct PasskeyConfig {
        bool enabled; // Whether passkey support is enabled for this org
        address universalFactory; // Reference to universal PasskeyAccountFactory
    }

    /*──────────────────── Access Deployment Params ────────────────────*/
    struct AccessParams {
        bytes32 orgId;
        string orgName;
        address poaManager;
        address orgRegistry;
        address hats;
        address executor;
        address deployer; // OrgDeployer address for registration callbacks
        address registryAddr; // Universal account registry
        address roleBundleHatter; // Per-org RoleBundleHatter (deployed by GovernanceFactory)
        uint256[] roleHatIds;
        bool autoUpgrade;
        RoleAssignments roleAssignments;
        PasskeyConfig passkeyConfig; // Passkey infrastructure configuration
    }

    /*──────────────────── Access Deployment Result ────────────────────*/
    struct AccessResult {
        address quickJoin;
        address participationToken;
    }

    /*══════════════  MAIN DEPLOYMENT FUNCTION  ═════════════=*/

    /**
     * @notice Deploys complete access control infrastructure for an organization
     * @param params Access deployment parameters
     * @return result Addresses of deployed access components
     */
    function deployAccess(AccessParams memory params) external returns (AccessResult memory result) {
        if (
            params.poaManager == address(0) || params.orgRegistry == address(0) || params.hats == address(0)
                || params.executor == address(0)
        ) {
            revert InvalidAddress();
        }

        address quickJoinBeacon;
        address participationTokenBeacon;

        /* 1. Deploy QuickJoin (without registration) */
        {
            // Get the role hat IDs for new members
            uint256[] memory memberHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.quickJoinRolesBitmap
            );

            quickJoinBeacon = _createBeacon(
                ModuleTypes.QUICK_JOIN_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
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

            // TEMPORARY SHIM (Task #5): role-bitmap resolution still produces an array of role hats.
            // For now, the first resolved role hat is used as the member capability hat. Full
            // capability-hat config indexing lands with the OrgDeployer threading work.
            uint256 qjMemberHat = memberHats.length > 0 ? memberHats[0] : 0;

            result.quickJoin = ModuleDeploymentLib.deployQuickJoin(
                config,
                params.executor,
                params.registryAddr,
                address(this),
                qjMemberHat,
                params.roleBundleHatter,
                quickJoinBeacon
            );
        }

        /* 2. Deploy Participation Token (without registration) */
        {
            string memory tName = string(abi.encodePacked(params.orgName, " Token"));
            string memory tSymbol = "PT";

            // Get the role hat IDs for member and approver permissions
            uint256[] memory memberHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.tokenMemberRolesBitmap
            );

            uint256[] memory approverHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.tokenApproverRolesBitmap
            );

            participationTokenBeacon = _createBeacon(
                ModuleTypes.PARTICIPATION_TOKEN_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
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

            // TEMPORARY SHIM (Task #5): ParticipationToken now takes single capability hats.
            // Picks the first resolved hat from each bitmap until factory threading lands.
            uint256 ptMemberHat = memberHats.length > 0 ? memberHats[0] : 0;
            uint256 ptApproverHat = approverHats.length > 0 ? approverHats[0] : 0;

            result.participationToken = ModuleDeploymentLib.deployParticipationToken(
                config, params.executor, tName, tSymbol, ptMemberHat, ptApproverHat, participationTokenBeacon
            );
        }

        /* 3. Configure QuickJoin with universal passkey factory if enabled */
        if (params.passkeyConfig.enabled) {
            if (params.passkeyConfig.universalFactory == address(0)) revert InvalidAddress();
            IQuickJoinPasskeyConfig(result.quickJoin).setUniversalFactory(params.passkeyConfig.universalFactory);
        }

        /* 4. Batch register all contracts */
        {
            OrgRegistry.ContractRegistration[] memory registrations = new OrgRegistry.ContractRegistration[](2);

            registrations[0] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.QUICK_JOIN_ID,
                proxy: result.quickJoin,
                beacon: quickJoinBeacon,
                owner: params.executor
            });

            registrations[1] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.PARTICIPATION_TOKEN_ID,
                proxy: result.participationToken,
                beacon: participationTokenBeacon,
                owner: params.executor
            });

            // Call OrgDeployer to batch register (not the last batch)
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);
        }

        return result;
    }

    /*══════════════  INTERNAL HELPERS  ═════════════=*/

    /**
     * @notice Creates a SwitchableBeacon for a module type
     * @dev Returns a beacon address that points to the implementation
     */
    function _createBeacon(
        bytes32 typeId,
        address poaManager,
        address moduleOwner,
        bool autoUpgrade,
        address customImpl
    ) internal returns (address beacon) {
        IPoaManager poa = IPoaManager(poaManager);

        address poaBeacon = poa.getBeaconById(typeId);
        if (poaBeacon == address(0)) revert UnsupportedType();

        address initImpl = address(0);
        SwitchableBeacon.Mode beaconMode = SwitchableBeacon.Mode.Mirror;

        if (!autoUpgrade) {
            // For static mode, get the current implementation
            initImpl = (customImpl == address(0)) ? poa.getCurrentImplementationById(typeId) : customImpl;
            if (initImpl == address(0)) revert UnsupportedType();
            beaconMode = SwitchableBeacon.Mode.Static;
        }

        // Create SwitchableBeacon with appropriate configuration
        beacon = address(new SwitchableBeacon(moduleOwner, poaBeacon, initImpl, beaconMode));
    }
}
