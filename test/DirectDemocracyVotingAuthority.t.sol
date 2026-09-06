// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DirectDemocracyVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {MockMembershipAuthority} from "./mocks/MockMembershipAuthority.sol";

contract DDAuthMockExecutor is IExecutor {
    function execute(uint256, Call[] calldata batch) external {
        for (uint256 i; i < batch.length; ++i) {
            (bool ok,) = batch[i].target.call{value: batch[i].value}(batch[i].data);
            require(ok, "DDAuthMockExecutor: call failed");
        }
    }
}

/// @notice Access v2 (workstream B1) DUAL-PATH suite for DirectDemocracyVoting: creator gating +
///         voter ELECTORATE ACTIVATION GATE via the MembershipAuthority, restricted-poll subject
///         lists, the legacy↔authority equality differential, and rollback-to-zero. The legacy-path
///         regression lives in DirectDemocracyVoting.t.sol / DirectDemocracyVotingV2.t.sol (green).
contract DirectDemocracyVotingAuthorityTest is Test {
    DirectDemocracyVoting dd;
    MockHats hats;
    MockMembershipAuthority auth;
    DDAuthMockExecutor exec;

    address creator = address(0xC1);
    address voter = address(0xA11CE);
    address rando = address(0xBAD);

    uint256 constant VOTING_HAT = 1;
    uint256 constant CREATOR_HAT = 2;
    uint256 constant EXEC_SUBJECT = 777; // a restricted-poll subject id (opaque uint256)

    event MembershipAuthoritySet(address indexed authority);

    function setUp() public {
        hats = new MockHats();
        auth = new MockMembershipAuthority();
        exec = new DDAuthMockExecutor();

        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory initialHats = new uint256[](1);
        initialHats[0] = VOTING_HAT;
        uint256[] memory initialCreatorHats = new uint256[](1);
        initialCreatorHats[0] = CREATOR_HAT;
        address[] memory targets = new address[](0);

        bytes memory data = abi.encodeCall(DirectDemocracyVoting.initialize, (address(exec), targets, 50, 0));
        dd = DirectDemocracyVoting(address(new ERC1967Proxy(address(impl), data)));
    }

    /*───────────────────────── helpers ─────────────────────────*/

    function _emptyBatches(uint8 opts) internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](opts);
        for (uint256 i; i < opts; ++i) {
            b[i] = new IExecutor.Call[](0);
        }
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _voteYes(address who, uint256 id) internal {
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(who);
        dd.vote(id, idx, w);
    }

    function _createUnrestricted(address who) internal returns (uint256 id) {
        id = dd.proposalsCount();
        vm.prank(who);
        dd.createProposal(bytes("p"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
    }

    function _setAuthority(address a) internal {
        vm.prank(address(exec));
        dd.setMembershipAuthority(a);
    }

    /*───────────────────────── setter auth + rollback ─────────────────────────*/

    function testSetMembershipAuthorityOnlyExecutor() public {
        vm.prank(rando);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.setMembershipAuthority(address(auth));

        vm.expectEmit(true, false, false, false);
        emit MembershipAuthoritySet(address(auth));
        _setAuthority(address(auth));
        assertEq(dd.membershipAuthority(), address(auth));

        vm.prank(address(exec));
        vm.expectRevert(VotingErrors.ZeroAddress.selector);
        dd.setMembershipAuthority(address(0));
        assertEq(dd.membershipAuthority(), address(auth), "failed rollback preserves authority");
    }

    /*───────────────────────── creator gating ─────────────────────────*/

    function testAuthorityCreatorGating() public {
        _setAuthority(address(auth));

        // No DD_CREATE perm ⇒ cannot create (legacy CREATOR_HAT is now dead).
        hats.mintHat(CREATOR_HAT, creator);
        vm.prank(creator);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.createProposal(bytes("p"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));

        // Grant DD_CREATE via the authority ⇒ creation succeeds.
        auth.setPermBool(creator, AccessV2PermKeys.DD_CREATE, true);
        uint256 id = _createUnrestricted(creator);
        assertEq(id, 0);
    }

    /*───────────────────────── ELECTORATE ACTIVATION GATE ─────────────────────────*/

    /// @notice A member added AFTER a proposal's creation cannot vote on it, but CAN vote on the next
    ///         proposal created once active — the anti-packing gate, authority path only.
    function testActivationGateMidProposalAdd() public {
        _setAuthority(address(auth));
        auth.setPermBool(creator, AccessV2PermKeys.DD_CREATE, true);

        // T0: proposal P0 created; voter not yet a member.
        uint256 t0 = block.timestamp;
        uint256 p0 = _createUnrestricted(creator);
        assertEq(dd.proposalCreatedAt(p0), uint64(t0));

        vm.prank(voter);
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.vote(p0, idx, w);

        // Voter joins mid-proposal at T1 > T0.
        vm.warp(t0 + 100);
        uint64 t1 = uint64(block.timestamp);
        auth.setKeyActive(voter, AccessV2PermKeys.DD_VOTE, t1);

        // Still cannot vote on P0 (activation t1 > P0.createdAt t0).
        vm.prank(voter);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.vote(p0, idx, w);

        // But CAN vote on P1 created at T1 (activation t1 <= P1.createdAt t1).
        uint256 p1 = _createUnrestricted(creator);
        assertEq(dd.proposalCreatedAt(p1), t1);
        _voteYes(voter, p1);
        assertEq(dd.proposalsCount(), 2);
    }

    /*───────────────────────── PRE-CUTOVER ANCHOR SENTINEL (C5/C8/C9) ─────────────────────────*/

    /// @notice REGRESSION (C5/C8/C9): a proposal created BEFORE the module carried the activation
    ///         anchor — its `proposalCreatedAt` slot reads 0, i.e. a pre-cutover / pre-Access-v2
    ///         legacy proposal — must stay votable by the ELIGIBLE electorate after
    ///         `setMembershipAuthority` flips the module onto the authority path. Pre-fix the whole
    ///         electorate was locked out (activeMemberSince, always a real ts or the max sentinel, is
    ///         never `<= 0`), disenfranchising every in-flight proposal that spans an org's cutover.
    ///         Membership is STILL required on the zero anchor: a non-member remains blocked.
    function testPreCutoverProposalVotableAfterAuthoritySet() public {
        // Create the proposal on the LEGACY path (authority unset) at genesis, so its anchor slot
        // reads 0 — mirroring a proposal created under pre-Access-v2 bytecode (mapping absent).
        vm.warp(0);
        hats.mintHat(CREATOR_HAT, creator);
        uint256 id = _createUnrestricted(address(exec));
        assertEq(dd.proposalCreatedAt(id), 0, "precondition: legacy proposal has a zero anchor");

        // Cutover: repoint the still-open proposal onto the authority path.
        vm.warp(100);
        _setAuthority(address(auth));

        // A long-standing eligible member (active since T=1, before the proposal existed) can vote.
        auth.setKeyActive(voter, AccessV2PermKeys.DD_VOTE, uint64(1));
        _voteYes(voter, id);

        // Anti-packing survives on the zero anchor: a non-member is still rejected (membership gate).
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(rando);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.vote(id, idx, w);
    }

    /// @notice REGRESSION (C5/C8/C9), restricted-poll arm: a pre-cutover restricted poll (zero anchor)
    ///         stays votable by its subject members after cutover, while the per-poll subject gate is
    ///         still enforced (a DD_VOTE holder outside the subject gets RoleNotAllowed).
    function testPreCutoverRestrictedPollVotableAfterAuthoritySet() public {
        vm.warp(0);
        hats.mintHat(CREATOR_HAT, creator);
        uint256 id = dd.proposalsCount();
        vm.prank(address(exec));
        dd.createProposal(bytes("restricted"), bytes32(0), 10, 2, _emptyBatches(2), _one(EXEC_SUBJECT));
        assertEq(dd.proposalCreatedAt(id), 0, "precondition: legacy restricted poll has a zero anchor");

        vm.warp(100);
        _setAuthority(address(auth));

        // `voter`: DD_VOTE + EXEC_SUBJECT member ⇒ passes both gates on the zero anchor.
        auth.setKeyActive(voter, AccessV2PermKeys.DD_VOTE, uint64(1));
        auth.setSubjectActive(EXEC_SUBJECT, voter, uint64(1));
        _voteYes(voter, id);

        // `rando`: holds DD_VOTE but NOT EXEC_SUBJECT ⇒ subject gate still bites ⇒ RoleNotAllowed.
        auth.setKeyActive(rando, AccessV2PermKeys.DD_VOTE, uint64(1));
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(rando);
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(id, idx, w);
    }

    /*───────────────────────── restricted-poll subjects ─────────────────────────*/

    function testAuthorityRestrictedPollSubject() public {
        _setAuthority(address(auth));
        auth.setPermBool(creator, AccessV2PermKeys.DD_CREATE, true);

        uint256 t0 = block.timestamp;
        // Base DD_VOTE eligibility for both users (active since T0).
        auth.setKeyActive(voter, AccessV2PermKeys.DD_VOTE, uint64(t0));
        auth.setKeyActive(rando, AccessV2PermKeys.DD_VOTE, uint64(t0));

        // Restricted poll gated on subject EXEC_SUBJECT; only `voter` is an active member of it.
        auth.setSubjectActive(EXEC_SUBJECT, voter, uint64(t0));

        uint256 id = dd.proposalsCount();
        vm.prank(creator);
        dd.createProposal(bytes("restricted"), bytes32(0), 10, 2, _emptyBatches(2), _one(EXEC_SUBJECT));

        // `voter` (subject member) can vote.
        _voteYes(voter, id);

        // `rando` passes the base DD_VOTE gate but is NOT a member of EXEC_SUBJECT ⇒ RoleNotAllowed.
        vm.prank(rando);
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(id, idx, w);
    }
}
