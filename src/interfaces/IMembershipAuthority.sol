// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {AccessV2Types} from "../libs/AccessV2Types.sol";

/// @title IMembershipAuthority
/// @notice ONE per-org authority (ERC-7201, BeaconProxy) unifying membership, eligibility,
///         permissions, delegation and the Hats/ERC-1155 read surface (ACCESS-V2-SPEC.md §1–§5).
/// @dev ROOT AUTH is the org Executor BY ADDRESS (set at initialize, like every module's
///      onlyExecutor) — NOT membership-based (circular at seed time). Admin/operator SUBJECTS still
///      exist for router/hub resolution but never gate the authority's own writes.
///
///      MEMBERSHIP = accepted && eligible, COMPUTED — never a third stored thing. The pending-action
///      table (§4) is delegation MACHINERY, not membership state.
///
///      PAUSE (REDEFINED — ruling 5): pause gates NON-EXECUTOR writes only (user claims/renounce/
///      vouch, delegated manager actions, module-triggered writes). ALL executor-root writes are
///      PAUSE-EXEMPT — governance is never locked out of its own §6 ceremony. The READ surface stays
///      LIVE while paused.
interface IMembershipAuthority {
    /*═══════════════════════════════ Structs ═══════════════════════════════*/

    /// @notice Subject record — renameable via the SUBJECT_RENAME perm key (not executor-only, §2).
    struct SubjectInfo {
        AccessV2Types.SubjectKind kind; // Role | Group
        string name;
        bytes32 metadataCID;
        string imageURI;
        uint32 maxMembers; // 0 = unlimited (v1 maxSupply convention); ROLE only
        bool exists;
    }

    /// @notice PACKED per-(subject,user) membership slot — gate-adopted recovery lever (§ preamble).
    struct Membership {
        bool accepted; // byte 0
        uint64 acceptedAt; // bytes 1..8 — activation timestamp (0 iff never accepted)
    }

    /// @notice The single explicit-rule slot per (subject,user) (§2). The slot IS the rule.
    struct Rule {
        AccessV2Types.RuleKind kind; // None | Grant | Ban
        AccessV2Types.RuleAuthor author; // Governance | Delegated
        uint256 managerSubject; // authoring manager subject when author==Delegated (else 0)
        bool delegable; // governance grants only; delegated remove may clear iff true
    }

    /// @notice Per-subject manager delegation (§4). The delay applies to grant, offer AND remove.
    struct ManagerConfig {
        uint256 managerSubject;
        uint8 caps;
        uint32 delaySecs;
    }

    /// @notice ONE in-flight delegated action (§4). Finalize/cancel/void are identical across kinds.
    struct PendingAction {
        AccessV2Types.PendingKind action; // Grant | Offer | Remove
        uint256 subject;
        address user;
        address actor; // the delegate that created the action (re-checked at finalize)
        uint64 activatesAt;
        bool ban; // Remove only: soft(false)/hard(true); ignored for Grant/Offer
        bool exists;
    }

    /// @notice One-time initialise payload: root gate + module wiring + the genesis seed.
    struct InitConfig {
        address executor; // ROOT gate (by address)
        address paymasterHub; // for budget resolution / operator subject wiring
        bytes32 orgId;
        AccessV2Types.OrgAccessSeed seed; // genesis subjects/defaults/composition/vouch/perm rows
    }

    /*═══════════════════════════════ Errors ═══════════════════════════════*/
    // Auth / existence
    error NotExecutor();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error UnknownSubject();
    error NotAuthorizedManager(); // delegated caller lacks the cap / manager-subject membership
    error Paused(); // a NON-EXECUTOR write attempted while paused (ruling 5; reads stay live)

    // Subject / composition caps (§1)
    error RoleLimit(); // 16 roles per user, checked at accepted-flip
    error GroupSizeLimit(); // 16 member-roles per group
    error GroupsPerRoleLimit(); // 8 groups per role
    error PermFanoutLimit(); // 16 subjects per (key, ctx), checked at perm-table write
    error MaxMembersOnGroup(); // setMaxMembers on a Group subject

    /// @notice grant/claim on a full ROLE subject (§2 companion runtime rule — ruling 6).
    error SubjectFull(uint256 subjectId, address lapsedCandidate);

