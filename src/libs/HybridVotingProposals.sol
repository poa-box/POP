// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

import "../HybridVoting.sol";
import "./VotingErrors.sol";
import "./VotingMath.sol";
import "./ValidationLib.sol";
import {IExecutor} from "../Executor.sol";

library HybridVotingProposals {
    bytes32 private constant _STORAGE_SLOT = keccak256("poa.hybridvoting.v2.storage");

    uint8 public constant MAX_OPTIONS = 50;
    uint8 public constant MAX_CALLS = 20;
    uint32 public constant MAX_DURATION = 43_200;
    uint32 public constant MIN_DURATION = 10;
    // M-14: cap poll-specific hats — HybridVotingCore.vote() scans p.pollHatIds linearly for
    // restricted polls, so an unbounded array makes every vote() call a gas-griefing target.
    uint16 public constant MAX_POLL_HATS = 100;

    event NewProposal(uint256 id, bytes title, bytes32 descriptionHash, uint8 numOptions, uint64 endTs, uint64 created);
    event NewHatProposal(
        uint256 id,
        bytes title,
        bytes32 descriptionHash,
        uint8 numOptions,
        uint64 endTs,
        uint64 created,
        uint256[] hatIds
    );
    // V2 (RoleManager Phase 2): additive config event carrying per-proposal knobs absent from the
    // legacy NewProposal/NewHatProposal ABIs. Emitted alongside them, never replacing them.
    event ProposalConfigV2(uint256 indexed id, uint32 quorumOverride, bool equalWeight);

    function _layout() private pure returns (HybridVoting.Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function createProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds
    ) external {
        uint256 id = _initProposal(title, descriptionHash, minutesDuration, numOptions, batches, hatIds, false);

        uint64 endTs = _layout()._proposals[id].endTimestamp;

        if (hatIds.length > 0) {
            emit NewHatProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp), hatIds);
        } else {
            emit NewProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp));
        }
    }

    /// @notice V2 proposal creation with per-proposal quorum override and/or equalWeight tally.
    /// @dev Auth (onlyCreator) + pause are enforced by the facade. Rules (PLAN §1.5, H-2):
    ///      overrides/equalWeight are restricted-only; executable proposals raise-only; equalWeight
    ///      snapshots a single synthetic DIRECT class instead of the org classes.
    function createProposalV2(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds,
        uint32 quorumOverride,
        bool equalWeight
    ) external {
        if (hatIds.length == 0 && (quorumOverride != 0 || equalWeight)) {
            revert VotingErrors.InvalidQuorum();
        }

        uint256 id = _initProposal(title, descriptionHash, minutesDuration, numOptions, batches, hatIds, equalWeight);

        HybridVoting.Layout storage l = _layout();
        if (quorumOverride != 0) {
            l.proposalQuorumOverride[id] = quorumOverride;
        }

        uint64 endTs = l._proposals[id].endTimestamp;
        if (hatIds.length > 0) {
            emit NewHatProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp), hatIds);
        } else {
            emit NewProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp));
        }
        emit ProposalConfigV2(id, quorumOverride, equalWeight);
    }

    function _initProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds,
        bool equalWeight
    ) internal returns (uint256) {
        ValidationLib.requireValidTitle(title);
        if (numOptions == 0) revert VotingErrors.LengthMismatch();
        if (numOptions > MAX_OPTIONS) revert VotingErrors.TooManyOptions();
        _validateDuration(minutesDuration);

        HybridVoting.Layout storage l = _layout();
        // equalWeight builds a self-contained synthetic class, so org classes are not required for
        // it; the legacy path still requires at least one configured class.
        if (!equalWeight && l.classes.length == 0) revert VotingErrors.InvalidClassCount();

        bool isExecuting = false;
        if (batches.length > 0) {
            if (numOptions != batches.length) revert VotingErrors.LengthMismatch();
            for (uint256 i; i < numOptions;) {
                if (batches[i].length > 0) {
                    isExecuting = true;
                    _validateTargets(batches[i]);
                }
                unchecked {
                    ++i;
                }
            }
        }

        uint64 endTs = uint64(block.timestamp + minutesDuration * 60);
        HybridVoting.Proposal storage p = l._proposals.push();
        p.endTimestamp = endTs;
        p.restricted = hatIds.length > 0;

        uint256 classCount;
        if (equalWeight) {
            // Snapshot ONE synthetic DIRECT class {slicePct:100, hatIds: pollHatIds} instead of the
            // org classes. _calculateClassPower then yields 100 for any voter wearing a poll hat and
            // 0 otherwise → one-person-one-vote regardless of token balances. vote()/announceWinner()
            // are untouched. equalWeight is restricted-only (guarded in createProposalV2), so
            // pollHatIds is guaranteed non-empty here.
            _snapshotEqualWeightClass(p, hatIds);
            classCount = 1;
        } else {
            _snapshotClasses(p, l);
            classCount = l.classes.length;
        }
        _initOptions(p, numOptions, classCount);

        uint256 id = l._proposals.length - 1;

        if (isExecuting) {
            for (uint256 i; i < numOptions;) {
                p.batches.push(batches[i]);
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < numOptions;) {
                p.batches.push();
                unchecked {
                    ++i;
                }
            }
        }

        if (hatIds.length > 0) {
            uint256 len = hatIds.length;
            if (len > MAX_POLL_HATS) revert VotingErrors.TooManyPollHats(); // M-14
            for (uint256 i; i < len;) {
                p.pollHatIds.push(hatIds[i]);
                p.pollHatAllowed[hatIds[i]] = true;
                unchecked {
                    ++i;
                }
            }
        }

        return id;
    }

    function _validateDuration(uint32 minutesDuration) internal pure {
        if (minutesDuration < MIN_DURATION || minutesDuration > MAX_DURATION) {
            revert VotingErrors.DurationOutOfRange();
        }
    }

    function _validateTargets(IExecutor.Call[] calldata batch) internal pure {
        // NOTE: intentionally no self-target guard. Governance self-amendment is a core feature —
        // setConfig/setClasses/pause/setExecutor are onlyExecutor, so the ONLY way to change
        // HybridVoting's own config is a passed proposal whose batch targets this contract and is
        // executed by the Executor. An earlier L-02 change added a `target == address(this)` revert
        // here; it silently disabled self-amendment and was reverted. Reentrancy during execution
        // is guarded by the `executed` in-flight lock in HybridVotingCore, not by restricting
        // targets. HybridVoting deliberately has no target allow-list (see #74).
        if (batch.length > MAX_CALLS) revert VotingErrors.TooManyCalls();
    }

    function _snapshotClasses(HybridVoting.Proposal storage p, HybridVoting.Layout storage l) internal {
        uint256 classCount = l.classes.length;
        for (uint256 i; i < classCount;) {
            p.classesSnapshot.push(l.classes[i]);
            unchecked {
                ++i;
            }
        }
        p.classTotalsRaw = new uint256[](classCount);
    }

    /// @dev equalWeight snapshot: a single DIRECT class holding 100% of the slice, gated on the
    ///      poll's own hat set. Every eligible voter contributes exactly 100 raw points.
    function _snapshotEqualWeightClass(HybridVoting.Proposal storage p, uint256[] calldata pollHatIds) internal {
        HybridVoting.ClassConfig storage sc = p.classesSnapshot.push();
        sc.strategy = HybridVoting.ClassStrategy.DIRECT;
        sc.slicePct = 100;
        // quadratic=false, minBalance=0, asset=address(0) are the zero defaults for a fresh push.
        uint256 len = pollHatIds.length;
        for (uint256 i; i < len;) {
            sc.hatIds.push(pollHatIds[i]);
            unchecked {
                ++i;
            }
        }
        p.classTotalsRaw = new uint256[](1);
    }

    function _initOptions(HybridVoting.Proposal storage p, uint8 numOptions, uint256 classCount) internal {
        for (uint256 i; i < numOptions;) {
            HybridVoting.PollOption storage opt = p.options.push();
            opt.classRaw = new uint128[](classCount);
            unchecked {
                ++i;
            }
        }
    }
}
