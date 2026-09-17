// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockModuleAuthority} from "./mocks/MockModuleAuthority.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {HybridVotingConfig} from "../src/libs/HybridVotingConfig.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExecutor} from "../src/Executor.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract HVV2MockExecutor is IExecutor {
    function execute(uint256, Call[] calldata) external {}
}

contract HVV2MockERC20 is IERC20 {
    string public name = "PT";
    string public symbol = "PT";
    uint8 public decimals = 18;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;

    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address, address, uint256) public pure returns (bool) {
        return false;
    }

    function approve(address, uint256) public pure returns (bool) {
        return false;
    }

    function allowance(address, address) public pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

    /// @notice W3 coverage for HybridVoting.createProposalV2 (quorum override + equalWeight), the
    ///         incremental class edits, and the scoped configAdmin surface. V1 stays byte-identical.
    contract HybridVotingV2Test is Test {
        HybridVoting hv;
        MockHats hats;
        HVV2MockExecutor exec;
        HVV2MockERC20 token;

        address creator = address(0xC1);
        address configAdmin = address(0xC0FFEE);
        address rando = address(0xBAD);

        // Voters — all wear MEMBER_HAT (also used as poll hat); wildly different token balances.
        address va = address(0xA1);
        address vb = address(0xA2);
        address vc = address(0xA3); // whale

        uint256 constant MEMBER_HAT = 1;
        uint256 constant CREATOR_HAT = 2;
        uint256 constant EXTRA_HAT = 3;

        event ConfigAdminSet(address indexed admin);
        event ClassHatSet(uint8 indexed classIdx, uint256 indexed hatId, bool added);
        event ProposalConfigV2(uint256 indexed id, uint32 quorumOverride, bool equalWeight);

        // Mirror of HybridVotingCore.VoteCast for log decoding.
        bytes32 constant VOTECAST_SIG = keccak256("VoteCast(uint256,address,uint8[],uint8[],uint256[],uint64)");

        function setUp() public {
            hats = new MockHats();
            exec = new HVV2MockExecutor();
            token = new HVV2MockERC20();

            hats.mintHat(CREATOR_HAT, creator);
            hats.mintHat(MEMBER_HAT, va);
            hats.mintHat(MEMBER_HAT, vb);
            hats.mintHat(MEMBER_HAT, vc);

            token.mint(va, 1e18);
            token.mint(vb, 1e18);
            token.mint(vc, 1_000_000e18); // whale

            uint256[] memory memberHats = new uint256[](1);
            memberHats[0] = MEMBER_HAT;
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT;

            // Org classes: DIRECT 50% + ERC20_BAL 50%, both gated on MEMBER_HAT.
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: memberHats
            });
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(token),
                hatIds: memberHats
            });

            HybridVoting impl = new HybridVoting();
            bytes memory data = abi.encodeCall(HybridVoting.initialize, (address(exec), uint8(50), uint32(0), classes));
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
            hv = HybridVoting(payable(address(proxy)));
            MockModuleAuthority moduleAuthority = new MockModuleAuthority(address(hats), address(exec));
            moduleAuthority.setSubjects(AccessV2PermKeys.HV_CREATE, creatorHats);
            vm.prank(address(exec));
            hv.setMembershipAuthority(address(moduleAuthority));
        }

        /* ─────────── helpers ─────────── */

        function _pollHats() internal pure returns (uint256[] memory h) {
            h = new uint256[](1);
            h[0] = MEMBER_HAT;
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
            b[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
            for (uint256 i = 1; i < opts; ++i) {
                b[i] = new IExecutor.Call[](0);
            }
        }

        function _setGlobalQuorum(uint32 q) internal {
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(q));
        }

        function _vote(uint256 id, address who, uint8 option) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = option;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(who);
            hv.vote(id, idx, w);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                                    V1 REGRESSION
           ───────────────────────────────────────────────────────────────────────── */

        function testV1CreateVoteAnnounceUnchanged() public {
            vm.prank(creator);
            hv.createProposal(bytes("V1"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));
            uint256 id = hv.proposalsCount() - 1;
            assertEq(hv.proposalQuorumOverride(id), 0, "no override on V1");
            assertFalse(hv.pollRestricted(id));

            _vote(id, va, 0);
            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid);
            assertEq(winner, 0);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                                    V2 GUARDS
           ───────────────────────────────────────────────────────────────────────── */

        function testV2UnrestrictedWithOverrideReverts() public {
            vm.prank(creator);
            vm.expectRevert(VotingErrors.InvalidQuorum.selector);
            hv.createProposalV2(bytes("x"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0), 1, false);
        }

        function testV2UnrestrictedWithEqualWeightReverts() public {
            vm.prank(creator);
            vm.expectRevert(VotingErrors.InvalidQuorum.selector);
            hv.createProposalV2(bytes("x"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0), 0, true);
        }

        function testV2RecordsOverrideAndEmits() public {
            vm.prank(creator);
            vm.expectEmit(true, true, true, true);
            emit ProposalConfigV2(0, 4, false);
            hv.createProposalV2(bytes("p"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 4, false);
            assertEq(hv.proposalQuorumOverride(0), 4);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                  H-2: EXECUTABLE restricted poll CANNOT lower quorum (max enforced)
           ───────────────────────────────────────────────────────────────────────── */

        function testH2ExecutableRestrictedCannotLowerQuorum() public {
            _setGlobalQuorum(3);
            vm.prank(creator);
            hv.createProposalV2(bytes("attack"), bytes32(0), 15, 2, _executableBatches(2), _pollHats(), 1, false);
            uint256 id = hv.proposalsCount() - 1;

            _vote(id, va, 0); // single voter
            vm.warp(block.timestamp + 16 minutes);
            (, bool valid) = hv.announceWinner(id);
            assertFalse(valid, "override cannot lower quorum on executable proposal");
        }

        function testH2ExecutableRestrictedRaisedQuorumMet() public {
            _setGlobalQuorum(1);
            vm.prank(creator);
            hv.createProposalV2(bytes("raise"), bytes32(0), 15, 2, _executableBatches(2), _pollHats(), 3, false);
            uint256 id = hv.proposalsCount() - 1;

            _vote(id, va, 0);
            _vote(id, vb, 0);
            vm.warp(block.timestamp + 16 minutes);
            (, bool valid) = hv.announceWinner(id);
            assertFalse(valid, "2 voters < raised quorum 3");

            // Fresh proposal with the third voter added meets the bar.
            vm.prank(creator);
            hv.createProposalV2(bytes("raise2"), bytes32(0), 15, 2, _executableBatches(2), _pollHats(), 3, false);
            uint256 id2 = hv.proposalsCount() - 1;
            _vote(id2, va, 0);
            _vote(id2, vb, 0);
            _vote(id2, vc, 0);
            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner2, bool valid2) = hv.announceWinner(id2);
            assertTrue(valid2, "3 voters == raised quorum 3");
            assertEq(winner2, 0);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                    Signal (non-executable) poll MAY lower quorum
           ───────────────────────────────────────────────────────────────────────── */

        function testSignalPollMayLowerQuorumAndPasses() public {
            _setGlobalQuorum(5);
            vm.prank(creator);
            hv.createProposalV2(bytes("signal"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 1, false);
            uint256 id = hv.proposalsCount() - 1;

            _vote(id, va, 0); // single voter, override 1
            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid, "signal poll override lowers quorum to 1");
            assertEq(winner, 0);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                  equalWeight = one-person-one-vote regardless of PT balances
           ───────────────────────────────────────────────────────────────────────── */

        /// @notice equalWeight snapshots a single DIRECT class; the whale (vc, 1e24 tokens) gets the
        ///         same 100 raw power as va/vb (1e18 tokens). The 2-vote majority (va,vb) beats the
        ///         whale's single vote.
        function testEqualWeightIsOnePersonOneVote() public {
            vm.prank(creator);
            hv.createProposalV2(bytes("eq"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 0, true);
            uint256 id = hv.proposalsCount() - 1;

            // Snapshot is exactly one synthetic DIRECT class {slicePct:100, hatIds:[MEMBER_HAT]}.
            HybridVoting.ClassConfig[] memory snap = hv.getProposalClasses(id);
            assertEq(snap.length, 1, "single synthetic class");
            assertEq(uint8(snap[0].strategy), uint8(HybridVoting.ClassStrategy.DIRECT), "DIRECT");
            assertEq(snap[0].slicePct, 100, "100% slice");
            assertEq(snap[0].hatIds.length, 1);
            assertEq(snap[0].hatIds[0], MEMBER_HAT);

            // Whale's raw power is exactly 100 (not scaled by balance) — decoded from VoteCast.
            vm.recordLogs();
            _vote(id, vc, 1); // whale votes option 1
            uint256 whalePower = _lastVoteCastFirstClassPower();
            assertEq(whalePower, 100, "whale power == 100 despite huge balance");

            _vote(id, va, 0);
            _vote(id, vb, 0);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid, "majority reached");
            assertEq(winner, 0, "2 members outvote the whale - token balance irrelevant");
        }

        /// @notice Control: WITHOUT equalWeight, the whale's ERC20 balance dominates the same vote
        ///         split (proving the equalWeight test above actually neutralised balances).
        function testControlWhaleDominatesWithoutEqualWeight() public {
            vm.prank(creator);
            hv.createProposal(bytes("ctrl"), bytes32(0), 15, 2, _emptyBatches(2), new uint256[](0));
            uint256 id = hv.proposalsCount() - 1;

            _vote(id, va, 0);
            _vote(id, vb, 0);
            _vote(id, vc, 1); // whale

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid);
            assertEq(winner, 1, "whale's ERC20 balance carries option 1 in the blended tally");
        }

        /// @notice A voter outside pollHatIds has zero power in an equalWeight poll (also fails the
        ///         restricted gate first — belt and suspenders).
        function testEqualWeightOutsiderHasNoPower() public {
            vm.prank(creator);
            hv.createProposalV2(bytes("eq"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 0, true);
            uint256 id = hv.proposalsCount() - 1;

            address outsider = address(0xDEAD01);
            token.mint(outsider, 5_000_000e18); // huge balance but no poll hat
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(outsider);
            vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
            hv.vote(id, idx, w);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                                INCREMENTAL CLASS EDITS
           ───────────────────────────────────────────────────────────────────────── */

        function testAddHatToClassByExecutor() public {
            vm.prank(address(exec));
            vm.expectEmit(true, true, true, true);
            emit ClassHatSet(0, EXTRA_HAT, true);
            hv.addHatToClass(0, EXTRA_HAT);

            HybridVoting.ClassConfig[] memory c = hv.getClasses();
            assertEq(c[0].hatIds.length, 2, "hat appended to class 0");
            assertEq(c[0].hatIds[1], EXTRA_HAT);
            // Slice percentages untouched.
            assertEq(c[0].slicePct, 50);
            assertEq(c[1].slicePct, 50);
        }

        function testAddHatToClassRandoReverts() public {
            vm.prank(rando);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.addHatToClass(0, EXTRA_HAT);
        }

        function testAddHatToClassOutOfBoundsReverts() public {
            vm.prank(address(exec));
            vm.expectRevert(VotingErrors.InvalidClassCount.selector);
            hv.addHatToClass(2, EXTRA_HAT); // only classes 0,1 exist
        }

        function testRemoveHatFromClass() public {
            vm.prank(address(exec));
            hv.addHatToClass(0, EXTRA_HAT);
            assertEq(hv.getClasses()[0].hatIds.length, 2);

            vm.prank(address(exec));
            vm.expectEmit(true, true, true, true);
            emit ClassHatSet(0, EXTRA_HAT, false);
            hv.removeHatFromClass(0, EXTRA_HAT);
            assertEq(hv.getClasses()[0].hatIds.length, 1, "hat removed");
            assertEq(hv.getClasses()[0].hatIds[0], MEMBER_HAT, "original hat retained");
        }

        function testRemoveHatFromClassRandoReverts() public {
            vm.prank(rando);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.removeHatFromClass(0, MEMBER_HAT);
        }

        function testRemoveHatFromClassOutOfBoundsReverts() public {
            vm.prank(address(exec));
            vm.expectRevert(VotingErrors.InvalidClassCount.selector);
            hv.removeHatFromClass(5, MEMBER_HAT);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                                CONFIG ADMIN AUTH MATRIX
           ───────────────────────────────────────────────────────────────────────── */

        function testSetClassesRandoReverts() public {
            HybridVoting.ClassConfig[] memory nc = new HybridVoting.ClassConfig[](1);
            uint256[] memory mh = new uint256[](1);
            mh[0] = MEMBER_HAT;
            nc[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 100,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: mh
            });
            vm.prank(rando);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.setClasses(nc);
        }

        /* ─────────────────────────────────────────────────────────────────────────
                                STORAGE LAYOUT SAFETY
           ───────────────────────────────────────────────────────────────────────── */

        function testStorageLayoutOldProposalsStillReadable() public {
            vm.prank(creator);
            hv.createProposal(bytes("old-0"), bytes32(0), 15, 3, _emptyBatches(3), new uint256[](0));
            vm.prank(creator);
            hv.createProposal(bytes("old-1"), bytes32(0), 20, 2, _emptyBatches(2), _pollHats());

            uint64 end0 = hv.proposalEndTimestamp(0);
            uint64 end1 = hv.proposalEndTimestamp(1);
            _vote(0, va, 0);

            // V2 proposals appending to the side mappings.
            vm.prank(creator);
            hv.createProposalV2(bytes("new-2"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 9, false);
            vm.prank(creator);
            hv.createProposalV2(bytes("new-3"), bytes32(0), 15, 2, _emptyBatches(2), _pollHats(), 0, true);

            assertEq(hv.proposalEndTimestamp(0), end0, "old p0 end intact");
            assertEq(hv.proposalEndTimestamp(1), end1, "old p1 end intact");
            assertEq(hv.proposalQuorumOverride(0), 0, "old p0 no override");
            assertEq(hv.proposalQuorumOverride(1), 0, "old p1 no override");
            assertFalse(hv.pollRestricted(0), "old p0 unrestricted");
            assertTrue(hv.pollRestricted(1), "old p1 restricted");
            assertEq(hv.proposalQuorumOverride(2), 9, "new p2 override");
            assertEq(hv.getProposalClasses(1).length, 2, "old p1 kept 2-class snapshot");
            assertEq(hv.getProposalClasses(3).length, 1, "equalWeight p3 has 1-class snapshot");

            vm.warp(block.timestamp + 21 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(0);
            assertTrue(valid, "old p0 still finalizes");
            assertEq(winner, 0);
        }

        /* ─────────── log decode ─────────── */

        function _lastVoteCastFirstClassPower() internal returns (uint256) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = logs.length; i > 0; --i) {
                Vm.Log memory log = logs[i - 1];
                if (log.topics.length > 0 && log.topics[0] == VOTECAST_SIG) {
                    (,, uint256[] memory classRawPowers,) = abi.decode(log.data, (uint8[], uint8[], uint256[], uint64));
                    return classRawPowers[0];
                }
            }
            revert("no VoteCast log");
        }
    }