    error SubjectExists(); // adopted id / composition already registered
    error NotAGroup(); // composition write on a role subject
    error SelfManagedCycle(); // manager-subject direct cycle (v1 SelfManagedGroup heir)

    // Membership lifecycle (§2/§4)
    error NotInOrg();
    error AlreadyMember();
    error NotMember();
    error RemovalIneffective(uint8 sourceSet); // CARRIES the surviving EligSource bitmask (§4)
    error NotYetActive(uint64 activatesAt); // claim/finalize before the pending anchor (§4)
    error NoPendingAction();
    error GrantBlockedByGovernanceBan(); // delegated grant over a governance ban (v1 heir)
    error RemoveBlockedByStickyGovernance(); // delegate removing a delegable=false governance grant
    error NotClaimable(); // claim with no explicit-ALLOW / offer / reserved seat

    // Config / rule guards (§2)
    error RuleNotDelegable(); // delegated write on a delegable=false governance rule
    error ForceRequired(); // default ALLOW→DENY flip while memberCount > 0 without force

    /// @notice STRUCTURALLY INCOHERENT wiring only — e.g. a vouch config whose voucherSubject is the
    ///         subject itself (bootstrap deadlock) or a vouch config on a GROUP subject. The §2 LINT
    ///         SET does NOT revert (ruling 4).
    error WiringIncompatible();

    // Vouch runtime / admin guards (§2 attestor — ruling 2)
    error InvalidMaxDailyVouches(); // setMaxDailyVouches(0) (v1 heir)
    error VouchRateLimited(); // vouch() over the daily cap

    error NotRegisteredModule(); // email-verify caller is not the org's registered ZkEmailInvites

    // Additive (v1-heir) vouch bookkeeping guards — see DEVIATIONS note. Not part of a frozen
    // signature; needed for revokeVouch's per-voucher accounting.
    error AlreadyVouched();
    error HasNotVouched();
    error PendingActionExists(); // one in-flight pending per (subject,user) at a time

    /*═══════════════════════════════ Events ═══════════════════════════════*/
    event MembershipAuthorityInitialized(address indexed executor, bytes32 indexed orgId, bool paused);
    event PausedSet(bool paused);

    /// @notice NON-REVERTING config-time lint (§2 lint set — ruling 4).
    event ConfigLint(uint256 indexed subjectId, uint8 lintCode);
    event SubjectCreated(uint256 indexed subjectId, uint8 kind, string name, bytes32 metadataCID, uint32 maxMembers);
    event SubjectRenamed(uint256 indexed subjectId, string name, bytes32 metadataCID, string imageURI);
    event GroupCompositionChanged(uint256 indexed groupId, uint256 indexed roleId, bool added);
    event ManagerConfigSet(uint256 indexed subjectId, uint256 indexed managerSubject, uint8 caps, uint32 delaySecs);
    event SubjectDefaultSet(uint256 indexed subjectId, bool allow);
    event MaxMembersSet(uint256 indexed subjectId, uint32 maxMembers);

    // ── Permission table (§3) ──
    event PermSet(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx, uint256 word);
    event PermCleared(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx);

    // ── Explicit rule / attestor writes (§2) ──
    event RuleSet(uint256 indexed subjectId, address indexed user, uint8 kind, uint8 author, bool delegable);
    event RuleCleared(uint256 indexed subjectId, address indexed user);
    event VouchConfigured(uint256 indexed subjectId, uint32 quorum, uint256 indexed voucherSubject);
    event Vouched(uint256 indexed subjectId, address indexed user, address indexed voucher);
    event VouchRevoked(uint256 indexed subjectId, address indexed user, address indexed voucher);
    event EmailVerifiedSet(uint256 indexed subjectId, address indexed user, bool verified);

    // ── Vouch ADMIN + seed events (ruling 2/3) ──
    event VouchEpochReset(uint256 indexed subjectId, uint64 newEpoch);
    event UserVouchesCleared(uint256 indexed subjectId, address indexed user);
    event MaxDailyVouchesSet(uint32 maxDailyVouches);
    event VouchSeeded(uint256 indexed subjectId, address indexed user, uint32 count);

