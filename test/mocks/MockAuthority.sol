// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @notice Minimal MembershipAuthority router-facing READ surface for AuthorityRouter tests.
/// @dev Deliberately NOT dependent on workstream A1's real contract — only the frozen router-facing
///      selectors are implemented (isWearerOfHat / isEligible / balanceOf / getWearerStatus /
///      checkHatWearerStatus / viewHat). State is fully settable so the degenerate-input matrix and
///      revert-wrapping differentials can be driven deterministically. `revertAll` simulates a
///      reverting authority; `checkHatWearerStatus` performs an SSTORE so a CALL-vs-STATICCALL
///      regression (ruling R5) is observable.
contract MockAuthority {
    mapping(address => mapping(uint256 => bool)) public wearer;
    mapping(address => mapping(uint256 => bool)) public eligibleFlag;
    mapping(address => mapping(uint256 => bool)) public standingFlag;

    struct HatView {
        string details;
        uint32 maxSupply;
        uint32 supply;
        address eligibility;
        address toggle;
        string imageURI;
        uint16 lastHatId;
        bool mutable_;
        bool active;
    }

    mapping(uint256 => HatView) internal hatViews;

    bool public revertAll;
    uint256 public checkCallCount; // proves checkHatWearerStatus is reached via CALL (SSTORE)

    function setWearer(address user, uint256 id, bool w) external {
        wearer[user][id] = w;
    }

    function setEligible(address user, uint256 id, bool e) external {
        eligibleFlag[user][id] = e;
    }

    function setStanding(address user, uint256 id, bool s) external {
        standingFlag[user][id] = s;
    }

    function setHatView(uint256 id, HatView calldata v) external {
        hatViews[id] = v;
    }

    function setRevertAll(bool v) external {
        revertAll = v;
    }

    function isWearerOfHat(address user, uint256 id) external view returns (bool) {
        if (revertAll) revert("MockAuthority: revert");
        return wearer[user][id];
    }

    function isEligible(address user, uint256 id) external view returns (bool) {
        if (revertAll) revert("MockAuthority: revert");
        return eligibleFlag[user][id];
    }

    function balanceOf(address user, uint256 id) external view returns (uint256) {
        if (revertAll) revert("MockAuthority: revert");
        return wearer[user][id] ? 1 : 0;
    }

    function getWearerStatus(address user, uint256 id) external view returns (bool eligible, bool standing) {
        if (revertAll) revert("MockAuthority: revert");
        return (eligibleFlag[user][id], standingFlag[user][id]);
    }

    function checkHatWearerStatus(uint256 id, address user) external returns (bool) {
        if (revertAll) revert("MockAuthority: revert");
        checkCallCount += 1; // SSTORE — a STATICCALL would revert here
        return wearer[user][id];
    }

    function viewHat(uint256 id)
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
        if (revertAll) revert("MockAuthority: revert");
        HatView storage v = hatViews[id];
        return
            (v.details, v.maxSupply, v.supply, v.eligibility, v.toggle, v.imageURI, v.lastHatId, v.mutable_, v.active);
    }
}

/// @notice A with-CODE embedded target that returns MALFORMED (too-short) returndata for every call,
///         exercising the router's "malformed returndata → EMPTY resolution" arm of the classification
///         predicate (§2 table) — must never be decoded or propagated as a revert on hub reads.
contract MalformedAuthority {
    fallback() external {
        assembly {
            mstore(0x00, 0x01)
            return(0x00, 0x04) // 4 bytes — below every decode floor
        }
    }
}

/// @notice A tiny passthrough-Hats stand-in whose checkHatWearerStatus performs an SSTORE, proving the
///         router uses CALL (not STATICCALL) on the passthrough arm (ruling R5). Only the one selector
///         the test drives is implemented; the router talks to `hats` purely via low-level calls.
contract WritingHats {
    uint256 public writes;

    function checkHatWearerStatus(uint256, address) external returns (bool) {
        writes += 1; // SSTORE — STATICCALL would revert
        return true;
    }
}
