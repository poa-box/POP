// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../../src/OrgDeployer.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {IExecutor} from "../../src/Executor.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

interface IZkInvitesView {
    function merkleRoot() external view returns (bytes32);
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
 *           Quorum of 2 voters + PT rename to "comfiest.house shares"/"COMFY" + class
 *           restriction (exclude AGENT hat) are applied by the genesis proposal (Step2),
 *           because hat IDs don't exist until deploy and quorum/name are executor-gated.
 *   Paymaster: auto-whitelist all org contracts, generous caps (6M callGas for big
 *              announceWinner batches), 1 xDAI/day budget per role hat, funded with 5 xDAI.
 *   ZK email: module deployed dormant (no allowlist root); a steward activates rules later
 *             via governance `setActiveAllowlist(root, cid)`.
 *
 * Run order (all under FOUNDRY_PROFILE=production):
 *   1. SimComfiestHouse       --fork-url gnosis          (must PASS before any broadcast)
 *   2. Step1_DeployOrg        --broadcast                (~14M gas — fits Gnosis's 17M block
 *                                                         limit; funds paymaster 5 xDAI)
 *   3. Step2_GenesisProposal  --broadcast                (creates genesis proposal + votes YES;
 *                                                         id resolved on-chain, printed in logs)
 *   4. wait 30 min, then run the printed:
 *      cast send <hybridVoting> 'announceWinner(uint256)' <id> --gas-limit 3000000 ...
 */
abstract contract ComfiestHouseConfig is Script {
    // ── Gnosis protocol addresses ──
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
    uint32 constant QUORUM_VOTERS = 2; // min voters per proposal (set via genesis proposal)
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
        // hatIds left empty → factory backfills ALL role hats (incl. AGENT); the genesis
        // proposal (Step2) immediately restricts both classes to STEWARD+MEMBER. Until it
        // executes, only the deployer wears any hat, so no agent can vote in the gap.
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
            taskManagerPerms: _buildTaskPerms()
        });
    }

    function _zkConfig() internal pure returns (ModulesFactory.ZkEmailConfig memory) {
        return ModulesFactory.ZkEmailConfig({enabled: true, initialRoot: bytes32(0), initialCid: bytes32(0)});
    }

    /// @dev Genesis proposal batch: restrict voting classes to STEWARD+MEMBER, set quorum,
    ///      rename PT. All four calls are executor-gated, so they ride one YES batch.
    function _genesisBatch(address hv, address pt, uint256 stewardHat, uint256 memberHat)
        internal
        pure
        returns (IExecutor.Call[][] memory batches)
    {
        uint256[] memory voterHats = new uint256[](2);
        voterHats[0] = stewardHat;
        voterHats[1] = memberHat;

        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 80,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: voterHats
        });
        classes[1] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.ERC20_BAL,
            slicePct: 20,
            quadratic: false,
            minBalance: 0,
            asset: pt,
            hatIds: voterHats
        });

        IExecutor.Call[] memory yes = new IExecutor.Call[](4);
        yes[0] = IExecutor.Call({target: hv, value: 0, data: abi.encodeCall(HybridVoting.setClasses, (classes))});
        yes[1] = IExecutor.Call({
            target: hv,
            value: 0,
            data: abi.encodeCall(HybridVoting.setConfig, (HybridVoting.ConfigKey.QUORUM, abi.encode(QUORUM_VOTERS)))
        });
        yes[2] = IExecutor.Call({target: pt, value: 0, data: abi.encodeCall(ParticipationToken.setName, (PT_NAME))});
        yes[3] = IExecutor.Call({target: pt, value: 0, data: abi.encodeCall(ParticipationToken.setSymbol, (PT_SYMBOL))});

        batches = new IExecutor.Call[][](2);
        batches[0] = yes;
        batches[1] = new IExecutor.Call[](0); // NO = do nothing
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

    function run() external {
        address member = makeAddr("comfy-member");
        address agent = makeAddr("comfy-agent");
        address steward2 = makeAddr("comfy-steward2");
        address stranger = makeAddr("comfy-stranger");

        vm.deal(HUDSON, 100 ether);

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

        /* ── 3. Genesis proposal: classes restriction + quorum + PT rename ── */
        {
            vm.startPrank(HUDSON);
            hv.createProposal(
                bytes("genesis: quorum 2, voter classes, COMFY rename"),
                bytes32(0),
                PROPOSAL_MINUTES,
                2,
                _genesisBatch(r.hybridVoting, r.participationToken, stewardHat, memberHat),
                new uint256[](0)
            );
            uint8[] memory idx = new uint8[](1);
            uint8[] memory w = new uint8[](1);
            idx[0] = 0;
            w[0] = 100;
            hv.vote(0, idx, w);
            vm.stopPrank();

            vm.warp(vm.getBlockTimestamp() + (PROPOSAL_MINUTES + 1) * 60);
            (uint256 winner, bool valid) = hv.announceWinner(0);
            require(winner == 0 && valid, "genesis proposal failed");
            require(hv.quorum() == QUORUM_VOTERS, "quorum not set");
            require(keccak256(bytes(pt.name())) == keccak256(bytes(PT_NAME)), "PT name not set");
            require(keccak256(bytes(pt.symbol())) == keccak256(bytes(PT_SYMBOL)), "PT symbol not set");
            HybridVoting.ClassConfig[] memory cls = hv.getClasses();
            require(cls.length == 2 && cls[0].hatIds.length == 2 && cls[1].hatIds.length == 2, "classes not restricted");
            require(cls[1].asset == r.participationToken, "class 1 asset should be PT");
            console.log("genesis proposal executed: quorum=2, classes restricted, PT renamed");
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

            // member CAN create proposals (proposal #1); only Hudson votes -> quorum unmet
            vm.prank(member);
            hv.createProposal(bytes("quorum test: 1 voter"), bytes32(0), PROPOSAL_MINUTES, 2, noop, new uint256[](0));
            vm.prank(HUDSON);
            hv.vote(1, yesIdx, yesW);
            vm.warp(vm.getBlockTimestamp() + (PROPOSAL_MINUTES + 1) * 60);
            (, bool valid1) = hv.announceWinner(1);
            require(!valid1, "1 voter should NOT meet quorum of 2");

            // agent CAN create proposals (proposal #2) but CANNOT vote
            vm.prank(agent);
            hv.createProposal(bytes("agent proposal"), bytes32(0), PROPOSAL_MINUTES, 2, noop, new uint256[](0));
            vm.prank(agent);
            vm.expectRevert();
            hv.vote(2, yesIdx, yesW);

            vm.prank(HUDSON);
            hv.vote(2, yesIdx, yesW);
            vm.prank(member);
            hv.vote(2, yesIdx, yesW);
            vm.warp(vm.getBlockTimestamp() + (PROPOSAL_MINUTES + 1) * 60);
            (uint256 win2, bool valid2) = hv.announceWinner(2);
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
        console.log("NEXT: run Step2_GenesisProposal, wait 30 min, then announceWinner(0)");
    }
}

