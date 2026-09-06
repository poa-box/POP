// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "../../lib/hats-protocol/src/Interfaces/IHats.sol";

/**
 * @title EligibilityLogic
 * @notice Delegatecall library holding the derived (group) eligibility + claim + role-manager logic
 *         for {EligibilityModule}. Offloaded to keep the module under the EIP-170 runtime limit
 *         (PaymasterRuleLib / HybridVoting precedent). Its functions are `external` so the linker
 *         deploys the library separately and the module reaches it via DELEGATECALL — msg.sender,
 *         msg.value and storage context are the module's.
 * @dev The Layout struct + storage slot below MUST stay byte-identical to {EligibilityModule.Layout}
 *      (append-only ERC-7201). Access modifiers / pause / reentrancy guards are enforced by the module
 *      wrappers before delegatecalling here; these bodies assume the caller was already authorized.
 */
library EligibilityLogic {
    /*═════════════════════════════════════════ ERRORS ═════════════════════════════════════════*/

    error ZeroAddress();
    error DerivedConflictsWithVouch();
    error NestedDerivedHat();
    error NotClaimableHat();
    error AlreadyWearingHat();
    error CannotKickGovernanceRuled();
    error KickIneffective();
    error NoPendingKick();
    error KickNotReady();
    error NotAuthorizedToKick();
    error KickNotEnabled();
    error NotDelegatedKick();
    error CannotVouchForSelf();
    error VouchingNotEnabled();
    error NotAuthorizedToVouch();
    error AlreadyVouched();
    error HasNotVouched();
    error VouchingRateLimitExceeded();
    error NewUserVouchingRestricted();

    /*═════════════════════════════════════════ EVENTS ═════════════════════════════════════════*/

    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );
    event HatClaimed(address indexed wearer, uint256 indexed hatId);
    event GroupEligibilitySet(uint256 indexed groupHatId, uint256[] memberHats);
    event HatConfigUpdated(uint256 indexed hatId, uint32 newMaxSupply);
    event KickConfigSet(uint256 indexed hatId, uint256 indexed kickerHatId, uint32 delaySecs, bool enabled);
    event KickPending(uint256 indexed hatId, address indexed wearer, address indexed kicker, uint64 effectiveAt);
    event KickCancelled(uint256 indexed hatId, address indexed wearer, address indexed by);
    event WearerKicked(uint256 indexed hatId, address indexed wearer, address indexed kicker);
    event WearerUnkicked(uint256 indexed hatId, address indexed wearer, address indexed by);
    event Vouched(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);
    event VouchRevoked(address indexed voucher, address indexed wearer, uint256 indexed hatId, uint32 newCount);

    /*═════════════════════════════════════════ STRUCTS ═════════════════════════════════════════*/

    struct WearerRules {
        uint8 flags;
    }

    struct VouchConfig {
        uint32 quorum;
        uint256 membershipHatId;
        uint8 flags;
    }

    /// @notice Per-hat delegated-kick configuration (Primitive B).
    struct KickConfig {
        uint256 kickerHatId; // wearers of this hat may kick/unkick wearers of the target hat
        uint32 delaySecs; // 0 = kick applies immediately; else the pending-kick effect delay
        bool enabled;
    }

    /// @notice A pending (delayed) kick awaiting finalize.
    struct PendingKick {
        uint64 effectiveAt; // 0 = no pending kick
        address kicker; // the original kicker (re-checked at finalize)
    }

    /*═══════════════════════════ ERC-7201 STORAGE (mirror of EligibilityModule) ═══════════════════════════*/

    /// @custom:storage-location erc7201:poa.eligibilitymodule.storage
    struct Layout {
        IHats hats;
        address superAdmin;
        address toggleModule;
        uint256 eligibilityModuleAdminHat;
        bool _paused;
        mapping(address => mapping(uint256 => WearerRules)) wearerRules;
        mapping(address => mapping(uint256 => bool)) hasSpecificWearerRules;
        mapping(uint256 => WearerRules) defaultRules;
        mapping(uint256 => VouchConfig) vouchConfigs;
        mapping(uint256 => mapping(address => mapping(address => bool))) vouchers;
        mapping(uint256 => mapping(address => uint32)) currentVouchCount;
        mapping(address => uint256) userJoinTime;
        mapping(address => mapping(uint256 => uint32)) dailyVouchCount;
        mapping(uint256 => mapping(address => bytes32)) roleApplications;
        mapping(uint256 => address[]) roleApplicants;
        uint256 _notEntered;
        mapping(uint256 => uint256) vouchConfigEpoch;
        mapping(uint256 => mapping(address => uint256)) wearerVouchEpoch;
        mapping(uint256 => mapping(address => mapping(address => uint256))) voucherRecordEpoch;
        uint32 maxDailyVouches;
        mapping(uint256 => mapping(address => bool)) emailVerified;
        address roleManager;
        mapping(uint256 => uint256[]) groupMemberHats;
        mapping(uint256 => uint256) groupMembershipRefCount;
        // Delegated-kick primitive (append-only tail — MUST mirror EligibilityModule.Layout byte-for-byte).
        mapping(uint256 => KickConfig) kickConfigs; // hatId => kick config
        mapping(uint256 => mapping(address => PendingKick)) pendingKicks; // hatId => wearer => pending kick
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.eligibilitymodule.storage");

    uint8 private constant ENABLED_FLAG = 0x01;
    /// @dev WearerRules.flags bit 2: DELEGATION_MANAGED provenance (kick / RM-mediated rule write).
    uint8 private constant DELEGATION_MANAGED = 0x04;

    uint32 private constant DEFAULT_MAX_DAILY_VOUCHES = 20;
    uint256 private constant NEW_USER_RESTRICTION_DAYS = 0;
    uint256 private constant SECONDS_PER_DAY = 86400;

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═══════════════════════════════════ DERIVED (GROUP) ELIGIBILITY ═══════════════════════════════════*/

    /// @dev See {EligibilityModule.setGroupEligibility}. Access enforced by the module wrapper.
    function setGroupEligibility(uint256 groupHatId, uint256[] calldata memberHats) external {
        Layout storage l = _layout();

        // Bidirectional derived<->vouch guard: cannot derive-configure a vouch-enabled hat.
        if (_isVouchingEnabled(l.vouchConfigs[groupHatId].flags)) revert DerivedConflictsWithVouch();

        // Nesting guard (target side): a hat that is itself a member of some other group may not become
        // a derived hat — the second level of nesting the flat model forbids.
        if (l.groupMembershipRefCount[groupHatId] > 0) revert NestedDerivedHat();

        // Nesting guard (member side): every new member hat must be a leaf (no derived config of its
        // own) and may not be the group hat itself (self-cycle).
        uint256 newLen = memberHats.length;
        for (uint256 i; i < newLen;) {
            uint256 memberHat = memberHats[i];
            if (memberHat == groupHatId) revert NestedDerivedHat();
            if (l.groupMemberHats[memberHat].length > 0) revert NestedDerivedHat();
            unchecked {
                ++i;
            }
        }

        // Maintain refcounts: release old members, adopt new ones (all checks are complete).
        uint256[] storage current = l.groupMemberHats[groupHatId];
        uint256 oldLen = current.length;
        for (uint256 i; i < oldLen;) {
            unchecked {
                --l.groupMembershipRefCount[current[i]];
                ++i;
            }
        }

        l.groupMemberHats[groupHatId] = memberHats;

        for (uint256 i; i < newLen;) {
            unchecked {
                ++l.groupMembershipRefCount[memberHats[i]];
                ++i;
            }
        }

        emit GroupEligibilitySet(groupHatId, memberHats);
    }

    /// @dev See {EligibilityModule.grantWearerEligibility}. Grant-only (true,true); access enforced by wrapper.
    ///      FIX 1: RoleManager-mediated writes (msg.sender == roleManager) carry the DELEGATION_MANAGED
    ///      provenance bit (grant writes (true,true|0x04)); direct superAdmin (governance) writes stay
    ///      governance-owned (bit clear). Also voids any pending delegated kick for this (wearer, hat).
    function grantWearerEligibility(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        uint8 flags = _packWearerFlags(true, true);
        if (msg.sender == l.roleManager) flags |= DELEGATION_MANAGED;
        l.wearerRules[wearer][hatId] = WearerRules(flags);
        l.hasSpecificWearerRules[wearer][hatId] = true;
        delete l.pendingKicks[hatId][wearer];
        emit WearerEligibilityUpdated(wearer, hatId, true, true, msg.sender);
    }

    /// @dev See {EligibilityModule.updateHatConfig}. Access enforced by wrapper.
    function updateHatConfig(uint256 hatId, uint32 newMaxSupply) external {
        _layout().hats.changeHatMaxSupply(hatId, newMaxSupply);
        emit HatConfigUpdated(hatId, newMaxSupply);
    }

    /*═══════════════════════════════════════ CLAIM PATHS ═══════════════════════════════════════*/

    /// @dev See {EligibilityModule.claimHat}/{claimHats}. `skipIfWorn` toggles batch (skip) vs single
    ///      (revert) semantics for the already-wearing case. Enforces a SPECIFIC eligibility source
    ///      (never bare default-open) and writes state before the external mint (CEI). Pause/reentrancy
    ///      guards live on the module wrappers.
    function claimHat(uint256 hatId, bool skipIfWorn) external {
        Layout storage l = _layout();

        if (l.hats.isWearerOfHat(msg.sender, hatId)) {
            if (skipIfWorn) return;
            revert AlreadyWearingHat();
        }

        (bool eligible, bool standing) = _getWearerStatus(l, msg.sender, hatId);
        if (!eligible || !standing) revert NotClaimableHat();
        if (!_hasSpecificEligibilitySource(l, msg.sender, hatId)) revert NotClaimableHat();

        // State change BEFORE external call (CEI): clear any pending application signal.
        delete l.roleApplications[hatId][msg.sender];

        bool success = l.hats.mintHat(hatId, msg.sender);
        require(success, "Hat minting failed");

        emit HatClaimed(msg.sender, hatId);
    }

    /// @dev See {EligibilityModule.claimVouchedHat}. Behaviour identical to the pre-offload body (same
    ///      require strings) — resolves status via the internal helper instead of an external self-call.
    ///      Pause/reentrancy guards live on the module wrapper.
    function claimVouchedHat(uint256 hatId) external {
        Layout storage l = _layout();

        (bool eligible, bool standing) = _getWearerStatus(l, msg.sender, hatId);
        require(eligible && standing, "Not eligible to claim hat");

        require(!l.hats.isWearerOfHat(msg.sender, hatId), "Already wearing hat");

        // State change BEFORE external call (CEI pattern)
        delete l.roleApplications[hatId][msg.sender];

        bool success = l.hats.mintHat(hatId, msg.sender);
        require(success, "Hat minting failed");

        emit HatClaimed(msg.sender, hatId);
    }

    /*═══════════════════════════════════ KICK DELEGATION (Primitive B) ═══════════════════════════════════*/

    /// @dev See {EligibilityModule.configureKick}. Access (onlySuperAdmin) enforced by the module wrapper.
    function configureKick(uint256 hatId, uint256 kickerHatId, uint32 delaySecs, bool enabled) external {
        Layout storage l = _layout();
        l.kickConfigs[hatId] = KickConfig({kickerHatId: kickerHatId, delaySecs: delaySecs, enabled: enabled});
        emit KickConfigSet(hatId, kickerHatId, delaySecs, enabled);
    }

    /// @dev See {EligibilityModule.kickWearer}. Caller must wear the config's kicker hat. Governance
    ///      supremacy: never flip provenance on a governance-written non-(true,true) rule. delaySecs==0
    ///      applies immediately (burn); else records a pending kick for permissionless {finalizeKick}.
    function kickWearer(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        KickConfig memory cfg = l.kickConfigs[hatId];
        if (!cfg.enabled) revert KickNotEnabled();
        if (!l.hats.isWearerOfHat(msg.sender, cfg.kickerHatId)) revert NotAuthorizedToKick();
        if (_isGovernanceRuled(l, wearer, hatId)) revert CannotKickGovernanceRuled();

        if (cfg.delaySecs == 0) {
            _applyKick(l, wearer, hatId, msg.sender);
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + cfg.delaySecs;
            l.pendingKicks[hatId][wearer] = PendingKick({effectiveAt: effectiveAt, kicker: msg.sender});
            emit KickPending(hatId, wearer, msg.sender, effectiveAt);
        }
    }

    /// @dev See {EligibilityModule.finalizeKick}. Permissionless after effectiveAt; RE-CHECKS that the
    ///      config is still enabled AND the original kicker still wears the kicker hat (pending kicks die
    ///      with the delegation) and that no governance supremacy ban was written during the delay.
    function finalizeKick(address wearer, uint256 hatId) external {
        Layout storage l = _layout();
        PendingKick memory pk = l.pendingKicks[hatId][wearer];
        if (pk.effectiveAt == 0) revert NoPendingKick();
        if (block.timestamp < pk.effectiveAt) revert KickNotReady();

        KickConfig memory cfg = l.kickConfigs[hatId];
        if (!cfg.enabled || !l.hats.isWearerOfHat(pk.kicker, cfg.kickerHatId)) revert NotAuthorizedToKick();
        if (_isGovernanceRuled(l, wearer, hatId)) revert CannotKickGovernanceRuled();

        delete l.pendingKicks[hatId][wearer];
        _applyKick(l, wearer, hatId, pk.kicker);
    }

    /// @dev See {EligibilityModule.cancelKick}. The original kicker or the superAdmin may cancel.
    function cancelKick(address wearer, uint256 hatId) external {
        Layout storage l = _layout();
        PendingKick memory pk = l.pendingKicks[hatId][wearer];
        if (pk.effectiveAt == 0) revert NoPendingKick();
        if (msg.sender != pk.kicker && msg.sender != l.superAdmin) revert NotAuthorizedToKick();
        delete l.pendingKicks[hatId][wearer];
        emit KickCancelled(hatId, wearer, msg.sender);
    }

    /// @dev See {EligibilityModule.unkickWearer}. Caller must wear the kicker hat. Requires the current
    ///      rule to be EXACTLY a delegated-kick ban (flags == 0x04) — never a governance ban (0x00) nor a
    ///      grant — then restores (true,true|0x04) so {claimHat}'s specific-source check passes and the
    ///      un-kicked wearer self-re-mints (prior wearing established consent).
    function unkickWearer(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        KickConfig memory cfg = l.kickConfigs[hatId];
        if (!cfg.enabled) revert KickNotEnabled();
        if (!l.hats.isWearerOfHat(msg.sender, cfg.kickerHatId)) revert NotAuthorizedToKick();
        if (!l.hasSpecificWearerRules[wearer][hatId] || l.wearerRules[wearer][hatId].flags != DELEGATION_MANAGED) {
            revert NotDelegatedKick();
        }
        l.wearerRules[wearer][hatId] = WearerRules(_packWearerFlags(true, true) | DELEGATION_MANAGED);
        emit WearerUnkicked(hatId, wearer, msg.sender);
    }

    /// @dev Applies a kick: writes (false,false | 0x04) BEFORE the external reconcile (CEI), burns via
    ///      Hats, then HONESTLY reverts {KickIneffective} if the wearer somehow still wears the hat
    ///      (belt-and-suspenders — unreachable under FIX 0 supremacy, but a full-tx revert leaves no
    ///      half-state if it ever were).
    function _applyKick(Layout storage l, address wearer, uint256 hatId, address kicker) internal {
        l.wearerRules[wearer][hatId] = WearerRules(DELEGATION_MANAGED);
        l.hasSpecificWearerRules[wearer][hatId] = true;
        l.hats.setHatWearerStatus(hatId, wearer, false, false);
        if (l.hats.isWearerOfHat(wearer, hatId)) revert KickIneffective();
        emit WearerKicked(hatId, wearer, kicker);
    }

    /// @dev True IFF an explicit rule exists that is governance-owned and NOT (true,true)-shaped — i.e.
    ///      bits 0-1 are not both set AND the DELEGATION_MANAGED provenance bit is clear. Kicks must never
    ///      flip provenance on such a rule (a governance ban / partial), so both {kickWearer} and
    ///      {finalizeKick} revert {CannotKickGovernanceRuled} on it. A (true,true) grant (0x03 or 0x07)
    ///      and an existing delegated kick (0x04) are kickable.
    function _isGovernanceRuled(Layout storage l, address wearer, uint256 hatId) internal view returns (bool) {
        if (!l.hasSpecificWearerRules[wearer][hatId]) return false;
        uint8 f = l.wearerRules[wearer][hatId].flags;
        return (f & 0x03) != 0x03 && (f & DELEGATION_MANAGED) == 0;
    }

    /*═══════════════════════════════════ VOUCHING (EIP-170 offload) ═══════════════════════════════════*/

    /// @dev See {EligibilityModule.vouchFor}. Behaviour identical to the pre-offload body; pause guard on
    ///      the module wrapper. msg.sender (the voucher) and block.timestamp are the module's under
    ///      delegatecall.
    function vouchFor(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();
        if (wearer == msg.sender) revert CannotVouchForSelf();

        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];
        if (!_isVouchingEnabled(config.flags)) revert VouchingNotEnabled();

        bool isAuthorized = l.hats.isWearerOfHat(msg.sender, config.membershipHatId);
        if (!isAuthorized && _shouldCombineWithHierarchy(config.flags)) {
            isAuthorized = l.hats.isAdminOfHat(msg.sender, hatId);
        }
        if (!isAuthorized) revert NotAuthorizedToVouch();

        uint256 currentEpoch = l.vouchConfigEpoch[hatId];
        if (l.wearerVouchEpoch[hatId][wearer] != currentEpoch) {
            l.currentVouchCount[hatId][wearer] = 0;
            l.wearerVouchEpoch[hatId][wearer] = currentEpoch;
        }

        if (l.vouchers[hatId][wearer][msg.sender] && l.voucherRecordEpoch[hatId][wearer][msg.sender] == currentEpoch) {
            revert AlreadyVouched();
        }

        _checkVouchingRateLimit(l, msg.sender);

        l.vouchers[hatId][wearer][msg.sender] = true;
        l.voucherRecordEpoch[hatId][wearer][msg.sender] = currentEpoch;
        uint32 newCount = l.currentVouchCount[hatId][wearer] + 1;
        l.currentVouchCount[hatId][wearer] = newCount;

        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        uint32 dailyCount = l.dailyVouchCount[msg.sender][currentDay] + 1;
        l.dailyVouchCount[msg.sender][currentDay] = dailyCount;

        emit Vouched(msg.sender, wearer, hatId, newCount);
    }

    /// @dev See {EligibilityModule.revokeVouch}. Behaviour identical to the pre-offload body.
    function revokeVouch(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();

        Layout storage l = _layout();
        VouchConfig memory config = l.vouchConfigs[hatId];
        if (!_isVouchingEnabled(config.flags)) revert VouchingNotEnabled();

        uint256 currentEpoch = l.vouchConfigEpoch[hatId];
        if (l.wearerVouchEpoch[hatId][wearer] != currentEpoch) revert HasNotVouched();
        if (!l.vouchers[hatId][wearer][msg.sender] || l.voucherRecordEpoch[hatId][wearer][msg.sender] != currentEpoch) {
            revert HasNotVouched();
        }

        l.vouchers[hatId][wearer][msg.sender] = false;
        uint32 newCount = l.currentVouchCount[hatId][wearer] - 1;
        l.currentVouchCount[hatId][wearer] = newCount;

        emit VouchRevoked(msg.sender, wearer, hatId, newCount);

        if (
            !_shouldCombineWithHierarchy(config.flags) && newCount < config.quorum
                && l.hats.isWearerOfHat(wearer, hatId) && !l.hasSpecificWearerRules[wearer][hatId]
        ) {
            l.hats.setHatWearerStatus(hatId, wearer, false, false);
        }
    }

    function _getMaxDailyVouches(Layout storage l) internal view returns (uint32) {
        uint32 stored = l.maxDailyVouches;
        return stored > 0 ? stored : DEFAULT_MAX_DAILY_VOUCHES;
    }

    function _checkVouchingRateLimit(Layout storage l, address user) internal view {
        uint256 joinTime = l.userJoinTime[user];
        if (joinTime != 0) {
            uint256 daysSinceJoined = (block.timestamp - joinTime) / SECONDS_PER_DAY;
            if (daysSinceJoined < NEW_USER_RESTRICTION_DAYS) {
                revert NewUserVouchingRestricted();
            }
        }

        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        if (l.dailyVouchCount[user][currentDay] >= _getMaxDailyVouches(l)) {
            revert VouchingRateLimitExceeded();
        }
    }

    /*═══════════════════════════════════ ELIGIBILITY RESOLUTION ═══════════════════════════════════*/

    /// @dev See {EligibilityModule.getWearerStatus}. Additive derived (group) branch mirrors the email
    ///      branch's placement + precedence; a hat with no derived config returns byte-identical results.
    function getWearerStatus(address wearer, uint256 hatId) external view returns (bool eligible, bool standing) {
        return _getWearerStatus(_layout(), wearer, hatId);
    }

    function _getWearerStatus(Layout storage l, address wearer, uint256 hatId)
        internal
        view
        returns (bool eligible, bool standing)
    {
        VouchConfig memory config = l.vouchConfigs[hatId];

        bool hierarchyEligible;
        bool hierarchyStanding;
        bool vouchEligible;
        bool vouchStanding;

        WearerRules memory rules;
        if (l.hasSpecificWearerRules[wearer][hatId]) {
            rules = l.wearerRules[wearer][hatId];
            // FIX 0 (explicit-ban supremacy): an explicit rule whose eligible+standing bits (0x03) are
            // BOTH clear — i.e. (false,false), regardless of the 0x04 provenance bit — beats vouch, email,
            // derived, and default on EVERY path. Short-circuit before the vouch combine so a governance
            // ban (or delegated kick) sticks even on vouch-gated hats. Explicit (true,true) keeps today's
            // additive OR semantics (no short-circuit).
            if ((rules.flags & 0x03) == 0) return (false, false);
        } else {
            rules = l.defaultRules[hatId];
        }
        (hierarchyEligible, hierarchyStanding) = _unpackWearerFlags(rules.flags);

        uint32 effectiveVouchCount =
            (l.wearerVouchEpoch[hatId][wearer] == l.vouchConfigEpoch[hatId]) ? l.currentVouchCount[hatId][wearer] : 0;
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
        if (l.emailVerified[hatId][wearer] && !l.hasSpecificWearerRules[wearer][hatId]) {
            eligible = true;
            standing = true;
        }

        // FOURTH path: derived (group) membership. Additive — skipped entirely for any hat with no
        // derived config, so those return byte-identical results. Explicit per-wearer rule wins (kick).
        if (l.groupMemberHats[hatId].length > 0 && !l.hasSpecificWearerRules[wearer][hatId]) {
            if (_wearsAnyMemberHat(l, wearer, hatId)) {
                eligible = true;
                standing = true;
            }
        }

        if (!standing) {
            eligible = false;
        }
    }

    /// @dev True if `wearer` wears at least one of `hatId`'s configured derived member hats.
    function _wearsAnyMemberHat(Layout storage l, address wearer, uint256 hatId) internal view returns (bool) {
        uint256[] storage members = l.groupMemberHats[hatId];
        uint256 len = members.length;
        for (uint256 i; i < len;) {
            if (l.hats.isWearerOfHat(wearer, members[i])) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev True IFF the caller's eligibility for `hatId` traces to a SPECIFIC source (explicit rule
    ///      granting, met vouch quorum current epoch, email verification, or derived membership) — NOT
    ///      bare default-open eligibility (H-03 class). Precedence mirrors {_getWearerStatus}.
    function _hasSpecificEligibilitySource(Layout storage l, address wearer, uint256 hatId)
        internal
        view
        returns (bool)
    {
        bool hasRules = l.hasSpecificWearerRules[wearer][hatId];

        if (hasRules) {
            uint8 f = l.wearerRules[wearer][hatId].flags;
            // FIX 0 mirror: an explicit ban ((false,false), 0x03 bits clear) is a supremacy rule — it is
            // NOT a specific eligibility source and blocks every other path (vouch/email/derived).
            if ((f & 0x03) == 0) return false;
            // Explicit (true,true) grant is a specific source.
            if ((f & 0x03) == 0x03) return true;
        }

        VouchConfig memory config = l.vouchConfigs[hatId];
        if (_isVouchingEnabled(config.flags)) {
            uint32 eff = (l.wearerVouchEpoch[hatId][wearer] == l.vouchConfigEpoch[hatId])
                ? l.currentVouchCount[hatId][wearer]
                : 0;
            if (eff >= config.quorum) return true;
        }

        if (!hasRules && l.emailVerified[hatId][wearer]) return true;

        if (!hasRules && l.groupMemberHats[hatId].length > 0 && _wearsAnyMemberHat(l, wearer, hatId)) {
            return true;
        }

        return false;
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
