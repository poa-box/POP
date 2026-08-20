// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title NativeLedgerPrototype
 * @notice A faithful, minimal "unified authority" for the remove-Hats blank-slate decision
 *         (.context/rolemanager/blank-slate-review.md). It collapses the current
 *         module -> Hats -> EligibilityModule -> EligibilityLogic(delegatecall) chain into a
 *         single contract that a module calls once. It is an honest apples-to-apples target:
 *
 *         - Membership = accepted(bit) && eligible(policy). `accepted` is the mint-at-grant consent
 *           bit (the analog of *actually wearing* a Hats marker: derived eligibility alone grants
 *           nothing — the exact C-1 invariant the current design enforces via mint-at-grant).
 *         - The SAME five-path eligibility resolution as {EligibilityLogic._getWearerStatus}, ported
 *           by logic shape not stubbed to constants: explicit-ban supremacy, hierarchy/default flags
 *           with provenance, vouch-with-epochs (+combine mode), email, derived groups (one flat level).
 *         - A role/group subject registry, a permTable[subjectId][permKey] -> uint256 mask, and an
 *           isMember / hasPerm external read surface a module calls.
 *         - ERC-7201-style namespaced storage, and events on every write (subgraph parity).
 *
 *         What it deliberately OMITS versus a production build (see the benchmark caveats): the
 *         delegatecall library hop (EIP-170 offload), pause / reentrancy guards, the ERC-1155
 *         token surface Hats carries (balanceOf/supply/admin-tree), and full access-control
 *         modifiers. Those add gas back; this measures the floor of the collapsed-authority path.
 */
