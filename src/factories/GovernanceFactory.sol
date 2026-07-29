// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import "../OrgRegistry.sol";
import {ModuleDeploymentLib, IHybridVotingInit} from "../libs/ModuleDeploymentLib.sol";
import {BeaconDeploymentLib} from "../libs/BeaconDeploymentLib.sol";
import {ModuleTypes} from "../libs/ModuleTypes.sol";
import {RoleResolver} from "../libs/RoleResolver.sol";
import {IPoaManager} from "../libs/ModuleDeploymentLib.sol";
import {IEligibilityModule, IToggleModule} from "../interfaces/IHatsModules.sol";
import {RoleConfigStructs} from "../libs/RoleConfigStructs.sol";

/*──────────────────── HatsTreeSetup interface ────────────────────*/
interface IHatsTreeSetup {
    struct SetupResult {
        uint256 topHatId;
        uint256[] roleHatIds;
        address eligibilityModule;
        address toggleModule;
    }

    struct SetupParams {
        IHats hats;
        OrgRegistry orgRegistry;
        bytes32 orgId;
        address eligibilityModule;
        address toggleModule;
        address deployer;
        address deployerAddress;
        address executor;
        address accountRegistry;
        string orgName;
        string deployerUsername;
        uint256 regDeadline;
        uint256 regNonce;
        bytes regSignature;
        RoleConfigStructs.RoleConfig[] roles;
    }

