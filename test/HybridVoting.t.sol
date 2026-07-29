// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.20;

/* forge‑std helpers */
import "forge-std/Test.sol";

/* target */
import {HybridVoting} from "../src/HybridVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {HybridVotingProposals} from "../src/libs/HybridVotingProposals.sol";
import {HybridVotingConfig} from "../src/libs/HybridVotingConfig.sol";
import {ValidationLib} from "../src/libs/ValidationLib.sol";

/* OpenZeppelin */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IExecutor} from "../src/Executor.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {console2} from "forge-std/console2.sol";

/* ───────────── Local lightweight mocks ───────────── */
contract MockERC20 is IERC20 {
    string public name = "ParticipationToken";
    string public symbol = "PTKN";
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

    /* mint helper for tests */
    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

    contract MockExecutor is IExecutor {
        event Executed(uint256 id, Call[] batch);

        Call[] public lastBatch;
        uint256 public lastId;

        function execute(uint256 id, Call[] calldata batch) external {
            lastId = id;
            delete lastBatch;
            for (uint256 i; i < batch.length; ++i) {
                lastBatch.push(batch[i]);
            }
            emit Executed(id, batch);
        }
    }

    /* ────────────────────────────────   TEST  ──────────────────────────────── */
    contract HybridVotingTest is Test {
        event ProposalExecutionFailed(uint256 indexed id, uint256 indexed winningIdx, bytes reason);
        /* actors */
        address owner = vm.addr(1);
        address alice = vm.addr(2); // has executive hat (voting + DD power), some tokens
        address bob = vm.addr(3); // has default hat (voting only, no DD power), many tokens
        address carol = vm.addr(4); // has executive hat (voting + DD power), tokens
        address nonExecutor = vm.addr(5); // someone without executor access

        /* contracts */
        MockERC20 token;
        MockHats hats;
        MockExecutor exec;
        HybridVoting hv;

        /* hat constants */
        uint256 constant DEFAULT_HAT_ID = 1;
        uint256 constant EXECUTIVE_HAT_ID = 2;
        uint256 constant CREATOR_HAT_ID = 3;

        /* ────────── set‑up ────────── */
        function setUp() public {
            token = new MockERC20();
            hats = new MockHats();
            exec = new MockExecutor();

            /* give hats */
            hats.mintHat(DEFAULT_HAT_ID, alice);
            hats.mintHat(EXECUTIVE_HAT_ID, alice);
            hats.mintHat(CREATOR_HAT_ID, alice);
            hats.mintHat(DEFAULT_HAT_ID, bob); // Bob gets voting permission but no DD power
            hats.mintHat(DEFAULT_HAT_ID, carol);
            hats.mintHat(EXECUTIVE_HAT_ID, carol);
            hats.mintHat(CREATOR_HAT_ID, carol);

            /* mint tokens (18 dec) - adjust balances to make sure YES wins */
            token.mint(bob, 400e18); // reduce bob's tokens
            token.mint(alice, 400e18); // increase alice's balance
            token.mint(carol, 600e18); // increase carol's balance

            /* prepare allowed hats/targets for init */
            uint256[] memory votingHats = new uint256[](2);
            votingHats[0] = DEFAULT_HAT_ID;
            votingHats[1] = EXECUTIVE_HAT_ID;

            uint256[] memory democracyHats = new uint256[](1);
            democracyHats[0] = EXECUTIVE_HAT_ID; // Only EXECUTIVE hat gets DD power

            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT_ID;

            address[] memory targets = new address[](1);
            targets[0] = address(0xCA11); // random allowed call target

            // Build ClassConfig array for hybrid voting
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);

            // Class 0: Direct Democracy (50%)
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: democracyHats
            });

            // Class 1: Participation Token (50%)
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
                (
                    address(hats), // hats
                    address(exec), // executor
                    creatorHats, // allowed creator hats
                    targets, // allowed target(s)
                    uint8(50), // threshold %
                    uint8(50), // earlyCloseTurnoutPct (matches pre-redesign ceil(N/2) behavior)
                    classes // class configurations
                )
            );

            HybridVoting impl = new HybridVoting();

            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
            BeaconProxy proxy = new BeaconProxy(address(beacon), initData);

            hv = HybridVoting(payable(address(proxy)));
            vm.label(address(hv), "HybridVoting");
        }

        /* ───────────────────────── CREATE PROPOSAL ───────────────────────── */

        function _defaultNames() internal pure returns (string[] memory n) {
            n = new string[](2);
            n[0] = "YES";
            n[1] = "NO";
        }

        function testCreateProposalEmptyBatches() public {
            vm.startPrank(alice);

            /* build empty 2‑option batches */
            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](1);
            batches[1] = new IExecutor.Call[](1);

            batches[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
            batches[1][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});

            bytes memory title = bytes("Test Proposal");
            bytes32 descriptionHash = bytes32(0);
            uint256[] memory hatIds = new uint256[](0);
            hv.createProposal(title, descriptionHash, 30, 2, batches, hatIds);

            vm.stopPrank();

            assertEq(hv.proposalsCount(), 1, "should store proposal");
        }

        function testCreateProposalUnauthorized() public {
            // Bob has no creator hat, should fail
            vm.startPrank(bob);

            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](0);
            batches[1] = new IExecutor.Call[](0);

            bytes memory title = bytes("Test Proposal");
            bytes32 descriptionHash = bytes32(0);
            uint256[] memory hatIds = new uint256[](0);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.createProposal(title, descriptionHash, 30, 2, batches, hatIds);

            vm.stopPrank();
        }

        /* ───────────────────────── VOTING paths ───────────────────────── */

        function _create() internal returns (uint256) {
            /* anyone with creator hat */
            vm.startPrank(alice);

            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](1);
            batches[1] = new IExecutor.Call[](1);

            batches[0][0] = IExecutor.Call({
                target: address(0xCA11), // Use the same target that was allowed during initialization
                value: 0,
                data: ""
            });

            batches[1][0] = IExecutor.Call({
                target: address(0xCA11), // Use the same target that was allowed during initialization
                value: 0,
                data: ""
            });

            bytes memory title = bytes("Test Proposal");
            bytes32 descriptionHash = bytes32(0);
            uint256[] memory hatIds = new uint256[](0);
            hv.createProposal(title, descriptionHash, 15, 2, batches, hatIds);
            vm.stopPrank();
            return hv.proposalsCount() - 1;
        }

        function _createHatPoll(uint8 opts, uint256[] memory hatIds) internal returns (uint256) {
            vm.prank(alice);
            IExecutor.Call[][] memory batches = new IExecutor.Call[][](0);
            hv.createProposal(bytes("Test Hat Poll"), bytes32(0), 15, opts, batches, hatIds);
            return hv.proposalsCount() - 1;
        }

        function _voteYES(address voter) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            hv.vote(0, idx, w);
        }

        function testDDOnlyWeight() public {
            _create();
            /* bob has voting hat but no DD hat => can vote but only contributes PT power */
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(bob);
            hv.vote(0, idx, w); // should succeed because bob has voting hat, but no DD power
            /* bob contributes only PT power (400e18 tokens), no DD power */
        }

        function testVoteUnauthorized() public {
            _create();

            // Create a voter with no hats and insufficient tokens
            address poorVoter = vm.addr(10);
            token.mint(poorVoter, 0.5 ether); // Below minimum balance

            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;

            // Voter with zero power across all classes is rejected to prevent quorum inflation
            vm.prank(poorVoter);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.vote(0, idx, w);
        }

        function testBlendAndExecution() public {
            // Create the proposal first
            uint256 id = _create();

            // The quadratic flag is already set during initialization for this test
            // or we could update it before creating the proposal

            /* YES votes: Alice and Carol (both have DD power) */
            _voteYES(alice);
            _voteYES(carol);

            /* NO vote: Bob (has voting permission but no DD power, only PT power) */
            uint8[] memory idx = new uint8[](1);
            idx[0] = 1;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(bob);
            hv.vote(id, idx, w); // should succeed with PT power only

            /* advance time, finalise */
            vm.warp(block.timestamp + 16 minutes);
            vm.prank(alice);
            (uint256 win, bool ok) = hv.announceWinner(id);

            assertTrue(ok, "threshold not met");
            assertEq(win, 0, "YES should win");

            /* executor should be called with the winning option's batch */
            assertEq(exec.lastId(), id, "executor should be called with correct id");
        }

        /* ───────────────────────── PAUSE / CLEANUP ───────────────────────── */
        function testPauseUnpause() public {
            vm.prank(address(exec));
            hv.pause();

            // Try to create proposal while paused - should revert
            vm.startPrank(alice);
            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](1);
            batches[1] = new IExecutor.Call[](1);
            batches[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
            batches[1][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});

            uint256[] memory hatIds = new uint256[](0);
            vm.expectRevert(VotingErrors.Paused.selector);
            hv.createProposal(bytes("Test Proposal"), bytes32(0), 15, 2, batches, hatIds);
            vm.stopPrank();

            // Unpause and try again
            vm.prank(address(exec));
            hv.unpause();

            // Now it should work
            _create();
        }

        /* ───────────────────────── HAT MANAGEMENT TESTS ───────────────────────── */
        function testSetHatAllowed() public {
            // This test now validates class configuration updates
            vm.prank(address(exec));

            // Create new classes without DEFAULT_HAT_ID
            HybridVoting.ClassConfig[] memory newClasses = new HybridVoting.ClassConfig[](2);

            uint256[] memory executiveOnly = new uint256[](1);
            executiveOnly[0] = EXECUTIVE_HAT_ID;

            newClasses[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: executiveOnly
            });

            newClasses[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: executiveOnly
            });

            hv.setClasses(newClasses);

            // Create proposal with new classes
            uint256 proposalId = _create();

            // Alice with EXECUTIVE hat can vote
            vm.prank(alice);
            uint8[] memory aliceIdx = new uint8[](1);
            aliceIdx[0] = 0;
            uint8[] memory aliceW = new uint8[](1);
            aliceW[0] = 100;
            hv.vote(proposalId, aliceIdx, aliceW);

            // Create a new voter with only DEFAULT_HAT_ID
            address hatOnlyVoter = vm.addr(15);
            hats.mintHat(DEFAULT_HAT_ID, hatOnlyVoter);
            token.mint(hatOnlyVoter, 0.5 ether);

            uint8[] memory idx = new uint8[](1);
            idx[0] = 1;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;

            // Zero-power voter is rejected to prevent quorum inflation via Sybil
            vm.prank(hatOnlyVoter);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.vote(proposalId, idx, w);
        }

        function testSetCreatorHatAllowed() public {
            // Test that executor can modify creator hat permissions
            uint256 newCreatorHat = 99;
            address newCreator = vm.addr(20);

            // Give new creator the new hat
            hats.mintHat(newCreatorHat, newCreator);

            // Enable new hat as creator hat
            vm.prank(address(exec));
            hv.setCreatorHatAllowed(newCreatorHat, true);

            // New creator should be able to create proposal
            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](0);
            batches[1] = new IExecutor.Call[](0);

            vm.prank(newCreator);
            uint256[] memory hatIds = new uint256[](0);
            hv.createProposal(bytes("Test Proposal"), bytes32(0), 15, 2, batches, hatIds);
            assertEq(hv.proposalsCount(), 1);

            // Disable new hat
            vm.prank(address(exec));
            hv.setCreatorHatAllowed(newCreatorHat, false);

            // Should now fail
            vm.prank(newCreator);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.createProposal(bytes("Test Proposal 2"), bytes32(0), 15, 2, batches, hatIds);
        }

        /* ───────────────────────── UNAUTHORIZED ACCESS TESTS ───────────────────────── */
        function testOnlyExecutorRevertWhenNonExecutorCallsAdminFunctions() public {
            // Test that non-executors cannot call admin functions
            vm.startPrank(nonExecutor);

            // Pause
            vm.expectRevert();
            hv.pause();

            // Set executor
            vm.expectRevert();
            hv.setConfig(HybridVoting.ConfigKey.EXECUTOR, abi.encode(nonExecutor));

            // Set creator hat allowed
            vm.expectRevert();
            hv.setCreatorHatAllowed(CREATOR_HAT_ID, false);

            // Set target allowed
            vm.expectRevert();
            hv.setConfig(HybridVoting.ConfigKey.TARGET_ALLOWED, abi.encode(address(0xDEAD), true));

            // Set threshold
            vm.expectRevert();
            hv.setConfig(HybridVoting.ConfigKey.THRESHOLD, abi.encode(60));

            // Split, quadratic, and min balance are now configured via setClasses
            // These legacy config options no longer exist

            vm.stopPrank();
        }

        function testExecutorCanCallAdminFunctions() public {
            // Test that executor can call admin functions
            vm.startPrank(address(exec));

            // Set threshold
            hv.setConfig(HybridVoting.ConfigKey.THRESHOLD, abi.encode(60));
            assertEq(hv.thresholdPct(), 60);

            // Split, quadratic, and min balance are now configured via setClasses
            // Test class configuration update instead
            HybridVoting.ClassConfig[] memory newClasses = hv.getClasses();
            newClasses[0].slicePct = 60;
            newClasses[1].slicePct = 40;
            newClasses[1].quadratic = true;
            newClasses[1].minBalance = 2 ether;
            hv.setClasses(newClasses);

            // Verify the changes
            HybridVoting.ClassConfig[] memory updatedClasses = hv.getClasses();
            assertEq(updatedClasses[0].slicePct, 60);
            assertEq(updatedClasses[1].slicePct, 40);
            assertEq(updatedClasses[1].quadratic, true);
            assertEq(updatedClasses[1].minBalance, 2 ether);

            vm.stopPrank();
        }

        function testExecutorTransfer() public {
            // Test transfer of executor role
            address newExecutor = vm.addr(6);

            // Set new executor
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.EXECUTOR, abi.encode(newExecutor));

            // Old executor should no longer have permissions
            vm.prank(address(exec));
            vm.expectRevert();
            hv.setConfig(HybridVoting.ConfigKey.THRESHOLD, abi.encode(70));

            // New executor should have permissions
            vm.prank(newExecutor);
            hv.setConfig(HybridVoting.ConfigKey.THRESHOLD, abi.encode(70));
            assertEq(hv.thresholdPct(), 70);
        }

        // function testCleanup() public {
        //     _create();
        //     _voteYES(alice);
        //     address[] memory voters = new address[](1);
        //     voters[0] = alice;
        //     /* warp */
        //     vm.warp(block.timestamp + 20 minutes);
        //     hv.cleanupProposal(0, voters);
        // }

        function testSpecialCase() public {
            // This test verifies the difference between voting hats and democracy hats
            // and creates a perfect tie scenario with 50-50 hybrid split

            // 1. Setup specific test actors
            address votingOnlyUser = vm.addr(40); // Has voting hat but no democracy hat
            address democracyUser = vm.addr(41); // Has democracy hat but insufficient tokens

            // 2. Give hats
            hats.mintHat(DEFAULT_HAT_ID, votingOnlyUser); // Voting permission only
            hats.mintHat(EXECUTIVE_HAT_ID, democracyUser); // Both voting and DD power

            // 3. Give tokens to create perfect tie scenario
            // votingOnlyUser: only PT power (gets 100% of PT slice = 50% total)
            token.mint(votingOnlyUser, 100 ether);
            // democracyUser: only DD power (gets 100% of DD slice = 50% total)
            token.mint(democracyUser, 0.5 ether); // Below MIN_BAL, so no PT power

            // 4. Create a test proposal
            uint256 id = _create();

            // 5. Both users vote
            uint8[] memory idxYes = new uint8[](1);
            idxYes[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;

            // votingOnlyUser votes YES (only PT power: 50% of total)
            vm.prank(votingOnlyUser);
            hv.vote(id, idxYes, w);

            // democracyUser votes NO (only DD power: 50% of total)
            uint8[] memory idxNo = new uint8[](1);
            idxNo[0] = 1;

            vm.prank(democracyUser);
            hv.vote(id, idxNo, w);

            // 6. Advance time and check results
            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool valid) = hv.announceWinner(id);

            // 7. Should be invalid due to perfect tie (50-50 split)
            assertFalse(valid, "Should be invalid due to perfect tie");
        }

        function testCreateHatPoll() public {
            uint256[] memory hatIds = new uint256[](1);
            hatIds[0] = EXECUTIVE_HAT_ID;

            // Expect the NewHatProposal event to be emitted
            vm.expectEmit(true, true, true, true);
            emit HybridVotingProposals.NewHatProposal(
                0,
                bytes("Test Hat Poll"),
                bytes32(0),
                2,
                uint64(block.timestamp + 15 minutes),
                uint64(block.timestamp),
                hatIds
            );

            uint256 id = _createHatPoll(2, hatIds);
            assertTrue(hv.pollRestricted(id));
            assertTrue(hv.pollHatAllowed(id, EXECUTIVE_HAT_ID));
            assertFalse(hv.pollHatAllowed(id, DEFAULT_HAT_ID));
        }

        function testHatPollRestrictions() public {
            // Create a different hat for the poll
            uint256 POLL_HAT_ID = 99;
            hats.createHat(POLL_HAT_ID, "Poll Hat", type(uint32).max, address(0), address(0), true, "");

            uint256[] memory hatIds = new uint256[](1);
            hatIds[0] = POLL_HAT_ID;
            uint256 id = _createHatPoll(2, hatIds);
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;

            // First test: voter with valid hat but not the specific poll hat should get RoleNotAllowed
            vm.prank(alice);
            vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
            hv.vote(id, idx, w);

            // Second test: voter with correct hat should succeed
            hats.mintHat(POLL_HAT_ID, alice);
            vm.prank(alice);
            hv.vote(id, idx, w);
        }

        function testHatPollUnrestricted() public {
            // Empty hat IDs should create unrestricted poll
            uint256[] memory hatIds = new uint256[](0);
            uint256 id = _createHatPoll(1, hatIds);
            assertFalse(hv.pollRestricted(id));

            // Anyone with voting hat should be able to vote
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(alice);
            hv.vote(id, idx, w);
        }

        /* ───────────────────────── N-CLASS VOTING TESTS ───────────────────────── */

        function testNClassConfiguration() public {
            vm.startPrank(address(exec));

            // Create a 3-class configuration
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](3);

            // Class 0: Direct Democracy (30%)
            uint256[] memory ddHats = new uint256[](1);
            ddHats[0] = EXECUTIVE_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 30,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: ddHats
            });

            // Class 1: Token holders (50%)
            uint256[] memory tokenHats = new uint256[](1);
            tokenHats[0] = DEFAULT_HAT_ID;
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: tokenHats
            });

            // Class 2: Service providers (20%)
            uint256[] memory serviceHats = new uint256[](1);
            serviceHats[0] = CREATOR_HAT_ID;
            classes[2] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 20,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: serviceHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            // Verify classes were set
            HybridVoting.ClassConfig[] memory stored = hv.getClasses();
            assertEq(stored.length, 3, "Should have 3 classes");
            assertEq(uint8(stored[0].strategy), uint8(HybridVoting.ClassStrategy.DIRECT), "Class 0 should be DIRECT");
            assertEq(stored[0].slicePct, 30, "Class 0 should be 30%");
            assertEq(stored[1].slicePct, 50, "Class 1 should be 50%");
            assertEq(stored[2].slicePct, 20, "Class 2 should be 20%");
        }

        function testNClassInvalidConfiguration() public {
            vm.startPrank(address(exec));

            // Test: slices don't sum to 100
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            uint256[] memory hats = new uint256[](0);

            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 40,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: hats
            });

            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50, // Total would be 90, not 100
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: hats
            });

            vm.expectRevert(VotingErrors.InvalidSliceSum.selector);
            hv.setClasses(classes);

            // Test: too many classes
            HybridVoting.ClassConfig[] memory tooMany = new HybridVoting.ClassConfig[](9);
            for (uint256 i = 0; i < 9; i++) {
                tooMany[i] = HybridVoting.ClassConfig({
                    strategy: HybridVoting.ClassStrategy.DIRECT,
                    slicePct: i == 0 ? 100 : 0,
                    quadratic: false,
                    minBalance: 0,
                    asset: address(0),
                    hatIds: hats
                });
            }

            vm.expectRevert(VotingErrors.TooManyClasses.selector);
            hv.setClasses(tooMany);

            vm.stopPrank();
        }

        function testNClassVoting() public {
            // Set up 2-class configuration (reproducing legacy hybrid)
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);

            // Class 0: Direct Democracy (50%)
            uint256[] memory ddHats = new uint256[](1);
            ddHats[0] = EXECUTIVE_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: ddHats
            });

            // Class 1: Token holders (50%)
            uint256[] memory tokenHats = new uint256[](2);
            tokenHats[0] = DEFAULT_HAT_ID;
            tokenHats[1] = EXECUTIVE_HAT_ID;
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: true, // Enable quadratic for token class
                minBalance: 1 ether,
                asset: address(token),
                hatIds: tokenHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            // Create proposal
            uint256 id = _create();

            // Vote with alice (has both DD and token power)
            _voteYES(alice);

            // Vote with bob (only token power, no DD)
            uint8[] memory idx = new uint8[](1);
            idx[0] = 1; // Vote NO
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(bob);
            hv.vote(id, idx, w);

            // Vote with carol (has both DD and token power)
            _voteYES(carol);

            // Advance time and announce winner
            vm.warp(block.timestamp + 16 minutes);
            vm.prank(alice);
            (uint256 win, bool ok) = hv.announceWinner(id);

            assertTrue(ok, "Threshold should be met");
            assertEq(win, 0, "YES should win");
        }

        function testNClassProposalSnapshot() public {
            // Set initial configuration
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes1 = new HybridVoting.ClassConfig[](1);
            uint256[] memory hats = new uint256[](0);
            classes1[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 100,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: hats
            });
            hv.setClasses(classes1);
            vm.stopPrank();

            // Create proposal with first configuration
            uint256 id1 = _create();

            // Change configuration
            vm.startPrank(address(exec));
            HybridVoting.ClassConfig[] memory classes2 = new HybridVoting.ClassConfig[](2);
            classes2[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 60,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: hats
            });
            classes2[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 40,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: hats
            });
            hv.setClasses(classes2);
            vm.stopPrank();

            // Create proposal with second configuration
            uint256 id2 = _create();

            // Verify proposals have different snapshots
            HybridVoting.ClassConfig[] memory snap1 = hv.getProposalClasses(id1);
            HybridVoting.ClassConfig[] memory snap2 = hv.getProposalClasses(id2);

            assertEq(snap1.length, 1, "First proposal should have 1 class");
            assertEq(snap2.length, 2, "Second proposal should have 2 classes");
            assertEq(snap1[0].slicePct, 100, "First proposal class should be 100%");
            assertEq(snap2[0].slicePct, 60, "Second proposal first class should be 60%");
        }

        function testNClass3ClassVoting() public {
            // Test 3-class voting: Core Team (30%), Token Holders (50%), Community (20%)
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](3);

            // Class 0: Core Team - DIRECT voting (30%)
            uint256[] memory coreHats = new uint256[](1);
            coreHats[0] = EXECUTIVE_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 30,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: coreHats
            });

            // Class 1: Token Holders - Token weighted (50%)
            uint256[] memory tokenHats = new uint256[](1);
            tokenHats[0] = DEFAULT_HAT_ID;
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: tokenHats
            });

            // Class 2: Community - DIRECT voting (20%)
            uint256[] memory communityHats = new uint256[](1);
            communityHats[0] = CREATOR_HAT_ID;
            classes[2] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 20,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: communityHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            // Create proposal
            uint256 id = _create();

            // Vote with different class members
            // Alice: has EXECUTIVE_HAT (Core Team - 30% slice)
            _voteYES(alice);

            // Bob: has DEFAULT_HAT and tokens (Token Holder - 50% slice)
            uint8[] memory idx = new uint8[](1);
            idx[0] = 1; // Vote NO
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(bob);
            hv.vote(id, idx, w);

            // Carol: has EXECUTIVE_HAT and tokens (participates in both Core and Token classes)
            _voteYES(carol);

            // Dave (creator): has CREATOR_HAT (Community - 20% slice)
            address dave = vm.addr(50);
            hats.mintHat(CREATOR_HAT_ID, dave);
            vm.prank(dave);
            hv.vote(id, idx, w); // Vote NO

            // Advance time and check winner
            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool ok) = hv.announceWinner(id);

            assertTrue(ok, "Should meet threshold");
            // YES votes: alice (30% of 30% = 9%), carol (30% of 30% + her token share of 50%)
            // NO votes: bob (his token share of 50%), dave (100% of 20% = 20%)
            // Winner depends on token distribution
        }

        function testNClass4ClassVoting() public {
            // Test 4-class voting with different strategies
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](4);
            uint256[] memory emptyHats = new uint256[](0);

            // Class 0: Founders - DIRECT (25%)
            uint256[] memory founderHats = new uint256[](1);
            founderHats[0] = EXECUTIVE_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 25,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: founderHats
            });

            // Class 1: Large Token Holders - Quadratic (35%)
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 35,
                quadratic: true, // Quadratic to reduce whale influence
                minBalance: 10 ether,
                asset: address(token),
                hatIds: emptyHats // Anyone with enough tokens
            });

            // Class 2: Small Token Holders - Linear (25%)
            classes[2] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 25,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: emptyHats
            });

            // Class 3: Service Providers - DIRECT (15%)
            uint256[] memory serviceHats = new uint256[](1);
            serviceHats[0] = CREATOR_HAT_ID;
            classes[3] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 15,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: serviceHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            // Create proposal
            uint256 id = _create();

            // Create voters with different profiles
            address whale = vm.addr(60);
            token.mint(whale, 1000 ether); // Large holder

            address smallHolder1 = vm.addr(61);
            token.mint(smallHolder1, 5 ether); // Small holder

            address smallHolder2 = vm.addr(62);
            token.mint(smallHolder2, 3 ether); // Small holder

            // Vote
            _voteYES(alice); // Founder vote

            vm.prank(whale);
            uint8[] memory yesVote = new uint8[](1);
            yesVote[0] = 0;
            uint8[] memory weight = new uint8[](1);
            weight[0] = 100;
            hv.vote(id, yesVote, weight);

            vm.prank(smallHolder1);
            uint8[] memory noVote = new uint8[](1);
            noVote[0] = 1;
            hv.vote(id, noVote, weight);

            vm.prank(smallHolder2);
            hv.vote(id, noVote, weight);

            // Check results
            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool ok) = hv.announceWinner(id);
            assertTrue(ok, "Should meet threshold");
        }

        function testNClassThresholdCalculation() public {
            // Test that threshold is calculated correctly across all classes
            vm.startPrank(address(exec));

            // Set up 2-class system with 40% threshold requirement
            hv.setConfig(HybridVoting.ConfigKey.THRESHOLD, abi.encode(40));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            uint256[] memory emptyHats = new uint256[](0);

            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 60,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: emptyHats
            });

            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 40,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: emptyHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            // Create proposal
            uint256 id = _create();

            // Single voter with minimal participation
            address voter = vm.addr(70);
            token.mint(voter, 100 ether);

            vm.prank(voter);
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            hv.vote(id, idx, w);

            // Should meet threshold with significant participation in token class
            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool ok) = hv.announceWinner(id);

            // With only one voter in token class (40% of total), should meet 40% threshold
            assertTrue(ok, "Should meet threshold with 40% participation");
        }

        function testNClassZeroBalanceVoters() public {
            // Test voters with zero balance in token classes
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            uint256[] memory emptyHats = new uint256[](0);

            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 50,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: emptyHats
            });

            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: emptyHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            uint256 id = _create();

            // Voter with no tokens (below minBalance)
            address poorVoter = vm.addr(80);
            token.mint(poorVoter, 0.5 ether); // Below 1 ether minimum

            vm.prank(poorVoter);
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            hv.vote(id, idx, w);

            // Vote succeeds but with 0 power in both classes
            // (no hat for DIRECT, below minBalance for TOKEN)

            // Another voter with actual power
            address richVoter = vm.addr(81);
            token.mint(richVoter, 100 ether);

            vm.prank(richVoter);
            hv.vote(id, idx, w);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool ok) = hv.announceWinner(id);

            assertEq(win, 0, "Option 0 should win");
            assertTrue(ok, "Should meet threshold from rich voter");
        }

        function testNClassMixedQuadraticLinear() public {
            // Test mixed quadratic and linear voting in different classes
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](2);
            uint256[] memory emptyHats = new uint256[](0);

            // Linear token voting (50%)
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: false, // Linear
                minBalance: 1 ether,
                asset: address(token),
                hatIds: emptyHats
            });

            // Quadratic token voting (50%)
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: true, // Quadratic
                minBalance: 1 ether,
                asset: address(token),
                hatIds: emptyHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            uint256 id = _create();

            // Whale voter
            address whale = vm.addr(90);
            token.mint(whale, 10000 ether);

            // Small voters
            address small1 = vm.addr(91);
            token.mint(small1, 100 ether);

            address small2 = vm.addr(92);
            token.mint(small2, 100 ether);

            // Whale votes YES
            vm.prank(whale);
            uint8[] memory yesIdx = new uint8[](1);
            yesIdx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            hv.vote(id, yesIdx, w);

            // Small voters vote NO
            vm.prank(small1);
            uint8[] memory noIdx = new uint8[](1);
            noIdx[0] = 1;
            hv.vote(id, noIdx, w);

            vm.prank(small2);
            hv.vote(id, noIdx, w);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 win,) = hv.announceWinner(id);

            // Whale has huge advantage in linear class but less in quadratic
            // Linear: whale gets 10000, smalls get 200 total
            // Quadratic: whale gets sqrt(10000)=100, smalls get 2*sqrt(100)=20
            assertEq(win, 0, "Whale should still win despite quadratic dampening");
        }

        function testNClassAllClassesRequired() public {
            // Test that proposal fails if no classes are configured
            vm.startPrank(alice);

            // Try to create proposal without classes configured (should revert)
            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](1);
            batches[1] = new IExecutor.Call[](1);
            batches[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
            batches[1][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});

            // This should revert because no classes are set after initialization
            // (initialization sets up default classes from legacy parameters)
            // So let's first clear the classes
            vm.stopPrank();
            vm.startPrank(address(exec));

            // Try to set empty classes array (should revert)
            HybridVoting.ClassConfig[] memory emptyClasses = new HybridVoting.ClassConfig[](0);
            vm.expectRevert(VotingErrors.InvalidClassCount.selector);
            hv.setClasses(emptyClasses);

            vm.stopPrank();
        }

        function testNClassMaxClasses() public {
            // Test maximum number of classes (8)
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](8);
            uint256[] memory emptyHats = new uint256[](0);

            // Create 8 classes, each with 12.5% (except last with 12.5%)
            for (uint256 i = 0; i < 7; i++) {
                classes[i] = HybridVoting.ClassConfig({
                    strategy: HybridVoting.ClassStrategy.DIRECT,
                    slicePct: 12,
                    quadratic: false,
                    minBalance: 0,
                    asset: address(0),
                    hatIds: emptyHats
                });
            }

            // Last class gets 16% to make it sum to 100
            classes[7] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 16,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: emptyHats
            });

            hv.setClasses(classes);

            // Verify all 8 classes are set
            HybridVoting.ClassConfig[] memory stored = hv.getClasses();
            assertEq(stored.length, 8, "Should have maximum 8 classes");

            vm.stopPrank();
        }

        /* ───────────────────────── CLASSES REPLACED EVENT TESTS ───────────────────────── */

        function testClassesReplacedEventOnSetClasses() public {
            vm.startPrank(address(exec));

            // Create a new class configuration
            HybridVoting.ClassConfig[] memory newClasses = new HybridVoting.ClassConfig[](2);

            uint256[] memory ddHats = new uint256[](1);
            ddHats[0] = EXECUTIVE_HAT_ID;
            newClasses[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 60,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: ddHats
            });

            uint256[] memory tokenHats = new uint256[](1);
            tokenHats[0] = DEFAULT_HAT_ID;
            newClasses[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 40,
                quadratic: true,
                minBalance: 2 ether,
                asset: address(token),
                hatIds: tokenHats
            });

            // Calculate expected hash
            bytes32 expectedHash = keccak256(abi.encode(newClasses));

            // Expect the ClassesReplaced event with full class data
            vm.expectEmit(true, true, false, true);
            emit HybridVotingConfig.ClassesReplaced(block.number, expectedHash, newClasses, uint64(block.timestamp));

            hv.setClasses(newClasses);

            // Verify classes were stored correctly
            HybridVoting.ClassConfig[] memory stored = hv.getClasses();
            assertEq(stored.length, 2, "Should have 2 classes");
            assertEq(stored[0].slicePct, 60, "First class should be 60%");
            assertEq(stored[1].slicePct, 40, "Second class should be 40%");
            assertEq(stored[1].quadratic, true, "Second class should be quadratic");
            assertEq(stored[1].minBalance, 2 ether, "Second class minBalance should be 2 ether");
            assertEq(stored[1].asset, address(token), "Second class asset should be token");

            vm.stopPrank();
        }

        function testClassesReplacedEventContainsAllFields() public {
            vm.startPrank(address(exec));

            // Create a 3-class configuration to test all field types
            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](3);

            // Class 0: Direct with multiple hat IDs
            uint256[] memory multiHats = new uint256[](2);
            multiHats[0] = EXECUTIVE_HAT_ID;
            multiHats[1] = CREATOR_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 30,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: multiHats
            });

            // Class 1: ERC20 with quadratic
            uint256[] memory tokenHats = new uint256[](1);
            tokenHats[0] = DEFAULT_HAT_ID;
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 50,
                quadratic: true,
                minBalance: 5 ether,
                asset: address(token),
                hatIds: tokenHats
            });

            // Class 2: Direct with no hats (open)
            uint256[] memory emptyHats = new uint256[](0);
            classes[2] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 20,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: emptyHats
            });

            hv.setClasses(classes);

            // Verify all fields are stored and would be emitted
            HybridVoting.ClassConfig[] memory stored = hv.getClasses();

            // Check class 0
            assertEq(uint8(stored[0].strategy), uint8(HybridVoting.ClassStrategy.DIRECT));
            assertEq(stored[0].slicePct, 30);
            assertEq(stored[0].quadratic, false);
            assertEq(stored[0].minBalance, 0);
            assertEq(stored[0].asset, address(0));
            assertEq(stored[0].hatIds.length, 2);
            assertEq(stored[0].hatIds[0], EXECUTIVE_HAT_ID);
            assertEq(stored[0].hatIds[1], CREATOR_HAT_ID);

            // Check class 1
            assertEq(uint8(stored[1].strategy), uint8(HybridVoting.ClassStrategy.ERC20_BAL));
            assertEq(stored[1].slicePct, 50);
            assertEq(stored[1].quadratic, true);
            assertEq(stored[1].minBalance, 5 ether);
            assertEq(stored[1].asset, address(token));
            assertEq(stored[1].hatIds.length, 1);

            // Check class 2
            assertEq(uint8(stored[2].strategy), uint8(HybridVoting.ClassStrategy.DIRECT));
            assertEq(stored[2].slicePct, 20);
            assertEq(stored[2].hatIds.length, 0);

            vm.stopPrank();
        }

        function testNClassComplexScenario() public {
            // Complex scenario: Multiple classes, multiple voters, close vote
            vm.startPrank(address(exec));

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](3);

            // Governance token holders (40%)
            uint256[] memory govHats = new uint256[](1);
            govHats[0] = DEFAULT_HAT_ID;
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 40,
                quadratic: true,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: govHats
            });

            // Core contributors (35%)
            uint256[] memory coreHats = new uint256[](1);
            coreHats[0] = EXECUTIVE_HAT_ID;
            classes[1] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 35,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: coreHats
            });

            // Community members (25%)
            uint256[] memory communityHats = new uint256[](1);
            communityHats[0] = CREATOR_HAT_ID;
            classes[2] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.DIRECT,
                slicePct: 25,
                quadratic: false,
                minBalance: 0,
                asset: address(0),
                hatIds: communityHats
            });

            hv.setClasses(classes);
            vm.stopPrank();

            uint256 id = _create();

            // Create diverse voter set
            address[5] memory voters;
            for (uint256 i = 0; i < 5; i++) {
                voters[i] = vm.addr(100 + i);
            }

            // Setup voters with different profiles
            hats.mintHat(DEFAULT_HAT_ID, voters[0]);
            token.mint(voters[0], 500 ether); // Large token holder

            hats.mintHat(DEFAULT_HAT_ID, voters[1]);
            token.mint(voters[1], 50 ether); // Medium token holder

            hats.mintHat(EXECUTIVE_HAT_ID, voters[2]); // Core contributor

            hats.mintHat(CREATOR_HAT_ID, voters[3]); // Community member
            hats.mintHat(CREATOR_HAT_ID, voters[4]); // Community member

            // Mixed voting pattern
            uint8[] memory yesVote = new uint8[](1);
            yesVote[0] = 0;
            uint8[] memory noVote = new uint8[](1);
            noVote[0] = 1;
            uint8[] memory weight = new uint8[](1);
            weight[0] = 100;

            vm.prank(voters[0]);
            hv.vote(id, yesVote, weight); // Large holder votes YES

            vm.prank(voters[1]);
            hv.vote(id, noVote, weight); // Medium holder votes NO

            vm.prank(voters[2]);
            hv.vote(id, yesVote, weight); // Core contributor votes YES

            vm.prank(voters[3]);
            hv.vote(id, noVote, weight); // Community votes NO

            vm.prank(voters[4]);
            hv.vote(id, noVote, weight); // Community votes NO

            // Also have alice (executive) and carol (executive + tokens) vote
            _voteYES(alice);
            _voteYES(carol);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 win, bool ok) = hv.announceWinner(id);

            assertTrue(ok, "Should meet threshold with multiple participants");
            // The result depends on the complex interaction of all classes
        }

        /* ───────────────────────── QUORUM TESTS ───────────────────────── */

        function testSetQuorum() public {
            assertEq(hv.quorum(), 0, "Default quorum should be 0");
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(5)));
            assertEq(hv.quorum(), 5, "Quorum should be 5");
        }

        function testSetQuorumEmitsEvent() public {
            vm.prank(address(exec));
            vm.expectEmit(true, true, true, true);
            emit HybridVoting.QuorumSet(uint32(5));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(5)));
        }

        function testSetQuorumUnauthorized() public {
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(5)));
        }

        function testQuorumNotMet() public {
            // Set quorum to 3 voters
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(3)));

            // Create proposal and have only 1 voter vote
            uint256 id = _create();
            _voteYES(alice);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertFalse(valid, "Should be invalid when quorum not met");
            assertEq(winner, 0, "Winner should be 0 when quorum not met");
        }

        function testQuorumMet() public {
            // Set quorum to 2 voters
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(2)));

            // Create proposal and have 2 voters vote
            uint256 id = _create();
            _voteYES(alice);
            _voteYES(carol);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid, "Should be valid when quorum met");
        }

        function testQuorumDisabledByDefault() public {
            // Default quorum is 0, even 1 voter should work
            uint256 id = _create();
            _voteYES(alice);

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid, "Should be valid with quorum disabled (0)");
        }

        function testVoterCountTracking() public {
            uint256 id = _create();
            _voteYES(alice);
            _voteYES(bob);
            _voteYES(carol);

            // Verify voter count is tracked (3 voters)
            // Set quorum to 3 - should pass exactly
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(3)));

            vm.warp(block.timestamp + 16 minutes);
            (uint256 winner, bool valid) = hv.announceWinner(id);
            assertTrue(valid, "Should pass with exactly 3 voters and quorum of 3");
        }

        function testQuorumCanBeSetToZeroToDisable() public {
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(10)));
            assertEq(hv.quorum(), 10);

            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.QUORUM, abi.encode(uint32(0)));
            assertEq(hv.quorum(), 0, "Quorum should be disabled after setting to 0");
        }

        /* ───────────── ANNOUNCE WINNER REPLAY PROTECTION ───────────── */

        function testAnnounceWinnerDoubleCallReverts() public {
            uint256 id = _create();

            _voteYES(alice);
            _voteYES(carol);

            vm.warp(block.timestamp + 16 minutes);

            // First call succeeds
            vm.prank(alice);
            hv.announceWinner(id);

            // Second call reverts
            vm.expectRevert(VotingErrors.AlreadyExecuted.selector);
            vm.prank(alice);
            hv.announceWinner(id);
        }

        function testAnnounceWinnerExecutionFailDoesNotRevert() public {
            // Deploy a reverting executor
            RevertingExecutor revertExec = new RevertingExecutor();

            // Swap the executor via setConfig (must be called by current executor)
            vm.prank(address(exec));
            hv.setConfig(HybridVoting.ConfigKey.EXECUTOR, abi.encode(address(revertExec)));

            // Create a proposal with a batch (targets the allowed address)
            uint256 id = _create();

            _voteYES(alice);
            _voteYES(carol);

            vm.warp(block.timestamp + 16 minutes);

            // announceWinner should NOT revert even though execution fails
            // Expect ProposalExecutionFailed event
            vm.expectEmit(true, true, false, false);
            emit ProposalExecutionFailed(id, 0, "");

            vm.prank(alice);
            (uint256 winner, bool valid) = hv.announceWinner(id);

            assertTrue(valid, "Proposal should be valid");
            assertEq(winner, 0, "Option 0 should win");

            // Cannot re-announce (executed flag is set)
            vm.expectRevert(VotingErrors.AlreadyExecuted.selector);
            vm.prank(alice);
            hv.announceWinner(id);
        }
    }

    /// @dev Executor that always reverts on execute
    contract RevertingExecutor is IExecutor {
        function execute(uint256, Call[] calldata) external pure {
            revert("Execution deliberately failed");
        }
    }
