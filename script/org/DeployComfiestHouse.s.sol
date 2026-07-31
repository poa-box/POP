// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {IExecutor} from "../../src/Executor.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

interface IZkInvitesView {
    function merkleRoot() external view returns (bytes32);
}

interface ISatelliteV17 {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

/**
 * @title  DeployComfiestHouse
 * @notice Deploys the "comfiest.house" org on Gnosis with zk-email enabled (dormant allowlist).
 *
 * Org spec:
 *   Roles: 0=STEWARD, 1=MEMBER, 2=AGENT — all vouch-gated (1 vouch from a Steward).
 *     STEWARD: full task/project perms (create/claim/review/assign/budget/edit), creates
 *              proposals, edits org metadata, votes. Deployer (Hudson) seeded as first steward.
 *     MEMBER:  creates + claims tasks (no review, no project creation), creates proposals, votes.
 *     AGENT:   creates tasks, projects, and proposals; cannot vote, review, or claim tasks.
 *   Voting: HybridVoting 80% membership (DIRECT) / 20% participation (PT), 50% threshold.
 *           Quorum of 2 voters, AGENT exclusion (canVote=false roles are filtered out of
 *           the voting classes), and the "comfiest.house shares"/"COMFY" token identity
 *           are all set AT DEPLOY via the v17 deploy-time governance config — no genesis
 *           proposal needed.
 *   Paymaster: auto-whitelist all org contracts, generous caps (6M callGas for big
 *              announceWinner batches), 1 xDAI/day budget per role hat, funded with 5 xDAI.
 *   ZK email: module deployed dormant (no allowlist root); a steward activates rules later
 *             via governance `setActiveAllowlist(root, cid)`.
 *
 * Run order (all under FOUNDRY_PROFILE=production):
 *   0. PREREQUISITE: the deploy-time-governance-config rollout must be LIVE on Gnosis
 *      (script/upgrades/UpgradeDeployTimeGovConfig.s.sol — HybridVoting v12, DDV v12,
 *      OrgDeployer v17, new Governance/Access factories). The sim applies it on the
 *      fork automatically; the broadcast requires it on-chain first.
 *   1. SimComfiestHouse  --fork-url gnosis   (must PASS before any broadcast)
 *   2. Step1_DeployOrg   --broadcast         (~14M gas — fits Gnosis's 17M block limit;
 *                                             funds paymaster 5 xDAI; nothing else to run)
 */
abstract contract ComfiestHouseConfig is Script {
    // ── Gnosis protocol addresses ──
    address constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06; // owner = Hudson
    address constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;
    address constant PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address constant ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    // ── Org constants ──
    string constant ORG_NAME = "comfiest.house";
    string constant PT_NAME = "comfiest.house shares";
    string constant PT_SYMBOL = "COMFY";
    uint256 constant PAYMASTER_FUNDING = 5 ether; // 5 xDAI initial gas sponsorship pool
    uint8 constant THRESHOLD_PCT = 50; // simple majority (hybrid + DD)
    uint32 constant QUORUM_VOTERS = 2; // min voters per proposal (set at deploy, v17)
    uint32 constant PROPOSAL_MINUTES = 30;

    uint256 constant IDX_STEWARD = 0;
    uint256 constant IDX_MEMBER = 1;
    uint256 constant IDX_AGENT = 2;

    function _orgId() internal pure returns (bytes32) {
        return keccak256(bytes(ORG_NAME));
    }

    function _buildRoles() internal pure returns (RoleConfigStructs.RoleConfig[] memory roles) {
        roles = new RoleConfigStructs.RoleConfig[](3);
        string[3] memory names = ["STEWARD", "MEMBER", "AGENT"];
        for (uint256 i; i < 3; i++) {
            roles[i] = RoleConfigStructs.RoleConfig({
                name: names[i],
                image: "",
                metadataCID: bytes32(0),
                canVote: i != IDX_AGENT,
                // every role needs 1 vouch from a STEWARD. combineWithHierarchy MUST be true:
                // vouch-only mode ignores explicit per-wearer rules, which would strip the
                // deployer's seeded steward eligibility. With defaults.eligible=false the
                // hierarchy path grants nothing to anyone else, so the vouch gate holds.
                vouching: RoleConfigStructs.RoleVouchingConfig({
                    enabled: true, quorum: 1, voucherRoleIndex: IDX_STEWARD, combineWithHierarchy: true
                }),
                defaults: RoleConfigStructs.RoleEligibilityDefaults({eligible: false, standing: true}),
                hierarchy: RoleConfigStructs.RoleHierarchyConfig({adminRoleIndex: type(uint256).max}),
                distribution: RoleConfigStructs.RoleDistributionConfig({
                    mintToDeployer: i == IDX_STEWARD, // Hudson = bootstrap first steward
                    additionalWearers: new address[](0)
                }),
                hatConfig: RoleConfigStructs.HatConfig({maxSupply: 0, mutableHat: true})
            });
        }
    }

    function _buildAssignments() internal pure returns (OrgDeployer.RoleAssignments memory) {
        return OrgDeployer.RoleAssignments({
            quickJoinRolesBitmap: 0, // no open join: every role is vouch-gated
            tokenMemberRolesBitmap: 0x3, // steward + member hold PT
            tokenApproverRolesBitmap: 0x1, // steward approves transfer requests
            taskCreatorRolesBitmap: 0x5, // PROJECT creators: steward + agent (not member)
            educationCreatorRolesBitmap: 0x1, // steward
            educationMemberRolesBitmap: 0x3, // steward + member
            hybridProposalCreatorRolesBitmap: 0x7, // steward + member + agent all propose
            ddVotingRolesBitmap: 0x3, // steward + member vote in polls
            ddCreatorRolesBitmap: 0x7 // all three create polls
        });
    }

    function _buildClasses() internal pure returns (IHybridVotingInit.ClassConfig[] memory classes) {
        classes = new IHybridVotingInit.ClassConfig[](2);
        // hatIds left empty → the factory backfills them with canVote=true role hats only
        // (v17 deploy-time filter), so STEWARD + MEMBER are in and AGENT is excluded from
        // genesis with no post-deploy proposal needed.
        classes[0] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.DIRECT,
            slicePct: 80,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: new uint256[](0)
        });
        classes[1] = IHybridVotingInit.ClassConfig({
            strategy: IHybridVotingInit.ClassStrategy.ERC20_BAL,
            slicePct: 20,
            quadratic: false,
            minBalance: 0,
            asset: address(0), // backfilled with the org's soulbound ParticipationToken
            hatIds: new uint256[](0)
        });
    }

    /// @dev TaskPerm masks: STEWARD full (255), MEMBER CREATE|CLAIM (3), AGENT CREATE (1)
    function _buildTaskPerms() internal pure returns (OrgDeployer.TaskManagerPermConfig memory) {
        uint256[] memory idx = new uint256[](3);
        uint8[] memory masks = new uint8[](3);
        idx[0] = IDX_STEWARD;
        masks[0] = 255;
        idx[1] = IDX_MEMBER;
        masks[1] = 3;
        idx[2] = IDX_AGENT;
        masks[2] = 1;
        return OrgDeployer.TaskManagerPermConfig({roleIndices: idx, masks: masks});
    }

    function _buildPaymasterConfig() internal pure returns (OrgDeployer.PaymasterConfig memory) {
        return OrgDeployer.PaymasterConfig({
            operatorRoleIndex: IDX_STEWARD,
            autoWhitelistContracts: true,
            // generous spam guards: Gnosis runs ~1-2 gwei, big announceWinner batches ~3M gas
            maxFeePerGas: 50 gwei,
            maxPriorityFeePerGas: 10 gwei,
            maxCallGas: 6_000_000,
            maxVerificationGas: 2_000_000,
            maxPreVerificationGas: 1_000_000,
            defaultBudgetCapPerEpoch: 1 ether, // 1 xDAI per role hat per day
            defaultBudgetEpochLen: 1 days
        });
    }

    function _buildParams() internal pure returns (OrgDeployer.DeploymentParams memory) {
        return OrgDeployer.DeploymentParams({
            orgId: _orgId(),
            orgName: ORG_NAME,
            metadataHash: bytes32(0),
            registryAddr: ACCOUNT_REGISTRY,
            deployerAddress: HUDSON,
            deployerUsername: "", // already registered as "hudsonhrh"
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true, // Mirror mode: follow protocol upgrades
            hybridThresholdPct: THRESHOLD_PCT,
            ddThresholdPct: THRESHOLD_PCT,
            hybridClasses: _buildClasses(),
            ddInitialTargets: new address[](0),
            roles: _buildRoles(),
            roleAssignments: _buildAssignments(),
            metadataAdminRoleIndex: IDX_STEWARD,
            passkeyEnabled: true,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: true}),
            bootstrap: OrgDeployer.BootstrapConfig({
                projects: new ITaskManagerBootstrap.BootstrapProjectConfig[](0),
                tasks: new ITaskManagerBootstrap.BootstrapTaskConfig[](0)
            }),
            paymasterConfig: _buildPaymasterConfig(),
            taskManagerPerms: _buildTaskPerms(),
            hybridQuorum: QUORUM_VOTERS, // set at deploy (v17) — no genesis proposal needed
            ddQuorum: QUORUM_VOTERS,
            tokenName: PT_NAME,
            tokenSymbol: PT_SYMBOL
        });
    }

    function _zkConfig() internal pure returns (ModulesFactory.ZkEmailConfig memory) {
        return ModulesFactory.ZkEmailConfig({enabled: true, initialRoot: bytes32(0), initialCid: bytes32(0)});
    }

    function _emptyProject(bytes memory title) internal pure returns (TaskManager.BootstrapProjectConfig memory) {
        return TaskManager.BootstrapProjectConfig({
            title: title,
            metadataHash: bytes32(0),
            cap: 0,
            managers: new address[](0),
            createHats: new uint256[](0), // empty per-project perms → global TaskPerm grants apply
            claimHats: new uint256[](0),
            reviewHats: new uint256[](0),
            assignHats: new uint256[](0),
            bountyTokens: new address[](0),
            bountyCaps: new uint256[](0)
        });
    }
}

