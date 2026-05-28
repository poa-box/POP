// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) - Fix Neighbor default eligibility
 * ============================================================================
 *
 * Single-call governance proposal:
 *   EligibilityModule.setDefaultEligibility(NEIGHBOR_HAT, eligible=true, standing=true)
 *
 * Decentral Park's Neighbor role is intended to be quick-joinable by anyone
 * (the Neighbor hat IS listed in QuickJoin.memberHatIds via subgraph), but the
 * default eligibility on the EligibilityModule was left at `false`. As a
 * result, when a new user tries to quick-join, Hats Protocol calls the
 * eligibility module's `getWearerStatus`, which returns the default rules for
 * any address with no per-wearer entry — `(eligible=false, standing=true)` —
 * so `isEligible` returns false and `mintHat` reverts NotEligible.
 *
 * Vouching is NOT configured on Neighbor (quorum=0), so the fix is the
 * one-liner: flip defaultEligible from false to true. defaultStanding is
 * already true, leaving it as-is for documentation parity.
 *
 * Auth: `setDefaultEligibility` is `onlyHatAdmin(hatId)`. The EligibilityModule
 * modifier accepts either superAdmin (== Executor) or any Hats-admin-of-hatId.
 * Executor wears Decentral Park's topHat, so the call passes.
 *
 * Sim-first per CLAUDE.md: prank Hudson (real Delegate-hat wearer) for
 * createProposal + vote against real on-chain Hats Protocol state. After
 * announceWinner fires, the sim asserts:
 *   - Pre-state: defaultEligible == false (the reported bug)
 *   - Post-state: defaultEligible == true
 *   - A randomly chosen EOA now passes Hats.isEligible(eoa, neighborHat) — the
 *     functional QuickJoin precondition.
 *
 * Usage:
 *   # Sim
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/FixDecentralParkNeighborEligibility.s.sol:SimFixDecentralParkNeighborEligibility \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (sender must wear Delegate or Neighbor hat to satisfy HV.creatorHats)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/FixDecentralParkNeighborEligibility.s.sol:BroadcastFixDecentralParkNeighborEligibility \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   PROPOSAL_DURATION_MIN  - Voting window (minutes). Default 30.
 * ============================================================================
 */

address constant GNOSIS_HATS_PROTOCOL = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

// Decentral Park (Gnosis) - verified via subgraph 2026-05-28
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;
address constant DECENTRAL_PARK_EM = 0xe4A02F20B8282A272879e31479Ee070dab07B015;
uint256 constant DECENTRAL_PARK_NEIGHBOR_HAT = 36180248838698575132261002770404529440178570924043841009651669962588160;

// Hudson - verified Delegate-hat wearer; the sim pranks this address.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

// 10 minutes = HybridVoting MIN_DURATION; matches the sim's internal value so broadcasting
// uses the same cadence the sim validates against.
uint32 constant DEFAULT_PROPOSAL_DURATION_MIN = 10;

interface IEligibilityModuleMinimal {
    function setDefaultEligibility(uint256 hatId, bool eligible, bool standing) external;
    function getDefaultRules(uint256 hatId) external view returns (bool eligible, bool standing);
}

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
    function isEligible(address user, uint256 hatId) external view returns (bool);
}

