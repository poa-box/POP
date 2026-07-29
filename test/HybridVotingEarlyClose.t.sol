// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* forge-std helpers */
import "forge-std/Test.sol";

/* target */
import {HybridVoting} from "../src/HybridVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {HybridVotingProposals} from "../src/libs/HybridVotingProposals.sol";

/* OpenZeppelin */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IExecutor} from "../src/Executor.sol";
import {MockHats} from "./mocks/MockHats.sol";

/// MockERC20 + MockExecutor copied from HybridVoting.t.sol pattern; kept
/// separate so this test file compiles standalone.
contract MockERC20EC is IERC20 {
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

    contract MockExecutorEC is IExecutor {
        Call[] public lastBatch;
        uint256 public lastId;
        uint256 public callCount;

        function execute(uint256 id, Call[] calldata batch) external {
            lastId = id;
            callCount++;
            delete lastBatch;
            for (uint256 i; i < batch.length; ++i) {
                lastBatch.push(batch[i]);
            }
        }
    }

    /// Early-close integration tests. Group A uses the shared `hv` proxy from
    /// setUp; group B/C tests deploy fresh proxies via `_deploy` to vary config.
    contract HybridVotingEarlyCloseTest is Test {
        address owner = vm.addr(1);
        address alice = vm.addr(2);
        address bob = vm.addr(3);
        address carol = vm.addr(4);

        MockERC20EC token;
        MockHats hats;
        MockExecutorEC exec;
        HybridVoting hv;

        uint256 constant DEFAULT_HAT_ID = 1;
        uint256 constant EXECUTIVE_HAT_ID = 2;
        uint256 constant CREATOR_HAT_ID = 3;

        function setUp() public {
            token = new MockERC20EC();
            hats = new MockHats();
            exec = new MockExecutorEC();

            // 3 voters all wearing creator + executive + default hats.
            hats.mintHat(DEFAULT_HAT_ID, alice);
            hats.mintHat(EXECUTIVE_HAT_ID, alice);
            hats.mintHat(CREATOR_HAT_ID, alice);
            hats.mintHat(DEFAULT_HAT_ID, bob);
            hats.mintHat(EXECUTIVE_HAT_ID, bob);
            hats.mintHat(CREATOR_HAT_ID, bob);
            hats.mintHat(DEFAULT_HAT_ID, carol);
            hats.mintHat(EXECUTIVE_HAT_ID, carol);
            hats.mintHat(CREATOR_HAT_ID, carol);

            token.mint(alice, 100e18);
            token.mint(bob, 100e18);
            token.mint(carol, 100e18);

            uint256[] memory votingHats = new uint256[](2);
            votingHats[0] = DEFAULT_HAT_ID;
            votingHats[1] = EXECUTIVE_HAT_ID;
            uint256[] memory democracyHats = new uint256[](1);
            democracyHats[0] = EXECUTIVE_HAT_ID;
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT_ID;
            address[] memory targets = new address[](1);
            targets[0] = address(0xCA11);

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: democracyHats
            });
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: votingHats
            });

            bytes memory initData = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), creatorHats, targets, uint8(50), uint8(50), classes)
            );

            HybridVoting impl = new HybridVoting();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
            BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
            hv = HybridVoting(payable(address(proxy)));
        }

        function _names() internal pure returns (string[] memory n) {
            n = new string[](2);
            n[0] = "YES";
            n[1] = "NO";
        }

        function _emptyBatches() internal pure returns (IExecutor.Call[][] memory b) {
            b = new IExecutor.Call[][](2);
            b[0] = new IExecutor.Call[](0);
            b[1] = new IExecutor.Call[](0);
        }

        function _voteYes(address voter) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            hv.vote(0, idx, w);
        }

        function _voteNo(address voter) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = 1;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            hv.vote(0, idx, w);
        }

        function _createDefault() internal {
            bytes memory title = "Async-Majority Test";
            vm.prank(alice);
            hv.createProposal(title, bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));
        }

        function _createWithHint(uint64 callerHint) internal {
            bytes memory title = "Async-Majority With Hint";
            vm.prank(alice);
            hv.createProposalWithEligibleSnapshot(
                title, bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), callerHint
            );
        }

        // Opt out of early-close via the snapshot sentinel.
        function _createLegacyTimerOnly() internal {
            vm.prank(alice);
            hv.createProposalWithEligibleSnapshot(
                "Legacy Timer Only", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), type(uint64).max
            );
        }

        /* ─── Scenario 1: threshold met + majority → early-close fires ─── */

        function test_EarlyClose_thresholdMet_majorityWinning_announceSucceedsBeforeTimer() public {
            _createDefault();
            // 3 eligible voters; ceil(3/2)=2 threshold. 2 of 3 vote YES = majority.
            _voteYes(alice);
            _voteYes(bob);
            // Timer is 60 minutes; we're at t=0
            // Without early-close this would revert VotingOpen.
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertEq(win, 0); // YES option index
            assertTrue(ok); // valid winner
        }

        /* ─── Scenario 2: threshold not met → reverts VotingOpen ─── */

        function test_EarlyClose_thresholdNotMet_revertsVotingOpen() public {
            _createDefault();
            // Only 1 of 3 voted; ceil(3/2)=2 not met
            _voteYes(alice);
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);
        }

        /* ─── Scenario 3: threshold met but tied → gate fires; announceWinner returns invalid ─── */

        function test_EarlyClose_thresholdMetButTied_announceReturnsInvalid() public {
            _createDefault();
            // 2 of 3 vote split 1-1 between YES and NO
            _voteYes(alice);
            _voteNo(bob);
            assertTrue(hv.isEarlyCloseEligible(0), "turnout-only gate fires regardless of tie");
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertFalse(ok, "announceWinner returns invalid for tied score");
            assertEq(win, 0);
        }

        /* ─── Scenario 4: callerHint=0 (default path) uses on-chain truth ─── */

        function test_EarlyClose_callerHintZero_usesOnChainTruth() public {
            _createDefault(); // back-compat path passes callerHint=0
            // On-chain truth from creatorHatIds=[CREATOR_HAT_ID] sums hatSupply
            // alice+bob+carol all wear CREATOR_HAT_ID = 3. Threshold ceil(3/2)=2.
            _voteYes(alice);
            _voteYes(bob);
            // Should be early-close eligible (threshold + majority both met)
            assertTrue(hv.isEarlyCloseEligible(0));
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertEq(win, 0);
            assertTrue(ok);
        }

        /* ─── Scenario 5: callerHint > onChainTruth → caller honored ─── */

        function test_EarlyClose_callerHintExceedsOnChainTruth_callerHonored() public {
            // On-chain truth = 3 (3 creator-hat wearers). Caller passes 10.
            _createWithHint(10);
            // Threshold = ceil(10/2) = 5. Only 3 voters exist; threshold uncrossable.
            _voteYes(alice);
            _voteYes(bob);
            _voteYes(carol);
            // All 3 voted but threshold is 5 → not early-close eligible
            assertFalse(hv.isEarlyCloseEligible(0));
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);
        }

        /* ─── Scenario 6: callerHint < onChainTruth → contract overrides (Q1 SAFETY FIX) ─── */

        function test_EarlyClose_callerHintBelowOnChainTruth_contractOverrides() public {
            // On-chain truth = 3 (3 creator-hat wearers). Caller passes 1 (ATTEMPTED UNDER-COUNT).
            _createWithHint(1);
            // If caller hint were honored, threshold would be ceil(1/2)=1; single voter would early-close.
            // BUT contract enforces max(1, 3) = 3 → threshold ceil(3/2) = 2.
            _voteYes(alice);
            // 1 of 3 voted; threshold 2 not met
            assertFalse(hv.isEarlyCloseEligible(0));
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);
        }

        /* ─── Scenario 7: callerHint == max → opt-out timer-only ─── */

        function test_EarlyClose_legacyTimerOnly_optOut_neverEligible() public {
            _createLegacyTimerOnly();
            // All 3 vote unanimously YES — would normally early-close
            _voteYes(alice);
            _voteYes(bob);
            _voteYes(carol);
            // But snapshotEligibleVoters = type(uint64).max → not eligible
            assertFalse(hv.isEarlyCloseEligible(0));
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);
        }

        /* ─── Scenario 8: snapshotEligibleVoters == 0 (legacy back-compat) → timer-only ─── */

        /// Zero snapshot (legacy zero-init) must short-circuit the gate.
        function test_EarlyClose_legacyBackCompat_zeroSnapshot_timerOnly() public {
            _createDefault();
            _voteYes(alice);
            _voteYes(bob);
            _voteYes(carol);

            // Sanity: as-created with on-chain snapshot, the proposal IS eligible.
            assertTrue(hv.isEarlyCloseEligible(0));

            // Locate the storage slot holding (executed | voterCount | snapshotEligibleVoters).
            // ERC-7201 layout slot for `poa.hybridvoting.v2.storage`. The Layout
            // struct's `_proposals` array starts at a deterministic offset; for
            // proposal index 0, the slot containing the post-classesSnapshot
            // packed fields is computed below. We rely on the fact that all
            // earlier struct fields use full slots or dynamic-array-headers,
            // so the (bool executed, uint32 voterCount, uint64 snapshotEligibleVoters)
            // group lands together.
            //
            // To avoid fragility we lookup via probe: read each candidate slot,
            // find the one whose lowest-72-bits encodes our known voterCount=3
            // followed by our known snapshotEligibleVoters=3. Then zero the
            // snapshotEligibleVoters portion (high 64 bits of that 72-bit window).
            bytes32 storageSlot = keccak256("poa.hybridvoting.v2.storage");
            // _proposals is the 7th element in Layout (slot offset 6):
            // hats(0) executor(1) allowedTarget-mapping(2) creatorHatIds-len(3)
            // thresholdPct(4) classes-len(5) _proposals-len(6)
            bytes32 proposalsArrayLengthSlot = bytes32(uint256(storageSlot) + 6);
            // Element 0 of the dynamic Proposal[] starts at keccak256(slot 6).
            bytes32 proposal0Base = keccak256(abi.encode(proposalsArrayLengthSlot));
            // Walk the next ~12 slots looking for the packed (executed,voterCount,snapshotEligibleVoters)
            // storage word. Match on voterCount=3 + snapshotEligibleVoters=3 packed.
            bytes32 zeroSnapshot = bytes32(0); // we'll write this if the slot matches
            bool found;
            for (uint256 offset; offset < 16; ++offset) {
                bytes32 slot = bytes32(uint256(proposal0Base) + offset);
                uint256 raw = uint256(vm.load(address(hv), slot));
                // Layout in the packed slot (bool executed, uint32 voterCount, uint64 snapshotEligibleVoters):
                //   executed at bits 0:8 (1 byte), voterCount at 8:40 (4 bytes), snapshot at 40:104 (8 bytes).
                uint8 executedBit = uint8(raw & 0xFF);
                uint32 vCount = uint32((raw >> 8) & 0xFFFFFFFF);
                uint64 snap = uint64((raw >> 40) & 0xFFFFFFFFFFFFFFFF);
                if (executedBit == 0 && vCount == 3 && snap == 3) {
                    // Zero the snapshot portion (clear bits 40:104).
                    uint256 mask = ~(uint256(0xFFFFFFFFFFFFFFFF) << 40);
                    uint256 newRaw = raw & mask;
                    vm.store(address(hv), slot, bytes32(newRaw));
                    found = true;
                    break;
                }
            }
            assertTrue(found, "could not locate packed (executed,voterCount,snapshot) slot");

            // Now the gate must fire: snapshotEligibleVoters == 0 → not eligible.
            assertFalse(hv.isEarlyCloseEligible(0));
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);

            // After timer expires the legacy timer path still works.
            vm.warp(block.timestamp + 60 * 60 + 1);
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertEq(win, 0);
            assertTrue(ok);
            zeroSnapshot; // silence unused warning if any
        }

        /* ─── Additional robustness scenarios ─── */

        /// Restricted proposals snapshot from pollHatIds, not creatorHatIds.
        function test_EarlyClose_restrictedPoll_snapshotFromPollHatIds() public {
            // Add a 4th wearer to the DEFAULT_HAT_ID so creator and poll counts diverge:
            // - creatorHatIds = [CREATOR_HAT_ID]; supply = 3 (alice/bob/carol)
            // - pollHatIds (passed at create) = [DEFAULT_HAT_ID]; supply = 4 after we add dave
            address dave = vm.addr(99);
            hats.mintHat(DEFAULT_HAT_ID, dave);
            // dave doesn't get the EXECUTIVE_HAT_ID so they have no DD power, but
            // we don't actually have them vote — we only need their hat to bump
            // pollHatId supply.

            uint256[] memory pollHats = new uint256[](1);
            pollHats[0] = DEFAULT_HAT_ID;
            vm.prank(alice);
            hv.createProposal("Restricted Poll", bytes32(0), 60, 2, _emptyBatches(), pollHats);

            // Snapshot should be 4 (DEFAULT_HAT_ID supply), not 3 (CREATOR_HAT_ID).
            // Threshold = ceil(4/2) = 2.
            _voteYes(alice);
            // 1 voter; threshold 2 not met
            assertFalse(hv.isEarlyCloseEligible(0));
            _voteYes(bob);
            // 2 voters; threshold met + 100% YES
            assertTrue(hv.isEarlyCloseEligible(0));
        }

        function test_EarlyClose_thresholdBoundary_evenEligibleSet() public {
            // 4 eligible via callerHint (skipping on-chain since fleet is 3)
            _createWithHint(4);
            _voteYes(alice);
            _voteYes(bob);
            // 2 of 4; ceil(4/2)=2 met. Both YES → 100% > 50% strict majority.
            assertTrue(hv.isEarlyCloseEligible(0));
        }

        function test_EarlyClose_thresholdBoundary_oddEligibleSet() public {
            _createWithHint(5);
            _voteYes(alice);
            _voteYes(bob);
            // 2 of 5; ceil(5/2)=3 not met
            assertFalse(hv.isEarlyCloseEligible(0));
            _voteYes(carol);
            // 3 of 5; threshold met + unanimous → eligible
            assertTrue(hv.isEarlyCloseEligible(0));
        }

        function test_EarlyClose_strictMajority_narrowWinPasses() public {
            _createDefault();
            // Vote weights: alice 60% YES / 40% NO; bob 60% YES / 40% NO
            // Carol abstains. 2 of 3 voters meets threshold; YES leads strictly.
            uint8[] memory idx = new uint8[](2);
            idx[0] = 0;
            idx[1] = 1;
            uint8[] memory w = new uint8[](2);
            w[0] = 60;
            w[1] = 40;
            vm.prank(alice);
            hv.vote(0, idx, w);
            vm.prank(bob);
            hv.vote(0, idx, w);
            assertTrue(hv.isEarlyCloseEligible(0));
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertEq(win, 0); // YES wins
            assertTrue(ok);
        }

        /// Overlapping-hat over-count raises (not lowers) the threshold.
        function test_EarlyClose_overlappingHats_overcountIsSafeDirection() public {
            // Use callerHint=0 so contract uses on-chain truth across creatorHatIds=[CREATOR_HAT_ID].
            // alice/bob/carol each wear CREATOR_HAT_ID → supply=3 → threshold=2.
            _createDefault();
            _voteYes(alice);
            _voteYes(bob);
            // 2 voters meets threshold; unanimous YES; eligible.
            assertTrue(hv.isEarlyCloseEligible(0));

            // Now create a proposal restricted to BOTH default and executive hats.
            // alice/bob/carol all wear both → snapshot is 3 + 3 = 6 (overlapping
            // double-count). Threshold = ceil(6/2) = 3.
            uint256[] memory pollHats = new uint256[](2);
            pollHats[0] = DEFAULT_HAT_ID;
            pollHats[1] = EXECUTIVE_HAT_ID;
            vm.prank(alice);
            hv.createProposal("Multi-hat Poll", bytes32(0), 60, 2, _emptyBatches(), pollHats);
            // Vote on the SECOND proposal (id=1)
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(alice);
            hv.vote(1, idx, w);
            vm.prank(bob);
            hv.vote(1, idx, w);
            // 2 voters, but threshold is 3 (because of double-count) → NOT eligible
            assertFalse(hv.isEarlyCloseEligible(1));
        }

        /* ─── Scenario sanity: timer-only path still works for new proposals after timer expires ─── */

        function test_EarlyClose_timerExpiry_legacyPathStillWorks() public {
            _createLegacyTimerOnly(); // explicit timer-only
            _voteYes(alice);
            _voteYes(bob);
            _voteYes(carol);
            // Before timer: should revert
            assertFalse(hv.isEarlyCloseEligible(0));
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hv.announceWinner(0);

            // After timer expires: should succeed (timer path, regardless of snapshot)
            vm.warp(block.timestamp + 60 * 60 + 1);
            (uint256 win, bool ok) = hv.announceWinner(0);
            assertEq(win, 0);
            assertTrue(ok);
        }

        /* ──────────────────────────────────────────────────────────────────
         * Group B: Supplementary coverage. These tests deploy fresh HybridVoting
         * proxies with custom slice/threshold/quorum config rather than using
         * the shared `hv` instance from setUp.
         * ────────────────────────────────────────────────────────────────── */

        address constant DAVE = address(uint160(uint256(keccak256("dave"))));

        function _deploy(uint8 ddSlice, uint8 ercSlice, uint8 thresholdPct_, uint32 quorum_)
            internal
            returns (HybridVoting hvOut)
        {
            return _deployWithTurnout(ddSlice, ercSlice, thresholdPct_, 50, quorum_);
        }

        /// `_deploy` wraps with earlyCloseTurnoutPct=50 (matches pre-redesign turnout floor).
        function _deployWithTurnout(
            uint8 ddSlice,
            uint8 ercSlice,
            uint8 thresholdPct_,
            uint8 earlyCloseTurnoutPct_,
            uint32 quorum_
        ) internal returns (HybridVoting hvOut) {
            uint256[] memory votingHats = new uint256[](2);
            votingHats[0] = DEFAULT_HAT_ID;
            votingHats[1] = EXECUTIVE_HAT_ID;
            uint256[] memory democracyHats = new uint256[](1);
            democracyHats[0] = EXECUTIVE_HAT_ID;
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT_ID;
            address[] memory targets = new address[](1);
            targets[0] = address(0xCA11);

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: ddSlice,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: democracyHats
            });
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: ercSlice,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: votingHats
            });

            bytes memory initData = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), creatorHats, targets, thresholdPct_, earlyCloseTurnoutPct_, classes)
            );

            HybridVoting impl = new HybridVoting();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
            BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
            hvOut = HybridVoting(payable(address(proxy)));

            if (quorum_ > 0) {
                vm.prank(address(exec));
                hvOut.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(quorum_));
            }
        }

        function _emptyBatches3() internal pure returns (IExecutor.Call[][] memory b) {
            b = new IExecutor.Call[][](3);
            b[0] = new IExecutor.Call[](0);
            b[1] = new IExecutor.Call[](0);
            b[2] = new IExecutor.Call[](0);
        }

        function _voteOn(HybridVoting target, address voter, uint256 id, uint8 option) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = option;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            target.vote(id, idx, w);
        }

        function _voteWeighted(
            HybridVoting target,
            address voter,
            uint256 id,
            uint8[] memory idxs,
            uint8[] memory weights
        ) internal {
            vm.prank(voter);
            target.vote(id, idxs, weights);
        }

        /* ─── Slice-weighted gate predicts the same winner announceWinner picks ─── */

        /// Turnout-only gate fires once threshold met; whale-vs-DD outcome
        /// is decided by announceWinner's slice-weighted pickWinnerNSlices.
        function test_EarlyClose_sliceWeightedGate_predictsAnnounceWinner() public {
            HybridVoting hvCustom = _deploy(90, 10, 50, 0);

            // Carol becomes a 100x token whale.
            token.mint(carol, 9900e18);

            vm.prank(alice);
            hvCustom.createProposal("Slice Divergence", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0); // YES
            _voteOn(hvCustom, bob, 0, 0); // YES
            _voteOn(hvCustom, carol, 0, 1); // NO (whale)

            // Slice-weighted math:
            //   DD (90%): YES 200/300, NO 100/300 → YES contribution 60%, NO 30%
            //   ERC20 (10%): YES 2e22/1.02e24 ≈ 0.02, NO ≈ 0.98 → YES ~0.2%, NO ~9.8%
            //   YES total ≈ 60.2%, NO ≈ 39.8% → YES wins
            // hi = ~602000 (PRECISION-scaled), totalScore = 1000000
            // strictMajority: 1204000 > 1000000 → TRUE
            // thresholdMet: 602000 >= 500000 → TRUE
            // strictMargin: 602000 > 398000 → TRUE → gate fires for YES

            assertTrue(hvCustom.isEarlyCloseEligible(0), "gate fires (slice-weighted YES strict majority)");

            (uint256 win, bool ok) = hvCustom.announceWinner(0);
            assertTrue(ok);
            assertEq(win, 0, "announceWinner picks YES (same as gate predicts)");
        }

        /* ─── 3-option equal split: gate fires (turnout met); announceWinner returns invalid ─── */

        function test_EarlyClose_threeOptionEqualSplit_gateFires_announceInvalid() public {
            HybridVoting hvCustom = _deploy(90, 10, 50, 0);

            vm.prank(alice);
            hvCustom.createProposal("3-way", bytes32(0), 60, 3, _emptyBatches3(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 1);
            _voteOn(hvCustom, carol, 0, 2);

            // 3 of 3 voted at 50% turnout floor → gate fires.
            assertTrue(hvCustom.isEarlyCloseEligible(0));
            (uint256 win, bool ok) = hvCustom.announceWinner(0);
            assertFalse(ok, "tied 3-way split -> announceWinner invalid");
            assertEq(win, 0);
        }

        /* ─── Pause blocks announceWinner even when gate is eligible ─── */

        function test_EarlyClose_pausedBlocksAnnounce() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            vm.prank(alice);
            hvCustom.createProposal("Pause Test", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0));

            vm.prank(address(exec));
            hvCustom.pause();

            vm.expectRevert(VotingErrors.Paused.selector);
            hvCustom.announceWinner(0);
        }

        /* ─── Snapshot is frozen at create-time; mid-vote hat mints don't shift it ─── */

        function test_EarlyClose_snapshotFrozenAtCreateTime() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            // Snapshot uses creatorHatIds (3 wearers) → threshold = ceil(3/2) = 2.
            vm.prank(alice);
            hvCustom.createProposal("Drift Test", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            // Mid-vote: mint 3 more creator hats. Actual eligibility is now 6.
            hats.mintHat(CREATOR_HAT_ID, DAVE);
            hats.mintHat(CREATOR_HAT_ID, vm.addr(6));
            hats.mintHat(CREATOR_HAT_ID, vm.addr(7));

            // 2 of the original 3 vote unanimously.
            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);

            // Gate fires based on snapshot (3), not current supply (6).
            assertTrue(hvCustom.isEarlyCloseEligible(0));
        }

        /* ─── Gate refuses when quorum is unmet (new behavior) ─── */

        function test_EarlyClose_quorumUnmet_gateRefuses() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 10); // quorum=10

            vm.prank(alice);
            hvCustom.createProposal("Quorum Block", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);

            // Snapshot eligibility threshold met (2 ≥ ceil(3/2)=2) but quorum (10) is not.
            assertFalse(hvCustom.isEarlyCloseEligible(0), "gate refuses when quorum unmet");
            vm.expectRevert(VotingErrors.VotingOpen.selector);
            hvCustom.announceWinner(0);
        }

        /* ─── Gate is transient: a subsequent vote can flip eligibility ─── */

        function test_EarlyClose_gateTransient_subsequentVoteDoesntFlip() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            vm.prank(alice);
            hvCustom.createProposalWithEligibleSnapshot(
                "Transient", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 4
            );

            // max(callerHint=4, onChainSum=3) = 4 → threshold ceil(4/2)=2.
            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "after 2 YES, gate eligible");

            // Carol votes NO. YES still strict majority slice-weighted (~66.6% > 50%).
            _voteOn(hvCustom, carol, 0, 1);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "YES still strict majority");
        }

        function test_EarlyClose_gateStaysEligibleOnTie_announceInvalidates() public {
            hats.setHatWearerStatus(CREATOR_HAT_ID, carol, false, false);

            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            vm.prank(alice);
            hvCustom.createProposal("Tie Flip", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "1 voter, threshold 1, unanimous");

            _voteOn(hvCustom, bob, 0, 1);
            // New turnout-only gate keeps firing — score doesn't matter at the gate.
            assertTrue(hvCustom.isEarlyCloseEligible(0), "turnout already reached");

            (, bool ok) = hvCustom.announceWinner(0);
            assertFalse(ok, "tied score -> announce returns invalid");
        }

        /* ─── Early-close path executes batches via executor ─── */

        function test_EarlyClose_executesBatchViaExecutor() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](1);
            batches[0][0] = IExecutor.Call({target: address(0xBEEF), value: 0, data: hex"1234"});
            batches[1] = new IExecutor.Call[](0);

            vm.prank(alice);
            hvCustom.createProposal("Batch Exec", bytes32(0), 60, 2, batches, new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);

            uint256 callsBefore = exec.callCount();
            (uint256 win, bool ok) = hvCustom.announceWinner(0);
            assertTrue(ok);
            assertEq(win, 0);
            assertEq(exec.callCount(), callsBefore + 1, "executor.execute() invoked on early-close path");
        }

        /* ─── Threshold = 1: single-voter org early-closes on first vote ─── */

        function test_EarlyClose_thresholdOne_firstVoteTriggers() public {
            hats.setHatWearerStatus(CREATOR_HAT_ID, bob, false, false);
            hats.setHatWearerStatus(CREATOR_HAT_ID, carol, false, false);

            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            vm.prank(alice);
            hvCustom.createProposal("Single Voter", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            assertFalse(hvCustom.isEarlyCloseEligible(0), "pre-vote: not eligible");

            _voteOn(hvCustom, alice, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "1 voter on threshold=1 with unanimous YES");

            (uint256 win, bool ok) = hvCustom.announceWinner(0);
            assertTrue(ok);
            assertEq(win, 0);
        }

        /* ─── callerHint == onChainSum boundary ─── */

        function test_EarlyClose_callerHintEqualsOnChainTruth() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);

            vm.prank(alice);
            hvCustom.createProposalWithEligibleSnapshot(
                "Boundary", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 3
            );

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0));
        }

        /* ─── isEarlyCloseEligible safely returns false for out-of-range IDs ─── */

        function test_EarlyClose_isEarlyCloseEligible_outOfRangeIdSafe() public {
            HybridVoting hvCustom = _deploy(50, 50, 50, 0);
            assertFalse(hvCustom.isEarlyCloseEligible(0));
            assertFalse(hvCustom.isEarlyCloseEligible(999_999));
        }

        /* ─── Empty creatorHats + unrestricted + callerHint=0 → silently timer-only ─── */

        function test_EarlyClose_emptyCreatorHatsUnrestricted_timerOnly() public {
            uint256[] memory votingHats = new uint256[](2);
            votingHats[0] = DEFAULT_HAT_ID;
            votingHats[1] = EXECUTIVE_HAT_ID;
            uint256[] memory democracyHats = new uint256[](1);
            democracyHats[0] = EXECUTIVE_HAT_ID;
            uint256[] memory emptyCreatorHats = new uint256[](0);
            address[] memory targets = new address[](1);
            targets[0] = address(0xCA11);

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: democracyHats
            });
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: votingHats
            });

            bytes memory initData = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), emptyCreatorHats, targets, uint8(50), uint8(100), classes)
            );

            HybridVoting impl = new HybridVoting();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
            BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
            HybridVoting hvCustom = HybridVoting(payable(address(proxy)));

            vm.prank(address(exec));
            hvCustom.createProposal("Empty Creators", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            _voteOn(hvCustom, bob, 0, 0);
            _voteOn(hvCustom, carol, 0, 0);

            assertFalse(hvCustom.isEarlyCloseEligible(0), "empty creator hats + hint=0 -> snapshot=0 -> timer-only");
        }

        /* ──────────────────────────────────────────────────────────────────
         * Group C: Configurable turnout-percent gate (the new design).
         * ────────────────────────────────────────────────────────────────── */

        function test_EarlyClose_turnoutPct100_requiresFullTurnout() public {
            HybridVoting hvCustom = _deployWithTurnout(50, 50, 50, 100, 0);

            vm.prank(alice);
            hvCustom.createProposal("Full Turnout", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            _voteOn(hvCustom, alice, 0, 0);
            assertFalse(hvCustom.isEarlyCloseEligible(0), "1 of 3 not enough at pct=100");
            _voteOn(hvCustom, bob, 0, 0);
            assertFalse(hvCustom.isEarlyCloseEligible(0), "2 of 3 not enough at pct=100");
            _voteOn(hvCustom, carol, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "3 of 3 -> gate fires");
        }

        function test_EarlyClose_turnoutPct51_fires_onMajorityTurnout() public {
            HybridVoting hvCustom = _deployWithTurnout(50, 50, 50, 51, 0);

            vm.prank(alice);
            hvCustom.createProposal("Majority Turnout", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));

            // ceil(3 × 51 / 100) = ceil(1.53) = 2 → 2 voters trigger the gate.
            _voteOn(hvCustom, alice, 0, 0);
            assertFalse(hvCustom.isEarlyCloseEligible(0));
            _voteOn(hvCustom, bob, 0, 0);
            assertTrue(hvCustom.isEarlyCloseEligible(0), "2 of 3 >= ceil(3*51/100)");
        }

        function test_EarlyClose_setConfigUpdatesTurnoutPct() public {
            assertEq(hv.earlyCloseTurnoutPct(), 50, "setUp uses 50");

            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.EARLY_CLOSE_TURNOUT_PCT, abi.encode(uint8(75)));

            assertEq(hv.earlyCloseTurnoutPct(), 75, "executor updated to 75");
        }

        function test_EarlyClose_setConfigRejectsInvalidPct() public {
            vm.startPrank(address(exec));

            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            hv.setConfig(HybridVoting.ConfigKey.EARLY_CLOSE_TURNOUT_PCT, abi.encode(uint8(0)));

            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            hv.setConfig(HybridVoting.ConfigKey.EARLY_CLOSE_TURNOUT_PCT, abi.encode(uint8(101)));

            vm.stopPrank();
        }

        function test_EarlyClose_setConfigOnlyExecutor() public {
            vm.prank(alice);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.setConfig(HybridVoting.ConfigKey.EARLY_CLOSE_TURNOUT_PCT, abi.encode(uint8(75)));
        }

        function test_EarlyClose_perProposalOverride_ratchetsUp() public {
            // Org default 50; override to 100 for a sensitive proposal.
            vm.prank(alice);
            hv.createProposalWithTurnoutPct("Sensitive", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 100);

            assertEq(hv.proposalTurnoutPct(0), 100, "proposal pct = 100");

            // Org default 50% would trigger at 2 voters; override 100 requires 3.
            _voteYes(alice);
            _voteYes(bob);
            assertFalse(hv.isEarlyCloseEligible(0), "2 of 3 below override 100%");
            _voteYes(carol);
            assertTrue(hv.isEarlyCloseEligible(0), "3 of 3 meets override 100%");
        }

        function test_EarlyClose_overrideRejectedBelowOrgDefault() public {
            // Org default 50; trying override=30 must revert.
            vm.prank(alice);
            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            hv.createProposalWithTurnoutPct("Too Low", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 30);
        }

        function test_EarlyClose_overrideRejectedAbove100() public {
            vm.prank(alice);
            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            hv.createProposalWithTurnoutPct("Too High", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 101);
        }

        event ProposalEarlyCloseConfig(
            uint256 indexed id, uint64 snapshotEligibleVoters, uint8 turnoutPctOverride, bool isTimerOnly
        );

        function test_EarlyClose_eventEmittedOnCreateProposal() public {
            vm.expectEmit(true, false, false, true);
            // alice/bob/carol all wear CREATOR_HAT_ID, so the snapshot is 3.
            emit ProposalEarlyCloseConfig(0, 3, 0, false);
            _createDefault();
        }

        function test_EarlyClose_eventEmittedOnWithEligibleSnapshot() public {
            // Caller hint 10 > onChainSum 3 → snapshot becomes 10.
            vm.expectEmit(true, false, false, true);
            emit ProposalEarlyCloseConfig(0, 10, 0, false);
            _createWithHint(10);
        }

        function test_EarlyClose_eventEmittedOnLegacyTimerOnly() public {
            vm.expectEmit(true, false, false, true);
            emit ProposalEarlyCloseConfig(0, type(uint64).max, 0, true);
            _createLegacyTimerOnly();
        }

        function test_EarlyClose_eventEmittedOnWithTurnoutPct() public {
            // Org default = 50 (from setUp); override to 75.
            vm.expectEmit(true, false, false, true);
            emit ProposalEarlyCloseConfig(0, 3, 75, false);
            vm.prank(alice);
            hv.createProposalWithTurnoutPct("With Override", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 75);
        }

        function test_EarlyClose_overrideEqualsOrgDefault_ok() public {
            HybridVoting hvCustom = _deployWithTurnout(50, 50, 50, 100, 0);

            vm.prank(alice);
            hvCustom.createProposalWithTurnoutPct("Equal", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0), 100);
            assertEq(hvCustom.proposalTurnoutPct(0), 100);
        }

        function test_EarlyClose_initializeRejectsInvalidPct() public {
            address[] memory targets = new address[](0);
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT_ID;
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
            uint256[] memory democracyHats = new uint256[](1);
            democracyHats[0] = EXECUTIVE_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 100,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: democracyHats
            });

            HybridVoting impl = new HybridVoting();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);

            bytes memory badZero = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), creatorHats, targets, uint8(50), uint8(0), classes)
            );
            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            new BeaconProxy(address(beacon), badZero);

            bytes memory bad101 = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), creatorHats, targets, uint8(50), uint8(101), classes)
            );
            vm.expectRevert(VotingErrors.InvalidTurnoutPct.selector);
            new BeaconProxy(address(beacon), bad101);
        }

        /// Happy-path scenarios where gate fires AND announceWinner returns valid.
        function test_EarlyClose_gateMatchesAnnounceWinnerInvariant() public {
            // Scenario 1: balanced 50/50 slices, 2 of 3 vote YES.
            HybridVoting hvA = _deploy(50, 50, 50, 0);
            vm.prank(alice);
            hvA.createProposal("Inv 1", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));
            _voteOn(hvA, alice, 0, 0);
            _voteOn(hvA, bob, 0, 0);
            assertTrue(hvA.isEarlyCloseEligible(0));
            (uint256 winA, bool okA) = hvA.announceWinner(0);
            assertTrue(okA);
            assertEq(winA, 0);

            // Scenario 2: skewed 90/10 slices with a token whale.
            HybridVoting hvB = _deploy(90, 10, 50, 0);
            token.mint(alice, 1000e18); // alice is now a whale; alice's class shares dominate
            vm.prank(alice);
            hvB.createProposal("Inv 2", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));
            _voteOn(hvB, alice, 0, 0);
            _voteOn(hvB, bob, 0, 0);
            assertTrue(hvB.isEarlyCloseEligible(0));
            (uint256 winB, bool okB) = hvB.announceWinner(0);
            assertTrue(okB);
            assertEq(winB, 0);

            // Scenario 3: 70/30 slices, unanimous YES.
            HybridVoting hvC = _deploy(70, 30, 50, 0);
            vm.prank(alice);
            hvC.createProposal("Inv 3", bytes32(0), 60, 2, _emptyBatches(), new uint256[](0));
            _voteOn(hvC, alice, 0, 0);
            _voteOn(hvC, bob, 0, 0);
            _voteOn(hvC, carol, 0, 0);
            assertTrue(hvC.isEarlyCloseEligible(0));
            (uint256 winC, bool okC) = hvC.announceWinner(0);
            assertTrue(okC);
            assertEq(winC, 0);
        }
    }
