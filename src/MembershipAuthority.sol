// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IMembershipAuthority} from "./interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "./libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "./libs/AccessV2PermKeys.sol";
import {MembershipAuthorityLogic as Lib} from "./libs/MembershipAuthorityLogic.sol";
import {MembershipAuthoritySeed as Seed} from "./libs/MembershipAuthoritySeed.sol";

/// @title MembershipAuthority
/// @notice ONE per-org authority (ERC-7201, BeaconProxy) unifying membership, the tri-state
///         eligibility fold, the semantic permission table, manager delegation, seed/migration and
///         the Hats/ERC-1155 read surface (ACCESS-V2-SPEC.md §1–§5; ACCESS-V2-INTERFACES.md §0–§5).
/// @dev Root auth is the org Executor BY ADDRESS. Pause gates NON-executor writes only; executor
///      writes and all reads are pause-exempt (freeze SPEC ERRATA / ruling 5). Cold surfaces
///      (seed/config/delegation/vouch-admin/rule writes) live in {MembershipAuthorityLogic}, reached
///      by DELEGATECALL, to stay under EIP-170; the hot read surface + accepted-flip user writes
///      stay in this hub. Both share the ONE {MembershipAuthorityLogic.Layout} declaration.
contract MembershipAuthority is Initializable, IMembershipAuthority {
    /*═══════════════════════════════ Modifiers ═══════════════════════════════*/

    modifier nonReentrant() {
        Lib.Layout storage l = Lib.layout();
        if (l.lock == 2) revert Paused();
        l.lock = 2;
        _;
        l.lock = 1;
    }

    constructor() {
        _disableInitializers();
    }

    /*═══════════════════════════════ Initialize ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function initialize(InitConfig calldata cfg) external initializer {
        if (cfg.executor == address(0)) revert ZeroAddress();
        Lib.Layout storage l = Lib.layout();
        l.executor = cfg.executor;
        l.paymasterHub = cfg.paymasterHub;
        l.orgId = cfg.orgId;
        l.paused = true; // born paused (ruling 1)
        l.lock = 1;
        emit MembershipAuthorityInitialized(cfg.executor, cfg.orgId, true);
        emit PausedSet(true);
        Seed.applySeed(cfg.seed);
    }

    /*═══════════════════════════════ User self-service (pause-gated) ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function claim(uint256 subject) external nonReentrant {
        Lib.Layout storage l = Lib.layout();
        Lib._gateNonExecutor(l);
        Lib._requireRole(l, subject);
        if (l.membership[subject][msg.sender].accepted) revert AlreadyMember();

        uint256 pid = l.pendingOf[subject][msg.sender];
        if (pid != 0 && l.pending[pid].action == AccessV2Types.PendingKind.Offer) {
            Lib.PendingRec storage p = l.pending[pid];
            if (block.timestamp < p.activatesAt) revert NotYetActive(p.activatesAt);
            if (!Lib._eligibleRole(l, subject, msg.sender)) revert NotClaimable();
            Lib._requireManager(l, subject, p.actor, Lib.CAP_GRANT);
            Lib._deletePending(l, pid);
        } else {
            if (!Lib._eligibleRole(l, subject, msg.sender)) revert NotClaimable();
        }
        Lib._flipOn(l, subject, msg.sender);
        emit RoleClaimed(subject, msg.sender);
    }

    /// @inheritdoc IMembershipAuthority
    function renounce(uint256 subject) external nonReentrant {
        Lib.Layout storage l = Lib.layout();
        Lib._gateNonExecutor(l);
        Lib._requireRole(l, subject);
        if (!l.membership[subject][msg.sender].accepted) revert NotMember();
        Lib.RuleRec storage r = l.ruleOf[subject][msg.sender];
        if (r.kind == AccessV2Types.RuleKind.Grant && (r.author == AccessV2Types.RuleAuthor.Delegated || r.delegable)) {
            delete l.ruleOf[subject][msg.sender];
        }
        Lib._flipOff(l, subject, msg.sender);
        emit RoleRenounced(subject, msg.sender);
    }

    /// @inheritdoc IMembershipAuthority
    function reconcile(uint256 subject, address user) external nonReentrant {
        Lib._reconcileOne(Lib.layout(), subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function reconcile(uint256 subject, address[] calldata users) external nonReentrant {
        Lib.Layout storage l = Lib.layout();
        for (uint256 i; i < users.length;) {
            Lib._reconcileOne(l, subject, users[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IMembershipAuthority
    function vouch(uint256 subject, address user) external nonReentrant {
        Lib.Layout storage l = Lib.layout();
        Lib._gateNonExecutor(l);
        if (user == address(0)) revert ZeroAddress();
        Lib.VouchCfg storage cfg = l.vouchConfigs[subject];
        if (cfg.quorum == 0) revert WiringIncompatible();
        if (!Lib._isMember(l, cfg.voucherSubject, msg.sender)) revert NotAuthorizedManager();

        uint64 epoch = l.vouchEpoch[subject];
        if (l.wearerVouchEpoch[subject][user] != epoch) {
            l.currentVouchCount[subject][user] = 0;
            l.wearerVouchEpoch[subject][user] = epoch;
        }
        uint64 gen = l.userVouchGen[subject][user];
        if (
            l.vouchers[subject][user][msg.sender] && l.voucherRecordEpoch[subject][user][msg.sender] == epoch
                && l.voucherRecordGen[subject][user][msg.sender] == gen
        ) {
            revert AlreadyVouched();
        }
        uint256 day = block.timestamp / Lib.SECONDS_PER_DAY;
        uint32 today = l.dailyVouchCount[msg.sender][day];
        if (today >= Lib._maxDailyVouches(l)) revert VouchRateLimited();
        l.dailyVouchCount[msg.sender][day] = today + 1;

        l.vouchers[subject][user][msg.sender] = true;
        l.voucherRecordEpoch[subject][user][msg.sender] = epoch;
        l.voucherRecordGen[subject][user][msg.sender] = gen;
        unchecked {
            l.currentVouchCount[subject][user] += 1;
        }
        emit Vouched(subject, user, msg.sender);
    }

    /// @inheritdoc IMembershipAuthority
    function revokeVouch(uint256 subject, address user) external nonReentrant {
        Lib.Layout storage l = Lib.layout();
        Lib._gateNonExecutor(l);
        uint64 epoch = l.vouchEpoch[subject];
        if (l.wearerVouchEpoch[subject][user] != epoch) revert HasNotVouched();
        if (
            !l.vouchers[subject][user][msg.sender] || l.voucherRecordEpoch[subject][user][msg.sender] != epoch
                || l.voucherRecordGen[subject][user][msg.sender] != l.userVouchGen[subject][user]
        ) {
            revert HasNotVouched();
        }
        // Defense-in-depth: a stale record can never make this underflow (the gen check above
        // strands cleared records), but guard the decrement explicitly so no future path can wrap
        // currentVouchCount to type(uint32).max and forge eligibility.
        uint32 c = l.currentVouchCount[subject][user];
        if (c == 0) revert HasNotVouched();
        l.vouchers[subject][user][msg.sender] = false;
        l.currentVouchCount[subject][user] = c - 1;
        emit VouchRevoked(subject, user, msg.sender);
        Lib._reconcileOne(l, subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function setEmailVerified(address wearer, uint256[] calldata hatIds) external nonReentrant {
        if (wearer == address(0)) revert ZeroAddress();
        Lib.Layout storage l = Lib.layout();
        if (msg.sender != l.executor) {
            Lib._gateNonExecutor(l);
            if (!Lib._isRegisteredEmailModule(l.executor, msg.sender)) revert NotRegisteredModule();
        }
        for (uint256 i; i < hatIds.length;) {
            l.emailVerified[hatIds[i]][wearer] = true;
            emit EmailVerifiedSet(hatIds[i], wearer, true);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IMembershipAuthority
    function mintHat(uint256 subjectId, address user) external nonReentrant returns (bool) {
        Lib.Layout storage l = Lib.layout();
        if (msg.sender != l.executor) revert NotExecutor();
        Lib._requireRole(l, subjectId);
        if (user == address(0)) revert ZeroAddress();
        if (l.membership[subjectId][user].accepted) return true;
        if (!Lib._eligibleRole(l, subjectId, user)) revert NotMember();
        Lib._flipOn(l, subjectId, user);
        emit RoleGranted(subjectId, user, msg.sender, false);
        return true;
    }

    /// @inheritdoc IMembershipAuthority
    function setPaused(bool p) external {
        Lib.Layout storage l = Lib.layout();
        if (msg.sender != l.executor) revert NotExecutor();
        l.paused = p;
        emit PausedSet(p);
    }

    /*═══════════════════════════════ Cold-surface forwards (delegatecall lib) ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function createRole(string calldata name, bytes32 metadataCID, string calldata imageURI, uint32 maxMembers)
        external
        returns (uint256)
    {
        return Lib.createRole(name, metadataCID, imageURI, maxMembers);
    }

    /// @inheritdoc IMembershipAuthority
    function createGroup(
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint256[] calldata memberRoleIds
    ) external returns (uint256) {
        return Lib.createGroup(name, metadataCID, imageURI, memberRoleIds);
    }

    /// @inheritdoc IMembershipAuthority
    function addRoleToGroup(uint256 roleId, uint256 groupId) external {
        Lib.addRoleToGroup(roleId, groupId);
    }

    /// @inheritdoc IMembershipAuthority
    function removeRoleFromGroup(uint256 roleId, uint256 groupId) external {
        Lib.removeRoleFromGroup(roleId, groupId);
    }

    /// @inheritdoc IMembershipAuthority
    function renameSubject(uint256 subjectId, string calldata name, bytes32 metadataCID, string calldata imageURI)
        external
    {
        Lib.renameSubject(subjectId, name, metadataCID, imageURI);
    }

    /// @inheritdoc IMembershipAuthority
    function setMaxMembers(uint256 subjectId, uint32 maxMembers) external {
        Lib.setMaxMembers(subjectId, maxMembers);
    }

    /// @inheritdoc IMembershipAuthority
    function setSubjectDefault(uint256 subjectId, bool allow, bool force) external {
        Lib.setSubjectDefault(subjectId, allow, force);
    }

    /// @inheritdoc IMembershipAuthority
    function setRule(uint256 subject, address user, AccessV2Types.RuleKind kind, bool delegable) external {
        Lib.setRule(subject, user, kind, delegable);
    }

    /// @inheritdoc IMembershipAuthority
    function clearRule(uint256 subject, address user) external {
        Lib.clearRule(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function grant(uint256 subject, address user, bool delegable) external {
        Lib.grant(subject, user, delegable);
    }

    /// @inheritdoc IMembershipAuthority
    function offer(uint256 subject, address user, bool delegable) external {
        Lib.offer(subject, user, delegable);
    }

    /// @inheritdoc IMembershipAuthority
    function withdrawOffer(uint256 subject, address user) external {
        Lib.withdrawOffer(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function remove(uint256 subject, address user, bool ban) external {
        Lib.remove(subject, user, ban);
    }

    /// @inheritdoc IMembershipAuthority
    function unremove(uint256 subject, address user) external {
        Lib.unremove(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function setManagerConfig(uint256 subject, uint256 managerSubject, uint8 caps, uint32 delaySecs) external {
        Lib.setManagerConfig(subject, managerSubject, caps, delaySecs);
    }

    /// @inheritdoc IMembershipAuthority
    function delegatedGrant(uint256 subject, address user) external returns (uint256) {
        return Lib.delegatedGrant(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function delegatedOffer(uint256 subject, address user) external returns (uint256) {
        return Lib.delegatedOffer(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function delegatedRemove(uint256 subject, address user, bool ban) external returns (uint256) {
        return Lib.delegatedRemove(subject, user, ban);
    }

    /// @inheritdoc IMembershipAuthority
    function delegatedUnremove(uint256 subject, address user) external {
        Lib.delegatedUnremove(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function finalize(uint256 pendingId) external {
        Lib.finalize(pendingId);
    }

    /// @inheritdoc IMembershipAuthority
    function cancel(uint256 pendingId) external {
        Lib.cancel(pendingId);
    }

    /// @inheritdoc IMembershipAuthority
    function configureVouchAttestor(uint256 subject, uint32 quorum, uint256 voucherSubject) external {
        Lib.configureVouchAttestor(subject, quorum, voucherSubject);
    }

    /// @inheritdoc IMembershipAuthority
    function resetVouchEpoch(uint256 subject) external {
        Lib.resetVouchEpoch(subject);
    }

    /// @inheritdoc IMembershipAuthority
    function clearUserVouches(uint256 subject, address user) external {
        Lib.clearUserVouches(subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function setMaxDailyVouches(uint32 maxVouches) external {
        Lib.setMaxDailyVouches(maxVouches);
    }

    /// @inheritdoc IMembershipAuthority
    function setPerm(uint256 subject, bytes32 permKey, bytes32 ctx, uint256 word) external {
        Lib.setPerm(subject, permKey, ctx, word);
    }

    /// @inheritdoc IMembershipAuthority
    function clearPerm(uint256 subject, bytes32 permKey, bytes32 ctx) external {
        Lib.clearPerm(subject, permKey, ctx);
    }

    /// @inheritdoc IMembershipAuthority
    function seedSubjects(
        uint256[] calldata subjectIds,
        AccessV2Types.SubjectKind[] calldata kinds,
        string[] calldata names,
        uint32[] calldata maxMembers
    ) external {
        Seed.seedSubjects(subjectIds, kinds, names, maxMembers);
    }

    /// @inheritdoc IMembershipAuthority
    function seedRules(
        uint256[] calldata subjects,
        address[] calldata users,
        AccessV2Types.RuleKind[] calldata kinds,
        bool[] calldata delegable
    ) external {
        Seed.seedRules(subjects, users, kinds, delegable);
    }

    /// @inheritdoc IMembershipAuthority
    function seedMemberships(uint256[] calldata subjects, address[] calldata users) external {
        Seed.seedMemberships(subjects, users);
    }

    /// @inheritdoc IMembershipAuthority
    function seedPerms(
        uint256[] calldata subjects,
        bytes32[] calldata permKeys,
        bytes32[] calldata ctxs,
        uint256[] calldata words
    ) external {
        Seed.seedPerms(subjects, permKeys, ctxs, words);
    }

    /// @inheritdoc IMembershipAuthority
    function seedVouchers(uint256 subject, address user, address[] calldata vouchers) external {
        Seed.seedVouchers(subject, user, vouchers);
    }

    /// @inheritdoc IMembershipAuthority
    function seedEmailVerified(uint256 subject, address[] calldata users) external {
        Seed.seedEmailVerified(subject, users);
    }

    /// @inheritdoc IMembershipAuthority
    function emitUnportedBurns(uint256[] calldata subjects, address[] calldata users) external {
        Seed.emitUnportedBurns(subjects, users);
    }

    /*═══════════════════════════════ Views: membership ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function isMember(uint256 subject, address user) external view returns (bool) {
        return Lib._isMember(Lib.layout(), subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function getStatus(uint256 subject, address user)
        external
        view
        returns (bool accepted, bool eligible_, uint64 acceptedAt, AccessV2Types.RuleKind ruleKind)
    {
        Lib.Layout storage l = Lib.layout();
        Lib.SubjectRec storage s = l.subjects[subject];
        if (s.kind == AccessV2Types.SubjectKind.Group) {
            return (false, Lib._memberOfGroup(l, subject, user), 0, AccessV2Types.RuleKind.None);
        }
        Lib.MembershipRec storage m = l.membership[subject][user];
        return (m.accepted, Lib._eligibleRole(l, subject, user), m.acceptedAt, l.ruleOf[subject][user].kind);
    }

    /// @inheritdoc IMembershipAuthority
    function memberCount(uint256 subject) external view returns (uint256) {
        return Lib.layout().subjects[subject].memberCount;
    }

    /*═══════════════════════════════ Views: permissions (§3 inverted fold) ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function hasPerm(address user, bytes32 permKey, bytes32 ctx) external view returns (uint256) {
        return Lib._hasPerm(Lib.layout(), user, permKey, ctx);
    }

    /// @inheritdoc IMembershipAuthority
    function activeMemberSince(uint256 subject, address user) external view returns (uint64) {
        return Lib._activeMemberSince(Lib.layout(), subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function activeMemberSince(address user, bytes32 permKey, bytes32 ctx) external view returns (uint64 earliest) {
        Lib.Layout storage l = Lib.layout();
        earliest = Lib.SENTINEL;
        uint256[] storage ctxArr = l.subjectsWithKeyList[permKey][ctx];
        for (uint256 i; i < ctxArr.length;) {
            uint64 t = Lib._activeMemberSince(l, ctxArr[i], user);
            if (t < earliest) earliest = t;
            unchecked {
                ++i;
            }
        }
        if (ctx != bytes32(0)) {
            uint256[] storage gArr = l.subjectsWithKeyList[permKey][bytes32(0)];
            for (uint256 i; i < gArr.length;) {
                uint256 sid = gArr[i];
                if (l.subjectKeyIndex[permKey][ctx][sid] == 0) {
                    uint64 t = Lib._activeMemberSince(l, sid, user);
                    if (t < earliest) earliest = t;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /*═══════════════════════════════ Views: preflights (§4) ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function canGrant(uint256 subject, address user)
        external
        view
        returns (AccessV2Types.ActionReason reason, address lapsedCandidate)
    {
        Lib.Layout storage l = Lib.layout();
        Lib.SubjectRec storage s = l.subjects[subject];
        if (!s.exists || s.kind != AccessV2Types.SubjectKind.Role) {
            return (AccessV2Types.ActionReason.UnknownSubject, address(0));
        }
        if (l.membership[subject][user].accepted) return (AccessV2Types.ActionReason.AlreadyMember, address(0));
        Lib.RuleRec storage r = l.ruleOf[subject][user];
        // Mirror the enforcement guard (delegatedGrant/Offer): a delegated action is blocked by ANY
        // non-delegable governance rule (grant OR ban), not just a ban — otherwise this preflight
        // would say Ok on a sticky-grant seat a delegate cannot actually touch.
        if (r.kind != AccessV2Types.RuleKind.None && r.author == AccessV2Types.RuleAuthor.Governance && !r.delegable) {
            return (AccessV2Types.ActionReason.BlockedByGovernanceBan, address(0));
        }
        if (!Lib._isInOrg(l, user)) return (AccessV2Types.ActionReason.NotInOrg, address(0));
        if (s.maxMembers != 0 && s.memberCount >= s.maxMembers) {
            return (AccessV2Types.ActionReason.SubjectFull, Lib._findLapsed(l, subject));
        }
        return (AccessV2Types.ActionReason.Ok, address(0));
    }

    /// @inheritdoc IMembershipAuthority
    function canRemove(uint256 subject, address user, bool ban)
        external
        view
        returns (AccessV2Types.ActionReason reason, uint8 sourceSet)
    {
        Lib.Layout storage l = Lib.layout();
        Lib.SubjectRec storage s = l.subjects[subject];
        if (!s.exists || s.kind != AccessV2Types.SubjectKind.Role) {
            return (AccessV2Types.ActionReason.UnknownSubject, 0);
        }
        if (!l.membership[subject][user].accepted) return (AccessV2Types.ActionReason.NotMember, 0);
        if (ban) return (AccessV2Types.ActionReason.Ok, 0);
        uint8 srcs;
        if (l.emailVerified[subject][user]) srcs |= Lib.SRC_EMAIL_VERIFIED;
        if (Lib._vouchMet(l, subject, user)) srcs |= Lib.SRC_VOUCH_QUORUM;
        if (s.defaultAllow) srcs |= Lib.SRC_DEFAULT_ALLOW;
        if (srcs != 0) return (AccessV2Types.ActionReason.RemovalIneffective, srcs);
        return (AccessV2Types.ActionReason.Ok, 0);
    }

    /// @inheritdoc IMembershipAuthority
    function canClaim(uint256 subject, address user)
        external
        view
        returns (AccessV2Types.ActionReason reason, uint64 activatesAt, address lapsedCandidate)
    {
        Lib.Layout storage l = Lib.layout();
        Lib.SubjectRec storage s = l.subjects[subject];
        if (!s.exists || s.kind != AccessV2Types.SubjectKind.Role) {
            return (AccessV2Types.ActionReason.UnknownSubject, 0, address(0));
        }
        if (l.membership[subject][user].accepted) return (AccessV2Types.ActionReason.AlreadyMember, 0, address(0));

        uint256 pid = l.pendingOf[subject][user];
        if (pid != 0 && l.pending[pid].action == AccessV2Types.PendingKind.Offer) {
            uint64 at = l.pending[pid].activatesAt;
            if (block.timestamp < at) return (AccessV2Types.ActionReason.NotYetActive, at, address(0));
        } else if (!Lib._eligibleRole(l, subject, user)) {
            return (AccessV2Types.ActionReason.NoRuleToClaim, 0, address(0));
        }
        if (s.maxMembers != 0 && s.memberCount >= s.maxMembers) {
            return (AccessV2Types.ActionReason.SubjectFull, 0, Lib._findLapsed(l, subject));
        }
        Lib.RuleRec storage r = l.ruleOf[subject][user];
        if (
            pid == 0 && r.kind == AccessV2Types.RuleKind.Grant && r.author == AccessV2Types.RuleAuthor.Governance
                && !r.delegable
        ) return (AccessV2Types.ActionReason.RenouncedClaimable, 0, address(0));
        return (AccessV2Types.ActionReason.Ok, 0, address(0));
    }

    /*═══════════════════════════════ Views: eligibility internals + enumeration ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
    function eligible(uint256 subject, address user) external view returns (bool) {
        Lib.Layout storage l = Lib.layout();
        if (l.subjects[subject].kind == AccessV2Types.SubjectKind.Group) return Lib._memberOfGroup(l, subject, user);
        return Lib._eligibleRole(l, subject, user);
    }

    /// @inheritdoc IMembershipAuthority
    function getRule(uint256 subject, address user) external view returns (Rule memory) {
        Lib.RuleRec storage r = Lib.layout().ruleOf[subject][user];
        return Rule({kind: r.kind, author: r.author, managerSubject: r.managerSubject, delegable: r.delegable});
    }

    /// @inheritdoc IMembershipAuthority
    function getRuleFlags(uint256 subject, address user)
        external
        view
        returns (bool present, AccessV2Types.RuleKind kind, AccessV2Types.RuleAuthor author, bool delegable)
    {
        Lib.RuleRec storage r = Lib.layout().ruleOf[subject][user];
        return (r.kind != AccessV2Types.RuleKind.None, r.kind, r.author, r.delegable);
    }

    /// @inheritdoc IMembershipAuthority
    function getSubject(uint256 subjectId) external view returns (SubjectInfo memory) {
        Lib.SubjectRec storage s = Lib.layout().subjects[subjectId];
        return SubjectInfo({
            kind: s.kind,
            name: s.name,
            metadataCID: s.metadataCID,
            imageURI: s.imageURI,
            maxMembers: s.maxMembers,
            exists: s.exists
        });
    }

    /// @inheritdoc IMembershipAuthority
    function getManagerConfig(uint256 subjectId) external view returns (ManagerConfig memory) {
        Lib.ManagerCfg storage mc = Lib.layout().managerConfig[subjectId];
        return ManagerConfig({managerSubject: mc.managerSubject, caps: mc.caps, delaySecs: mc.delaySecs});
    }

    /// @inheritdoc IMembershipAuthority
    function getPending(uint256 pendingId) external view returns (PendingAction memory) {
        Lib.PendingRec storage p = Lib.layout().pending[pendingId];
        return PendingAction({
            action: p.action,
            subject: p.subject,
            user: p.user,
            actor: p.actor,
            activatesAt: p.activatesAt,
            ban: p.ban,
            exists: p.exists
        });
    }

    /// @inheritdoc IMembershipAuthority
    function getPerm(uint256 subject, bytes32 permKey, bytes32 ctx) external view returns (uint256 word) {
        return Lib.layout().perm[subject][permKey][ctx];
    }

    /// @inheritdoc IMembershipAuthority
    function subjectsWithKey(bytes32 permKey, bytes32 ctx) external view returns (uint256[] memory) {
        return Lib.layout().subjectsWithKeyList[permKey][ctx];
    }

    /// @inheritdoc IMembershipAuthority
    function groupMemberRoles(uint256 groupId) external view returns (uint256[] memory) {
        return Lib.layout().groupRoles[groupId];
    }

    /// @inheritdoc IMembershipAuthority
    function userSubjects(address user) external view returns (uint256[] memory) {
        return Lib.layout().userSubjectList[user];
    }

    /// @inheritdoc IMembershipAuthority
    function subjectCount() external view returns (uint256) {
        return Lib.layout().subjectCount;
    }

    /// @inheritdoc IMembershipAuthority
    function executor() external view returns (address) {
        return Lib.layout().executor;
    }

    /// @inheritdoc IMembershipAuthority
    function orgId() external view returns (bytes32) {
        return Lib.layout().orgId;
    }

    /// @inheritdoc IMembershipAuthority
    function paused() external view returns (bool) {
        return Lib.layout().paused;
    }

    /// @inheritdoc IMembershipAuthority
    function vouchConfig(uint256 subject) external view returns (uint32 quorum, uint256 voucherSubject, uint64 epoch) {
        Lib.Layout storage l = Lib.layout();
        Lib.VouchCfg storage cfg = l.vouchConfigs[subject];
        return (cfg.quorum, cfg.voucherSubject, l.vouchEpoch[subject]);
    }

    /// @inheritdoc IMembershipAuthority
    function vouchCount(uint256 subject, address user) external view returns (uint32) {
        Lib.Layout storage l = Lib.layout();
        return l.wearerVouchEpoch[subject][user] == l.vouchEpoch[subject] ? l.currentVouchCount[subject][user] : 0;
    }

    /// @inheritdoc IMembershipAuthority
    function maxDailyVouches() external view returns (uint32) {
        return Lib._maxDailyVouches(Lib.layout());
    }

    /*═══════════════════════════════ IHats read-subset + ERC-1155 views (§5) ═══════════════════════════════*/

    /// @inheritdoc IMembershipAuthority
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
        )
    {
        Lib.Layout storage l = Lib.layout();
        Lib.SubjectRec storage s = l.subjects[subjectId];
        details = s.name;
        maxSupply = s.maxMembers;
        supply = s.kind == AccessV2Types.SubjectKind.Group ? 0 : s.memberCount;
        eligibility = address(this);
        toggle = address(this);
        imageURI = s.imageURI;
        lastHatId = 0;
        mutable_ = true;
        active = !l.paused;
    }

    /// @inheritdoc IMembershipAuthority
    function getWearerStatus(address wearer, uint256 subjectId) external view returns (bool eligible_, bool standing) {
        Lib.Layout storage l = Lib.layout();
        bool e = l.subjects[subjectId].kind == AccessV2Types.SubjectKind.Group
            ? Lib._memberOfGroup(l, subjectId, wearer)
            : Lib._eligibleRole(l, subjectId, wearer);
        return (e, e);
    }

    /// @inheritdoc IMembershipAuthority
    function isWearerOfHat(address user, uint256 subjectId) external view returns (bool) {
        return Lib._isMember(Lib.layout(), subjectId, user);
    }

    /// @inheritdoc IMembershipAuthority
    function isEligible(address user, uint256 subjectId) external view returns (bool) {
        Lib.Layout storage l = Lib.layout();
        if (l.subjects[subjectId].kind == AccessV2Types.SubjectKind.Group) {
            return Lib._memberOfGroup(l, subjectId, user);
        }
        return Lib._eligibleRole(l, subjectId, user);
    }

    /// @inheritdoc IMembershipAuthority
    function balanceOf(address user, uint256 subjectId) external view returns (uint256) {
        return Lib._isMember(Lib.layout(), subjectId, user) ? 1 : 0;
    }

    /// @inheritdoc IMembershipAuthority
    function balanceOfBatch(address[] calldata users, uint256[] calldata subjectIds)
        external
        view
        returns (uint256[] memory out)
    {
        if (users.length != subjectIds.length) revert ArrayLengthMismatch();
        Lib.Layout storage l = Lib.layout();
        out = new uint256[](users.length);
        for (uint256 i; i < users.length;) {
            out[i] = Lib._isMember(l, subjectIds[i], users[i]) ? 1 : 0;
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IMembershipAuthority
    function checkHatWearerStatus(uint256, address) external pure returns (bool) {
        return true;
    }
}
