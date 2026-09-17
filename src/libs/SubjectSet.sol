// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @notice A storage set of opaque MembershipAuthority subject identifiers.
library SubjectSet {
    function set(uint256[] storage ids, uint256 id, bool enabled) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] != id) continue;
            if (!enabled) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
            }
            return;
        }
        if (enabled) ids.push(id);
    }
}
