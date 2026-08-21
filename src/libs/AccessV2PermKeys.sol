// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @title AccessV2PermKeys — protocol-defined permission-key constants (ACCESS-V2-SPEC.md §3).
/// @dev THE FOLD TAG IS THE TOP BYTE of each key: 0x00 = bool-any, 0x01 = OR-mask, 0x02 = MAX. The
///      authority folds keys it has never seen (no stored tag registry, zero extra SLOADs); a new
///      module ships a new key constant + rulebook entry + subgraph template and NEVER touches
///      authority code. No key in this spec uses MAX — the tag is RESERVED so adding a scalar key
///      later is a new constant, not a semantics migration (rejected-findings §1).
///
///      ctx CONVENTION (§3): ctx == bytes32(0) is GLOBAL; ctx == bytes32(projectId) is TaskManager
///      per-project. CTX RESOLUTION: project entry exists ? (inheritGlobal ? COMBINE(global,project)
///      : project) : global, where COMBINE is the key's top-byte fold tag.
///
///      KEY DERIVATION: `key = (uint256(tag) << 248) | (uint256(keccak256(label)) >> 8)` — the low
///      248 bits are a domain-separated label hash, the top byte is the fold tag.
library AccessV2PermKeys {
    // Fold tags (top byte of the key).
    uint8 internal constant TAG_BOOL_ANY = 0x00; // membership-in-any-holding-subject boolean
    uint8 internal constant TAG_OR_MASK = 0x01; // OR-fold of bitmask words (TaskManager permission mask)
    uint8 internal constant TAG_MAX = 0x02; // RESERVED — MAX-fold of a scalar; unused in v1

    // ── DirectDemocracy (bool-any) ──
    bytes32 internal constant DD_VOTE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.dd.vote")) >> 8));
    bytes32 internal constant DD_CREATE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.dd.create")) >> 8));

    // ── HybridVoting (bool-any) ── (class MEMBERSHIP is via classSubject, §4; this gates creation)
    bytes32 internal constant HV_CREATE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.hv.create")) >> 8));

    // ── TaskManager (OR-mask) ── ctx = projectId; value is the TaskPerm bitmask (uint8 saturation gone, §4)
    bytes32 internal constant TM_PERMS =
        bytes32((uint256(TAG_OR_MASK) << 248) | (uint256(keccak256("poa.perm.tm.perms")) >> 8));

    // ── ParticipationToken (bool-any) ──
    bytes32 internal constant PT_MEMBER =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.pt.member")) >> 8));
    bytes32 internal constant PT_APPROVE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.pt.approve")) >> 8));

    // ── EducationHub (bool-any) ──
    bytes32 internal constant EDU_CREATE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.edu.create")) >> 8));
    bytes32 internal constant EDU_MEMBER =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.edu.member")) >> 8));

    // ── QuickJoin (bool-any) ── default-ALLOW auto-join roles
    bytes32 internal constant QJ_AUTOJOIN =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.qj.autojoin")) >> 8));

    // ── PaymentManager (bool-any) ──
    bytes32 internal constant PAY_CREATE =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.pay.create")) >> 8));

    // ── Subject metadata (bool-any) ── AUTH key for renameSubject (§1/§2; seeded from metadataAdmin)
    bytes32 internal constant SUBJECT_RENAME =
        bytes32((uint256(TAG_BOOL_ANY) << 248) | (uint256(keccak256("poa.perm.subject.rename")) >> 8));

    // §3 perm word packing constants.
    uint256 internal constant EXISTS_BIT = 1 << 255;
    uint256 internal constant INHERIT_GLOBAL_BIT = 1 << 254;
    uint256 internal constant VALUE_MASK = (1 << 254) - 1;

    /// @notice The fold tag = top byte of the key.
    function foldTag(bytes32 key) internal pure returns (uint8) {
        return uint8(uint256(key) >> 248);
    }
}
