// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

import "../HybridVoting.sol";
import "./VotingErrors.sol";
import {SubjectSet} from "./SubjectSet.sol";

library HybridVotingConfig {
    bytes32 private constant _STORAGE_SLOT = keccak256("poa.hybridvoting.v2.storage");

    uint8 public constant MAX_CLASSES = 8;

    event ClassesReplaced(
        uint256 indexed version, bytes32 indexed classesHash, HybridVoting.ClassConfig[] classes, uint64 timestamp
    );
    // V2 (RoleManager Phase 2): incremental single-hat edit to a class's voter set. `added` = true
    // for addHatToClass, false for removeHatFromClass. Slice percentages are never touched.
    event ClassHatSet(uint8 indexed classIdx, uint256 indexed hatId, bool added);
    // Access v2 (§4): a positional class index is bound to an authority subject id. `classId` is the
    // stable id allocated for `classIdx` (idx→classId linkage), `subjectId == 0` clears the binding.
    event ClassSubjectSet(uint256 indexed classId, uint256 indexed classIdx, uint256 indexed subjectId);

    function _layout() private pure returns (HybridVoting.Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function setClasses(HybridVoting.ClassConfig[] calldata newClasses) external {
        if (newClasses.length == 0) revert VotingErrors.InvalidClassCount();
        if (newClasses.length > MAX_CLASSES) revert VotingErrors.TooManyClasses();

        uint256 totalSlice;
        for (uint256 i; i < newClasses.length;) {
            HybridVoting.ClassConfig calldata c = newClasses[i];
            if (c.slicePct == 0 || c.slicePct > 100) revert VotingErrors.InvalidSliceSum();
            totalSlice += c.slicePct;

            if (c.strategy == HybridVoting.ClassStrategy.ERC20_BAL) {
                if (c.asset == address(0)) revert VotingErrors.ZeroAddress();
            }
            unchecked {
                ++i;
            }
        }

        if (totalSlice != 100) revert VotingErrors.InvalidSliceSum();

        HybridVoting.Layout storage l = _layout();
        delete l.classes;
        for (uint256 i; i < newClasses.length;) {
            l.classes.push(newClasses[i]);
            unchecked {
                ++i;
            }
        }

        bytes32 classesHash = keccak256(abi.encode(newClasses));
        emit ClassesReplaced(block.number, classesHash, l.classes, uint64(block.timestamp));
    }

    /// @notice Add a single hat to class `classIdx`'s voter set (idempotent — no-op if present).
    /// @dev Auth is enforced by the facade (executor only). Reverts InvalidClassCount if
    ///      `classIdx` is out of bounds. Slice percentages are untouched, so no sum re-validation.
    function addHatToClass(uint8 classIdx, uint256 hatId) external {
        HybridVoting.Layout storage l = _layout();
        if (classIdx >= l.classes.length) revert VotingErrors.InvalidClassCount();
        SubjectSet.set(l.classes[classIdx].hatIds, hatId, true);
        emit ClassHatSet(classIdx, hatId, true);
    }

    /// @notice Remove a single hat from class `classIdx`'s voter set (idempotent — no-op if absent).
    /// @dev Auth is enforced by the facade (executor only). Reverts InvalidClassCount if
    ///      `classIdx` is out of bounds. Slice percentages are untouched.
    function removeHatFromClass(uint8 classIdx, uint256 hatId) external {
        HybridVoting.Layout storage l = _layout();
        if (classIdx >= l.classes.length) revert VotingErrors.InvalidClassCount();
        SubjectSet.set(l.classes[classIdx].hatIds, hatId, false);
        emit ClassHatSet(classIdx, hatId, false);
    }

    /// @notice Bind positional class index `classIdx` to authority subject `subjectId` (§4). Allocates
    ///         the stable classId for `classIdx` on first use and records the idx→classId linkage.
    /// @dev Auth is enforced by the facade (executor only). ALLOCATION IS FROZEN HERE: the
    ///      first setClassSubject for an idx assigns `classId = ++classSubjectSeq` and writes
    ///      `classIdOfIdx[classIdx] = classId`; subsequent calls reuse the allocated id (so the stable
    ///      subject binding survives positional class churn). `subjectId == 0` clears the binding — the
    ///      class then falls back to its legacy `hatIds`. Emits ClassSubjectSet.
    function setClassSubject(uint256 classIdx, uint256 subjectId) external {
        HybridVoting.Layout storage l = _layout();
        uint256 classId = l.classIdOfIdx[classIdx];
        if (classId == 0) {
            classId = ++l.classSubjectSeq;
            l.classIdOfIdx[classIdx] = classId;
        }
        l.classSubject[classId] = subjectId;
        emit ClassSubjectSet(classId, classIdx, subjectId);
    }

    function validateAndInitClasses(HybridVoting.ClassConfig[] calldata initialClasses) external {
        if (initialClasses.length == 0) revert VotingErrors.InvalidClassCount();
        if (initialClasses.length > MAX_CLASSES) revert VotingErrors.TooManyClasses();

        uint256 totalSlice;
        for (uint256 i; i < initialClasses.length;) {
            HybridVoting.ClassConfig calldata c = initialClasses[i];
            if (c.slicePct == 0 || c.slicePct > 100) revert VotingErrors.InvalidSliceSum();
            totalSlice += c.slicePct;

            if (c.strategy == HybridVoting.ClassStrategy.ERC20_BAL) {
                if (c.asset == address(0)) revert VotingErrors.ZeroAddress();
            }

            _layout().classes.push(initialClasses[i]);
            unchecked {
                ++i;
            }
        }

        if (totalSlice != 100) revert VotingErrors.InvalidSliceSum();

        HybridVoting.Layout storage l = _layout();
        bytes32 classesHash = keccak256(abi.encode(l.classes));
        emit ClassesReplaced(block.number, classesHash, l.classes, uint64(block.timestamp));
    }
}
