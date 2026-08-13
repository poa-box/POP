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
    mapping(uint256 => uint256[]) internal _groupMemberHats;

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

    function clearWearerEligibility(address wearer, uint256 hatId) external {
        hasExplicit[hatId][wearer] = false;
        explicitEligible[hatId][wearer] = false;
        clearCount[hatId] += 1;
    }

    function grantWearerEligibility(address wearer, uint256 hatId) external {
        hasExplicit[hatId][wearer] = true;
        explicitEligible[hatId][wearer] = true;
        grantCount[hatId] += 1;
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
