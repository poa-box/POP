// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {IExecutor} from "../../src/Executor.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/**
 * @title SimulateVotingUpgrade
 * @notice Fork-simulate the HybridVoting/DDV v10 upgrade on Arbitrum (home chain),
 *         then exercise the new try-catch announceWinner logic against KUBI's
 *         real on-chain HybridVoting proxy.
 *
 * Usage:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/SimulateVotingUpgrade.s.sol:SimulateVotingUpgrade \
 *     --rpc-url arbitrum --slow
 *
 *   (No --broadcast: dry-run on fork only)
 */
contract SimulateVotingUpgrade is Script {
    // ── Arbitrum (home chain) addresses ──
    address constant ARB_PM = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    // KUBI org on Arbitrum
    address constant KUBI_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;
    address constant KUBI_EXEC = 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41;

    // Events
    event ProposalExecutionFailed(uint256 indexed id, uint256 indexed winningIdx, bytes reason);
    event ProposalExecuted(uint256 indexed id, uint256 indexed winningOption, uint256 callCount);
    event Winner(uint256 indexed id, uint256 indexed winningOption, bool valid, bool didExecute, uint64 timestamp);

    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);
        PoaManager pm = PoaManager(ARB_PM);
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n========================================");
        console.log("  Voting Upgrade Fork Simulation (Arbitrum)");
        console.log("========================================");
        console.log("Deployer:", deployer);

        // ── 1. Pre-upgrade state ──
        bytes32 hvTypeId = keccak256("HybridVoting");
        bytes32 ddvTypeId = keccak256("DirectDemocracyVoting");
        address hvImplBefore = pm.getCurrentImplementationById(hvTypeId);
        address ddvImplBefore = pm.getCurrentImplementationById(ddvTypeId);
        console.log("\n--- Pre-upgrade ---");
        console.log("HV impl:", hvImplBefore);
        console.log("DDV impl:", ddvImplBefore);

        // ── 2. Deploy v10 impls via DD ──
        bytes32 hvSalt = dd.computeSalt("HybridVoting", "v10");
        address hvImpl = dd.computeAddress(hvSalt);
        bytes32 ddvSalt = dd.computeSalt("DirectDemocracyVoting", "v10");
        address ddvImpl = dd.computeAddress(ddvSalt);
        console.log("\n--- Deploy v10 impls ---");

        vm.startPrank(deployer);
        if (hvImpl.code.length == 0) {
            dd.deploy(hvSalt, type(HybridVoting).creationCode);
            console.log("HV v10 deployed:", hvImpl);
        } else {
            console.log("HV v10 exists:", hvImpl);
        }
        if (ddvImpl.code.length == 0) {
            dd.deploy(ddvSalt, type(DirectDemocracyVoting).creationCode);
            console.log("DDV v10 deployed:", ddvImpl);
        } else {
            console.log("DDV v10 exists:", ddvImpl);
        }
        vm.stopPrank();

        // ── 3. Upgrade beacon via PM owner ──
        address pmOwner = pm.owner();
        console.log("\n--- Upgrade beacons (PM owner:", pmOwner, ") ---");
        vm.startPrank(pmOwner);
        pm.upgradeBeacon("HybridVoting", hvImpl, "v10");
        console.log("HV beacon upgraded");
        pm.upgradeBeacon("DirectDemocracyVoting", ddvImpl, "v10");
        console.log("DDV beacon upgraded");
        vm.stopPrank();

        // ── 4. Verify upgrade ──
        address hvImplAfter = pm.getCurrentImplementationById(hvTypeId);
        address ddvImplAfter = pm.getCurrentImplementationById(ddvTypeId);
        require(hvImplAfter == hvImpl, "HV impl mismatch");
        require(ddvImplAfter == ddvImpl, "DDV impl mismatch");
        console.log("HV impl after:", hvImplAfter, "PASS");
        console.log("DDV impl after:", ddvImplAfter, "PASS");

        // ── 5. Verify KUBI proxy picks up new impl ──
        HybridVoting hv = HybridVoting(KUBI_HV);
        console.log("\n--- KUBI HV proxy verification ---");
        // If the beacon chain works, this call should succeed against the new impl
        uint256 count = hv.proposalsCount();
        console.log("KUBI proposalsCount:", count, "(proxy resolves new impl)");
        uint8 threshold = hv.thresholdPct();
        console.log("KUBI thresholdPct:", threshold);

        // ── 6. Test: announceWinner with reverting execution ──
        console.log("\n--- Test: reverting execution batch ---");
        _testRevertingExecution(deployer, hv);

        // ── 7. Test: signal vote (empty batch) ──
        console.log("\n--- Test: signal vote (empty batch) ---");
        _testSignalVote(deployer, hv);

        // ── 8. Test: double-announce reverts ──
        console.log("\n--- Test: double announce protection ---");
        _testDoubleAnnounce(deployer, hv);

        console.log("\n========================================");
        console.log("  ALL TESTS PASSED");
        console.log("========================================");
    }

    function _mockHats(address who, HybridVoting hv) internal {
        uint256[] memory creatorHats = hv.creatorHats();
        require(creatorHats.length > 0, "No creator hats");
        vm.mockCall(HATS, abi.encodeWithSelector(IHats.isWearerOfHat.selector, who, creatorHats[0]), abi.encode(true));

        HybridVoting.ClassConfig[] memory classes = hv.getClasses();
        for (uint256 i = 0; i < classes.length; i++) {
            if (classes[i].hatId != 0) {
                vm.mockCall(
                    HATS, abi.encodeWithSelector(IHats.isWearerOfHat.selector, who, classes[i].hatId), abi.encode(true)
                );
            }
        }
    }

    function _createAndVote(address voter, HybridVoting hv, IExecutor.Call[][] memory batches, uint8 voteIdx)
        internal
        returns (uint256)
    {
        _mockHats(voter, hv);
        vm.startPrank(voter);

        uint256 id = hv.proposalsCount();
        hv.createProposal(bytes("Test Proposal"), keccak256(abi.encode(id)), 10, 2, batches, new uint256[](0));

        uint8[] memory idxs = new uint8[](1);
        idxs[0] = voteIdx;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;
        hv.vote(id, idxs, weights);

        vm.warp(block.timestamp + 11 minutes);
        vm.stopPrank();
        return id;
    }

    function _testRevertingExecution(address deployer, HybridVoting hv) internal {
        // Create batch that will revert (calls TargetSelf on executor)
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        IExecutor.Call[] memory revertBatch = new IExecutor.Call[](1);
        revertBatch[0] =
            IExecutor.Call({target: address(KUBI_EXEC), value: 0, data: abi.encodeWithSignature("nonExistent()")});
        batches[0] = revertBatch;
        batches[1] = new IExecutor.Call[](0);

        uint256 id = _createAndVote(deployer, hv, batches, 0);

        // announceWinner should NOT revert despite execution failure
        (uint256 winner, bool valid) = hv.announceWinner(id);
        require(valid, "Should be valid");
        require(winner == 0, "Option 0 should win");
        console.log(
            "  Reverting batch: announceWinner succeeded (winner=%d, valid=%s)", winner, valid ? "true" : "false"
        );
        console.log("  PASS: try-catch caught execution failure");
    }

    function _testSignalVote(address deployer, HybridVoting hv) internal {
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);

        uint256 id = _createAndVote(deployer, hv, batches, 1);

        (uint256 winner, bool valid) = hv.announceWinner(id);
        require(valid, "Should be valid");
        require(winner == 1, "Option 1 should win");
        console.log("  Signal vote: winner=%d, valid=%s", winner, valid ? "true" : "false");
        console.log("  PASS: empty batch handled correctly");
    }

    function _testDoubleAnnounce(address deployer, HybridVoting hv) internal {
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);

        uint256 id = _createAndVote(deployer, hv, batches, 0);
        hv.announceWinner(id);

        // Second call must revert
        vm.expectRevert();
        hv.announceWinner(id);
        console.log("  PASS: double announce correctly reverts");
    }
}
