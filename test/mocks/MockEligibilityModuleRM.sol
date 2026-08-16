// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {MockHatsRM} from "./MockHatsRM.sol";

/// @notice Minimal EligibilityModule stand-in for RoleManager unit tests. Models the parts of the
///         W1 derived-eligibility surface RoleManager depends on: explicit per-wearer rules (which
///         WIN over everything — kick precedence), per-hat default eligibility, and derived
///         membership (wearer of any listed member hat is eligible for the group hat). `MockHatsRM`
///         consults this contract so `balanceOf`/`isWearerOfHat` are dynamic, matching real Hats.
contract MockEligibilityModuleRM {
    struct CreateHatParams {
        uint256 parentHatId;
        string details;
        uint32 maxSupply;
        bool _mutable;
        string imageURI;
        bool defaultEligible;
        bool defaultStanding;
        address[] mintToAddresses;
        bool[] wearerEligibleFlags;
        bool[] wearerStandingFlags;
    }

    MockHatsRM public hats;
    uint256 public adminHat;
    uint256 public nextHatId = 1000;

    // eligibility state
    mapping(uint256 => bool) public defaultEligible;
    mapping(uint256 => mapping(address => bool)) public hasExplicit;
    mapping(uint256 => mapping(address => bool)) public explicitEligible;
    // Provenance emulation (W12 getWearerRuleFlags): the full flags byte per explicit rule —
    // bit0 eligible, bit1 standing, bit2 (0x04) DELEGATION_MANAGED. RM-mediated writes carry 0x04;
    // governance (superAdmin) writes do NOT. `govSetRule`/`delegatedKick` seed the two provenances.
    mapping(uint256 => mapping(address => uint8)) public explicitFlags;
    mapping(uint256 => uint256[]) internal _groupMemberHats;

    uint8 private constant FLAG_ELIGIBLE = 0x01;
    uint8 private constant FLAG_STANDING = 0x02;
    uint8 private constant FLAG_DELEGATION_MANAGED = 0x04;

    // call recording
    mapping(uint256 => uint32) public lastVouchQuorum;
    mapping(uint256 => bool) public vouchConfigured;
    mapping(uint256 => uint32) public lastMaxSupply;
    mapping(uint256 => uint256) public grantCount; // hatId => number of grantWearerEligibility calls
    mapping(uint256 => uint256) public clearCount; // hatId => number of clearWearerEligibility calls

    event GroupEligibilitySet(uint256 indexed groupHatId, uint256[] memberHats);

    constructor(MockHatsRM _hats, uint256 _adminHat) {
        hats = _hats;
        adminHat = _adminHat;
    }

    function eligibilityModuleAdminHat() external view returns (uint256) {
        return adminHat;
    }

    function createHatWithEligibility(CreateHatParams calldata params) external returns (uint256 hatId) {
        hatId = nextHatId++;
        defaultEligible[hatId] = params.defaultEligible;
        lastMaxSupply[hatId] = params.maxSupply;
    }

    /// @dev RM-path clear: wipes the rule AND its provenance bit (W12 semantics — RM writes clear 0x04).
    function clearWearerEligibility(address wearer, uint256 hatId) external {
        hasExplicit[hatId][wearer] = false;
        explicitEligible[hatId][wearer] = false;
        explicitFlags[hatId][wearer] = 0;
        clearCount[hatId] += 1;
    }

    /// @dev RM-path grant: writes (true,true | 0x04) — RM-mediated, delegation-managed provenance.
    function grantWearerEligibility(address wearer, uint256 hatId) external {
        hasExplicit[hatId][wearer] = true;
        explicitEligible[hatId][wearer] = true;
        explicitFlags[hatId][wearer] = FLAG_ELIGIBLE | FLAG_STANDING | FLAG_DELEGATION_MANAGED;
        grantCount[hatId] += 1;
    }

    /// @notice Test-only: emulate a GOVERNANCE (superAdmin) rule write — carries NO 0x04 provenance
    ///         bit, so RoleManager treats it as governance-owned (ban when ineligible, offer when
    ///         (true,true)).
    function govSetRule(address wearer, uint256 hatId, bool eligible, bool standing) external {
        hasExplicit[hatId][wearer] = true;
        explicitEligible[hatId][wearer] = eligible;
        explicitFlags[hatId][wearer] = (eligible ? FLAG_ELIGIBLE : 0) | (standing ? FLAG_STANDING : 0);
    }

    /// @notice Test-only: emulate a DELEGATED KICK — explicit (false,false | 0x04). RoleManager may
    ///         clear/overwrite it (manager undoing manager).
    function delegatedKick(address wearer, uint256 hatId) external {
        hasExplicit[hatId][wearer] = true;
        explicitEligible[hatId][wearer] = false;
        explicitFlags[hatId][wearer] = FLAG_DELEGATION_MANAGED;
    }

    /// @notice Provenance view consumed by RoleManager's delegated grant/revoke guards.
    function getWearerRuleFlags(address wearer, uint256 hatId) external view returns (bool hasRule, uint8 flags) {
        return (hasExplicit[hatId][wearer], explicitFlags[hatId][wearer]);
    }

    function mintHatToAddress(uint256 hatId, address wearer) external {
        require(isEligible(wearer, hatId), "not eligible");
        hats.mintHat(hatId, wearer);
    }

    function setGroupEligibility(uint256 groupHatId, uint256[] calldata memberHats) external {
        _groupMemberHats[groupHatId] = memberHats;
        emit GroupEligibilitySet(groupHatId, memberHats);
    }

    function getGroupMemberHats(uint256 groupHatId) external view returns (uint256[] memory) {
        return _groupMemberHats[groupHatId];
    }

    function configureVouching(uint256 hatId, uint32 quorum, uint256, bool) external {
        vouchConfigured[hatId] = true;
        lastVouchQuorum[hatId] = quorum;
    }

    function updateHatConfig(uint256 hatId, uint32 newMaxSupply) external {
        lastMaxSupply[hatId] = newMaxSupply;
    }

    function getDefaultRules(uint256 hatId) external view returns (bool eligible, bool standing) {
        return (defaultEligible[hatId], true);
    }

    /// @notice Eligibility resolution: explicit per-wearer rule wins; else default; else derived.
    function isEligible(address wearer, uint256 hatId) public view returns (bool) {
        if (hasExplicit[hatId][wearer]) return explicitEligible[hatId][wearer];
        if (defaultEligible[hatId]) return true;
        uint256[] storage members = _groupMemberHats[hatId];
        uint256 len = members.length;
        for (uint256 i; i < len; ++i) {
            if (hats.isWearerOfHat(wearer, members[i])) return true;
        }
        return false;
    }
}
