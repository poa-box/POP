// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {AccessV2PermKeys} from "../../src/libs/AccessV2PermKeys.sol";

/// @notice Authority read double for module behavior tests. The existing membership fixture supplies
///         subject ownership; production modules only call this authority interface. Real authority
///         folding and activation are exercised by MembershipAuthority and AccessV2Acceptance tests.
contract MockModuleAuthority {
    IHats private immutable members;
    address public immutable executor;
    mapping(bytes32 => uint256[]) private subjects;
    mapping(uint256 => mapping(bytes32 => uint256)) private masks;
    uint256[] private maskSubjects;

    constructor(address fixture, address executor_) {
        members = IHats(fixture);
        executor = executor_;
    }

    function setSubjects(bytes32 key, uint256[] memory ids) external {
        subjects[key] = ids;
    }

    function setMask(uint256 subject, bytes32 ctx, uint256 word) external {
        masks[subject][ctx] = word;
        for (uint256 i; i < maskSubjects.length; ++i) {
            if (maskSubjects[i] == subject) return;
        }
        maskSubjects.push(subject);
    }

    function isMember(uint256 subject, address user) public view returns (bool) {
        return members.isWearerOfHat(user, subject);
    }

    function hasPerm(address user, bytes32 key, bytes32 ctx) public view returns (uint256 result) {
        if (key == AccessV2PermKeys.TM_PERMS) {
            for (uint256 i; i < maskSubjects.length; ++i) {
                uint256 id = maskSubjects[i];
                if (!isMember(id, user)) continue;
                uint256 word = masks[id][ctx];
                result |= word == 0 ? masks[id][bytes32(0)] : word;
            }
            return result;
        }
        uint256[] storage ids = subjects[key];
        for (uint256 i; i < ids.length; ++i) {
            if (isMember(ids[i], user)) return 1;
        }
    }

    function activeMemberSince(uint256 subject, address user) external view returns (uint64) {
        return isMember(subject, user) ? 1 : type(uint64).max;
    }

    function activeMemberSince(address user, bytes32 key, bytes32 ctx) external view returns (uint64) {
        return hasPerm(user, key, ctx) == 0 ? type(uint64).max : 1;
    }

    function subjectsWithKey(bytes32 key, bytes32) external view returns (uint256[] memory) {
        return subjects[key];
    }

    function mintHat(uint256 subject, address user) external returns (bool) {
        return members.mintHat(subject, user);
    }
}