/*══════════════════════════ SIM (run first, must PASS) ══════════════════════════*/

contract SimComfiestHouse is ComfiestHouseConfig {
    IHats constant hats = IHats(HATS);

    /// @dev FORK-ONLY pre-step: applies the v17 deploy-time-governance-config rollout
    ///      (HybridVoting v12, DDV v12, OrgDeployer v17, fresh Governance/Access factories)
    ///      so this sim exercises the exact post-rollout deploy path. The real rollout
    ///      broadcast is script/upgrades/UpgradeDeployTimeGovConfig.s.sol and MUST be live
    ///      on Gnosis before Step1_DeployOrg is broadcast.
    function _applyV17OnFork() internal {
        address newHV = address(new HybridVoting());
        address newDDV = address(new DirectDemocracyVoting());
        address newOD = address(new OrgDeployer());
        address newGF = address(new GovernanceFactory());
        address newAF = address(new AccessFactory());

        vm.startPrank(HUDSON);
        ISatelliteV17(SATELLITE).upgradeBeaconDirect("HybridVoting", newHV, "v12");
        ISatelliteV17(SATELLITE).upgradeBeaconDirect("DirectDemocracyVoting", newDDV, "v12");
        ISatelliteV17(SATELLITE).upgradeBeaconDirect("OrgDeployer", newOD, "v17");
        ISatelliteV17(SATELLITE)
            .adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setGovernanceFactory(address)", newGF));
        ISatelliteV17(SATELLITE).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setAccessFactory(address)", newAF));
        vm.stopPrank();
        console.log("fork pre-step: v17 governance-config rollout applied");
    }

    function run() external {
        address member = makeAddr("comfy-member");
        address agent = makeAddr("comfy-agent");
        address steward2 = makeAddr("comfy-steward2");
        address stranger = makeAddr("comfy-stranger");

        vm.deal(HUDSON, 100 ether);
        _applyV17OnFork();

        /* ── 1. Deploy ── */
        uint256 gasBefore = gasleft();
        vm.prank(HUDSON);
        OrgDeployer.DeploymentResult memory r =
            OrgDeployer(ORG_DEPLOYER).deployFullOrgWithZkEmail{value: PAYMASTER_FUNDING}(_buildParams(), _zkConfig());
        console.log("deploy gas used (must fit Gnosis block gas limit):", gasBefore - gasleft());

        require(r.hybridVoting != address(0) && r.executor != address(0), "core modules missing");
        require(r.educationHub != address(0), "educationHub missing");
        require(r.paymentManager != address(0), "paymentManager missing");
        require(r.zkEmailInvites != address(0), "zkEmailInvites missing (infra not wired?)");
        require(IZkInvitesView(r.zkEmailInvites).merkleRoot() == bytes32(0), "zk allowlist should be dormant");
        console.log("org deployed; zkEmailInvites (dormant):", r.zkEmailInvites);

        bytes32 orgId = _orgId();
        OrgRegistry reg = OrgRegistry(ORG_REGISTRY);
        uint256 stewardHat = reg.getRoleHat(orgId, IDX_STEWARD);
        uint256 memberHat = reg.getRoleHat(orgId, IDX_MEMBER);
        uint256 agentHat = reg.getRoleHat(orgId, IDX_AGENT);
        require(stewardHat != 0 && memberHat != 0 && agentHat != 0, "role hats not registered");
        require(hats.isWearerOfHat(HUDSON, stewardHat), "deployer not seeded as steward");
        require(reg.getOrgMetadataAdminHat(orgId) == stewardHat, "metadata admin should be steward hat");

        /* ── 2. Paymaster wiring ── */
        {
            PaymasterHub hub = PaymasterHub(payable(PAYMASTER));
            require(hub.getOrgFinancials(orgId).deposited == PAYMASTER_FUNDING, "paymaster funding not credited");
            PaymasterHub.FeeCaps memory caps = hub.getFeeCaps(orgId);
            require(caps.maxCallGas == 6_000_000, "maxCallGas cap wrong");
            require(caps.maxFeePerGas == 50 gwei, "maxFeePerGas cap wrong");
            PaymasterHub.Rule memory announceRule =
                hub.getRule(orgId, r.hybridVoting, bytes4(keccak256("announceWinner(uint256)")));
            require(announceRule.allowed && announceRule.maxCallGasHint == 0, "announceWinner rule wrong");
            PaymasterHub.Rule memory claimRule =
                hub.getRule(orgId, r.taskManager, bytes4(keccak256("claimTask(uint256)")));
            require(claimRule.allowed, "claimTask rule missing");
            bytes32 memberBudgetKey = keccak256(abi.encodePacked(uint8(0x01), bytes32(memberHat)));
            require(hub.getBudget(orgId, memberBudgetKey).capPerEpoch == 1 ether, "member hat budget missing");
            bytes32 zkBudgetKey = keccak256(abi.encodePacked(uint8(0x05), bytes32(uint256(uint160(r.zkEmailInvites)))));
            require(hub.getBudget(orgId, zkBudgetKey).capPerEpoch == 1 ether, "zk claim budget missing");
            console.log("paymaster: funded, caps + rules + budgets verified");
        }

        HybridVoting hv = HybridVoting(payable(r.hybridVoting));
        ParticipationToken pt = ParticipationToken(r.participationToken);
        EligibilityModule elig = EligibilityModule(payable(r.eligibilityModule));
        TaskManager tm = TaskManager(r.taskManager);

        /* ── 3. Deploy-time governance config (v17): quorum, voter classes, token identity ── */
        {
            require(hv.quorum() == QUORUM_VOTERS, "quorum not set at deploy");
            require(keccak256(bytes(pt.name())) == keccak256(bytes(PT_NAME)), "PT name not set at deploy");
            require(keccak256(bytes(pt.symbol())) == keccak256(bytes(PT_SYMBOL)), "PT symbol not set at deploy");
            HybridVoting.ClassConfig[] memory cls = hv.getClasses();
            require(cls.length == 2, "class count wrong");
            // AGENT has canVote=false, so the deploy-time filter excludes its hat from both classes
            require(cls[0].hatIds.length == 2 && cls[1].hatIds.length == 2, "classes should hold steward+member only");
            require(cls[0].hatIds[0] == stewardHat && cls[0].hatIds[1] == memberHat, "class 0 hats wrong");
            require(cls[1].asset == r.participationToken, "class 1 asset should be PT");
            console.log("deploy-time config verified: quorum=2, classes exclude AGENT, PT = COMFY");
        }

        /* ── 4. Vouch flows: 1 steward vouch gates every role ── */
        {
            // non-steward cannot vouch
            vm.prank(stranger);
            vm.expectRevert();
            elig.vouchFor(member, memberHat);

            // un-vouched cannot claim
            vm.prank(stranger);
            vm.expectRevert();
            elig.claimVouchedHat(memberHat);

            vm.startPrank(HUDSON);
            elig.vouchFor(member, memberHat);
            elig.vouchFor(agent, agentHat);
            elig.vouchFor(steward2, stewardHat);
            vm.stopPrank();

            vm.prank(member);
            elig.claimVouchedHat(memberHat);
            vm.prank(agent);
            elig.claimVouchedHat(agentHat);
            vm.prank(steward2);
            elig.claimVouchedHat(stewardHat);
            require(hats.isWearerOfHat(member, memberHat), "member claim failed");
            require(hats.isWearerOfHat(agent, agentHat), "agent claim failed");
            require(hats.isWearerOfHat(steward2, stewardHat), "steward2 claim failed");

            // a member (non-steward) still cannot vouch
            vm.prank(member);
            vm.expectRevert();
            elig.vouchFor(stranger, memberHat);
            console.log("vouch flows verified (member, agent, steward2 onboarded)");
        }

        uint8[] memory yesIdx = new uint8[](1);
        uint8[] memory yesW = new uint8[](1);
        yesIdx[0] = 0;
        yesW[0] = 100;

        /* ── 5. Quorum enforcement: 1 voter fails, 2 voters pass ── */
        {
            IExecutor.Call[][] memory noop = new IExecutor.Call[][](2);
            noop[0] = new IExecutor.Call[](0);
            noop[1] = new IExecutor.Call[](0);

            // member CAN create proposals (proposal #0); only Hudson votes -> quorum unmet
            vm.prank(member);
            hv.createProposal(bytes("quorum test: 1 voter"), bytes32(0), PROPOSAL_MINUTES, 2, noop, new uint256[](0));
            vm.prank(HUDSON);
            hv.vote(0, yesIdx, yesW);
            vm.warp(vm.getBlockTimestamp() + (PROPOSAL_MINUTES + 1) * 60);
            (, bool valid1) = hv.announceWinner(0);
            require(!valid1, "1 voter should NOT meet quorum of 2");

            // agent CAN create proposals (proposal #1) but CANNOT vote
            vm.prank(agent);
            hv.createProposal(bytes("agent proposal"), bytes32(0), PROPOSAL_MINUTES, 2, noop, new uint256[](0));
            vm.prank(agent);
            vm.expectRevert();
            hv.vote(1, yesIdx, yesW);

            vm.prank(HUDSON);
            hv.vote(1, yesIdx, yesW);
            vm.prank(member);
            hv.vote(1, yesIdx, yesW);
            vm.warp(vm.getBlockTimestamp() + (PROPOSAL_MINUTES + 1) * 60);
            (uint256 win2, bool valid2) = hv.announceWinner(1);
            require(win2 == 0 && valid2, "2 voters should meet quorum");
            console.log("governance verified: quorum=2 enforced, agent proposes but cannot vote");
        }

        /* ── 6. Task lifecycle + permission boundaries ── */
        {
            // steward creates a project (global perms apply: no per-project overrides)
            vm.prank(HUDSON);
            bytes32 pid = tm.createProject(_emptyProject(bytes("genesis project")));

            // member cannot create projects
            vm.prank(member);
            vm.expectRevert();
            tm.createProject(_emptyProject(bytes("member project")));

            // agent CAN create projects. NOTE: TaskManager makes every project creator a
            // project MANAGER of that project (perm-check bypass inside it) — so agents have
            // full control within projects they create, but no claim/review anywhere else.
            vm.prank(agent);
            bytes32 pidAgent = tm.createProject(_emptyProject(bytes("agent project")));

            // member creates + claims + submits task #0; steward reviews
            vm.startPrank(member);
            tm.createTask(10e18, bytes("first task"), bytes32(0), pid, address(0), 0, false, 0, 0);
            tm.claimTask(0);
            tm.submitTask(0, keccak256("done"));
            vm.stopPrank();

            // neither member nor agent can review
            vm.prank(member);
            vm.expectRevert();
            tm.completeTask(0);
            vm.prank(agent);
            vm.expectRevert();
            tm.completeTask(0);

            vm.prank(HUDSON);
            tm.completeTask(0);
            require(pt.balanceOf(member) == 10e18, "PT payout not minted to member");

            // agent creates task #1 in its own project; member claims it; steward2 reviews
            vm.prank(agent);
            tm.createTask(5e18, bytes("agent-created task"), bytes32(0), pidAgent, address(0), 0, false, 0, 0);
            vm.startPrank(member);
            tm.claimTask(1);
            tm.submitTask(1, keccak256("done2"));
            vm.stopPrank();
            vm.prank(steward2);
            tm.completeTask(1);
            require(pt.balanceOf(member) == 15e18, "second payout missing");

            // org-wide boundary: agent has no CLAIM in projects it did NOT create
            vm.prank(member);
            tm.createTask(1e18, bytes("open task"), bytes32(0), pid, address(0), 0, false, 0, 0);
            vm.prank(agent);
            vm.expectRevert();
            tm.claimTask(2);
            console.log("task lifecycle verified: perms match spec, PT payouts mint");
        }

        console.log("");
        console.log("=== PASS: comfiest.house full deploy + genesis + actions verified on Gnosis fork ===");
    }
}

