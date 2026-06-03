// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {Executor, IExecutor} from "../../src/Executor.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {UniversalAccountRegistry} from "../../src/UniversalAccountRegistry.sol";
import {IEligibilityModule} from "../../src/interfaces/IHatsModules.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";

/**
 * @title RunOrgActionsAdvanced
 * @notice Advanced demonstration showcasing vouching system and complete org lifecycle
 * @dev Extends basic org actions with vouching demonstrations
 *
 * This script demonstrates:
 * 1. Organization deployment
 * 2. Member onboarding (QuickJoin + hat minting)
 * 3. **Vouching system (vouch for COORDINATOR hat)**
 * 4. **Hat minting after vouching**
 * 5. **Vouch revocation**
 * 6. Participation token management
 * 7. Task creation and lifecycle (TaskManager)
 * 8. Proposal creation and voting (HybridVoting)
 * 9. Proposal execution through governance
 *
 * Usage:
 *   # First deploy infrastructure (if not already deployed)
 *   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
 *
 *   # Then run this script to demonstrate advanced org actions
 *   forge script script/RunOrgActionsAdvanced.s.sol:RunOrgActionsAdvanced \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Environment Variables Required:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment and funding demo accounts
 *   - ORG_CONFIG_PATH: (Optional) Path to org config (default: script/org-config-advanced-demo.json)
 *
 * Note: Script automatically generates ephemeral test accounts - no need for multiple private keys!
 *
 * Note: Run with --slow flag to give block time between actions
 */