    function setupHatsTree(SetupParams memory params) external returns (SetupResult memory);
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
 * @notice Factory contract for deploying governance infrastructure (Executor, Hats modules)
 * @dev Deploys BeaconProxy instances, NOT implementation contracts
 */
contract GovernanceFactory {
    /*──────────────────── Governance Deployment Params ────────────────────*/
    struct GovernanceParams {
        bytes32 orgId;
        string orgName;
        address poaManager;
        address orgRegistry;
        address hats;
        address hatsTreeSetup;
        address deployer; // OrgDeployer address for registration callbacks
        address deployerAddress; // Address to receive ADMIN hat
        address accountRegistry; // UniversalAccountRegistry for username registration
        address participationToken; // Token for HybridVoting
        string deployerUsername; // Optional username for deployer (empty string = skip registration)
        uint256 regDeadline; // EIP-712 signature deadline (0 = skip registration)
        uint256 regNonce; // User's current nonce on the registry
        bytes regSignature; // User's EIP-712 ECDSA signature for username registration
        bool autoUpgrade;
        uint8 hybridThresholdPct; // Support threshold for HybridVoting
        uint8 hybridEarlyCloseTurnoutPct; // Min turnout % for early-close (1..100; 100 = wait for everyone)
        uint8 ddThresholdPct; // Support threshold for DirectDemocracyVoting
        IHybridVotingInit.ClassConfig[] hybridClasses; // Voting class configuration
        uint256 hybridProposalCreatorRolesBitmap; // Bit N set = Role N can create proposals
        uint256 ddVotingRolesBitmap; // Bit N set = Role N can vote in polls
        uint256 ddCreatorRolesBitmap; // Bit N set = Role N can create polls
        address[] ddInitialTargets; // Allowed execution targets for DirectDemocracyVoting
        RoleConfigStructs.RoleConfig[] roles; // Complete role configuration
    }

    /*──────────────────── Governance Deployment Result ────────────────────*/
    struct GovernanceResult {
        address executor;
        address eligibilityModule;
        address toggleModule;
        address hybridVoting; // Governance mechanism
        address directDemocracyVoting; // Polling mechanism
        address execBeacon; // Executor's SwitchableBeacon (for two-step ownership acceptance)
        uint256 topHatId;
        uint256[] roleHatIds;
    }

    /*══════════════  INFRASTRUCTURE DEPLOYMENT  ═════════════=*/

    /**
     * @notice Deploys governance infrastructure (Executor, Hats modules, Hats tree)
     * @dev Called BEFORE AccessFactory. Voting mechanisms deployed separately after token exists.
     * @param params Governance deployment parameters
     * @return result Addresses and IDs of deployed governance components (voting addresses will be zero)
     */
    function deployInfrastructure(GovernanceParams memory params) external returns (GovernanceResult memory result) {
        if (
            params.poaManager == address(0) || params.orgRegistry == address(0) || params.hats == address(0)
                || params.hatsTreeSetup == address(0)
        ) {
            revert InvalidAddress();
        }

        /* 1. Deploy Executor with temporary ownership (without registration) */
        address execBeacon;
        address eligibilityBeacon;
        address toggleBeacon;
        {
            execBeacon = BeaconDeploymentLib.createBeacon(
                ModuleTypes.EXECUTOR_ID,
                params.poaManager,
                address(this), // temporary owner
                params.autoUpgrade,
                address(0) // no custom impl
            );

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

        /* 2. Deploy and configure modules for Hats tree (without registration) */
        (result.eligibilityModule, eligibilityBeacon) = _deployEligibilityModule(
            params.orgId, params.poaManager, params.orgRegistry, params.hats, params.autoUpgrade, result.executor
        );

        (result.toggleModule, toggleBeacon) = _deployToggleModule(
            params.orgId, params.poaManager, params.orgRegistry, params.hats, params.autoUpgrade, result.executor
        );

        /* 3. Setup Hats Tree */
        {
            // Transfer superAdmin rights to HatsTreeSetup contract
            IEligibilityModule(result.eligibilityModule).transferSuperAdmin(params.hatsTreeSetup);
            IToggleModule(result.toggleModule).transferAdmin(params.hatsTreeSetup);

            // Call HatsTreeSetup to do all the Hats configuration
            IHatsTreeSetup.SetupParams memory setupParams = IHatsTreeSetup.SetupParams({
                hats: IHats(params.hats),
                orgRegistry: OrgRegistry(params.orgRegistry),
                orgId: params.orgId,
                eligibilityModule: result.eligibilityModule,
                toggleModule: result.toggleModule,
                deployer: address(this),
                deployerAddress: params.deployerAddress,
                executor: result.executor,
                accountRegistry: params.accountRegistry,
                orgName: params.orgName,
                deployerUsername: params.deployerUsername,
                regDeadline: params.regDeadline,
                regNonce: params.regNonce,
                regSignature: params.regSignature,
                roles: params.roles
            });

            IHatsTreeSetup.SetupResult memory setupResult =
                IHatsTreeSetup(params.hatsTreeSetup).setupHatsTree(setupParams);

            result.topHatId = setupResult.topHatId;
            result.roleHatIds = setupResult.roleHatIds;
        }

        /* 4. Batch register all 3 deployed contracts */
        {
            OrgRegistry.ContractRegistration[] memory registrations = new OrgRegistry.ContractRegistration[](3);

            registrations[0] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.EXECUTOR_ID, proxy: result.executor, beacon: execBeacon, owner: address(this)
            });

            registrations[1] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.ELIGIBILITY_MODULE_ID,
                proxy: result.eligibilityModule,
                beacon: eligibilityBeacon,
                owner: address(this)
            });

            registrations[2] = OrgRegistry.ContractRegistration({
                typeId: ModuleTypes.TOGGLE_MODULE_ID,
                proxy: result.toggleModule,
                beacon: toggleBeacon,
                owner: address(this)
            });

