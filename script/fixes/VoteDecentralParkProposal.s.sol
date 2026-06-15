// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) — vote on a HybridVoting proposal directly
 * ============================================================================
 *
 * For when the subgraph/frontend is down: reads the proposal id straight from
 * the HybridVoting contract (latest = proposalsCount - 1) and casts a 100%
 * vote for one option. No subgraph dependency.
 *
 * Defaults to the LATEST proposal and option 0 (the single "approve" option
 * these governance proposals use). Override either via env.
 *
 * Usage:
 *   # Sim (no broadcast — confirm the vote lands on a fork; pranks Hudson)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/VoteDecentralParkProposal.s.sol:SimVoteDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (casts your real vote)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/VoteDecentralParkProposal.s.sol:BroadcastVoteDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   PROPOSAL_ID  — which proposal to vote on (default = latest = proposalsCount-1)
 *   VOTE_OPTION  — option index to back 100% (default 0)
 * ============================================================================
 */

address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;

// Verified Delegate-hat wearer — pranked in the sim so the vote resolves against real Hats state.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

abstract contract VoteBase is Script {
    function _resolveProposalId() internal view returns (uint256) {
        uint256 count = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();
        require(count > 0, "no proposals on this HybridVoting");
        return vm.envOr("PROPOSAL_ID", count - 1);
    }

    function _resolveOption() internal view returns (uint8) {
        return uint8(vm.envOr("VOTE_OPTION", uint256(0)));
    }

    /// @dev Single-choice ballot: 100% weight to `option`.
    function _ballot(uint8 option) internal pure returns (uint8[] memory idxs, uint8[] memory weights) {
        idxs = new uint8[](1);
        weights = new uint8[](1);
        idxs[0] = option;
        weights[0] = 100;
    }
}

contract SimVoteDecentralPark is VoteBase {
    function run() public {
        uint256 count = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();
        uint256 id = _resolveProposalId();
        uint8 option = _resolveOption();
        console.log("=== Vote sim (Decentral Park) ===");
        console.log("  HybridVoting:  ", DECENTRAL_PARK_HV);
        console.log("  proposalsCount:", count);
        console.log("  voting proposal id:", id, " option:", option);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot(option);

        // Prank Hudson (real Delegate-hat wearer) so class-hat checks resolve against real Hats.
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(id, idxs, weights);
        console.log("  vote cast (no revert).");

        // Informational: warp past the window and check whether this vote passes it.
        vm.warp(block.timestamp + 31 days);
        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(id);
        console.log("  announceWinner -> winner option:", winner, " valid:", valid);
        require(valid, "Sim: proposal does NOT pass with just this vote (needs more voters/quorum)");
        console.log("PASS: vote lands and the proposal passes.");
    }
}

contract BroadcastVoteDecentralPark is VoteBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address voter = vm.addr(key);

        uint256 count = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();
        uint256 id = _resolveProposalId();
        uint8 option = _resolveOption();

        console.log("=== Casting vote (Decentral Park) ===");
        console.log("  Voter:         ", voter);
        console.log("  HybridVoting:  ", DECENTRAL_PARK_HV);
        console.log("  proposalsCount:", count);
        console.log("  voting proposal id:", id, " option:", option);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot(option);

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV).vote(id, idxs, weights);
        vm.stopBroadcast();

        console.log("  Vote submitted for proposal", id);
        console.log("  After the window expires, anyone calls announceWinner(", id, ") to execute.");
    }
}
