// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {ValidationLib} from "../libs/ValidationLib.sol";

interface ITaskManager {
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

/**
 * @title TaskManagerLens
 * @notice External view functions for TaskManager, primarily for testing and debugging
 * @dev Separated from main contract to reduce bytecode size
 */
contract TaskManagerLens {
    /*──────── Enums ────────*/
    enum StorageKey {
        HATS,
        EXECUTOR,
        CREATOR_HATS,
        CREATOR_HAT_COUNT,
        PERMISSION_HATS,
        PERMISSION_HAT_COUNT,
        VERSION,
        TASK_INFO,
        TASK_FULL_INFO,
        PROJECT_INFO,
        TASK_APPLICANTS,
        TASK_APPLICATION,
        TASK_APPLICANT_COUNT,
        HAS_APPLIED_FOR_TASK,
        BOUNTY_BUDGET,
        TASK_DEADLINES
    }

    enum Status {
        UNCLAIMED,
        CLAIMED,
        SUBMITTED,
        COMPLETED,
        CANCELLED
    }

    /*──────── Unified Storage Getter ─────── */
    function getStorage(address taskManager, StorageKey key, bytes calldata params)
        external
        view
        returns (bytes memory)
    {
        ITaskManager tm = ITaskManager(taskManager);

        if (key == StorageKey.HATS) {
            return tm.getLensData(3, "");
        } else if (key == StorageKey.EXECUTOR) {
            return tm.getLensData(4, "");
        } else if (key == StorageKey.CREATOR_HATS) {
            return tm.getLensData(5, "");
        } else if (key == StorageKey.CREATOR_HAT_COUNT) {
            uint256[] memory hats = abi.decode(tm.getLensData(5, ""), (uint256[]));
            return abi.encode(hats.length);
        } else if (key == StorageKey.PERMISSION_HATS) {
            return tm.getLensData(6, "");
        } else if (key == StorageKey.PERMISSION_HAT_COUNT) {
            uint256[] memory hats = abi.decode(tm.getLensData(6, ""), (uint256[]));
            return abi.encode(hats.length);
        } else if (key == StorageKey.VERSION) {
            return abi.encode("v2");
        } else if (key == StorageKey.TASK_INFO) {
            uint256 id = abi.decode(params, (uint256));
            bytes memory data = tm.getLensData(1, params);
            (
                bytes32 projectId,
                uint96 payout,
                address claimer,, // bountyPayout
                bool requiresApplication,
                Status status,
                // bountyToken
            ) = abi.decode(data, (bytes32, uint96, address, uint96, bool, Status, address));
            return abi.encode(payout, status, claimer, projectId, requiresApplication);
        } else if (key == StorageKey.TASK_FULL_INFO) {
            uint256 id = abi.decode(params, (uint256));
            bytes memory data = tm.getLensData(1, params);
            (
                bytes32 projectId,
                uint96 payout,
                address claimer,
                uint96 bountyPayout,
                bool requiresApplication,
                Status status,
                address bountyToken,
                uint48 absoluteDeadline,
                uint32 completionWindow,
                uint48 claimDeadline
            ) = abi.decode(data, (bytes32, uint96, address, uint96, bool, Status, address, uint48, uint32, uint48));
            return abi.encode(
                payout,
                bountyPayout,
                bountyToken,
                status,
                claimer,
                projectId,
                requiresApplication,
                absoluteDeadline,
                completionWindow,
                claimDeadline
            );
        } else if (key == StorageKey.PROJECT_INFO) {
            bytes32 pid = abi.decode(params, (bytes32));
            bytes memory data = tm.getLensData(2, params);
            (uint128 cap, uint128 spent, bool exists) = abi.decode(data, (uint128, uint128, bool));
            return abi.encode(cap, spent, false); // isManager always false for now since we don't pass caller context
        } else if (key == StorageKey.TASK_APPLICANTS) {
            uint256 id = abi.decode(params, (uint256));
            return tm.getLensData(7, params);
        } else if (key == StorageKey.TASK_APPLICATION) {
            (uint256 id, address applicant) = abi.decode(params, (uint256, address));
            return tm.getLensData(8, params);
        } else if (key == StorageKey.TASK_APPLICANT_COUNT) {
            uint256 id = abi.decode(params, (uint256));
            address[] memory applicants = abi.decode(tm.getLensData(7, params), (address[]));
            return abi.encode(applicants.length);
        } else if (key == StorageKey.HAS_APPLIED_FOR_TASK) {
            (uint256 id, address applicant) = abi.decode(params, (uint256, address));
            bytes32 application = abi.decode(tm.getLensData(8, params), (bytes32));
            return abi.encode(application);
        } else if (key == StorageKey.BOUNTY_BUDGET) {
            (bytes32 pid, address token) = abi.decode(params, (bytes32, address));
            if (token == address(0)) revert ValidationLib.ZeroAddress();
            bytes memory data = tm.getLensData(9, params);
            (uint128 cap, uint128 spent) = abi.decode(data, (uint128, uint128));
            return abi.encode(cap, spent);
        } else if (key == StorageKey.TASK_DEADLINES) {
            // v6: (uint48 absoluteDeadline, uint32 completionWindow, uint48 claimDeadline)
            bytes memory data = tm.getLensData(1, params);
            (,,,,,,, uint48 absoluteDeadline, uint32 completionWindow, uint48 claimDeadline) =
                abi.decode(data, (bytes32, uint96, address, uint96, bool, Status, address, uint48, uint32, uint48));
            return abi.encode(absoluteDeadline, completionWindow, claimDeadline);
        }

        revert("Invalid index");
    }

    // Overloaded version for compatibility with tests that don't pass taskManager
    function getStorage(StorageKey key, bytes calldata params) external view returns (bytes memory) {
        // For backward compatibility, assume msg.sender is the TaskManager
        return this.getStorage(msg.sender, key, params);
    }
}
