// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Executor, IExecutor} from "../src/Executor.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {AuthorityRouter} from "../src/AuthorityRouter.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2Ids} from "../src/libs/AccessV2Ids.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";

import {MockHats} from "./mocks/MockHats.sol";
import {MockRegistry} from "./QuickJoin.t.sol";

/**
 * @title AccessV2AcceptanceTest — the v2 org-level acceptance suite (Wave C / C1).
 * @notice Ports the v1 "KUBI story" (the RoleManager integration suite, deleted with the v1 access
 *         rails in Wave F) onto v2 rails: a FULL v2 org
 *         wired dual-path — real MembershipAuthority (+ its delegatecall libs), a real Executor
 *         repointed via setMembershipAuthority, real DirectDemocracyVoting + HybridVoting + TaskManager
 *         + ParticipationToken + QuickJoin, plus the protocol AuthorityRouter over a real OrgRegistry.
 *         Governance is driven through the REAL Executor (configureModule owner-relay for the cheap
 *         ceremony writes; Executor.execute for the election batch). No Hats fork, no marker-hat
 *         stratum (deleted): the same org-level outcomes are asserted on the unified subject model.
 *
 *         v1 scenario → v2 scenario mapping:
 *           1. group + roles + perm fan-out + grant-to-member ⇒ perms live on TM / HV-create / DD-vote.
 *           2. out-of-org offer → claim; the paymaster-shaped router.isEligible-true-pre-claim invariant.
 *           3. exec-only restricted DD poll via the GROUP subject id; HV class over the group subject
 *              with the W2 snapshot-only semantics.
 *           4. election batch through the real Executor.execute + the activation gate.
 *           5. delegated management (setManagerConfig / pend / finalize / void / lose-seat).
 *           6. kick semantics (hard ban supremacy; sticky-grant survival; renounce leaves claimable).
 *           7. adoption-shaped seed on a SECOND authority + router bind + paymaster read chain.
 *           8. QuickJoin join on v2 rails through the unchanged Executor mint loop.
 */
