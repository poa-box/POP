// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib, IHybridVotingInit} from "../libs/ModuleDeploymentLib.sol";
import {BeaconDeploymentLib} from "../libs/BeaconDeploymentLib.sol";
import {ModuleTypes} from "../libs/ModuleTypes.sol";
import {RoleResolver} from "../libs/RoleResolver.sol";
import {IPoaManager} from "../libs/ModuleDeploymentLib.sol";
import {RoleConfigStructs} from "../libs/RoleConfigStructs.sol";

/*──────────────────── UniversalAccountRegistry interface ────────────────────*/
interface IUniversalAccountRegistry {
    function getUsername(address account) external view returns (string memory);
    function registerAccountBySig(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external;
}

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
 * @title GovernanceFactory
 * @notice Factory for the org's Executor and its two voting modules.
 * @dev Deploys BeaconProxy instances, NOT implementation contracts. Access v2: there is no Hats
 *      tree, no EligibilityModule and no ToggleModule — membership lives in the org's
 *      MembershipAuthority, which AccessFactory deploys against the Executor produced here. Every
 *      `uint256` role id flowing through this factory is an authority SUBJECT id.
 */
contract GovernanceFactory {
    /*──────────────────── Governance Deployment Params ────────────────────*/
    struct GovernanceParams {
        bytes32 orgId;
        string orgName;
        address poaManager;
        address orgRegistry;
        address hats; // Hats Protocol address stored on the Executor (legacy read path / rollback target)
        address deployer; // OrgDeployer address for registration callbacks
        address deployerAddress; // Founder address
        address accountRegistry; // UniversalAccountRegistry for username registration
        address participationToken; // Token for HybridVoting
        string deployerUsername; // Optional username (empty string = skip)
        uint256 regDeadline; // EIP-712 signature deadline (0 = skip registration)
        uint256 regNonce; // User's current nonce on the registry
        bytes regSignature; // User's EIP-712 ECDSA signature for username registration
        bool autoUpgrade;
        uint8 hybridThresholdPct; // Support threshold for HybridVoting
        uint8 ddThresholdPct; // Support threshold for DirectDemocracyVoting
        IHybridVotingInit.ClassConfig[] hybridClasses; // Voting class configuration
        uint256 hybridProposalCreatorRolesBitmap; // Bit N set = Role N can create proposals
        uint256 ddVotingRolesBitmap; // Bit N set = Role N can vote in polls
        uint256 ddCreatorRolesBitmap; // Bit N set = Role N can create polls
        address[] ddInitialTargets; // Allowed execution targets for DirectDemocracyVoting
        RoleConfigStructs.RoleConfig[] roles; // Complete role configuration
        uint32 hybridQuorum; // Min voter count for HybridVoting proposals (0 = disabled)
        uint32 ddQuorum; // Min voter count for DirectDemocracyVoting polls (0 = disabled)
    }

    /*──────────────────── Governance Deployment Result ────────────────────*/
    struct GovernanceResult {
        address executor;
        address execBeacon; // Executor's SwitchableBeacon (for two-step ownership acceptance)
    }

    /*══════════════  INFRASTRUCTURE DEPLOYMENT  ═════════════=*/

    /**
     * @notice Deploys the org's Executor and registers the founder's username if requested.
     * @dev Called FIRST: the Executor address is the root gate every later module — the
     *      MembershipAuthority included — is initialized against.
     * @param params Governance deployment parameters
     * @return result The Executor proxy and its beacon (ownership transfer is two-step)
     */
    function deployInfrastructure(GovernanceParams memory params) external returns (GovernanceResult memory result) {
        if (params.poaManager == address(0) || params.orgRegistry == address(0) || params.hats == address(0)) {
            revert InvalidAddress();
        }

        /* 1. Register the founder's username (needs a non-empty username AND signature data) */
        if (
            params.accountRegistry != address(0) && bytes(params.deployerUsername).length > 0
                && params.regSignature.length > 0
        ) {
            IUniversalAccountRegistry registry = IUniversalAccountRegistry(params.accountRegistry);
            if (bytes(registry.getUsername(params.deployerAddress)).length == 0) {
                registry.registerAccountBySig(
                    params.deployerAddress,
                    params.deployerUsername,
                    params.regDeadline,
                    params.regNonce,
                    params.regSignature
                );
            }
        }

        /* 2. Deploy the Executor with temporary ownership */
        address execBeacon = BeaconDeploymentLib.createBeacon(
            ModuleTypes.EXECUTOR_ID,
            params.poaManager,
            address(this), // temporary owner
            params.autoUpgrade,
            address(0)
        );
        {
            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: address(this),
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            result.executor = ModuleDeploymentLib.deployExecutor(config, params.deployer, execBeacon);
        }

        /* 3. Register the Executor */
        {
            OrgRegistry.ContractRegistration[] memory registrations = new OrgRegistry.ContractRegistration[](1);
            registrations[0] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.EXECUTOR_ID, proxy: result.executor, beacon: execBeacon, owner: address(this)
            });
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);
        }

        /* 4. Initiate the two-step beacon ownership transfer to the Executor */
        SwitchableBeacon(execBeacon).transferOwnership(result.executor);
        result.execBeacon = execBeacon;

        return result;
    }

    /*══════════════  VOTING DEPLOYMENT  ═════════════=*/

    /**
     * @notice Deploys voting mechanisms for an organization
     * @dev Called AFTER AccessFactory to ensure participationToken exists
     * @param params Governance deployment parameters (must include participationToken address)
     * @param executor Address of the executor (from deployInfrastructure)
     * @param roleSubjectIds Authority subject ids for the org's roles (index-aligned with params.roles)
     * @return hybridVoting Address of deployed HybridVoting contract
     * @return directDemocracyVoting Address of deployed DirectDemocracyVoting contract
     */
    function deployVoting(GovernanceParams memory params, address executor, uint256[] memory roleSubjectIds)
        external
        returns (address hybridVoting, address directDemocracyVoting)
    {
        if (executor == address(0) || params.participationToken == address(0)) {
            revert InvalidAddress();
        }

        address hybridBeacon;
        address ddBeacon;

        /* 1. Deploy HybridVoting (Governance Mechanism) */
        {
            // Update voting classes with token addresses and class subject ids. Classes with an empty
            // id list are backfilled with the subjects of canVote=true roles ONLY, so RoleConfig.canVote
            // decides hybrid-voting membership at deploy time (bots/agents with canVote=false are
            // excluded without a post-deploy setClasses proposal).
            IHybridVotingInit.ClassConfig[] memory finalClasses = _updateClassesWithTokenAndHats(
                params.hybridClasses, params.participationToken, _filterCanVoteHats(params.roles, roleSubjectIds)
            );

            hybridBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.HYBRID_VOTING_ID, params.poaManager, executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            hybridVoting = ModuleDeploymentLib.deployHybridVoting(
                config, executor, params.hybridThresholdPct, params.hybridQuorum, finalClasses, hybridBeacon
            );
        }

        /* 2. Deploy DirectDemocracyVoting (Polling Mechanism) */
        {
            ddBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, params.poaManager, executor, params.autoUpgrade, address(0)
            );

            ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
                poaManager: IPoaManager(params.poaManager),
                orgRegistry: OrgRegistry(params.orgRegistry),
                hats: params.hats,
                orgId: params.orgId,
                moduleOwner: executor,
                autoUpgrade: params.autoUpgrade,
                customImpl: address(0)
            });

            directDemocracyVoting = ModuleDeploymentLib.deployDirectDemocracyVoting(
                config, executor, params.ddInitialTargets, params.ddThresholdPct, params.ddQuorum, ddBeacon
            );
        }

        /* 3. Batch register both voting contracts */
        {
            OrgRegistry.ContractRegistration[] memory registrations = new OrgRegistry.ContractRegistration[](2);

            registrations[0] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.HYBRID_VOTING_ID, proxy: hybridVoting, beacon: hybridBeacon, owner: executor
            });

            registrations[1] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID,
                proxy: directDemocracyVoting,
                beacon: ddBeacon,
                owner: executor
            });

            // Call OrgDeployer to batch register (this is the LAST batch - finalizes bootstrap)
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, true);
        }

        return (hybridVoting, directDemocracyVoting);
    }

    /*══════════════  INTERNAL HELPERS  ═════════════=*/

    /**
     * @notice Returns the subset of `roleSubjectIds` whose role has `canVote == true`.
     * @dev Falls back to ALL role subjects when no role has canVote set (a degenerate config —
     *      matches the historical backfill rather than bricking the org with an unvotable governance
     *      module). `roles` and `roleSubjectIds` are index-aligned.
     */
    function _filterCanVoteHats(RoleConfigStructs.RoleConfig[] memory roles, uint256[] memory roleSubjectIds)
        internal
        pure
        returns (uint256[] memory)
    {
        if (roles.length != roleSubjectIds.length) {
            return roleSubjectIds; // defensive: only filter when index-aligned
        }
        uint256 count;
        for (uint256 i = 0; i < roles.length; i++) {
            if (roles[i].canVote) count++;
        }
        if (count == 0 || count == roleSubjectIds.length) {
            return roleSubjectIds;
        }
        uint256[] memory voterSubjects = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < roles.length; i++) {
            if (roles[i].canVote) {
                voterSubjects[j++] = roleSubjectIds[i];
            }
        }
        return voterSubjects;
    }

    /**
     * @notice Fills in missing token addresses and class electorates.
     *
     *      ┌──────────────────────── H-06 SECURITY INVARIANT ────────────────────────┐
     *      │ Every ERC20_BAL class reads a LIVE balance at vote time (HybridVotingCore │
     *      │ ._calculateClassPower). The asset assigned here MUST be non-transferable / │
     *      │ soulbound. A transferable ERC20 lets a voter flash-loan a huge balance,    │
     *      │ vote with inflated power, and return it in the same block — a flash-loan   │
     *      │ governance attack. When `asset == 0` we backfill the org's Participation   │
     *      │ Token, which is SAFE precisely because PT is soulbound (non-transferable). │
     *      │ Callers that pass a non-zero `asset` are responsible for guaranteeing that │
     *      │ token is likewise non-transferable.                                        │
     *      └────────────────────────────────────────────────────────────────────────────┘
     */
    function _updateClassesWithTokenAndHats(
        IHybridVotingInit.ClassConfig[] memory classes,
        address token,
        uint256[] memory roleSubjectIds
    ) internal pure returns (IHybridVotingInit.ClassConfig[] memory) {
        for (uint256 i = 0; i < classes.length; i++) {
            if (classes[i].strategy == IHybridVotingInit.ClassStrategy.ERC20_BAL) {
                // Fill in token address if not provided (defaults to the soulbound PT — safe).
                if (classes[i].asset == address(0)) {
                    classes[i].asset = token;
                }
            }
            // For both DIRECT and ERC20_BAL, use all role subjects if the electorate is unspecified.
            if (classes[i].hatIds.length == 0) {
                classes[i].hatIds = roleSubjectIds;
            }
        }
        return classes;
    }
}
