// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

library VotingErrors {
    error Unauthorized();
    error AlreadyVoted();
    error InvalidProposal();
    error VotingExpired();
    error VotingOpen();
    error InvalidIndex();
    error LengthMismatch();
    error DurationOutOfRange();
    error TooManyOptions();
    error TooManyCalls();
    error ZeroAddress();
    error RoleNotAllowed();
    error WeightSumNot100(uint256 sum);
    error InvalidWeight();
    error DuplicateIndex();
    error TargetNotAllowed();
    error EmptyBatch();
    error InvalidThreshold();
    error InvalidQuorum();
    error Paused();
    error Overflow();
    error InvalidClassCount();
    error InvalidSliceSum();
    error TooManyClasses();
    error AlreadyExecuted();
    error TooManyPollHats(); // M-14: poll-specific hat count exceeds MAX_POLL_HATS
}
