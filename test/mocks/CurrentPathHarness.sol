// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

// HISTORICAL ARTIFACT — the pre-build gas-benchmark prototype. Referenced by NOTHING in the
// build or test graph; kept for the recorded benchmark numbers only. DO NOT sync with the real
// implementation and do not cite its behavior as current.

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {LegacyHatManager as HatManager} from "./LegacyHatManager.sol";

/**
 * @title CurrentPathHarness
 * @notice Thin, faithful harness for the two current-path measurements whose bodies live in
 *         internal library / internal functions and so cannot be called directly against the real
 *         modules:
 *         - {hasAnyHat}: exercises the REAL {HatManager.hasAnyHat} library over a storage array,
 *           calling the REAL (forked) Hats — the exact DD/HV vote hot-path check.
 *         - {permMask}: a verbatim copy of {TaskManager._permMask} (balanceOfBatch over N permission
 *           hats + per-hat global-mask OR), calling the REAL Hats. The mapping is a stand-in for
 *           TaskManager's `rolePermGlobal`; the resolution shape is identical.
 *         No mocks of Hats — the harness is measured on a live Gnosis fork.
 */
contract CurrentPathHarness {
    IHats public immutable hats;
    uint256[] public votingHatIds;
    uint256[] public permissionHatIds;
    mapping(uint256 => uint8) public rolePermGlobal;
    // project override mask, keyed like TaskManager.rolePermProj[pid][hat]
    mapping(bytes32 => mapping(uint256 => uint8)) public rolePermProj;

    constructor(IHats hats_) {
        hats = hats_;
    }

    function setVotingHats(uint256[] calldata ids) external {
        votingHatIds = ids;
    }

    function setPermissionHat(uint256 hatId, uint8 globalMask) external {
        permissionHatIds.push(hatId);
        rolePermGlobal[hatId] = globalMask;
    }

    /// @notice REAL HatManager.hasAnyHat over the configured voting-hat array (DD/HV vote gate).
    function hasAnyHat(address user) external view returns (bool) {
        return HatManager.hasAnyHat(hats, votingHatIds, user);
    }

    /// @notice Verbatim copy of TaskManager._permMask resolution (real balanceOfBatch + mask OR).
    function permMask(address user, bytes32 pid) external view returns (uint8 m) {
        uint256 len = permissionHatIds.length;
        if (len == 0) return 0;

        address[] memory wearers = new address[](len);
        uint256[] memory hats_ = new uint256[](len);
        for (uint256 i; i < len;) {
            wearers[i] = user;
            hats_[i] = permissionHatIds[i];
            unchecked {
                ++i;
            }
        }
        uint256[] memory bal = hats.balanceOfBatch(wearers, hats_);

        for (uint256 i; i < len;) {
            if (bal[i] == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 h = hats_[i];
            uint8 mask = rolePermProj[pid][h];
            m |= mask == 0 ? rolePermGlobal[h] : mask;
            unchecked {
                ++i;
            }
        }
    }
}
