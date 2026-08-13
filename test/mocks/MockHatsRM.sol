// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

interface IEligibilitySource {
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
}

/// @notice Minimal Hats stand-in that models the ONE property RoleManager tests care about:
///         membership is `minted AND eligible`. `mintHat` sets a stored balance (requiring
///         eligibility at mint time); `isWearerOfHat`/`balanceOf` re-check eligibility on every read
///         so derived-eligibility revocation zeroes balances dynamically with no burn call — exactly
///         like real Hats (balanceOf gates on `_isEligible`).
contract MockHatsRM {
    IEligibilitySource public eligibility;
    mapping(uint256 => mapping(address => bool)) public minted;

    /// @dev Set after construction (mock EM and mock Hats reference each other).
    function setEligibility(address src) external {
        eligibility = IEligibilitySource(src);
    }

    /// @dev Directly seed membership for test setup (bypasses eligibility — used to put a user "in
    ///      org" via a pre-existing member hat). Marks the hat eligible-by-fiat too.
    function forceWear(uint256 hatId, address wearer) external {
        minted[hatId][wearer] = true;
        _forced[hatId][wearer] = true;
    }

    mapping(uint256 => mapping(address => bool)) internal _forced;

    function mintHat(uint256 hatId, address wearer) external returns (bool) {
        require(_eligible(wearer, hatId), "mint: not eligible");
        minted[hatId][wearer] = true;
        return true;
    }

    function isWearerOfHat(address wearer, uint256 hatId) public view returns (bool) {
        return minted[hatId][wearer] && _eligible(wearer, hatId);
    }

    function balanceOf(address wearer, uint256 hatId) public view returns (uint256) {
        return isWearerOfHat(wearer, hatId) ? 1 : 0;
    }

    function balanceOfBatch(address[] calldata wearers, uint256[] calldata hatIds)
        external
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](wearers.length);
        for (uint256 i; i < wearers.length; ++i) {
            balances[i] = balanceOf(wearers[i], hatIds[i]);
        }
    }

    /// @dev Mirrors Hats.checkHatWearerStatus: burns (clears) the STATIC balance when the wearer
    ///      holds the token but the eligibility module now reports ineligible. Permissionless no-op
    ///      otherwise — RoleManager.revokeRole relies on this to free supply on capped hats.
    function checkHatWearerStatus(uint256 hatId, address wearer) external returns (bool updated) {
        if (minted[hatId][wearer] && !_eligible(wearer, hatId)) {
            minted[hatId][wearer] = false;
            return true;
        }
        return false;
    }

    function _eligible(address wearer, uint256 hatId) internal view returns (bool) {
        if (_forced[hatId][wearer]) return true;
        if (address(eligibility) == address(0)) return false;
        return eligibility.isEligible(wearer, hatId);
    }
}