contract NativeLedgerPrototype {
    /*═════════════════════════════════════════ ERRORS ═════════════════════════════════════════*/

    error ZeroAddress();
    error DerivedConflictsWithVouch();
    error NestedDerivedSubject();
    error UnknownSubject();
    error NotAuthorized();

    /*═════════════════════════════════════════ EVENTS ═════════════════════════════════════════*/

    event SubjectRegistered(uint256 indexed subjectId, uint8 kind, string name);
    event DefaultEligibilitySet(uint256 indexed subjectId, bool eligible, bool standing);
    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed subjectId, bool eligible, bool standing, address indexed admin
    );
    event VouchConfigured(uint256 indexed subjectId, uint32 quorum, uint256 membershipSubjectId, bool combine);
    event Vouched(address indexed voucher, address indexed wearer, uint256 indexed subjectId, uint32 newCount);
    event EmailVerifiedSet(uint256 indexed subjectId, address indexed wearer, bool verified);
    event GroupEligibilitySet(uint256 indexed groupSubjectId, uint256[] memberSubjects);
    event PermSet(uint256 indexed subjectId, bytes32 indexed permKey, uint256 mask);
    event RoleGranted(uint256 indexed subjectId, address indexed user, bool provenanceDelegated);
    event RoleRevoked(uint256 indexed subjectId, address indexed user);

    /*═════════════════════════════════════════ STRUCTS ═════════════════════════════════════════*/

    struct WearerRules {
        uint8 flags;
    }

    struct VouchConfig {
        uint32 quorum;
        uint256 membershipSubjectId;
        uint8 flags;
    }

    struct SubjectInfo {
        bool exists;
        uint8 kind; // 1 = role, 2 = group
        string name;
    }

    /*═══════════════════════════ ERC-7201 STORAGE (mirror of EligibilityModule shape) ═══════════════════════════*/

    /// @custom:storage-location erc7201:poa.nativeledger.storage
    struct Layout {
        address authorityAdmin; // superAdmin analog
        address roleManager; // provenance-source analog
        uint256 subjectCount;
        mapping(uint256 => SubjectInfo) subjects;
        // membership consent bit (mint-at-grant analog of "actually wearing")
        mapping(uint256 => mapping(address => bool)) accepted;
        // five-path eligibility state (ported from EligibilityLogic.Layout)
        mapping(address => mapping(uint256 => WearerRules)) wearerRules;
        mapping(address => mapping(uint256 => bool)) hasSpecificWearerRules;
        mapping(uint256 => WearerRules) defaultRules;
        mapping(uint256 => VouchConfig) vouchConfigs;
        mapping(uint256 => mapping(address => uint32)) currentVouchCount;
        mapping(uint256 => uint256) vouchConfigEpoch;
        mapping(uint256 => mapping(address => uint256)) wearerVouchEpoch;
        mapping(uint256 => mapping(address => bool)) emailVerified;
        mapping(uint256 => uint256[]) groupMemberSubjects;
        mapping(uint256 => uint256) groupMembershipRefCount;
        // unified permission table (replaces the per-module hat-id lists + rolePermGlobal masks)
        mapping(uint256 => mapping(bytes32 => uint256)) permTable;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.nativeledger.storage");

    uint8 private constant ENABLED_FLAG = 0x01;
    uint8 private constant DELEGATION_MANAGED = 0x04;

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═════════════════════════════════════════ INIT ═════════════════════════════════════════*/

    function initialize(address authorityAdmin_, address roleManager_) external {
        Layout storage l = _layout();
        if (l.authorityAdmin != address(0)) revert NotAuthorized();
        if (authorityAdmin_ == address(0)) revert ZeroAddress();
        l.authorityAdmin = authorityAdmin_;
        l.roleManager = roleManager_;
    }

    modifier onlyAdminOrRM() {
        Layout storage l = _layout();
        if (msg.sender != l.authorityAdmin && msg.sender != l.roleManager) revert NotAuthorized();
        _;
    }

    /*═════════════════════════════════════ SUBJECT REGISTRY ═════════════════════════════════════*/

    function registerSubject(uint8 kind, string calldata name) external onlyAdminOrRM returns (uint256 subjectId) {
        Layout storage l = _layout();
        subjectId = ++l.subjectCount;
        l.subjects[subjectId] = SubjectInfo({exists: true, kind: kind, name: name});
        emit SubjectRegistered(subjectId, kind, name);
    }

    function setDefaultEligibility(uint256 subjectId, bool eligible, bool standing) external onlyAdminOrRM {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.defaultRules[subjectId] = WearerRules(_packWearerFlags(eligible, standing));
        emit DefaultEligibilitySet(subjectId, eligible, standing);
    }

    /*═════════════════════════════════════ ELIGIBILITY WRITES ═════════════════════════════════════*/

    /// @dev Explicit per-wearer rule write (governance path). Mirrors EM.setWearerEligibility.
    function setWearerEligibility(address wearer, uint256 subjectId, bool eligible, bool standing)
        external
        onlyAdminOrRM
    {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        uint8 flags = _packWearerFlags(eligible, standing);
        // RoleManager-mediated writes carry the DELEGATION_MANAGED provenance bit (mirror of FIX 1).
        if (msg.sender == l.roleManager) flags |= DELEGATION_MANAGED;
        l.wearerRules[wearer][subjectId] = WearerRules(flags);
        l.hasSpecificWearerRules[wearer][subjectId] = true;
        emit WearerEligibilityUpdated(wearer, subjectId, eligible, standing, msg.sender);
    }

    function clearWearerEligibility(address wearer, uint256 subjectId) external onlyAdminOrRM {
        Layout storage l = _layout();
        delete l.wearerRules[wearer][subjectId];
        delete l.hasSpecificWearerRules[wearer][subjectId];
        emit WearerEligibilityUpdated(wearer, subjectId, false, false, msg.sender);
    }

    function configureVouch(uint256 subjectId, uint32 quorum, uint256 membershipSubjectId, bool combine)
        external
        onlyAdminOrRM
    {
        Layout storage l = _layout();
        if (l.groupMemberSubjects[subjectId].length > 0) revert DerivedConflictsWithVouch();
        uint8 flags = ENABLED_FLAG | (combine ? 0x02 : 0);
        l.vouchConfigs[subjectId] =
            VouchConfig({quorum: quorum, membershipSubjectId: membershipSubjectId, flags: flags});
        emit VouchConfigured(subjectId, quorum, membershipSubjectId, combine);
    }

    /// @dev Minimal vouch record with the SAME epoch-staleness shape as EligibilityLogic.vouchFor.
    function vouchFor(address wearer, uint256 subjectId) external {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        uint256 currentEpoch = l.vouchConfigEpoch[subjectId];
        if (l.wearerVouchEpoch[subjectId][wearer] != currentEpoch) {
            l.currentVouchCount[subjectId][wearer] = 0;
            l.wearerVouchEpoch[subjectId][wearer] = currentEpoch;
        }
        uint32 newCount = l.currentVouchCount[subjectId][wearer] + 1;
        l.currentVouchCount[subjectId][wearer] = newCount;
        emit Vouched(msg.sender, wearer, subjectId, newCount);
    }

    function setEmailVerified(uint256 subjectId, address wearer, bool verified) external onlyAdminOrRM {
        Layout storage l = _layout();
        l.emailVerified[subjectId][wearer] = verified;
        emit EmailVerifiedSet(subjectId, wearer, verified);
    }

    /// @dev Derived (group) config with the same bidirectional vouch guard + flat one-level nesting
    ///      guard as EligibilityLogic.setGroupEligibility.
    function setGroupEligibility(uint256 groupSubjectId, uint256[] calldata memberSubjects) external onlyAdminOrRM {
        Layout storage l = _layout();
        if (_isVouchingEnabled(l.vouchConfigs[groupSubjectId].flags)) revert DerivedConflictsWithVouch();
        if (l.groupMembershipRefCount[groupSubjectId] > 0) revert NestedDerivedSubject();

        uint256 newLen = memberSubjects.length;
        for (uint256 i; i < newLen;) {
            uint256 m = memberSubjects[i];
            if (m == groupSubjectId) revert NestedDerivedSubject();
            if (l.groupMemberSubjects[m].length > 0) revert NestedDerivedSubject();
            unchecked {
                ++i;
            }
        }

        uint256[] storage current = l.groupMemberSubjects[groupSubjectId];
        uint256 oldLen = current.length;
        for (uint256 i; i < oldLen;) {
            unchecked {
                --l.groupMembershipRefCount[current[i]];
                ++i;
            }
        }
        l.groupMemberSubjects[groupSubjectId] = memberSubjects;
        for (uint256 i; i < newLen;) {
            unchecked {
                ++l.groupMembershipRefCount[memberSubjects[i]];
                ++i;
            }
        }
        emit GroupEligibilitySet(groupSubjectId, memberSubjects);
    }

    /*═════════════════════════════════════ PERMISSION TABLE ═════════════════════════════════════*/

    function setPerm(uint256 subjectId, bytes32 permKey, uint256 mask) external onlyAdminOrRM {
        Layout storage l = _layout();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        l.permTable[subjectId][permKey] = mask;
        emit PermSet(subjectId, permKey, mask);
    }

    /*═════════════════════════════════════ ROLE LIFECYCLE ═════════════════════════════════════*/

    /// @dev Grant = mint-at-grant: set the accepted consent bit + an explicit (true,true) rule, the
    ///      unified analog of RoleManager._grantRole's grantWearerEligibility + mintHat. Group markers
    ///      are NOT separately minted — group membership is derived (this is exactly the collapse the
    ///      prototype is measuring). Provenance bit set when called by roleManager.
    function grantRole(uint256 subjectId, address user) external {
        Layout storage l = _layout();
        if (msg.sender != l.authorityAdmin && msg.sender != l.roleManager) revert NotAuthorized();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        uint8 flags = _packWearerFlags(true, true);
        bool delegated = msg.sender == l.roleManager;
        if (delegated) flags |= DELEGATION_MANAGED;
        l.wearerRules[user][subjectId] = WearerRules(flags);
        l.hasSpecificWearerRules[user][subjectId] = true;
        l.accepted[subjectId][user] = true;
        emit RoleGranted(subjectId, user, delegated);
    }

    /// @dev Revoke = clear the explicit rule + the accepted bit. Membership drops to false with no
    ///      external burn call (the derived markers auto-drop for free — the current design needs a
    ///      per-marker checkHatWearerStatus reconcile loop to free ERC-1155 supply; this does not).
    function revokeRole(uint256 subjectId, address user) external {
        Layout storage l = _layout();
        if (msg.sender != l.authorityAdmin && msg.sender != l.roleManager) revert NotAuthorized();
        if (!l.subjects[subjectId].exists) revert UnknownSubject();
        delete l.wearerRules[user][subjectId];
        delete l.hasSpecificWearerRules[user][subjectId];
        delete l.accepted[subjectId][user];
        emit RoleRevoked(subjectId, user);
    }

    /*═════════════════════════════════════ READ SURFACE (module calls these) ═════════════════════════════════════*/

    /// @notice Membership = accepted(consent bit) && eligible(policy). The analog of Hats
    ///         `isWearerOfHat` = stored balance>0 && active && eligible.
    function isMember(uint256 subjectId, address user) external view returns (bool) {
        Layout storage l = _layout();
        if (!l.accepted[subjectId][user]) return false;
        (bool eligible, bool standing) = _getStatus(l, user, subjectId);
        return eligible && standing;
    }

    /// @notice Raw eligibility (accepted bit ignored) — the analog of EM.getWearerStatus, used by the
    ///         onboarding/sponsorship pre-check path (eligible-but-not-yet-member).
    function getStatus(uint256 subjectId, address user) external view returns (bool eligible, bool standing) {
        return _getStatus(_layout(), user, subjectId);
    }

    /// @notice True if `user` is a member of ANY of `subjectIds` — the analog of
    ///         HatManager.hasAnyHat over a module's voting-hat array (DD/HV hot path).
    function hasAnyMember(uint256[] calldata subjectIds, address user) external view returns (bool) {
        Layout storage l = _layout();
        uint256 len = subjectIds.length;
        for (uint256 i; i < len;) {
            uint256 sid = subjectIds[i];
            if (l.accepted[sid][user]) {
                (bool eligible, bool standing) = _getStatus(l, user, sid);
                if (eligible && standing) return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice The permission mask a member subject grants for `permKey`, or 0 if `user` is not a
    ///         member of `subjectId`. Single-call replacement for the current TaskManager._permMask
    ///         (balanceOfBatch over N permission hats + per-hat mask OR).
    function hasPerm(uint256 subjectId, bytes32 permKey, address user) external view returns (uint256) {
        Layout storage l = _layout();
        if (!l.accepted[subjectId][user]) return 0;
        (bool eligible, bool standing) = _getStatus(l, user, subjectId);
        if (!eligible || !standing) return 0;
        return l.permTable[subjectId][permKey];
    }

    /*═════════════════════════════════════ ELIGIBILITY RESOLUTION (ported) ═════════════════════════════════════*/

    /// @dev Byte-for-byte logic-shape port of {EligibilityLogic._getWearerStatus}: explicit-ban
    ///      supremacy, hierarchy/default flags, vouch-with-epochs (+combine), email, derived groups.
    function _getStatus(Layout storage l, address wearer, uint256 subjectId)
        internal
        view
        returns (bool eligible, bool standing)
    {
        VouchConfig memory config = l.vouchConfigs[subjectId];

        bool hierarchyEligible;
        bool hierarchyStanding;
        bool vouchEligible;
        bool vouchStanding;

        WearerRules memory rules;
        if (l.hasSpecificWearerRules[wearer][subjectId]) {
            rules = l.wearerRules[wearer][subjectId];
            // FIX 0: explicit ban ((false,false), 0x03 bits clear) beats every other path.
            if ((rules.flags & 0x03) == 0) return (false, false);
        } else {
            rules = l.defaultRules[subjectId];
        }
        (hierarchyEligible, hierarchyStanding) = _unpackWearerFlags(rules.flags);

        uint32 effectiveVouchCount = (l.wearerVouchEpoch[subjectId][wearer] == l.vouchConfigEpoch[subjectId])
            ? l.currentVouchCount[subjectId][wearer]
            : 0;
        if (_isVouchingEnabled(config.flags) && effectiveVouchCount >= config.quorum) {
            vouchEligible = true;
            vouchStanding = true;
        }

        if (_isVouchingEnabled(config.flags)) {
            if (_shouldCombineWithHierarchy(config.flags)) {
                eligible = hierarchyEligible || vouchEligible;
                standing = hierarchyStanding || vouchStanding;
            } else {
                eligible = vouchEligible;
                standing = vouchStanding;
            }
        } else {
            eligible = hierarchyEligible;
            standing = hierarchyStanding;
        }

        // THIRD path: email-verified (only when no explicit per-wearer rule overrides it).
        if (l.emailVerified[subjectId][wearer] && !l.hasSpecificWearerRules[wearer][subjectId]) {
            eligible = true;
            standing = true;
        }

        // FOURTH path: derived (group) membership. Additive; explicit per-wearer rule wins.
        if (l.groupMemberSubjects[subjectId].length > 0 && !l.hasSpecificWearerRules[wearer][subjectId]) {
            if (_isMemberOfAnyMemberSubject(l, wearer, subjectId)) {
                eligible = true;
                standing = true;
            }
        }

        if (!standing) {
            eligible = false;
        }
    }

    /// @dev True if `wearer` is a member of at least one of `subjectId`'s derived member subjects.
    ///      Flat one level (member subjects are leaves): mirrors {EligibilityLogic._wearsAnyMemberHat},
    ///      but "wearing a member hat" becomes "being an accepted+eligible member of the member subject".
    function _isMemberOfAnyMemberSubject(Layout storage l, address wearer, uint256 subjectId)
        internal
        view
        returns (bool)
    {
        uint256[] storage members = l.groupMemberSubjects[subjectId];
        uint256 len = members.length;
        for (uint256 i; i < len;) {
            uint256 m = members[i];
            if (l.accepted[m][wearer]) {
                (bool e, bool s) = _leafStatus(l, wearer, m);
                if (e && s) return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Leaf eligibility (no derived recursion — the flat model forbids a second level), so a group
    ///      resolution is O(members) leaf reads, matching the current derived path's O(members)
    ///      isWearerOfHat calls.
    function _leafStatus(Layout storage l, address wearer, uint256 subjectId)
        internal
        view
        returns (bool eligible, bool standing)
    {
        WearerRules memory rules;
        if (l.hasSpecificWearerRules[wearer][subjectId]) {
            rules = l.wearerRules[wearer][subjectId];
            if ((rules.flags & 0x03) == 0) return (false, false);
        } else {
            rules = l.defaultRules[subjectId];
        }
        (eligible, standing) = _unpackWearerFlags(rules.flags);

        VouchConfig memory config = l.vouchConfigs[subjectId];
        if (_isVouchingEnabled(config.flags)) {
            uint32 eff = (l.wearerVouchEpoch[subjectId][wearer] == l.vouchConfigEpoch[subjectId])
                ? l.currentVouchCount[subjectId][wearer]
                : 0;
            if (eff >= config.quorum) {
                eligible = true;
                standing = true;
            } else if (!_shouldCombineWithHierarchy(config.flags)) {
                eligible = false;
                standing = false;
            }
        }

        if (l.emailVerified[subjectId][wearer] && !l.hasSpecificWearerRules[wearer][subjectId]) {
            eligible = true;
            standing = true;
        }
        if (!standing) eligible = false;
    }

    /*═════════════════════════════════════ PURE HELPERS ═════════════════════════════════════════*/

    function _packWearerFlags(bool eligible, bool standing) internal pure returns (uint8 flags) {
        assembly {
            flags := or(eligible, shl(1, standing))
        }
    }

    function _unpackWearerFlags(uint8 flags) internal pure returns (bool eligible, bool standing) {
        assembly {
            eligible := and(flags, 1)
            standing := and(shr(1, flags), 1)
        }
    }

    function _isVouchingEnabled(uint8 flags) internal pure returns (bool) {
        return (flags & ENABLED_FLAG) != 0;
    }

    function _shouldCombineWithHierarchy(uint8 flags) internal pure returns (bool) {
        return (flags & 0x02) != 0;
    }
}
