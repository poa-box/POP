// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {AccessV2Types} from "./AccessV2Types.sol";
import {AccessV2PermKeys} from "./AccessV2PermKeys.sol";
import {RoleConfigStructs} from "./RoleConfigStructs.sol";

/**
 * @title OrgAccessSeedLib
 * @notice Translates a new org's deploy-time role/group description into the genesis
 *         {AccessV2Types.OrgAccessSeed} consumed by `MembershipAuthority.initialize`.
 * @dev Subject order is fixed and is what makes ids predictable: the ADMIN subject is index 0 (the
 *      §6 lock-out guard wants admin/operator subjects first), then one ROLE subject per configured
 *      role, then one GROUP subject per configured group. `subjectIds` are left at 0 so the authority
 *      allocates them from its own address — id k is `AccessV2Ids.newSubjectId(authority, k + 1)`.
 *      Every subject reference uses the seed's index convention (a value < 2^64 is an index into
 *      `subjectIds`), so nothing here needs the authority address.
 */
library OrgAccessSeedLib {
    /// @notice Index of the ADMIN subject inside the genesis seed.
    uint256 internal constant ADMIN_SUBJECT_INDEX = 0;

    /// @notice Name of the ADMIN subject. Its sole member is the org Executor; it is the org-admin
    ///         subject the PaymasterHub resolves through the router.
    string internal constant ADMIN_SUBJECT_NAME = "ADMIN";

    /// @notice Role-index bitmaps and per-project-free permission rows, one field per permission key.
    /// @dev Bit N set = role N holds the key. These are the same booleans the pre-v2 deploy expressed
    ///      as hat arrays on each module; in v2 they become perm-table rows on the role subject.
    struct PermConfig {
        uint256 quickJoinRolesBitmap; // QJ_AUTOJOIN
        uint256 tokenMemberRolesBitmap; // PT_MEMBER
        uint256 tokenApproverRolesBitmap; // PT_APPROVE
        uint256 educationCreatorRolesBitmap; // EDU_CREATE
        uint256 educationMemberRolesBitmap; // EDU_MEMBER
        uint256 hybridProposalCreatorRolesBitmap; // HV_CREATE
        uint256 ddVotingRolesBitmap; // DD_VOTE
        uint256 ddCreatorRolesBitmap; // DD_CREATE
        uint256[] tmRoleIndices; // TM_PERMS (global ctx) role indices …
        uint256[] tmMasks; // … and their TaskPerm masks (index-aligned)
        uint256 metadataAdminRoleIndex; // SUBJECT_RENAME; >= roles.length = skip
    }

    /// @notice Build the genesis seed for `roles` + `groups` with the permission rows in `perms`.
    function build(
        RoleConfigStructs.RoleConfig[] memory roles,
        RoleConfigStructs.GroupConfig[] memory groups,
        PermConfig memory perms
    ) internal pure returns (AccessV2Types.OrgAccessSeed memory seed) {
        uint256 n = roles.length;
        uint256 g = groups.length;
        uint256 total = 1 + n + g;

        seed.subjectIds = new uint256[](total); // all zero => the authority allocates v2 ids
        seed.subjectKinds = new AccessV2Types.SubjectKind[](total);
        seed.subjectNames = new string[](total);
        seed.subjectMaxMembers = new uint32[](total);
        seed.subjectDefaults = new bool[](total);
        seed.groupMemberRoles = new uint256[][](total);

        seed.subjectKinds[ADMIN_SUBJECT_INDEX] = AccessV2Types.SubjectKind.Role;
        seed.subjectNames[ADMIN_SUBJECT_INDEX] = ADMIN_SUBJECT_NAME;
        seed.groupMemberRoles[ADMIN_SUBJECT_INDEX] = new uint256[](0);

        for (uint256 i; i < n; ++i) {
            uint256 k = 1 + i;
            seed.subjectKinds[k] = AccessV2Types.SubjectKind.Role;
            seed.subjectNames[k] = roles[i].name;
            seed.subjectMaxMembers[k] = roles[i].maxMembers;
            seed.subjectDefaults[k] = roles[i].open;
            seed.groupMemberRoles[k] = new uint256[](0);
        }

        for (uint256 j; j < g; ++j) {
            uint256 k = 1 + n + j;
            seed.subjectKinds[k] = AccessV2Types.SubjectKind.Group;
            seed.subjectNames[k] = groups[j].name;
            uint256 m = groups[j].memberRoleIndices.length;
            uint256[] memory members = new uint256[](m);
            for (uint256 x; x < m; ++x) {
                members[x] = roleRef(groups[j].memberRoleIndices[x]);
            }
            seed.groupMemberRoles[k] = members;
        }

        _buildVouchRows(seed, roles);
        _buildPermRows(seed, n, perms);
    }

    /// @notice Seed index of role `roleIndex` (the ADMIN subject occupies index 0).
    function roleRef(uint256 roleIndex) internal pure returns (uint256) {
        return roleIndex + 1;
    }

    /// @notice Seed index of group `groupIndex` for a config with `roleCount` roles.
    function groupRef(uint256 roleCount, uint256 groupIndex) internal pure returns (uint256) {
        return 1 + roleCount + groupIndex;
    }

    /// @notice The perm word for a boolean (`TAG_BOOL_ANY`) key: present, value 1.
    function boolWord() internal pure returns (uint256) {
        return AccessV2PermKeys.EXISTS_BIT | 1;
    }

    /// @notice The perm word for an OR-mask key carrying `mask`.
    function maskWord(uint256 mask) internal pure returns (uint256) {
        return AccessV2PermKeys.EXISTS_BIT | (mask & AccessV2PermKeys.VALUE_MASK);
    }

    /*────────────────────────────  Internals  ───────────────────────────────*/

    function _buildVouchRows(AccessV2Types.OrgAccessSeed memory seed, RoleConfigStructs.RoleConfig[] memory roles)
        private
        pure
    {
        uint256 n = roles.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (roles[i].vouching.enabled) ++count;
        }
        seed.vouchSubjects = new uint256[](count);
        seed.vouchQuorums = new uint32[](count);
        seed.vouchVoucherSubjects = new uint256[](count);
        uint256 w;
        for (uint256 i; i < n; ++i) {
            if (!roles[i].vouching.enabled) continue;
            seed.vouchSubjects[w] = roleRef(i);
            seed.vouchQuorums[w] = roles[i].vouching.quorum;
            seed.vouchVoucherSubjects[w] = roleRef(roles[i].vouching.voucherRoleIndex);
            ++w;
        }
    }

    function _buildPermRows(AccessV2Types.OrgAccessSeed memory seed, uint256 n, PermConfig memory perms) private pure {
        uint256 count = _popcount(perms.quickJoinRolesBitmap, n) + _popcount(perms.tokenMemberRolesBitmap, n)
            + _popcount(perms.tokenApproverRolesBitmap, n) + _popcount(perms.educationCreatorRolesBitmap, n)
            + _popcount(perms.educationMemberRolesBitmap, n) + _popcount(perms.hybridProposalCreatorRolesBitmap, n)
            + _popcount(perms.ddVotingRolesBitmap, n) + _popcount(perms.ddCreatorRolesBitmap, n)
            + perms.tmRoleIndices.length + (perms.metadataAdminRoleIndex < n ? 1 : 0);

        seed.permSubjects = new uint256[](count);
        seed.permKeys = new bytes32[](count);
        seed.permCtxs = new bytes32[](count);
        seed.permWords = new uint256[](count);

        uint256 w;
        w = _writeBitmap(seed, w, n, perms.quickJoinRolesBitmap, AccessV2PermKeys.QJ_AUTOJOIN);
        w = _writeBitmap(seed, w, n, perms.tokenMemberRolesBitmap, AccessV2PermKeys.PT_MEMBER);
        w = _writeBitmap(seed, w, n, perms.tokenApproverRolesBitmap, AccessV2PermKeys.PT_APPROVE);
        w = _writeBitmap(seed, w, n, perms.educationCreatorRolesBitmap, AccessV2PermKeys.EDU_CREATE);
        w = _writeBitmap(seed, w, n, perms.educationMemberRolesBitmap, AccessV2PermKeys.EDU_MEMBER);
        w = _writeBitmap(seed, w, n, perms.hybridProposalCreatorRolesBitmap, AccessV2PermKeys.HV_CREATE);
        w = _writeBitmap(seed, w, n, perms.ddVotingRolesBitmap, AccessV2PermKeys.DD_VOTE);
        w = _writeBitmap(seed, w, n, perms.ddCreatorRolesBitmap, AccessV2PermKeys.DD_CREATE);

        // Org-wide TaskManager masks live at ctx 0; per-project rows are governance-time writes.
        for (uint256 i; i < perms.tmRoleIndices.length; ++i) {
            seed.permSubjects[w] = roleRef(perms.tmRoleIndices[i]);
            seed.permKeys[w] = AccessV2PermKeys.TM_PERMS;
            seed.permWords[w] = maskWord(perms.tmMasks[i]);
            ++w;
        }

        if (perms.metadataAdminRoleIndex < n) {
            seed.permSubjects[w] = roleRef(perms.metadataAdminRoleIndex);
            seed.permKeys[w] = AccessV2PermKeys.SUBJECT_RENAME;
            seed.permWords[w] = boolWord();
            ++w;
        }
    }

    function _writeBitmap(AccessV2Types.OrgAccessSeed memory seed, uint256 w, uint256 n, uint256 bitmap, bytes32 key)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < n; ++i) {
            if (bitmap & (1 << i) == 0) continue;
            seed.permSubjects[w] = roleRef(i);
            seed.permKeys[w] = key;
            seed.permWords[w] = boolWord();
            ++w;
        }
        return w;
    }

    function _popcount(uint256 bitmap, uint256 n) private pure returns (uint256 c) {
        for (uint256 i; i < n; ++i) {
            if (bitmap & (1 << i) != 0) ++c;
        }
    }
}
