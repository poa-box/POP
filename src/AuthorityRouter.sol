// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IAuthorityRouter} from "./interfaces/IAuthorityRouter.sol";

/// @notice Minimal OrgRegistry read surface the router consumes for the bind gate (ACCESS-V2-SPEC.md
///         §5). Matches the concrete `OrgRegistry` getters on this branch verbatim: `orgOf` (executor
///         lookup) and `getTopHat` (recorded topHat-domain source).
interface IOrgRegistryRouter {
    function orgOf(bytes32 orgId)
        external
        view
        returns (address executor, uint32 contractCount, bool bootstrap, bool exists);
    function getTopHat(bytes32 orgId) external view returns (uint256);
}

/// @notice The IHats read subset the router relays to for passthrough ids. Selectors are
///         byte-identical to the served subset, so native-authority ids can be forwarded with the
///         same calldata. `getWearerStatus` is absent from IHats — passthrough composes it from
///         `isEligible` + `isInGoodStanding`.
interface IHatsRouter {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
    function isInGoodStanding(address wearer, uint256 hatId) external view returns (bool);
    function balanceOf(address wearer, uint256 hatId) external view returns (uint256);
    function checkHatWearerStatus(uint256 hatId, address wearer) external returns (bool);
    function viewHat(uint256 hatId)
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

/// @title AuthorityRouter
/// @notice Protocol-owned singleton implementing the TOTAL CLASSIFICATION PREDICATE + revert-wrapping
///         of ACCESS-V2-SPEC.md §5 / ACCESS-V2-INTERFACES.md §2 (+ ruling R5). Chain-wide readers
///         (PaymasterHub.hats) point here; the router classifies every id structurally and dispatches
///         to the bound org authority, a self-routing v2 authority, real Hats passthrough, or empty
///         resolution — no adversarial id can cross arms.
/// @dev ERC-7201 namespaced storage at `keccak256("poa.authorityrouter.storage")` (freeze §0 idiom,
///      v1 direct-slot convention). Append-only Layout. `_disableInitializers` in the constructor.
contract AuthorityRouter is Initializable, IAuthorityRouter {
    /*═══════════════════════════════ Constants (freeze §5.1) ═══════════════════════════════*/

    /// @notice Legacy/Hats-namespace floor: every real Hats id embeds a nonzero tophat domain in bits
    ///         224–255, so every legacy id ≥ 2^224 (Hats.sol tophat domain).
    uint256 internal constant HATS_NAMESPACE_FLOOR = 1 << 224;

    /// @notice v2 id shape: `(uint160(authority) << 64) | localSeq`; the embedded authority occupies
    ///         bits 64..223 (freeze §5.1 `AUTHORITY_ADDR_SHIFT`).
    uint256 internal constant AUTHORITY_ADDR_SHIFT = 64;

    /// @notice tophat-domain shift (bits 224..255 hold the domain).
    uint256 internal constant TOPHAT_DOMAIN_SHIFT = 224;

    /*═══════════════════════════════ ERC-7201 storage ═══════════════════════════════*/

    /// @custom:storage-location erc7201:poa.authorityrouter.storage
    struct Layout {
        address hats; // real Hats (passthrough arm)
        address orgRegistry; // bind-gate Executor-verification source
        address paymasterHub; // revert-wrap branch (msg.sender == hub)
        address admin; // protocol admin (pointer maintenance)
        mapping(uint256 => address) authorityByDomain; // legacy topHat domain (id >> 224) → bound authority
        mapping(uint256 => bytes32) orgIdByDomain; // domain → orgId that bound it (unbind bookkeeping)
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.authorityrouter.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═══════════════════════════════ Routing arms ═══════════════════════════════*/

    enum Arm {
        Native, // dispatch to `target` authority; `alwaysEmptyOnFail` distinguishes v2 vs bound
        Passthrough, // dispatch to real Hats
        ForcedEmpty // codeless v2-embedded id → resolve empty without any call
    }

    /*═══════════════════════════════ Constructor ═══════════════════════════════*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*═══════════════════════════════ Initialize / config ═══════════════════════════════*/

    /// @inheritdoc IAuthorityRouter
    function initialize(address hats_, address orgRegistry_, address paymasterHub_, address admin_)
        external
        initializer
    {
        if (hats_ == address(0) || orgRegistry_ == address(0) || paymasterHub_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        Layout storage l = _layout();
        l.hats = hats_;
        l.orgRegistry = orgRegistry_;
        l.paymasterHub = paymasterHub_;
        l.admin = admin_;

        emit RouterInitialized(hats_, orgRegistry_, admin_);
        emit PaymasterHubSet(paymasterHub_); // mirror the setter (subgraph initialize-mirror rule)
    }

    /// @inheritdoc IAuthorityRouter
    function setPaymasterHub(address paymasterHub_) external {
        Layout storage l = _layout();
        if (msg.sender != l.admin) revert NotAdmin();
        if (paymasterHub_ == address(0)) revert ZeroAddress();
        l.paymasterHub = paymasterHub_;
        emit PaymasterHubSet(paymasterHub_);
    }

    function hats() external view returns (address) {
        return _layout().hats;
    }

    function orgRegistry() external view returns (address) {
        return _layout().orgRegistry;
    }

    function paymasterHub() external view returns (address) {
        return _layout().paymasterHub;
    }

    function admin() external view returns (address) {
        return _layout().admin;
    }

    /*═══════════════════════════════ Binding surface ═══════════════════════════════*/

    /// @inheritdoc IAuthorityRouter
    /// @dev `topHatDomain` is the value carried in bits 224–255 of the org's adopted legacy ids —
    ///      i.e. `topHatId >> 224` (freeze §2 "bits 224–255"). Verified equal to the org's recorded
    ///      topHat's domain via OrgRegistry.getTopHat; the caller must be the org's Executor.
    function bindAuthority(bytes32 orgId, uint256 topHatDomain, address authority) external {
        if (authority == address(0)) revert ZeroAddress();
        Layout storage l = _layout();

        (address executor,,, bool exists) = IOrgRegistryRouter(l.orgRegistry).orgOf(orgId);
        if (!exists || msg.sender != executor) revert NotOrgExecutor();

        uint256 recordedDomain = IOrgRegistryRouter(l.orgRegistry).getTopHat(orgId) >> TOPHAT_DOMAIN_SHIFT;
        if (recordedDomain == 0 || topHatDomain != recordedDomain) revert TopHatDomainMismatch();

        if (l.authorityByDomain[topHatDomain] != address(0)) revert AlreadyBound();

        l.authorityByDomain[topHatDomain] = authority;
        l.orgIdByDomain[topHatDomain] = orgId;
        emit AuthorityBound(orgId, topHatDomain, authority);
    }

    /// @inheritdoc IAuthorityRouter
    function unbindAuthority(bytes32 orgId, uint256 topHatDomain) external {
        Layout storage l = _layout();

        (address executor,,, bool exists) = IOrgRegistryRouter(l.orgRegistry).orgOf(orgId);
        if (!exists || msg.sender != executor) revert NotOrgExecutor();

        uint256 recordedDomain = IOrgRegistryRouter(l.orgRegistry).getTopHat(orgId) >> TOPHAT_DOMAIN_SHIFT;
        if (recordedDomain == 0 || topHatDomain != recordedDomain) revert TopHatDomainMismatch();

        address bound = l.authorityByDomain[topHatDomain];
        if (bound == address(0)) revert NotBound();

        delete l.authorityByDomain[topHatDomain];
        delete l.orgIdByDomain[topHatDomain];
        emit AuthorityUnbound(orgId, topHatDomain, bound);
    }

    /// @inheritdoc IAuthorityRouter
    function authorityOf(uint256 id) external view returns (address) {
        if (id >= HATS_NAMESPACE_FLOOR) {
            return _layout().authorityByDomain[id >> TOPHAT_DOMAIN_SHIFT];
        }
        return address(0);
    }

    /*═══════════════════════════════ Classification predicate ═══════════════════════════════*/

    /// @notice The TOTAL structural classifier (freeze §2 table). Pure bit test — no adversarial id
    ///         can cross arms.
    /// @return arm the routing arm
    /// @return target the dispatch target (authority or Hats; unused for ForcedEmpty)
    /// @return alwaysEmptyOnFail true for self-routing v2 authorities (a call failure resolves EMPTY
    ///         for EVERY caller — the structural predicate); false for legacy-bound authorities and
    ///         passthrough (a call failure resolves empty ONLY for the hub, else propagates).
    function _classify(uint256 id) internal view returns (Arm arm, address target, bool alwaysEmptyOnFail) {
        if (id >= HATS_NAMESPACE_FLOOR) {
            // Legacy/Hats namespace.
            address bound = _layout().authorityByDomain[id >> TOPHAT_DOMAIN_SHIFT];
            if (bound != address(0)) return (Arm.Native, bound, false); // bound → org authority
            return (Arm.Passthrough, _layout().hats, false); // unbound → real Hats (safe zeros)
        }
        // id < 2^224: check bits 64..223 for an embedded authority address.
        address embedded = address(uint160(id >> AUTHORITY_ADDR_SHIFT));
        if (embedded == address(0)) {
            // No embedded address (incl. any id < 2^64) → not a v2 id → passthrough safe zeros.
            return (Arm.Passthrough, _layout().hats, false);
        }
        // v2 embedded-address namespace.
        if (embedded.code.length == 0) {
            return (Arm.ForcedEmpty, address(0), true); // codeless → EMPTY resolution
        }
        return (Arm.Native, embedded, true); // self-route; malformed/reverting → EMPTY (all callers)
    }

    /// @notice Execute a read-only relay against the classified target, applying the empty-resolution
    ///         and hub-wrapping policy. Returns `empty=true` when the caller should synthesize a zeroed
    ///         result; otherwise `ret` is the (length-checked) success returndata. Propagates a genuine
    ///         revert only for a non-hub caller on a legacy-bound / passthrough arm.
    function _relayView(uint256 id, bytes memory data, uint256 minRetLen)
        internal
        view
        returns (bytes memory ret, bool empty)
    {
        (Arm arm, address target, bool alwaysEmptyOnFail) = _classify(id);
        if (arm == Arm.ForcedEmpty) return (ret, true);

        (bool ok, bytes memory r) = target.staticcall(data);
        if (ok && r.length >= minRetLen) return (r, false); // success

        // Failure (revert) or malformed/short returndata.
        // Malformed-but-ok is always resolved empty (no revert data to bubble). A genuine revert is
        // resolved empty for v2 self-routes (structural) and for the hub (wrapping); otherwise it
        // propagates honestly.
        if (ok || alwaysEmptyOnFail || msg.sender == _layout().paymasterHub) return (ret, true);
        assembly {
            revert(add(r, 0x20), mload(r))
        }
    }

    /*═══════════════════════════════ Served IHats read subset ═══════════════════════════════*/

    /// @inheritdoc IAuthorityRouter
    function isWearerOfHat(address user, uint256 id) external view returns (bool) {
        (bytes memory ret, bool empty) =
            _relayView(id, abi.encodeWithSelector(IHatsRouter.isWearerOfHat.selector, user, id), 32);
        if (empty) return false;
        return abi.decode(ret, (bool));
    }

    /// @inheritdoc IAuthorityRouter
    function isEligible(address user, uint256 id) external view returns (bool) {
        (bytes memory ret, bool empty) =
            _relayView(id, abi.encodeWithSelector(IHatsRouter.isEligible.selector, user, id), 32);
        if (empty) return false;
        return abi.decode(ret, (bool));
    }

    /// @inheritdoc IAuthorityRouter
    function balanceOf(address user, uint256 id) external view returns (uint256) {
        return _singleBalance(user, id);
    }

    function _singleBalance(address user, uint256 id) internal view returns (uint256) {
        (bytes memory ret, bool empty) =
            _relayView(id, abi.encodeWithSelector(IHatsRouter.balanceOf.selector, user, id), 32);
        if (empty) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @inheritdoc IAuthorityRouter
    /// @dev Each element is classified independently (a batch may span orgs / passthrough / empty), so
    ///      the batch is resolved per-id rather than blind-forwarded.
    function balanceOfBatch(address[] calldata users, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory balances)
    {
        if (users.length != ids.length) revert ArrayLengthMismatchRouter();
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            balances[i] = _singleBalance(users[i], ids[i]);
        }
    }

    /// @notice batch length guard (internal — not part of the frozen error surface, so kept distinct
    ///         from the IHats/authority `ArrayLengthMismatch`).
    error ArrayLengthMismatchRouter();

    /// @inheritdoc IAuthorityRouter
    /// @dev IHats has no `getWearerStatus`; passthrough composes it from `isEligible` +
    ///      `isInGoodStanding`. Native authorities expose the selector directly.
    function getWearerStatus(address wearer, uint256 id) external view returns (bool eligible, bool standing) {
        (Arm arm, address target, bool alwaysEmptyOnFail) = _classify(id);
        if (arm == Arm.ForcedEmpty) return (false, false);

        if (arm == Arm.Native) {
            (bool ok, bytes memory r) =
                target.staticcall(abi.encodeWithSelector(IAuthorityRouter.getWearerStatus.selector, wearer, id));
            if (ok && r.length >= 64) return abi.decode(r, (bool, bool));
            if (ok || alwaysEmptyOnFail || msg.sender == _layout().paymasterHub) return (false, false);
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }

        // Passthrough: compose from Hats' two views.
        eligible = _passthroughBool(target, abi.encodeWithSelector(IHatsRouter.isEligible.selector, wearer, id));
        standing = _passthroughBool(target, abi.encodeWithSelector(IHatsRouter.isInGoodStanding.selector, wearer, id));
    }

    /// @notice Passthrough bool read with hub-wrapping (used by getWearerStatus's composed arm).
    function _passthroughBool(address target, bytes memory data) internal view returns (bool) {
        (bool ok, bytes memory r) = target.staticcall(data);
        if (ok && r.length >= 32) return abi.decode(r, (bool));
        if (ok || msg.sender == _layout().paymasterHub) return false;
        assembly {
            revert(add(r, 0x20), mload(r))
        }
    }

    /// @inheritdoc IAuthorityRouter
    /// @dev RULING R5: passthrough uses CALL (not STATICCALL) because real Hats' checkHatWearerStatus
    ///      is state-mutating (it may burn a lapsed wearer's hat). Native authorities implement the
    ///      constant-true no-op. ForcedEmpty ids resolve `false`. Hub-wrapping + honest propagation
    ///      mirror the view relay.
    function checkHatWearerStatus(uint256 id, address user) external returns (bool) {
        (Arm arm, address target, bool alwaysEmptyOnFail) = _classify(id);
        if (arm == Arm.ForcedEmpty) return false;

        (bool ok, bytes memory r) =
            target.call(abi.encodeWithSelector(IHatsRouter.checkHatWearerStatus.selector, id, user));
        if (ok && r.length >= 32) return abi.decode(r, (bool));
        if (ok || alwaysEmptyOnFail || msg.sender == _layout().paymasterHub) return false;
        assembly {
            revert(add(r, 0x20), mload(r))
        }
    }

    /// @inheritdoc IAuthorityRouter
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
        (bytes memory ret, bool empty) = _relayView(id, abi.encodeWithSelector(IHatsRouter.viewHat.selector, id), 288);
        if (empty) return ("", 0, 0, address(0), address(0), "", 0, false, false);

        // Guard against malformed dynamic returndata from a rogue self-routing authority: decode via a
        // catchable external self-call so a crafted-offset payload resolves EMPTY, never a router
        // revert on this hub-served selector.
        try this.decodeHat(ret) returns (
            string memory d, uint32 mx, uint32 sp, address el, address tg, string memory iu, uint16 lh, bool mu, bool ac
        ) {
            return (d, mx, sp, el, tg, iu, lh, mu, ac);
        } catch {
            return ("", 0, 0, address(0), address(0), "", 0, false, false);
        }
    }

    /// @notice External ABI-decode helper for {viewHat} (enables a try/catch malformed-data guard).
    ///         Not part of the frozen surface; callable by anyone but pure and side-effect free.
    function decodeHat(bytes calldata ret)
        external
        pure
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
        return abi.decode(ret, (string, uint32, uint32, address, address, string, uint16, bool, bool));
    }
}
