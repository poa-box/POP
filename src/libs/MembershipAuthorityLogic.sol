// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {AccessV2Types} from "./AccessV2Types.sol";
import {AccessV2Ids} from "./AccessV2Ids.sol";
import {AccessV2PermKeys} from "./AccessV2PermKeys.sol";

/// @dev Minimal read subset of the org Executor used to gate the module-triggered email-verify write.
interface IExecutorMinterLib {
    function isAuthorizedHatMinter(address minter) external view returns (bool);
}

/// @title MembershipAuthorityLogic
/// @notice DELEGATECALL library holding the cold-surface logic of {MembershipAuthority} — seed/
///         migration, subject/config writes, governance rule writes, manager delegation and vouch
///         admin — split out to reclaim EIP-170 headroom (PaymasterRuleLib / EligibilityLogic
///         precedent). Its functions are `external` so the linker deploys it separately and the hub
///         reaches it via DELEGATECALL: msg.sender / address(this) / storage are the hub's.
/// @dev STORAGE: this library IS the single canonical declaration of {Layout} + every stored struct
///      + the ERC-7201 slot; the hub references `MembershipAuthorityLogic.Layout` directly, so the
///      "byte-identical mirror" obligation is met by SHARING one declaration (stronger than mirroring).
///      A slot-mirror sync test pins the constant from day 1.
library MembershipAuthorityLogic {
    using AccessV2Ids for uint256;

    /*═══════════════════════════════ Constants ═══════════════════════════════*/

    uint8 internal constant CAP_GRANT = 1;
    uint8 internal constant CAP_REMOVE = 2;

    uint256 internal constant ROLE_LIMIT = 16;
    uint256 internal constant GROUP_SIZE_LIMIT = 16;
    uint256 internal constant GROUPS_PER_ROLE_LIMIT = 8;
    uint256 internal constant PERM_FANOUT_LIMIT = 16;

    uint32 internal constant DEFAULT_MAX_DAILY_VOUCHES = 20;
    uint256 internal constant SECONDS_PER_DAY = 86_400;
    uint64 internal constant SENTINEL = type(uint64).max;

    uint8 internal constant SRC_DEFAULT_ALLOW = uint8(1) << uint8(AccessV2Types.EligSource.DefaultAllow);
    uint8 internal constant SRC_VOUCH_QUORUM = uint8(1) << uint8(AccessV2Types.EligSource.VouchQuorum);
    uint8 internal constant SRC_EMAIL_VERIFIED = uint8(1) << uint8(AccessV2Types.EligSource.EmailVerified);
    uint8 internal constant SRC_STICKY_GRANT = uint8(1) << uint8(AccessV2Types.EligSource.StickyGovernanceGrant);

    /*═══════════════════════════════ Errors (mirror IMembershipAuthority) ═══════════════════════════════*/
    error NotExecutor();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error UnknownSubject();
    error NotAuthorizedManager();
    error Paused();
    error RoleLimit();
    error GroupSizeLimit();
    error GroupsPerRoleLimit();
    error PermFanoutLimit();
    error MaxMembersOnGroup();
    error SubjectFull(uint256 subjectId, address lapsedCandidate);
    error SubjectExists();
    error NotAGroup();
    error SelfManagedCycle();
    error NotInOrg();
    error AlreadyMember();
    error NotMember();
    error RemovalIneffective(uint8 sourceSet);
    error NotYetActive(uint64 activatesAt);
    error NoPendingAction();
    error GrantBlockedByGovernanceBan();
    error RemoveBlockedByStickyGovernance();
    error NotClaimable();
    error RuleNotDelegable();
    error ForceRequired();
    error WiringIncompatible();
    error InvalidMaxDailyVouches();
    error VouchRateLimited();
    error NotRegisteredModule();
    error AlreadyVouched();
    error HasNotVouched();
    error PendingActionExists();

    /*═══════════════════════════════ Events (mirror IMembershipAuthority) ═══════════════════════════════*/
    event ConfigLint(uint256 indexed subjectId, uint8 lintCode);
    event SubjectCreated(uint256 indexed subjectId, uint8 kind, string name, bytes32 metadataCID, uint32 maxMembers);
    event SubjectRenamed(uint256 indexed subjectId, string name, bytes32 metadataCID, string imageURI);
    event GroupCompositionChanged(uint256 indexed groupId, uint256 indexed roleId, bool added);
    event ManagerConfigSet(uint256 indexed subjectId, uint256 indexed managerSubject, uint8 caps, uint32 delaySecs);
    event SubjectDefaultSet(uint256 indexed subjectId, bool allow);
    event MaxMembersSet(uint256 indexed subjectId, uint32 maxMembers);
    event PermSet(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx, uint256 word);
    event PermCleared(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx);
    event RuleSet(uint256 indexed subjectId, address indexed user, uint8 kind, uint8 author, bool delegable);
    event RuleCleared(uint256 indexed subjectId, address indexed user);
    event VouchConfigured(uint256 indexed subjectId, uint32 quorum, uint256 indexed voucherSubject);
    event Vouched(uint256 indexed subjectId, address indexed user, address indexed voucher);
    event VouchRevoked(uint256 indexed subjectId, address indexed user, address indexed voucher);
    event EmailVerifiedSet(uint256 indexed subjectId, address indexed user, bool verified);
    event VouchEpochReset(uint256 indexed subjectId, uint64 newEpoch);
    event UserVouchesCleared(uint256 indexed subjectId, address indexed user);
    event MaxDailyVouchesSet(uint32 maxDailyVouches);
    event VouchSeeded(uint256 indexed subjectId, address indexed user, uint32 count);
    event RoleOffered(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event OfferWithdrawn(uint256 indexed subjectId, address indexed user, address actor);
    event RoleClaimed(uint256 indexed subjectId, address indexed user);
    event RoleGranted(uint256 indexed subjectId, address indexed user, address actor, bool delegated);
    event RoleRemoved(uint256 indexed subjectId, address indexed user, bool banned, address actor, bool delegated);
    event RoleRenounced(uint256 indexed subjectId, address indexed user);
    event MembershipReconciled(uint256 indexed subjectId, address indexed user);
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
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    /*═══════════════════════════════ Stored structs ═══════════════════════════════*/

    struct SubjectRec {
        bool exists;
        AccessV2Types.SubjectKind kind;
        bool defaultAllow;
        uint32 maxMembers;
        uint32 memberCount;
        uint32 permCount;
        string name;
        bytes32 metadataCID;
        string imageURI;
    }

    struct RuleRec {
        AccessV2Types.RuleKind kind;
        AccessV2Types.RuleAuthor author;
        bool delegable;
        uint256 managerSubject;
    }

    struct VouchCfg {
        uint32 quorum;
        uint256 voucherSubject;
    }

    struct ManagerCfg {
        uint256 managerSubject;
        uint8 caps;
        uint32 delaySecs;
    }

    struct PendingRec {
        AccessV2Types.PendingKind action;
        uint256 subject;
        address user;
        address actor;
        uint64 activatesAt;
        bool ban;
        bool exists;
    }

    struct MembershipRec {
        bool accepted;
        uint64 acceptedAt;
    }

    /// @custom:storage-location erc7201:poa.membershipauthority.storage
    struct Layout {
        address executor;
        address paymasterHub;
        bytes32 orgId;
        bool paused;
        uint256 lock;
        uint64 localSeq;
        uint256 subjectCount;
        uint256 pendingSeq;
        uint32 maxDailyVouches;
        mapping(uint256 => SubjectRec) subjects;
        mapping(uint256 => mapping(address => MembershipRec)) membership;
        mapping(address => uint256[]) userSubjectList;
        mapping(address => mapping(uint256 => uint256)) userSubjectIndex;
        mapping(uint256 => address[]) subjectMembers;
        mapping(uint256 => mapping(address => uint256)) subjectMemberIndex;
        mapping(uint256 => mapping(address => RuleRec)) ruleOf;
        mapping(uint256 => VouchCfg) vouchConfigs;
        mapping(uint256 => uint64) vouchEpoch;
        mapping(uint256 => mapping(address => uint32)) currentVouchCount;
        mapping(uint256 => mapping(address => uint64)) wearerVouchEpoch;
        mapping(uint256 => mapping(address => mapping(address => bool))) vouchers;
        mapping(uint256 => mapping(address => mapping(address => uint64))) voucherRecordEpoch;
        // Per-user vouch generation. (Placed mid-struct here for locality with the other vouch
        // fields; MembershipAuthority is NEW on this branch with no deployed baseline, so the whole
        // Layout is authored fresh — position only needs to be self-consistent across the hub + both
        // libs, which share this single struct definition. Post-deploy, all additions append at the
        // tail per repo discipline.) Bumped by clearUserVouches to
        // PERMANENTLY strand that user's prior per-voucher records without disturbing other users
        // (the subject-level vouchEpoch can't be bumped per-user). Voucher records validate against
        // BOTH the subject epoch and this generation, so a stranded record can never be revived by
        // a later fresh vouch resetting wearerVouchEpoch — closing the revokeVouch underflow.
        mapping(uint256 => mapping(address => uint64)) userVouchGen;
        mapping(uint256 => mapping(address => mapping(address => uint64))) voucherRecordGen;
        mapping(address => mapping(uint256 => uint32)) dailyVouchCount;
        mapping(uint256 => mapping(address => bool)) emailVerified;
        mapping(uint256 => uint256[]) groupRoles;
        mapping(uint256 => mapping(uint256 => uint256)) roleIdxInGroup;
        mapping(uint256 => uint256[]) roleGroups;
        mapping(uint256 => mapping(uint256 => uint256)) groupIdxOfRole;
        mapping(uint256 => mapping(bytes32 => mapping(bytes32 => uint256))) perm;
        mapping(bytes32 => mapping(bytes32 => uint256[])) subjectsWithKeyList;
        mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) subjectKeyIndex;
        mapping(uint256 => ManagerCfg) managerConfig;
        mapping(uint256 => PendingRec) pending;
        mapping(uint256 => mapping(address => uint256)) pendingOf;
    }

    bytes32 internal constant STORAGE_SLOT = keccak256("poa.membershipauthority.storage");

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═══════════════════════════════ Guards ═══════════════════════════════*/

    function _onlyExecutor(Layout storage l) internal view {
        if (msg.sender != l.executor) revert NotExecutor();
    }

    function _gateNonExecutor(Layout storage l) internal view {
        if (l.paused) revert Paused();
    }

    modifier nonReentrant(Layout storage l) {
        if (l.lock == 2) revert Paused();
        l.lock = 2;
        _;
        l.lock = 1;
    }

    /*═══════════════════════════════ Subject lifecycle ═══════════════════════════════*/

    function createRole(string calldata name, bytes32 metadataCID, string calldata imageURI, uint32 maxMembers)
        external
        returns (uint256 subjectId)
    {
        Layout storage l = layout();
        _onlyExecutor(l);
        subjectId = AccessV2Ids.newSubjectId(address(this), ++l.localSeq);
        _createSubject(l, subjectId, AccessV2Types.SubjectKind.Role, name, metadataCID, imageURI, maxMembers);
    }

    function createGroup(
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint256[] calldata memberRoleIds
    ) external returns (uint256 subjectId) {
        Layout storage l = layout();
        _onlyExecutor(l);
        subjectId = AccessV2Ids.newSubjectId(address(this), ++l.localSeq);
        _createSubject(l, subjectId, AccessV2Types.SubjectKind.Group, name, metadataCID, imageURI, 0);
        for (uint256 i; i < memberRoleIds.length;) {
            _addRoleToGroup(l, memberRoleIds[i], subjectId);
            unchecked {
                ++i;
            }
        }
    }

    function _createSubject(
        Layout storage l,
        uint256 id,
        AccessV2Types.SubjectKind kind,
        string memory name,
        bytes32 metadataCID,
        string memory imageURI,
        uint32 maxMembers
    ) internal {
        if (l.subjects[id].exists) revert SubjectExists();
        if (kind == AccessV2Types.SubjectKind.Group && maxMembers != 0) revert MaxMembersOnGroup();
        SubjectRec storage s = l.subjects[id];
        s.exists = true;
        s.kind = kind;
        s.maxMembers = maxMembers;
        s.name = name;
        s.metadataCID = metadataCID;
        s.imageURI = imageURI;
        unchecked {
            ++l.subjectCount;
        }
        emit SubjectCreated(id, uint8(kind), name, metadataCID, maxMembers);
    }

    function addRoleToGroup(uint256 roleId, uint256 groupId) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        _addRoleToGroup(l, roleId, groupId);
    }

    function _addRoleToGroup(Layout storage l, uint256 roleId, uint256 groupId) internal {
        SubjectRec storage g = l.subjects[groupId];
        if (!g.exists) revert UnknownSubject();
        if (g.kind != AccessV2Types.SubjectKind.Group) revert NotAGroup();
        SubjectRec storage r = l.subjects[roleId];
        if (!r.exists || r.kind != AccessV2Types.SubjectKind.Role) revert UnknownSubject();
        if (l.roleIdxInGroup[groupId][roleId] != 0) revert SubjectExists();

        uint256[] storage members = l.groupRoles[groupId];
        if (members.length >= GROUP_SIZE_LIMIT) revert GroupSizeLimit();
        uint256[] storage groups = l.roleGroups[roleId];
        if (groups.length >= GROUPS_PER_ROLE_LIMIT) revert GroupsPerRoleLimit();

        members.push(roleId);
        l.roleIdxInGroup[groupId][roleId] = members.length;
        groups.push(groupId);
        l.groupIdxOfRole[roleId][groupId] = groups.length;

        emit GroupCompositionChanged(groupId, roleId, true);
        if (g.permCount > 3) emit ConfigLint(groupId, uint8(AccessV2Types.LintCode.GroupFanout));
    }

    function removeRoleFromGroup(uint256 roleId, uint256 groupId) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        uint256 idx1 = l.roleIdxInGroup[groupId][roleId];
        if (idx1 == 0) revert UnknownSubject();
        _swapPop(l.groupRoles[groupId], l.roleIdxInGroup[groupId], roleId, idx1);
        uint256 gidx1 = l.groupIdxOfRole[roleId][groupId];
        _swapPop(l.roleGroups[roleId], l.groupIdxOfRole[roleId], groupId, gidx1);
        emit GroupCompositionChanged(groupId, roleId, false);
    }

    function renameSubject(uint256 subjectId, string calldata name, bytes32 metadataCID, string calldata imageURI)
        external
    {
        Layout storage l = layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        if (msg.sender != l.executor) {
            _gateNonExecutor(l);
            if (_hasPerm(l, msg.sender, AccessV2PermKeys.SUBJECT_RENAME, bytes32(0)) == 0) {
                revert NotAuthorizedManager();
            }
        }
        SubjectRec storage s = l.subjects[subjectId];
        s.name = name;
        s.metadataCID = metadataCID;
        s.imageURI = imageURI;
        emit SubjectRenamed(subjectId, name, metadataCID, imageURI);
    }

    function setMaxMembers(uint256 subjectId, uint32 maxMembers) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        SubjectRec storage s = l.subjects[subjectId];
        if (!s.exists) revert UnknownSubject();
        if (s.kind == AccessV2Types.SubjectKind.Group) revert MaxMembersOnGroup();
        s.maxMembers = maxMembers;
        emit MaxMembersSet(subjectId, maxMembers);
        if (maxMembers != 0 && l.vouchConfigs[subjectId].quorum != 0) {
            emit ConfigLint(subjectId, uint8(AccessV2Types.LintCode.VouchWithMaxMembers));
        }
    }

    function setSubjectDefault(uint256 subjectId, bool allow, bool force) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        SubjectRec storage s = l.subjects[subjectId];
        if (!s.exists) revert UnknownSubject();
        if (s.defaultAllow && !allow && s.memberCount > 0 && !force) revert ForceRequired();
        s.defaultAllow = allow;
        emit SubjectDefaultSet(subjectId, allow);
        if (allow) {
            if (l.vouchConfigs[subjectId].quorum != 0) {
                emit ConfigLint(subjectId, uint8(AccessV2Types.LintCode.QuorumNoOp));
            }
            if (s.permCount > 0) emit ConfigLint(subjectId, uint8(AccessV2Types.LintCode.DefaultAllowStrongPerms));
        }
    }

    /*═══════════════════════════════ Governance rule writes ═══════════════════════════════*/

    function setRule(uint256 subject, address user, AccessV2Types.RuleKind kind, bool delegable) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        if (!l.subjects[subject].exists) revert UnknownSubject();
        if (user == address(0)) revert ZeroAddress();
        _writeRuleEmit(l, subject, user, kind, AccessV2Types.RuleAuthor.Governance, delegable, 0);
        _voidPending(l, subject, user);
        _reconcileAfterRuleWrite(l, subject, user, kind == AccessV2Types.RuleKind.Ban, address(0), false);
    }

    function clearRule(uint256 subject, address user) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        delete l.ruleOf[subject][user];
        emit RuleCleared(subject, user);
        _voidPending(l, subject, user);
        _reconcileAfterRuleWrite(l, subject, user, false, address(0), false);
    }

    function grant(uint256 subject, address user, bool delegable) external nonReentrant(layout()) {
        Layout storage l = layout();
        _onlyExecutor(l);
        _requireRole(l, subject);
        if (user == address(0)) revert ZeroAddress();
        if (l.membership[subject][user].accepted) revert AlreadyMember();
        _writeRuleEmit(
            l, subject, user, AccessV2Types.RuleKind.Grant, AccessV2Types.RuleAuthor.Governance, delegable, 0
        );
        _voidPending(l, subject, user);
        if (_isInOrg(l, user)) {
            _flipOn(l, subject, user);
            emit RoleGranted(subject, user, msg.sender, false);
        } else {
            emit RoleOffered(subject, user, msg.sender, false);
        }
    }

    function offer(uint256 subject, address user, bool delegable) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        _requireRole(l, subject);
        if (user == address(0)) revert ZeroAddress();
        _writeRuleEmit(
            l, subject, user, AccessV2Types.RuleKind.Grant, AccessV2Types.RuleAuthor.Governance, delegable, 0
        );
        _voidPending(l, subject, user);
        emit RoleOffered(subject, user, msg.sender, false);
    }

    function withdrawOffer(uint256 subject, address user) external nonReentrant(layout()) {
        Layout storage l = layout();
        _onlyExecutor(l);
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind == AccessV2Types.RuleKind.Grant) delete l.ruleOf[subject][user];
        emit OfferWithdrawn(subject, user, msg.sender);
        _voidPending(l, subject, user);
        _reconcileAfterRuleWrite(l, subject, user, false, msg.sender, false);
    }

    function remove(uint256 subject, address user, bool ban) external nonReentrant(layout()) {
        Layout storage l = layout();
        _onlyExecutor(l);
        _requireRole(l, subject);
        if (!l.membership[subject][user].accepted) revert NotMember();
        _voidPending(l, subject, user);
        if (ban) {
            _writeRuleEmit(l, subject, user, AccessV2Types.RuleKind.Ban, AccessV2Types.RuleAuthor.Governance, false, 0);
            _flipOff(l, subject, user);
            emit RoleRemoved(subject, user, true, msg.sender, false);
        } else {
            _softRemove(l, subject, user, msg.sender, false);
        }
    }

    function _softRemove(Layout storage l, uint256 subject, address user, address actor, bool delegated) internal {
        RuleRec storage r = l.ruleOf[subject][user];
        RuleRec memory prior = r;
        bool cleared;
        if (r.kind == AccessV2Types.RuleKind.Grant) {
            delete l.ruleOf[subject][user];
            cleared = true;
        }
        uint8 srcs = _survivingSources(l, subject, user);
        if (srcs != 0) {
            if (cleared) {
                RuleRec storage rr = l.ruleOf[subject][user];
                rr.kind = prior.kind;
                rr.author = prior.author;
                rr.delegable = prior.delegable;
                rr.managerSubject = prior.managerSubject;
            }
            revert RemovalIneffective(srcs);
        }
        _flipOff(l, subject, user);
        emit RoleRemoved(subject, user, false, actor, delegated);
    }

    function unremove(uint256 subject, address user) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind == AccessV2Types.RuleKind.Ban) delete l.ruleOf[subject][user];
        emit RuleCleared(subject, user);
        _voidPending(l, subject, user);
    }

    /*═══════════════════════════════ Delegation config + lifecycle ═══════════════════════════════*/

    function setManagerConfig(uint256 subject, uint256 managerSubject, uint8 caps, uint32 delaySecs) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        if (!l.subjects[subject].exists) revert UnknownSubject();
        if (managerSubject != 0) {
            if (!l.subjects[managerSubject].exists) revert UnknownSubject();
            if (l.roleIdxInGroup[managerSubject][subject] != 0 || managerSubject == subject) revert SelfManagedCycle();
        }
        l.managerConfig[subject] = ManagerCfg({managerSubject: managerSubject, caps: caps, delaySecs: delaySecs});
        emit ManagerConfigSet(subject, managerSubject, caps, delaySecs);
    }

    function delegatedGrant(uint256 subject, address user) external nonReentrant(layout()) returns (uint256 pendingId) {
        Layout storage l = layout();
        _gateNonExecutor(l);
        _requireRole(l, subject);
        _requireManager(l, subject, msg.sender, CAP_GRANT);
        RuleRec storage r = l.ruleOf[subject][user];
        // A delegate may never overwrite a STICKY (non-delegable) governance rule — grant OR ban
        // (§4 cross-delegate rule: sticky governance rules are untouchable by all delegates).
        // Guarding Ban alone let a renounced sticky-seat officer (accepted=false, sticky Grant
        // survives) be delegatedGrant→finalize'd, laundering the sticky protection into a
        // delegable rule the delegate could then ban. kind != None excludes the empty slot
        // (author defaults to Governance(0), delegable=false).
        if (r.kind != AccessV2Types.RuleKind.None && r.author == AccessV2Types.RuleAuthor.Governance && !r.delegable) {
            revert GrantBlockedByGovernanceBan();
        }
        pendingId = _createPending(l, AccessV2Types.PendingKind.Grant, subject, user, false);
    }

    function delegatedOffer(uint256 subject, address user) external nonReentrant(layout()) returns (uint256 pendingId) {
        Layout storage l = layout();
        _gateNonExecutor(l);
        _requireRole(l, subject);
        if (user == address(0)) revert ZeroAddress();
        uint256 managerSubject = _requireManager(l, subject, msg.sender, CAP_GRANT);
        RuleRec storage r = l.ruleOf[subject][user];
        // Same sticky-supremacy guard as delegatedGrant (broader vector: delegatedOffer writes the
        // rule immediately with no membership check, so it could launder a sticky governance grant
        // on an ACTIVE officer, not just a renounced reserved seat). Reject any non-delegable
        // governance rule (grant OR ban); kind != None excludes the empty slot.
        if (r.kind != AccessV2Types.RuleKind.None && r.author == AccessV2Types.RuleAuthor.Governance && !r.delegable) {
            revert GrantBlockedByGovernanceBan();
        }
        _writeRuleEmit(
            l, subject, user, AccessV2Types.RuleKind.Grant, AccessV2Types.RuleAuthor.Delegated, true, managerSubject
        );
        pendingId = _createPending(l, AccessV2Types.PendingKind.Offer, subject, user, false);
        emit RoleOffered(subject, user, msg.sender, true);
    }

    function delegatedRemove(uint256 subject, address user, bool ban)
        external
        nonReentrant(layout())
        returns (uint256 pendingId)
    {
        Layout storage l = layout();
        _gateNonExecutor(l);
        _requireRole(l, subject);
        _requireManager(l, subject, msg.sender, CAP_REMOVE);
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind == AccessV2Types.RuleKind.Grant && r.author == AccessV2Types.RuleAuthor.Governance && !r.delegable) {
            revert RemoveBlockedByStickyGovernance();
        }
        pendingId = _createPending(l, AccessV2Types.PendingKind.Remove, subject, user, ban);
    }

    function delegatedUnremove(uint256 subject, address user) external nonReentrant(layout()) {
        Layout storage l = layout();
        _gateNonExecutor(l);
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind != AccessV2Types.RuleKind.Ban) revert NotClaimable();
        if (r.author != AccessV2Types.RuleAuthor.Delegated) revert RuleNotDelegable();
        _requireManager(l, subject, msg.sender, CAP_REMOVE);
        delete l.ruleOf[subject][user];
        emit RuleCleared(subject, user);
        _voidPending(l, subject, user);
    }

    function finalize(uint256 pendingId) external nonReentrant(layout()) {
        Layout storage l = layout();
        _gateNonExecutor(l);
        PendingRec storage p = l.pending[pendingId];
        if (!p.exists) revert NoPendingAction();
        if (p.action == AccessV2Types.PendingKind.Offer) revert NoPendingAction();
        if (block.timestamp < p.activatesAt) revert NotYetActive(p.activatesAt);

        uint256 subject = p.subject;
        address user = p.user;
        bool ban = p.ban;
        address actor = p.actor;
        AccessV2Types.PendingKind action = p.action;
        uint256 managerSubject =
            _requireManager(l, subject, actor, action == AccessV2Types.PendingKind.Grant ? CAP_GRANT : CAP_REMOVE);

        _deletePending(l, pendingId);

        if (action == AccessV2Types.PendingKind.Grant) {
            // Defense-in-depth mirror of the delegatedGrant guard: never overwrite a sticky
            // (non-delegable) governance rule at finalize either (D3).
            RuleRec storage rr = l.ruleOf[subject][user];
            if (
                rr.kind != AccessV2Types.RuleKind.None && rr.author == AccessV2Types.RuleAuthor.Governance
                    && !rr.delegable
            ) {
                revert GrantBlockedByGovernanceBan();
            }
            _writeRuleEmit(
                l, subject, user, AccessV2Types.RuleKind.Grant, AccessV2Types.RuleAuthor.Delegated, true, managerSubject
            );
            // Consent model (§1, mirrors governance grant): a delegated GRANT force-accepts only an
            // IN-ORG target. An out-of-org target is recorded as an OFFER (rule written above,
            // RoleOffered emitted, accepted stays false) — the target's own claim is the consent.
            if (_isInOrg(l, user)) {
                _flipOn(l, subject, user);
                emit RoleGranted(subject, user, actor, true);
            } else {
                emit RoleOffered(subject, user, actor, true);
            }
        } else {
            if (!l.membership[subject][user].accepted) revert NotMember();
            if (ban) {
                _writeRuleEmit(
                    l,
                    subject,
                    user,
                    AccessV2Types.RuleKind.Ban,
                    AccessV2Types.RuleAuthor.Delegated,
                    false,
                    managerSubject
                );
                _flipOff(l, subject, user);
                emit RoleRemoved(subject, user, true, actor, true);
            } else {
                _softRemove(l, subject, user, actor, true);
            }
        }
    }

    function cancel(uint256 pendingId) external nonReentrant(layout()) {
        Layout storage l = layout();
        PendingRec storage p = l.pending[pendingId];
        if (!p.exists) revert NoPendingAction();
        if (msg.sender != l.executor) {
            _gateNonExecutor(l);
            uint256 ms = l.managerConfig[p.subject].managerSubject;
            bool ok = ms != 0 && _isMember(l, ms, msg.sender);
            if (!ok && _isContainingManager(l, p.subject, msg.sender, 0) == 0) revert NotAuthorizedManager();
        }
        // An Offer pending wrote a Delegated Grant (ALLOW) rule at creation (delegatedOffer). Deleting
        // the pending alone would strand that rule live, so the target could claim IMMEDIATELY with no
        // delay and no manager re-check — worse than an uncancelled offer. Mirror withdrawOffer's dual
        // cleanup and drop the rule too. Grant/Remove pendings write no rule at creation, so nothing
        // to clear there (D2).
        if (p.action == AccessV2Types.PendingKind.Offer) {
            uint256 subject = p.subject;
            address user = p.user;
            if (l.ruleOf[subject][user].kind == AccessV2Types.RuleKind.Grant) {
                delete l.ruleOf[subject][user];
                emit RuleCleared(subject, user);
            }
        }
        _deletePending(l, pendingId);
        emit PendingActionCancelled(pendingId, msg.sender);
    }

    /*═══════════════════════════════ Vouch admin + perm writes ═══════════════════════════════*/

    function configureVouchAttestor(uint256 subject, uint32 quorum, uint256 voucherSubject) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        _configureVouch(l, subject, quorum, voucherSubject);
    }

    function _configureVouch(Layout storage l, uint256 subject, uint32 quorum, uint256 voucherSubject) internal {
        SubjectRec storage s = l.subjects[subject];
        if (!s.exists) revert UnknownSubject();
        if (s.kind == AccessV2Types.SubjectKind.Group) revert WiringIncompatible();
        // C1: a self-referential voucher config (voucherSubject == subject) is a REAL live semantic —
        // KUBI's Executive role is Execs-vouch-Execs. It is NOT structurally incoherent: only an EMPTY
        // subject bootstrap-deadlocks (nobody is a member to cast the first vouch), and that is
        // recoverable via a governance grant/seed exactly like legacy. So it is a NON-REVERTING lint
        // (ruling 4 lint discipline), not a WiringIncompatible revert.
        l.vouchConfigs[subject] = VouchCfg({quorum: quorum, voucherSubject: voucherSubject});
        emit VouchConfigured(subject, quorum, voucherSubject);
        if (quorum != 0) {
            if (voucherSubject == subject) emit ConfigLint(subject, uint8(AccessV2Types.LintCode.SelfVoucher));
            if (s.defaultAllow) emit ConfigLint(subject, uint8(AccessV2Types.LintCode.QuorumNoOp));
            if (s.maxMembers != 0) emit ConfigLint(subject, uint8(AccessV2Types.LintCode.VouchWithMaxMembers));
        }
    }

    function resetVouchEpoch(uint256 subject) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        if (!l.subjects[subject].exists) revert UnknownSubject();
        uint64 e = ++l.vouchEpoch[subject];
        emit VouchEpochReset(subject, e);
    }

    function clearUserVouches(uint256 subject, address user) external nonReentrant(layout()) {
        Layout storage l = layout();
        _onlyExecutor(l);
        // Strand the wearer's vouch state PERMANENTLY by bumping the per-user generation: every
        // prior per-voucher record (vouchers / voucherRecordGen) is now stale forever, because
        // vouch()/revokeVouch() validate records against BOTH the subject epoch AND this generation.
        // The SENTINEL epoch reset alone was insufficient — a later fresh vouch() resets
        // wearerVouchEpoch back to the recoverable subject epoch, which would have revived the stale
        // records and let their revokeVouch underflow currentVouchCount to type(uint32).max,
        // restoring governance-cleared eligibility. The generation bump makes that impossible.
        unchecked {
            l.userVouchGen[subject][user] += 1;
        }
        l.currentVouchCount[subject][user] = 0;
        l.wearerVouchEpoch[subject][user] = SENTINEL;
        emit UserVouchesCleared(subject, user);
        _reconcileOne(l, subject, user);
    }

    function setMaxDailyVouches(uint32 maxVouches) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        if (maxVouches == 0) revert InvalidMaxDailyVouches();
        l.maxDailyVouches = maxVouches;
        emit MaxDailyVouchesSet(maxVouches);
    }

    function setPerm(uint256 subject, bytes32 permKey, bytes32 ctx, uint256 word) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        _setPerm(l, subject, permKey, ctx, word);
    }

    function _setPerm(Layout storage l, uint256 subject, bytes32 permKey, bytes32 ctx, uint256 word) internal {
        SubjectRec storage s = l.subjects[subject];
        if (!s.exists) revert UnknownSubject();
        bool existed = l.perm[subject][permKey][ctx] & AccessV2PermKeys.EXISTS_BIT != 0;
        l.perm[subject][permKey][ctx] = word;
        if (!existed) {
            uint256[] storage arr = l.subjectsWithKeyList[permKey][ctx];
            if (arr.length >= PERM_FANOUT_LIMIT) revert PermFanoutLimit();
            arr.push(subject);
            l.subjectKeyIndex[permKey][ctx][subject] = arr.length;
            unchecked {
                ++s.permCount;
            }
        }
        emit PermSet(subject, permKey, ctx, word);
        if (s.defaultAllow) emit ConfigLint(subject, uint8(AccessV2Types.LintCode.DefaultAllowStrongPerms));
        if (_groupFanout(l, permKey, ctx) > 3) emit ConfigLint(subject, uint8(AccessV2Types.LintCode.GroupFanout));
    }

    function clearPerm(uint256 subject, bytes32 permKey, bytes32 ctx) external {
        Layout storage l = layout();
        _onlyExecutor(l);
        if (l.perm[subject][permKey][ctx] & AccessV2PermKeys.EXISTS_BIT == 0) {
            emit PermCleared(subject, permKey, ctx);
            return;
        }
        delete l.perm[subject][permKey][ctx];
        uint256 idx1 = l.subjectKeyIndex[permKey][ctx][subject];
        _swapPop(l.subjectsWithKeyList[permKey][ctx], l.subjectKeyIndex[permKey][ctx], subject, idx1);
        if (l.subjects[subject].permCount != 0) {
            unchecked {
                --l.subjects[subject].permCount;
            }
        }
        emit PermCleared(subject, permKey, ctx);
    }

    /*═══════════════════════════════ Shared internals ═══════════════════════════════*/

    function _writeRule(
        Layout storage l,
        uint256 subject,
        address user,
        AccessV2Types.RuleKind kind,
        AccessV2Types.RuleAuthor author,
        bool delegable,
        uint256 managerSubject
    ) internal {
        if (kind == AccessV2Types.RuleKind.None) {
            delete l.ruleOf[subject][user];
            return;
        }
        RuleRec storage r = l.ruleOf[subject][user];
        r.kind = kind;
        r.author = author;
        r.delegable = delegable;
        r.managerSubject = managerSubject;
    }

    /// @dev Write the rule slot AND emit RuleSet — the two always travel together (size dedup).
    function _writeRuleEmit(
        Layout storage l,
        uint256 subject,
        address user,
        AccessV2Types.RuleKind kind,
        AccessV2Types.RuleAuthor author,
        bool delegable,
        uint256 managerSubject
    ) internal {
        _writeRule(l, subject, user, kind, author, delegable, managerSubject);
        emit RuleSet(subject, user, uint8(kind), uint8(author), delegable);
    }

    function _reconcileAfterRuleWrite(
        Layout storage l,
        uint256 subject,
        address user,
        bool banned,
        address actor,
        bool delegated
    ) internal {
        if (l.subjects[subject].kind != AccessV2Types.SubjectKind.Role) return;
        if (l.membership[subject][user].accepted && !_eligibleRole(l, subject, user)) {
            _flipOff(l, subject, user);
            emit RoleRemoved(subject, user, banned, actor, delegated);
        }
    }

    function _survivingSources(Layout storage l, uint256 subject, address user) internal view returns (uint8 srcs) {
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind == AccessV2Types.RuleKind.Ban) return 0;
        if (r.kind == AccessV2Types.RuleKind.Grant && r.author == AccessV2Types.RuleAuthor.Governance && !r.delegable) {
            srcs |= SRC_STICKY_GRANT;
        }
        if (l.emailVerified[subject][user]) srcs |= SRC_EMAIL_VERIFIED;
        if (_vouchMet(l, subject, user)) srcs |= SRC_VOUCH_QUORUM;
        if (l.subjects[subject].defaultAllow) srcs |= SRC_DEFAULT_ALLOW;
    }

    function _createPending(Layout storage l, AccessV2Types.PendingKind action, uint256 subject, address user, bool ban)
        internal
        returns (uint256 pid)
    {
        if (l.pendingOf[subject][user] != 0) revert PendingActionExists();
        pid = ++l.pendingSeq;
        uint64 activatesAt = uint64(block.timestamp) + l.managerConfig[subject].delaySecs;
        l.pending[pid] = PendingRec({
            action: action,
            subject: subject,
            user: user,
            actor: msg.sender,
            activatesAt: activatesAt,
            ban: ban,
            exists: true
        });
        l.pendingOf[subject][user] = pid;
        emit PendingActionCreated(pid, subject, user, uint8(action), msg.sender, activatesAt);
    }

    function _deletePending(Layout storage l, uint256 pid) internal {
        PendingRec storage p = l.pending[pid];
        delete l.pendingOf[p.subject][p.user];
        delete l.pending[pid];
    }

    function _voidPending(Layout storage l, uint256 subject, address user) internal {
        uint256 pid = l.pendingOf[subject][user];
        if (pid != 0) {
            delete l.pending[pid];
            delete l.pendingOf[subject][user];
            emit PendingActionVoided(pid);
        }
    }

    function _requireManager(Layout storage l, uint256 subject, address actor, uint8 cap)
        internal
        view
        returns (uint256 managerSubject)
    {
        ManagerCfg storage mc = l.managerConfig[subject];
        if (mc.managerSubject != 0 && (mc.caps & cap) != 0 && _isMember(l, mc.managerSubject, actor)) {
            return mc.managerSubject;
        }
        uint256 viaGroup = _isContainingManager(l, subject, actor, cap);
        if (viaGroup != 0) return viaGroup;
        revert NotAuthorizedManager();
    }

    function _isContainingManager(Layout storage l, uint256 subject, address actor, uint8 cap)
        internal
        view
        returns (uint256)
    {
        uint256[] storage groups = l.roleGroups[subject];
        for (uint256 i; i < groups.length;) {
            ManagerCfg storage gc = l.managerConfig[groups[i]];
            if (gc.managerSubject != 0 && (cap == 0 || (gc.caps & cap) != 0) && _isMember(l, gc.managerSubject, actor))
            {
                return gc.managerSubject;
            }
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    function _flipOn(Layout storage l, uint256 subject, address user) internal {
        _flipOnAt(l, subject, user, uint64(block.timestamp));
    }

    /// @dev Accepted-flip with an EXPLICIT activation timestamp. Runtime paths pass block.timestamp
    ///      (via {_flipOn}); the SEED path passes `1` (epoch) so pre-existing seeded members predate
    ///      any in-flight proposal's createdAt — keeping those proposals votable — while the §4
    ///      activation gate still binds post-cutover claim() members (acceptedAt = now). (Ruling R7.)
    function _flipOnAt(Layout storage l, uint256 subject, address user, uint64 at) internal {
        if (user == address(0)) revert ZeroAddress();
        MembershipRec storage m = l.membership[subject][user];
        if (m.accepted) revert AlreadyMember();
        uint256[] storage roles = l.userSubjectList[user];
        if (roles.length >= ROLE_LIMIT) revert RoleLimit();
        SubjectRec storage s = l.subjects[subject];
        if (s.maxMembers != 0 && s.memberCount >= s.maxMembers) revert SubjectFull(subject, _findLapsed(l, subject));
        m.accepted = true;
        m.acceptedAt = at;
        unchecked {
            ++s.memberCount;
        }
        roles.push(subject);
        l.userSubjectIndex[user][subject] = roles.length;
        address[] storage mem = l.subjectMembers[subject];
        mem.push(user);
        l.subjectMemberIndex[subject][user] = mem.length;
        emit TransferSingle(msg.sender, address(0), user, subject, 1);
    }

    function _flipOff(Layout storage l, uint256 subject, address user) internal {
        MembershipRec storage m = l.membership[subject][user];
        m.accepted = false;
        m.acceptedAt = 0;
        SubjectRec storage s = l.subjects[subject];
        if (s.memberCount != 0) {
            unchecked {
                --s.memberCount;
            }
        }
        _swapPop(l.userSubjectList[user], l.userSubjectIndex[user], subject, l.userSubjectIndex[user][subject]);
        _swapPopMember(l.subjectMembers[subject], l.subjectMemberIndex[subject], user);
        emit TransferSingle(msg.sender, user, address(0), subject, 1);
    }

    function _findLapsed(Layout storage l, uint256 subject) internal view returns (address) {
        address[] storage mem = l.subjectMembers[subject];
        for (uint256 i; i < mem.length;) {
            if (!_eligibleRole(l, subject, mem[i])) return mem[i];
            unchecked {
                ++i;
            }
        }
        return address(0);
    }

    function _reconcileOne(Layout storage l, uint256 subject, address user) internal {
        if (!l.membership[subject][user].accepted) return;
        if (_isMember(l, subject, user)) return;
        _flipOff(l, subject, user);
        emit MembershipReconciled(subject, user);
    }

    function _swapPop(uint256[] storage arr, mapping(uint256 => uint256) storage idxOf, uint256 key, uint256 idx1)
        internal
    {
        if (idx1 == 0) return;
        uint256 i = idx1 - 1;
        uint256 last = arr.length - 1;
        if (i != last) {
            uint256 moved = arr[last];
            arr[i] = moved;
            idxOf[moved] = i + 1;
        }
        arr.pop();
        delete idxOf[key];
    }

    function _swapPopMember(address[] storage arr, mapping(address => uint256) storage idxOf, address key) internal {
        uint256 idx1 = idxOf[key];
        if (idx1 == 0) return;
        uint256 i = idx1 - 1;
        uint256 last = arr.length - 1;
        if (i != last) {
            address moved = arr[last];
            arr[i] = moved;
            idxOf[moved] = i + 1;
        }
        arr.pop();
        delete idxOf[key];
    }

    /*═══════════════════════════════ Eligibility fold + reads (shared) ═══════════════════════════════*/

    function _requireRole(Layout storage l, uint256 subject) internal view {
        SubjectRec storage s = l.subjects[subject];
        if (!s.exists) revert UnknownSubject();
        if (s.kind != AccessV2Types.SubjectKind.Role) revert NotAGroup();
    }

    function _eligibleRole(Layout storage l, uint256 subject, address user) internal view returns (bool) {
        RuleRec storage r = l.ruleOf[subject][user];
        if (r.kind == AccessV2Types.RuleKind.Ban) return false;
        if (r.kind == AccessV2Types.RuleKind.Grant) return true;
        if (l.emailVerified[subject][user]) return true;
        if (_vouchMet(l, subject, user)) return true;
        return l.subjects[subject].defaultAllow;
    }

    function _vouchMet(Layout storage l, uint256 subject, address user) internal view returns (bool) {
        VouchCfg storage cfg = l.vouchConfigs[subject];
        if (cfg.quorum == 0) return false;
        uint32 eff = l.wearerVouchEpoch[subject][user] == l.vouchEpoch[subject] ? l.currentVouchCount[subject][user] : 0;
        return eff >= cfg.quorum;
    }

    function _isMember(Layout storage l, uint256 subject, address user) internal view returns (bool) {
        SubjectRec storage s = l.subjects[subject];
        if (s.kind == AccessV2Types.SubjectKind.Group) return _memberOfGroup(l, subject, user);
        if (!l.membership[subject][user].accepted) return false;
        return _eligibleRole(l, subject, user);
    }

    function _memberOfGroup(Layout storage l, uint256 group, address user) internal view returns (bool) {
        uint256[] storage roles = l.groupRoles[group];
        for (uint256 i; i < roles.length;) {
            uint256 rid = roles[i];
            if (l.membership[rid][user].accepted && _eligibleRole(l, rid, user)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _isInOrg(Layout storage l, address user) internal view returns (bool) {
        return l.userSubjectList[user].length > 0;
    }

    function _maxDailyVouches(Layout storage l) internal view returns (uint32) {
        uint32 stored = l.maxDailyVouches;
        return stored > 0 ? stored : DEFAULT_MAX_DAILY_VOUCHES;
    }

    function _hasPerm(Layout storage l, address user, bytes32 permKey, bytes32 ctx)
        internal
        view
        returns (uint256 acc)
    {
        uint8 tag = AccessV2PermKeys.foldTag(permKey);
        uint256[] storage ctxArr = l.subjectsWithKeyList[permKey][ctx];
        uint256 cl = ctxArr.length;
        for (uint256 i; i < cl;) {
            uint256 sid = ctxArr[i];
            if (_isMember(l, sid, user)) acc = _fold(acc, _resolveCtx(l, sid, permKey, ctx, tag), tag);
            unchecked {
                ++i;
            }
        }
        if (ctx != bytes32(0)) {
            uint256[] storage gArr = l.subjectsWithKeyList[permKey][bytes32(0)];
            uint256 gl = gArr.length;
            for (uint256 i; i < gl;) {
                uint256 sid = gArr[i];
                if (l.subjectKeyIndex[permKey][ctx][sid] == 0 && _isMember(l, sid, user)) {
                    acc = _fold(acc, l.perm[sid][permKey][bytes32(0)] & AccessV2PermKeys.VALUE_MASK, tag);
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _resolveCtx(Layout storage l, uint256 subject, bytes32 permKey, bytes32 ctx, uint8 tag)
        internal
        view
        returns (uint256)
    {
        uint256 proj = l.perm[subject][permKey][ctx];
        if (proj & AccessV2PermKeys.EXISTS_BIT != 0) {
            if (proj & AccessV2PermKeys.INHERIT_GLOBAL_BIT != 0) {
                uint256 glob = l.perm[subject][permKey][bytes32(0)] & AccessV2PermKeys.VALUE_MASK;
                return _fold(glob, proj & AccessV2PermKeys.VALUE_MASK, tag);
            }
            return proj & AccessV2PermKeys.VALUE_MASK;
        }
        return l.perm[subject][permKey][bytes32(0)] & AccessV2PermKeys.VALUE_MASK;
    }

    function _fold(uint256 acc, uint256 v, uint8 tag) internal pure returns (uint256) {
        if (tag == AccessV2PermKeys.TAG_OR_MASK) return acc | v;
        if (tag == AccessV2PermKeys.TAG_MAX) return v > acc ? v : acc;
        return acc != 0 ? acc : v;
    }

    function _groupFanout(Layout storage l, bytes32 permKey, bytes32 ctx) internal view returns (uint256 count) {
        uint256[] storage arr = l.subjectsWithKeyList[permKey][ctx];
        for (uint256 i; i < arr.length;) {
            if (l.subjects[arr[i]].kind == AccessV2Types.SubjectKind.Group) {
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _activeMemberSince(Layout storage l, uint256 subject, address user) internal view returns (uint64) {
        SubjectRec storage s = l.subjects[subject];
        if (s.kind == AccessV2Types.SubjectKind.Group) {
            uint64 earliest = SENTINEL;
            uint256[] storage roles = l.groupRoles[subject];
            for (uint256 i; i < roles.length;) {
                uint256 rid = roles[i];
                if (l.membership[rid][user].accepted && _eligibleRole(l, rid, user)) {
                    uint64 t = l.membership[rid][user].acceptedAt;
                    if (t < earliest) earliest = t;
                }
                unchecked {
                    ++i;
                }
            }
            return earliest;
        }
        if (l.membership[subject][user].accepted && _eligibleRole(l, subject, user)) {
            return l.membership[subject][user].acceptedAt;
        }
        return SENTINEL;
    }

    function _isRegisteredEmailModule(address executor_, address caller) internal view returns (bool) {
        if (executor_.code.length == 0) return false;
        try IExecutorMinterLib(executor_).isAuthorizedHatMinter(caller) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