            // Call OrgDeployer to batch register (not the last batch)
            IOrgDeployer(params.deployer).batchRegisterContracts(params.orgId, registrations, params.autoUpgrade, false);
        }

        /* 5. Initiate two-step ownership transfer for executor beacon */
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
     * @param roleHatIds Hat IDs for roles (from deployInfrastructure)
     * @return hybridVoting Address of deployed HybridVoting contract
     * @return directDemocracyVoting Address of deployed DirectDemocracyVoting contract
     */
    function deployVoting(GovernanceParams memory params, address executor, uint256[] memory roleHatIds)
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
            // Resolve proposal creator roles to hat IDs
            uint256[] memory creatorHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.hybridProposalCreatorRolesBitmap
            );

            // Update voting classes with token addresses and role hat IDs
            IHybridVotingInit.ClassConfig[] memory finalClasses =
                _updateClassesWithTokenAndHats(params.hybridClasses, params.participationToken, roleHatIds);

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
                config,
                executor,
                creatorHats,
                params.hybridThresholdPct,
                params.hybridEarlyCloseTurnoutPct,
                finalClasses,
                hybridBeacon
            );
        }

        /* 2. Deploy DirectDemocracyVoting (Polling Mechanism) */
        {
            // Resolve voting and creator roles to hat IDs
            uint256[] memory votingHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.ddVotingRolesBitmap
            );

            uint256[] memory creatorHats = RoleResolver.resolveRoleBitmap(
                OrgRegistry(params.orgRegistry), params.orgId, params.ddCreatorRolesBitmap
            );

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
                config, executor, votingHats, creatorHats, params.ddInitialTargets, params.ddThresholdPct, ddBeacon
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
     * @notice Updates voting classes with token addresses and role hat IDs
     * @dev Fills in missing token addresses for ERC20_BAL classes
     */
    function _updateClassesWithTokenAndHats(
        IHybridVotingInit.ClassConfig[] memory classes,
        address token,
        uint256[] memory roleHatIds
    ) internal pure returns (IHybridVotingInit.ClassConfig[] memory) {
        for (uint256 i = 0; i < classes.length; i++) {
            if (classes[i].strategy == IHybridVotingInit.ClassStrategy.ERC20_BAL) {
                // Fill in token address if not provided
                if (classes[i].asset == address(0)) {
                    classes[i].asset = token;
                }
            }
            // For both DIRECT and ERC20_BAL, use all role hats if hatIds not specified
            if (classes[i].hatIds.length == 0) {
                classes[i].hatIds = roleHatIds;
            }
        }
        return classes;
    }

    /*══════════════  INTERNAL DEPLOYMENT HELPERS  ═════════════=*/

    /**
     * @notice Deploys EligibilityModule BeaconProxy (without registration)
     * @dev Registration handled via batch in deployInfrastructure
     * @return emProxy The deployed eligibility module proxy address
     * @return beacon The beacon address for this module
     */
    function _deployEligibilityModule(
        bytes32 orgId,
        address poaManager,
        address orgRegistry,
        address hats,
        bool autoUpgrade,
        address beaconOwner
    ) internal returns (address emProxy, address beacon) {
        beacon = BeaconDeploymentLib.createBeacon(
            ModuleTypes.ELIGIBILITY_MODULE_ID, poaManager, beaconOwner, autoUpgrade, address(0)
        );

        ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
            poaManager: IPoaManager(poaManager),
            orgRegistry: OrgRegistry(orgRegistry),
            hats: hats,
            orgId: orgId,
            moduleOwner: address(this),
            autoUpgrade: autoUpgrade,
            customImpl: address(0)
        });

        emProxy = ModuleDeploymentLib.deployEligibilityModule(config, address(this), address(0), beacon);
    }

    /**
     * @notice Deploys ToggleModule BeaconProxy (without registration)
     * @dev Registration handled via batch in deployInfrastructure
     * @return tmProxy The deployed toggle module proxy address
     * @return beacon The beacon address for this module
     */
    function _deployToggleModule(
        bytes32 orgId,
        address poaManager,
        address orgRegistry,
        address hats,
        bool autoUpgrade,
        address beaconOwner
    ) internal returns (address tmProxy, address beacon) {
        beacon = BeaconDeploymentLib.createBeacon(
            ModuleTypes.TOGGLE_MODULE_ID, poaManager, beaconOwner, autoUpgrade, address(0)
        );

        ModuleDeploymentLib.DeployConfig memory config = ModuleDeploymentLib.DeployConfig({
            poaManager: IPoaManager(poaManager),
            orgRegistry: OrgRegistry(orgRegistry),
            hats: hats,
            orgId: orgId,
            moduleOwner: address(this),
            autoUpgrade: autoUpgrade,
            customImpl: address(0)
        });

        tmProxy = ModuleDeploymentLib.deployToggleModule(config, address(this), beacon);
    }
}
