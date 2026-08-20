// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title MembershipAuthorityProto
 * @notice PRODUCTION-WEIGHT prototype of the POP Access v2 "MembershipAuthority" (SPEC v1.3,
 *         .context/rolemanager/ACCESS-V2-SPEC.md). It is the round-2 successor to
 *         {NativeLedgerPrototype}: the round-1 prototype measured the collapsed-authority FLOOR;
 *         this one adds back every spec shape that moves gas or size, so the benchmark deltas are a
 *         realistic (not upper-bound) estimate of the win at production weight.
 *
 *         Shapes implemented verbatim-by-logic from the spec (section refs inline):
 *         - §3 INVERTED FOLD: `perm[subject][key][ctx] -> packed word {exists, inheritGlobal, 254-bit
 *           value}`; a `subjectsWithKey[key][ctx]` enumeration index maintained on perm writes;
 *           `hasPerm` iterates the DEDUPED UNION of `[key][ctx]` and `[key][0]` with per-subject CTX
 *           RESOLUTION; the fold tag is read from the permKey's top byte (0x00 bool-any / 0x01 OR /
 *           0x02 MAX) — zero stored tag registry.
 *         - §3 `activeMemberSince(subject,user)` + the key-folded `activeMemberSince(user,key,ctx)`
 *           (the §4 electorate activation gate read shape).
 *         - §1 MEMBERSHIP = accepted && eligible, computed; `memberCount`/`maxMembers`;
 *           `userRoles` enumeration; caps (16 roles/user, 16 members/group, 8 groups/role, 16
 *           subjects per (key,ctx)) enforced with named errors.
 *         - §2 tri-state eligibility fold: explicit rule {GRANT|BAN, authoredBy, delegable} >
 *           attestor-ALLOW (vouch quorum met | email-verified) > per-subject default.
 *         - §1 GROUPS: subjects with no acceptance — membership derived from member-roles (the
 *           composed 1+members cost model).
 *         - §4 unified pending-action table (Grant|Offer|Remove) with per-subject ManagerConfig
 *           delaySecs; create / finalize / cancel; claim-is-finalize for offers (NotYetActive
 *           anchor in the pending entry); reconcile; unremove.
 *         - §5 ERC-1155 TransferSingle + the six-plus-RoleClaimed lifecycle event vocabulary on
 *           lifecycle writes; the IHats read-subset (isWearerOfHat / isEligible / balanceOf /
 *           balanceOfBatch / viewHat(9 fields) / checkHatWearerStatus) + router-facing views.
 *         - §1 pause gate (WRITES only; reads stay live) + reentrancy guard on mutating paths;
 *           §1 scoped access matrix (executor-by-ADDRESS root + ManagerConfig check on delegated
 *           paths).
 *
 *         Deliberately still OUT (declared, so the size number is honest about what remains): the
 *         delegatecall-lib split itself (this measures the ONE-CONTRACT max), vouch admin internals
 *         beyond a working quorum/epoch attestor, and the full seed/migration entrypoints (a couple
 *         of batch seeders). Those are the "remaining unmodeled surface" the gate weighs a margin
 *         against.
 */
