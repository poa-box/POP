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

        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize,
            (address(hats), address(exec), initialHats, initialCreatorHats, targets, 50, 0)
        );
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

    /*───────────────────────── equality differential ─────────────────────────*/

    /// @notice The SAME electorate expressed via legacy hats vs authority subjects yields identical
    ///         tallies/winners on two otherwise-identical DD instances.
    function testEqualityDifferentialLegacyVsAuthority() public {
        // ── Legacy instance: voter wears VOTING_HAT ──
        hats.mintHat(CREATOR_HAT, creator);
        hats.mintHat(VOTING_HAT, voter);
        uint256 idL = _createUnrestricted(creator); // creator wears CREATOR_HAT (legacy path)
        _voteYes(voter, idL);
        vm.warp(block.timestamp + 11 * 60);
        (uint256 winL, bool validL) = dd.announceWinner(idL);

        // ── Authority instance: identical electorate via subjects/keys ──
        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        address[] memory targets = new address[](0);
        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize,
            (address(hats), address(exec), new uint256[](0), new uint256[](0), targets, 50, 0)
        );
        DirectDemocracyVoting dd2 = DirectDemocracyVoting(address(new ERC1967Proxy(address(impl), data)));
        vm.prank(address(exec));
        dd2.setMembershipAuthority(address(auth));

        auth.setPermBool(creator, AccessV2PermKeys.DD_CREATE, true);
        uint256 idA = dd2.proposalsCount();
        vm.prank(creator);
        dd2.createProposal(bytes("p"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
        // voter active since before creation.
        auth.setKeyActive(voter, AccessV2PermKeys.DD_VOTE, dd2.proposalCreatedAt(idA));
        {
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            dd2.vote(idA, idx, w);
        }
        vm.warp(block.timestamp + 11 * 60);
        (uint256 winA, bool validA) = dd2.announceWinner(idA);

        assertEq(winL, winA, "winner idx differs");
        assertEq(validL, validA, "validity differs");
        assertTrue(validA);
    }

    /*───────────────────────── rollback to zero ─────────────────────────*/

    function testRollbackToZeroRestoresLegacy() public {
        _setAuthority(address(auth));
        assertEq(dd.membershipAuthority(), address(auth));

        // Rollback.
        _setAuthority(address(0));
        assertEq(dd.membershipAuthority(), address(0));

        // Legacy path is live again: hat-wearing creator + voter work without any authority perms.
        hats.mintHat(CREATOR_HAT, creator);
        hats.mintHat(VOTING_HAT, voter);
        uint256 id = _createUnrestricted(creator);
        _voteYes(voter, id);
        vm.warp(block.timestamp + 11 * 60);
        (, bool valid) = dd.announceWinner(id);
        assertTrue(valid);
    }
}
