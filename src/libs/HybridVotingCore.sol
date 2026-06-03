// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

import "../HybridVoting.sol";
import "./VotingErrors.sol";
import "./VotingMath.sol";
import {IExecutor} from "../Executor.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library HybridVotingCore {
    bytes32 private constant _STORAGE_SLOT = keccak256("poa.hybridvoting.v2.storage");

    event VoteCast(
        uint256 indexed id,
        address indexed voter,
        uint8[] idxs,
        uint8[] weights,
        uint256[] classRawPowers,
        uint64 timestamp
    );
    event Winner(uint256 indexed id, uint256 indexed winningIdx, bool valid, bool executed, uint64 timestamp);
    event ProposalExecuted(uint256 indexed id, uint256 indexed winningIdx, uint256 numCalls);
    event ProposalExecutionFailed(uint256 indexed id, uint256 indexed winningIdx, bytes reason);

    function _layout() private pure returns (HybridVoting.Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function vote(uint256 id, uint8[] calldata idxs, uint8[] calldata weights) external {
        if (idxs.length != weights.length) revert VotingErrors.LengthMismatch();
        if (block.timestamp > _layout()._proposals[id].endTimestamp) revert VotingErrors.VotingExpired();

        HybridVoting.Layout storage l = _layout();
        HybridVoting.Proposal storage p = l._proposals[id];
        address voter = msg.sender;

        // Check poll-level restrictions
        if (p.restricted) {
            bool hasAllowedHat = false;
            uint256 len = p.pollHatIds.length;
            for (uint256 i = 0; i < len;) {
                if (l.hats.isWearerOfHat(voter, p.pollHatIds[i])) {
                    hasAllowedHat = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }
            if (!hasAllowedHat) revert VotingErrors.RoleNotAllowed();
        }

        if (p.hasVoted[voter]) revert VotingErrors.AlreadyVoted();

        // Validate weights
        VotingMath.validateWeights(VotingMath.Weights({idxs: idxs, weights: weights, optionsLen: p.options.length}));

        // Calculate raw power for each class
        uint256 classCount = p.classesSnapshot.length;
        uint256[] memory classRawPowers = new uint256[](classCount);

        for (uint256 c; c < classCount;) {
            HybridVoting.ClassConfig memory cls = p.classesSnapshot[c];
            uint256 rawPower = _calculateClassPower(voter, cls, l);
            classRawPowers[c] = rawPower;
            p.classTotalsRaw[c] += rawPower;
            unchecked {
                ++c;
            }
        }

        // Reject voters with zero power across all classes (prevents quorum inflation via Sybil)
        {
            bool hasAnyPower = false;
            for (uint256 c2; c2 < classCount;) {
                if (classRawPowers[c2] > 0) {
                    hasAnyPower = true;
                    break;
                }
                unchecked {
                    ++c2;
                }
            }
            if (!hasAnyPower) revert VotingErrors.Unauthorized();
        }

        // Accumulate deltas for each option
        uint256 len2 = weights.length;
        for (uint256 i; i < len2;) {
            uint8 ix = idxs[i];
            uint8 weight = weights[i];

            for (uint256 c; c < classCount;) {
                if (classRawPowers[c] > 0) {
                    uint256 delta = (classRawPowers[c] * weight) / 100;
                    if (delta > 0) {
                        uint256 newVal = p.options[ix].classRaw[c] + delta;
                        require(VotingMath.fitsUint128(newVal), "Class raw overflow");
                        p.options[ix].classRaw[c] = uint128(newVal);
                    }
                }
                unchecked {
                    ++c;
                }
            }
            unchecked {
                ++i;
            }
        }

        p.hasVoted[voter] = true;
        unchecked {
            p.voterCount++;
        }
        emit VoteCast(id, voter, idxs, weights, classRawPowers, uint64(block.timestamp));
    }

    function _calculateClassPower(address voter, HybridVoting.ClassConfig memory cls, HybridVoting.Layout storage l)
        internal
        view
        returns (uint256)
    {
        // Hats-native: each class has a single capability hat.
        // Semantic NOTE: `cls.hatId == 0` means "unrestricted" — any voter passes the hat
        // check and accrues power according to the class's strategy (e.g., token-balance).
        // This is INTENTIONALLY DIFFERENT from every other capability-hat gate in the protocol
        // (TaskManager / EducationHub / DDV / QuickJoin / ParticipationToken), where 0 means
        // "disabled / no one passes". The asymmetry exists because HybridVoting classes
        // legitimately model token-only voting tiers (e.g., a quadratic ERC20-balance class
        // with no hat prerequisite). Production deployments should treat 0 as a sentinel for
        // "token/strategy-only" classes; if a class is meant to be disabled, remove it via
        // `setClasses` rather than setting its hatId to 0.
        bool hasClassHat = (voter == address(l.executor)) || (cls.hatId == 0) || l.hats.isWearerOfHat(voter, cls.hatId);

        if (!hasClassHat) return 0;

        if (cls.strategy == HybridVoting.ClassStrategy.DIRECT) {
            return 100; // Direct democracy: 1 person = 100 raw points
        } else if (cls.strategy == HybridVoting.ClassStrategy.ERC20_BAL) {
            uint256 balance = IERC20(cls.asset).balanceOf(voter);
            if (balance < cls.minBalance) return 0;
            uint256 power = cls.quadratic ? VotingMath.sqrt(balance) : balance;
            return power * 100; // Scale to match existing system
        }

        return 0;
    }

    function announceWinner(uint256 id) external returns (uint256 winner, bool valid) {
        HybridVoting.Layout storage l = _layout();
        HybridVoting.Proposal storage p = l._proposals[id];
        if (p.executed) revert VotingErrors.AlreadyExecuted();
        p.executed = true;

        // Check if any votes were cast
        bool hasVotes = false;
        for (uint256 i; i < p.classTotalsRaw.length;) {
            if (p.classTotalsRaw[i] > 0) {
                hasVotes = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (!hasVotes) {
            emit Winner(id, 0, false, false, uint64(block.timestamp));
            return (0, false);
        }

        // Check quorum: minimum number of voters required
        if (l.quorum > 0 && p.voterCount < l.quorum) {
            emit Winner(id, 0, false, false, uint64(block.timestamp));
            return (0, false);
        }

        // Build matrix for N-class winner calculation
        uint256 numOptions = p.options.length;
        uint256 numClasses = p.classesSnapshot.length;
        uint256[][] memory perOptionPerClassRaw = new uint256[][](numOptions);
        uint8[] memory slices = new uint8[](numClasses);

        for (uint256 opt; opt < numOptions;) {
            perOptionPerClassRaw[opt] = new uint256[](numClasses);
            for (uint256 cls; cls < numClasses;) {
                perOptionPerClassRaw[opt][cls] = p.options[opt].classRaw[cls];
                unchecked {
                    ++cls;
                }
            }
            unchecked {
                ++opt;
            }
        }

        for (uint256 cls; cls < numClasses;) {
            slices[cls] = p.classesSnapshot[cls].slicePct;
            unchecked {
                ++cls;
            }
        }

        // Use VotingMath to pick winner with N-class logic
        (winner, valid,,) = VotingMath.pickWinnerNSlices(
            perOptionPerClassRaw,
            p.classTotalsRaw,
            slices,
            l.thresholdPct,
            true // strict majority required
        );

        IExecutor.Call[] storage batch = p.batches[winner];
        bool didExecute = false;
        if (valid && batch.length > 0) {
            try l.executor.execute(id, batch) {
                didExecute = true;
                emit ProposalExecuted(id, winner, batch.length);
            } catch (bytes memory reason) {
                emit ProposalExecutionFailed(id, winner, reason);
            }
        }
        emit Winner(id, winner, valid, didExecute, uint64(block.timestamp));
    }
}
