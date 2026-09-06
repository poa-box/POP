// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @notice Minimal, fully-settable MembershipAuthority READ surface for the voting modules'
///         dual-path suites (Access v2, workstream B1). Only the three selectors the voting modules
///         consume are implemented — `hasPerm`, the key-folded `activeMemberSince(user,key,ctx)`, and
///         the per-subject `activeMemberSince(subject,user)` — plus a convenience `isMember`.
/// @dev NOT the production authority: state is deterministic and directly poked by tests so the
///      electorate ACTIVATION GATE (activeMemberSince <= proposal.createdAt) and creator gating can be
///      driven exactly. Absent entries return the frozen `type(uint64).max` "not a current member"
///      sentinel (§5.1), which fails every `<= createdAt` check — mirroring the real authority's
///      "folds keys it has never seen" behaviour.
contract MockMembershipAuthority {
    uint64 internal constant NOT_MEMBER = type(uint64).max;

    // hasPerm(user, key, ctx) → packed word. ctx is folded into the key here (the voting modules only
    // ever pass ctx == bytes32(0) for DD_CREATE / DD_VOTE / HV_CREATE), matching §3 global rows.
    mapping(address => mapping(bytes32 => uint256)) internal permWord;

    // key-folded activation: user → key → activation ts (unset ⇒ NOT_MEMBER sentinel).
    mapping(address => mapping(bytes32 => uint64)) internal keyActiveTs;
    mapping(address => mapping(bytes32 => bool)) internal keyActiveSet;

    // per-subject activation: subject → user → activation ts (unset ⇒ NOT_MEMBER sentinel).
    mapping(uint256 => mapping(address => uint64)) internal subjActiveTs;
    mapping(uint256 => mapping(address => bool)) internal subjActiveSet;

    /*───────────────────────────── test pokes ─────────────────────────────*/

    /// @notice Set the hasPerm word for `user` at `key` (top bit = exists; nonzero ⇒ permitted).
    function setPerm(address user, bytes32 key, uint256 word) external {
        permWord[user][key] = word;
    }

    /// @notice Grant/clear a boolean perm (word = EXISTS_BIT | 1 when granted, 0 when cleared).
    function setPermBool(address user, bytes32 key, bool ok) external {
        permWord[user][key] = ok ? ((uint256(1) << 255) | 1) : 0;
    }

    /// @notice Set the key-folded activation timestamp for `user` at `key`.
    function setKeyActive(address user, bytes32 key, uint64 ts) external {
        keyActiveTs[user][key] = ts;
        keyActiveSet[user][key] = true;
    }

    /// @notice Set the per-subject activation timestamp for `user` on `subject`.
    function setSubjectActive(uint256 subject, address user, uint64 ts) external {
        subjActiveTs[subject][user] = ts;
        subjActiveSet[subject][user] = true;
    }

    /// @notice Clear a per-subject activation (reverts the entry to the NOT_MEMBER sentinel).
    function clearSubjectActive(uint256 subject, address user) external {
        subjActiveSet[subject][user] = false;
    }

    /*───────────────────────────── read surface ─────────────────────────────*/

    function hasPerm(
        address user,
        bytes32 key,
        bytes32 /*ctx*/
    )
        external
        view
        returns (uint256)
    {
        return permWord[user][key];
    }

    function activeMemberSince(
        address user,
        bytes32 key,
        bytes32 /*ctx*/
    )
        external
        view
        returns (uint64)
    {
        return keyActiveSet[user][key] ? keyActiveTs[user][key] : NOT_MEMBER;
    }

    function activeMemberSince(uint256 subject, address user) external view returns (uint64) {
        return subjActiveSet[subject][user] ? subjActiveTs[subject][user] : NOT_MEMBER;
    }

    function isMember(uint256 subject, address user) external view returns (bool) {
        return subjActiveSet[subject][user] && subjActiveTs[subject][user] != NOT_MEMBER;
    }
}
