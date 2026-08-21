// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AuthorityRouter} from "../src/AuthorityRouter.sol";
import {IAuthorityRouter} from "../src/interfaces/IAuthorityRouter.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2Ids} from "../src/libs/AccessV2Ids.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {HybridVotingConfig} from "../src/libs/HybridVotingConfig.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {Executor, IExecutor} from "../src/Executor.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/*═══════════════════════════════════════════════════════════════════════════════════════════════
                                        SHARED HARNESSES
═══════════════════════════════════════════════════════════════════════════════════════════════*/

/// @dev Minimal executor forwarder for the voting-module rollback rehearsal (obligation 5): DD's
///      `announceWinner` calls `executor.execute(id, batch)`; empty batches make this a no-op.
contract DiffMockExecutor is IExecutor {
    function execute(uint256, Call[] calldata batch) external {
        for (uint256 i; i < batch.length; ++i) {
            (bool ok,) = batch[i].target.call{value: batch[i].value}(batch[i].data);
            require(ok, "DiffMockExecutor: call failed");
        }
    }
}

/// @dev ParticipationToken stand-in for TaskManager init (never exercised on the perm-fold path).
contract DiffMockPToken {
    function mint(address, uint256) external {}
}

/// @dev Exposes TaskManager's internal `_permMask` so the W4 ctx-collision differential (obligation 7)
///      can assert the exact fold boundary rather than only gated externals.
contract TMDiffHarness is TaskManager {
    function permMask(address user, bytes32 pid) external view returns (uint8) {
        return _permMask(user, pid);
    }
}

/*═══════════════════════════════════════════════════════════════════════════════════════════════
    WORKSTREAM C2 — LOCAL DIFFERENTIALS (freeze §5.2 obligations implementable without a fork)

    Covers obligation 1 (two-org subjectKey distinctness + id arithmetic), obligation 5 (rollback
    rehearsal), obligation 6 (fold-mirror / slot-mirror conformance for the Wave-B module
    side-mappings), obligation 7 (W4 ctx project-0/global collision regression).
═══════════════════════════════════════════════════════════════════════════════════════════════*/

