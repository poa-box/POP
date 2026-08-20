// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @title IAuthorityRouter
/// @notice Protocol-owned singleton the chain-wide readers (PaymasterHub.hats, any shared reader)
///         point to. Per-org authorities cannot answer a chain-wide pointer, so the router classifies
///         every id and dispatches (ACCESS-V2-SPEC.md §5 / ACCESS-V2-INTERFACES.md §2).
///
/// TOTAL CLASSIFICATION PREDICATE (structural bit test — no adversarial id can cross arms):
///   • id ≥ 2^224 (legacy/Hats namespace):
///       BOUND   → the org's authority (bind verified against the org's recorded topHat domain).
///       UNBOUND → view-only generic PASSTHROUGH to real Hats (writes revert). A real foreign hat
///                 answers from Hats; an id Hats never minted bottoms out in Hats' own SAFE ZEROS.
///   • id < 2^224 with bits 64..223 == 0 (no embedded address, incl. any id < 2^64):
///       NOT a v2 id → PASSTHROUGH to Hats (which holds nothing below 2^224 — SAFE ZEROS).
///   • id < 2^224 with bits 64..223 != 0 (v2 embedded-address namespace):
///       address WITH code → self-route (staticcall to the embedded authority).
///       address with NO code, or malformed/empty returndata → resolve EMPTY (isEligible=false,
///       isWearerOfHat=false, balanceOf=0, viewHat inactive/zeroed) — NEVER passthrough to Hats,
///       NEVER a revert on the hub-consumed selectors.
///
/// DEGENERATE-INPUT BEHAVIOR TABLE (differential-tested, §5):
/// | id shape                              | resolution                                  |
/// |---------------------------------------|---------------------------------------------|
/// | ≥ 2^224, bound                        | org authority (native)                      |
/// | ≥ 2^224, unbound, real foreign hat    | Hats passthrough (its real state)           |
/// | ≥ 2^224, unbound, never-minted        | Hats safe zeros                             |
/// | < 2^64 (garbage low id)               | Hats safe zeros (passthrough, holds nothing)|
/// | < 2^224, embedded addr, code present  | embedded authority (self-route)             |
/// | < 2^224, embedded addr, NO code       | EMPTY resolution (false/0/inactive)         |
/// | < 2^224, embedded addr, malformed ret | EMPTY resolution (never revert on hub reads)|
///
/// REVERT WRAPPING lives HERE, branched on `msg.sender == PaymasterHub` (hub validation code stays
/// UNCHANGED): inside hub validation a reverting foreign id is wrapped so it cannot brick
/// validateUserOp; every OTHER caller gets honest revert propagation. Wrap-everywhere (masks faults)
/// and wrap-nowhere (brickable validation) are both non-conforming.
interface IAuthorityRouter {
    /*────────────────── Errors ──────────────────*/
    error NotOrgExecutor(); // bind/unbind caller is not the org's Executor (via OrgRegistry)
    error TopHatDomainMismatch(); // claimed ids don't carry the org's recorded topHatId in bits 224–255
    error AlreadyBound();
    error NotBound();
    error ZeroAddress();
    error NotAdmin(); // config setter caller is not the protocol admin
    error WriteToPassthrough(); // a mutating IHats selector reached the passthrough arm

    /*────────────────── Events ──────────────────*/
    event RouterInitialized(address indexed hats, address indexed orgRegistry, address indexed admin);
    event PaymasterHubSet(address indexed paymasterHub); // mirrored in initialize (subgraph rule)
    event AuthorityBound(bytes32 indexed orgId, uint256 indexed topHatDomain, address indexed authority);
    event AuthorityUnbound(bytes32 indexed orgId, uint256 indexed topHatDomain, address indexed authority);

    /*────────────────── Initialize / protocol config (beacon-proxied singleton) ──────────────────*/

    /// @notice One-time proxy initializer wiring the router's three documented dependencies:
    ///         `hats_` (real Hats, the passthrough arm), `orgRegistry_` (the bind gate's
    ///         Executor-verification source), `paymasterHub_` (the msg.sender revert-wrap branch),
    ///         and `admin_` (poaManager/protocolAdmin, for pointer maintenance). Emits
    ///         RouterInitialized + PaymasterHubSet. Zero bindings at birth (pure passthrough — the
    ///         §6 step-0.5 precondition).
    /// @dev AUTH: OZ `initializer`; impl constructor calls _disableInitializers (hard rule).
    ///      Reverts {ZeroAddress} on any zero arg.
    function initialize(address hats_, address orgRegistry_, address paymasterHub_, address admin_) external;

    /// @notice Repoint the revert-wrap branch if the hub proxy address ever changes. Hats and
    ///         OrgRegistry have NO setters (Hats v1 is immutable; OrgRegistry is a stable proxy) —
    ///         [MICRO-CHOICE: one maintenance lever, not three]. Emits PaymasterHubSet.
    /// @dev AUTH: admin ({NotAdmin}).
    function setPaymasterHub(address paymasterHub_) external;

    function hats() external view returns (address);
    function orgRegistry() external view returns (address);
    function paymasterHub() external view returns (address);
    function admin() external view returns (address);

    /*────────────────── Binding surface (OrgRegistry-gated, §5) ──────────────────*/

    /// @notice Bind an org's adopted legacy-id RANGE (its topHat domain, bits 224–255) to `authority`.
    ///         The router verifies on-chain via OrgRegistry that msg.sender is the org's Executor AND
    ///         that the claimed domain matches the org's recorded topHatId — NO self-service binding.
    /// @dev AUTH: the org's Executor through OrgRegistry. NEW-STYLE ids self-route and need NO bind.
    function bindAuthority(bytes32 orgId, uint256 topHatDomain, address authority) external;

    /// @notice De-register a binding (rollback path, §6) — same Executor-through-OrgRegistry gate.
    function unbindAuthority(bytes32 orgId, uint256 topHatDomain) external;

    /// @notice The authority bound to a legacy id's topHat domain (address(0) if unbound).
    function authorityOf(uint256 id) external view returns (address);

    /*────────────────── Served IHats read subset (§5) ──────────────────*/
    // Every selector routes via the classification predicate above.
    function isWearerOfHat(address user, uint256 id) external view returns (bool);
    function isEligible(address user, uint256 id) external view returns (bool);
    function balanceOf(address user, uint256 id) external view returns (uint256);
    function balanceOfBatch(address[] calldata users, uint256[] calldata ids) external view returns (uint256[] memory);
    function getWearerStatus(address wearer, uint256 id) external view returns (bool eligible, bool standing);

    /// @notice IHats-parity toggle probe (§5). DEVIATION (freeze §2 declared this `view`): per RULING
    ///         R5 the passthrough arm uses CALL (not STATICCALL) — real Hats' checkHatWearerStatus is
    ///         state-mutating (it may burn a lapsed wearer's hat), which a `view` function cannot
    ///         express in Solidity. Declared non-view here so the passthrough CALL compiles; the
    ///         4-byte selector is identical to the frozen `view` form, so the on-chain ABI is
    ///         unchanged. The native-authority arm resolves the constant-true no-op.
    function checkHatWearerStatus(uint256 id, address user) external returns (bool);

    /// @notice Nine-field viewHat (§5). GROUP ids: supply=0; bound v2 ids answer from the authority;
    ///         passthrough ids answer from real Hats; empty-resolution ids return zeroed/inactive.
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
        );
}
