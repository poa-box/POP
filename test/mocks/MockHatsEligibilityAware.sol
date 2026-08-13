// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {IHatsEligibility} from "lib/hats-protocol/src/Interfaces/IHatsEligibility.sol";

/// @title MockHatsEligibilityAware
/// @notice Hats stand-in that faithfully models the Hats "eligibility != balance" invariant (audit
///         finding C-1): `mintHat` sets the stored ERC-1155 balance, but `balanceOf` / `isWearerOfHat`
///         return that balance ONLY while the wearer is currently eligible + in good standing per the
///         wired eligibility module. Losing eligibility therefore zeroes `balanceOf` dynamically with
///         NO burn call — exactly the auto-revocation the derived (group) eligibility path relies on.
///         `isEligible` (used by PaymasterHub for pre-claim sponsorship) reports eligibility regardless
///         of whether a mint has happened.
contract MockHatsEligibilityAware is IHats {
    /// @dev The stored ERC-1155 balance (whether a mint has occurred). NOT the effective wearer status.
    mapping(address => mapping(uint256 => bool)) public minted;
    mapping(uint256 => bool) public activeHats;
    mapping(uint256 => uint32) public maxSupplyOf;

    /// @dev The eligibility module consulted for effective status (the EligibilityModule under test).
    address public eligibilityModule;

    function setEligibilityModule(address module) external {
        eligibilityModule = module;
    }

    /// @dev Effective eligibility+standing per the wired module. Defaults to true when no module is set
    ///      (models a hat with no eligibility gate) so unrelated helper hats behave as plain wearers.
    function _eligible(address wearer, uint256 hatId) internal view returns (bool) {
        if (eligibilityModule == address(0)) return true;
        (bool e, bool s) = IHatsEligibility(eligibilityModule).getWearerStatus(wearer, hatId);
        return e && s;
    }

    /*───────────────────────────── Balance / wearer status (eligibility-aware) ─────────────────────────────*/

    function mintHat(uint256 _hatId, address _wearer) external returns (bool success) {
        minted[_wearer][_hatId] = true;
        if (!activeHats[_hatId]) activeHats[_hatId] = true;
        return true;
    }

    function balanceOf(address wearer, uint256 hatId) public view returns (uint256 balance) {
        return (minted[wearer][hatId] && _eligible(wearer, hatId)) ? 1 : 0;
    }

    function isWearerOfHat(address _user, uint256 _hatId) public view returns (bool isWearer) {
        return balanceOf(_user, _hatId) > 0;
    }

    function isEligible(address _wearer, uint256 _hatId) external view returns (bool eligible) {
        return _eligible(_wearer, _hatId);
    }

    function balanceOfBatch(address[] calldata _wearers, uint256[] calldata _hatIds)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory balances = new uint256[](_wearers.length);
        for (uint256 i = 0; i < _wearers.length; i++) {
            balances[i] = balanceOf(_wearers[i], _hatIds[i]);
        }
        return balances;
    }

    function isInGoodStanding(address _wearer, uint256 _hatId) external view returns (bool standing) {
        if (eligibilityModule == address(0)) return true;
        (, bool s) = IHatsEligibility(eligibilityModule).getWearerStatus(_wearer, _hatId);
        return s;
    }

    function isAdminOfHat(address _user, uint256 _hatId) external view returns (bool isAdmin) {
        return isWearerOfHat(_user, _hatId);
    }

    /*───────────────────────────── Hat creation / config ─────────────────────────────*/

    function createHat(uint256 _admin, string calldata, uint32 _maxSupply, address, address, bool, string calldata)
        external
        returns (uint256 newHatId)
    {
        newHatId = _admin + 1;
        activeHats[newHatId] = true;
        maxSupplyOf[newHatId] = _maxSupply;
        return newHatId;
    }

    function changeHatMaxSupply(uint256 _hatId, uint32 _newMaxSupply) external {
        maxSupplyOf[_hatId] = _newMaxSupply;
    }

    function setHatStatus(uint256 _hatId, bool _newStatus) external returns (bool toggled) {
        activeHats[_hatId] = _newStatus;
        return true;
    }

    function setHatWearerStatus(uint256 _hatId, address _wearer, bool _eligible_, bool _standing)
        external
        returns (bool updated)
    {
        // Model a burn on eligibility loss: clears the stored balance.
        if (!(_eligible_ && _standing)) minted[_wearer][_hatId] = false;
        return true;
    }

    /*───────────────────────────── IHatsIdUtilities (minimal) ─────────────────────────────*/

    function buildHatId(uint256 _admin, uint16 _newHat) external pure returns (uint256 id) {
        return _admin + _newHat;
    }

    function getHatLevel(uint256) external pure returns (uint32 level) {
        return 1;
    }

    function getLocalHatLevel(uint256) external pure returns (uint32 level) {
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

    function getAdminAtLevel(uint256 _hatId, uint32) external pure returns (uint256 admin) {
        return _hatId - 1;
    }

    function getAdminAtLocalLevel(uint256 _hatId, uint32) external pure returns (uint256 admin) {
        return _hatId - 1;
    }

    function getTopHatDomain(uint256) external pure returns (uint32 domain) {
        return 1;
    }

    function getTippyTopHatDomain(uint32 _topHatDomain) external pure returns (uint32 domain) {
        return _topHatDomain;
    }

    function noCircularLinkage(uint32, uint256) external pure returns (bool notCircular) {
        return true;
    }

    function sameTippyTopHatDomain(uint32, uint256) external pure returns (bool sameDomain) {
        return true;
    }

    /*───────────────────────────── Remaining IHats surface (stubs) ─────────────────────────────*/

    function mintTopHat(address _target, string memory, string memory) external returns (uint256 topHatId) {
        topHatId = 1;
        minted[_target][topHatId] = true;
        activeHats[topHatId] = true;
        return topHatId;
    }

    function batchCreateHats(
        uint256[] calldata,
        string[] calldata,
        uint32[] calldata,
        address[] memory,
        address[] memory,
        bool[] calldata,
        string[] calldata
    ) external pure returns (bool success) {
        return true;
    }

    function getNextId(uint256 _admin) external pure returns (uint256 nextId) {
        return _admin + 1;
    }

    function batchMintHats(uint256[] calldata, address[] calldata) external pure returns (bool success) {
        return true;
    }

    function checkHatStatus(uint256 _hatId) external returns (bool toggled) {
        return activeHats[_hatId];
    }

    function checkHatWearerStatus(uint256 _hatId, address _wearer) external returns (bool updated) {
        return isWearerOfHat(_wearer, _hatId);
    }

    function renounceHat(uint256 _hatId) external {
        minted[msg.sender][_hatId] = false;
    }

    function transferHat(uint256 _hatId, address _from, address _to) external {
        minted[_from][_hatId] = false;
        minted[_to][_hatId] = true;
    }

    function makeHatImmutable(uint256) external {}
    function changeHatDetails(uint256, string memory) external {}
    function changeHatEligibility(uint256, address) external {}
    function changeHatToggle(uint256, address) external {}
    function changeHatImageURI(uint256, string memory) external {}
    function requestLinkTopHatToTree(uint32, uint256) external {}
    function approveLinkTopHatToTree(uint32, uint256, address, address, string calldata, string calldata) external {}
    function unlinkTopHatFromTree(uint32, address) external {}
    function relinkTopHatWithinTree(uint32, uint256, address, address, string calldata, string calldata) external {}

    function viewHat(uint256 _hatId)
        external
        view
        returns (string memory, uint32, uint32, address, address, string memory, uint16, bool, bool)
    {
        return ("", maxSupplyOf[_hatId], 0, address(0), address(0), "", 0, true, activeHats[_hatId]);
    }

    function getHatEligibilityModule(uint256) external view returns (address eligibility) {
        return eligibilityModule;
    }

    function getHatToggleModule(uint256) external pure returns (address toggle) {
        return address(0);
    }

    function getHatMaxSupply(uint256 _hatId) external view returns (uint32 maxSupply) {
        return maxSupplyOf[_hatId];
    }

    function hatSupply(uint256) external pure returns (uint32 supply) {
        return 0;
    }

    function getImageURIForHat(uint256) external pure returns (string memory _uri) {
        return "";
    }

    function uri(uint256) external pure returns (string memory _uri) {
        return "";
    }
}