/*══════════════════════════ BROADCAST STEP 1: deploy ══════════════════════════*/

contract Step1_DeployOrg is ComfiestHouseConfig {
    function run() external {
        vm.startBroadcast();
        OrgDeployer.DeploymentResult memory r =
            OrgDeployer(ORG_DEPLOYER).deployFullOrgWithZkEmail{value: PAYMASTER_FUNDING}(_buildParams(), _zkConfig());
        vm.stopBroadcast();

        console.log("=== comfiest.house deployed on Gnosis ===");
        console.log("orgId:");
        console.logBytes32(_orgId());
        console.log("executor:            ", r.executor);
        console.log("hybridVoting:        ", r.hybridVoting);
        console.log("directDemocracy:     ", r.directDemocracyVoting);
        console.log("quickJoin:           ", r.quickJoin);
        console.log("participationToken:  ", r.participationToken);
        console.log("taskManager:         ", r.taskManager);
        console.log("educationHub:        ", r.educationHub);
        console.log("paymentManager:      ", r.paymentManager);
        console.log("eligibilityModule:   ", r.eligibilityModule);
        console.log("zkEmailInvites:      ", r.zkEmailInvites);
        console.log("");
        console.log("Done - quorum, voter classes, and COMFY identity were all set at deploy.");
    }
}