contract AccessV2AcceptanceTest is Test {
    /*───────────────────────── Contracts ─────────────────────────*/
    Executor internal exec;
    MembershipAuthority internal auth;
    DirectDemocracyVoting internal dd;
    HybridVoting internal hv;
    TaskManager internal tm;
    ParticipationToken internal pt;
    QuickJoin internal qj;
    OrgRegistry internal orgReg;
    AuthorityRouter internal router;
    MockHats internal legacyHats;
    MockRegistry internal accountReg;

    /*───────────────────────── Subjects ─────────────────────────*/
    uint256 internal member; // base default-ALLOW membership role (+ QJ_AUTOJOIN)
    uint256 internal presRole; // President identity role (member-role of Executives)
    uint256 internal vpRole; // VP identity role (member-role of Executives)
    uint256 internal execGroup; // Executives group (carries the shared perm fan-out)

    /*───────────────────────── Actors ─────────────────────────*/
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal ianthe = makeAddr("ianthe");
    address internal dave = makeAddr("dave"); // out-of-org (offer/claim)
    address internal outsider = makeAddr("outsider");

    /*───────────────────────── Config ─────────────────────────*/
    uint8 internal constant THRESHOLD = 50;
    uint32 internal constant DD_QUORUM = 1;
    bytes32 internal constant ORG_ID = keccak256("KUBI.v2");
    uint256 internal constant ORG_DOMAIN = 0xABBA; // this org's Hats tophat domain (adoption-safe)
    address internal admin = makeAddr("protocolAdmin");
    address internal hub = address(0xBEEF);

    /*──────────── lifecycle events mirrored for expectEmit ────────────*/
    event RoleClaimed(uint256 indexed subjectId, address indexed user);
    event RoleGranted(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleOffered(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleRemoved(uint256 indexed subjectId, address indexed user, bool banned, address actor, bool delegated);
    event RoleRenounced(uint256 indexed subjectId, address indexed user);
    event OfferWithdrawn(uint256 indexed subjectId, address indexed user, address actor);
    event MembershipReconciled(uint256 indexed subjectId, address indexed user);
    event PendingActionCreated(
        uint256 indexed pendingId,
        uint256 indexed subjectId,
        address indexed user,
        uint8 action,
        address actor,
        uint64 activatesAt
    );
    event QuickJoined(address indexed user, uint256[] hatIds);

    /*═══════════════════════════════ setUp: stand up the whole org ═══════════════════════════════*/

    function setUp() public {
        legacyHats = new MockHats();
        accountReg = new MockRegistry();

        // 1. Real Executor — this test contract is BOTH owner (configureModule relay) and the sole
        //    governor (allowedCaller, for Executor.execute batches).
        exec = Executor(
            payable(_proxy(
                    address(new Executor()), abi.encodeCall(Executor.initialize, (address(this), address(legacyHats)))
                ))
        );
        exec.setCaller(address(this));

        // 2. Protocol singletons: a real OrgRegistry + the AuthorityRouter, with THIS org registered so
        //    its self-routing v2 ids resolve through the router (paymaster read surface).
        orgReg = OrgRegistry(
            _proxy(
                address(new OrgRegistry()), abi.encodeCall(OrgRegistry.initialize, (address(this), address(legacyHats)))
            )
        );
        router = AuthorityRouter(
            _proxy(
                address(new AuthorityRouter()),
                abi.encodeCall(AuthorityRouter.initialize, (address(legacyHats), address(orgReg), hub, admin))
            )
        );
        orgReg.registerOrg(ORG_ID, address(exec), bytes("KUBI"), bytes32(0));
        orgReg.registerHatsTree(ORG_ID, ORG_DOMAIN << 224, new uint256[](0));

        // 3. The org's MembershipAuthority (executor gate == the Executor). Born paused.
        auth = MembershipAuthority(
            _proxy(
                address(new MembershipAuthority()),
                abi.encodeCall(
                    MembershipAuthority.initialize,
                    (IMembershipAuthority.InitConfig({
                            executor: address(exec), paymasterHub: hub, orgId: ORG_ID, seed: _emptySeed()
                        }))
                )
            )
        );

        // 4. Sibling modules (legacy Hats at init; repointed to the authority below).
        pt = ParticipationToken(
            _proxy(
                address(new ParticipationToken()),
                abi.encodeCall(
                    ParticipationToken.initialize,
                    (address(exec), "Participation", "PT", address(legacyHats), _u(), _u())
                )
            )
        );
        tm = TaskManager(
            _proxy(
                address(new TaskManager()),
                abi.encodeCall(
                    TaskManager.initialize, (address(pt), address(legacyHats), _u(), address(exec), address(0))
                )
            )
        );
        dd = DirectDemocracyVoting(
            _proxy(
                address(new DirectDemocracyVoting()),
                abi.encodeCall(
                    DirectDemocracyVoting.initialize,
                    (address(legacyHats), address(exec), _u(), _u(), _a(), THRESHOLD, DD_QUORUM)
                )
            )
        );
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(pt),
            hatIds: _u()
        });
        hv = HybridVoting(
            _proxy(
                address(new HybridVoting()),
                abi.encodeCall(
                    HybridVoting.initialize, (address(legacyHats), address(exec), _u(), _a(), THRESHOLD, 0, classes)
                )
            )
        );
        qj = QuickJoin(
            _proxy(
                address(new QuickJoin()),
                abi.encodeCall(
                    QuickJoin.initialize, (address(exec), address(legacyHats), address(accountReg), address(this), _u())
                )
            )
        );

        // 5. Governance ceremony (through the real Executor, owner-relay). Unpause + repoint everything
        //    to the authority + wire the modules.
        _gov(address(auth), abi.encodeCall(MembershipAuthority.setPaused, (false)));
        exec.setMembershipAuthority(address(auth)); // §4.7: Executor.hats() now resolves to the authority
        _gov(address(dd), abi.encodeCall(DirectDemocracyVoting.setMembershipAuthority, (address(auth))));
        _gov(address(hv), abi.encodeCall(HybridVoting.setMembershipAuthority, (address(auth))));
        _gov(address(tm), abi.encodeCall(TaskManager.setMembershipAuthority, (address(auth))));
        _gov(address(pt), abi.encodeCall(ParticipationToken.setMembershipAuthority, (address(auth))));
        _gov(address(qj), abi.encodeCall(QuickJoin.setMembershipAuthority, (address(auth))));
        _gov(address(pt), abi.encodeCall(ParticipationToken.setTaskManager, (address(tm))));
        _gov(
            address(dd),
            abi.encodeCall(
                DirectDemocracyVoting.setConfig,
                (DirectDemocracyVoting.ConfigKey.TARGET_ALLOWED, abi.encode(address(tm), true))
            )
        );
        exec.setHatMinterAuthorization(address(qj), true);

        // 6. The org's subjects. Member is the default-ALLOW base role (also the QJ auto-join role).
        member = _createRole("Member", 0);
        _setSubjectDefault(member, true);
        _setPerm(member, AccessV2PermKeys.QJ_AUTOJOIN, bytes32(0), 1, false);
        // v1 parity: the base membership was itself a DD voting hat — every plain member may VOTE on
        // unrestricted polls (create/task perms stay exec-only via the group below).
        _setPerm(member, AccessV2PermKeys.DD_VOTE, bytes32(0), 1, false);

        // President / VP identity roles (capped) + the Executives group over them.
        presRole = _createRole("President", 5);
        vpRole = _createRole("VP", 5);
        uint256[] memory execRoles = new uint256[](2);
        execRoles[0] = presRole;
        execRoles[1] = vpRole;
        execGroup = _createGroup("Executives", execRoles);

        // Shared exec perm fan-out lives on the GROUP subject (v1's "marker wiring"): TM CREATE|BUDGET,
        // DD vote + create, HV create, PT member. isMember(group) derives from the member-roles.
        _setPerm(execGroup, AccessV2PermKeys.TM_PERMS, bytes32(0), TaskPerm.CREATE | TaskPerm.BUDGET, false);
        _setPerm(execGroup, AccessV2PermKeys.DD_VOTE, bytes32(0), 1, false);
        _setPerm(execGroup, AccessV2PermKeys.DD_CREATE, bytes32(0), 1, false);
        _setPerm(execGroup, AccessV2PermKeys.HV_CREATE, bytes32(0), 1, false);
        _setPerm(execGroup, AccessV2PermKeys.PT_MEMBER, bytes32(0), 1, false);
    }

    /*═══════════════════════════════ Scenario 1 ═══════════════════════════════*/
    /// Group + roles + shared perm fan-out; grant President to an in-org member ⇒ perms live on TM
    /// (task creation gated by CREATE), HV proposal creation, and DD voting.
    function testScenario1_GroupRoleGrantPermissionsLiveEverywhere() public {
        _join(member, alice); // alice in-org via the default-ALLOW base role

        // grant President to the in-org member is an ORG act (RoleGranted + mint), not an offer. Full
        // data-check pins the actor/delegated shape: actor == the Executor, delegated == false.
        vm.expectEmit(true, true, true, true, address(auth));
        emit RoleGranted(presRole, alice, address(exec), false);
        _grant(presRole, alice, true);
        assertTrue(auth.isMember(presRole, alice), "alice seated as President");
        assertTrue(auth.isMember(execGroup, alice), "President =+> Executives group member (derived)");

        // Perms resolve on every module via the group subject.
        assertEq(
            auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, bytes32(0)), TaskPerm.CREATE | TaskPerm.BUDGET, "TM mask"
        );
        assertTrue(auth.hasPerm(alice, AccessV2PermKeys.HV_CREATE, bytes32(0)) != 0, "HV create perm");
        assertTrue(auth.hasPerm(alice, AccessV2PermKeys.DD_CREATE, bytes32(0)) != 0, "DD create perm");

        // TaskManager gate: governance creates a project (executor bypass), alice creates a task; a
        // plain member (bob) without CREATE cannot.
        bytes32 pid = _createProject();
        vm.prank(alice);
        tm.createTask(1e18, bytes("task"), bytes32("m"), pid, address(0), 0, false, 0, 0);

        _join(member, bob);
        vm.prank(bob);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1e18, bytes("nope"), bytes32("m"), pid, address(0), 0, false, 0, 0);

        // HybridVoting: alice (HV_CREATE) can open a proposal.
        vm.prank(alice);
        hv.createProposal(bytes("hv"), bytes32("d"), 60, 2, _noBatch(), _u());
        assertEq(hv.proposalsCount(), 1, "HV proposal created by exec");

        // DirectDemocracy: alice (exec) can create AND vote via the group + base-member DD_VOTE perm.
        vm.prank(alice);
        dd.createProposal(bytes("dd"), bytes32("d"), 60, 2, _noBatch(), _u());
        uint256 id = dd.proposalsCount() - 1;
        vm.prank(alice);
        dd.vote(id, _u8(0), _u8(100));

        vm.warp(block.timestamp + 61 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid, "DD poll valid: exec voter met quorum");
        assertEq(winner, 0, "option 0 wins");
    }

    /*═══════════════════════════════ Scenario 2 ═══════════════════════════════*/
    /// Out-of-org offer → RoleOffered → claim → member; the paymaster invariant: the router-served
    /// isEligible is TRUE pre-claim while balanceOf stays 0 (sponsors the claim tx).
    function testScenario2_OfferClaimAndPaymasterEligiblePreClaim() public {
        assertFalse(_inOrg(dave), "dave starts out-of-org");

        // Governance offer to an out-of-org user writes the explicit-ALLOW only (no mint). Full
        // data-check pins actor == the Executor, delegated == false.
        vm.expectEmit(true, true, true, true, address(auth));
        emit RoleOffered(presRole, dave, address(exec), false);
        _gov(address(auth), abi.encodeCall(MembershipAuthority.offer, (presRole, dave, true)));
        assertFalse(auth.isMember(presRole, dave), "offer, not member yet");
        assertEq(auth.balanceOf(dave, presRole), 0, "no mint on offer");

        // PAYMASTER-SHAPED INVARIANT (router self-routes the v2 id to the authority): isEligible true
        // pre-claim while balance is 0 — the sponsorship semantic for dave's onboarding tx.
        assertEq(AccessV2Ids.embeddedAuthority(presRole), address(auth), "President is a self-routing v2 id");
        assertTrue(router.isEligible(dave, presRole), "router: isEligible true pre-claim");
        assertEq(router.balanceOf(dave, presRole), 0, "router: balance still 0 pre-claim");
        assertFalse(router.isWearerOfHat(dave, presRole), "router: not wearing pre-claim");

        // dave claims the offer ⇒ RoleClaimed (USER act) + mint.
        vm.expectEmit(true, true, false, false, address(auth));
        emit RoleClaimed(presRole, dave);
        vm.prank(dave);
        auth.claim(presRole);
        assertTrue(auth.isMember(presRole, dave), "dave now a member");
        assertTrue(_inOrg(dave), "dave now in-org");
        assertEq(router.balanceOf(dave, presRole), 1, "router: balance 1 post-claim");
        assertTrue(router.isWearerOfHat(dave, presRole), "router: wearing post-claim");
    }

    /*═══════════════════════════════ Scenario 3 ═══════════════════════════════*/
    /// Exec-only restricted DD poll addressed by the GROUP subject id; a plain member is rejected.
    function testScenario3a_DDRestrictedPollByGroupSubject() public {
        _makeExec(alice, presRole);
        _join(member, bob); // in-org, but NOT an exec

        uint256[] memory pollSubjects = _u1(execGroup); // "Only Executives"
        vm.prank(alice);
        dd.createProposalV2(bytes("execs"), bytes32("d"), 60, 2, _noBatch(), pollSubjects, DD_QUORUM);
        uint256 id = dd.proposalsCount() - 1;

        // Non-exec in-org member cannot vote on the restricted poll.
        vm.prank(bob);
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(id, _u8(0), _u8(100));

        // The exec voter passes the group-subject gate.
        vm.prank(alice);
        dd.vote(id, _u8(0), _u8(100));
        vm.warp(block.timestamp + 61 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid, "restricted poll valid with the exec voter");
        assertEq(winner, 0);
    }

    /// HV class references the group subject via setClassSubject; W2 snapshot-only semantics: a
    /// post-creation setClassSubject cannot move an in-flight electorate.
    function testScenario3b_HVClassGroupSubjectSnapshotOnly() public {
        _makeExec(alice, presRole);
        _join(member, bob);

        // Bind class 0 to the Executives group (allocates stable classId 1).
        _gov(address(hv), abi.encodeCall(HybridVoting.setClassSubject, (0, execGroup)));
        assertEq(hv.classIdOfIndex(0), 1, "stable classId allocated on first setClassSubject");
        assertEq(hv.classSubjectOf(1), execGroup, "classId 1 -> Executives group");

        // Proposal P1 snapshots the group binding at creation.
        vm.prank(alice);
        hv.createProposal(bytes("p1"), bytes32("d"), 60, 2, _noBatch(), _u());
        uint256 p1 = hv.proposalsCount() - 1;
        assertEq(hv.proposalClassSubject(p1, 0), execGroup, "P1 class-0 snapshot = Executives group");

        // Exec (group member) has class power; a non-exec in-org member has none (Sybil-rejected).
        vm.prank(alice);
        hv.vote(p1, _u8(0), _u8(100));
        vm.prank(bob);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.vote(p1, _u8(0), _u8(100));

        // W2: rebind class 0 to a DIFFERENT group AFTER P1's creation. P1 keeps its snapshot; only a
        // NEW proposal P2 sees the new binding.
        uint256 vpOnly = _createRole("Directors", 5);
        uint256 group2 = _createGroup("Directors", _u1(vpOnly));
        _gov(address(hv), abi.encodeCall(HybridVoting.setClassSubject, (0, group2)));
        assertEq(hv.proposalClassSubject(p1, 0), execGroup, "W2: P1 snapshot immutable after rebind");
        assertEq(hv.classSubjectOf(1), group2, "live classSubject moved to Directors");

        vm.prank(alice);
        hv.createProposal(bytes("p2"), bytes32("d"), 60, 2, _noBatch(), _u());
        uint256 p2 = hv.proposalsCount() - 1;
        assertEq(hv.proposalClassSubject(p2, 0), group2, "P2 snapshots the NEW binding");
    }

    /*═══════════════════════════════ Scenario 4 ═══════════════════════════════*/
    /// Election as one atomic batch through the REAL Executor.execute: soft-remove the loser + grant
    /// the winner. Seat frees (memberCount), winner votes, loser cannot; activation gate: a winner
    /// granted mid-proposal cannot vote on THAT proposal but votes on the next.
    function testScenario4_ElectionBatchThroughRealExecutorAndActivationGate() public {
        _makeExec(alice, presRole); // incumbent President
        _join(member, ianthe); // challenger is in-org (so grant seats, not offers)
        assertEq(auth.memberCount(presRole), 1, "one seat filled");

        // An exec-restricted DD poll is open BEFORE the election — the activation anchor for the gate.
        // Membership eligibility rides on Executives-group activation, so a mid-proposal seat change
        // cannot enfranchise the newcomer on THIS poll.
        vm.prank(alice);
        dd.createProposalV2(bytes("term"), bytes32("d"), 120, 2, _noBatch(), _u1(execGroup), DD_QUORUM);
        uint256 openId = dd.proposalsCount() - 1;

        vm.warp(block.timestamp + 1); // election happens strictly after openId's creation

        // Election batch through the real Executor (this test is the sole allowedCaller / governor).
        IExecutor.Call[] memory batch = new IExecutor.Call[](2);
        batch[0] = IExecutor.Call({
            target: address(auth), value: 0, data: abi.encodeCall(MembershipAuthority.remove, (presRole, alice, false))
        });
        batch[1] = IExecutor.Call({
            target: address(auth), value: 0, data: abi.encodeCall(MembershipAuthority.grant, (presRole, ianthe, true))
        });
        assertLt(batch.length, exec.MAX_CALLS_PER_BATCH(), "batch under the cap");
        exec.execute(uint256(1), batch);

        // Winner seated, loser out, seat count unchanged at one.
        assertTrue(auth.isMember(presRole, ianthe), "winner seated");
        assertFalse(auth.isMember(presRole, alice), "loser removed");
        assertEq(auth.memberCount(presRole), 1, "seat freed then refilled");

        // ACTIVATION GATE: ianthe's Executives activation is AFTER openId's creation ⇒ she cannot vote
        // on openId (the restricted-poll electorate is frozen at creation).
        vm.prank(ianthe);
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(openId, _u8(0), _u8(100));
        // The deposed alice also cannot vote (no longer an exec).
        vm.prank(alice);
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(openId, _u8(1), _u8(100));

        // ...but ianthe votes on the NEXT exec poll (created after her activation).
        vm.prank(ianthe);
        dd.createProposalV2(bytes("next"), bytes32("d"), 60, 2, _noBatch(), _u1(execGroup), DD_QUORUM);
        uint256 nextId = dd.proposalsCount() - 1;
        vm.prank(ianthe);
        dd.vote(nextId, _u8(0), _u8(100));
        vm.warp(block.timestamp + 61 minutes);
        (, bool valid) = dd.announceWinner(nextId);
        assertTrue(valid, "winner votes on the proposal created after her activation");
    }

    /*═══════════════════════════════ Scenario 5 ═══════════════════════════════*/
    /// Delegated management: Executives manage the Member role (CAP_GRANT|CAP_REMOVE, delay>0). A
    /// delegated grant pends then finalizes; a delegated remove is voided by a governance write; a
    /// pending dies when the manager loses their seat.
    function testScenario5_DelegatedManagementLifecycle() public {
        _makeExec(bob, presRole); // bob is an exec ⇒ a Member-role manager
        // Executives manage a fresh delegated role.
        uint256 crew = _createRole("Crew", 0);
        _gov(
            address(auth),
            abi.encodeCall(MembershipAuthority.setManagerConfig, (crew, execGroup, uint8(3), uint32(1 days)))
        );

        // ── delegated grant pends → finalize after delay → member ──
        _join(member, alice); // grant target must be in-org
        vm.expectEmit(false, true, true, false, address(auth));
        emit PendingActionCreated(1, crew, alice, uint8(AccessV2Types.PendingKind.Grant), bob, 0);
        vm.prank(bob);
        uint256 pid = auth.delegatedGrant(crew, alice);
        uint64 at = auth.getPending(pid).activatesAt;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMembershipAuthority.NotYetActive.selector, at));
        auth.finalize(pid);
        vm.warp(block.timestamp + 1 days + 1);
        // Finalize emits the RESULTING lifecycle verb with the DELEGATED shape: actor == the manager
        // (bob), delegated == true (distinct from the governance grant's actor==Executor/false).
        vm.expectEmit(true, true, true, true, address(auth));
        emit RoleGranted(crew, alice, bob, true);
        vm.prank(bob);
        auth.finalize(pid);
        assertTrue(auth.isMember(crew, alice), "delegated grant finalized after delay");

        // ── delegated remove pends → governance write voids it ──
        vm.prank(bob);
        uint256 removePid = auth.delegatedRemove(crew, alice, false);
        assertTrue(auth.getPending(removePid).exists, "remove pending created");
        // Governance writes the same (subject,user) → voids the pending.
        _gov(
            address(auth),
            abi.encodeCall(MembershipAuthority.setRule, (crew, alice, AccessV2Types.RuleKind.Grant, false))
        );
        assertFalse(auth.getPending(removePid).exists, "governance write voids the pending remove");
        assertTrue(auth.isMember(crew, alice), "alice retained by the governance grant");

        // ── a pending dies when the manager loses their seat ──
        _join(member, carol);
        vm.prank(bob);
        uint256 pid2 = auth.delegatedGrant(crew, carol);
        // bob loses his exec seat (hard remove President) ⇒ no longer a manager-subject member.
        _gov(address(auth), abi.encodeCall(MembershipAuthority.remove, (presRole, bob, true)));
        assertFalse(auth.isMember(execGroup, bob), "bob no longer an exec");
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        vm.expectRevert(IMembershipAuthority.NotAuthorizedManager.selector);
        auth.finalize(pid2); // pending cannot be finalized by an ex-manager
        assertFalse(auth.isMember(crew, carol), "pending died with the manager's seat");
    }

    /*═══════════════════════════════ Scenario 6 ═══════════════════════════════*/
    /// Kick semantics: a hard remove writes the ban; a re-vouch cannot bypass it (supremacy);
    /// governance overwrites the ban; a sticky (delegable=false) governance grant survives a delegate
    /// remove (RemoveBlockedByStickyGovernance) and its renounce leaves the seat claimable.
    function testScenario6_KickBanSupremacyAndStickySurvival() public {
        // Vouch-eligible role so a re-vouch is a real bypass attempt.
        uint256 voucher = _createRole("Voucher", 0);
        _setSubjectDefault(voucher, true);
        uint256 guild = _createRole("Guild", 0);
        _gov(address(auth), abi.encodeCall(MembershipAuthority.configureVouchAttestor, (guild, uint32(1), voucher)));

        _join(voucher, bob); // bob can vouch
        vm.prank(bob);
        auth.vouch(guild, alice);
        vm.prank(alice);
        auth.claim(guild);
        assertTrue(auth.isMember(guild, alice), "alice joined via vouch");

        // Hard remove writes the governance ban.
        _gov(address(auth), abi.encodeCall(MembershipAuthority.remove, (guild, alice, true)));
        assertFalse(auth.isMember(guild, alice), "alice banned");
        assertFalse(auth.eligible(guild, alice), "ban -> ineligible");

        // Re-vouch cannot bypass the ban (supremacy): a FRESH voucher piles on more quorum (bob's
        // original vouch persists through the ban), yet the explicit ban still dominates the fold.
        _join(voucher, carol);
        vm.prank(carol);
        auth.vouch(guild, alice);
        assertFalse(auth.eligible(guild, alice), "ban supremacy over re-vouch");
        vm.prank(alice);
        vm.expectRevert(IMembershipAuthority.NotClaimable.selector);
        auth.claim(guild);

        // Governance overwrites the ban (unremove) ⇒ claimable again via the live vouch.
        _gov(address(auth), abi.encodeCall(MembershipAuthority.unremove, (guild, alice)));
        assertTrue(auth.eligible(guild, alice), "governance cleared the ban");
        vm.prank(alice);
        auth.claim(guild);
        assertTrue(auth.isMember(guild, alice), "re-joined after governance overwrite");

        // Sticky governance grant survives a delegate remove.
        uint256 seat = _createRole("Seat", 0);
        _gov(
            address(auth), abi.encodeCall(MembershipAuthority.setManagerConfig, (seat, execGroup, uint8(3), uint32(0)))
        );
        _makeExec(carol, vpRole); // carol is a manager (exec)
        _join(member, alice); // ensure in-org for the sticky grant
        _gov(address(auth), abi.encodeCall(MembershipAuthority.grant, (seat, alice, false))); // sticky (delegable=false)
        assertTrue(auth.isMember(seat, alice), "alice holds the sticky seat");
        vm.prank(carol);
        vm.expectRevert(IMembershipAuthority.RemoveBlockedByStickyGovernance.selector);
        auth.delegatedRemove(seat, alice, false);

        // Renounce leaves the sticky seat reserved & re-claimable.
        vm.prank(alice);
        auth.renounce(seat);
        assertFalse(auth.isMember(seat, alice), "renounced");
        (AccessV2Types.ActionReason reason,,) = auth.canClaim(seat, alice);
        assertEq(
            uint8(reason), uint8(AccessV2Types.ActionReason.RenouncedClaimable), "sticky seat reserved after renounce"
        );
        vm.prank(alice);
        auth.claim(seat);
        assertTrue(auth.isMember(seat, alice), "re-claimed the reserved sticky seat");
    }

    /*═══════════════════════════════ Scenario 7 ═══════════════════════════════*/
    /// Adoption-shaped seed on a SECOND authority with legacy (>=2^224) adopted ids; seed while paused;
    /// bind on the real OrgRegistry via the router; unpause; verify the paymaster read chain
    /// (router.isEligible for an adopted id) end-to-end.
    function testScenario7_AdoptionSeedRouterBindPaymasterReadChain() public {
        uint256 DOMAIN2 = 0xCAFE;
        bytes32 ORG2 = keccak256("Adopted.org");
        // The second org's Executor is THIS test contract (so it can seed + bind directly).
        orgReg.registerOrg(ORG2, address(this), bytes("Adopted"), bytes32(0));
        orgReg.registerHatsTree(ORG2, DOMAIN2 << 224, new uint256[](0));

        MembershipAuthority auth2 = MembershipAuthority(
            _proxy(
                address(new MembershipAuthority()),
                abi.encodeCall(
                    MembershipAuthority.initialize,
                    (IMembershipAuthority.InitConfig({
                            executor: address(this), paymasterHub: hub, orgId: ORG2, seed: _emptySeed()
                        }))
                )
            )
        );
        assertTrue(auth2.paused(), "second authority born paused");

        // Adopted legacy-shaped ids (>= 2^224) in DOMAIN2.
        uint256 adoptedRole = (DOMAIN2 << 224) | 1;
        uint256 adoptedVoucher = (DOMAIN2 << 224) | 2;
        uint256 vouchedRole = (DOMAIN2 << 224) | 3;
        assertTrue(AccessV2Ids.isLegacyNamespace(adoptedRole), "adopted id in the legacy namespace");

        // Seed subjects/rules/memberships/vouches WHILE PAUSED (executor writes are pause-exempt).
        {
            uint256[] memory ids = new uint256[](3);
            ids[0] = adoptedRole;
            ids[1] = adoptedVoucher;
            ids[2] = vouchedRole;
            AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](3); // all Role (0)
            string[] memory names = new string[](3);
            names[0] = "AdoptedExec";
            names[1] = "AdoptedVoucher";
            names[2] = "AdoptedVouched";
            uint32[] memory mm = new uint32[](3);
            auth2.seedSubjects(ids, kinds, names, mm);
        }
        // frank: seeded rule (Grant) + seeded membership on adoptedRole.
        {
            uint256[] memory subs = _u1(adoptedRole);
            address[] memory users = _a1(makeAddr("frank"));
            AccessV2Types.RuleKind[] memory rk = new AccessV2Types.RuleKind[](1);
            rk[0] = AccessV2Types.RuleKind.Grant;
            bool[] memory dg = new bool[](1);
            dg[0] = true;
            auth2.seedRules(subs, users, rk, dg);
            auth2.seedMemberships(subs, users);
        }
        // grace: a seeded per-voucher RECORD (records-first, C2) meeting a quorum-1 attestor on
        // vouchedRole — one real voucher who is a member of the voucher subject.
        address grace = makeAddr("grace");
        address graceVoucher = makeAddr("graceVoucher");
        auth2.setSubjectDefault(adoptedVoucher, true, false);
        auth2.configureVouchAttestor(vouchedRole, 1, adoptedVoucher);
        auth2.seedVouchers(vouchedRole, grace, _a1(graceVoucher));

        // Bind the adopted domain to auth2 (Executor-through-OrgRegistry gate; this == ORG2's Executor).
        router.bindAuthority(ORG2, DOMAIN2, address(auth2));
        assertEq(router.authorityOf(adoptedRole), address(auth2), "domain bound to the adopted authority");

        // Unpause ⇒ the org functions.
        auth2.setPaused(false);

        // PAYMASTER READ CHAIN (router.isEligible for an adopted id) end-to-end.
        address frank = makeAddr("frank");
        assertTrue(router.isEligible(frank, adoptedRole), "router: seeded member eligible");
        assertTrue(router.isWearerOfHat(frank, adoptedRole), "router: seeded member wearing");
        assertEq(router.balanceOf(frank, adoptedRole), 1, "router: seeded member balance 1");
        // Seeded vouches ⇒ eligible (attestor-ALLOW) even without an accepted membership.
        assertTrue(router.isEligible(grace, vouchedRole), "router: seeded-vouch eligible");
        assertFalse(router.isWearerOfHat(grace, vouchedRole), "router: vouch-eligible != wearing (not accepted)");
        // A never-seeded user resolves to safe zeros through the same bound authority.
        assertFalse(router.isEligible(outsider, adoptedRole), "router: unseeded user ineligible");
    }

    /*═══════════════════════════════ Scenario 8 ═══════════════════════════════*/
    /// QuickJoin on v2 rails: a QJ_AUTOJOIN default-ALLOW role ⇒ join mints through the UNCHANGED
    /// Executor.mintHatsForUser loop (whose repointed l.hats.mintHat resolves against the authority).
    function testScenario8_QuickJoinThroughUnchangedExecutorLoop() public {
        accountReg.setUsername(carol, "carol");

        // The auto-join set is enumerated off the QJ_AUTOJOIN key ⇒ the Member base role.
        uint256[] memory expected = _u1(member);
        vm.expectEmit(true, false, false, true, address(qj));
        emit QuickJoined(carol, expected);
        vm.prank(carol);
        qj.quickJoinWithUser();

        assertTrue(auth.isMember(member, carol), "QuickJoin minted the QJ_AUTOJOIN membership via the Executor loop");
        assertEq(auth.balanceOf(carol, member), 1, "membership token minted");

        // No username ⇒ the unchanged QuickJoin guard still reverts.
        vm.prank(outsider);
        vm.expectRevert(QuickJoin.NoUsername.selector);
        qj.quickJoinWithUser();
    }

    /*═══════════════════════════════ Event-feed truthfulness ═══════════════════════════════*/
    /// The remaining disjoint lifecycle verbs render with the correct actor/delegated/banned shapes:
    /// OfferWithdrawn (governance), RoleRemoved (governance hard ban), RoleRenounced (user), and the
    /// attestor-lapse repair MembershipReconciled (permissionless).
    function testScenario9_EventFeedRemainingLifecycleVerbs() public {
        // OfferWithdrawn — governance offers, then withdraws (actor == the Executor).
        _gov(address(auth), abi.encodeCall(MembershipAuthority.offer, (presRole, dave, true)));
        vm.expectEmit(true, true, true, true, address(auth));
        emit OfferWithdrawn(presRole, dave, address(exec));
        _gov(address(auth), abi.encodeCall(MembershipAuthority.withdrawOffer, (presRole, dave)));

        // RoleRemoved — governance hard ban: banned == true, actor == Executor, delegated == false.
        _makeExec(alice, presRole);
        vm.expectEmit(true, true, true, true, address(auth));
        emit RoleRemoved(presRole, alice, true, address(exec), false);
        _gov(address(auth), abi.encodeCall(MembershipAuthority.remove, (presRole, alice, true)));

        // RoleRenounced — the USER resigns the default-ALLOW base role.
        _join(member, bob);
        vm.expectEmit(true, true, false, false, address(auth));
        emit RoleRenounced(member, bob);
        vm.prank(bob);
        auth.renounce(member);

        // MembershipReconciled — a vouch-based membership lapses (epoch amnesty) then is repaired
        // permissionlessly (config-level lapse ⇒ burn + MembershipReconciled, no revert).
        uint256 voucher = _createRole("Voucher2", 0);
        _setSubjectDefault(voucher, true);
        uint256 guild = _createRole("Guild2", 0);
        _gov(address(auth), abi.encodeCall(MembershipAuthority.configureVouchAttestor, (guild, uint32(1), voucher)));
        _join(voucher, carol);
        vm.prank(carol);
        auth.vouch(guild, ianthe);
        vm.prank(ianthe);
        auth.claim(guild);
        assertTrue(auth.isMember(guild, ianthe), "ianthe joined via vouch");
        _gov(address(auth), abi.encodeCall(MembershipAuthority.resetVouchEpoch, (guild))); // amnesty ⇒ lapse
        assertFalse(auth.eligible(guild, ianthe), "no longer eligible after epoch reset");
        vm.expectEmit(true, true, false, false, address(auth));
        emit MembershipReconciled(guild, ianthe);
        auth.reconcile(guild, ianthe);
        assertFalse(auth.isMember(guild, ianthe), "reconciled out");
    }

    /*═════════════════════════════ Helpers ═════════════════════════════*/

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    /// @dev Governance relay — perform `data` on `target` AS the Executor (owner-gated bootstrap path).
    function _gov(address target, bytes memory data) internal returns (bytes memory) {
        return exec.configureModule(target, data);
    }

    function _createRole(string memory name, uint32 maxMembers) internal returns (uint256) {
        return abi.decode(
            _gov(address(auth), abi.encodeCall(MembershipAuthority.createRole, (name, bytes32(0), "", maxMembers))),
            (uint256)
        );
    }

    function _createGroup(string memory name, uint256[] memory roleIds) internal returns (uint256) {
        return abi.decode(
            _gov(address(auth), abi.encodeCall(MembershipAuthority.createGroup, (name, bytes32(0), "", roleIds))),
            (uint256)
        );
    }

    function _setSubjectDefault(uint256 subject, bool allow) internal {
        _gov(address(auth), abi.encodeCall(MembershipAuthority.setSubjectDefault, (subject, allow, false)));
    }

    function _setPerm(uint256 subject, bytes32 key, bytes32 ctx, uint256 value, bool inherit) internal {
        uint256 w = value | AccessV2PermKeys.EXISTS_BIT;
        if (inherit) w |= AccessV2PermKeys.INHERIT_GLOBAL_BIT;
        _gov(address(auth), abi.encodeCall(MembershipAuthority.setPerm, (subject, key, ctx, w)));
    }

    function _grant(uint256 subject, address user, bool delegable) internal {
        _gov(address(auth), abi.encodeCall(MembershipAuthority.grant, (subject, user, delegable)));
    }

    function _join(uint256 role, address user) internal {
        vm.prank(user);
        auth.claim(role);
    }

    /// @dev Make `user` an Executive: join the base Member role, then seat the given identity role.
    function _makeExec(address user, uint256 role) internal {
        _join(member, user);
        _grant(role, user, true);
        assertTrue(auth.isMember(execGroup, user), "exec setup failed");
    }

    function _inOrg(address user) internal view returns (bool) {
        return auth.userSubjects(user).length > 0;
    }

    function _createProject() internal returns (bytes32 pid) {
        bytes memory ret = _gov(
            address(tm),
            abi.encodeCall(
                TaskManager.createProject,
                (TaskManager.BootstrapProjectConfig({
                        title: bytes("Project X"),
                        metadataHash: bytes32("p"),
                        cap: 0,
                        managers: _a(),
                        createHats: _u(),
                        claimHats: _u(),
                        reviewHats: _u(),
                        assignHats: _u(),
                        bountyTokens: _a(),
                        bountyCaps: _u()
                    }))
            )
        );
        pid = abi.decode(ret, (bytes32));
    }

    function _emptySeed() internal pure returns (AccessV2Types.OrgAccessSeed memory s) {
        s.subjectIds = new uint256[](0);
        s.subjectKinds = new AccessV2Types.SubjectKind[](0);
        s.subjectNames = new string[](0);
        s.subjectMaxMembers = new uint32[](0);
        s.subjectDefaults = new bool[](0);
        s.groupMemberRoles = new uint256[][](0);
        s.vouchSubjects = new uint256[](0);
        s.vouchQuorums = new uint32[](0);
        s.vouchVoucherSubjects = new uint256[](0);
        s.permSubjects = new uint256[](0);
        s.permKeys = new bytes32[](0);
        s.permCtxs = new bytes32[](0);
        s.permWords = new uint256[](0);
    }

    /*──────── tiny array builders ────────*/
    function _u() internal pure returns (uint256[] memory a) {
        a = new uint256[](0);
    }

    function _u1(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _a() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _a1(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _u8(uint8 x) internal pure returns (uint8[] memory a) {
        a = new uint8[](1);
        a[0] = x;
    }

    function _u8_32(uint32 x) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = x;
    }

    function _noBatch() internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](0);
    }
}
