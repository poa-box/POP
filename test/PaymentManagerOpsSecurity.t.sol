// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {IPaymentManager} from "../src/interfaces/IPaymentManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title PaymentManagerOpsSecurityTest
 * @notice Regression coverage for the WS-E PaymentManager fixes:
 *   M-08 — finalize timer anchored to creationBlock (not the past checkpointBlock), with a
 *          creationBlock==0 fallback to checkpointBlock for pre-upgrade distributions.
 *   L-18 — finalizeDistribution is nonReentrant.
 *   L-19 — opt-out no longer blocks an already-allocated claim (applies to future dists only).
 */
contract PaymentManagerOpsSecurityTest is Test {
    PaymentManager public pm;

    address public executor = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    // keccak256("poa.paymentmanager.storage")
    bytes32 constant STORAGE_SLOT = keccak256("poa.paymentmanager.storage");

    function setUp() public {
        PaymentManager impl = new PaymentManager();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        // revenue-share token address is irrelevant for these tests; use a nonzero placeholder.
        pm = PaymentManager(payable(address(new BeaconProxy(address(beacon), ""))));
        pm.initialize(executor, address(0xBEEF));

        vm.deal(address(pm), 100 ether);
    }

    /*──────────────────────────────────────────────────────────────────────────
                    M-08: finalize timer anchored to creationBlock
    ──────────────────────────────────────────────────────────────────────────*/

    /// @dev The core of M-08: even when the checkpoint is far in the past (so
    ///      checkpointBlock + minClaimPeriodBlocks is already behind us at creation), finalize
    ///      must still wait creationBlock + minClaimPeriodBlocks.
    function testFinalizeAnchoredToCreationNotStaleCheckpoint() public {
        // Advance well past the checkpoint we'll use.
        vm.roll(10_000);
        uint256 staleCheckpoint = 100; // far in the past
        uint256 minPeriod = 500;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        vm.prank(executor);
        uint256 distId = pm.createDistribution(address(0), 5 ether, leaf, staleCheckpoint);

        uint256 creation = block.number; // 10_000

        // Pre-fix: checkpointBlock(100)+minPeriod(500)=600 <= 10_000, so finalize would pass now.
        // Post-fix: gate is creationBlock(10_000)+minPeriod(500)=10_500.

        // Just before the window closes -> revert.
        vm.roll(creation + minPeriod - 1); // 10_499
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.ClaimPeriodNotExpired.selector);
        pm.finalizeDistribution(distId, minPeriod);

        // Exactly at the window -> success.
        vm.roll(creation + minPeriod); // 10_500
        vm.prank(executor);
        pm.finalizeDistribution(distId, minPeriod);

        (,,,,, bool finalized) = pm.getDistribution(distId);
        assertTrue(finalized, "distribution should be finalized once creation window elapses");
    }

    /// @dev Backward-compat: a pre-upgrade distribution (creationBlock==0) falls back to the
    ///      checkpointBlock anchor so it still finalizes sanely. We emulate a legacy record by
    ///      creating one and zeroing its creationBlock slot via vm.store.
    function testLegacyDistributionFallsBackToCheckpoint() public {
        vm.roll(10_000);
        uint256 checkpoint = 9_000;
        uint256 minPeriod = 500;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        vm.prank(executor);
        uint256 distId = pm.createDistribution(address(0), 5 ether, leaf, checkpoint);

        // Emulate a pre-upgrade record: zero the appended creationBlock field.
        _zeroCreationBlock(distId);
        assertEq(_readCreationBlock(distId), 0, "creationBlock should read 0 (legacy emulation)");

        // Fallback anchor is checkpointBlock(9_000)+minPeriod(500)=9_500.
        // Before that -> revert.
        vm.roll(9_499);
        vm.prank(executor);
        vm.expectRevert(IPaymentManager.ClaimPeriodNotExpired.selector);
        pm.finalizeDistribution(distId, minPeriod);

        // At/after -> success.
        vm.roll(9_500);
        vm.prank(executor);
        pm.finalizeDistribution(distId, minPeriod);

        (,,,,, bool finalized) = pm.getDistribution(distId);
        assertTrue(finalized, "legacy distribution should finalize via checkpoint fallback");
    }

    /// @dev Sanity: creationBlock is actually stored at creation for new distributions.
    function testCreationBlockStoredOnCreate() public {
        vm.roll(4_242);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 1 ether))));
        vm.prank(executor);
        uint256 distId = pm.createDistribution(address(0), 1 ether, leaf, 4_000);
        assertEq(_readCreationBlock(distId), 4_242, "creationBlock must equal creation block number");
    }

    /*──────────────────────────────────────────────────────────────────────────
                        L-18: finalizeDistribution nonReentrant
    ──────────────────────────────────────────────────────────────────────────*/

    /// @dev A malicious owner (executor) that re-enters finalizeDistribution on the ETH
    ///      unclaimed-return callback is blocked. Note the protection is layered: the
    ///      re-entrant call reverts at the `nonReentrant` guard (L-18, defense-in-depth),
    ///      and even absent the guard CEI ordering (`finalized = true` before the send)
    ///      would revert it via AlreadyFinalized — either way the callback fails, so the
    ///      outer finalize surfaces `TransferFailed`. We pin that exact selector rather
    ///      than accept any revert, so a regression that finalized for a different reason
    ///      (or double-paid) is caught.
    function testFinalizeIsNonReentrant() public {
        ReentrantOwner attacker = new ReentrantOwner();

        // Fresh PM owned by the attacker contract.
        PaymentManager impl = new PaymentManager();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        PaymentManager victim = PaymentManager(payable(address(new BeaconProxy(address(beacon), ""))));
        victim.initialize(address(attacker), address(0xBEEF));
        vm.deal(address(victim), 10 ether);

        attacker.setTarget(victim);

        // Create a distribution with unclaimed funds so finalize triggers the ETH callback.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        vm.roll(1_000);
        vm.prank(address(attacker));
        uint256 distId = victim.createDistribution(address(0), 5 ether, leaf, 500);

        vm.roll(2_000);
        attacker.setDistId(distId);

        // The re-entrant finalize must revert the whole call; the failed callback surfaces
        // as TransferFailed at the outer frame (see the layered-protection note above).
        vm.expectRevert(IPaymentManager.TransferFailed.selector);
        attacker.attack(distId, 100);
    }

    /*──────────────────────────────────────────────────────────────────────────
                    L-19: opt-out does not block already-allocated claims
    ──────────────────────────────────────────────────────────────────────────*/

    function testOptedOutUserCanStillClaimExistingDistribution() public {
        vm.roll(1_000);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        vm.prank(executor);
        uint256 distId = pm.createDistribution(address(0), 5 ether, leaf, 500);

        // Alice opts out AFTER being allocated in this distribution's tree.
        vm.prank(alice);
        pm.optOut(true);
        assertTrue(pm.isOptedOut(alice), "opt-out flag must still be recorded");

        // She must still be able to claim her already-allocated funds (L-19).
        bytes32[] memory proof = new bytes32[](0);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        pm.claimDistribution(distId, 5 ether, proof);
        assertEq(alice.balance, balBefore + 5 ether, "opted-out user must still receive allocated funds");
        assertTrue(pm.hasClaimed(distId, alice));
    }

    function testOptedOutUserCanClaimViaClaimMultiple() public {
        vm.roll(1_000);
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(alice, 5 ether))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(alice, 3 ether))));

        vm.startPrank(executor);
        uint256 d1 = pm.createDistribution(address(0), 5 ether, leaf1, 500);
        uint256 d2 = pm.createDistribution(address(0), 3 ether, leaf2, 500);
        vm.stopPrank();

        vm.prank(alice);
        pm.optOut(true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = d1;
        ids[1] = d2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5 ether;
        amounts[1] = 3 ether;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        pm.claimMultiple(ids, amounts, proofs);
        assertEq(alice.balance, balBefore + 8 ether, "opted-out user must still batch-claim allocated funds");
    }

    /*──────────────────────────────────────────────────────────────────────────
                                    STORAGE HELPERS
    ──────────────────────────────────────────────────────────────────────────*/

    /// @dev Compute the base slot of distributions[id] (a struct-value mapping).
    ///      distributions is the 3rd field of Layout (revenueShareToken[0], optedOut[1],
    ///      distributions[2], ...). Its slot = STORAGE_SLOT + 2.
    function _distBaseSlot(uint256 distId) internal pure returns (uint256) {
        uint256 mappingSlot = uint256(STORAGE_SLOT) + 2;
        return uint256(keccak256(abi.encode(distId, mappingSlot)));
    }

    /// @dev creationBlock is field index 8 within Distribution:
    ///      [0]payoutToken [1]totalAmount [2]checkpointBlock [3]merkleRoot [4]totalClaimed
    ///      [5]finalized [6]claimed(mapping) [7]... wait — see comment below.
    ///      Actual layout: payoutToken(0), totalAmount(1), checkpointBlock(2), merkleRoot(3),
    ///      totalClaimed(4), finalized(5), claimed mapping occupies slot(6), creationBlock(7).
    function _creationBlockSlot(uint256 distId) internal pure returns (bytes32) {
        return bytes32(_distBaseSlot(distId) + 7);
    }

    function _readCreationBlock(uint256 distId) internal view returns (uint256) {
        return uint256(vm.load(address(pm), _creationBlockSlot(distId)));
    }

    function _zeroCreationBlock(uint256 distId) internal {
        vm.store(address(pm), _creationBlockSlot(distId), bytes32(0));
    }
}

/*──────────────────────────────────────────────────────────────────────────
                                MOCKS
──────────────────────────────────────────────────────────────────────────*/

/// @dev Owner contract that attempts to re-enter finalizeDistribution during the ETH
///      unclaimed-return callback. The reentrancy guard must abort the whole call.
contract ReentrantOwner {
    PaymentManager public target;
    uint256 public distId;
    bool internal reentered;

    function setTarget(PaymentManager t) external {
        target = t;
    }

    function setDistId(uint256 id) external {
        distId = id;
    }

    function attack(uint256 id, uint256 minPeriod) external {
        target.finalizeDistribution(id, minPeriod);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            // Re-enter: this must revert due to nonReentrant on finalizeDistribution.
            target.finalizeDistribution(distId, 100);
        }
    }
}
