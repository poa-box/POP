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

    /*═════════════════════════════════════════ EVENTS ═════════════════════════════════════════*/

    event WearerEligibilityUpdated(
        address indexed wearer, uint256 indexed hatId, bool eligible, bool standing, address indexed admin
    );
    event HatClaimed(address indexed wearer, uint256 indexed hatId);
    event GroupEligibilitySet(uint256 indexed groupHatId, uint256[] memberHats);
    event HatConfigUpdated(uint256 indexed hatId, uint32 newMaxSupply);

    /*═════════════════════════════════════════ STRUCTS ═════════════════════════════════════════*/

    struct WearerRules {
        uint8 flags;
    }

    struct VouchConfig {
        uint32 quorum;
        uint256 membershipHatId;
        uint8 flags;
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
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.eligibilitymodule.storage");

    uint8 private constant ENABLED_FLAG = 0x01;

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
    function grantWearerEligibility(address wearer, uint256 hatId) external {
        if (wearer == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        l.wearerRules[wearer][hatId] = WearerRules(_packWearerFlags(true, true));
        l.hasSpecificWearerRules[wearer][hatId] = true;
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
            (bool e, bool s) = _unpackWearerFlags(l.wearerRules[wearer][hatId].flags);
            if (e && s) return true;
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
