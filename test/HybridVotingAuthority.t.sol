// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {HybridVotingConfig} from "../src/libs/HybridVotingConfig.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IExecutor} from "../src/Executor.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {MockMembershipAuthority} from "./mocks/MockMembershipAuthority.sol";

contract HVAuthMockExecutor is IExecutor {
    function execute(uint256, Call[] calldata) external {}
}

/// @notice Access v2 (workstream B1) DUAL-PATH suite for HybridVoting: HV_CREATE creator gating, the
///         class-membership ELECTORATE ACTIVATION GATE via stable subject ids, per-proposal subject
///         snapshot IMMUTABILITY across setClassSubject edits, the setClassSubject allocation
///         semantics + auth, the legacy↔authority equality differential, and rollback-to-zero. The
///         legacy-path regression lives in HybridVoting*.t.sol (green).
contract HybridVotingAuthorityTest is Test {
    HybridVoting hv;
    MockHats hats;
    MockMembershipAuthority auth;
    HVAuthMockExecutor exec;

    address creator = address(0xC1);
    address configAdmin = address(0xC0FFEE);
    address voter = address(0xA11CE);
    address voterB = address(0xB0B);
    address rando = address(0xBAD);

    uint256 constant MEMBER_HAT = 1;
    uint256 constant CREATOR_HAT = 2;
    uint256 constant SUBJ_A = 1001;
    uint256 constant SUBJ_B = 1002;

    event MembershipAuthoritySet(address indexed authority);
    event ClassSubjectSet(uint256 indexed classId, uint256 indexed classIdx, uint256 indexed subjectId);

    function setUp() public {
        hats = new MockHats();
        auth = new MockMembershipAuthority();
        exec = new HVAuthMockExecutor();

        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = MEMBER_HAT;
        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = CREATOR_HAT;

        // Single DIRECT class, 100% slice, gated on MEMBER_HAT (legacy) — trivially deterministic tally.
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: memberHats
        });

        HybridVoting impl = new HybridVoting();
        bytes memory data = abi.encodeCall(
            HybridVoting.initialize,
            (address(hats), address(exec), creatorHats, new address[](0), uint8(50), uint32(0), classes)
        );
        hv = HybridVoting(payable(address(new ERC1967Proxy(address(impl), data))));
    }

    /*───────────────────────── helpers ─────────────────────────*/

    function _emptyBatches(uint8 opts) internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](opts);
        for (uint256 i; i < opts; ++i) {
            b[i] = new IExecutor.Call[](0);
        }
    }

    function _vote(uint256 id, address who, uint8 option) internal {
        uint8[] memory idx = new uint8[](1);
        idx[0] = option;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(who);
        hv.vote(id, idx, w);
    }

    function _expectVoteRevert(uint256 id, address who) internal {
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(who);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.vote(id, idx, w);
    }

    function _setAuthority(address a) internal {
        vm.prank(address(exec));
        hv.setMembershipAuthority(a);
    }

    function _create(address who) internal returns (uint256 id) {
        id = hv.proposalsCount();
        vm.prank(who);
        hv.createProposal(bytes("p"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));
    }

    /*───────────────────────── setter auth + rollback ─────────────────────────*/

    function testSetMembershipAuthorityOnlyExecutor() public {
        vm.prank(rando);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.setMembershipAuthority(address(auth));

        vm.expectEmit(true, false, false, false);
        emit MembershipAuthoritySet(address(auth));
        _setAuthority(address(auth));
        assertEq(hv.membershipAuthority(), address(auth));
    }

    /*───────────────────────── setClassSubject allocation + auth ─────────────────────────*/

    function testSetClassSubjectAllocationAndAuth() public {
        // configAdmin path is allowed; rando is not.
        vm.prank(address(exec));
        hv.setConfigAdmin(configAdmin);

        vm.prank(rando);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.setClassSubject(0, SUBJ_A);

        // First use of idx 0 allocates stable classId = 1 and records the linkage + binding.
        assertEq(hv.classIdOfIndex(0), 0, "unallocated before first set");
        vm.expectEmit(true, true, true, false);
        emit ClassSubjectSet(1, 0, SUBJ_A);
        vm.prank(configAdmin);
        hv.setClassSubject(0, SUBJ_A);
        assertEq(hv.classIdOfIndex(0), 1, "classId allocated");
        assertEq(hv.classSubjectOf(1), SUBJ_A, "subject bound");

        // Re-binding idx 0 REUSES the same stable classId (no re-allocation).
        vm.prank(address(exec));
        hv.setClassSubject(0, SUBJ_B);
        assertEq(hv.classIdOfIndex(0), 1, "classId reused");
        assertEq(hv.classSubjectOf(1), SUBJ_B, "subject re-bound");

        // A different idx allocates a fresh id.
        vm.prank(address(exec));
        hv.setClassSubject(1, SUBJ_A);
        assertEq(hv.classIdOfIndex(1), 2, "second idx allocates classId 2");
    }

    /*───────────────────────── creator gating ─────────────────────────*/

    function testAuthorityCreatorGating() public {
        _setAuthority(address(auth));

        // Legacy CREATOR_HAT is dead under the authority path.
        hats.mintHat(CREATOR_HAT, creator);
        vm.prank(creator);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.createProposal(bytes("p"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));

        auth.setPermBool(creator, AccessV2PermKeys.HV_CREATE, true);
        uint256 id = _create(creator);
        assertEq(id, 0);
    }

    /*───────────────────────── class-membership ACTIVATION GATE ─────────────────────────*/

    function testActivationGateClassMembership() public {
        _setAuthority(address(auth));
        vm.prank(address(exec));
        hv.setClassSubject(0, SUBJ_A);
        auth.setPermBool(creator, AccessV2PermKeys.HV_CREATE, true);

        uint256 t0 = block.timestamp;
        uint256 p0 = _create(creator);
        assertEq(hv.proposalCreatedAt(p0), uint64(t0));
        assertEq(hv.proposalClassSubject(p0, 0), SUBJ_A, "snapshot bound to SUBJ_A");

        // Voter not yet a member ⇒ zero power ⇒ vote reverts.
        _expectVoteRevert(p0, voter);

        // Voter joins SUBJ_A mid-proposal at T1 > T0.
        vm.warp(t0 + 100);
        uint64 t1 = uint64(block.timestamp);
        auth.setSubjectActive(SUBJ_A, voter, t1);

        // Still excluded from P0 (activation t1 > P0.createdAt t0).
        _expectVoteRevert(p0, voter);

        // But eligible on P1 created at T1.
        uint256 p1 = _create(creator);
        assertEq(hv.proposalCreatedAt(p1), t1);
        _vote(p1, voter, 0);
        vm.warp(block.timestamp + 16 minutes);
        (, bool valid) = hv.announceWinner(p1);
        assertTrue(valid);
    }

    /*───────────────────────── PRE-CUTOVER ANCHOR SENTINEL (C5/C8/C9) ─────────────────────────*/

    /// @notice REGRESSION (C5/C8/C9): a proposal created BEFORE the module carried the activation
    ///         anchor — `proposalCreatedAt` slot reads 0, a pre-cutover / pre-Access-v2 legacy
    ///         proposal — must stay votable by its eligible classes after `setMembershipAuthority`
    ///         repoints the module. Pre-fix every class member yielded zero power (activeMemberSince
    ///         is never `<= 0`), so the whole electorate hit Unauthorized on any in-flight proposal
    ///         spanning cutover. Membership is still required on the zero anchor: a non-member reverts.
    function testPreCutoverProposalVotableAfterAuthoritySet() public {
        // Legacy-path proposal at genesis ⇒ its anchor + class-subject snapshot slots both read 0
        // (pre-Access-v2 bytecode: neither mapping existed). Class 0 stays hat-gated on MEMBER_HAT.
        vm.warp(0);
        hats.mintHat(CREATOR_HAT, creator);
        uint256 id = _create(creator);
        assertEq(hv.proposalCreatedAt(id), 0, "precondition: legacy proposal has a zero anchor");
        assertEq(hv.proposalClassSubject(id, 0), 0, "precondition: no class-subject snapshot");

        // Cutover.
        vm.warp(100);
        _setAuthority(address(auth));

        // Snapshot is 0 ⇒ class falls back to cls.hatIds ([MEMBER_HAT]) as adopted-verbatim subject
        // ids. A member of subject MEMBER_HAT (active since T=1, before creation) can vote.
        auth.setSubjectActive(MEMBER_HAT, voter, uint64(1));
        _vote(id, voter, 0);
        vm.warp(block.timestamp + 16 minutes);
        (, bool valid) = hv.announceWinner(id);
        assertTrue(valid, "eligible member's vote must count on the zero-anchor proposal");
    }

    /// @notice REGRESSION (C5/C8/C9): a non-member is still excluded from a zero-anchor proposal —
    ///         the fix relaxes the TIME gate, not the MEMBERSHIP gate.
    function testPreCutoverProposalStillBlocksNonMember() public {
        vm.warp(0);
        hats.mintHat(CREATOR_HAT, creator);
        uint256 id = _create(creator);
        assertEq(hv.proposalCreatedAt(id), 0);

        vm.warp(100);
        _setAuthority(address(auth));

        // `rando` is a member of no subject ⇒ zero power ⇒ Unauthorized, even on the zero anchor.
        _expectVoteRevert(id, rando);
    }

    /*───────────────────────── subject snapshot IMMUTABILITY ─────────────────────────*/

    /// @notice A class's per-proposal subject is snapshotted at creation and is immune to later
    ///         setClassSubject edits: the old proposal keeps resolving via the ORIGINAL subject.
    function testClassSubjectSnapshotImmutability() public {
        _setAuthority(address(auth));
        vm.prank(address(exec));
        hv.setClassSubject(0, SUBJ_A);
        auth.setPermBool(creator, AccessV2PermKeys.HV_CREATE, true);

        uint256 t0 = block.timestamp;
        // voter ∈ SUBJ_A only; voterB ∈ SUBJ_B only — both active since T0.
        auth.setSubjectActive(SUBJ_A, voter, uint64(t0));
        auth.setSubjectActive(SUBJ_B, voterB, uint64(t0));

        uint256 p = _create(creator);
        assertEq(hv.proposalClassSubject(p, 0), SUBJ_A);

        // Governance re-binds class 0 to SUBJ_B AFTER creation (live classSubject now SUBJ_B).
        vm.prank(address(exec));
        hv.setClassSubject(0, SUBJ_B);
        assertEq(hv.classSubjectOf(hv.classIdOfIndex(0)), SUBJ_B, "live binding moved");

        // The old proposal still uses the SNAPSHOT (SUBJ_A): voter votes, voterB (only SUBJ_B) cannot.
        _vote(p, voter, 0);
        _expectVoteRevert(p, voterB);

        // A NEW proposal snapshots the new binding (SUBJ_B): now voterB qualifies, voter does not.
        uint256 p2 = _create(creator);
        assertEq(hv.proposalClassSubject(p2, 0), SUBJ_B);
        _vote(p2, voterB, 0);
        _expectVoteRevert(p2, voter);
    }

    /*───────────────────────── equality differential ─────────────────────────*/

    /// @notice The SAME electorate expressed via legacy hats vs an authority subject yields identical
    ///         tallies on two otherwise-identical HV instances.
    function testEqualityDifferentialLegacyVsAuthority() public {
        // ── Legacy instance (the setUp one): creator wears CREATOR_HAT, voter wears MEMBER_HAT ──
        hats.mintHat(CREATOR_HAT, creator);
        hats.mintHat(MEMBER_HAT, voter);
        uint256 idL = _create(creator);
        _vote(idL, voter, 0);
        vm.warp(block.timestamp + 16 minutes);
        (uint256 winL, bool validL) = hv.announceWinner(idL);

        // ── Authority instance: identical single DIRECT class, subject SUBJ_A ──
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = MEMBER_HAT;
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: memberHats
        });
        HybridVoting impl = new HybridVoting();
        bytes memory data = abi.encodeCall(
            HybridVoting.initialize,
            (address(hats), address(exec), new uint256[](0), new address[](0), uint8(50), uint32(0), classes)
        );
        HybridVoting hv2 = HybridVoting(payable(address(new ERC1967Proxy(address(impl), data))));
        vm.prank(address(exec));
        hv2.setMembershipAuthority(address(auth));
        vm.prank(address(exec));
        hv2.setClassSubject(0, SUBJ_A);
        auth.setPermBool(creator, AccessV2PermKeys.HV_CREATE, true);

        uint256 idA = hv2.proposalsCount();
        vm.prank(creator);
        hv2.createProposal(bytes("p"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));
        auth.setSubjectActive(SUBJ_A, voter, hv2.proposalCreatedAt(idA));
        {
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            hv2.vote(idA, idx, w);
        }
        vm.warp(block.timestamp + 16 minutes);
        (uint256 winA, bool validA) = hv2.announceWinner(idA);

        assertEq(winL, winA, "winner idx differs");
        assertEq(validL, validA, "validity differs");
        assertTrue(validA);
    }

    /*───────────────────────── rollback to zero ─────────────────────────*/

    function testRollbackToZeroRestoresLegacy() public {
        _setAuthority(address(auth));
        assertEq(hv.membershipAuthority(), address(auth));

        _setAuthority(address(0));
        assertEq(hv.membershipAuthority(), address(0));

        // Legacy path live again: hat-wearing creator + voter work without authority perms/subjects.
        hats.mintHat(CREATOR_HAT, creator);
        hats.mintHat(MEMBER_HAT, voter);
        uint256 id = _create(creator);
        _vote(id, voter, 0);
        vm.warp(block.timestamp + 16 minutes);
        (, bool valid) = hv.announceWinner(id);
        assertTrue(valid);
    }
}