abstract contract FixNeighborBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION_MIN", uint256(DEFAULT_PROPOSAL_DURATION_MIN)));
    }

    function _buildBatch() internal pure returns (IExecutor.Call[] memory batch) {
        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: DECENTRAL_PARK_EM,
            value: 0,
            data: abi.encodeCall(
                IEligibilityModuleMinimal.setDefaultEligibility, (DECENTRAL_PARK_NEIGHBOR_HAT, true, true)
            )
        });
    }

    function _printPreview() internal view {
        (bool eligibleBefore, bool standingBefore) =
            IEligibilityModuleMinimal(DECENTRAL_PARK_EM).getDefaultRules(DECENTRAL_PARK_NEIGHBOR_HAT);
        console.log("\n=== Proposal preview ===");
        console.log("  Neighbor hatId:                 ", DECENTRAL_PARK_NEIGHBOR_HAT);
        console.log("  defaultEligible BEFORE:         ", eligibleBefore);
        console.log("  defaultStanding BEFORE:         ", standingBefore);
        console.log("  defaultEligible AFTER (target): ", true);
        console.log("  defaultStanding AFTER (target): ", true);
    }

    /// @dev Full sim using REAL Hats Protocol state - no etch. Pranks Hudson for proposal +
    /// vote; the Executor fires the EligibilityModule call.
    function _simFullFlow() internal {
        console.log("\n=== Decentral Park Neighbor eligibility fix sim (real Hats, prank Hudson) ===");

        _printPreview();

        // Pre-state assertion: bug must be present.
        (bool eligibleBefore,) =
            IEligibilityModuleMinimal(DECENTRAL_PARK_EM).getDefaultRules(DECENTRAL_PARK_NEIGHBOR_HAT);
        require(!eligibleBefore, "Sim: defaultEligible is already true - nothing to fix");

        // Sanity-check: a fresh EOA cannot currently quick-join (functional manifestation of bug).
        address probe = makeAddr("dp-neighbor-eligibility-probe");
        bool eligibleProbeBefore = IHatsMinimal(GNOSIS_HATS_PROTOCOL).isEligible(probe, DECENTRAL_PARK_NEIGHBOR_HAT);
        require(!eligibleProbeBefore, "Sim: fresh EOA already passes isEligible - state differs from bug report");

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: fix Neighbor default eligibility (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        console.log("\n  Proposal id:", proposalId);

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass");
        console.log("  Winner option:", winner, " valid:", valid);

        // Post-state assertion: defaults flipped.
        (bool eligibleAfter, bool standingAfter) =
            IEligibilityModuleMinimal(DECENTRAL_PARK_EM).getDefaultRules(DECENTRAL_PARK_NEIGHBOR_HAT);
        require(eligibleAfter, "Sim: defaultEligible did not flip to true");
        require(standingAfter, "Sim: defaultStanding regressed to false");

        // Functional verification: a fresh EOA now passes isEligible (i.e. QuickJoin will succeed).
        bool eligibleProbeAfter = IHatsMinimal(GNOSIS_HATS_PROTOCOL).isEligible(probe, DECENTRAL_PARK_NEIGHBOR_HAT);
        require(eligibleProbeAfter, "Sim: fresh EOA still cannot pass isEligible after fix");

        console.log("\n  Post-state:");
        console.log("    defaultEligible:             ", eligibleAfter);
        console.log("    defaultStanding:             ", standingAfter);
        console.log("    fresh EOA isEligible:        ", eligibleProbeAfter);
        console.log("\nPASS: Decentral Park Neighbor eligibility fix landed end-to-end.");
    }

    function _broadcast() internal {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Neighbor eligibility fix proposal ===");
        console.log("  Sender:        ", sender);
        console.log("  Duration (min):", uint256(minutesDuration));

        _printPreview();

        // Sanity: sender must wear an HV creator hat.
        IHatsMinimal hats = IHatsMinimal(GNOSIS_HATS_PROTOCOL);
        uint256[] memory creatorHats = HybridVoting(DECENTRAL_PARK_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on Decentral Park HybridVoting");

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: fix Neighbor default eligibility (set eligible=true so QuickJoin works)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        uint256 newId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        require(newId == idBefore, "Proposal not created");
        console.log("\n  Proposal ID:", newId);
        console.log("  Next: members vote; after expiry anyone calls announceWinner.");
    }
}

contract SimFixDecentralParkNeighborEligibility is FixNeighborBase {
    function run() public {
        _simFullFlow();
    }
}

contract BroadcastFixDecentralParkNeighborEligibility is FixNeighborBase {
    function run() public {
        _broadcast();
    }
}
