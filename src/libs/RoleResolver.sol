// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title RoleResolver
 * @notice Expands a deploy-time role-index bitmap into the org's authority SUBJECT ids.
 * @dev Access v2: the subject ids are derived from the authority address at deploy and handed to
 *      every factory directly, so resolution is a pure memory lookup — nothing reads them back out
 *      of OrgRegistry's Hats-era role list.
 */
library RoleResolver {
    /// @notice Thrown when a bitmap addresses a role index the org does not have.
    /// @dev OrgDeployer rejects out-of-range bits up front; this is the factory-side backstop, and it
    ///      matters because a zero id stored as an "authorized" subject would silently grant nobody.
    error UnregisteredRole(uint256 roleIdx);

    /**
     * @notice Resolves a bitmap of role indices to the matching subject ids.
     * @dev Bit N set = role index N. Results follow ascending role-index order.
     * @param roleSubjectIds Authority subject id per role index
     * @param rolesBitmap Bitmap where bit N set means role N is assigned
     * @return subjectIds The selected subject ids
     */
    function resolveRoleBitmap(uint256[] memory roleSubjectIds, uint256 rolesBitmap)
        internal
        pure
        returns (uint256[] memory subjectIds)
    {
        if (rolesBitmap == 0) return new uint256[](0);

        uint256 count = _countSetBits(rolesBitmap);
        subjectIds = new uint256[](count);

        uint256 index;
        for (uint256 roleIdx = 0; roleIdx < 256; roleIdx++) {
            if ((rolesBitmap & (1 << roleIdx)) == 0) continue;
            if (roleIdx >= roleSubjectIds.length || roleSubjectIds[roleIdx] == 0) {
                revert UnregisteredRole(roleIdx);
            }
            subjectIds[index++] = roleSubjectIds[roleIdx];
            if (index == count) break;
        }
    }

    /// @dev Brian Kernighan's population count.
    function _countSetBits(uint256 bitmap) private pure returns (uint256 count) {
        while (bitmap != 0) {
            bitmap &= bitmap - 1; // clear lowest set bit
            count++;
        }
    }
}
