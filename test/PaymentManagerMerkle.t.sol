// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {console2} from "forge-std/console2.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {IPaymentManager} from "../src/interfaces/IPaymentManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

/**
 * @title PaymentManagerMerkleTest
 * @notice Comprehensive tests for merkle-based distribution system
 */
contract PaymentManagerMerkleTest is Test {
    PaymentManager public paymentManager;
    ParticipationToken public participationToken;
    MockPaymentToken public paymentToken;
    MockHats public hats;

    address public executor = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public dave = address(0x5);

    uint256 constant ALICE_TOKENS = 500e18;
    uint256 constant BOB_TOKENS = 300e18;
    uint256 constant CHARLIE_TOKENS = 200e18;
    uint256 constant TOTAL_SUPPLY = ALICE_TOKENS + BOB_TOKENS + CHARLIE_TOKENS; // 1000e18

    uint256 memberHatId = 1;
    uint256 approverHatId = 2;

    event DistributionCreated(
        uint256 indexed distributionId,
        address indexed token,
        uint256 amount,
        uint256 checkpointBlock,
        bytes32 merkleRoot
    );
    event DistributionClaimed(uint256 indexed distributionId, address indexed claimer, uint256 amount);
    event DistributionFinalized(uint256 indexed distributionId, uint256 unclaimedAmount);

    function setUp() public {
        // Deploy mock hats
        hats = new MockHats();

        // Deploy participation token
        ParticipationToken _ptImpl = new ParticipationToken();
        UpgradeableBeacon _ptBeacon = new UpgradeableBeacon(address(_ptImpl), address(this));
        participationToken = ParticipationToken(address(new BeaconProxy(address(_ptBeacon), "")));

        participationToken.initialize(
            executor, "Participation Token", "PART", address(hats), memberHatId, approverHatId
        );

        // Deploy payment manager
        PaymentManager _pmImpl = new PaymentManager();
        UpgradeableBeacon _pmBeacon = new UpgradeableBeacon(address(_pmImpl), address(this));
        paymentManager = PaymentManager(payable(address(new BeaconProxy(address(_pmBeacon), ""))));
        paymentManager.initialize(executor, address(participationToken));

        // Deploy payment token
        paymentToken = new MockPaymentToken("Payment Token", "PAY");

        // Setup: mint tokens to users via executor (using request/approve flow)
        vm.startPrank(executor);
        participationToken.mint(alice, ALICE_TOKENS);
        participationToken.mint(bob, BOB_TOKENS);
        participationToken.mint(charlie, CHARLIE_TOKENS);
        vm.stopPrank();

        // Fund payment manager with ETH and tokens
        vm.deal(address(paymentManager), 100 ether);
        paymentToken.mint(address(paymentManager), 10000e18);
    }

    /*──────────────────────────────────────────────────────────────────────────
                            CREATE DISTRIBUTION TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function test_CreateDistribution_ETH() public {
        uint256 amount = 10 ether;
        uint256 checkpointBlock = block.number;
        bytes32 merkleRoot = keccak256("test");

        vm.roll(block.number + 1);

        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit DistributionCreated(1, address(0), amount, checkpointBlock, merkleRoot);

        uint256 distributionId = paymentManager.createDistribution(address(0), amount, merkleRoot, checkpointBlock);

        assertEq(distributionId, 1);
        assertEq(paymentManager.distributionCounter(), 1);

        (
            address payoutToken,
            uint256 totalAmount,
            uint256 checkpoint,
            bytes32 root,
            uint256 totalClaimed,
            bool finalized
        ) = paymentManager.getDistribution(distributionId);

        assertEq(payoutToken, address(0));
        assertEq(totalAmount, amount);
        assertEq(checkpoint, checkpointBlock);
        assertEq(root, merkleRoot);
        assertEq(totalClaimed, 0);
        assertFalse(finalized);
    }

    function test_CreateDistribution_ERC20() public {
        uint256 amount = 1000e18;
        uint256 checkpointBlock = block.number;
        bytes32 merkleRoot = keccak256("test");

        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId =
            paymentManager.createDistribution(address(paymentToken), amount, merkleRoot, checkpointBlock);

        (address payoutToken,,,,,) = paymentManager.getDistribution(distributionId);
        assertEq(payoutToken, address(paymentToken));
    }

    function test_RevertCreateDistribution_ZeroAmount() public {
        vm.roll(block.number + 1);
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.ZeroAmount.selector);
        paymentManager.createDistribution(address(0), 0, keccak256("test"), block.number - 1);
    }

    function test_RevertCreateDistribution_ZeroMerkleRoot() public {
        vm.roll(block.number + 1);
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InvalidMerkleRoot.selector);
        paymentManager.createDistribution(address(0), 1 ether, bytes32(0), block.number - 1);
    }

    function test_RevertCreateDistribution_CheckpointNotInPast() public {
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InvalidCheckpoint.selector);
        paymentManager.createDistribution(address(0), 1 ether, keccak256("test"), block.number);
    }

    function test_RevertCreateDistribution_InsufficientETH() public {
        vm.roll(block.number + 1);
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InsufficientFunds.selector);
        paymentManager.createDistribution(address(0), 1000 ether, keccak256("test"), block.number - 1);
    }

    function test_RevertCreateDistribution_InsufficientERC20() public {
        vm.roll(block.number + 1);
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InsufficientFunds.selector);
        paymentManager.createDistribution(address(paymentToken), 100000e18, keccak256("test"), block.number - 1);
    }

    function test_RevertCreateDistribution_OnlyOwner() public {
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert();
        paymentManager.createDistribution(address(0), 1 ether, keccak256("test"), block.number - 1);
    }

    function test_RevertCreateDistribution_OverCommitment() public {
        vm.roll(block.number + 1);

        // Contract has 100 ETH. Create first distribution for 60 ETH.
        vm.prank(executor);
        paymentManager.createDistribution(address(0), 60 ether, keccak256("dist1"), block.number - 1);

        // Try to create second distribution for 50 ETH — total committed would be 110 ETH > 100 ETH balance
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InsufficientFunds.selector);
        paymentManager.createDistribution(address(0), 50 ether, keccak256("dist2"), block.number - 1);
    }

    function test_CreateDistribution_AfterFinalize_FreesCommitted() public {
        vm.roll(block.number + 1);
        uint256 checkpoint = block.number - 1;

        // Create distribution for 60 ETH (balance=100, committed=60)
        vm.prank(executor);
        uint256 distId = paymentManager.createDistribution(address(0), 60 ether, keccak256("dist1"), checkpoint);

        // Second dist for 50 ETH should fail (committed would be 110 > 100 balance)
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.InsufficientFunds.selector);
        paymentManager.createDistribution(address(0), 50 ether, keccak256("dist2"), checkpoint);

        // Finalize first dist (returns 60 ETH unclaimed to executor, committed=0, balance=40)
        vm.roll(block.number + 100);
        vm.prank(executor);
        paymentManager.finalizeDistribution(distId, 1);

        // Now 40 ETH available with 0 committed — distribution for 40 ETH succeeds
        vm.prank(executor);
        paymentManager.createDistribution(address(0), 40 ether, keccak256("dist3"), block.number - 1);
    }

    /*──────────────────────────────────────────────────────────────────────────
                            CLAIM DISTRIBUTION TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function test_ClaimDistribution_SingleLeaf() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        // Create single-leaf merkle tree for alice
        uint256 aliceAmount = 5 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 merkleRoot = leaf;

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), aliceAmount, merkleRoot, checkpointBlock);

        uint256 aliceBalBefore = alice.balance;
        bytes32[] memory proof = new bytes32[](0); // Empty proof for single leaf

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit DistributionClaimed(distributionId, alice, aliceAmount);
        paymentManager.claimDistribution(distributionId, aliceAmount, proof);

        assertEq(alice.balance, aliceBalBefore + aliceAmount);
        assertTrue(paymentManager.hasClaimed(distributionId, alice));

        (,,,, uint256 totalClaimed,) = paymentManager.getDistribution(distributionId);
        assertEq(totalClaimed, aliceAmount);
    }

    function test_ClaimDistribution_ThreeLeaves() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        // Distribution: alice=5 ETH, bob=3 ETH, charlie=2 ETH
        uint256 aliceAmount = 5 ether;
        uint256 bobAmount = 3 ether;
        uint256 charlieAmount = 2 ether;

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 leafCharlie = keccak256(bytes.concat(keccak256(abi.encode(charlie, charlieAmount))));

        // Build tree: ((alice, bob), charlie)
        bytes32 node1 = _hashPair(leafAlice, leafBob);
        bytes32 merkleRoot = _hashPair(node1, leafCharlie);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 10 ether, merkleRoot, checkpointBlock);

        // Alice claims with proof [bob, charlie]
        bytes32[] memory proofAlice = new bytes32[](2);
        proofAlice[0] = leafBob;
        proofAlice[1] = leafCharlie;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);
        assertEq(alice.balance, aliceBalBefore + aliceAmount);

        // Bob claims with proof [alice, charlie]
        bytes32[] memory proofBob = new bytes32[](2);
        proofBob[0] = leafAlice;
        proofBob[1] = leafCharlie;

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        paymentManager.claimDistribution(distributionId, bobAmount, proofBob);
        assertEq(bob.balance, bobBalBefore + bobAmount);

        // Charlie claims with proof [node1]
        bytes32[] memory proofCharlie = new bytes32[](1);
        proofCharlie[0] = node1;

        uint256 charlieBalBefore = charlie.balance;
        vm.prank(charlie);
        paymentManager.claimDistribution(distributionId, charlieAmount, proofCharlie);
        assertEq(charlie.balance, charlieBalBefore + charlieAmount);

        // Verify all claimed
        assertTrue(paymentManager.hasClaimed(distributionId, alice));
        assertTrue(paymentManager.hasClaimed(distributionId, bob));
        assertTrue(paymentManager.hasClaimed(distributionId, charlie));

        (,,,, uint256 totalClaimed,) = paymentManager.getDistribution(distributionId);
        assertEq(totalClaimed, 10 ether);
    }

    function test_ClaimDistribution_ERC20() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        uint256 aliceAmount = 1000e18;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));

        vm.prank(executor);
        uint256 distributionId =
            paymentManager.createDistribution(address(paymentToken), aliceAmount, leaf, checkpointBlock);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proof);

        assertEq(paymentToken.balanceOf(alice), aliceAmount);
    }

    function test_RevertClaimDistribution_InvalidProof() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        // Wrong amount
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.InvalidProof.selector);
        paymentManager.claimDistribution(distributionId, 10 ether, proof);
    }

    function test_RevertClaimDistribution_WrongProof() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, 3 ether))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 8 ether, merkleRoot, checkpointBlock);

        // Alice tries to use wrong proof (empty instead of [bob])
        bytes32[] memory wrongProof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.InvalidProof.selector);
        paymentManager.claimDistribution(distributionId, 5 ether, wrongProof);
    }

    function test_RevertClaimDistribution_AlreadyClaimed() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, 5 ether, proof);

        // Try to claim again
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.AlreadyClaimed.selector);
        paymentManager.claimDistribution(distributionId, 5 ether, proof);
    }

    function test_RevertClaimDistribution_OptedOut() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        // Alice opts out
        vm.prank(alice);
        paymentManager.optOut(true);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.OptedOut.selector);
        paymentManager.claimDistribution(distributionId, 5 ether, proof);
    }

    function test_RevertClaimDistribution_DistributionNotFound() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.DistributionNotFound.selector);
        paymentManager.claimDistribution(999, 1 ether, proof);
    }

    function test_RevertClaimDistribution_DistributionFinalized() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        // Fast forward and finalize
        vm.roll(block.number + 100000);
        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 100000);

        // Try to claim
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IPaymentManager.DistributionAlreadyFinalized.selector);
        paymentManager.claimDistribution(distributionId, 5 ether, proof);
    }

    /*──────────────────────────────────────────────────────────────────────────
                            CLAIM MULTIPLE TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function test_ClaimMultiple() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        // Create two distributions
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(alice, 3 ether))));

        vm.startPrank(executor);
        uint256 dist1 = paymentManager.createDistribution(address(0), 5 ether, leaf1, checkpointBlock);
        uint256 dist2 = paymentManager.createDistribution(address(0), 3 ether, leaf2, checkpointBlock);
        vm.stopPrank();

        // Batch claim
        uint256[] memory ids = new uint256[](2);
        ids[0] = dist1;
        ids[1] = dist2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5 ether;
        amounts[1] = 3 ether;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        uint256 aliceBalBefore = alice.balance;

        vm.prank(alice);
        paymentManager.claimMultiple(ids, amounts, proofs);

        assertEq(alice.balance, aliceBalBefore + 8 ether);
        assertTrue(paymentManager.hasClaimed(dist1, alice));
        assertTrue(paymentManager.hasClaimed(dist2, alice));
    }

    function test_RevertClaimMultiple_ArrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](1); // Wrong length
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.prank(alice);
        vm.expectRevert(IPaymentManager.ArrayLengthMismatch.selector);
        paymentManager.claimMultiple(ids, amounts, proofs);
    }

    /*──────────────────────────────────────────────────────────────────────────
                            FINALIZE DISTRIBUTION TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function test_FinalizeDistribution_FullyClaimed() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        // Alice claims everything
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, 5 ether, proof);

        // Fast forward
        vm.roll(checkpointBlock + 100001);

        uint256 executorBalBefore = executor.balance;

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit DistributionFinalized(distributionId, 0);
        paymentManager.finalizeDistribution(distributionId, 100000);

        // No unclaimed funds
        assertEq(executor.balance, executorBalBefore);

        (,,,,, bool finalized) = paymentManager.getDistribution(distributionId);
        assertTrue(finalized);
    }

    function test_FinalizeDistribution_PartiallyClaimed() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        // Alice and bob in tree, but only alice claims
        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, 5 ether))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 10 ether, merkleRoot, checkpointBlock);

        // Only alice claims
        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, 5 ether, proofAlice);

        // Fast forward
        vm.roll(checkpointBlock + 100001);

        uint256 executorBalBefore = executor.balance;

        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 100000);

        // Bob's 5 ether returned to executor
        assertEq(executor.balance, executorBalBefore + 5 ether);
    }

    function test_FinalizeDistribution_ERC20() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, 500e18))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, 500e18))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        vm.prank(executor);
        uint256 distributionId =
            paymentManager.createDistribution(address(paymentToken), 1000e18, merkleRoot, checkpointBlock);

        // Fast forward without any claims
        vm.roll(checkpointBlock + 100001);

        uint256 executorBalBefore = paymentToken.balanceOf(executor);

        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 100000);

        // All unclaimed tokens returned
        assertEq(paymentToken.balanceOf(executor), executorBalBefore + 1000e18);
    }

    function test_RevertFinalizeDistribution_ClaimPeriodNotExpired() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        // Try to finalize immediately
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.ClaimPeriodNotExpired.selector);
        paymentManager.finalizeDistribution(distributionId, 100000);
    }

    function test_RevertFinalizeDistribution_AlreadyFinalized() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        vm.roll(checkpointBlock + 100001);

        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 100000);

        // Try to finalize again
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.AlreadyFinalized.selector);
        paymentManager.finalizeDistribution(distributionId, 100000);
    }

    function test_RevertFinalizeDistribution_OnlyOwner() public {
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 5 ether, leaf, checkpointBlock);

        vm.roll(checkpointBlock + 100001);

        vm.prank(alice);
        vm.expectRevert();
        paymentManager.finalizeDistribution(distributionId, 100000);
    }

    /*──────────────────────────────────────────────────────────────────────────
                            VULNERABILITY FIX TEST
    ──────────────────────────────────────────────────────────────────────────*/

    function test_VulnerabilityFix_MintAfterCheckpoint() public {
        // This is the KEY test - verifies the vulnerability is fixed
        uint256 checkpointBlock = block.number;

        // At checkpoint: alice=500, bob=300, charlie=200 (total=1000)
        // Distribution: 10 ETH
        // Expected shares: alice=5 ETH, bob=3 ETH, charlie=2 ETH

        vm.roll(block.number + 1);

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, 3 ether))));
        bytes32 leafCharlie = keccak256(bytes.concat(keccak256(abi.encode(charlie, 2 ether))));

        bytes32 node1 = _hashPair(leafAlice, leafBob);
        bytes32 merkleRoot = _hashPair(node1, leafCharlie);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), 10 ether, merkleRoot, checkpointBlock);

        // CRITICAL: Dave receives tokens AFTER checkpoint
        // In old system, this would cause IncompleteHoldersList revert
        vm.prank(executor);
        participationToken.mint(dave, 1000e18);

        // Verify total supply increased
        assertEq(participationToken.totalSupply(), TOTAL_SUPPLY + 1000e18);

        // Original holders can still claim (not affected by new mints)
        bytes32[] memory proofAlice = new bytes32[](2);
        proofAlice[0] = leafBob;
        proofAlice[1] = leafCharlie;

        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, 5 ether, proofAlice);
        assertEq(alice.balance, 5 ether);

        bytes32[] memory proofBob = new bytes32[](2);
        proofBob[0] = leafAlice;
        proofBob[1] = leafCharlie;

        vm.prank(bob);
        paymentManager.claimDistribution(distributionId, 3 ether, proofBob);
        assertEq(bob.balance, 3 ether);

        bytes32[] memory proofCharlie = new bytes32[](1);
        proofCharlie[0] = node1;

        vm.prank(charlie);
        paymentManager.claimDistribution(distributionId, 2 ether, proofCharlie);
        assertEq(charlie.balance, 2 ether);

        // Dave cannot claim (not in merkle tree, which is correct)
        bytes32 fakeDaveLeaf = keccak256(bytes.concat(keccak256(abi.encode(dave, 1 ether))));
        bytes32[] memory proofDave = new bytes32[](0);

        vm.prank(dave);
        vm.expectRevert(IPaymentManager.InvalidProof.selector);
        paymentManager.claimDistribution(distributionId, 1 ether, proofDave);

        // SUCCESS! The vulnerability is fixed.
        // Old system: would revert with IncompleteHoldersList
        // New system: original holders claim successfully, new holders excluded
    }

    /*──────────────────────────────────────────────────────────────────────────
                                OVER-CLAIM CAP TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function testRevertClaimDistribution_OverClaimed() public {
        // Build a malformed merkle tree where alice(4 ether) + bob(4 ether) > totalAmount(5 ether)
        uint256 aliceAmount = 4 ether;
        uint256 bobAmount = 4 ether;
        uint256 totalAmount = 5 ether;

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Alice claims 4 ether (totalClaimed=4, still <= 5)
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);

        // Bob claims 4 ether (totalClaimed would become 8 > 5) — should revert
        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimDistribution(distributionId, bobAmount, proofBob);
    }

    function testRevertClaimMultiple_OverClaimed() public {
        // Same scenario but via claimMultiple
        uint256 aliceAmount = 4 ether;
        uint256 bobAmount = 4 ether;
        uint256 totalAmount = 5 ether;

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Alice claims first via single claim
        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);

        // Bob claims via claimMultiple — should revert
        uint256[] memory ids = new uint256[](1);
        ids[0] = distributionId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = bobAmount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = proofBob;

        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimMultiple(ids, amounts, proofs);
    }

    function testFinalizeDistribution_SafeWithinCap() public {
        // Normal distribution where claims are within bounds
        uint256 aliceAmount = 3 ether;
        uint256 bobAmount = 2 ether;
        uint256 totalAmount = 5 ether;

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Alice claims
        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);

        // Finalize (bob doesn't claim, 2 ether unclaimed)
        vm.roll(block.number + 100);
        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 10);
    }

    /*──────────────────────────────────────────────────────────────────────────
                        OVER-CLAIM BOUNDARY & EDGE CASE TESTS
    ──────────────────────────────────────────────────────────────────────────*/

    function testClaimExactlyTotalAmount_Succeeds() public {
        // totalClaimed == totalAmount is allowed (not >)
        uint256 aliceAmount = 3 ether;
        uint256 bobAmount = 2 ether;
        uint256 totalAmount = 5 ether; // exactly alice + bob

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Both claim — total exactly equals totalAmount
        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;
        vm.prank(bob);
        paymentManager.claimDistribution(distributionId, bobAmount, proofBob);

        // Finalize with zero unclaimed
        vm.roll(block.number + 100);
        vm.prank(executor);
        paymentManager.finalizeDistribution(distributionId, 10);
    }

    function testSingleUserClaimsEntireDistribution() public {
        uint256 amount = 7 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, amount))));

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), amount, leaf, checkpointBlock);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, amount, proof);

        // Verify totalClaimed == totalAmount
        assertTrue(paymentManager.hasClaimed(distributionId, alice));
    }

    function testOverClaimDoesNotAffectOtherDistributions() public {
        // Create two distributions
        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        // Distribution 1: malformed (allocations > total)
        bytes32 leafAlice1 = keccak256(bytes.concat(keccak256(abi.encode(alice, 4 ether))));
        bytes32 leafBob1 = keccak256(bytes.concat(keccak256(abi.encode(bob, 4 ether))));
        bytes32 root1 = _hashPair(leafAlice1, leafBob1);

        // Distribution 2: well-formed
        bytes32 leafAlice2 = keccak256(bytes.concat(keccak256(abi.encode(alice, 2 ether))));
        bytes32 leafBob2 = keccak256(bytes.concat(keccak256(abi.encode(bob, 1 ether))));
        bytes32 root2 = _hashPair(leafAlice2, leafBob2);

        vm.startPrank(executor);
        uint256 dist1 = paymentManager.createDistribution(address(0), 5 ether, root1, checkpointBlock);
        uint256 dist2 = paymentManager.createDistribution(address(0), 3 ether, root2, checkpointBlock);
        vm.stopPrank();

        // Dist1: Alice claims, then Bob's claim should revert
        bytes32[] memory proof1Alice = new bytes32[](1);
        proof1Alice[0] = leafBob1;
        vm.prank(alice);
        paymentManager.claimDistribution(dist1, 4 ether, proof1Alice);

        bytes32[] memory proof1Bob = new bytes32[](1);
        proof1Bob[0] = leafAlice1;
        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimDistribution(dist1, 4 ether, proof1Bob);

        // Dist2: Both should still claim fine (independent)
        bytes32[] memory proof2Alice = new bytes32[](1);
        proof2Alice[0] = leafBob2;
        vm.prank(alice);
        paymentManager.claimDistribution(dist2, 2 ether, proof2Alice);

        bytes32[] memory proof2Bob = new bytes32[](1);
        proof2Bob[0] = leafAlice2;
        vm.prank(bob);
        paymentManager.claimDistribution(dist2, 1 ether, proof2Bob);
    }

    function testThreeUserTree_OverClaim() public {
        // 3-leaf merkle tree where total allocations exceed totalAmount
        uint256 aliceAmt = 3 ether;
        uint256 bobAmt = 3 ether;
        uint256 charlieAmt = 3 ether;
        uint256 totalAmount = 5 ether; // 9 allocated vs 5 total

        bytes32 leafA = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmt))));
        bytes32 leafB = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmt))));
        bytes32 leafC = keccak256(bytes.concat(keccak256(abi.encode(charlie, charlieAmt))));

        // Build 3-leaf tree: hash(hash(A,B), C)
        bytes32 abHash = _hashPair(leafA, leafB);
        bytes32 merkleRoot = _hashPair(abHash, leafC);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Alice claims 3 ether (totalClaimed = 3 <= 5, OK)
        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = leafB;
        proofA[1] = leafC;
        vm.prank(alice);
        paymentManager.claimDistribution(distId, aliceAmt, proofA);

        // Bob claims 3 ether (totalClaimed would be 6 > 5, REVERT)
        bytes32[] memory proofB = new bytes32[](2);
        proofB[0] = leafA;
        proofB[1] = leafC;
        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimDistribution(distId, bobAmt, proofB);
    }

    function testOverClaimGuard_ERC20Distribution() public {
        // Test the guard with ERC20 token distributions too
        uint256 aliceAmount = 600e18;
        uint256 bobAmount = 600e18;
        uint256 totalAmount = 800e18;

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId =
            paymentManager.createDistribution(address(paymentToken), totalAmount, merkleRoot, checkpointBlock);

        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmount, proofAlice);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;
        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimDistribution(distributionId, bobAmount, proofBob);
    }

    function testFuzz_ClaimWithinBounds(uint128 aliceAmt, uint128 bobAmt) public {
        // Ensure amounts are reasonable
        aliceAmt = uint128(bound(aliceAmt, 0.01 ether, 10 ether));
        bobAmt = uint128(bound(bobAmt, 0.01 ether, 10 ether));
        uint256 totalAmount = uint256(aliceAmt) + uint256(bobAmt);

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(aliceAmt)))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(bobAmt)))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        // Both claims should succeed when totalAmount == sum of allocations
        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmt, proofAlice);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;
        vm.prank(bob);
        paymentManager.claimDistribution(distributionId, bobAmt, proofBob);
    }

    function testFuzz_OverClaimReverts(uint128 aliceAmt, uint128 bobAmt, uint128 totalShort) public {
        // totalAmount is intentionally less than sum of allocations
        aliceAmt = uint128(bound(aliceAmt, 1 ether, 5 ether));
        bobAmt = uint128(bound(bobAmt, 1 ether, 5 ether));
        totalShort = uint128(bound(totalShort, 1, uint256(aliceAmt) + uint256(bobAmt) - 1));
        uint256 totalAmount = totalShort;

        // Need totalAmount > aliceAmt so first claim passes, but < aliceAmt + bobAmt
        vm.assume(totalAmount >= aliceAmt);

        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(aliceAmt)))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(bobAmt)))));
        bytes32 merkleRoot = _hashPair(leafAlice, leafBob);

        uint256 checkpointBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(executor);
        uint256 distributionId = paymentManager.createDistribution(address(0), totalAmount, merkleRoot, checkpointBlock);

        bytes32[] memory proofAlice = new bytes32[](1);
        proofAlice[0] = leafBob;
        vm.prank(alice);
        paymentManager.claimDistribution(distributionId, aliceAmt, proofAlice);

        // Bob's claim should revert (totalClaimed would exceed totalAmount)
        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafAlice;
        vm.prank(bob);
        vm.expectRevert(IPaymentManager.OverClaimed.selector);
        paymentManager.claimDistribution(distributionId, bobAmt, proofBob);
    }

    /*──────────────────────────────────────────────────────────────────────────
                                    HELPER FUNCTIONS
    ──────────────────────────────────────────────────────────────────────────*/

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

/*──────────────────────────────────────────────────────────────────────────
                                    MOCK CONTRACTS
──────────────────────────────────────────────────────────────────────────*/

contract MockPaymentToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Simplified mock - provides minimal IHats functionality for ParticipationToken
contract MockHats {
    mapping(address => mapping(uint256 => bool)) public isWearerOf;

    function setHatWearerStatus(address wearer, uint256 hatId, bool wearing) external {
        isWearerOf[wearer][hatId] = wearing;
    }

    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool) {
        return isWearerOf[wearer][hatId];
    }

    function balanceOfBatch(address[] calldata wearers, uint256[] calldata hatIds)
        external
        view
        returns (uint256[] memory balances)
    {
        require(wearers.length == hatIds.length, "Length mismatch");
        balances = new uint256[](wearers.length);
        for (uint256 i = 0; i < wearers.length; i++) {
            balances[i] = isWearerOf[wearers[i]][hatIds[i]] ? 1 : 0;
        }
        return balances;
    }
}
