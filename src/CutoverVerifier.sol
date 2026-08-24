// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IAuthorityRouter} from "./interfaces/IAuthorityRouter.sol";

/// @dev Canonical Hats supply read — the enumeration-INDEPENDENT upper bound on ported members.
interface IHatsSupply {
    function hatSupply(uint256 hatId) external view returns (uint32 supply);
}

/// @dev OrgRegistry: resolve an org's Executor (the sole admin/topHat wearer) from its orgId.
interface IOrgRegistryExecutor {
    function orgOf(bytes32 orgId)
        external
        view
        returns (address executor, uint32 contractCount, bool bootstrap, bool exists);
}

/// @dev The two authority reads this verifier consumes directly.
interface IMembershipAuthorityCutover {
    function paused() external view returns (bool);
    function memberCount(uint256 subject) external view returns (uint256);
}

/// @title CutoverVerifier
/// @notice STATELESS, plain (non-upgradeable, ZERO storage) verifier for the Access-v2 per-org cutover
///         ceremony (ACCESS-V2-SPEC.md §6 step 3). Intended as the LAST call of the cutover Executor
///         batch: a single view-revert entrypoint {verify} that `require()`s the whole post-cutover
///         invariant set. Because the Executor runs batch calls sequentially and bubbles a revert, a
///         FAILED check reverts the ENTIRE batch (nothing half-lands) — enforcing on-chain the
///         regenerate-before-cutover discipline (the generation-time member counts are baked into the
///         batch as `expectedCounts`; any drift between generation and announceWinner reverts).
/// @dev No proxy, no initializer: `hats` and `orgRegistry` are protocol-wide per-chain constants pinned
///      as IMMUTABLES at deploy (bytecode, not storage). The router is passed per-call (it is the value
///      the cutover batch just bound through), and every check cross-verifies it. Loud custom errors,
///      one per check (SPEC §6: "reverts the batch loudly instead of bricking hub sponsorship").
contract CutoverVerifier {
    /*═══════════════════════════════ Immutables (zero storage) ═══════════════════════════════*/

    /// @notice Canonical Hats v1 (the enumeration-independent supply source).
    address public immutable hats;
    /// @notice OrgRegistry (the org → Executor resolution source).
    address public immutable orgRegistry;

    /*═══════════════════════════════ Errors (one per check) ═══════════════════════════════*/

    error NoSubjects();
    error ArrayLengthMismatch();
    error OrgNotRegistered(bytes32 orgId);
    /// (a) router.authorityOf(subject) != authority — a missing or spoofed bind.
    error AuthorityNotBound(uint256 subject, address expected, address actual);
    /// (b) authority still paused after the cutover unpause.
    error AuthorityPaused();
    /// (c1) authority.memberCount(subject) != the generation-time expected count (seed→cutover drift).
    error MemberCountDrift(uint256 subject, uint256 expected, uint256 actual);
    /// (c2) memberCount exceeds the canonical Hats supply (the self-referential-parity guard).
    error MemberCountExceedsSupply(uint256 subject, uint256 memberCount, uint32 hatSupply);
    /// (d1) the admin (topHat) id does not resolve to the org Executor THROUGH THE ROUTER.
    error AdminNotResolved(uint256 adminSubject, address executor);
    /// (d2) the admin (topHat) hat is not active through the router (viewHat.active == false).
    error AdminHatInactive(uint256 adminSubject);

    constructor(address hats_, address orgRegistry_) {
        hats = hats_;
        orgRegistry = orgRegistry_;
    }

    /*═══════════════════════════════ Verify ═══════════════════════════════*/

    /// @notice Assert the full §6 cutover invariant set. Reverts (view) on any failure; returns nothing
    ///         on success. `subjects[0]` MUST be the org's admin (topHat) id.
    /// @param orgId          the org's canonical id (OrgRegistry key).
    /// @param authority      the org's MembershipAuthority proxy (the just-bound target).
    /// @param router         the protocol AuthorityRouter singleton (the just-bound-through router).
    /// @param subjects       adopted subject ids to verify; index 0 = the admin (topHat) id.
    /// @param expectedCounts generation-time memberCount per subject (index-aligned with `subjects`).
    function verify(
        bytes32 orgId,
        address authority,
        address router,
        uint256[] calldata subjects,
        uint32[] calldata expectedCounts
    ) external view {
        uint256 n = subjects.length;
        if (n == 0) revert NoSubjects();
        if (expectedCounts.length != n) revert ArrayLengthMismatch();

        // (b) the authority must be UNPAUSED post-cutover (writes live again).
        if (IMembershipAuthorityCutover(authority).paused()) revert AuthorityPaused();

        for (uint256 i; i < n;) {
            uint256 subject = subjects[i];

            // (a) the bind landed with no spoof: the router routes this id to THIS authority.
            address bound = IAuthorityRouter(router).authorityOf(subject);
            if (bound != authority) revert AuthorityNotBound(subject, authority, bound);

            // (c) memberCount == the generation-time count AND <= canonical Hats supply.
            uint256 mc = IMembershipAuthorityCutover(authority).memberCount(subject);
            if (mc != expectedCounts[i]) revert MemberCountDrift(subject, expectedCounts[i], mc);
            uint32 supply = IHatsSupply(hats).hatSupply(subject);
            if (mc > supply) revert MemberCountExceedsSupply(subject, mc, supply);

            unchecked {
                ++i;
            }
        }

        // (d) router-through resolution of the ADMIN (topHat) id: the org Executor wears it AND the
        //     hat is active — proves the bind serves the hub org-admin surface, not just storage.
        (address executor,,, bool exists) = IOrgRegistryExecutor(orgRegistry).orgOf(orgId);
        if (!exists) revert OrgNotRegistered(orgId);
        uint256 adminSubject = subjects[0];
        if (!IAuthorityRouter(router).isWearerOfHat(executor, adminSubject)) {
            revert AdminNotResolved(adminSubject, executor);
        }
        (,,,,,,,, bool active) = IAuthorityRouter(router).viewHat(adminSubject);
        if (!active) revert AdminHatInactive(adminSubject);
    }
}