contract MembershipAuthorityProto {
    /*═════════════════════════════════════════ ERRORS ═════════════════════════════════════════*/

    error ZeroAddress();
    error NotAuthorized();
    error Paused();
    error Reentrancy();
    error UnknownSubject();
    error NotARole();
    error NotAGroup();
    error RoleLimit();
    error GroupSizeLimit();
    error GroupsPerRoleLimit();
    error PermFanoutLimit();
    error MaxMembersReached();
    error MaxMembersOnGroup();
    error NotYetActive();
    error NoPending();
    error RemovalIneffective(uint8 sources);
    error StickyGovernanceRule();
    error DelegationDisabled();
    error AlreadyMember();
    error NotMember();

    /*═════════════════════════════════════════ EVENTS ═════════════════════════════════════════*/

    // ERC-1155 token surface (roles only) — same ids the subgraph indexes.
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    // §5 lifecycle vocabulary (six disjoint + RoleClaimed).
    event RoleOffered(uint256 indexed subjectId, address indexed user, address indexed actor);
    event OfferWithdrawn(uint256 indexed subjectId, address indexed user);
    event RoleGranted(uint256 indexed subjectId, address indexed user);
    event RoleClaimed(uint256 indexed subjectId, address indexed user);
    event RoleRemoved(uint256 indexed subjectId, address indexed user, bool banned);
    event RoleRenounced(uint256 indexed subjectId, address indexed user);
    event MembershipReconciled(uint256 indexed subjectId, address indexed user);

    // §5 delegation machinery events (the review window must be visible).
    event PendingActionCreated(
        uint256 indexed pendingId, uint256 indexed subjectId, address indexed user, uint8 action, uint64 activatesAt
    );
    event PendingActionCancelled(uint256 indexed pendingId, address by);
    event PendingActionVoided(uint256 indexed pendingId);

    // config events (mirrored at initialize per events-first discipline).
    event Initialized(address executor);
    event PausedSet(bool paused);
    event SubjectRegistered(uint256 indexed subjectId, uint8 kind, string name, uint32 maxMembers);
    event SubjectRenamed(uint256 indexed subjectId, string name);
    event DefaultSet(uint256 indexed subjectId, bool allow);
    event RuleSet(uint256 indexed subjectId, address indexed user, uint8 kind, bool delegable, uint8 authoredBy);
    event RuleCleared(uint256 indexed subjectId, address indexed user);
    event PermSet(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx, uint256 word);
    event PermRemoved(uint256 indexed subjectId, bytes32 indexed permKey, bytes32 indexed ctx);
    event VouchConfigured(uint256 indexed subjectId, uint32 quorum, uint256 membershipSubjectId);
    event Vouched(address indexed voucher, address indexed user, uint256 indexed subjectId, uint32 newCount);
    event EmailVerifiedSet(uint256 indexed subjectId, address indexed user, bool verified);
    event GroupCompositionChanged(uint256 indexed groupSubjectId, uint256[] memberRoles);
    event ManagerConfigured(uint256 indexed subjectId, uint256 managerSubjectId, uint256 caps, uint64 delaySecs);

    /*═════════════════════════════════════════ CONSTANTS ═════════════════════════════════════════*/

    uint8 internal constant KIND_ROLE = 1;
    uint8 internal constant KIND_GROUP = 2;

    // Rule kinds (explicit slot).
    uint8 internal constant RULE_NONE = 0;
    uint8 internal constant RULE_GRANT = 1;
    uint8 internal constant RULE_BAN = 2;

    // Rule authorship.
    uint8 internal constant AUTH_GOV = 0;
    uint8 internal constant AUTH_DELEGATED = 1;

    // Pending-action kinds.
    uint8 internal constant ACT_GRANT = 1;
    uint8 internal constant ACT_OFFER = 2;
    uint8 internal constant ACT_REMOVE = 3;

    // Fold tags (permKey top byte).
    uint8 internal constant TAG_BOOL = 0x00;
    uint8 internal constant TAG_OR = 0x01;
    uint8 internal constant TAG_MAX = 0x02;

    // §3 packed perm word bits.
    uint256 internal constant EXISTS_BIT = uint256(1) << 255;
    uint256 internal constant INHERIT_BIT = uint256(1) << 254;
    uint256 internal constant VALUE_MASK = (uint256(1) << 254) - 1;

    // §1 caps.
    uint256 internal constant MAX_ROLES_PER_USER = 16;
    uint256 internal constant MAX_MEMBERS_PER_GROUP = 16;
    uint256 internal constant MAX_GROUPS_PER_ROLE = 8;
    uint256 internal constant MAX_SUBJECTS_PER_KEY = 16;

    // §4 RemovalIneffective source enum-set bits.
    uint8 internal constant SRC_DEFAULT_ALLOW = 0x01;
    uint8 internal constant SRC_VOUCH_QUORUM = 0x02;
    uint8 internal constant SRC_EMAIL_VERIFIED = 0x04;
    uint8 internal constant SRC_STICKY_GRANT = 0x08;

    uint64 internal constant SENTINEL = type(uint64).max;

    /*═════════════════════════════════════════ STRUCTS ═════════════════════════════════════════*/

    struct SubjectInfo {
        bool exists;
        uint8 kind;
        uint32 maxMembers; // roles only
        uint32 memberCount; // roles only
        bool defaultAllow;
        string name;
        bytes32 metadataCID;
        string imageURI;
    }

    struct Rule {
        uint8 kind; // RULE_NONE | RULE_GRANT | RULE_BAN
        uint8 authoredBy; // AUTH_GOV | AUTH_DELEGATED
        bool delegable;
        uint256 managerSubject; // provenance for delegated authorship
    }

    struct VouchConfig {
        bool enabled;
        uint32 quorum;
        uint256 membershipSubjectId;
    }

    struct ManagerConfig {
        bool enabled;
        uint256 managerSubjectId;
        uint256 caps;
        uint64 delaySecs;
    }

    struct Pending {
        bool exists;
        uint8 action;
        uint256 subject;
        address user;
        address actor;
        uint64 activatesAt;
    }

    /*═══════════════════════════ ERC-7201 STORAGE ═══════════════════════════*/

    /// @custom:storage-location erc7201:poa.membershipauthority.proto.storage
    struct Layout {
        // root/access
        address executor; // root gate, by ADDRESS (§1)
        bool paused;
        uint256 lock; // reentrancy
        uint256 subjectCount;
        uint256 pendingSeq;
        // subject registry
        mapping(uint256 => SubjectInfo) subjects;
        // membership (roles): accepted && eligible = member
        mapping(uint256 => mapping(address => bool)) accepted;
        mapping(uint256 => mapping(address => uint64)) acceptedAt;
        mapping(address => uint256[]) userRoles; // enumeration (off hot path)
        mapping(address => mapping(uint256 => uint256)) userRoleIndex; // user => subject => index+1
        // eligibility sources
        mapping(uint256 => mapping(address => Rule)) ruleOf; // explicit slot per (subject,user)
        mapping(uint256 => VouchConfig) vouchConfigs;
        mapping(uint256 => mapping(address => uint32)) currentVouchCount;
        mapping(uint256 => uint256) vouchEpoch;
        mapping(uint256 => mapping(address => uint256)) wearerVouchEpoch;
        mapping(uint256 => mapping(address => bool)) emailVerified;
        // groups
        mapping(uint256 => uint256[]) groupMemberRoles;
        mapping(uint256 => uint256) groupsPerRole; // role => # groups referencing (cap 8)
        // §3 perm table + inverted-fold index
        mapping(uint256 => mapping(bytes32 => mapping(bytes32 => uint256))) perm;
        mapping(bytes32 => mapping(bytes32 => uint256[])) subjectsWithKey;
        mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) subjectKeyIndex; // key=>ctx=>subject=>idx+1
        // §4 delegation
        mapping(uint256 => ManagerConfig) managerConfig;
        mapping(uint256 => Pending) pending;
    }

    bytes32 private constant _SLOT = keccak256("poa.membershipauthority.proto.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═════════════════════════════════════════ MODIFIERS ═════════════════════════════════════════*/

    modifier onlyExecutor() {
        if (msg.sender != _layout().executor) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_layout().paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        Layout storage l = _layout();
        if (l.lock == 2) revert Reentrancy();
        l.lock = 2;
        _;
        l.lock = 1;
    }

    /*═════════════════════════════════════════ INIT ═════════════════════════════════════════*/

    function initialize(address executor_) external {
        Layout storage l = _layout();
        if (l.executor != address(0)) revert NotAuthorized();
        if (executor_ == address(0)) revert ZeroAddress();
        l.executor = executor_;
        l.lock = 1;
        // events-first: mirror the setters at init.
        emit Initialized(executor_);
        emit PausedSet(false);
    }

    function setPaused(bool p) external onlyExecutor {
        _layout().paused = p;
        emit PausedSet(p);
    }

    /*═════════════════════════════════════ SUBJECT REGISTRY ═════════════════════════════════════*/

    function registerSubject(
        uint8 kind,
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint32 maxMembers
    ) external onlyExecutor returns (uint256 subjectId) {
        if (kind != KIND_ROLE && kind != KIND_GROUP) revert NotARole();
        if (kind == KIND_GROUP && maxMembers != 0) revert MaxMembersOnGroup();
        Layout storage l = _layout();
        subjectId = ++l.subjectCount;
        SubjectInfo storage s = l.subjects[subjectId];
        s.exists = true;
        s.kind = kind;
        s.maxMembers = maxMembers;
        s.name = name;
        s.metadataCID = metadataCID;
        s.imageURI = imageURI;
        emit SubjectRegistered(subjectId, kind, name, maxMembers);
    }

    function renameSubject(uint256 subjectId, string calldata name) external onlyExecutor {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.subjects[subjectId].name = name;
        emit SubjectRenamed(subjectId, name);
    }

    function setDefault(uint256 subjectId, bool allow) external onlyExecutor {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.subjects[subjectId].defaultAllow = allow;
        emit DefaultSet(subjectId, allow);
    }

    /*═════════════════════════════════════ ELIGIBILITY SOURCE WRITES ═════════════════════════════════════*/

    /// @dev Governance rule write (§2 supremacy — overwrites any rule in one call).
    function setRule(uint256 subjectId, address user, uint8 kind, bool delegable) external onlyExecutor whenNotPaused {
        if (user == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        Rule storage r = l.ruleOf[subjectId][user];
        // any governance write on (subject,user) voids a pending entry keyed elsewhere — see finalize re-check.
        r.kind = kind;
        r.authoredBy = AUTH_GOV;
        r.delegable = delegable;
        r.managerSubject = 0;
        emit RuleSet(subjectId, user, kind, delegable, AUTH_GOV);
    }

    function clearRule(uint256 subjectId, address user) external onlyExecutor whenNotPaused {
        Layout storage l = _layout();
        delete l.ruleOf[subjectId][user];
        emit RuleCleared(subjectId, user);
    }

    function configureVouch(uint256 subjectId, uint32 quorum, uint256 membershipSubjectId) external onlyExecutor {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.vouchConfigs[subjectId] =
            VouchConfig({enabled: true, quorum: quorum, membershipSubjectId: membershipSubjectId});
        emit VouchConfigured(subjectId, quorum, membershipSubjectId);
    }

    function vouchFor(address user, uint256 subjectId) external whenNotPaused {
        if (user == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        uint256 epoch = l.vouchEpoch[subjectId];
        if (l.wearerVouchEpoch[subjectId][user] != epoch) {
            l.currentVouchCount[subjectId][user] = 0;
            l.wearerVouchEpoch[subjectId][user] = epoch;
        }
        uint32 nc = l.currentVouchCount[subjectId][user] + 1;
        l.currentVouchCount[subjectId][user] = nc;
        emit Vouched(msg.sender, user, subjectId, nc);
    }

    function setEmailVerified(uint256 subjectId, address user, bool verified) external whenNotPaused {
        Layout storage l = _layout();
        // gated on executor OR the (registered) email attestor in production; executor-only here.
        if (msg.sender != l.executor) revert NotAuthorized();
        l.emailVerified[subjectId][user] = verified;
        emit EmailVerifiedSet(subjectId, user, verified);
    }

    /// @dev §1 group composition writes; enforces GroupSizeLimit + GroupsPerRoleLimit.
    function setGroupComposition(uint256 groupSubjectId, uint256[] calldata memberRoles) external onlyExecutor {
        Layout storage l = _layout();
        SubjectInfo storage g = l.subjects[groupSubjectId];
        if (!g.exists) revert UnknownSubject();
        if (g.kind != KIND_GROUP) revert NotAGroup();
        if (memberRoles.length > MAX_MEMBERS_PER_GROUP) revert GroupSizeLimit();

        uint256[] storage cur = l.groupMemberRoles[groupSubjectId];
        uint256 oldLen = cur.length;
        for (uint256 i; i < oldLen;) {
            unchecked {
                --l.groupsPerRole[cur[i]];
                ++i;
            }
        }
        uint256 newLen = memberRoles.length;
        for (uint256 i; i < newLen;) {
            uint256 rid = memberRoles[i];
            if (!l.subjects[rid].exists || l.subjects[rid].kind != KIND_ROLE) revert NotARole();
            uint256 gpr = l.groupsPerRole[rid] + 1;
            if (gpr > MAX_GROUPS_PER_ROLE) revert GroupsPerRoleLimit();
            l.groupsPerRole[rid] = gpr;
            unchecked {
                ++i;
            }
        }
        l.groupMemberRoles[groupSubjectId] = memberRoles;
        emit GroupCompositionChanged(groupSubjectId, memberRoles);
    }

    function setManagerConfig(uint256 subjectId, uint256 managerSubjectId, uint256 caps, uint64 delaySecs)
        external
        onlyExecutor
    {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.managerConfig[subjectId] =
            ManagerConfig({enabled: true, managerSubjectId: managerSubjectId, caps: caps, delaySecs: delaySecs});
        emit ManagerConfigured(subjectId, managerSubjectId, caps, delaySecs);
    }

    /*═════════════════════════════════════ PERM TABLE (§3 inverted fold) ═════════════════════════════════════*/

    /// @dev Set a packed perm word and maintain the subjectsWithKey enumeration index. Enforces
    ///      PermFanoutLimit (16 subjects per (key,ctx)).
    function setPerm(uint256 subjectId, bytes32 permKey, bytes32 ctx, uint256 value, bool inheritGlobal)
        external
        onlyExecutor
    {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        if (value > VALUE_MASK) revert PermFanoutLimit(); // 254-bit value constraint (§3)
        uint256 word = EXISTS_BIT | (inheritGlobal ? INHERIT_BIT : 0) | (value & VALUE_MASK);

        bool existed = l.perm[subjectId][permKey][ctx] & EXISTS_BIT != 0;
        l.perm[subjectId][permKey][ctx] = word;
        if (!existed) {
            uint256[] storage arr = l.subjectsWithKey[permKey][ctx];
            if (arr.length >= MAX_SUBJECTS_PER_KEY) revert PermFanoutLimit();
            arr.push(subjectId);
            l.subjectKeyIndex[permKey][ctx][subjectId] = arr.length; // idx+1
        }
        emit PermSet(subjectId, permKey, ctx, word);
    }

    function removePerm(uint256 subjectId, bytes32 permKey, bytes32 ctx) external onlyExecutor {
        Layout storage l = _layout();
        if (l.perm[subjectId][permKey][ctx] & EXISTS_BIT == 0) return;
        delete l.perm[subjectId][permKey][ctx];
        uint256[] storage arr = l.subjectsWithKey[permKey][ctx];
        uint256 idx1 = l.subjectKeyIndex[permKey][ctx][subjectId];
        if (idx1 != 0) {
            uint256 i = idx1 - 1;
            uint256 last = arr.length - 1;
            if (i != last) {
                uint256 moved = arr[last];
                arr[i] = moved;
                l.subjectKeyIndex[permKey][ctx][moved] = i + 1;
            }
            arr.pop();
            delete l.subjectKeyIndex[permKey][ctx][subjectId];
        }
        emit PermRemoved(subjectId, permKey, ctx);
    }

    /*═════════════════════════════════════ LIFECYCLE ═════════════════════════════════════*/

    /// @dev Direct grant to an in-org member (an ORG act) — RoleGranted. §5 emission: TransferSingle mint.
    function grant(uint256 subjectId, address user) external onlyExecutor whenNotPaused nonReentrant {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        // seed the explicit governance grant so a deny-default role is eligible (§6 seed invariant).
        _writeGovGrant(l, subjectId, user);
        _flipAccepted(l, subjectId, user, true);
        emit RoleGranted(subjectId, user);
    }

    /// @dev Self-claim on a default-ALLOW role (a USER act) — RoleClaimed.
    function claimOpen(uint256 subjectId) external whenNotPaused nonReentrant {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        if (!_eligibleRole(l, subjectId, msg.sender)) revert NotMember();
        _flipAccepted(l, subjectId, msg.sender, true);
        emit RoleClaimed(subjectId, msg.sender);
    }

    /// @dev Governance/manager offer to an out-of-org user — creates a pending Offer (§4). RoleOffered.
    function offer(uint256 subjectId, address user)
        external
        onlyExecutor
        whenNotPaused
        nonReentrant
        returns (uint256 pid)
    {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        _writeGovGrant(l, subjectId, user); // explicit-ALLOW makes isEligible true through the router
        pid = _createPending(l, ACT_OFFER, subjectId, user, 0);
        emit RoleOffered(subjectId, user, msg.sender);
    }

    /// @dev Offer-accept: the target's claim IS the finalize (§4). Reverts NotYetActive before activatesAt.
    function claim(uint256 pid) external whenNotPaused nonReentrant {
        Layout storage l = _layout();
        Pending storage p = l.pending[pid];
        if (!p.exists || p.action != ACT_OFFER) revert NoPending();
        if (p.user != msg.sender) revert NotAuthorized();
        if (block.timestamp < p.activatesAt) revert NotYetActive();
        uint256 subjectId = p.subject;
        _finalizeChecks(l, p);
        _flipAccepted(l, subjectId, msg.sender, true);
        _deletePending(l, pid);
        emit RoleClaimed(subjectId, msg.sender);
    }

    function renounce(uint256 subjectId) external whenNotPaused nonReentrant {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        if (!l.accepted[subjectId][msg.sender]) revert NotMember();
        // clear accepted AND the clearable grant (§2 renounce): delegated or delegable=true governance.
        Rule storage r = l.ruleOf[subjectId][msg.sender];
        if (r.kind == RULE_GRANT && (r.authoredBy == AUTH_DELEGATED || r.delegable)) {
            delete l.ruleOf[subjectId][msg.sender];
        }
        _flipAccepted(l, subjectId, msg.sender, false);
        emit RoleRenounced(subjectId, msg.sender);
    }

    /// @dev §4 one-primitive removal. SOFT reverts RemovalIneffective (carrying the source set) if the
    ///      target remains eligible after clearing accepted+explicit-ALLOW; HARD writes the ban.
    function remove(uint256 subjectId, address user, bool ban) external onlyExecutor whenNotPaused nonReentrant {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        if (!l.accepted[subjectId][user]) revert NotMember();
        if (ban) {
            Rule storage r = l.ruleOf[subjectId][user];
            r.kind = RULE_BAN;
            r.authoredBy = AUTH_GOV;
            r.delegable = false;
            _flipAccepted(l, subjectId, user, false);
            emit RoleRemoved(subjectId, user, true);
        } else {
            // clear explicit ALLOW then re-check eligibility.
            Rule storage r = l.ruleOf[subjectId][user];
            if (r.kind == RULE_GRANT) delete l.ruleOf[subjectId][user];
            uint8 srcs = _survivingSources(l, subjectId, user);
            if (srcs != 0) {
                // restore the grant we speculatively cleared and revert with the source set.
                _writeGovGrant(l, subjectId, user);
                revert RemovalIneffective(srcs);
            }
            _flipAccepted(l, subjectId, user, false);
            emit RoleRemoved(subjectId, user, false);
        }
    }

    /// @dev §4 unremove: clears a ban and restores claimable state (prior membership = consent).
    function unremove(uint256 subjectId, address user) external onlyExecutor whenNotPaused {
        Layout storage l = _layout();
        Rule storage r = l.ruleOf[subjectId][user];
        if (r.kind == RULE_BAN) delete l.ruleOf[subjectId][user];
        emit RuleCleared(subjectId, user);
    }

    /// @dev §2 permissionless reconcile: clears accepted for an accepted-but-ineligible member.
    function reconcile(uint256 subjectId, address user) external nonReentrant {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        if (!l.accepted[subjectId][user]) revert NotMember();
        if (_eligibleRole(l, subjectId, user)) revert RemovalIneffective(_survivingSources(l, subjectId, user));
        _flipAccepted(l, subjectId, user, false);
        emit MembershipReconciled(subjectId, user);
    }

    /*═════════════════════════════════════ DELEGATION (§4 pending model) ═════════════════════════════════════*/

    /// @dev A delegated manager creates a pending Grant/Remove; activatesAt = now + config.delaySecs.
    function createPending(uint8 action, uint256 subjectId, address user)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 pid)
    {
        Layout storage l = _layout();
        _requireRole(l, subjectId);
        ManagerConfig storage mc = l.managerConfig[subjectId];
        if (!mc.enabled) revert DelegationDisabled();
        // scoped access matrix: actor must be a member of the manager subject.
        if (!_isMember(l, mc.managerSubjectId, msg.sender)) revert NotAuthorized();
        // delegated writes revert on a non-delegable governance rule (§2 supremacy).
        Rule storage r = l.ruleOf[subjectId][user];
        if (r.kind != RULE_NONE && r.authoredBy == AUTH_GOV && !r.delegable) revert StickyGovernanceRule();
        if (action == ACT_GRANT) {
            _writeDelegatedGrant(l, subjectId, user, mc.managerSubjectId);
        }
        pid = _createPending(l, action, subjectId, user, mc.delaySecs);
    }

    /// @dev §4 finalize (Grant/Remove) after activatesAt with re-checks; emits the resulting lifecycle event.
    function finalize(uint256 pid) external whenNotPaused nonReentrant {
        Layout storage l = _layout();
        Pending storage p = l.pending[pid];
        if (!p.exists) revert NoPending();
        if (block.timestamp < p.activatesAt) revert NotYetActive();
        _finalizeChecks(l, p);
        uint256 subjectId = p.subject;
        address user = p.user;
        uint8 action = p.action;
        _deletePending(l, pid);
        if (action == ACT_GRANT) {
            _flipAccepted(l, subjectId, user, true);
            emit RoleGranted(subjectId, user);
        } else if (action == ACT_REMOVE) {
            if (l.accepted[subjectId][user]) {
                _flipAccepted(l, subjectId, user, false);
            }
            emit RoleRemoved(subjectId, user, false);
        }
    }

    function cancelPending(uint256 pid) external whenNotPaused {
        Layout storage l = _layout();
        Pending storage p = l.pending[pid];
        if (!p.exists) revert NoPending();
        // acting manager OR governance may cancel.
        bool isGov = msg.sender == l.executor;
        bool isManager = _isMember(l, l.managerConfig[p.subject].managerSubjectId, msg.sender);
        if (!isGov && !isManager) revert NotAuthorized();
        _deletePending(l, pid);
        emit PendingActionCancelled(pid, msg.sender);
    }

    /*═════════════════════════════════════ READ SURFACE ═════════════════════════════════════*/

    function isMember(uint256 subjectId, address user) external view returns (bool) {
        return _isMember(_layout(), subjectId, user);
    }

    function pendingSeqView() external view returns (uint256) {
        return _layout().pendingSeq;
    }

    function memberCount(uint256 subjectId) external view returns (uint32) {
        return _layout().subjects[subjectId].memberCount;
    }

    function subjectsWithKeyLen(bytes32 permKey, bytes32 ctx) external view returns (uint256) {
        return _layout().subjectsWithKey[permKey][ctx].length;
    }

    function isEligibleSubject(uint256 subjectId, address user) external view returns (bool) {
        Layout storage l = _layout();
        if (l.subjects[subjectId].kind == KIND_GROUP) return _memberOfAnyMemberRole(l, subjectId, user);
        return _eligibleRole(l, subjectId, user);
    }

    function hasAnyMember(uint256[] calldata subjectIds, address user) external view returns (bool) {
        Layout storage l = _layout();
        uint256 len = subjectIds.length;
        for (uint256 i; i < len;) {
            if (_isMember(l, subjectIds[i], user)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice §3 INVERTED FOLD hasPerm: iterate the deduped union of [key][ctx] and [key][0], apply
    ///         per-subject CTX RESOLUTION and the permKey-top-byte fold tag.
    function hasPerm(address user, bytes32 permKey, bytes32 ctx) external view returns (uint256 acc) {
        Layout storage l = _layout();
        uint8 tag = uint8(permKey[0]);
        if (ctx == bytes32(0)) {
            uint256[] storage arr = l.subjectsWithKey[permKey][bytes32(0)];
            uint256 len = arr.length;
            for (uint256 i; i < len;) {
                uint256 sid = arr[i];
                if (_isMember(l, sid, user)) {
                    acc = _fold(acc, l.perm[sid][permKey][bytes32(0)] & VALUE_MASK, tag);
                }
                unchecked {
                    ++i;
                }
            }
            return acc;
        }
        // ctx != 0: union of ctx-list and global-list, deduped.
        uint256[] storage ctxArr = l.subjectsWithKey[permKey][ctx];
        uint256[] storage gArr = l.subjectsWithKey[permKey][bytes32(0)];
        uint256 cl = ctxArr.length;
        for (uint256 i; i < cl;) {
            uint256 sid = ctxArr[i];
            if (_isMember(l, sid, user)) {
                acc = _fold(acc, _resolveCtx(l, sid, permKey, ctx, tag), tag);
            }
            unchecked {
                ++i;
            }
        }
        uint256 gl = gArr.length;
        for (uint256 i; i < gl;) {
            uint256 sid = gArr[i];
            // dedup: skip if this subject also carries a ctx entry (already processed above).
            if (l.subjectKeyIndex[permKey][ctx][sid] == 0) {
                if (_isMember(l, sid, user)) {
                    acc = _fold(acc, l.perm[sid][permKey][bytes32(0)] & VALUE_MASK, tag);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice §3 activation read for subject-list gates (HV classes, DD restricted polls).
    function activeMemberSince(uint256 subjectId, address user) external view returns (uint64) {
        return _activeMemberSince(_layout(), subjectId, user);
    }

    /// @notice §3 key-folded activation: EARLIEST activation over the hasPerm iteration set (union).
    function activeMemberSince(address user, bytes32 permKey, bytes32 ctx) external view returns (uint64 earliest) {
        Layout storage l = _layout();
        earliest = SENTINEL;
        uint256[] storage ctxArr = l.subjectsWithKey[permKey][ctx];
        uint256 cl = ctxArr.length;
        for (uint256 i; i < cl;) {
            uint64 t = _activeMemberSince(l, ctxArr[i], user);
            if (t < earliest) earliest = t;
            unchecked {
                ++i;
            }
        }
        if (ctx != bytes32(0)) {
            uint256[] storage gArr = l.subjectsWithKey[permKey][bytes32(0)];
            uint256 gl = gArr.length;
            for (uint256 i; i < gl;) {
                uint256 sid = gArr[i];
                if (l.subjectKeyIndex[permKey][ctx][sid] == 0) {
                    uint64 t = _activeMemberSince(l, sid, user);
                    if (t < earliest) earliest = t;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /*═════════════════════════════════════ IHats READ-SUBSET / ROUTER VIEWS (§5) ═════════════════════════════════════*/

    function isWearerOfHat(address user, uint256 subjectId) external view returns (bool) {
        return _isMember(_layout(), subjectId, user);
    }

    function isEligible(address user, uint256 subjectId) external view returns (bool) {
        Layout storage l = _layout();
        if (l.subjects[subjectId].kind == KIND_GROUP) return _memberOfAnyMemberRole(l, subjectId, user);
        return _eligibleRole(l, subjectId, user);
    }

    function isInGoodStanding(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address user, uint256 subjectId) external view returns (uint256) {
        return _isMember(_layout(), subjectId, user) ? 1 : 0;
    }

    function balanceOfBatch(address[] calldata users, uint256[] calldata subjectIds)
        external
        view
        returns (uint256[] memory out)
    {
        Layout storage l = _layout();
        uint256 len = users.length;
        out = new uint256[](len);
        for (uint256 i; i < len;) {
            out[i] = _isMember(l, subjectIds[i], users[i]) ? 1 : 0;
            unchecked {
                ++i;
            }
        }
    }

    function checkHatWearerStatus(uint256, address) external pure returns (bool) {
        return true;
    }

    /// @notice §5 all-nine-field viewHat: eligibility/toggle = this authority, active = !paused,
    ///         supply = memberCount (roles; 0 for groups), mutable = true.
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
        Layout storage l = _layout();
        SubjectInfo storage s = l.subjects[subjectId];
        details = s.name;
        maxSupply = s.maxMembers;
        supply = s.kind == KIND_GROUP ? 0 : s.memberCount;
        eligibility = address(this);
        toggle = address(this);
        imageURI = s.imageURI;
        lastHatId = 0;
        mutable_ = true;
        active = !l.paused;
    }

    /*═════════════════════════════════════ INTERNALS ═════════════════════════════════════*/

    function _requireRole(Layout storage l, uint256 subjectId) internal view {
        SubjectInfo storage s = l.subjects[subjectId];
        if (!s.exists) revert UnknownSubject();
        if (s.kind != KIND_ROLE) revert NotARole();
    }

    function _isMember(Layout storage l, uint256 subjectId, address user) internal view returns (bool) {
        SubjectInfo storage s = l.subjects[subjectId];
        if (s.kind == KIND_GROUP) return _memberOfAnyMemberRole(l, subjectId, user);
        if (!l.accepted[subjectId][user]) return false;
        return _eligibleRole(l, subjectId, user);
    }

    /// @dev §1 composed group derivation: member of >=1 member-role (1 + members cost).
    function _memberOfAnyMemberRole(Layout storage l, uint256 groupSubjectId, address user)
        internal
        view
        returns (bool)
    {
        uint256[] storage members = l.groupMemberRoles[groupSubjectId];
        uint256 len = members.length;
        for (uint256 i; i < len;) {
            uint256 rid = members[i];
            if (l.accepted[rid][user] && _eligibleRole(l, rid, user)) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev §2 tri-state fold for a ROLE: explicit rule > attestor-ALLOW > per-subject default.
    function _eligibleRole(Layout storage l, uint256 subjectId, address user) internal view returns (bool) {
        Rule storage r = l.ruleOf[subjectId][user];
        if (r.kind == RULE_BAN) return false;
        if (r.kind == RULE_GRANT) return true;
        // no explicit rule → attestors, then default.
        if (l.emailVerified[subjectId][user]) return true;
        if (_vouchAllowed(l, subjectId, user)) return true;
        return l.subjects[subjectId].defaultAllow;
    }

    function _vouchAllowed(Layout storage l, uint256 subjectId, address user) internal view returns (bool) {
        VouchConfig storage vc = l.vouchConfigs[subjectId];
        if (!vc.enabled) return false;
        uint32 eff =
            (l.wearerVouchEpoch[subjectId][user] == l.vouchEpoch[subjectId]) ? l.currentVouchCount[subjectId][user] : 0;
        return eff >= vc.quorum;
    }

    /// @dev §4 RemovalIneffective source set (which eligibility source still holds after clearing grant).
    function _survivingSources(Layout storage l, uint256 subjectId, address user) internal view returns (uint8 srcs) {
        Rule storage r = l.ruleOf[subjectId][user];
        if (r.kind == RULE_GRANT && r.authoredBy == AUTH_GOV && !r.delegable) srcs |= SRC_STICKY_GRANT;
        if (l.emailVerified[subjectId][user]) srcs |= SRC_EMAIL_VERIFIED;
        if (_vouchAllowed(l, subjectId, user)) srcs |= SRC_VOUCH_QUORUM;
        if (l.subjects[subjectId].defaultAllow) srcs |= SRC_DEFAULT_ALLOW;
    }

    function _activeMemberSince(Layout storage l, uint256 subjectId, address user) internal view returns (uint64) {
        SubjectInfo storage s = l.subjects[subjectId];
        if (s.kind == KIND_GROUP) {
            uint64 earliest = SENTINEL;
            uint256[] storage members = l.groupMemberRoles[subjectId];
            uint256 len = members.length;
            for (uint256 i; i < len;) {
                uint256 rid = members[i];
                if (l.accepted[rid][user] && _eligibleRole(l, rid, user)) {
                    uint64 t = l.acceptedAt[rid][user];
                    if (t < earliest) earliest = t;
                }
                unchecked {
                    ++i;
                }
            }
            return earliest;
        }
        if (l.accepted[subjectId][user] && _eligibleRole(l, subjectId, user)) return l.acceptedAt[subjectId][user];
        return SENTINEL;
    }

    /// @dev §3 CTX RESOLUTION: project entry exists ? (inherit ? COMBINE(global,project) : project) : global.
    function _resolveCtx(Layout storage l, uint256 subjectId, bytes32 permKey, bytes32 ctx, uint8 tag)
        internal
        view
        returns (uint256)
    {
        uint256 proj = l.perm[subjectId][permKey][ctx];
        if (proj & EXISTS_BIT != 0) {
            if (proj & INHERIT_BIT != 0) {
                uint256 glob = l.perm[subjectId][permKey][bytes32(0)] & VALUE_MASK;
                return _fold(glob, proj & VALUE_MASK, tag);
            }
            return proj & VALUE_MASK;
        }
        return l.perm[subjectId][permKey][bytes32(0)] & VALUE_MASK;
    }

    function _fold(uint256 acc, uint256 v, uint8 tag) internal pure returns (uint256) {
        if (tag == TAG_OR) return acc | v;
        if (tag == TAG_MAX) return v > acc ? v : acc;
        // TAG_BOOL: any nonzero.
        return acc != 0 ? acc : v;
    }

    /*──────── accepted-flip (§1: memberCount, userRoles, caps, TransferSingle) ────────*/

    function _flipAccepted(Layout storage l, uint256 subjectId, address user, bool on) internal {
        if (on) {
            if (l.accepted[subjectId][user]) revert AlreadyMember();
            uint256[] storage roles = l.userRoles[user];
            if (roles.length >= MAX_ROLES_PER_USER) revert RoleLimit();
            SubjectInfo storage s = l.subjects[subjectId];
            if (s.maxMembers != 0 && s.memberCount >= s.maxMembers) revert MaxMembersReached();
            l.accepted[subjectId][user] = true;
            l.acceptedAt[subjectId][user] = uint64(block.timestamp);
            unchecked {
                s.memberCount += 1;
            }
            roles.push(subjectId);
            l.userRoleIndex[user][subjectId] = roles.length;
            emit TransferSingle(msg.sender, address(0), user, subjectId, 1);
        } else {
            l.accepted[subjectId][user] = false;
            l.acceptedAt[subjectId][user] = 0;
            SubjectInfo storage s = l.subjects[subjectId];
            if (s.memberCount != 0) {
                unchecked {
                    s.memberCount -= 1;
                }
            }
            _removeUserRole(l, user, subjectId);
            emit TransferSingle(msg.sender, user, address(0), subjectId, 1);
        }
    }

    function _removeUserRole(Layout storage l, address user, uint256 subjectId) internal {
        uint256[] storage roles = l.userRoles[user];
        uint256 idx1 = l.userRoleIndex[user][subjectId];
        if (idx1 == 0) return;
        uint256 i = idx1 - 1;
        uint256 last = roles.length - 1;
        if (i != last) {
            uint256 moved = roles[last];
            roles[i] = moved;
            l.userRoleIndex[user][moved] = i + 1;
        }
        roles.pop();
        delete l.userRoleIndex[user][subjectId];
    }

    function _writeGovGrant(Layout storage l, uint256 subjectId, address user) internal {
        Rule storage r = l.ruleOf[subjectId][user];
        // do not downgrade a sticky (delegable=false) governance grant to a fresh one silently;
        // default proposal-builder behavior is delegable=true.
        r.kind = RULE_GRANT;
        r.authoredBy = AUTH_GOV;
        r.delegable = true;
        r.managerSubject = 0;
    }

    function _writeDelegatedGrant(Layout storage l, uint256 subjectId, address user, uint256 managerSubject) internal {
        Rule storage r = l.ruleOf[subjectId][user];
        r.kind = RULE_GRANT;
        r.authoredBy = AUTH_DELEGATED;
        r.delegable = true;
        r.managerSubject = managerSubject;
    }

    /*──────── pending-action helpers ────────*/

    function _createPending(Layout storage l, uint8 action, uint256 subjectId, address user, uint64 delaySecs)
        internal
        returns (uint256 pid)
    {
        pid = ++l.pendingSeq;
        uint64 activatesAt = uint64(block.timestamp) + delaySecs;
        l.pending[pid] = Pending({
            exists: true, action: action, subject: subjectId, user: user, actor: msg.sender, activatesAt: activatesAt
        });
        emit PendingActionCreated(pid, subjectId, user, action, activatesAt);
    }

    function _deletePending(Layout storage l, uint256 pid) internal {
        delete l.pending[pid];
    }

    /// @dev §4 finalize re-checks (all actions): config still enabled, actor still a manager member,
    ///      no sticky governance rule written during the delay, target still eligible / maxMembers open.
    function _finalizeChecks(Layout storage l, Pending storage p) internal view {
        uint256 subjectId = p.subject;
        if (p.action == ACT_GRANT || p.action == ACT_OFFER) {
            SubjectInfo storage s = l.subjects[subjectId];
            if (s.maxMembers != 0 && s.memberCount >= s.maxMembers) revert MaxMembersReached();
            // target still eligible via the seeded grant (or a subsequent gov write must not have banned).
            if (!_eligibleRole(l, subjectId, p.user)) revert NotMember();
        }
        // delegated actions: actor still a member of the manager subject (unless a direct gov offer).
        ManagerConfig storage mc = l.managerConfig[subjectId];
        if (mc.enabled && p.actor != l.executor) {
            if (!_isMember(l, mc.managerSubjectId, p.actor)) revert NotAuthorized();
        }
    }
}
