// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

contract MockHats is IHats {
    mapping(address => mapping(uint256 => bool)) public wearers;
    mapping(address => mapping(uint256 => bool)) public eligibles;
    mapping(uint256 => bool) public activeHats;

    // IHatsIdUtilities implementations
    function buildHatId(uint256 _admin, uint16 _newHat) external pure returns (uint256 id) {
        return _admin + _newHat;
    }

    function getHatLevel(uint256 _hatId) external pure returns (uint32 level) {
        return 1;
    }

    function getLocalHatLevel(uint256 _hatId) external pure returns (uint32 level) {
        return 1;
    }

    function isTopHat(uint256 _hatId) external pure returns (bool _topHat) {
        return _hatId == 1;
    }

    function isLocalTopHat(uint256 _hatId) external pure returns (bool _localTopHat) {
        return _hatId == 1;
    }

    function isValidHatId(uint256 _hatId) external pure returns (bool validHatId) {
        return _hatId > 0;
    }

    function getAdminAtLevel(uint256 _hatId, uint32 _level) external pure returns (uint256 admin) {
        return _hatId - 1;
    }

    function getAdminAtLocalLevel(uint256 _hatId, uint32 _level) external pure returns (uint256 admin) {
        return _hatId - 1;
    }

    function getTopHatDomain(uint256 _hatId) external pure returns (uint32 domain) {
        return 1;
    }

    function getTippyTopHatDomain(uint32 _topHatDomain) external pure returns (uint32 domain) {
        return _topHatDomain;
    }

    function noCircularLinkage(uint32 _topHatDomain, uint256 _linkedAdmin) external pure returns (bool notCircular) {
        return true;
    }

    function sameTippyTopHatDomain(uint32 _topHatDomain, uint256 _newAdminHat) external pure returns (bool sameDomain) {
        return true;
    }

    // Original IHats implementations
    function mintTopHat(address _target, string memory _details, string memory _imageURI)
        external
        returns (uint256 topHatId)
    {
        topHatId = 1;
        wearers[_target][topHatId] = true;
        activeHats[topHatId] = true;
        return topHatId;
    }

    function createHat(
        uint256 _admin,
        string calldata _details,
        uint32 _maxSupply,
        address _eligibility,
        address _toggle,
        bool _mutable,
        string calldata _imageURI
    ) external returns (uint256 newHatId) {
        newHatId = _admin + 1;
        activeHats[newHatId] = true;
        return newHatId;
    }

    function batchCreateHats(
        uint256[] calldata _admins,
        string[] calldata _details,
        uint32[] calldata _maxSupplies,
        address[] memory _eligibilityModules,
        address[] memory _toggleModules,
        bool[] calldata _mutables,
        string[] calldata _imageURIs
    ) external returns (bool success) {
        return true;
    }

    function getNextId(uint256 _admin) external view returns (uint256 nextId) {
        return _admin + 1;
    }

    function mintHat(uint256 _hatId, address _wearer) external returns (bool success) {
        wearers[_wearer][_hatId] = true;
        if (!activeHats[_hatId]) {
            activeHats[_hatId] = true;
        }
        return true;
    }

    function batchMintHats(uint256[] calldata _hatIds, address[] calldata _wearers) external returns (bool success) {
        return true;
    }

    function setHatStatus(uint256 _hatId, bool _newStatus) external returns (bool toggled) {
        activeHats[_hatId] = _newStatus;
        return true;
    }

    function checkHatStatus(uint256 _hatId) external returns (bool toggled) {
        return activeHats[_hatId];
    }

    function setHatWearerStatus(uint256 _hatId, address _wearer, bool _eligible, bool _standing)
        external
        returns (bool updated)
    {
        wearers[_wearer][_hatId] = _eligible && _standing;
        return true;
    }

    function checkHatWearerStatus(uint256 _hatId, address _wearer) external returns (bool updated) {
        return wearers[_wearer][_hatId];
    }

    function renounceHat(uint256 _hatId) external {
        wearers[msg.sender][_hatId] = false;
    }

    function transferHat(uint256 _hatId, address _from, address _to) external {
        wearers[_from][_hatId] = false;
        wearers[_to][_hatId] = true;
    }

    function makeHatImmutable(uint256 _hatId) external {}
    function changeHatDetails(uint256 _hatId, string memory _newDetails) external {}
    function changeHatEligibility(uint256 _hatId, address _newEligibility) external {}
    function changeHatToggle(uint256 _hatId, address _newToggle) external {}
    function changeHatImageURI(uint256 _hatId, string memory _newImageURI) external {}
    function changeHatMaxSupply(uint256 _hatId, uint32 _newMaxSupply) external {}
    function requestLinkTopHatToTree(uint32 _topHatId, uint256 _newAdminHat) external {}
    function approveLinkTopHatToTree(
        uint32 _topHatId,
        uint256 _newAdminHat,
        address _eligibility,
        address _toggle,
        string calldata _details,
        string calldata _imageURI
    ) external {}
    function unlinkTopHatFromTree(uint32 _topHatId, address _wearer) external {}
    function relinkTopHatWithinTree(
        uint32 _topHatDomain,
        uint256 _newAdminHat,
        address _eligibility,
        address _toggle,
        string calldata _details,
        string calldata _imageURI
    ) external {}

    function viewHat(uint256 _hatId)
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
        return ("", 0, 0, address(0), address(0), "", 0, true, activeHats[_hatId]);
    }

    function isWearerOfHat(address _user, uint256 _hatId) external view returns (bool isWearer) {
        return wearers[_user][_hatId];
    }

    function isAdminOfHat(address _user, uint256 _hatId) external view returns (bool isAdmin) {
        return wearers[_user][_hatId];
    }

    function isInGoodStanding(address _wearer, uint256 _hatId) external view returns (bool standing) {
        return wearers[_wearer][_hatId];
    }

    function setEligible(address _wearer, uint256 _hatId, bool _eligible) external {
        eligibles[_wearer][_hatId] = _eligible;
        if (!activeHats[_hatId]) {
            activeHats[_hatId] = true;
        }
    }

    bool public revertOnEligible;

    /// @dev Simulate a missing / non-conforming eligibility module so callers can exercise
    ///      their fail-closed handling of a reverting `isEligible` probe.
    function setRevertOnEligible(bool _v) external {
        revertOnEligible = _v;
    }

    function isEligible(address _wearer, uint256 _hatId) external view returns (bool eligible) {
        if (revertOnEligible) revert("MockHats: eligibility probe reverted");
        return wearers[_wearer][_hatId] || eligibles[_wearer][_hatId];
    }

    function getHatEligibilityModule(uint256 _hatId) external view returns (address eligibility) {
        return address(0);
    }

    function getHatToggleModule(uint256 _hatId) external view returns (address toggle) {
        return address(0);
    }

    function getHatMaxSupply(uint256 _hatId) external view returns (uint32 maxSupply) {
        return 0;
    }

    function hatSupply(uint256 _hatId) external view returns (uint32 supply) {
        return 0;
    }

    function getImageURIForHat(uint256 _hatId) external view returns (string memory _uri) {
        return "";
    }

    function balanceOf(address wearer, uint256 hatId) external view returns (uint256 balance) {
        return wearers[wearer][hatId] ? 1 : 0;
    }

    function balanceOfBatch(address[] calldata _wearers, uint256[] calldata _hatIds)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory balances = new uint256[](_wearers.length);
        for (uint256 i = 0; i < _wearers.length; i++) {
            balances[i] = wearers[_wearers[i]][_hatIds[i]] ? 1 : 0;
        }
        return balances;
    }

    function uri(uint256 id) external view returns (string memory _uri) {
        return "";
    }
}
