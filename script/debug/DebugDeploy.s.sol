// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {OrgDeployer as OD2, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";

contract DebugDeploy is Script {
    function run() public {
        address orgDeployerAddr = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;
        address registryAddr = 0x01A13c92321E9CA2C02577b92A4F8d2FDC4d8513;
        address deployer = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

        OrgDeployer.DeploymentParams memory params;
        params.orgId = keccak256("debug-test-org-12345");
        params.orgName = "Debug Test Org";
        params.metadataHash = bytes32(0);
        params.registryAddr = registryAddr;
        params.deployerAddress = deployer;
        params.deployerUsername = "";
        params.autoUpgrade = true;
        params.hybridThresholdPct = 50;
        params.ddThresholdPct = 50;

        // Voting classes
        params.hybridClasses = new IHybridVotingInit.ClassConfig[](2);
        uint256[] memory emptyHatIds = new uint256[](0);
        params.hybridClasses[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 50,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatId: 0
        });
        params.hybridClasses[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: 50,
            quadratic: false,
            minBalance: 1 ether,
            asset: address(0),
            hatId: 0
        });

        params.ddInitialTargets = new address[](0);

        // Roles with vouching (matching user's config)
        params.roles = new RoleConfigStructs.RoleConfig[](2);
        address[] memory noWearers = new address[](0);

        params.roles[0] = RoleConfigStructs.RoleConfig({
            name: "Member",
            image: "",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true, quorum: 1, voucherRoleIndex: 1, combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: 1}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: 1000, mutableHat: true})
        });

        params.roles[1] = RoleConfigStructs.RoleConfig({
            name: "Executive",
            image: "",
            metadataCID: bytes32(0),
            canVote: true,
            vouching: RoleConfigStructs.RoleVouchingConfig({
                enabled: true, quorum: 1, voucherRoleIndex: 1, combineWithHierarchy: true
            }),
            defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
            hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
            distribution: RoleConfigStructs.RoleDistributionConfig({
                mintToDeployer: true, additionalWearers: noWearers
            }),
            hatConfig: RoleConfigStructs.HatConfig({maxSupply: 10, mutableHat: true})
        });

        // Role assignments
        params.roleAssignments = OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 1,
            tokenMemberRolesBitmap: 3,
            tokenApproverRolesBitmap: 2,
            taskCreatorRolesBitmap: 3,
            educationCreatorRolesBitmap: 2,
            educationMemberRolesBitmap: 3,
            hybridProposalCreatorRolesBitmap: 3,
            ddVotingRolesBitmap: 3,
            ddCreatorRolesBitmap: 3
        });

        // THE KEY: metadataAdminRoleIndex = 1 (not max)
        params.metadataAdminRoleIndex = 1;
        params.passkeyEnabled = true;

        params.educationHubConfig = ModulesFactory.EducationHubConfig({enabled: true});

        // Empty bootstrap
        ITaskManagerBootstrap.BootstrapProjectConfig[] memory projects =
            new ITaskManagerBootstrap.BootstrapProjectConfig[](0);
        ITaskManagerBootstrap.BootstrapTaskConfig[] memory tasks = new ITaskManagerBootstrap.BootstrapTaskConfig[](0);
        params.bootstrap = OrgDeployer.BootstrapConfig({projects: projects, tasks: tasks});

        // Paymaster config
        params.paymasterConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: true,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0.003 ether,
            defaultBudgetEpochLen: 604800
        });

        console.log("Simulating deployFullOrg on Arbitrum...");
        console.log("OrgDeployer:", orgDeployerAddr);
        console.log("metadataAdminRoleIndex:", params.metadataAdminRoleIndex);

        vm.prank(deployer);
        OrgDeployer(orgDeployerAddr).deployFullOrg(params);

        console.log("SUCCESS - deployment completed");
    }
}
