// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IRoleBundleHatter} from "../interfaces/IRoleBundleHatter.sol";

/**
 * @title RoleBundleHatterLens
 * @notice Read-only helpers for indexing RoleBundleHatter state from off-chain (subgraph, UI).
 *         Bundles are stored as `mapping(uint256 => uint256[])` inside RoleBundleHatter, which
 *         means there's no native way to enumerate all role hats with bundles. The subgraph
 *         indexes `BundleSet` / `BundleUpdated` events to track this; the lens here provides
 *         efficient batch reads given a known set of role hats.
 */
contract RoleBundleHatterLens {
    /// @notice Fetches the bundle for a single role hat.
    /// @param rbh The RoleBundleHatter proxy
    /// @param roleHat Role hat ID to look up
    /// @return capabilityHats Capability hats granted alongside this role
    function getBundle(IRoleBundleHatter rbh, uint256 roleHat) external view returns (uint256[] memory) {
        return rbh.getBundle(roleHat);
    }

    /// @notice Batch-fetches bundles for many role hats in a single call. Returns a parallel
    ///         array — entry `i` is the bundle for `roleHats[i]`.
    /// @param rbh The RoleBundleHatter proxy
    /// @param roleHats Role hat IDs to look up
    /// @return bundles Parallel array of capability-hat arrays
    function getBundlesBatch(IRoleBundleHatter rbh, uint256[] calldata roleHats)
        external
        view
        returns (uint256[][] memory bundles)
    {
        uint256 len = roleHats.length;
        bundles = new uint256[][](len);
        for (uint256 i; i < len;) {
            bundles[i] = rbh.getBundle(roleHats[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Batch-fetches bundle sizes for many role hats. Useful for UI summary views
    ///         that show "VP role: 7 capabilities" without fetching the full lists.
    function getBundleSizes(IRoleBundleHatter rbh, uint256[] calldata roleHats)
        external
        view
        returns (uint256[] memory sizes)
    {
        uint256 len = roleHats.length;
        sizes = new uint256[](len);
        for (uint256 i; i < len;) {
            sizes[i] = rbh.bundleSize(roleHats[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks whether a capability hat is in a role's bundle.
    function isInBundle(IRoleBundleHatter rbh, uint256 roleHat, uint256 capabilityHat) external view returns (bool) {
        return rbh.isInBundle(roleHat, capabilityHat);
    }

    /// @notice Batch authorized-minter check. Useful for the UI to render which contracts can
    ///         currently grant roles in an org.
    function getAuthorizedMintersBatch(IRoleBundleHatter rbh, address[] calldata minters)
        external
        view
        returns (bool[] memory results)
    {
        uint256 len = minters.length;
        results = new bool[](len);
        for (uint256 i; i < len;) {
            results[i] = rbh.isAuthorizedMinter(minters[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Summary view: the executor, deployer, hats address, and a count of authorized
    ///         minters' results given a candidate list. Reduces the number of RPC roundtrips
    ///         the UI needs to render an org's role-bundle config page.
    struct RoleBundleHatterSummary {
        address executor;
        address deployer;
        address hats;
    }

    function getSummary(IRoleBundleHatter rbh) external view returns (RoleBundleHatterSummary memory) {
        return RoleBundleHatterSummary({executor: rbh.executor(), deployer: rbh.deployer(), hats: rbh.hats()});
    }
}