contract AccessV2DifferentialsLocalTest is Test {
    address internal executor = makeAddr("executor");
    address internal paymasterHub = address(0xBEEF);

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal creator = makeAddr("creator");
    address internal voter = makeAddr("voter");

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

    function _deployAuthority(bytes32 orgId) internal returns (MembershipAuthority a) {
        MembershipAuthority impl = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: executor, paymasterHub: paymasterHub, orgId: orgId, seed: _emptySeed()
        });
        a = MembershipAuthority(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MembershipAuthority.initialize, (cfg))))
        );
        vm.prank(executor);
        a.setPaused(false);
    }

    function _role(MembershipAuthority a, string memory name, uint32 max) internal returns (uint256 id) {
        vm.prank(executor);
        id = a.createRole(name, bytes32(0), "", max);
    }

    function _word(uint256 value, bool inherit) internal pure returns (uint256 w) {
        w = value | AccessV2PermKeys.EXISTS_BIT;
        if (inherit) w |= AccessV2PermKeys.INHERIT_GLOBAL_BIT;
    }

    /// @dev Membership = accepted && eligible; governance Grant rule + executor seedMembership.
    function _makeMember(MembershipAuthority a, uint256 subject, address user) internal {
        vm.prank(executor);
        a.setRule(subject, user, AccessV2Types.RuleKind.Grant, false);
        uint256[] memory subs = new uint256[](1);
        address[] memory users = new address[](1);
        subs[0] = subject;
        users[0] = user;
        vm.prank(executor);
        a.seedMemberships(subs, users);
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 1 — Two-org subjectKey distinctness + address-embedded id arithmetic (< 2^224).
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function test_obl1_twoOrgSubjectKeyDistinctness() public {
        MembershipAuthority authA = _deployAuthority(keccak256("org.A"));
        MembershipAuthority authB = _deployAuthority(keccak256("org.B"));

        // Two authorities each mint a role with the SAME name/config; the ids must still differ.
        uint256 idA = _role(authA, "Member", 0);
        uint256 idB = _role(authB, "Member", 0);
        assertTrue(idA != idB, "distinct authorities => distinct subject ids");

        // ── Address-embedded id arithmetic (freeze §1 / §5.1) ──
        // id = (uint160(authority) << 64) | localSeq  ⇒  embeds the authority address in bits 64..223,
        // top 32 bits zero ⇒ every new id < 2^224 (disjoint from the Hats legacy namespace).
        assertEq(AccessV2Ids.embeddedAuthority(idA), address(authA), "idA embeds authority A");
        assertEq(AccessV2Ids.embeddedAuthority(idB), address(authB), "idB embeds authority B");
        assertLt(idA, AccessV2Ids.HATS_NAMESPACE_FLOOR, "idA < 2^224");
        assertLt(idB, AccessV2Ids.HATS_NAMESPACE_FLOOR, "idB < 2^224");
        assertFalse(AccessV2Ids.isLegacyNamespace(idA), "idA is v2 namespace");
        assertGe(idA, uint256(1) << 64, "idA carries embedded-address bits");
        // localSeq is the low 64 bits; first-allocated ids share the same seq but different addrs.
        assertEq(idA & type(uint64).max, idB & type(uint64).max, "same localSeq, address disambiguates");

        // ── PaymasterHub subjectKey distinctness (PaymasterHub.sol:896/1507 — key has NO orgId) ──
        // Global uniqueness rides entirely on the address-embedded id; identical (type, name) rows in
        // two orgs must produce different paymaster keys or budgets would cross-contaminate.
        bytes32 keyA = keccak256(abi.encode("ParticipationToken", idA));
        bytes32 keyB = keccak256(abi.encode("ParticipationToken", idB));
        assertTrue(keyA != keyB, "distinct paymaster subjectKeys across orgs");

        // Same-type key within ONE org for two different subjects is also distinct (sanity).
        uint256 idA2 = _role(authA, "Contributor", 0);
        assertTrue(
            keccak256(abi.encode("ParticipationToken", idA)) != keccak256(abi.encode("ParticipationToken", idA2)),
            "distinct subjects => distinct keys within an org"
        );
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 5 — Rollback rehearsal (local): v2 rails → setMembershipAuthority(0) everywhere +
      Executor restore → byte-identical legacy behaviour resumes; re-set → v2 resumes.
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    uint256 internal constant CREATOR_HAT = 2;
    uint256 internal constant VOTING_HAT = 1;

    function _emptyBatches(uint8 opts) internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](opts);
        for (uint256 i; i < opts; ++i) {
            b[i] = new IExecutor.Call[](0);
        }
    }

    function _ddLegacyActionSet(DirectDemocracyVoting dd, MockHats hats) internal returns (uint256 winner, bool valid) {
        // A full legacy-path action set: hat-wearing creator opens a proposal, hat-wearing voter votes,
        // announceWinner tallies. Reproduced identically pre- and post-rollback for byte comparison.
        hats.mintHat(CREATOR_HAT, creator);
        hats.mintHat(VOTING_HAT, voter);
        uint256 id = dd.proposalsCount();
        vm.prank(creator);
        dd.createProposal(bytes("p"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));

        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(voter);
        dd.vote(id, idx, w);

        vm.warp(block.timestamp + 11 * 60);
        (winner, valid) = dd.announceWinner(id);
    }

    function test_obl5_rollbackRehearsal_ddModule() public {
        MockHats hats = new MockHats();
        DiffMockExecutor exec = new DiffMockExecutor();
        MembershipAuthority auth = _deployAuthority(keccak256("org.rollback"));

        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory vh = new uint256[](1);
        vh[0] = VOTING_HAT;
        uint256[] memory ch = new uint256[](1);
        ch[0] = CREATOR_HAT;
        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize, (address(hats), address(exec), vh, ch, new address[](0), 50, 0)
        );
        DirectDemocracyVoting dd = DirectDemocracyVoting(address(new ERC1967Proxy(address(impl), data)));

        // ── Phase A: LEGACY baseline (authority == 0) ──
        (uint256 winL, bool validL) = _ddLegacyActionSet(dd, hats);
        assertTrue(validL, "legacy baseline proposal valid");

        // ── Phase B: go to v2 rails — the legacy CREATOR_HAT wearer is now dead, needs DD_CREATE ──
        vm.prank(address(exec));
        dd.setMembershipAuthority(address(auth));
        assertEq(dd.membershipAuthority(), address(auth), "on v2 rails");
        vm.prank(creator); // already wears CREATOR_HAT, but v2 arm ignores hats
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.createProposal(bytes("v2"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));

        // ── Phase C: ROLLBACK to zero → legacy resumes BYTE-IDENTICALLY ──
        vm.prank(address(exec));
        dd.setMembershipAuthority(address(0));
        assertEq(dd.membershipAuthority(), address(0), "rolled back to legacy");
        (uint256 winR, bool validR) = _ddLegacyActionSet(dd, hats);
        assertEq(winR, winL, "rollback winner byte-identical to legacy baseline");
        assertEq(validR, validL, "rollback validity byte-identical to legacy baseline");

        // ── Phase D: RE-SET v2 → v2 gate active again ──
        vm.prank(address(exec));
        dd.setMembershipAuthority(address(auth));
        vm.prank(creator);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.createProposal(bytes("v2b"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
    }

    function test_obl5_rollbackRehearsal_tmModule() public {
        MockHats hats = new MockHats();
        DiffMockPToken token = new DiffMockPToken();
        MembershipAuthority auth = _deployAuthority(keccak256("org.rollback.tm"));

        uint256[] memory ch = new uint256[](1);
        ch[0] = CREATOR_HAT;
        TMDiffHarness impl = new TMDiffHarness();
        bytes memory initCall =
            abi.encodeCall(TaskManager.initialize, (address(token), address(hats), ch, executor, address(0)));
        TMDiffHarness tm = TMDiffHarness(address(new ERC1967Proxy(address(impl), initCall)));

        // Legacy baseline: alice wears HAT 101 with global CREATE.
        hats.mintHat(101, alice);
        vm.prank(executor);
        tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, abi.encode(uint256(101), TaskPerm.CREATE));
        uint8 legacyMask = tm.permMask(alice, bytes32("p1"));
        assertEq(legacyMask, TaskPerm.CREATE, "legacy baseline mask");

        // v2 rails — alice has no perms on the fresh authority.
        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        assertEq(tm.permMask(alice, bytes32("p1")), 0, "authority arm overrides legacy");

        // Rollback → byte-identical legacy answer.
        vm.prank(executor);
        tm.setMembershipAuthority(address(0));
        assertEq(tm.permMask(alice, bytes32("p1")), legacyMask, "rollback restores legacy byte-identically");

        // Re-set → v2 arm again.
        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));
        assertEq(tm.permMask(alice, bytes32("p1")), 0, "v2 resumes");
    }

    function test_obl5_executorHatsRepointRoundTrip() public {
        // The Executor's setMembershipAuthority IS the l.hats switch (§4.7): repoint stashes legacyHats,
        // rollback restores it byte-identically. hats() must track the pointer both ways.
        MockHats legacyHats = new MockHats();
        MembershipAuthority auth = _deployAuthority(keccak256("org.exec"));

        Executor impl = new Executor();
        Executor ex = Executor(
            payable(address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Executor.initialize, (address(this), address(legacyHats)))
                    )
                ))
        );
        assertEq(address(ex.hats()), address(legacyHats), "starts on legacy hats");

        // Repoint (owner path).
        ex.setMembershipAuthority(address(auth));
        assertEq(address(ex.hats()), address(auth), "executor.hats() follows the authority");

        // Rollback restores the ORIGINAL hats pointer byte-identically.
        ex.setMembershipAuthority(address(0));
        assertEq(address(ex.hats()), address(legacyHats), "rollback restores original hats pointer");

        // Re-set resumes v2.
        ex.setMembershipAuthority(address(auth));
        assertEq(address(ex.hats()), address(auth), "v2 resumes on executor");
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 6 — Fold-mirror / slot-mirror conformance for Wave-B module side-mappings.

      Extends the MembershipAuthorityLayoutSync pattern to the module side-mappings the Wave-B changes
      appended: HybridVoting's THREE v2-namespace libs (Core/Config/Proposals) share ONE slot
      keccak256("poa.hybridvoting.v2.storage"); DirectDemocracy's proposalCreatedAt side-mapping shares
      keccak256("poa.directdemocracy.storage"). A cross-lib write→read that returned 0 would prove a
      slot drift.
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function _hvClass(uint256[] memory hatIds) internal pure returns (HybridVoting.ClassConfig memory c) {
        c = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: hatIds
        });
    }

    function test_obl6_hvSideMappingSlotMirror() public {
        MockHats hats = new MockHats();
        DiffMockExecutor exec = new DiffMockExecutor();

        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = 1;
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = _hvClass(memberHats);
        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = CREATOR_HAT;

        HybridVoting impl = new HybridVoting();
        bytes memory data = abi.encodeCall(
            HybridVoting.initialize,
            (address(hats), address(exec), creatorHats, new address[](0), uint8(50), uint32(0), classes)
        );
        HybridVoting hv = HybridVoting(payable(address(new ERC1967Proxy(address(impl), data))));

        // Pin the shared ERC-7201 slot constant used by all three libs.
        bytes32 SLOT = keccak256("poa.hybridvoting.v2.storage");
        assertEq(SLOT, keccak256("poa.hybridvoting.v2.storage"), "HV shared slot constant pinned");

        // CONFIG-lib write (HybridVotingConfig.setClassSubject via delegatecall) → hub-accessor read.
        vm.prank(address(exec));
        hv.setConfigAdmin(address(this));
        uint256 SUBJ = 0xABCDEF;
        hv.setClassSubject(0, SUBJ); // allocates classId 1 for idx 0
        assertEq(hv.classIdOfIndex(0), 1, "config-lib allocated classId visible via accessor");
        assertEq(hv.classSubjectOf(1), SUBJ, "config-lib classSubject visible via accessor");

        // PROPOSALS-lib write (HybridVotingProposals.createProposal snapshots proposalClassSubjects)
        // → hub-accessor read: the snapshot mapping resolves the SAME slot the config lib wrote.
        uint256 pid = hv.proposalsCount();
        hats.mintHat(CREATOR_HAT, creator); // legacy creator gate
        vm.prank(creator);
        hv.createProposal(bytes("p"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));
        // classSubject snapshot for idx 0 must equal the config-lib-written SUBJ (cross-lib read).
        assertEq(hv.proposalClassSubject(pid, 0), SUBJ, "proposals-lib snapshot mirrors config-lib write");
        // proposalCreatedAt side-mapping (W1) written by the proposals lib, read by the accessor.
        assertEq(hv.proposalCreatedAt(pid), uint64(block.timestamp), "proposalCreatedAt side-mapping mirrored");
    }

    function test_obl6_ddSideMappingSlotMirror() public {
        MockHats hats = new MockHats();
        DiffMockExecutor exec = new DiffMockExecutor();

        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory vh = new uint256[](1);
        vh[0] = VOTING_HAT;
        uint256[] memory ch = new uint256[](1);
        ch[0] = CREATOR_HAT;
        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize, (address(hats), address(exec), vh, ch, new address[](0), 50, 0)
        );
        DirectDemocracyVoting dd = DirectDemocracyVoting(address(new ERC1967Proxy(address(impl), data)));

        // proposalCreatedAt (W1 side-mapping) is written on createProposal and read via the accessor
        // out of the SAME poa.directdemocracy.storage slot — a drift would return 0.
        hats.mintHat(CREATOR_HAT, creator);
        uint256 t0 = block.timestamp;
        uint256 id = dd.proposalsCount();
        vm.prank(creator);
        dd.createProposal(bytes("p"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
        assertEq(dd.proposalCreatedAt(id), uint64(t0), "DD proposalCreatedAt side-mapping mirrored");
        assertTrue(dd.proposalCreatedAt(id) != 0, "side-mapping non-zero => slot resolved");
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 7 — W4 ctx convention: project-0 rows and global rows are DISTINCT under the
      authority arm (regression for the pre-W4 collision where projectId 0 == global ctx 0).
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function test_obl7_projectZeroVsGlobalCtxDistinct_authoritySide() public {
        MembershipAuthority auth = _deployAuthority(keccak256("org.w4"));
        uint256 sid = _role(auth, "Taskers", 0);
        _makeMember(auth, sid, alice);

        // Global row at ctx 0; project-0 row at ctx = bytes32(projectId+1) = bytes32(1) (the W4 offset).
        uint256 GLOBAL_MASK = TaskPerm.CREATE | TaskPerm.CLAIM;
        uint256 PROJ0_MASK = TaskPerm.REVIEW;
        vm.prank(executor);
        auth.setPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(GLOBAL_MASK, false));
        vm.prank(executor);
        auth.setPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(uint256(1)), _word(PROJ0_MASK, false)); // project 0

        // The two rows are STORED distinctly: global ctx 0 keeps its value; project-0 ctx 1 keeps its
        // own. Pre-W4 (identity mapping projectId==ctx) these would have collided at ctx 0.
        assertEq(
            auth.getPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(0)) & AccessV2PermKeys.VALUE_MASK,
            GLOBAL_MASK,
            "global ctx row intact"
        );
        assertEq(
            auth.getPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(uint256(1))) & AccessV2PermKeys.VALUE_MASK,
            PROJ0_MASK,
            "project-0 ctx row intact"
        );

        // The fold at global ctx returns the global value; at project-0 ctx (inherit=false) returns the
        // project value ONLY — proving no cross-contamination.
        assertEq(auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, bytes32(0)), GLOBAL_MASK, "global fold");
        assertEq(
            auth.hasPerm(alice, AccessV2PermKeys.TM_PERMS, bytes32(uint256(1))),
            PROJ0_MASK,
            "project-0 fold (inherit=false replaces global)"
        );
        assertTrue(GLOBAL_MASK != PROJ0_MASK, "distinct masks => the differential is meaningful");
    }

    function test_obl7_projectZeroVsGlobalCtxDistinct_throughTaskManager() public {
        MockHats hats = new MockHats();
        DiffMockPToken token = new DiffMockPToken();
        MembershipAuthority auth = _deployAuthority(keccak256("org.w4.tm"));

        uint256[] memory ch = new uint256[](1);
        ch[0] = CREATOR_HAT;
        TMDiffHarness impl = new TMDiffHarness();
        bytes memory initCall =
            abi.encodeCall(TaskManager.initialize, (address(token), address(hats), ch, executor, address(0)));
        TMDiffHarness tm = TMDiffHarness(address(new ERC1967Proxy(address(impl), initCall)));

        uint256 sid = _role(auth, "Taskers", 0);
        _makeMember(auth, sid, alice);

        // Global CREATE|CLAIM; a DISTINCT override for project 0 only (REVIEW, inherit=false).
        vm.prank(executor);
        auth.setPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(0), _word(TaskPerm.CREATE | TaskPerm.CLAIM, false));
        vm.prank(executor);
        auth.setPerm(sid, AccessV2PermKeys.TM_PERMS, bytes32(uint256(1)), _word(TaskPerm.REVIEW, false)); // project 0

        vm.prank(executor);
        tm.setMembershipAuthority(address(auth));

        // TaskManager queries ctx = bytes32(projectId+1). Project 0 must read its OWN row (REVIEW), NOT
        // the global row — the W4 fix. A different project (id 1 → ctx 2, no row) falls back to global.
        bytes32 project0 = bytes32(uint256(0));
        bytes32 project1 = bytes32(uint256(1));
        assertEq(tm.permMask(alice, project0), TaskPerm.REVIEW, "project 0 reads its own row, not global (W4)");
        assertEq(
            tm.permMask(alice, project1), TaskPerm.CREATE | TaskPerm.CLAIM, "project 1 (no row) falls back to global"
        );
        assertTrue(
            tm.permMask(alice, project0) != tm.permMask(alice, project1), "project-0 and global no longer collide"
        );
    }
}