/*═══════════════════ BROADCAST STEP 2: genesis proposal + vote ═══════════════════*/

contract Step2_GenesisProposal is ComfiestHouseConfig {
    function run() external {
        bytes32 orgId = _orgId();
        OrgRegistry reg = OrgRegistry(ORG_REGISTRY);
        address hv = reg.getOrgContract(orgId, ModuleTypes.HYBRID_VOTING_ID);
        address pt = reg.getOrgContract(orgId, ModuleTypes.PARTICIPATION_TOKEN_ID);
        uint256 stewardHat = reg.getRoleHat(orgId, IDX_STEWARD);
        uint256 memberHat = reg.getRoleHat(orgId, IDX_MEMBER);
        require(hv != address(0) && pt != address(0) && stewardHat != 0 && memberHat != 0, "org not deployed?");

        uint8[] memory idx = new uint8[](1);
        uint8[] memory w = new uint8[](1);
        idx[0] = 0;
        w[0] = 100;

        // Resolve the id this proposal WILL get (ids are sequential = proposalsCount).
        // Hardcoding 0 would silently vote on the wrong proposal if anything created one
        // via the frontend between Step1 and Step2.
        uint256 proposalId = HybridVoting(payable(hv)).proposalsCount();

        vm.startBroadcast();
        HybridVoting(payable(hv))
            .createProposal(
                bytes("genesis: quorum 2, voter classes, COMFY rename"),
                bytes32(0),
                PROPOSAL_MINUTES,
                2,
                _genesisBatch(hv, pt, stewardHat, memberHat),
                new uint256[](0)
            );
        HybridVoting(payable(hv)).vote(proposalId, idx, w);
        vm.stopBroadcast();

        console.log("=== genesis proposal created + YES vote cast; proposal id:", proposalId);
        console.log("hybridVoting:", hv);
        console.log("After 30 minutes, finalize with an explicit gas limit (do NOT rely on estimation):");
        console.log("  cast send", hv);
        console.log("    'announceWinner(uint256)'", proposalId);
        console.log("    --rpc-url gnosis --gas-limit 3000000 --private-key $DEPLOYER_PRIVATE_KEY");
    }
}
