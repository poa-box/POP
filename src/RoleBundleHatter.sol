// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {IRoleBundleHatter} from "./interfaces/IRoleBundleHatter.sol";

/**
 * @notice Minimal interface for the Executor's hat-minting passthrough.
 */
interface IExecutorMint {
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
}

/**
 * @title RoleBundleHatter
 * @notice Holds role → capability-hat composition bundles. `mintRole(roleHat, user)`
 *         mints the role hat plus every capability hat in the role's bundle via the
 *         org's Executor (which holds top-hat admin authority in the Hats tree).
 *
 *         Bundle mutations (`setBundle`, `addToBundle`, `removeFromBundle`) are gated to
 *         the org's executor + a temporary bootstrap deployer (cleared after deploy).
 *         `mintRole` is gated by an `authorizedMinters` whitelist managed by the same
 *         admin path — typical entries: Executor (for governance grants), QuickJoin (for
 *         join-flow member-role mints), OrgDeployer (for initial backfill on org deploy).
 *
 *         Idempotent by design: `mintRole` skips capability hats the user already wears,
 *         so re-granting a role to the same wearer is a no-op.
 */
contract RoleBundleHatter is Initializable, IRoleBundleHatter {
    /* ─────────── Errors ─────────── */
    error NotAdmin();
    error NotAuthorizedMinter();
    error ZeroAddress();
    error ZeroHat();
    error SelfBundle();
    error AlreadyInBundle();
    error NotInBundle();
    error BundleTooLarge();
    error EligibilityModuleNotSet();
    error RevokeFailed();
    error EligibilityResetFailed();

    /* ─────────── Constants ─────────── */
    uint256 public constant MAX_BUNDLE_SIZE = 32;

    /* ─────────── ERC-7201 Storage ─────────── */
    /// @custom:storage-location erc7201:poa.rolebundlehatter.storage
    struct Layout {
        IHats hats; // Hats Protocol contract
        address executor; // org's Executor (governance entry point)
        address deployer; // temporary bootstrap admin; cleared after deploy
        mapping(uint256 => uint256[]) bundles; // roleHat → capability hat IDs
        mapping(uint256 => mapping(uint256 => bool)) inBundle; // roleHat → capabilityHat → present (O(1) dedup)
        mapping(address => bool) authorizedMinters; // whitelist for `mintRole` callers
        // ─── Revocation cascade support ───
        address eligibilityModule; // EligibilityModule for capability-hat revocation
        uint256[] roleHatsList; // Enumeration of every roleHat that has a bundle (for diff revoke)
        mapping(uint256 => bool) isTrackedRole; // O(1) check for "is in roleHatsList"
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.rolebundlehatter.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /* ─────────── Events ─────────── */
    event RoleBundleHatterInitialized(address indexed hats, address indexed executor, address indexed deployer);
    event DeployerCleared(address indexed clearedBy);
    event EligibilityModuleSet(address indexed eligibilityModule);
    event BundleSet(uint256 indexed roleHat, uint256[] capabilityHats);
    event BundleUpdated(uint256 indexed roleHat, uint256 indexed capabilityHat, bool added);
    event RoleMinted(uint256 indexed roleHat, address indexed user, uint256 hatsMinted);
    event RoleRevoked(uint256 indexed roleHat, address indexed user, uint256 capabilitiesRevoked);
    event AuthorizedMinterSet(address indexed minter, bool authorized);

    /* ─────────── Modifiers ─────────── */
    /// @dev Executor always allowed. Deployer allowed only until `clearDeployer` is called.
    modifier onlyAdmin() {
        Layout storage l = _layout();
        address sender = msg.sender;
        if (sender != l.executor && (l.deployer == address(0) || sender != l.deployer)) {
            revert NotAdmin();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ─────────── Initializer ─────────── */
    /**
     * @notice Initializes the per-org proxy. Called once at deploy time.
     * @param hats_ Hats Protocol address
     * @param executor_ Org's Executor contract (governance entry point)
     * @param deployer_ Bootstrap admin (typically OrgDeployer or HatsTreeSetup); can call admin
     *                  functions until `clearDeployer` is invoked.
     */
    function initialize(address hats_, address executor_, address deployer_) external initializer {
        if (hats_ == address(0) || executor_ == address(0) || deployer_ == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        l.hats = IHats(hats_);
        l.executor = executor_;
        l.deployer = deployer_;
        emit RoleBundleHatterInitialized(hats_, executor_, deployer_);
    }

    /**
     * @notice Clears the bootstrap deployer. After this call, only `executor` can mutate state.
     */
    function clearDeployer() external onlyAdmin {
        Layout storage l = _layout();
        address cleared = l.deployer;
        l.deployer = address(0);
        emit DeployerCleared(cleared);
    }

    /* ─────────── Bundle Management ─────────── */
    /**
     * @notice Replace a role's capability-hat bundle wholesale. Duplicates are silently deduped.
     * @param roleHat Role hat ID being configured
     * @param capabilityHats Array of capability hat IDs to set as the role's bundle
     */
    function setBundle(uint256 roleHat, uint256[] calldata capabilityHats) external onlyAdmin {
        if (roleHat == 0) revert ZeroHat();
        if (capabilityHats.length > MAX_BUNDLE_SIZE) revert BundleTooLarge();
        Layout storage l = _layout();

        // Clear existing `inBundle` flags for the old bundle, then drop the array
        uint256[] storage current = l.bundles[roleHat];
        uint256 oldLen = current.length;
        for (uint256 i; i < oldLen;) {
            l.inBundle[roleHat][current[i]] = false;
            unchecked {
                ++i;
            }
        }
        delete l.bundles[roleHat];

        // Add new entries (dedup against inBundle; skip zero and self-bundle entries)
        uint256 newLen = capabilityHats.length;
        for (uint256 i; i < newLen;) {
            uint256 cap = capabilityHats[i];
            if (cap == 0) revert ZeroHat();
            if (cap == roleHat) revert SelfBundle();
            if (!l.inBundle[roleHat][cap]) {
                l.bundles[roleHat].push(cap);
                l.inBundle[roleHat][cap] = true;
            }
            unchecked {
                ++i;
            }
        }

        // Track or untrack this role in the enumeration list (used by revokeRole for diff
        // computation). An empty bundle contributes nothing to revoke diffs, so we drop it
        // from the list to keep cascade-iteration bounded; a future setBundle re-tracks it.
        if (newLen == 0) {
            _untrackRole(l, roleHat);
        } else {
            _trackRole(l, roleHat);
        }

        emit BundleSet(roleHat, capabilityHats);
    }

    /// @dev Adds a role hat to the enumeration list if not already present. O(1).
    function _trackRole(Layout storage l, uint256 roleHat) internal {
        if (!l.isTrackedRole[roleHat]) {
            l.isTrackedRole[roleHat] = true;
            l.roleHatsList.push(roleHat);
        }
    }

    /// @dev Removes a role hat from the enumeration list via swap-and-pop. O(R) over the
    ///      tracked-role list. R is bounded by the org's role count (~5-10 in practice),
    ///      so this is cheap. Called only when a bundle is cleared via setBundle([]).
    function _untrackRole(Layout storage l, uint256 roleHat) internal {
        if (!l.isTrackedRole[roleHat]) return;
        l.isTrackedRole[roleHat] = false;
        uint256[] storage list = l.roleHatsList;
        uint256 len = list.length;
        for (uint256 i; i < len;) {
            if (list[i] == roleHat) {
                list[i] = list[len - 1];
                list.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Append a single capability hat to a role's bundle.
     * @dev Reverts if `capabilityHat` is zero (silent footgun: 0 means "disabled" in every
     *      gate, so it can't be in a bundle) or equals `roleHat` (would cause a double-mint
     *      on `mintRole`).
     */
    function addToBundle(uint256 roleHat, uint256 capabilityHat) external onlyAdmin {
        if (roleHat == 0) revert ZeroHat();
        if (capabilityHat == 0) revert ZeroHat();
        if (capabilityHat == roleHat) revert SelfBundle();
        Layout storage l = _layout();
        if (l.inBundle[roleHat][capabilityHat]) revert AlreadyInBundle();
        if (l.bundles[roleHat].length >= MAX_BUNDLE_SIZE) revert BundleTooLarge();
        l.bundles[roleHat].push(capabilityHat);
        l.inBundle[roleHat][capabilityHat] = true;
        _trackRole(l, roleHat);
        emit BundleUpdated(roleHat, capabilityHat, true);
    }

    /**
     * @notice Remove a capability hat from a role's bundle via swap-and-pop.
     *         If this drains the bundle to empty, the role is also untracked from the
     *         cascade enumeration list.
     */
    function removeFromBundle(uint256 roleHat, uint256 capabilityHat) external onlyAdmin {
        Layout storage l = _layout();
        if (!l.inBundle[roleHat][capabilityHat]) revert NotInBundle();

        uint256[] storage bundle = l.bundles[roleHat];
        uint256 len = bundle.length;
        for (uint256 i; i < len;) {
            if (bundle[i] == capabilityHat) {
                bundle[i] = bundle[len - 1];
                bundle.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        l.inBundle[roleHat][capabilityHat] = false;
        if (bundle.length == 0) _untrackRole(l, roleHat);
        emit BundleUpdated(roleHat, capabilityHat, false);
    }

    /* ─────────── Minter Authorization ─────────── */
    function setAuthorizedMinter(address minter, bool authorized) external onlyAdmin {
        if (minter == address(0)) revert ZeroAddress();
        _layout().authorizedMinters[minter] = authorized;
        emit AuthorizedMinterSet(minter, authorized);
    }

    /// @notice Wires the EligibilityModule address used for capability-hat revocation.
    ///         Without this set, `revokeRole` reverts. OrgDeployer wires this at deploy time;
    ///         post-deploy changes go through governance.
    function setEligibilityModule(address eligibilityModule_) external onlyAdmin {
        if (eligibilityModule_ == address(0)) revert ZeroAddress();
        _layout().eligibilityModule = eligibilityModule_;
        emit EligibilityModuleSet(eligibilityModule_);
    }

    /* ─────────── Mint Role ─────────── */
    /**
     * @notice Mints a role hat plus every capability hat in its bundle to `user`.
     *         Skips any hat `user` already wears (idempotent re-grant). For each hat
     *         about to be minted, eligibility is first reset to (true, true) on the
     *         EligibilityModule — this is required for the production code path because
     *         `Hats.mintHat` reverts with `NotEligible` if a prior cascade revoke left
     *         the user's eligibility flag at false. Without this reset, re-electing
     *         someone or re-granting a previously-revoked role would fail.
     *         Forwards minting through `Executor.mintHatsForUser`, which has top-hat
     *         admin authority in the org's Hats tree.
     * @param roleHat Role hat ID to grant
     * @param user Recipient address
     * @dev No reentrancy guard: the only external calls are
     *      `EligibilityModule.setWearerEligibility` (for the pre-mint reset) and
     *      `Executor.mintHatsForUser`, which calls `IHats.mintHat`. Neither invokes
     *      user-controlled callback hooks. All state writes happen before the externals.
     *      If the EligibilityModule is not set, the reset is skipped — works for fresh
     *      orgs that haven't wired the cascade yet (typical legacy deploys).
     */
    function mintRole(uint256 roleHat, address user) external {
        Layout storage l = _layout();
        if (!l.authorizedMinters[msg.sender]) revert NotAuthorizedMinter();
        if (user == address(0)) revert ZeroAddress();
        if (roleHat == 0) revert ZeroHat();

        IHats hats_ = l.hats;
        address executor_ = l.executor;
        uint256[] storage bundle = l.bundles[roleHat];
        uint256 bundleLen = bundle.length;

        // Allocate worst case (role hat + every capability), populate in place,
        // then trim the array length via assembly before forwarding. Saves one
        // allocation + copy compared to the two-pass approach.
        uint256[] memory toMint = new uint256[](bundleLen + 1);
        uint256 count = 0;

        if (!hats_.isWearerOfHat(user, roleHat)) {
            toMint[count] = roleHat;
            unchecked {
                ++count;
            }
        }

        for (uint256 i; i < bundleLen;) {
            uint256 cap = bundle[i];
            if (!hats_.isWearerOfHat(user, cap)) {
                toMint[count] = cap;
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (count > 0) {
            // Pre-mint eligibility reset. See the docstring for the production rationale.
            // Skipped entirely if no EligibilityModule is wired (legacy orgs) — those
            // can't have been cascade-revoked, so they can't hit the NotEligible path.
            address em = l.eligibilityModule;
            if (em != address(0)) {
                for (uint256 i; i < count;) {
                    // Only re-enable eligibility for a wearer who ALREADY has an explicit rule
                    // (e.g. a prior cascade-revoke wrote (false,false)). Wearers with no specific
                    // rule are left to the hat's DEFAULT eligibility, so an eligibility gate such as
                    // vouching (defaults.eligible=false) is not bypassed on a first-time mint. This
                    // still fixes re-mint-after-revoke (those wearers have a specific rule) and skips
                    // the wasted write for fresh wearers (the common case).
                    if (_hasSpecificEligibilityRule(em, user, toMint[i])) {
                        _setEligibilityTrue(em, user, toMint[i]);
                    }
                    unchecked {
                        ++i;
                    }
                }
            }

            // Truncate toMint.length to `count` in place. Safe: we only ever shrink,
            // never grow, so no stale data is exposed beyond the new length. Memory-safe
            // because we only modify the array header word, not the free memory pointer.
            /// @solidity memory-safe-assembly
            assembly {
                mstore(toMint, count)
            }
            IExecutorMint(executor_).mintHatsForUser(user, toMint);
        }

        emit RoleMinted(roleHat, user, count);
    }

    /// @dev True if the EligibilityModule already holds an explicit per-wearer rule for
    ///      (user, hatId). Scopes the pre-mint eligibility reset to wearers who were set
    ///      explicitly before (e.g. cascade-revoked), so the reset never overrides a
    ///      default-driven gate (such as vouching) for a fresh wearer.
    function _hasSpecificEligibilityRule(address em, address user, uint256 hatId) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            em.staticcall(abi.encodeWithSignature("hasSpecificWearerRules(address,uint256)", user, hatId));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev Internal helper to set a wearer's eligibility to true. Mirrors
    ///      `_setEligibilityFalse` but writes (true, true) so a `mintHat` call against
    ///      production Hats Protocol won't revert with `NotEligible`.
    function _setEligibilityTrue(address em, address user, uint256 hatId) internal {
        (bool ok, bytes memory ret) =
            em.call(abi.encodeWithSignature("setWearerEligibility(address,uint256,bool,bool)", user, hatId, true, true));
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            }
            revert EligibilityResetFailed();
        }
    }

    /* ─────────── Revoke Role (diff-based cascade) ─────────── */

    /**
     * @notice Revokes a role hat from `user` AND every capability hat in that role's bundle
     *         that is NOT also granted by another role `user` currently holds. This preserves
     *         capabilities inherited from other roles (e.g., losing VP but keeping Member's
     *         capabilities like `task.claim` and `vote`).
     *
     *         Caller must be in `authorizedMinters` (same whitelist as `mintRole`). Typically
     *         called from governance (the Executor) as part of an election's "demote loser" batch.
     *
     * @param roleHat Role hat ID to revoke from the user
     * @param user Address whose role is being revoked
     *
     * @dev Algorithm:
     *      1. Compute the "keep" set: union of capability hats in bundles for every OTHER role
     *         `user` currently wears (iterates `roleHatsList`, ~5 isWearerOfHat calls per org).
     *      2. Revoke `roleHat` itself via `EligibilityModule.setWearerEligibility`.
     *      3. For each capability in `roleHat`'s bundle that the user actually wears AND is not
     *         in the keep set, revoke via `setWearerEligibility(false, false)`.
     *
     *      Idempotent: if the user already doesn't wear the role hat, the eligibility-update
     *      is a no-op at the Hats layer (balanceOf already returns 0). Same for capability hats.
     *      No reentrancy guard needed: EligibilityModule.setWearerEligibility doesn't trigger
     *      any callback path back into this contract.
     */
    function revokeRole(uint256 roleHat, address user) external {
        Layout storage l = _layout();
        if (!l.authorizedMinters[msg.sender]) revert NotAuthorizedMinter();
        if (user == address(0)) revert ZeroAddress();
        if (roleHat == 0) revert ZeroHat();
        address em = l.eligibilityModule;
        if (em == address(0)) revert EligibilityModuleNotSet();

        // Revoke the role hat itself FIRST. After this, `isWearerOfHat(user, roleHat)`
        // returns false — but we never query it again, so the order is for symmetry only.
        _setEligibilityFalse(em, user, roleHat);

        // For each capability in the revoked role's bundle, revoke unless another role the
        // user still wears also grants it. Inner logic is in `_revokeCapsCascade` to keep
        // the default-profile (optimizer-off) compile under the stack-too-deep limit.
        uint256 revokedCount = _revokeCapsCascade(l, em, roleHat, user);

        emit RoleRevoked(roleHat, user, revokedCount);
    }

    /// @dev Iterates the bundle for `roleHat` and revokes each capability hat that no other
    ///      role the user wears also grants. Returns the number of capability hats revoked.
    function _revokeCapsCascade(Layout storage l, address em, uint256 roleHat, address user)
        internal
        returns (uint256 revokedCount)
    {
        IHats hats_ = l.hats;
        uint256[] storage bundle = l.bundles[roleHat];
        uint256 bundleLen = bundle.length;
        uint256[] storage roleList = l.roleHatsList;
        uint256 roleListLen = roleList.length;

        for (uint256 i; i < bundleLen;) {
            uint256 cap = bundle[i];
            if (!_capGrantedByOtherRole(l, hats_, roleList, roleListLen, roleHat, cap, user)) {
                if (hats_.isWearerOfHat(user, cap)) {
                    _setEligibilityFalse(em, user, cap);
                    unchecked {
                        ++revokedCount;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Returns true if any tracked role other than `roleHat` grants `cap` AND the user
    ///      still wears that role. Short-circuits on first match.
    function _capGrantedByOtherRole(
        Layout storage l,
        IHats hats_,
        uint256[] storage roleList,
        uint256 roleListLen,
        uint256 roleHat,
        uint256 cap,
        address user
    ) internal view returns (bool) {
        for (uint256 j; j < roleListLen;) {
            uint256 otherRole = roleList[j];
            if (otherRole != roleHat && l.inBundle[otherRole][cap] && hats_.isWearerOfHat(user, otherRole)) {
                return true;
            }
            unchecked {
                ++j;
            }
        }
        return false;
    }

    /// @dev Internal helper to set a wearer's eligibility to false. Bubbles up any revert
    ///      reason from EligibilityModule (typically a permission error).
    function _setEligibilityFalse(address em, address user, uint256 hatId) internal {
        (bool ok, bytes memory ret) = em.call(
            abi.encodeWithSignature("setWearerEligibility(address,uint256,bool,bool)", user, hatId, false, false)
        );
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            }
            revert RevokeFailed();
        }
    }

    /* ─────────── Views ─────────── */
    function getBundle(uint256 roleHat) external view returns (uint256[] memory) {
        return _layout().bundles[roleHat];
    }

    function bundleSize(uint256 roleHat) external view returns (uint256) {
        return _layout().bundles[roleHat].length;
    }

    function isInBundle(uint256 roleHat, uint256 capabilityHat) external view returns (bool) {
        return _layout().inBundle[roleHat][capabilityHat];
    }

    function isAuthorizedMinter(address minter) external view returns (bool) {
        return _layout().authorizedMinters[minter];
    }

    function executor() external view returns (address) {
        return _layout().executor;
    }

    function deployer() external view returns (address) {
        return _layout().deployer;
    }

    function hats() external view returns (address) {
        return address(_layout().hats);
    }

    function eligibilityModule() external view returns (address) {
        return _layout().eligibilityModule;
    }

    /// @notice Returns the count of role hats currently tracked for revocation cascade.
    ///         A role hat is tracked the first time `setBundle` or `addToBundle` is called for it.
    function trackedRoleCount() external view returns (uint256) {
        return _layout().roleHatsList.length;
    }

    /// @notice Returns the tracked role hat ID at the given index.
    function trackedRoleAt(uint256 index) external view returns (uint256) {
        return _layout().roleHatsList[index];
    }
}