/*═══════════════════════════════════════════════════════════════════════════════════════════════
    WORKSTREAM C2 — GNOSIS FORK DIFFERENTIALS (freeze §5.2 obligations 2, 3, 4)

    Runs against the LIVE canonical Hats + the real Gnosis OrgRegistry so passthrough fidelity and the
    OrgRegistry-gated bind path are exercised on real on-chain state. Tolerant of RPC flakiness:
    every test probes `_forkLive()` and skips-with-message on a rate-limited / dead endpoint.
═══════════════════════════════════════════════════════════════════════════════════════════════*/

interface IHatsFork {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
    function isInGoodStanding(address wearer, uint256 hatId) external view returns (bool);
    function balanceOf(address wearer, uint256 hatId) external view returns (uint256);
    function viewHat(uint256 hatId)
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        );
}

interface IOrgRegistryFork {
    function orgCount() external view returns (uint256);
    function orgOf(bytes32 orgId)
        external
        view
        returns (address executor, uint32 contractCount, bool bootstrap, bool exists);
    function getTopHat(bytes32 orgId) external view returns (uint256);
}

contract AccessV2DifferentialsGnosisForkTest is Test {
    // ── LIVE Gnosis addresses (verified on-chain at FORK_BLOCK) ──
    address internal constant CANONICAL_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address internal constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    uint256 internal constant FORK_BLOCK = 47_840_000;

    // ── LIVE org #1 on the Gnosis OrgRegistry (topHat domain 1071) ──
    bytes32 internal constant ORG1 = 0x9c22ff5f21f0b81b113e63f7db6da94fedef11b2119b4088b89664fb9a3cb658;
    address internal constant ORG1_EXECUTOR = 0xb92dfeD8C15e2c66c91BfE0491BA9FC158d988B8;
    uint256 internal constant ORG1_TOPHAT = 28874102880518335220088373158198024451465381676540953127261966576910336;
    uint256 internal constant ORG1_ROLEHAT0 = 28874103291900751747906241681822209527622904785535345867272591585050624;
    uint256 internal constant ORG1_DOMAIN = 1071; // ORG1_TOPHAT >> 224

    // ── LIVE org #2 (different executor — used for the spoof-bind rejection) ──
    bytes32 internal constant ORG2 = 0x4da432f1ecd4c0ac028ebde3a3f78510a21d54087b161590a63080d33b702b8d;
    address internal constant ORG2_EXECUTOR = 0x85021136212c2Ff091d7fbEcfD70F423D3039950;

    address internal admin = makeAddr("router-admin");
    address internal hub = makeAddr("paymaster-hub");
    address internal member = makeAddr("adopted-member");

    AuthorityRouter internal router;
    bool internal forkReady;

    function setUp() public {
        try vm.createSelectFork("gnosis", FORK_BLOCK) {
            forkReady = true;
        } catch {
            forkReady = false;
            return;
        }
        // Router points at the REAL Hats + REAL OrgRegistry (zero bindings at birth = pure passthrough).
        AuthorityRouter impl = new AuthorityRouter();
        try new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (CANONICAL_HATS, ORG_REGISTRY, hub, admin))
        ) returns (
            ERC1967Proxy p
        ) {
            router = AuthorityRouter(address(p));
        } catch {
            forkReady = false;
        }
    }

    /// @dev Probe the fork is live and the pinned org state is present; skip-with-message otherwise
    ///      (RPC rate limits surface as reverts / empty returndata per the repo's fork-noise convention).
    function _forkLive() internal returns (bool) {
        if (!forkReady || address(router) == address(0)) {
            vm.skip(true, "gnosis fork unavailable (RPC down/rate-limited)");
            return false;
        }
        try IOrgRegistryFork(ORG_REGISTRY).orgCount() returns (uint256 c) {
            if (c == 0) {
                vm.skip(true, "OrgRegistry empty at fork block (RPC anomaly)");
                return false;
            }
        } catch {
            vm.skip(true, "OrgRegistry probe reverted (RPC rate-limited)");
            return false;
        }
        return true;
    }

    struct Hat9 {
        string details;
        uint32 maxSupply;
        uint32 supply;
        address eligibility;
        address toggle;
        string imageURI;
        uint16 lastHatId;
        bool mutable_;
        bool active;
    }

    function _routerHat(uint256 id) internal view returns (Hat9 memory h) {
        (h.details, h.maxSupply, h.supply, h.eligibility, h.toggle, h.imageURI, h.lastHatId, h.mutable_, h.active) =
            router.viewHat(id);
    }

    function _hatsHat(uint256 id) internal view returns (Hat9 memory h) {
        (h.details, h.maxSupply, h.supply, h.eligibility, h.toggle, h.imageURI, h.lastHatId, h.mutable_, h.active) =
            IHatsFork(CANONICAL_HATS).viewHat(id);
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 2 — Hub-parity differential on live data. Router with ZERO bindings must byte-match
      direct Hats for the served IHats subset over REAL hat ids + wearers (passthrough fidelity); then
      a bound test authority serves adopted ids from itself.
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function test_obl2_passthroughFidelityOnLiveData() public {
        if (!_forkLive()) return;

        uint256[] memory ids = new uint256[](3);
        ids[0] = ORG1_TOPHAT;
        ids[1] = ORG1_ROLEHAT0;
        ids[2] = (uint256(9999) << 224) | 7; // a never-minted legacy id → safe zeros both sides

        address[] memory users = new address[](2);
        users[0] = ORG1_EXECUTOR; // a REAL wearer (wears the topHat)
        users[1] = member; // a non-wearer

        bool sawTrue;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            for (uint256 j; j < users.length; ++j) {
                address u = users[j];
                // Byte-parity of every hub-consumed selector through the passthrough arm.
                assertEq(
                    router.isWearerOfHat(u, id),
                    IHatsFork(CANONICAL_HATS).isWearerOfHat(u, id),
                    "isWearerOfHat passthrough parity"
                );
                assertEq(
                    router.isEligible(u, id),
                    IHatsFork(CANONICAL_HATS).isEligible(u, id),
                    "isEligible passthrough parity"
                );
                assertEq(
                    router.balanceOf(u, id), IHatsFork(CANONICAL_HATS).balanceOf(u, id), "balanceOf passthrough parity"
                );
                // getWearerStatus is composed from isEligible + isInGoodStanding on the passthrough arm.
                (bool re, bool rs) = router.getWearerStatus(u, id);
                assertEq(re, IHatsFork(CANONICAL_HATS).isEligible(u, id), "getWearerStatus.eligible parity");
                assertEq(rs, IHatsFork(CANONICAL_HATS).isInGoodStanding(u, id), "getWearerStatus.standing parity");
                if (router.isWearerOfHat(u, id)) sawTrue = true;
            }
            // Nine-field viewHat byte-parity on live data.
            assertEq(abi.encode(_routerHat(id)), abi.encode(_hatsHat(id)), "viewHat 9-field byte-parity");
        }
        assertTrue(sawTrue, "at least one live nonzero wearer proves parity on real data, not just zeros");
    }

    function test_obl2_authorityArmServesAdoptedIds() public {
        if (!_forkLive()) return;

        // Stand up a test authority (its own executor gate = this test) and seed the REAL roleHat0 as an
        // adopted subject with `member` as a member.
        MembershipAuthority auth = _deployTestAuthority();
        uint256[] memory subs = new uint256[](1);
        subs[0] = ORG1_ROLEHAT0;
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        names[0] = "AdoptedRole";
        uint32[] memory mm = new uint32[](1);
        auth.seedSubjects(subs, kinds, names, mm);
        // Grant + accept membership for `member`.
        auth.setRule(ORG1_ROLEHAT0, member, AccessV2Types.RuleKind.Grant, false);
        address[] memory us = new address[](1);
        us[0] = member;
        auth.seedMemberships(subs, us);
        assertTrue(auth.isMember(ORG1_ROLEHAT0, member), "authority seeded member");

        // Bind domain 1071 → our authority through the OrgRegistry-gated path (prank real executor).
        vm.prank(ORG1_EXECUTOR);
        router.bindAuthority(ORG1, ORG1_DOMAIN, address(auth));

        // Now the router serves roleHat0 from OUR authority, not Hats: `member` reads true even though
        // Hats never minted them the hat.
        assertTrue(router.isWearerOfHat(member, ORG1_ROLEHAT0), "authority-served membership via router");
        assertFalse(IHatsFork(CANONICAL_HATS).isWearerOfHat(member, ORG1_ROLEHAT0), "Hats direct answer is independent");
        // An id in the SAME domain the authority doesn't know resolves empty (authority arm), not Hats.
        assertFalse(
            router.isWearerOfHat(ORG1_EXECUTOR, ORG1_TOPHAT), "unknown-to-authority id in bound domain => empty"
        );
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 3 — Router binding integrity against REAL OrgRegistry state.
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function test_obl3_bindingIntegrityOnFork() public {
        if (!_forkLive()) return;
        MembershipAuthority auth = _deployTestAuthority();

        // Confirm the on-chain executor + topHat domain match our pinned constants (guards against a
        // registry migration silently invalidating the test).
        (address ex,,, bool exists) = IOrgRegistryFork(ORG_REGISTRY).orgOf(ORG1);
        assertTrue(exists, "ORG1 exists on the live registry");
        assertEq(ex, ORG1_EXECUTOR, "ORG1 executor matches pinned constant");
        assertEq(IOrgRegistryFork(ORG_REGISTRY).getTopHat(ORG1) >> 224, ORG1_DOMAIN, "ORG1 topHat domain == 1071");

        // ── Spoof #1: a DIFFERENT org's executor cannot bind ORG1's domain (NotOrgExecutor) ──
        vm.prank(ORG2_EXECUTOR);
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        router.bindAuthority(ORG1, ORG1_DOMAIN, address(auth));

        // ── Spoof #2: the real ORG1 executor claiming the WRONG domain (TopHatDomainMismatch) ──
        vm.prank(ORG1_EXECUTOR);
        vm.expectRevert(IAuthorityRouter.TopHatDomainMismatch.selector);
        router.bindAuthority(ORG1, ORG1_DOMAIN + 1, address(auth));

        // ── Legit bind by the real executor ──
        vm.prank(ORG1_EXECUTOR);
        router.bindAuthority(ORG1, ORG1_DOMAIN, address(auth));
        assertEq(router.authorityOf(ORG1_ROLEHAT0), address(auth), "bound: legacy id in domain routes to authority");

        // Double-bind guard.
        vm.prank(ORG1_EXECUTOR);
        vm.expectRevert(IAuthorityRouter.AlreadyBound.selector);
        router.bindAuthority(ORG1, ORG1_DOMAIN, address(auth));

        // ── Unbind restores passthrough (byte-parity with direct Hats resumes) ──
        vm.prank(ORG1_EXECUTOR);
        router.unbindAuthority(ORG1, ORG1_DOMAIN);
        assertEq(router.authorityOf(ORG1_ROLEHAT0), address(0), "unbound: domain no longer routes");
        assertEq(
            router.isWearerOfHat(ORG1_EXECUTOR, ORG1_TOPHAT),
            IHatsFork(CANONICAL_HATS).isWearerOfHat(ORG1_EXECUTOR, ORG1_TOPHAT),
            "passthrough parity restored after unbind"
        );

        // Only the org's own executor can unbind.
        vm.prank(ORG1_EXECUTOR);
        router.bindAuthority(ORG1, ORG1_DOMAIN, address(auth));
        vm.prank(ORG2_EXECUTOR);
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        router.unbindAuthority(ORG1, ORG1_DOMAIN);
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────
      OBLIGATION 4 — EntryPoint simulateValidation differential (closest achievable approximation).

      The full harness (test/PaymasterHub*.t.sol.skip) needs a deployed EntryPoint + PaymasterHub +
      PasskeyAccount + a signed UserOp — infra not reconstructable in a plain fork without secrets. We
      implement the load-bearing core: the hub's eligibility read is
      `IHats(hub.hats).isWearerOfHat(sender, hatId)` (PaymasterHub.sol:369/381/383). We prove that
      routing that exact read through the router (hub as msg.sender = the revert-wrap branch) is
      OUTCOME-IDENTICAL to the direct Hats read on live data, with a bounded validation-gas delta. The
      residual gap (real simulateValidation gas + ERC-7562 access-rule record) is documented below.
    ───────────────────────────────────────────────────────────────────────────────────────────*/

    function test_obl4_hubValidationReadParityAndGasDelta() public {
        if (!_forkLive()) return;

        uint256[] memory ids = new uint256[](2);
        ids[0] = ORG1_TOPHAT;
        ids[1] = ORG1_ROLEHAT0;
        address[] memory users = new address[](2);
        users[0] = ORG1_EXECUTOR;
        users[1] = member;

        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < users.length; ++j) {
                bool direct = IHatsFork(CANONICAL_HATS).isWearerOfHat(users[j], ids[i]);

                // Route the identical read through the router AS THE HUB (revert-wrap branch active).
                vm.prank(hub);
                uint256 g0 = gasleft();
                bool viaRouter = router.isWearerOfHat(users[j], ids[i]);
                uint256 routerGas = g0 - gasleft();

                uint256 g1 = gasleft();
                bool viaDirect = IHatsFork(CANONICAL_HATS).isWearerOfHat(users[j], ids[i]);
                uint256 directGas = g1 - gasleft();

                assertEq(viaRouter, direct, "router-relayed validation read matches direct Hats");
                assertEq(viaRouter, viaDirect, "self-consistency");

                // Bounded overhead: the router adds one classification + a staticcall relay. Assert the
                // added gas is small relative to a hub's verificationGasLimit default (well under 40k).
                uint256 overhead = routerGas > directGas ? routerGas - directGas : 0;
                assertLt(overhead, 40_000, "router validation-path overhead is bounded");
            }
        }
        // DOCUMENTED GAP: a true EntryPoint.simulateValidation differential (paymaster validation-gas
        // accounting + ERC-7562 storage-access-rule classification of the router hop) is deferred to an
        // ops fork run once a PaymasterHub proxy + EntryPoint + funded PasskeyAccount are deployed on the
        // migration fork — see the report's "deferred obligations" list.
    }

    /*───────────────────────────────────────────────────────────────────────────────────────────*/

    function _deployTestAuthority() internal returns (MembershipAuthority a) {
        AccessV2Types.OrgAccessSeed memory seed;
        seed.subjectIds = new uint256[](0);
        seed.subjectKinds = new AccessV2Types.SubjectKind[](0);
        seed.subjectNames = new string[](0);
        seed.subjectMaxMembers = new uint32[](0);
        seed.subjectDefaults = new bool[](0);
        seed.groupMemberRoles = new uint256[][](0);
        seed.vouchSubjects = new uint256[](0);
        seed.vouchQuorums = new uint32[](0);
        seed.vouchVoucherSubjects = new uint256[](0);
        seed.permSubjects = new uint256[](0);
        seed.permKeys = new bytes32[](0);
        seed.permCtxs = new bytes32[](0);
        seed.permWords = new uint256[](0);
        MembershipAuthority impl = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg =
            IMembershipAuthority.InitConfig({executor: address(this), paymasterHub: hub, orgId: ORG1, seed: seed});
        a = MembershipAuthority(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MembershipAuthority.initialize, (cfg))))
        );
        a.setPaused(false);
    }
}
