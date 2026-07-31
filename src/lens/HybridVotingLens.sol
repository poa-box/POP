// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

import {HybridVoting} from "../HybridVoting.sol";

/// @title HybridVotingLens
/// @notice Read-only aggregation helpers over a HybridVoting instance for off-chain callers.
contract HybridVotingLens {
    /// @notice Number of creator hats configured on the voting contract.
    function getCreatorHatCount(HybridVoting voting) external view returns (uint256) {
        uint256[] memory hats = voting.creatorHats();
        return hats.length;
    }

    /// @notice Unix timestamp at which voting on proposal `id` closes.
    /// @dev L-05: now backed by HybridVoting.proposalEndTimestamp (was a dead getter returning 0).
    ///      Reverts (via the exists modifier on the underlying getter) for out-of-range ids.
    function getProposalEndTimestamp(HybridVoting voting, uint256 id) external view returns (uint64) {
        return voting.proposalEndTimestamp(id);
    }

    /// @notice For each hat in `hatIds`, whether it is allowed to vote on proposal `proposalId`.
    function getAllProposalHatIds(HybridVoting voting, uint256 proposalId, uint256[] calldata hatIds)
        external
        view
        returns (bool[] memory)
    {
        bool[] memory allowed = new bool[](hatIds.length);
        for (uint256 i = 0; i < hatIds.length; i++) {
            allowed[i] = voting.pollHatAllowed(proposalId, hatIds[i]);
        }
        return allowed;
    }

    /// @notice True while proposal `id` is still open for voting (now < endTimestamp).
    /// @dev L-05: real active check against the proposal end timestamp (was a tautology that
    ///      always returned true). Reverts for out-of-range ids via the underlying getter.
    function isProposalActive(HybridVoting voting, uint256 id) external view returns (bool) {
        return block.timestamp < voting.proposalEndTimestamp(id);
    }
}