    // ── Six DISJOINT lifecycle events + RoleClaimed (§5) ──
    event RoleOffered(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event OfferWithdrawn(uint256 indexed subjectId, address indexed user, address actor);
    event RoleClaimed(uint256 indexed subjectId, address indexed user);
    event RoleGranted(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleRemoved(uint256 indexed subjectId, address indexed user, bool banned, address actor, bool delegated);
    event RoleRenounced(uint256 indexed subjectId, address indexed user);
    event MembershipReconciled(uint256 indexed subjectId, address indexed user);

    // ── Delegation MACHINERY events (§5) ──
    event PendingActionCreated(
        uint256 indexed pendingId,
        uint256 indexed subjectId,
        address indexed user,
        uint8 action,
        address actor,
        uint64 activatesAt
    );
    event PendingActionCancelled(uint256 indexed pendingId, address indexed by);
    event PendingActionVoided(uint256 indexed pendingId);

    // ── ERC-1155 token surface (ROLES ONLY, §5) ──
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    /*═══════════════════════════════ Initialize ═══════════════════════════════*/

    /// @notice One-time proxy initializer (ruling 1). Sets the executor ROOT gate (by address), wires
    ///         paymasterHub/orgId, applies the genesis seed, and sets paused = TRUE at birth.
    function initialize(InitConfig calldata cfg) external;

    /*═══════════════════════ Lifecycle: user self-service (pause-GATED) ═══════════════════════*/

    /// @notice Claim membership of `subject` — self-claim, offer-accept, or reserved sticky-grant seat.
    function claim(uint256 subject) external;

    /// @notice Resign from `subject` — clears accepted AND clearable explicit GRANT.
    function renounce(uint256 subject) external;

    /// @notice Permissionless repair: clear accepted for `user` on `subject` iff accepted && !eligible.
    function reconcile(uint256 subject, address user) external;

    /// @notice Batch reconcile — same predicate per (subject,user) (§2).
    function reconcile(uint256 subject, address[] calldata users) external;

    /*═══════════════ Lifecycle: governance (onlyExecutor — pause-EXEMPT) ═══════════════*/

    /// @notice Direct grant of `subject` to `user` (§2/§5).
    function grant(uint256 subject, address user, bool delegable) external;

    /// @notice Write an explicit OFFER (explicit-ALLOW) to an out-of-org `user` (governance path).
    function offer(uint256 subject, address user, bool delegable) external;

    /// @notice Withdraw a pending governance offer (clears the explicit-ALLOW before claim).
    function withdrawOffer(uint256 subject, address user) external;

    /// @notice ONE removal primitive (§4). SOFT (ban=false) re-checks eligibility; HARD writes the BAN.
    function remove(uint256 subject, address user, bool ban) external;

    /// @notice Clear a BAN and restore claimable state (v1 unkick parity, §4).
    function unremove(uint256 subject, address user) external;

    /// @notice Set the per-(subject,user) explicit rule directly (governance supremacy, §2).
    function setRule(uint256 subject, address user, AccessV2Types.RuleKind kind, bool delegable) external;

    /// @notice Clear the explicit rule (governance).
    function clearRule(uint256 subject, address user) external;

    /*═══════════════ Lifecycle: delegated (manager path — pause-GATED) ═══════════════*/

    /// @notice Delegate creates a pending GRANT to an in-org member (§4).
    function delegatedGrant(uint256 subject, address user) external returns (uint256 pendingId);

    /// @notice Delegate creates a pending OFFER to an out-of-org user (§4).
    function delegatedOffer(uint256 subject, address user) external returns (uint256 pendingId);

    /// @notice Delegate creates a pending REMOVE (soft/hard) (§4).
    function delegatedRemove(uint256 subject, address user, bool ban) external returns (uint256 pendingId);

    /// @notice Delegate clears a delegation-authored BAN and restores claimable state (§4 unremove).
    function delegatedUnremove(uint256 subject, address user) external;

    /// @notice Explicit finalize of a pending GRANT or REMOVE after activatesAt (§4).
    function finalize(uint256 pendingId) external;

    /// @notice Cancel a pending action (§4). AUTH: the acting manager OR the executor (governance).
    function cancel(uint256 pendingId) external;

    /*═══════════════ Delegation config (onlyExecutor — pause-EXEMPT) ═══════════════*/

    /// @notice Set/clear a subject's manager delegation (§4). `managerSubject == 0` clears it.
    function setManagerConfig(uint256 subject, uint256 managerSubject, uint8 caps, uint32 delaySecs) external;

    /*═══════════════════════════════ Subject lifecycle ═══════════════════════════════*/

    /// @notice Create a first-class ROLE subject (new v2 id).
    function createRole(string calldata name, bytes32 metadataCID, string calldata imageURI, uint32 maxMembers)
        external
        returns (uint256 subjectId);

    /// @notice Create a GROUP subject over `memberRoleIds` (no acceptance; pure derivation, §1).
    function createGroup(
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint256[] calldata memberRoleIds
    ) external returns (uint256 subjectId);

    /// @notice Composition writes (§1) — GroupSizeLimit(16)/GroupsPerRoleLimit(8) enforced here.
    function addRoleToGroup(uint256 roleId, uint256 groupId) external;
    function removeRoleFromGroup(uint256 roleId, uint256 groupId) external;

    /// @notice Rename / re-image a subject (§1). AUTH is the SUBJECT_RENAME perm key.
    function renameSubject(uint256 subjectId, string calldata name, bytes32 metadataCID, string calldata imageURI)
        external;

    /// @notice Set a ROLE subject's maxMembers (§1).
    function setMaxMembers(uint256 subjectId, uint32 maxMembers) external;

    /// @notice Set a subject's default eligibility verdict (§2).
    function setSubjectDefault(uint256 subjectId, bool allow, bool force) external;

    /*═══════════ Attestors: vouch ADMIN (onlyExecutor — pause-EXEMPT) ═══════════*/

    /// @notice Configure the vouch attestor for `subject` (§2). `quorum == 0` DISABLES the attestor.
    function configureVouchAttestor(uint256 subject, uint32 quorum, uint256 voucherSubject) external;

    /// @notice AMNESTY: bump `subject`'s vouch epoch, invalidating ALL live vouches (§2).
    function resetVouchEpoch(uint256 subject) external;

    /// @notice Surgical per-user clear of `user`'s received vouches on `subject` (§2).
    function clearUserVouches(uint256 subject, address user) external;

    /// @notice Set the org-wide daily vouch rate limit. Reverts {InvalidMaxDailyVouches} on 0.
    function setMaxDailyVouches(uint32 maxVouches) external;

    /*═══════════════════════════════ Attestors: runtime (pause-GATED) ═══════════════════════════════*/

    /// @notice Cast / revoke a vouch (§2). AUTH: a member of the config's voucher subject.
    function vouch(uint256 subject, address user) external;
    function revokeVouch(uint256 subject, address user) external;

    /// @notice ZK-email attestor write (§5 continuity), gated on the org's registered ZkEmailInvites.
    function setEmailVerified(address wearer, uint256[] calldata hatIds) external;

    /*═══════════════════════════════ Perm-table write surface (§3) ═══════════════════════════════*/

    /// @notice Write a perm-table row: perm[subject][permKey][ctx] = word.
    function setPerm(uint256 subject, bytes32 permKey, bytes32 ctx, uint256 word) external;

    /// @notice Clear a perm-table row (removes from the inverted index).
    function clearPerm(uint256 subject, bytes32 permKey, bytes32 ctx) external;

    /*═══════════════════════════════ Legacy-compat mint surface (§4 QuickJoin) ═══════════════════════════════*/

    /// @notice IHats-SHAPED mint so a truly UNCHANGED Executor works after the §4.7 `l.hats` repoint.
    function mintHat(uint256 subjectId, address user) external returns (bool);

    /*═══════ Seed / migration (onlyExecutor — pause-EXEMPT) ═══════*/

    function seedSubjects(
        uint256[] calldata subjectIds,
        AccessV2Types.SubjectKind[] calldata kinds,
        string[] calldata names,
        uint32[] calldata maxMembers
    ) external;

    function seedRules(
        uint256[] calldata subjects,
        address[] calldata users,
        AccessV2Types.RuleKind[] calldata kinds,
        bool[] calldata delegable
    ) external;

    function seedMemberships(uint256[] calldata subjects, address[] calldata users) external;

    function seedPerms(
        uint256[] calldata subjects,
        bytes32[] calldata permKeys,
        bytes32[] calldata ctxs,
        uint256[] calldata words
    ) external;

    function seedVouches(uint256 subject, address[] calldata users, uint32[] calldata counts) external;

    function seedEmailVerified(uint256 subject, address[] calldata users) external;

    /// @notice EVENT-ONLY cutover surface (§5/§6): emit the burn-shaped TransferSingle for unported wearers.
    function emitUnportedBurns(uint256[] calldata subjects, address[] calldata users) external;

    /// @notice Pause/unpause NON-EXECUTOR writes (reads stay live; executor writes always pass).
    function setPaused(bool paused) external;

    /*═══════════════════════════════ Views: membership (LIVE while paused) ═══════════════════════════════*/

    function isMember(uint256 subject, address user) external view returns (bool);

    function getStatus(uint256 subject, address user)
        external
        view
        returns (bool accepted, bool eligible, uint64 acceptedAt, AccessV2Types.RuleKind ruleKind);

    function memberCount(uint256 subject) external view returns (uint256);

    /*═══════════════════════════════ Views: permissions (§3 INVERTED fold) ═══════════════════════════════*/

    function hasPerm(address user, bytes32 permKey, bytes32 ctx) external view returns (uint256);

    /// @notice Subject-shaped activation read (§3).
    function activeMemberSince(uint256 subject, address user) external view returns (uint64);

    /// @notice Key-folded companion (§3).
    function activeMemberSince(address user, bytes32 permKey, bytes32 ctx) external view returns (uint64);

    /*═══════════════════════════════ Views: preflights (§4 error-channel) ═══════════════════════════════*/

    function canGrant(uint256 subject, address user)
        external
        view
        returns (AccessV2Types.ActionReason reason, address lapsedCandidate);

    function canRemove(uint256 subject, address user, bool ban)
        external
        view
        returns (AccessV2Types.ActionReason reason, uint8 sourceSet);

    function canClaim(uint256 subject, address user)
        external
        view
        returns (AccessV2Types.ActionReason reason, uint64 activatesAt, address lapsedCandidate);

    /*═══════════════════════════════ Views: eligibility internals + enumeration ═══════════════════════════════*/

    /// @notice The eligibility fold verdict (§2): explicit rule > attestor-ALLOW > per-subject default.
    function eligible(uint256 subject, address user) external view returns (bool);

    /// @notice Per-(subject,user) explicit rule slot (§2).
    function getRule(uint256 subject, address user) external view returns (Rule memory);

    /// @notice Provenance flags for the delegated-guard fast path.
    function getRuleFlags(uint256 subject, address user)
        external
        view
        returns (bool present, AccessV2Types.RuleKind kind, AccessV2Types.RuleAuthor author, bool delegable);

    function getSubject(uint256 subjectId) external view returns (SubjectInfo memory);
    function getManagerConfig(uint256 subjectId) external view returns (ManagerConfig memory);
    function getPending(uint256 pendingId) external view returns (PendingAction memory);
    function getPerm(uint256 subject, bytes32 permKey, bytes32 ctx) external view returns (uint256 word);

    function subjectsWithKey(bytes32 permKey, bytes32 ctx) external view returns (uint256[] memory);
    function groupMemberRoles(uint256 groupId) external view returns (uint256[] memory);
    function userSubjects(address user) external view returns (uint256[] memory);

    function subjectCount() external view returns (uint256);
    function executor() external view returns (address);
    function orgId() external view returns (bytes32);
    function paused() external view returns (bool);

    // Mandated ops/debug views (R3).
    function vouchConfig(uint256 subject) external view returns (uint32 quorum, uint256 voucherSubject, uint64 epoch);
    function vouchCount(uint256 subject, address user) external view returns (uint32);
    function maxDailyVouches() external view returns (uint32);

    /*═══════════════════════════════ IHats read-subset + ERC-1155 view surface (§5) ═══════════════════════════════*/

    function viewHat(uint256 subjectId)
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        );

    function getWearerStatus(address wearer, uint256 subjectId) external view returns (bool eligible, bool standing);

    function isWearerOfHat(address user, uint256 subjectId) external view returns (bool);
    function isEligible(address user, uint256 subjectId) external view returns (bool);
    function balanceOf(address user, uint256 subjectId) external view returns (uint256);
    function balanceOfBatch(address[] calldata users, uint256[] calldata subjectIds)
        external
        view
        returns (uint256[] memory);

    function checkHatWearerStatus(uint256 subjectId, address user) external view returns (bool);
}