contract RunOrgActionsAdvanced is Script {
    /*=========================== STRUCTS ===========================*/

    // JSON parsing structs - must match org config JSON structure
    struct OrgConfigJson {
        string orgId;
        string orgName;
        bool autoUpgrade;
        ThresholdConfig threshold;
        RoleConfig[] roles;
        VotingClassConfig[] votingClasses;
        RoleAssignmentsConfig roleAssignments;
        address[] ddInitialTargets;
        bool withPaymaster;
        bool withEducationHub; // Whether to deploy EducationHub (default: true)
        BootstrapConfigJson bootstrap; // Optional: initial projects and tasks
    }

    struct ThresholdConfig {
        uint8 hybrid;
        uint8 directDemocracy;
    }

    struct RoleVouchingConfigJson {
        bool enabled;
        uint32 quorum;
        uint256 voucherRoleIndex;
        bool combineWithHierarchy;
    }

    struct RoleEligibilityDefaultsJson {
        bool eligible;
        bool standing;
    }

    struct RoleHierarchyConfigJson {
        uint256 adminRoleIndex;
    }

    struct RoleDistributionConfigJson {
        bool mintToDeployer;
        address[] additionalWearers;
    }

    struct HatConfigJson {
        uint32 maxSupply;
        bool mutableHat;
    }

    struct RoleConfig {
        string name;
        string image;
        bool canVote;
        RoleVouchingConfigJson vouching;
        RoleEligibilityDefaultsJson defaults;
        RoleHierarchyConfigJson hierarchy;
        RoleDistributionConfigJson distribution;
        HatConfigJson hatConfig;
    }

    struct VotingClassConfig {
        string strategy;
        uint8 slicePct;
        bool quadratic;
        uint256 minBalance;
        address asset;
        uint256[] hatIds;
    }

    struct RoleAssignmentsConfig {
        uint256[] quickJoinRoles;
        uint256[] tokenMemberRoles;
        uint256[] tokenApproverRoles;
        uint256[] taskCreatorRoles;
        uint256[] educationCreatorRoles;
        uint256[] educationMemberRoles;
        uint256[] hybridProposalCreatorRoles;
        uint256[] ddVotingRoles;
        uint256[] ddCreatorRoles;
    }

    // Bootstrap config structs for initial project/task creation
    struct BootstrapProjectConfigJson {
        string title;
        bytes32 metadataHash;
        uint256 cap;
        address[] managers;
        uint256[] createRoles;
        uint256[] claimRoles;
        uint256[] reviewRoles;
        uint256[] assignRoles;
    }

    struct BootstrapTaskConfigJson {
        uint8 projectIndex;
        uint256 payout;
        string title;
        bytes32 metadataHash;
        address bountyToken;
        uint256 bountyPayout;
        bool requiresApplication;
    }

    struct BootstrapConfigJson {
        BootstrapProjectConfigJson[] projects;
        BootstrapTaskConfigJson[] tasks;
    }

    struct OrgContracts {
        address executor;
        address hybridVoting;
        address directDemocracyVoting;
        address quickJoin;
        address participationToken;
        address taskManager;
        address educationHub;
        address paymentManager;
        address eligibilityModule;
        uint256 topHatId;
        uint256[] roleHatIds;
    }

    struct MemberAddresses {
        address deployer;
        address member1;
        address member2;
        address coordinator;
        address admin;
    }

    struct MemberKeys {
        uint256 member1;
        uint256 member2;
        uint256 coordinator;
    }

    /*=========================== STATE ===========================*/

    bytes32 public orgId;
    OrgContracts public org;
    MemberAddresses public members;
    MemberKeys public memberKeys;
    IHats public hats;

    /*=========================== MAIN ===========================*/

    function run() public {
        console.log("\n========================================================");
        console.log("   POA Advanced Organization Actions Demo              ");
        console.log("========================================================\n");

        // Step 1: Deploy Organization
        _deployOrganization();

        // Step 2: Onboard Members
        _onboardMembers();

        // Step 3: Demonstrate Vouching System
        _demonstrateVouching();

        // Step 4: Distribute Participation Tokens
        _distributeTokens();

        // Step 5: Create Project and Tasks
        _demonstrateTaskManager();

        // Step 6: Create and Execute Governance Proposal
        _demonstrateGovernance();

        console.log("\n========================================================");
        console.log("   Advanced Demo Complete! All Actions Executed Successfully");
        console.log("========================================================\n");
    }

    /*=========================== STEP 1: DEPLOY ===========================*/

    function _deployOrganization() internal {
        console.log("=======================================================");
        console.log("STEP 1: Deploying Organization");
        console.log("=======================================================\n");

        // Read infrastructure addresses
        string memory infraJson = vm.readFile("script/config/infrastructure.json");
        address orgDeployerAddr = vm.parseJsonAddress(infraJson, ".orgDeployer");
        address globalAccountRegistry = vm.parseJsonAddress(infraJson, ".globalAccountRegistry");
        address hatsAddr = vm.parseJsonAddress(infraJson, ".hatsProtocol");
        address orgRegistryAddr = vm.parseJsonAddress(infraJson, ".orgRegistry");

        require(orgDeployerAddr != address(0), "OrgDeployer not found - deploy infrastructure first");

        hats = IHats(hatsAddr);

        // Get org config path
        string memory configPath = vm.envOr("ORG_CONFIG_PATH", string("script/config/org-config-advanced-demo.json"));

        // Load member addresses
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        members.deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer Address:", members.deployer);
        console.log("OrgDeployer Contract:", orgDeployerAddr);
        console.log("Config Path:", configPath);

        // Parse config
        string memory configJson = vm.readFile(configPath);
        OrgConfigJson memory config = _parseOrgConfig(configJson);

        orgId = keccak256(bytes(config.orgId));

        console.log("\nOrganization:");
        console.log("  ID:", config.orgId);
        console.log("  Name:", config.orgName);
        console.log("  Roles:", config.roles.length);
        console.log("  Voting Classes:", config.votingClasses.length);

        // Build deployment params (deployer will receive ADMIN hat)
        OrgDeployer.DeploymentParams memory params =
            _buildDeploymentParams(config, globalAccountRegistry, members.deployer);

        // Set deployer username from env var (pure helper can't read env)
        string memory deployerUsername = vm.envOr("DEPLOYER_USERNAME", string("hudsonhrh"));
        params.deployerUsername = deployerUsername;

        // Deploy
        vm.startBroadcast(deployerPrivateKey);

        OrgDeployer orgDeployer = OrgDeployer(orgDeployerAddr);
        OrgDeployer.DeploymentResult memory result = orgDeployer.deployFullOrg(params);

        // Register deployer username on GlobalAccountRegistry
        if (bytes(deployerUsername).length > 0) {
            UniversalAccountRegistry globalReg = UniversalAccountRegistry(globalAccountRegistry);
            if (bytes(globalReg.getUsername(members.deployer)).length == 0) {
                globalReg.registerAccount(deployerUsername);
                console.log("Deployer registered as:", deployerUsername);
            }
        }

        vm.stopBroadcast();

        // Store org contracts
        org.executor = result.executor;
        org.hybridVoting = result.hybridVoting;
        org.directDemocracyVoting = result.directDemocracyVoting;
        org.quickJoin = result.quickJoin;
        org.participationToken = result.participationToken;
        org.taskManager = result.taskManager;
        org.educationHub = result.educationHub;
        org.paymentManager = result.paymentManager;

        // Get eligibility module and role hat IDs from OrgRegistry
        OrgRegistry orgRegistry = OrgRegistry(orgRegistryAddr);
        org.eligibilityModule = orgRegistry.getOrgContract(orgId, ModuleTypes.ELIGIBILITY_MODULE_ID);

        org.roleHatIds = new uint256[](4); // 4 roles in config
        org.roleHatIds[0] = orgRegistry.getRoleHat(orgId, 0); // MEMBER
        org.roleHatIds[1] = orgRegistry.getRoleHat(orgId, 1); // COORDINATOR
        org.roleHatIds[2] = orgRegistry.getRoleHat(orgId, 2); // CONTRIBUTOR
        org.roleHatIds[3] = orgRegistry.getRoleHat(orgId, 3); // ADMIN

        console.log("\n[OK] Organization Deployed Successfully");
        console.log("  Executor:", org.executor);
        console.log("  HybridVoting:", org.hybridVoting);
        console.log("  TaskManager:", org.taskManager);
        console.log("  ParticipationToken:", org.participationToken);
        console.log("  QuickJoin:", org.quickJoin);
        console.log("  Role Hat IDs:", org.roleHatIds.length);
    }

    /*=========================== STEP 2: ONBOARD ===========================*/

    function _onboardMembers() internal {
        console.log("\n=======================================================");
        console.log("STEP 2: Onboarding Members");
        console.log("=======================================================\n");

        // Generate ephemeral accounts for demo (no need to store private keys!)
        console.log("-> Generating ephemeral test accounts...");

        (members.member1, memberKeys.member1) = makeAddrAndKey("member1-ephemeral");
        (members.member2, memberKeys.member2) = makeAddrAndKey("member2-ephemeral");
        (members.coordinator, memberKeys.coordinator) = makeAddrAndKey("coordinator-ephemeral");

        console.log("Member 1:", members.member1);
        console.log("Member 2:", members.member2);
        console.log("Coordinator:", members.coordinator);

        // Fund accounts with gas money from deployer
        uint256 gasAllowance = 0.01 ether; // ~$30 worth, enough for demo
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("\n-> Funding test accounts from deployer...");
        vm.startBroadcast(deployerKey);
        payable(members.member1).transfer(gasAllowance);
        payable(members.member2).transfer(gasAllowance);
        payable(members.coordinator).transfer(gasAllowance);
        vm.stopBroadcast();

        console.log("  [OK] Each account funded with", gasAllowance / 1e18, "ETH");

        QuickJoin quickJoin = QuickJoin(org.quickJoin);
        UniversalAccountRegistry registry = UniversalAccountRegistry(address(quickJoin.accountRegistry()));

        // Register usernames then join (no hats - vouching required for MEMBER hat)
        console.log("\n-> Member 1 registering & joining (no hats)...");
        vm.broadcast(memberKeys.member1);
        registry.registerAccount("member1");
        vm.broadcast(memberKeys.member1);
        quickJoin.quickJoinWithUser();
        console.log("  [OK] Joined org");

        console.log("-> Member 2 registering & joining (no hats)...");
        vm.broadcast(memberKeys.member2);
        registry.registerAccount("member2");
        vm.broadcast(memberKeys.member2);
        quickJoin.quickJoinWithUser();
        console.log("  [OK] Joined org");

        console.log("-> Coordinator registering & joining (no hats)...");
        vm.broadcast(memberKeys.coordinator);
        registry.registerAccount("coordinator");
        vm.broadcast(memberKeys.coordinator);
        quickJoin.quickJoinWithUser();
        console.log("  [OK] Joined org");

        console.log("\n[OK] All Members Registered");
        console.log("  (Note: No hats minted yet - vouching required for MEMBER and COORDINATOR hats)");
    }

    /*=========================== STEP 3: VOUCHING ===========================*/

    function _demonstrateVouching() internal {
        console.log("\n=======================================================");
        console.log("STEP 3: Demonstrating Two-Level Vouching System");
        console.log("=======================================================\n");

        uint256 memberHatId = org.roleHatIds[0]; // MEMBER role (index 0)
        uint256 coordinatorHatId = org.roleHatIds[1]; // COORDINATOR role (index 1)
        IEligibilityModule eligMod = IEligibilityModule(org.eligibilityModule);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Member Hat ID:", memberHatId);
        console.log("Coordinator Hat ID:", coordinatorHatId);
        console.log("Eligibility Module:", org.eligibilityModule);
        console.log("\nVouching Rules:");
        console.log("  MEMBER hat: 1 vouch from ADMIN/COORDINATOR/MEMBER (hierarchy)");
        console.log("  COORDINATOR hat: 1 vouch from ADMIN only");

        /* ─────────── Part 1: Admin vouches for member1 to get MEMBER hat ─────────── */
        console.log("\n[Part 1: Vouching for MEMBER hat]");

        // Verify deployer has ADMIN hat
        uint256 adminHatId = org.roleHatIds[3];
        console.log("\n-> Verifying deployer has ADMIN hat...");
        console.log("  Deployer address:", members.deployer);
        console.log("  ADMIN hat ID:", adminHatId);
        bool deployerHasAdminHat = hats.isWearerOfHat(members.deployer, adminHatId);
        console.log("  Deployer has ADMIN hat:", deployerHasAdminHat);
        require(deployerHasAdminHat, "Deployer does not have ADMIN hat - cannot vouch");

        console.log("\n-> Checking member1 initial status...");
        console.log("  Has MEMBER hat:", hats.isWearerOfHat(members.member1, memberHatId));
        console.log("  Vouch count:", eligMod.currentVouchCount(memberHatId, members.member1));

        console.log("\n-> Admin vouching for member1 to get MEMBER hat...");
        vm.broadcast(deployerPrivateKey);
        eligMod.vouchFor(members.member1, memberHatId);
        console.log("  [OK] Admin vouched for member1");
        console.log("  Vouch count:", eligMod.currentVouchCount(memberHatId, members.member1));

        console.log("\n-> member1 claiming MEMBER hat after being vouched...");
        vm.broadcast(memberKeys.member1);
        eligMod.claimVouchedHat(memberHatId);
        console.log("  [OK] member1 claimed MEMBER hat");
        bool hasMemberHat = hats.isWearerOfHat(members.member1, memberHatId);
        console.log("  member1 has MEMBER hat:", hasMemberHat);

        /* ─────────── Part 2: Admin vouches for coordinator to get COORDINATOR hat ─────────── */
        console.log("\n[Part 2: Vouching for COORDINATOR hat (separate coordinator account)]");

        console.log("\n-> Checking coordinator initial status...");
        console.log("  Has COORDINATOR hat:", hats.isWearerOfHat(members.coordinator, coordinatorHatId));
        console.log("  Vouch count:", eligMod.currentVouchCount(coordinatorHatId, members.coordinator));

        console.log("\n-> Admin vouching for coordinator to get COORDINATOR hat...");
        vm.broadcast(deployerPrivateKey);
        eligMod.vouchFor(members.coordinator, coordinatorHatId);
        console.log("  [OK] Admin vouched for coordinator");
        console.log("  Vouch count:", eligMod.currentVouchCount(coordinatorHatId, members.coordinator));

        console.log("\n-> coordinator claiming COORDINATOR hat after being vouched...");
        vm.broadcast(memberKeys.coordinator);
        eligMod.claimVouchedHat(coordinatorHatId);
        console.log("  [OK] coordinator claimed COORDINATOR hat");
        bool hasCoordinatorHat = hats.isWearerOfHat(members.coordinator, coordinatorHatId);
        console.log("  coordinator has COORDINATOR hat:", hasCoordinatorHat);

        /* ─────────── Part 3: member1 (now MEMBER) vouches for member2 ─────────── */
        console.log("\n[Part 3: Demonstrating MEMBER can vouch for new MEMBER]");

        console.log("\n-> member1 (who has MEMBER hat) vouching for member2...");
        vm.broadcast(memberKeys.member1);
        eligMod.vouchFor(members.member2, memberHatId);
        console.log("  [OK] member1 vouched for member2");
        console.log("  Vouch count:", eligMod.currentVouchCount(memberHatId, members.member2));

        console.log("\n-> member2 claiming MEMBER hat after being vouched...");
        vm.broadcast(memberKeys.member2);
        eligMod.claimVouchedHat(memberHatId);
        console.log("  [OK] member2 claimed MEMBER hat");
        bool member2HasMemberHat = hats.isWearerOfHat(members.member2, memberHatId);
        console.log("  member2 has MEMBER hat:", member2HasMemberHat);

        /* ─────────── Part 4: Demonstrate vouch revocation ─────────── */
        console.log("\n[Part 4: Demonstrating vouch revocation]");

        console.log("\n-> Admin revoking vouch for coordinator COORDINATOR hat...");
        vm.broadcast(deployerPrivateKey);
        eligMod.revokeVouch(members.coordinator, coordinatorHatId);
        console.log("  [OK] Vouch revoked");
        console.log("  Vouch count:", eligMod.currentVouchCount(coordinatorHatId, members.coordinator));

        // Re-vouch to ensure coordinator can continue demo
        console.log("\n-> Re-vouching coordinator for continued demo...");
        vm.broadcast(deployerPrivateKey);
        eligMod.vouchFor(members.coordinator, coordinatorHatId);
        console.log("  [OK] coordinator re-vouched");

        console.log("\n[OK] Two-Level Vouching System with Claim Pattern Demonstrated");
        console.log("  member1: MEMBER (vouched by ADMIN, claimed)");
        console.log("  member2: MEMBER (vouched by member1, claimed)");
        console.log("  coordinator: COORDINATOR (vouched by ADMIN, claimed)");
        console.log("  Hierarchy allows MEMBERs to vouch for new MEMBERs!");
        console.log("  Users must explicitly claim hats after being vouched!");
    }

    /*=========================== STEP 4: TOKENS ===========================*/

    function _distributeTokens() internal {
        console.log("\n=======================================================");
        console.log("STEP 4: Distributing Participation Tokens");
        console.log("=======================================================\n");

        ParticipationToken token = ParticipationToken(org.participationToken);

        console.log("Token Address:", address(token));
        console.log("Token Name:", token.name());
        console.log("Token Symbol:", token.symbol());

        // Members request tokens
        console.log("\n-> Member 1 requesting tokens...");
        vm.broadcast(memberKeys.member1);
        token.requestTokens(10 ether, "Initial token request for participation");
        console.log("  [OK] Requested 10 tokens");

        console.log("-> Member 2 requesting tokens...");
        vm.broadcast(memberKeys.member2);
        token.requestTokens(10 ether, "Initial token request for participation");
        console.log("  [OK] Requested 10 tokens");

        console.log("-> Coordinator requesting tokens...");
        vm.broadcast(memberKeys.coordinator);
        token.requestTokens(20 ether, "Coordinator token request");
        console.log("  [OK] Requested 20 tokens");

        // Note: In production, an approver would need to approve these requests
        // For demo purposes, we're showing the request flow
        // Approval would require: token.approveRequest(requestId)

        console.log("\n[OK] Token Distribution Initiated");
        console.log("  (Note: Requests pending approval from token approver)");
    }

    /*=========================== STEP 5: TASK MANAGER ===========================*/

    function _demonstrateTaskManager() internal {
        console.log("\n=======================================================");
        console.log("STEP 5: Demonstrating Task Manager");
        console.log("=======================================================\n");

        TaskManager tm = TaskManager(org.taskManager);

        console.log("TaskManager Address:", address(tm));

        // Create a project
        console.log("\n-> Coordinator creating project...");

        address[] memory managers = new address[](0);
        uint256[] memory emptyHats = new uint256[](0);

        // Set up task permissions: MEMBER, COORDINATOR, and ADMIN can claim tasks
        uint256[] memory claimHats = new uint256[](3);
        claimHats[0] = org.roleHatIds[0]; // MEMBER
        claimHats[1] = org.roleHatIds[1]; // COORDINATOR
        claimHats[2] = org.roleHatIds[3]; // ADMIN

        vm.broadcast(memberKeys.coordinator);
        bytes32 projectId = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: abi.encode("metadata", "Building core governance infrastructure for the cooperative"),
                metadataHash: bytes32(0),
                cap: 1000 ether,
                managers: managers,
                createHat: 0,
                claimHat: claimHats.length > 0 ? claimHats[0] : 0,
                reviewHat: 0,
                assignHat: 0,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        console.log("  [OK] Project Created");
        console.log("  Project ID:", vm.toString(uint256(projectId)));

        // Create tasks in the project
        // Note: Task IDs auto-increment starting from 0
        console.log("\n-> Creating Task 0: Deploy Voting System");
        vm.broadcast(memberKeys.coordinator);
        tm.createTask(
            10 ether, // payout in participation tokens
            abi.encode("task", "voting-deployment"),
            bytes32(0), // metadataHash
            projectId,
            address(0), // bountyToken (0 = no bounty)
            0, // bountyPayout
            false // requiresApplication (can be claimed directly)
        );
        uint256 task0 = 0; // First task ID starts at 0
        console.log("  [OK] Task 0 Created");

        console.log("-> Creating Task 1: Documentation");
        vm.broadcast(memberKeys.coordinator);
        tm.createTask(
            5 ether, // payout
            abi.encode("task", "docs"),
            bytes32(0), // metadataHash
            projectId,
            address(0),
            0,
            true // Requires application for this one
        );
        uint256 task1 = 1; // Second task ID
        console.log("  [OK] Task 1 Created");

        // Member 1 claims task 0 (directly claimable)
        console.log("\n-> Member 1 claiming Task 0...");
        vm.broadcast(memberKeys.member1);
        tm.claimTask(task0);
        console.log("  [OK] Task 0 Claimed");

        // Member 2 applies for task 1 (requires application)
        console.log("-> Member 2 applying for Task 1...");
        vm.broadcast(memberKeys.member2);
        tm.applyForTask(task1, keccak256("application-details-member2"));
        console.log("  [OK] Application Submitted");

        // Coordinator approves Member 2's application
        console.log("-> Coordinator approving Member 2 for Task 1...");
        vm.broadcast(memberKeys.coordinator);
        tm.approveApplication(task1, members.member2);
        console.log("  [OK] Application Approved, Task Assigned");

        // Members submit task work
        console.log("\n-> Member 1 submitting Task 0...");
        vm.broadcast(memberKeys.member1);
        tm.submitTask(task0, keccak256(abi.encode("submission", "voting-system-deployed")));
        console.log("  [OK] Task 0 Submitted for Review");

        console.log("-> Member 2 submitting Task 1...");
        vm.broadcast(memberKeys.member2);
        tm.submitTask(task1, keccak256(abi.encode("submission", "documentation-complete")));
        console.log("  [OK] Task 1 Submitted for Review");

        // Coordinator completes tasks (approves the submissions)
        console.log("\n-> Coordinator completing Task 0...");
        vm.broadcast(memberKeys.coordinator);
        tm.completeTask(task0);
        console.log("  [OK] Task 0 Completed");

        console.log("-> Coordinator completing Task 1...");
        vm.broadcast(memberKeys.coordinator);
        tm.completeTask(task1);
        console.log("  [OK] Task 1 Completed");

        console.log("\n[OK] Task Manager Demonstration Complete");
        console.log("  Project Created: 1");
        console.log("  Tasks Completed: 2");
    }

    /*=========================== STEP 6: GOVERNANCE ===========================*/

    function _demonstrateGovernance() internal {
        console.log("\n=======================================================");
        console.log("STEP 6: Demonstrating Governance (HybridVoting)");
        console.log("=======================================================\n");

        HybridVoting voting = HybridVoting(org.hybridVoting);
        Executor executor = Executor(payable(org.executor));

        console.log("HybridVoting Address:", address(voting));
        console.log("Executor Address:", address(executor));

        // Create a governance signaling proposal
        // This demonstrates the voting mechanism without executing onchain actions

        console.log("\n-> Coordinator creating governance proposal...");

        // Create a governance proposal (signaling poll)
        // This demonstrates the HybridVoting mechanism
        // Note: Executable proposals require targets to be in HybridVoting's allowedTarget list
        // Only Executor is in the allowlist by default

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);

        // Both options have empty batches (this is a signaling vote)
        batches[0] = new IExecutor.Call[](0); // Option 0: YES
        batches[1] = new IExecutor.Call[](0); // Option 1: NO

        uint256[] memory emptyHatIds = new uint256[](0);

        vm.broadcast(memberKeys.coordinator);
        voting.createProposal(
            abi.encode("ipfs://proposal-update-task-timeout"),
            bytes32(0), // descriptionHash
            1, // 1 minute for quick testing
            2, // 2 options (YES/NO)
            batches,
            emptyHatIds // No hat restrictions
        );

        uint256 proposalId = voting.proposalsCount() - 1;

        console.log("  [OK] Proposal Created (ID:", proposalId, ")");
        console.log("  Description: Signaling Vote - Should we update task timeout?");
        console.log("  Type: Non-executable (signaling poll)");
        console.log("  Duration: 1 minute");

        // Members vote on the proposal
        // Vote format: vote(proposalId, optionIndices[], optionWeights[])
        // optionIndices: which options you're voting for (0=YES, 1=NO)
        // optionWeights: weight for each option (must sum to 100)

        console.log("\n-> Coordinator voting YES (100%)...");
        uint8[] memory yesOption = new uint8[](1);
        yesOption[0] = 0; // Option 0 = YES

        uint8[] memory fullWeight = new uint8[](1);
        fullWeight[0] = 100; // 100% weight to YES

        vm.broadcast(memberKeys.coordinator);
        voting.vote(proposalId, yesOption, fullWeight);
        console.log("  [OK] Vote Cast");

        console.log("-> Member 1 voting YES (100%)...");
        vm.broadcast(memberKeys.member1);
        voting.vote(proposalId, yesOption, fullWeight);
        console.log("  [OK] Vote Cast");

        console.log("-> Member 2 voting YES (100%)...");
        vm.broadcast(memberKeys.member2);
        voting.vote(proposalId, yesOption, fullWeight);
        console.log("  [OK] Vote Cast");

        // Wait for voting period to end
        console.log("\n-> Waiting for voting period to end...");
        if (_isLocalAnvil()) {
            vm.warp(block.timestamp + 2 minutes);
            console.log("  [Anvil] Time warped forward");
        } else {
            console.log("  [Testnet] Waiting 70 seconds...");
            vm.sleep(70000); // 70 seconds in milliseconds
        }

        // Announce winner
        console.log("-> Announcing winner...");
        vm.broadcast(memberKeys.coordinator);
        (uint256 winningOption, bool isValid) = voting.announceWinner(proposalId);

        console.log("  [OK] Winner Announced");
        console.log("  Winning Option:", winningOption);
        console.log("  Is Valid (threshold met):", isValid);

        console.log("\n[OK] Governance Demonstration Complete - Full Cycle!");
        console.log("  Proposal Created: 1");
        console.log("  Votes Cast: 3");
        console.log("  Winner Announced: Option", winningOption);
    }

    function _isLocalAnvil() internal view returns (bool) {
        return block.chainid == 31337;
    }

    /*=========================== CONFIG PARSING ===========================*/

    function _parseOrgConfig(string memory configJson) internal returns (OrgConfigJson memory config) {
        // Parse top-level fields
        config.orgId = vm.parseJsonString(configJson, ".orgId");
        config.orgName = vm.parseJsonString(configJson, ".orgName");
        config.autoUpgrade = vm.parseJsonBool(configJson, ".autoUpgrade");
        config.withPaymaster = vm.parseJsonBool(configJson, ".withPaymaster");

        // Parse withEducationHub (default to true for backward compatibility)
        try vm.parseJsonBool(configJson, ".withEducationHub") returns (bool withEduHub) {
            config.withEducationHub = withEduHub;
        } catch {
            config.withEducationHub = true; // Default to enabled for backward compatibility
        }

        // Parse threshold
        config.threshold.hybrid = uint8(vm.parseJsonUint(configJson, ".threshold.hybrid"));
        config.threshold.directDemocracy = uint8(vm.parseJsonUint(configJson, ".threshold.directDemocracy"));

        // Parse roles array
        uint256 rolesLength = 0;
        for (uint256 i = 0; i < 100; i++) {
            // reasonable max
            try vm.parseJsonString(configJson, string.concat(".roles[", vm.toString(i), "].name")) returns (
                string memory
            ) {
                rolesLength++;
            } catch {
                break;
            }
        }

        config.roles = new RoleConfig[](rolesLength);
        for (uint256 i = 0; i < rolesLength; i++) {
            string memory basePath = string.concat(".roles[", vm.toString(i), "]");
            config.roles[i].name = vm.parseJsonString(configJson, string.concat(basePath, ".name"));
            config.roles[i].image = vm.parseJsonString(configJson, string.concat(basePath, ".image"));
            config.roles[i].canVote = vm.parseJsonBool(configJson, string.concat(basePath, ".canVote"));

            // Parse nested vouching config (optional - use try/catch for backwards compat)
            try vm.parseJsonBool(configJson, string.concat(basePath, ".vouching.enabled")) returns (bool enabled) {
                config.roles[i].vouching.enabled = enabled;
                config.roles[i].vouching.quorum =
                    uint32(vm.parseJsonUint(configJson, string.concat(basePath, ".vouching.quorum")));
                config.roles[i].vouching.voucherRoleIndex =
                    vm.parseJsonUint(configJson, string.concat(basePath, ".vouching.voucherRoleIndex"));
                config.roles[i].vouching.combineWithHierarchy =
                    vm.parseJsonBool(configJson, string.concat(basePath, ".vouching.combineWithHierarchy"));
            } catch {}

            // Parse nested defaults config (optional)
            try vm.parseJsonBool(configJson, string.concat(basePath, ".defaults.eligible")) returns (bool eligible) {
                config.roles[i].defaults.eligible = eligible;
                config.roles[i].defaults.standing =
                    vm.parseJsonBool(configJson, string.concat(basePath, ".defaults.standing"));
            } catch {
                // Default to eligible=true, standing=true for backwards compat
                config.roles[i].defaults.eligible = true;
                config.roles[i].defaults.standing = true;
            }

            // Parse nested hierarchy config (optional)
            try vm.parseJsonUint(configJson, string.concat(basePath, ".hierarchy.adminRoleIndex")) returns (
                uint256 adminIdx
            ) {
                config.roles[i].hierarchy.adminRoleIndex = adminIdx;
            } catch {
                // Default to type(uint256).max for backwards compat
                config.roles[i].hierarchy.adminRoleIndex = type(uint256).max;
            }

            // Parse nested distribution config (optional)
            try vm.parseJsonBool(configJson, string.concat(basePath, ".distribution.mintToDeployer")) returns (
                bool mintToDeployer
            ) {
                config.roles[i].distribution.mintToDeployer = mintToDeployer;
                bytes memory additionalWearersData =
                    vm.parseJson(configJson, string.concat(basePath, ".distribution.additionalWearers"));
                config.roles[i].distribution.additionalWearers = abi.decode(additionalWearersData, (address[]));
            } catch {}

            // Parse nested hatConfig (optional)
            try vm.parseJsonUint(configJson, string.concat(basePath, ".hatConfig.maxSupply")) returns (
                uint256 maxSupply
            ) {
                config.roles[i].hatConfig.maxSupply = uint32(maxSupply);
                config.roles[i].hatConfig.mutableHat =
                    vm.parseJsonBool(configJson, string.concat(basePath, ".hatConfig.mutableHat"));
            } catch {
                // Default to unlimited and mutable for backwards compat
                config.roles[i].hatConfig.maxSupply = type(uint32).max;
                config.roles[i].hatConfig.mutableHat = true;
            }
        }

        // Parse voting classes array
        uint256 votingClassesLength = 0;
        for (uint256 i = 0; i < 100; i++) {
            // reasonable max
            try vm.parseJsonString(configJson, string.concat(".votingClasses[", vm.toString(i), "].strategy")) returns (
                string memory
            ) {
                votingClassesLength++;
            } catch {
                break;
            }
        }

        config.votingClasses = new VotingClassConfig[](votingClassesLength);
        for (uint256 i = 0; i < votingClassesLength; i++) {
            string memory basePath = string.concat(".votingClasses[", vm.toString(i), "]");
            config.votingClasses[i].strategy = vm.parseJsonString(configJson, string.concat(basePath, ".strategy"));
            config.votingClasses[i].slicePct = uint8(vm.parseJsonUint(configJson, string.concat(basePath, ".slicePct")));
            config.votingClasses[i].quadratic = vm.parseJsonBool(configJson, string.concat(basePath, ".quadratic"));
            config.votingClasses[i].minBalance = vm.parseJsonUint(configJson, string.concat(basePath, ".minBalance"));
            config.votingClasses[i].asset = vm.parseJsonAddress(configJson, string.concat(basePath, ".asset"));

            // Parse hatIds array
            bytes memory hatIdsData = vm.parseJson(configJson, string.concat(basePath, ".hatIds"));
            config.votingClasses[i].hatIds = abi.decode(hatIdsData, (uint256[]));
        }

        // Parse role assignments
        bytes memory quickJoinData = vm.parseJson(configJson, ".roleAssignments.quickJoinRoles");
        config.roleAssignments.quickJoinRoles = abi.decode(quickJoinData, (uint256[]));

        bytes memory tokenMemberData = vm.parseJson(configJson, ".roleAssignments.tokenMemberRoles");
        config.roleAssignments.tokenMemberRoles = abi.decode(tokenMemberData, (uint256[]));

        bytes memory tokenApproverData = vm.parseJson(configJson, ".roleAssignments.tokenApproverRoles");
        config.roleAssignments.tokenApproverRoles = abi.decode(tokenApproverData, (uint256[]));

        bytes memory taskCreatorData = vm.parseJson(configJson, ".roleAssignments.taskCreatorRoles");
        config.roleAssignments.taskCreatorRoles = abi.decode(taskCreatorData, (uint256[]));

        bytes memory educationCreatorData = vm.parseJson(configJson, ".roleAssignments.educationCreatorRoles");
        config.roleAssignments.educationCreatorRoles = abi.decode(educationCreatorData, (uint256[]));

        bytes memory educationMemberData = vm.parseJson(configJson, ".roleAssignments.educationMemberRoles");
        config.roleAssignments.educationMemberRoles = abi.decode(educationMemberData, (uint256[]));

        bytes memory hybridProposalData = vm.parseJson(configJson, ".roleAssignments.hybridProposalCreatorRoles");
        config.roleAssignments.hybridProposalCreatorRoles = abi.decode(hybridProposalData, (uint256[]));

        bytes memory ddVotingData = vm.parseJson(configJson, ".roleAssignments.ddVotingRoles");
        config.roleAssignments.ddVotingRoles = abi.decode(ddVotingData, (uint256[]));

        bytes memory ddCreatorData = vm.parseJson(configJson, ".roleAssignments.ddCreatorRoles");
        config.roleAssignments.ddCreatorRoles = abi.decode(ddCreatorData, (uint256[]));

        // Parse DD initial targets
        bytes memory ddTargetsData = vm.parseJson(configJson, ".ddInitialTargets");
        config.ddInitialTargets = abi.decode(ddTargetsData, (address[]));

        // Parse bootstrap config (optional)
        config.bootstrap = _parseBootstrapConfig(configJson);

        return config;
    }

    function _parseBootstrapConfig(string memory configJson) internal returns (BootstrapConfigJson memory bootstrap) {
        // Count bootstrap projects
        uint256 projectsLength = 0;
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonString(
                configJson, string.concat(".bootstrap.projects[", vm.toString(i), "].title")
            ) returns (
                string memory
            ) {
                projectsLength++;
            } catch {
                break;
            }
        }

        if (projectsLength == 0) {
            return bootstrap; // No bootstrap config
        }

        bootstrap.projects = new BootstrapProjectConfigJson[](projectsLength);
        for (uint256 i = 0; i < projectsLength; i++) {
            string memory basePath = string.concat(".bootstrap.projects[", vm.toString(i), "]");

            bootstrap.projects[i].title = vm.parseJsonString(configJson, string.concat(basePath, ".title"));

            // Parse metadataHash (optional, default to 0)
            try vm.parseJsonBytes32(configJson, string.concat(basePath, ".metadataHash")) returns (bytes32 hash) {
                bootstrap.projects[i].metadataHash = hash;
            } catch {
                bootstrap.projects[i].metadataHash = bytes32(0);
            }

            bootstrap.projects[i].cap = vm.parseJsonUint(configJson, string.concat(basePath, ".cap"));

            // Parse managers array (optional)
            try vm.parseJson(configJson, string.concat(basePath, ".managers")) returns (bytes memory managersData) {
                bootstrap.projects[i].managers = abi.decode(managersData, (address[]));
            } catch {
                bootstrap.projects[i].managers = new address[](0);
            }

            // Parse role arrays
            bytes memory createRolesData = vm.parseJson(configJson, string.concat(basePath, ".createRoles"));
            bootstrap.projects[i].createRoles = abi.decode(createRolesData, (uint256[]));

            bytes memory claimRolesData = vm.parseJson(configJson, string.concat(basePath, ".claimRoles"));
            bootstrap.projects[i].claimRoles = abi.decode(claimRolesData, (uint256[]));

            bytes memory reviewRolesData = vm.parseJson(configJson, string.concat(basePath, ".reviewRoles"));
            bootstrap.projects[i].reviewRoles = abi.decode(reviewRolesData, (uint256[]));

            bytes memory assignRolesData = vm.parseJson(configJson, string.concat(basePath, ".assignRoles"));
            bootstrap.projects[i].assignRoles = abi.decode(assignRolesData, (uint256[]));
        }

        // Count bootstrap tasks
        uint256 tasksLength = 0;
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonString(configJson, string.concat(".bootstrap.tasks[", vm.toString(i), "].title")) returns (
                string memory
            ) {
                tasksLength++;
            } catch {
                break;
            }
        }

        bootstrap.tasks = new BootstrapTaskConfigJson[](tasksLength);
        for (uint256 i = 0; i < tasksLength; i++) {
            string memory basePath = string.concat(".bootstrap.tasks[", vm.toString(i), "]");

            bootstrap.tasks[i].projectIndex =
                uint8(vm.parseJsonUint(configJson, string.concat(basePath, ".projectIndex")));
            bootstrap.tasks[i].payout = vm.parseJsonUint(configJson, string.concat(basePath, ".payout"));
            bootstrap.tasks[i].title = vm.parseJsonString(configJson, string.concat(basePath, ".title"));

            // Parse metadataHash (optional, default to 0)
            try vm.parseJsonBytes32(configJson, string.concat(basePath, ".metadataHash")) returns (bytes32 hash) {
                bootstrap.tasks[i].metadataHash = hash;
            } catch {
                bootstrap.tasks[i].metadataHash = bytes32(0);
            }

            bootstrap.tasks[i].bountyToken = vm.parseJsonAddress(configJson, string.concat(basePath, ".bountyToken"));
            bootstrap.tasks[i].bountyPayout = vm.parseJsonUint(configJson, string.concat(basePath, ".bountyPayout"));
            bootstrap.tasks[i].requiresApplication =
                vm.parseJsonBool(configJson, string.concat(basePath, ".requiresApplication"));
        }

        return bootstrap;
    }

    /*=========================== PARAM BUILDING ===========================*/

    function _roleArrayToBitmap(uint256[] memory roles) internal pure returns (uint256 bitmap) {
        for (uint256 i = 0; i < roles.length; i++) {
            require(roles[i] < 256, "Role index must be < 256");
            bitmap |= (1 << roles[i]);
        }
    }

    function _buildDeploymentParams(OrgConfigJson memory config, address globalAccountRegistry, address deployerAddress)
        internal
        pure
        returns (OrgDeployer.DeploymentParams memory params)
    {
        // Set basic params
        params.orgId = keccak256(bytes(config.orgId));
        params.orgName = config.orgName;
        params.metadataHash = bytes32(0); // No metadata hash for demo
        params.registryAddr = globalAccountRegistry;
        params.deployerAddress = deployerAddress; // Address to receive ADMIN hat
        params.deployerUsername = ""; // overridden by run() from DEPLOYER_USERNAME env var
        params.autoUpgrade = config.autoUpgrade;
        params.hybridThresholdPct = config.threshold.hybrid;
        params.ddThresholdPct = config.threshold.directDemocracy;
        params.ddInitialTargets = config.ddInitialTargets;

        // Build role configs
        params.roles = new RoleConfigStructs.RoleConfig[](config.roles.length);

        for (uint256 i = 0; i < config.roles.length; i++) {
            RoleConfig memory role = config.roles[i];

            params.roles[i] = RoleConfigStructs.RoleConfig({
                name: role.name,
                image: role.image,
                metadataCID: bytes32(0),
                canVote: role.canVote,
                vouching: RoleConfigStructs.RoleVouchingConfig({
                    enabled: role.vouching.enabled,
                    quorum: role.vouching.quorum,
                    voucherRoleIndex: role.vouching.voucherRoleIndex,
                    combineWithHierarchy: role.vouching.combineWithHierarchy
                }),
                defaults: RoleConfigStructs.RoleEligibilityDefaults({
                    eligible: role.defaults.eligible, standing: role.defaults.standing
                }),
                hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: role.hierarchy.adminRoleIndex}),
                distribution: RoleConfigStructs.RoleDistributionConfig({
                    mintToDeployer: role.distribution.mintToDeployer,
                    additionalWearers: role.distribution.additionalWearers
                }),
                hatConfig: RoleConfigStructs.HatConfig({
                    maxSupply: role.hatConfig.maxSupply, mutableHat: role.hatConfig.mutableHat
                })
            });
        }

        // Build voting classes
        params.hybridClasses = new IHybridVotingInit.ClassConfig[](config.votingClasses.length);

        for (uint256 i = 0; i < config.votingClasses.length; i++) {
            VotingClassConfig memory vClass = config.votingClasses[i];

            IHybridVotingInit.ClassStrategy strategy;
            if (keccak256(bytes(vClass.strategy)) == keccak256(bytes("DIRECT"))) {
                strategy = IHybridVotingInit.ClassStrategy.DIRECT;
            } else if (keccak256(bytes(vClass.strategy)) == keccak256(bytes("ERC20_BAL"))) {
                strategy = IHybridVotingInit.ClassStrategy.ERC20_BAL;
            } else {
                revert("Invalid strategy: must be DIRECT or ERC20_BAL");
            }

            params.hybridClasses[i] = IHybridVotingInit.ClassConfig({
                strategy: strategy,
                slicePct: vClass.slicePct,
                quadratic: vClass.quadratic,
                minBalance: vClass.minBalance,
                asset: vClass.asset,
                hatId: vClass.hatIds.length > 0 ? vClass.hatIds[0] : 0
            });
        }

        // Build role assignments (convert arrays to bitmaps)
        params.roleAssignments = OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: _roleArrayToBitmap(config.roleAssignments.quickJoinRoles),
            tokenMemberRolesBitmap: _roleArrayToBitmap(config.roleAssignments.tokenMemberRoles),
            tokenApproverRolesBitmap: _roleArrayToBitmap(config.roleAssignments.tokenApproverRoles),
            taskCreatorRolesBitmap: _roleArrayToBitmap(config.roleAssignments.taskCreatorRoles),
            educationCreatorRolesBitmap: _roleArrayToBitmap(config.roleAssignments.educationCreatorRoles),
            educationMemberRolesBitmap: _roleArrayToBitmap(config.roleAssignments.educationMemberRoles),
            hybridProposalCreatorRolesBitmap: _roleArrayToBitmap(config.roleAssignments.hybridProposalCreatorRoles),
            ddVotingRolesBitmap: _roleArrayToBitmap(config.roleAssignments.ddVotingRoles),
            ddCreatorRolesBitmap: _roleArrayToBitmap(config.roleAssignments.ddCreatorRoles)
        });

        // Build education hub config
        params.educationHubConfig = ModulesFactory.EducationHubConfig({enabled: config.withEducationHub});

        // Build bootstrap config for initial projects/tasks
        params.bootstrap = _buildBootstrapConfig(config.bootstrap);

        params.paymasterConfig = OrgDeployer.PaymasterConfig({
            operatorRoleIndex: type(uint256).max,
            autoWhitelistContracts: false,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            defaultBudgetCapPerEpoch: 0,
            defaultBudgetEpochLen: 0
        });

        return params;
    }

    function _buildBootstrapConfig(BootstrapConfigJson memory bootstrapJson)
        internal
        pure
        returns (OrgDeployer.BootstrapConfig memory bootstrap)
    {
        if (bootstrapJson.projects.length == 0) {
            return bootstrap; // Empty bootstrap
        }

        // Build project configs. Role-index arrays from JSON collapse to a single role
        // index per cap (first element). Sentinel `type(uint256).max` = "no override,
        // use global cap hat". OrgDeployer._resolveBootstrapHatIndex resolves the index
        // to an actual hat ID at deploy time.
        bootstrap.projects = new ITaskManagerBootstrap.BootstrapProjectConfig[](bootstrapJson.projects.length);
        for (uint256 i = 0; i < bootstrapJson.projects.length; i++) {
            bootstrap.projects[i] = ITaskManagerBootstrap.BootstrapProjectConfig({
                title: bytes(bootstrapJson.projects[i].title),
                metadataHash: bootstrapJson.projects[i].metadataHash,
                cap: bootstrapJson.projects[i].cap,
                managers: bootstrapJson.projects[i].managers,
                createHat: bootstrapJson.projects[i].createRoles.length > 0
                    ? bootstrapJson.projects[i].createRoles[0]
                    : type(uint256).max,
                claimHat: bootstrapJson.projects[i].claimRoles.length > 0
                    ? bootstrapJson.projects[i].claimRoles[0]
                    : type(uint256).max,
                reviewHat: bootstrapJson.projects[i].reviewRoles.length > 0
                    ? bootstrapJson.projects[i].reviewRoles[0]
                    : type(uint256).max,
                assignHat: bootstrapJson.projects[i].assignRoles.length > 0
                    ? bootstrapJson.projects[i].assignRoles[0]
                    : type(uint256).max,
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            });
        }

        // Build task configs
        bootstrap.tasks = new ITaskManagerBootstrap.BootstrapTaskConfig[](bootstrapJson.tasks.length);
        for (uint256 i = 0; i < bootstrapJson.tasks.length; i++) {
            bootstrap.tasks[i] = ITaskManagerBootstrap.BootstrapTaskConfig({
                projectIndex: bootstrapJson.tasks[i].projectIndex,
                payout: bootstrapJson.tasks[i].payout,
                title: bytes(bootstrapJson.tasks[i].title),
                metadataHash: bootstrapJson.tasks[i].metadataHash,
                bountyToken: bootstrapJson.tasks[i].bountyToken,
                bountyPayout: bootstrapJson.tasks[i].bountyPayout,
                requiresApplication: bootstrapJson.tasks[i].requiresApplication
            });
        }

        return bootstrap;
    }
}
