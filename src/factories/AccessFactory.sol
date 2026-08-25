// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib} from "../libs/ModuleDeploymentLib.sol";
import {BeaconDeploymentLib} from "../libs/BeaconDeploymentLib.sol";
import {ModuleTypes} from "../libs/ModuleTypes.sol";
import {RoleResolver} from "../libs/RoleResolver.sol";
import {IPoaManager} from "../libs/ModuleDeploymentLib.sol";
import {AccessV2Ids} from "../libs/AccessV2Ids.sol";
import {AccessV2Types} from "../libs/AccessV2Types.sol";
import {IMembershipAuthority} from "../interfaces/IMembershipAuthority.sol";
import {OrgAccessSeedLib} from "../libs/OrgAccessSeedLib.sol";
import {RoleConfigStructs} from "../libs/RoleConfigStructs.sol";

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
 * @notice Deploys the org's access layer: the MembershipAuthority, QuickJoin and ParticipationToken.
 * @dev The authority is a BeaconProxy whose constructor data carries `initialize` — it is born
 *      configured (executor, paymasterHub, orgId, genesis seed) in a single transaction, so no
 *      window exists where an uninitialized authority is reachable.
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

    /*──────────────────── Authority Deployment Params ────────────────────*/
    struct AuthorityParams {
        bytes32 orgId;
        address poaManager;
        address orgRegistry;
        address executor;
        address deployer; // OrgDeployer address for registration callbacks
        address paymasterHub;
        bool autoUpgrade;
        RoleConfigStructs.RoleConfig[] roles;
        RoleConfigStructs.GroupConfig[] groups;
        OrgAccessSeedLib.PermConfig perms;
    }

    /*──────────────────── Authority Deployment Result ────────────────────*/
    struct AuthorityResult {
        address authority;
        uint256 adminSubjectId; // sole member is the Executor; the org-admin subject for PaymasterHub
        uint256[] roleSubjectIds; // index-aligned with AuthorityParams.roles
        uint256[] groupSubjectIds; // index-aligned with AuthorityParams.groups
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
        uint256[] roleSubjectIds;
        bool autoUpgrade;
        RoleAssignments roleAssignments;
        PasskeyConfig passkeyConfig; // Passkey infrastructure configuration
        string tokenName; // ParticipationToken name (empty = "<orgName> Token")
        string tokenSymbol; // ParticipationToken symbol (empty = "PT")
    }

    /*──────────────────── Access Deployment Result ────────────────────*/
    struct AccessResult {
        address quickJoin;
        address participationToken;
    }

    /*══════════════  AUTHORITY DEPLOYMENT  ═════════════=*/

    /**
     * @notice Deploys and registers the org's MembershipAuthority, seeded with its genesis shape.
     * @dev Subject ids are NOT read back: the authority allocates them as
     *      `newSubjectId(authority, k + 1)` in seed order, so the caller derives them from the proxy
     *      address alone. Registration follows the atomic initialize in the same transaction, which
     *      keeps the deploy-time config events under the org's subgraph template.
     * @param params Authority deployment parameters
     * @return result The authority proxy plus the admin / role / group subject ids
     */
    function deployAuthority(AuthorityParams memory params) external returns (AuthorityResult memory result) {
        if (
            params.poaManager == address(0) || params.orgRegistry == address(0) || params.executor == address(0)
                || params.paymasterHub == address(0)
        ) {
            revert InvalidAddress();
        }

        address beacon = BeaconDeploymentLib.createBeacon(
            ModuleTypes.MEMBERSHIP_AUTHORITY_ID, params.poaManager, params.executor, params.autoUpgrade, address(0)
        );

        {
            AccessV2Types.OrgAccessSeed memory seed = OrgAccessSeedLib.build(params.roles, params.groups, params.perms);
            bytes memory initData = abi.encodeCall(
                IMembershipAuthority.initialize,
                (IMembershipAuthority.InitConfig({
                        executor: params.executor, paymasterHub: params.paymasterHub, orgId: params.orgId, seed: seed
                    }))
            );
            result.authority = address(new BeaconProxy(beacon, initData));
        }

        uint256 n = params.roles.length;
        uint256 g = params.groups.length;
        result.adminSubjectId = AccessV2Ids.newSubjectId(result.authority, 1);
        result.roleSubjectIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            result.roleSubjectIds[i] =
                AccessV2Ids.newSubjectId(result.authority, uint64(OrgAccessSeedLib.roleRef(i) + 1));
        }
        result.groupSubjectIds = new uint256[](g);
        for (uint256 j; j < g; ++j) {
            result.groupSubjectIds[j] =
                AccessV2Ids.newSubjectId(result.authority, uint64(OrgAccessSeedLib.groupRef(n, j) + 1));
        }

        OrgRegistry.ContractRegistration[] memory registrations = new OrgRegistry.ContractRegistration[](1);
        registrations[0] = OrgRegistry.ContractRegistration({
            typeId: ModuleTypes.MEMBERSHIP_AUTHORITY_ID, proxy: result.authority, beacon: beacon, owner: params.executor
        });
        IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);

        return result;
    }

    /*══════════════  MAIN DEPLOYMENT FUNCTION  ═════════════=*/

    /**
     * @notice Deploys QuickJoin and ParticipationToken for an organization
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
            // Auto-join subjects for new members. Once the authority is wired these are re-derived
            // from the QJ_AUTOJOIN perm rows; the stored list is the rollback-path copy.
            uint256[] memory memberSubjects = RoleResolver.resolveRoleBitmap(
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

            result.quickJoin = ModuleDeploymentLib.deployQuickJoin(
                config, params.executor, params.registryAddr, address(this), memberSubjects, quickJoinBeacon
            );
        }

        /* 2. Deploy Participation Token (without registration) */
        {
            string memory tName = bytes(params.tokenName).length > 0
                ? params.tokenName
                : string(abi.encodePacked(params.orgName, " Token"));
            string memory tSymbol = bytes(params.tokenSymbol).length > 0 ? params.tokenSymbol : "PT";

            uint256[] memory memberSubjects = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.roleAssignments.tokenMemberRolesBitmap
            );

            uint256[] memory approverSubjects = RoleResolver.resolveRoleBitmap(
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

            result.participationToken = ModuleDeploymentLib.deployParticipationToken(
                config, params.executor, tName, tSymbol, memberSubjects, approverSubjects, participationTokenBeacon
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
