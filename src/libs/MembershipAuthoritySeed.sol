// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {AccessV2Types} from "./AccessV2Types.sol";
import {AccessV2Ids} from "./AccessV2Ids.sol";
import {MembershipAuthorityLogic as Logic} from "./MembershipAuthorityLogic.sol";

/// @title MembershipAuthoritySeed
/// @notice SECOND DELEGATECALL library of {MembershipAuthority} — the seed / migration surface
///         (§4.9 / §6): genesis seed application plus the executor-gated batch seeders. Split out of
///         {MembershipAuthorityLogic} purely for EIP-170 headroom (the combined cold surface exceeded
///         24,576 B). It shares the ONE canonical {Logic.Layout} declaration and reaches storage via
///         `Logic.layout()`, so the "byte-identical mirror" obligation is met by SHARING, not copying;
///         the slot-mirror sync test pins the constant across all three units.
/// @dev All functions are `external` (deployed separately; hub reaches them via DELEGATECALL, so
///      msg.sender / address(this) / storage are the hub's). The seeders inline {Logic}'s `internal`
///      write helpers (_createSubject / _addRoleToGroup / _configureVouch / _setPerm / _writeRuleEmit
///      / _flipOn) so their event-emission + invariant checks stay identical to the runtime paths.
library MembershipAuthoritySeed {
    // Errors reverted directly here (selectors are signature-derived, so identical to the interface's).
    error ArrayLengthMismatch();
    error AlreadyMember();
    error ZeroAddress();

    // Events emitted directly here (topic0 is signature-derived, so identical to the interface's).
    event SubjectDefaultSet(uint256 indexed subjectId, bool allow);
    event RoleGranted(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event VouchSeeded(uint256 indexed subjectId, address indexed user, uint32 count);
    event VoucherSeeded(uint256 indexed subjectId, address indexed user, address indexed voucher);
    event EmailVerifiedSet(uint256 indexed subjectId, address indexed user, bool verified);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    modifier nonReentrant(Logic.Layout storage l) {
        if (l.lock == 2) revert AlreadyMember(); // reuse of the shared lock; only reached under reentry
        l.lock = 2;
        _;
        l.lock = 1;
    }

    /*═══════════════════════════════ Genesis seed (from initialize) ═══════════════════════════════*/

    /// @notice Apply the genesis {OrgAccessSeed}: subjects → per-subject defaults → group composition →
    ///         vouch configs → perm rows (admin/operator subjects come first per the §6 lock-out guard).
    ///         Same-call subject-refs (`< 2^64`) resolve to freshly-allocated ids (§0 SUBJECT-REF).
    ///         Called from {MembershipAuthority.initialize} — pause-exempt (born paused).
    function applySeed(AccessV2Types.OrgAccessSeed calldata seed) external {
        Logic.Layout storage l = Logic.layout();
        uint256 n = seed.subjectIds.length;
        if (
            seed.subjectKinds.length != n || seed.subjectNames.length != n || seed.subjectMaxMembers.length != n
                || seed.subjectDefaults.length != n || seed.groupMemberRoles.length != n
        ) revert ArrayLengthMismatch();

        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n;) {
            uint256 id = seed.subjectIds[i];
            if (id == 0) id = AccessV2Ids.newSubjectId(address(this), ++l.localSeq);
            Logic._createSubject(
                l, id, seed.subjectKinds[i], seed.subjectNames[i], bytes32(0), "", seed.subjectMaxMembers[i]
            );
            if (seed.subjectDefaults[i]) {
                l.subjects[id].defaultAllow = true;
                emit SubjectDefaultSet(id, true);
            }
            ids[i] = id;
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < n;) {
            uint256[] calldata members = seed.groupMemberRoles[i];
            for (uint256 j; j < members.length;) {
                Logic._addRoleToGroup(l, _ref(members[j], ids), ids[i]);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        uint256 vn = seed.vouchSubjects.length;
        if (seed.vouchQuorums.length != vn || seed.vouchVoucherSubjects.length != vn) revert ArrayLengthMismatch();
        for (uint256 i; i < vn;) {
            Logic._configureVouch(
                l, _ref(seed.vouchSubjects[i], ids), seed.vouchQuorums[i], _ref(seed.vouchVoucherSubjects[i], ids)
            );
            unchecked {
                ++i;
            }
        }

        uint256 pn = seed.permSubjects.length;
        if (seed.permKeys.length != pn || seed.permCtxs.length != pn || seed.permWords.length != pn) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < pn;) {
            Logic._setPerm(l, _ref(seed.permSubjects[i], ids), seed.permKeys[i], seed.permCtxs[i], seed.permWords[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _ref(uint256 r, uint256[] memory ids) internal pure returns (uint256) {
        return r < (1 << 64) ? ids[r] : r;
    }

    /*═══════════════════════════════ Executor-gated batch seeders (§6) ═══════════════════════════════*/

    function seedSubjects(
        uint256[] calldata subjectIds,
        AccessV2Types.SubjectKind[] calldata kinds,
        string[] calldata names,
        uint32[] calldata maxMembers
    ) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        uint256 n = subjectIds.length;
        if (kinds.length != n || names.length != n || maxMembers.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n;) {
            uint256 id = subjectIds[i];
            if (id == 0) id = AccessV2Ids.newSubjectId(address(this), ++l.localSeq);
            Logic._createSubject(l, id, kinds[i], names[i], bytes32(0), "", maxMembers[i]);
            unchecked {
                ++i;
            }
        }
    }

    function seedRules(
        uint256[] calldata subjects,
        address[] calldata users,
        AccessV2Types.RuleKind[] calldata kinds,
        bool[] calldata delegable
    ) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        uint256 n = subjects.length;
        if (users.length != n || kinds.length != n || delegable.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n;) {
            Logic._writeRuleEmit(
                l, subjects[i], users[i], kinds[i], AccessV2Types.RuleAuthor.Governance, delegable[i], 0
            );
            unchecked {
                ++i;
            }
        }
    }

    function seedMemberships(uint256[] calldata subjects, address[] calldata users)
        external
        nonReentrant(Logic.layout())
    {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        uint256 n = subjects.length;
        if (users.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n;) {
            if (!l.membership[subjects[i]][users[i]].accepted) {
                // acceptedAt = 1 (epoch), NOT block.timestamp (ruling R7): seeded members are
                // pre-existing, so activeMemberSince = 1 <= any in-flight proposal's createdAt keeps
                // those proposals votable, while post-cutover claim() members (acceptedAt = now) stay
                // gated out of pre-claim proposals — the anti-packing property survives.
                Logic._flipOnAt(l, subjects[i], users[i], 1);
                emit RoleGranted(subjects[i], users[i], msg.sender, false);
            }
            unchecked {
                ++i;
            }
        }
    }

    function seedPerms(
        uint256[] calldata subjects,
        bytes32[] calldata permKeys,
        bytes32[] calldata ctxs,
        uint256[] calldata words
    ) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        uint256 n = subjects.length;
        if (permKeys.length != n || ctxs.length != n || words.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n;) {
            Logic._setPerm(l, subjects[i], permKeys[i], ctxs[i], words[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice RECORDS-FIRST vouch seed (C2): port the ACTUAL per-voucher records for one wearer, not a
    ///         bare count. For each `voucher`, write the `vouchers[subject][user][voucher]` record at the
    ///         CURRENT epoch + generation, then set `currentVouchCount = #distinct records` and
    ///         `wearerVouchEpoch = currentEpoch`. This is what makes the ported state runtime-sound: a
    ///         legacy voucher can `revokeVouch` (record present ⇒ count decrements ⇒ reconcile fires
    ///         below quorum) and CANNOT re-`vouch` on top (record present ⇒ AlreadyVouched), so the old
    ///         count-only seed's two bugs — un-revokable ghosts and re-vouch double-counting — are gone.
    /// @dev Dedups within the call (a repeated voucher is counted once), so the count can never be
    ///      inflated past the number of distinct real vouchers.
    function seedVouchers(uint256 subject, address user, address[] calldata vouchers) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        if (user == address(0)) revert ZeroAddress();
        uint64 epoch = l.vouchEpoch[subject];
        uint64 gen = l.userVouchGen[subject][user];
        uint32 written;
        for (uint256 i; i < vouchers.length;) {
            address v = vouchers[i];
            if (!l.vouchers[subject][user][v]) {
                l.vouchers[subject][user][v] = true;
                l.voucherRecordEpoch[subject][user][v] = epoch;
                l.voucherRecordGen[subject][user][v] = gen;
                emit VoucherSeeded(subject, user, v);
                unchecked {
                    ++written;
                }
            }
            unchecked {
                ++i;
            }
        }
        l.currentVouchCount[subject][user] = written;
        l.wearerVouchEpoch[subject][user] = epoch;
        emit VouchSeeded(subject, user, written);
    }

    function seedEmailVerified(uint256 subject, address[] calldata users) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        for (uint256 i; i < users.length;) {
            l.emailVerified[subject][users[i]] = true;
            emit EmailVerifiedSet(subject, users[i], true);
            unchecked {
                ++i;
            }
        }
    }

    function emitUnportedBurns(uint256[] calldata subjects, address[] calldata users) external {
        Logic.Layout storage l = Logic.layout();
        Logic._onlyExecutor(l);
        uint256 n = subjects.length;
        if (users.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n;) {
            if (Logic._isMember(l, subjects[i], users[i])) revert AlreadyMember();
            emit TransferSingle(msg.sender, users[i], address(0), subjects[i], 1);
            unchecked {
                ++i;
            }
        }
    }
}
