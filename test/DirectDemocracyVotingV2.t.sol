// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;
import {MockModuleAuthority} from "./mocks/MockModuleAuthority.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

import "forge-std/Test.sol";
import "../src/DirectDemocracyVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract DDV2MockExecutor is IExecutor {
    function execute(uint256, Call[] calldata batch) external {
        for (uint256 i; i < batch.length; ++i) {
            (bool ok,) = batch[i].target.call{value: batch[i].value}(batch[i].data);
            require(ok, "DDV2MockExecutor: call failed");
        }
    }
}

/// @notice W3 coverage for DirectDemocracyVoting.createProposalV2 (quorum override, H-2) and the
///         scoped configAdmin surface. V1 behaviour must stay byte-identical.
contract DirectDemocracyVotingV2Test is Test {
    DirectDemocracyVoting dd;
    MockHats hats;
    DDV2MockExecutor exec;

    address creator = address(0x1);
    address configAdmin = address(0xC0FFEE);
    address rando = address(0xBAD);

    uint256 constant VOTING_HAT = 1;
    uint256 constant CREATOR_HAT = 2;
    uint256 constant NEW_VOTING_HAT = 42;
    address constant ALLOWED_TARGET = address(0xdead);

    event ProposalConfigV2(uint256 indexed id, uint32 quorumOverride, bool equalWeight);
    event ConfigAdminSet(address indexed admin);
    event HatSet(DirectDemocracyVoting.HatType hatType, uint256 hat, bool allowed);

    function setUp() public {
        hats = new MockHats();
        exec = new DDV2MockExecutor();

        hats.mintHat(VOTING_HAT, creator);
        hats.mintHat(CREATOR_HAT, creator);

        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory initialHats = new uint256[](1);
        initialHats[0] = VOTING_HAT;
        uint256[] memory initialCreatorHats = new uint256[](1);
        initialCreatorHats[0] = CREATOR_HAT;
        address[] memory targets = new address[](1);
        targets[0] = ALLOWED_TARGET;

        bytes memory data = abi.encodeCall(DirectDemocracyVoting.initialize, (address(exec), targets, 50, 0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        dd = DirectDemocracyVoting(address(proxy));
        MockModuleAuthority moduleAuthority = new MockModuleAuthority(address(hats), address(exec));
        moduleAuthority.setSubjects(AccessV2PermKeys.DD_CREATE, initialCreatorHats);
        moduleAuthority.setSubjects(AccessV2PermKeys.DD_VOTE, initialHats);
        vm.prank(address(exec));
        dd.setMembershipAuthority(address(moduleAuthority));
    }

    /* ─────────── helpers ─────────── */

    function _mintVoter(address who) internal {
        hats.mintHat(VOTING_HAT, who);
    }

    function _voter(uint256 n) internal returns (address who) {
        who = address(uint160(0x1000 + n));
        _mintVoter(who);
    }

    function _setGlobalQuorum(uint32 q) internal {
        vm.prank(address(exec));
        dd.setConfig(DirectDemocracyVoting.ConfigKey.QUORUM, abi.encode(q));
    }

    function _emptyBatches(uint8 opts) internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](opts);
        for (uint256 i; i < opts; ++i) {
            b[i] = new IExecutor.Call[](0);
        }
    }

    function _executableBatches(uint8 opts) internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](opts);
        b[0] = new IExecutor.Call[](1);
        b[0][0] = IExecutor.Call({target: ALLOWED_TARGET, value: 0, data: ""});
        for (uint256 i = 1; i < opts; ++i) {
            b[i] = new IExecutor.Call[](0);
        }
    }

    function _pollHats() internal pure returns (uint256[] memory h) {
        h = new uint256[](1);
        h[0] = VOTING_HAT; // poll hat == voting hat, so wearers pass both gates
    }

    function _voteYes(uint256 id, address who) internal {
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(who);
        dd.vote(id, idx, w);
    }

    /* ─────────────────────────────────────────────────────────────────────────
                                V1 REGRESSION
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice Legacy createProposal + vote + announce is unchanged; no override recorded.
    function testV1CreateVoteAnnounceUnchanged() public {
        vm.prank(creator);
        dd.createProposal(bytes("V1"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
        uint256 id = dd.proposalsCount() - 1;

        assertEq(dd.proposalQuorumOverride(id), 0, "V1 proposal has no override");
        assertFalse(dd.pollRestricted(id), "V1 unrestricted");

        _voteYes(id, creator);
        vm.warp(block.timestamp + 11 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid);
        assertEq(winner, 0);
    }

    /// @notice The legacy quorum path is untouched: global quorum still gates V1 proposals.
    function testV1GlobalQuorumStillEnforced() public {
        _setGlobalQuorum(3);
        vm.prank(creator);
        dd.createProposal(bytes("V1Q"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0));
        uint256 id = dd.proposalsCount() - 1;

        _voteYes(id, creator);
        vm.warp(block.timestamp + 11 minutes);
        (, bool valid) = dd.announceWinner(id);
        assertFalse(valid, "1 voter < global quorum 3");
    }

    /* ─────────────────────────────────────────────────────────────────────────
                                V2 GUARDS
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice Override on an UNRESTRICTED proposal reverts (must pass 0).
    function testV2UnrestrictedWithOverrideReverts() public {
        vm.prank(creator);
        vm.expectRevert(VotingErrors.InvalidQuorum.selector);
        dd.createProposalV2(bytes("bad"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0), 1);
    }

    /// @notice Unrestricted V2 with override 0 is allowed and behaves like V1 (no override).
    function testV2UnrestrictedNoOverrideOk() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit ProposalConfigV2(0, 0, false);
        dd.createProposalV2(bytes("ok"), bytes32(0), 10, 2, _emptyBatches(2), new uint256[](0), 0);
        assertEq(dd.proposalQuorumOverride(0), 0);
    }

    /// @notice V2 records the override and emits ProposalConfigV2 for a restricted poll.
    function testV2RecordsOverrideAndEmits() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit ProposalConfigV2(0, 7, false);
        dd.createProposalV2(bytes("poll"), bytes32(0), 10, 2, _emptyBatches(2), _pollHats(), 7);
        assertEq(dd.proposalQuorumOverride(0), 7);
        assertTrue(dd.pollRestricted(0));
    }

    /* ─────────────────────────────────────────────────────────────────────────
              H-2: EXECUTABLE restricted poll CANNOT lower quorum (max enforced)
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice The crit-security H-2 attack: a restricted executable poll tries to set a tiny
    ///         override to push a batch through with one voter. effectiveQuorum = max(global, 1)
    ///         keeps the global bar, so it stays invalid.
    function testH2ExecutableRestrictedCannotLowerQuorum() public {
        _setGlobalQuorum(3);

        vm.prank(creator);
        dd.createProposalV2(bytes("attack"), bytes32(0), 10, 2, _executableBatches(2), _pollHats(), 1);
        uint256 id = dd.proposalsCount() - 1;

        _voteYes(id, creator); // single captured voter
        vm.warp(block.timestamp + 11 minutes);
        (, bool valid) = dd.announceWinner(id);
        assertFalse(valid, "override cannot lower quorum on executable proposal");
    }

    /// @notice Override CAN raise quorum on an executable proposal (must clear the higher bar).
    function testH2ExecutableRestrictedOverrideRaises() public {
        _setGlobalQuorum(1);

        vm.prank(creator);
        dd.createProposalV2(bytes("raise"), bytes32(0), 10, 2, _executableBatches(2), _pollHats(), 3);
        uint256 id = dd.proposalsCount() - 1;

        // Only 2 voters — below the raised override of 3.
        _voteYes(id, creator);
        _voteYes(id, _voter(1));
        vm.warp(block.timestamp + 11 minutes);
        (, bool valid) = dd.announceWinner(id);
        assertFalse(valid, "2 voters < raised quorum 3");
    }

    /// @notice With enough voters the raised-quorum executable proposal passes and executes.
    function testH2ExecutableRestrictedRaisedQuorumMet() public {
        _setGlobalQuorum(1);

        vm.prank(creator);
        dd.createProposalV2(bytes("meet"), bytes32(0), 10, 2, _executableBatches(2), _pollHats(), 3);
        uint256 id = dd.proposalsCount() - 1;

        _voteYes(id, creator);
        _voteYes(id, _voter(1));
        _voteYes(id, _voter(2));
        vm.warp(block.timestamp + 11 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid, "3 voters == raised quorum 3");
        assertEq(winner, 0);
    }

    /* ─────────────────────────────────────────────────────────────────────────
              Signal (non-executable) poll MAY lower quorum; small group passes
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice A restricted signal poll (empty batches) may lower quorum below the global value;
    ///         a small group can pass it.
    function testSignalPollMayLowerQuorumAndPasses() public {
        _setGlobalQuorum(5);

        vm.prank(creator);
        dd.createProposalV2(bytes("signal"), bytes32(0), 10, 2, _emptyBatches(2), _pollHats(), 1);
        uint256 id = dd.proposalsCount() - 1;

        _voteYes(id, creator); // single voter, override = 1
        vm.warp(block.timestamp + 11 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid, "signal poll override lowers quorum to 1");
        assertEq(winner, 0);
    }

    /// @notice Same small group WITHOUT the override would fail the global quorum (contrast).
    function testSignalPollWithoutOverrideBlockedByGlobal() public {
        _setGlobalQuorum(5);

        vm.prank(creator);
        dd.createProposal(bytes("noOverride"), bytes32(0), 10, 2, _emptyBatches(2), _pollHats());
        uint256 id = dd.proposalsCount() - 1;

        _voteYes(id, creator);
        vm.warp(block.timestamp + 11 minutes);
        (, bool valid) = dd.announceWinner(id);
        assertFalse(valid, "no override => global quorum 5 applies");
    }

    /* ─────────────────────────────────────────────────────────────────────────
                                CONFIG ADMIN AUTH MATRIX
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice configAdmin may toggle voting/creator hats via setConfig(HAT_ALLOWED).

    /// @notice configAdmin CANNOT touch any other ConfigKey (executor-only).

    /// @notice A random address (not executor, not configAdmin) cannot set HAT_ALLOWED.

    /// @notice Executor still works on every key after a configAdmin is set (no regression).

    /* ─────────────────────────────────────────────────────────────────────────
                            STORAGE LAYOUT SAFETY
       ───────────────────────────────────────────────────────────────────────── */

    /// @notice Create legacy (V1) proposals first, then V2 proposals with overrides, and assert
    ///         the pre-existing proposals still read correctly — proving the side-mapping/configAdmin
    ///         appends did NOT change the Proposal array stride.
    function testStorageLayoutOldProposalsStillReadable() public {
        // Two V1 proposals.
        vm.prank(creator);
        dd.createProposal(bytes("old-0"), bytes32(0), 10, 3, _emptyBatches(3), new uint256[](0));
        vm.prank(creator);
        dd.createProposal(bytes("old-1"), bytes32(0), 20, 2, _emptyBatches(2), _pollHats());

        uint64 end0 = dd.proposalEndTimestamp(0);
        uint64 end1 = dd.proposalEndTimestamp(1);

        // Vote on proposal 0 before creating V2 proposals.
        _voteYes(0, creator);

        // Now V2 proposals carrying overrides in the new side mapping.
        vm.prank(creator);
        dd.createProposalV2(bytes("new-2"), bytes32(0), 10, 2, _emptyBatches(2), _pollHats(), 9);
        vm.prank(creator);
        dd.createProposalV2(bytes("new-3"), bytes32(0), 15, 2, _executableBatches(2), _pollHats(), 2);

        // Old proposals unchanged.
        assertEq(dd.proposalEndTimestamp(0), end0, "old p0 end intact");
        assertEq(dd.proposalEndTimestamp(1), end1, "old p1 end intact");
        assertEq(dd.proposalQuorumOverride(0), 0, "old p0 no override");
        assertEq(dd.proposalQuorumOverride(1), 0, "old p1 no override");
        assertFalse(dd.pollRestricted(0), "old p0 unrestricted");
        assertTrue(dd.pollRestricted(1), "old p1 restricted");

        // New proposals carry their overrides.
        assertEq(dd.proposalQuorumOverride(2), 9, "new p2 override");
        assertEq(dd.proposalQuorumOverride(3), 2, "new p3 override");

        // Old proposal 0 still finalizes correctly with its recorded vote.
        vm.warp(block.timestamp + 21 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(0);
        assertTrue(valid, "old p0 still finalizes");
        assertEq(winner, 0);
    }
}
