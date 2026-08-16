// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────── OpenZeppelin v5.3 Upgradeables ────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/*──────── External interfaces / libs ────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";
import {IRoleManager} from "./interfaces/IRoleManager.sol";
// Minimal module-call interfaces + the wiring fan-out bodies live in the delegatecall library so both
// contracts share ONE declaration of each interface type (no divergence) and RoleManager stays under
// the EIP-170 runtime limit.
import {IEligibilityModuleRM, RoleManagerLogic} from "./libs/RoleManagerLogic.sol";

/*════════════════════════════════ RoleManager ════════════════════════════════*/
/// @title RoleManager – first-class named roles & role groups, orchestrated via governance.
/// @notice Scoped orchestrator (never superAdmin). Creates identity/marker hats through the
///         EligibilityModule, fans permission changes out to the org's sibling modules and drives
///         the consent-safe grant/offer flow. Structural mutations (create/wiring/group edits/config)
///         are `onlyExecutor`; only `grantRole`/`revokeRole` may additionally be called by a
///         manager-hat wearer with the matching capability (W13 delegated lifecycle), and even then
///         governance-owned EligibilityModule rules stay untouchable (provenance-guarded).
contract RoleManager is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable, IRoleManager {
    /*────────── Constants ─────────*/
    bytes4 public constant MODULE_ID = 0x524f4c45; /* "ROLE" */

    /// @notice Delegation capability bits (bitmask, separable). See {ManagerConfig}.
    uint8 public constant CAP_GRANT = 1;
    uint8 public constant CAP_REVOKE = 2;

    // Provenance flag masks on an EligibilityModule per-wearer rule (W12 `getWearerRuleFlags`):
    // bit0 eligible, bit1 standing (0x03 == fully eligible (true,true)); bit2 0x04 == DELEGATION_MANAGED.
    uint8 private constant FLAG_ELIGIBLE_STANDING = 0x03;
    uint8 private constant FLAG_DELEGATION_MANAGED = 0x04;

    /*────────── Errors ─────────*/
    error ZeroAddress();
    error NotExecutor();
    error ArrayLengthMismatch();
    error UnknownRole();
    error UnknownGroup();
    error AlreadyInGroup();
    error NotInGroup();
    error RevokeIneffective();
    error WiringIncompatible();
    error HatAlreadyRegistered();
    error MarkerAlreadyRegistered();
    error NotAuthorizedManager();
    error SelfManagedGroup();
    error GrantBlockedByGovernanceBan();
    // A delegated revoke may not clear a governance-written (true,true) rule (unclaimed offer / grant)
    // — those lack the 0x04 provenance bit. INTERNAL error (not in the frozen 3); reported as a
    // deviation. DELEGATION.md FIX 1 requires the refusal but INTERFACES.md did not name it.
    error RevokeBlockedByGovernance();

    /*────────── ERC-7201 Storage ─────────*/
    /// @custom:storage-location erc7201:poa.rolemanager.storage
    struct Layout {
        // module wiring
        address executor;
        address eligibilityModule;
        IHats hats;
        address ddVoting;
        address hybridVoting;
        address taskManager;
        address participationToken;
        address educationHub;
        address quickJoin;
        address paymasterHub;
        bytes32 orgId;
        // org membership set (role + member hats)
        uint256[] orgHats;
        // roles
        uint256 roleCount;
        mapping(uint256 => RoleInfo) roles; // roleId (1-based) => role
        mapping(uint256 => uint256) roleIdOfHat; // hatId => roleId
        mapping(uint256 => uint256[]) roleGroupIds; // roleId => group ids it belongs to
        // groups
        uint256 groupCount;
        mapping(uint256 => GroupInfo) groups; // groupId (1-based) => group
        mapping(uint256 => uint256) groupIdOfMarker; // marker hatId => groupId (one-to-one with groups)
        // delegation configs (W13 appends — MUST stay byte-identical with {RoleManagerLogic.Layout})
        mapping(uint256 => ManagerConfig) roleManagerConfigs; // roleId => manager-hat delegation config
        mapping(uint256 => ManagerConfig) groupManagerConfigs; // groupId => manager-hat delegation config
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.rolemanager.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*────────── Modifiers ─────────*/
    modifier onlyExecutor() {
        if (_msgSender() != _layout().executor) revert NotExecutor();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*═════════════════════════════ Initialiser ═════════════════════════════*/

    /// @notice One-time setup: wire module addresses and seed genesis roles from existing org hats.
    /// @dev Mirrors setter events so the subgraph reconstructs the full genesis picture from logs
    ///      alone (each seeded hat emits `RoleCreated(isExisting=true)`).
    function initialize(InitConfig calldata cfg) external initializer {
        ValidationLib.requireNonZeroAddress(cfg.executor);
        ValidationLib.requireNonZeroAddress(cfg.eligibilityModule);
        ValidationLib.requireNonZeroAddress(cfg.hats);
        if (cfg.existingOrgHats.length != cfg.existingOrgHatNames.length) revert ArrayLengthMismatch();

        __Context_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.executor = cfg.executor;
        l.eligibilityModule = cfg.eligibilityModule;
        l.hats = IHats(cfg.hats);
        l.ddVoting = cfg.ddVoting;
        l.hybridVoting = cfg.hybridVoting;
        l.taskManager = cfg.taskManager;
        l.participationToken = cfg.participationToken;
        l.educationHub = cfg.educationHub;
        l.quickJoin = cfg.quickJoin;
        l.paymasterHub = cfg.paymasterHub;
        l.orgId = cfg.orgId;

        emit RoleManagerInitialized(cfg.executor, cfg.orgId, cfg.eligibilityModule);
        // Fan-out targets must be reconstructable from logs (subgraph rule: no eth_calls) — and on
        // the hand-composed adoption path a mis-pasted module address should be visible immediately.
        emit ModulesWired(
            cfg.ddVoting,
            cfg.hybridVoting,
            cfg.taskManager,
            cfg.participationToken,
            cfg.educationHub,
            cfg.quickJoin,
            cfg.paymasterHub,
            cfg.hats
        );

        // Seed existing org hats as registered (existing) roles.
        uint256 len = cfg.existingOrgHats.length;
        for (uint256 i; i < len;) {
            _registerRole(l, cfg.existingOrgHats[i], cfg.existingOrgHatNames[i], bytes32(0), true);
            unchecked {
                ++i;
            }
        }
    }

    /*═════════════════════════════ Role lifecycle ═════════════════════════════*/

    /// @notice Create a first-class named role: mint an identity hat, register it, fan out wiring,
    ///         attach it to any groups and route initial grants through the consent model.
    /// @dev LOCKED: identity hats are ALWAYS created with `defaultEligible=false` so that a later
    ///      `clearWearerEligibility` dynamically zeroes the wearer's balance (revocation).
    function createRole(RoleParams calldata p) external onlyExecutor returns (uint256 roleId, uint256 hatId) {
        Layout storage l = _layout();

        hatId = _createIdentityHat(l, p.name, p.imageURI, p.maxSupply, p.mutableHat);
        roleId = _registerRole(l, hatId, p.name, p.metadataCID, false);

        // Typed permission fan-out onto the identity hat.
        RoleManagerLogic.applyWiring(roleId, hatId, false, p.wiring);

        // Group memberships.
        uint256 gLen = p.groupIds.length;
        for (uint256 i; i < gLen;) {
            _addRoleToGroup(l, roleId, p.groupIds[i]);
            unchecked {
                ++i;
            }
        }

        // Initial grants routed through the consent model (executor path — createRole is onlyExecutor).
        uint256 grantLen = p.initialGrants.length;
        for (uint256 i; i < grantLen;) {
            _grantRole(l, roleId, p.initialGrants[i], false);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Register a pre-existing hat as a first-class role (adoption path — no hat is created).
    function registerExistingRole(uint256 hatId, string calldata name) external onlyExecutor returns (uint256 roleId) {
        roleId = _registerRole(_layout(), hatId, name, bytes32(0), true);
    }

    /// @notice Set (re-apply) a role's permission wiring. Applies the target state idempotently.
    function setRoleWiring(uint256 roleId, RoleWiring calldata w) external onlyExecutor {
        Layout storage l = _layout();
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        RoleManagerLogic.applyWiring(roleId, r.hatId, false, w);
    }

    /// @notice Grant `roleId` to `user`. Consent model (PLAN §1.4b): in-org members are minted the
    ///         identity + group marker hats directly; non-members receive an explicit eligibility
    ///         OFFER only (they accept via EligibilityModule.claimHats). Nothing is minted for a
    ///         non-member — RoleManager never makes anyone a wearer without consent.
    /// @dev Executor OR a manager-hat wearer with {CAP_GRANT} on this role or any containing group.
    ///      The delegated path is provenance-guarded (DELEGATION.md FIX 1): it may not overwrite a
    ///      governance-owned ban (an explicit ineligible rule lacking the 0x04 flag) — reverts
    ///      {GrantBlockedByGovernanceBan} — but MAY clear a 0x04 delegated kick (manager undoing
    ///      manager). The executor path keeps today's clear-everything semantics byte-for-byte.
    function grantRole(uint256 roleId, address user) external nonReentrant {
        Layout storage l = _layout();
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        bool delegated = _authorizeLifecycle(l, roleId, CAP_GRANT);
        _grantRole(l, roleId, user, delegated);
    }

    /// @notice Revoke `roleId` from `user`. Clears the explicit eligibility rule on the identity hat
    ///         (also revoking an unclaimed offer — the explicit rule IS the offer), then reconciles
    ///         Hats static balances (`checkHatWearerStatus`) so the identity token is BURNED and its
    ///         supply slot freed (elections on capped hats), with group markers reconciled the same
    ///         way when this was the wearer's last member role.
    /// @dev    Reverts `RevokeIneffective` when clearing the explicit rule does not actually remove
    ///         the wearer — i.e. the hat is default-eligible (genesis-seeded / adopted roles) or the
    ///         wearer stays eligible via a vouch quorum or email verification. Those sources are
    ///         outside RoleManager's authority BY DESIGN (it can grant, never ban): governance must
    ///         pair the appropriate EligibilityModule call in the same batch
    ///         (`setWearerEligibility(user, hat, false, false)`, `clearWearerVouches`, or
    ///         `clearEmailVerified`). An honest revert here beats emitting a RoleRevoked event for a
    ///         removal that did not happen.
    function revokeRole(uint256 roleId, address user) external nonReentrant {
        Layout storage l = _layout();
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();

        bool delegated = _authorizeLifecycle(l, roleId, CAP_REVOKE);

        // Delegated revoke may clear an explicit (true,true) rule ONLY when it is delegation-managed
        // (0x04 set) — it must not cancel a governance-written offer/grant made via direct EM setters.
        // Governance (executor) revoke keeps clear-everything semantics.
        if (delegated) {
            (bool hasRule, uint8 flags) = IEligibilityModuleRM(l.eligibilityModule).getWearerRuleFlags(user, r.hatId);
            if (
                hasRule && (flags & FLAG_ELIGIBLE_STANDING) == FLAG_ELIGIBLE_STANDING
                    && (flags & FLAG_DELEGATION_MANAGED) == 0
            ) {
                revert RevokeBlockedByGovernance();
            }
        }

        bool wasWearing = l.hats.isWearerOfHat(user, r.hatId);
        IEligibilityModuleRM(l.eligibilityModule).clearWearerEligibility(user, r.hatId);

        // Burn the now-ineligible identity token (frees hat.supply — a dynamic zero alone leaks
        // supply and bricks successor mints on maxSupply-capped roles), then reconcile each group
        // marker whose derived eligibility may have lapsed with the identity hat. Permissionless
        // no-ops when there is nothing to burn.
        l.hats.checkHatWearerStatus(r.hatId, user);
        uint256[] storage groupIds = l.roleGroupIds[roleId];
        uint256 gLen = groupIds.length;
        for (uint256 i; i < gLen;) {
            l.hats.checkHatWearerStatus(l.groups[groupIds[i]].markerHatId, user);
            unchecked {
                ++i;
            }
        }

        if (l.hats.isWearerOfHat(user, r.hatId)) revert RevokeIneffective();

        emit RoleRevoked(roleId, user, wasWearing, _msgSender(), delegated);
    }

    /*═════════════════════════════ Group lifecycle ═════════════════════════════*/

    /// @notice Create a role group: mint a marker hat carrying the shared permissions, configure the
    ///         EligibilityModule derived list from the member roles' identity hats and fan out the
    ///         shared wiring onto the marker. Marker maxSupply = type(uint32).max, immutable.
    function createGroup(
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint256[] calldata memberRoleIds,
        RoleWiring calldata sharedWiring
    ) external onlyExecutor returns (uint256 groupId, uint256 markerHatId) {
        Layout storage l = _layout();

        markerHatId = _createMarkerHat(l, name, imageURI);

        groupId = ++l.groupCount;
        GroupInfo storage g = l.groups[groupId];
        g.markerHatId = markerHatId;
        g.name = name;
        g.exists = true;

        l.groupIdOfMarker[markerHatId] = groupId;
        l.orgHats.push(markerHatId);
        emit GroupCreated(groupId, markerHatId, name, metadataCID);

        // Attach member roles + derive eligibility.
        uint256 len = memberRoleIds.length;
        for (uint256 i; i < len;) {
            uint256 roleId = memberRoleIds[i];
            if (!l.roles[roleId].exists) revert UnknownRole();
            // Duplicate inputs would create double membership records: removal then pops one copy
            // and emits a removal event while eligibility persists through the other.
            if (_arrayContains(g.memberRoleIds, roleId)) revert AlreadyInGroup();
            g.memberRoleIds.push(roleId);
            l.roleGroupIds[roleId].push(groupId);
            emit RoleGroupMembershipChanged(roleId, groupId, true);
            unchecked {
                ++i;
            }
        }
        _syncGroupEligibility(l, groupId);

        // Shared permission fan-out onto the marker hat.
        RoleManagerLogic.applyWiring(groupId, markerHatId, true, sharedWiring);
    }

    /// @notice Register an existing hat as a group marker (adoption path, e.g. KUBI's Executive hat).
    function registerExistingGroup(uint256 markerHatId, string calldata name, uint256[] calldata memberRoleIds)
        external
        onlyExecutor
        returns (uint256 groupId)
    {
        Layout storage l = _layout();

        // One group per marker, and never a hat already registered as an identity role: a second
        // group on the same marker would overwrite the EligibilityModule's single derived member
        // list while the first group's stored membership silently diverges.
        if (l.groupIdOfMarker[markerHatId] != 0 || l.roleIdOfHat[markerHatId] != 0) revert MarkerAlreadyRegistered();

        groupId = ++l.groupCount;
        GroupInfo storage g = l.groups[groupId];
        g.markerHatId = markerHatId;
        g.name = name;
        g.exists = true;

        l.groupIdOfMarker[markerHatId] = groupId;
        l.orgHats.push(markerHatId);
        // Adopted pre-existing hats have no metadata registration path here; subgraph reads bytes32(0).
        emit GroupCreated(groupId, markerHatId, name, bytes32(0));

        uint256 len = memberRoleIds.length;
        for (uint256 i; i < len;) {
            uint256 roleId = memberRoleIds[i];
            if (!l.roles[roleId].exists) revert UnknownRole();
            if (_arrayContains(g.memberRoleIds, roleId)) revert AlreadyInGroup();
            g.memberRoleIds.push(roleId);
            l.roleGroupIds[roleId].push(groupId);
            emit RoleGroupMembershipChanged(roleId, groupId, true);
            unchecked {
                ++i;
            }
        }
        _syncGroupEligibility(l, groupId);
    }

    /// @notice Add `roleId` to `groupId`, re-syncing the derived eligibility list.
    function addRoleToGroup(uint256 roleId, uint256 groupId) external onlyExecutor {
        _addRoleToGroup(_layout(), roleId, groupId);
    }

    /// @notice Remove `roleId` from `groupId`. Membership relies on dynamic revocation (no burn).
    function removeRoleFromGroup(uint256 roleId, uint256 groupId) external onlyExecutor {
        Layout storage l = _layout();
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        GroupInfo storage g = l.groups[groupId];
        if (!g.exists) revert UnknownGroup();

        if (!_removeFromArray(g.memberRoleIds, roleId)) revert NotInGroup();
        _removeFromArray(l.roleGroupIds[roleId], groupId);

        _syncGroupEligibility(l, groupId);
        emit RoleGroupMembershipChanged(roleId, groupId, false);
    }

    /// @notice Set (re-apply) a group's shared permission wiring onto its marker hat.
    function setGroupWiring(uint256 groupId, RoleWiring calldata w) external onlyExecutor {
        Layout storage l = _layout();
        GroupInfo storage g = l.groups[groupId];
        if (!g.exists) revert UnknownGroup();
        RoleManagerLogic.applyWiring(groupId, g.markerHatId, true, w);
    }

    /*═════════════════════════════ Delegation config ═════════════════════════════*/

    /// @notice Delegate `roleId`'s grant/revoke lifecycle to wearers of `managerHatId` (with `caps`).
    /// @dev onlyExecutor. `managerHatId == 0` clears the delegation. Reverts {SelfManagedGroup} on the
    ///      direct cycle: `managerHatId` is the marker of a group that already contains `roleId` — a
    ///      wearer of that marker (obtained by holding `roleId`, a member of the group) could otherwise
    ///      mint co-managers / purge peers. Deeper transitive cycles are UI-surfaced, not contract-
    ///      checked (DELEGATION.md Primitive A).
    function setRoleManagerConfig(uint256 roleId, uint256 managerHatId, uint8 caps) external onlyExecutor {
        Layout storage l = _layout();
        if (!l.roles[roleId].exists) revert UnknownRole();
        _requireNoSelfManageCycle(l, roleId, managerHatId);
        l.roleManagerConfigs[roleId] = ManagerConfig({managerHatId: managerHatId, caps: caps});
        emit RoleManagerConfigSet(roleId, managerHatId, caps);
    }

    /// @notice Delegate the grant/revoke lifecycle of ALL of `groupId`'s member roles to wearers of
    ///         `managerHatId` (with `caps`).
    /// @dev onlyExecutor. `managerHatId == 0` clears the delegation. Reverts {SelfManagedGroup} when
    ///      `managerHatId` is the marker of a group that contains any of `groupId`'s member roles
    ///      (including `groupId` itself) — the same direct-cycle guard as {setRoleManagerConfig}.
    function setGroupManagerConfig(uint256 groupId, uint256 managerHatId, uint8 caps) external onlyExecutor {
        Layout storage l = _layout();
        GroupInfo storage g = l.groups[groupId];
        if (!g.exists) revert UnknownGroup();
        // A group config manages each member role — reject the cycle against every one of them.
        uint256[] storage members = g.memberRoleIds;
        uint256 len = members.length;
        for (uint256 i; i < len;) {
            _requireNoSelfManageCycle(l, members[i], managerHatId);
            unchecked {
                ++i;
            }
        }
        l.groupManagerConfigs[groupId] = ManagerConfig({managerHatId: managerHatId, caps: caps});
        emit GroupManagerConfigSet(groupId, managerHatId, caps);
    }

    /*═════════════════════════════ Views ═════════════════════════════*/

    /// @notice True iff `user` wears at least one hat in the org membership set.
    function isInOrg(address user) external view returns (bool) {
        Layout storage l = _layout();
        return HatManager.hasAnyHat(l.hats, l.orgHats, user);
    }

    /// @notice Role record for `roleId` (empty struct if unknown).
    function getRole(uint256 roleId) external view returns (RoleInfo memory) {
        return _layout().roles[roleId];
    }

    /// @notice Group record for `groupId` (empty struct if unknown).
    function getGroup(uint256 groupId) external view returns (GroupInfo memory) {
        return _layout().groups[groupId];
    }

    /// @notice Manager-hat delegation config for `roleId` (zeroed struct if none).
    function getRoleManagerConfig(uint256 roleId) external view returns (ManagerConfig memory) {
        return _layout().roleManagerConfigs[roleId];
    }

    /// @notice Manager-hat delegation config for `groupId` (zeroed struct if none).
    function getGroupManagerConfig(uint256 groupId) external view returns (ManagerConfig memory) {
        return _layout().groupManagerConfigs[groupId];
    }

    /// @notice Reverse index: role id owning `hatId` (0 if none).
    function roleIdOfHat(uint256 hatId) external view returns (uint256) {
        return _layout().roleIdOfHat[hatId];
    }

    /// @notice Number of registered roles.
    function roleCount() external view returns (uint256) {
        return _layout().roleCount;
    }

    /// @notice Number of registered groups.
    function groupCount() external view returns (uint256) {
        return _layout().groupCount;
    }

    /// @notice The full org membership hat set.
    /// @notice The wired sibling-module addresses this RoleManager fans permissions out to.
    function modules()
        external
        view
        returns (
            address ddVoting,
            address hybridVoting,
            address taskManager,
            address participationToken,
            address educationHub,
            address quickJoin,
            address paymasterHub,
            address hats_
        )
    {
        Layout storage l = _layout();
        return (
            l.ddVoting,
            l.hybridVoting,
            l.taskManager,
            l.participationToken,
            l.educationHub,
            l.quickJoin,
            l.paymasterHub,
            address(l.hats)
        );
    }

    function orgHats() external view returns (uint256[] memory) {
        return _layout().orgHats;
    }

    /*═════════════════════════════ Internal ═════════════════════════════*/

    function _createIdentityHat(
        Layout storage l,
        string calldata name,
        string calldata imageURI,
        uint32 maxSupply,
        bool mutableHat
    ) private returns (uint256 hatId) {
        IEligibilityModuleRM em = IEligibilityModuleRM(l.eligibilityModule);
        IEligibilityModuleRM.CreateHatParams memory params = IEligibilityModuleRM.CreateHatParams({
            parentHatId: em.eligibilityModuleAdminHat(),
            details: name,
            // 0 = unlimited (repo convention, mirrors HatsTreeSetup): Hats treats a raw 0 cap as
            // an unmintable hat — every grant/claim would revert AllHatsWorn.
            maxSupply: maxSupply == 0 ? type(uint32).max : maxSupply,
            _mutable: mutableHat,
            imageURI: imageURI,
            defaultEligible: false, // LOCKED: enables dynamic revocation via clearWearerEligibility
            defaultStanding: true,
            mintToAddresses: new address[](0),
            wearerEligibleFlags: new bool[](0),
            wearerStandingFlags: new bool[](0)
        });
        hatId = em.createHatWithEligibility(params);
    }

    function _createMarkerHat(Layout storage l, string calldata name, string calldata imageURI)
        private
        returns (uint256 hatId)
    {
        IEligibilityModuleRM em = IEligibilityModuleRM(l.eligibilityModule);
        IEligibilityModuleRM.CreateHatParams memory params = IEligibilityModuleRM.CreateHatParams({
            parentHatId: em.eligibilityModuleAdminHat(),
            details: name,
            maxSupply: type(uint32).max,
            _mutable: false,
            imageURI: imageURI,
            defaultEligible: false, // membership is driven purely by derived eligibility
            defaultStanding: true,
            mintToAddresses: new address[](0),
            wearerEligibleFlags: new bool[](0),
            wearerStandingFlags: new bool[](0)
        });
        hatId = em.createHatWithEligibility(params);
    }

    function _registerRole(Layout storage l, uint256 hatId, string memory name, bytes32 metadataCID, bool isExisting)
        private
        returns (uint256 roleId)
    {
        // One role per hat, and never a hat that already serves as a group marker: a duplicate
        // registration would leave two live roles steering the same hat with the reverse lookup
        // exposing only the newest — contradictory group/grant state.
        if (l.roleIdOfHat[hatId] != 0 || l.groupIdOfMarker[hatId] != 0) revert HatAlreadyRegistered();
        roleId = ++l.roleCount;
        RoleInfo storage r = l.roles[roleId];
        r.hatId = hatId;
        r.name = name;
        r.metadataCID = metadataCID;
        r.exists = true;
        l.roleIdOfHat[hatId] = roleId;
        l.orgHats.push(hatId);
        emit RoleCreated(roleId, hatId, name, metadataCID, isExisting);
    }

    function _addRoleToGroup(Layout storage l, uint256 roleId, uint256 groupId) private {
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        GroupInfo storage g = l.groups[groupId];
        if (!g.exists) revert UnknownGroup();
        if (_arrayContains(g.memberRoleIds, roleId)) revert AlreadyInGroup();

        g.memberRoleIds.push(roleId);
        l.roleGroupIds[roleId].push(groupId);

        // Re-check the direct-cycle invariant now that `roleId` belongs to `groupId`: adding the role
        // must not turn an existing role- or group-level delegation into a self-management cycle
        // (managerHatId being the marker of a group that now contains the managed role). Reverts roll
        // back the push above (DELEGATION.md: addRoleToGroup-time re-check).
        _requireNoSelfManageCycle(l, roleId, l.roleManagerConfigs[roleId].managerHatId);
        _requireNoSelfManageCycle(l, roleId, l.groupManagerConfigs[groupId].managerHatId);

        _syncGroupEligibility(l, groupId);
        emit RoleGroupMembershipChanged(roleId, groupId, true);
    }

    /// @dev Re-derives the group's EligibilityModule member-hat list from its current member roles.
    function _syncGroupEligibility(Layout storage l, uint256 groupId) private {
        GroupInfo storage g = l.groups[groupId];
        uint256 len = g.memberRoleIds.length;
        uint256[] memory memberHats = new uint256[](len);
        for (uint256 i; i < len;) {
            memberHats[i] = l.roles[g.memberRoleIds[i]].hatId;
            unchecked {
                ++i;
            }
        }
        IEligibilityModuleRM(l.eligibilityModule).setGroupEligibility(g.markerHatId, memberHats);
    }

    /// @dev Consent-model grant. In-org: (re)establish eligibility + mint identity, then group
    ///      markers (derived-eligible once the identity is worn). Out-of-org: explicit eligibility
    ///      OFFER only — mints nothing. When `delegated` (caller is a manager-hat wearer, not the
    ///      executor) every rule this path would clear/overwrite (identity + all markers) is first
    ///      checked for a governance-owned ban — an explicit ineligible rule WITHOUT the 0x04 flag —
    ///      and reverts {GrantBlockedByGovernanceBan} rather than lifting it. A 0x04 delegated kick is
    ///      clearable (manager undoing manager). The executor path is byte-identical to today.
    function _grantRole(Layout storage l, uint256 roleId, address user, bool delegated) private {
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        uint256 identityHat = r.hatId;
        IEligibilityModuleRM em = IEligibilityModuleRM(l.eligibilityModule);
        uint256[] storage groupIds = l.roleGroupIds[roleId];
        uint256 gLen = groupIds.length;

        // Provenance guard: a delegated grant must never overwrite a governance ban (identity or any
        // marker it would clear). Checked up-front so the whole call reverts atomically.
        if (delegated) {
            _requireNotGovernanceBanned(em, user, identityHat);
            for (uint256 i; i < gLen;) {
                _requireNotGovernanceBanned(em, user, l.groups[groupIds[i]].markerHatId);
                unchecked {
                    ++i;
                }
            }
        }

        if (HatManager.hasAnyHat(l.hats, l.orgHats, user)) {
            // Clear any stale explicit rules on the identity + markers (crit-integration 1.4).
            em.clearWearerEligibility(user, identityHat);
            for (uint256 i; i < gLen;) {
                em.clearWearerEligibility(user, l.groups[groupIds[i]].markerHatId);
                unchecked {
                    ++i;
                }
            }

            // Explicit eligibility on the identity hat (defaultEligible=false ⇒ mint needs a source);
            // this is also what a later revoke clears to zero the balance.
            em.grantWearerEligibility(user, identityHat);
            if (!l.hats.isWearerOfHat(user, identityHat)) {
                em.mintHatToAddress(identityHat, user);
            }

            // Markers: derived-eligible now the identity is worn. Skip already-worn.
            for (uint256 i; i < gLen;) {
                uint256 markerHat = l.groups[groupIds[i]].markerHatId;
                if (!l.hats.isWearerOfHat(user, markerHat)) {
                    em.mintHatToAddress(markerHat, user);
                }
                unchecked {
                    ++i;
                }
            }

            emit RoleGranted(roleId, user, true, _msgSender(), delegated);
        } else {
            // OFFER: explicit eligibility rule is the offer state; user accepts via EM.claimHats.
            // Clear stale explicit rules on the group markers too — an old kick would otherwise
            // shadow the derived path and make the one-tx claimHats([identity, markers]) acceptance
            // revert on the marker entry. (grantWearerEligibility overwrites the identity rule, so
            // no separate clear is needed there; a governance grant vote implies the un-ban.)
            for (uint256 i; i < gLen;) {
                em.clearWearerEligibility(user, l.groups[groupIds[i]].markerHatId);
                unchecked {
                    ++i;
                }
            }
            em.grantWearerEligibility(user, identityHat);
            emit RoleOffered(roleId, user, identityHat, _msgSender(), delegated);
            emit RoleGranted(roleId, user, false, _msgSender(), delegated);
        }
    }

    /// @dev Reverts {GrantBlockedByGovernanceBan} if `user` has an explicit ineligible rule on `hat`
    ///      that is NOT delegation-managed (0x04) — a governance-owned ban a delegate may not lift.
    function _requireNotGovernanceBanned(IEligibilityModuleRM em, address user, uint256 hat) private view {
        (bool hasRule, uint8 flags) = em.getWearerRuleFlags(user, hat);
        if (
            hasRule && (flags & FLAG_ELIGIBLE_STANDING) != FLAG_ELIGIBLE_STANDING
                && (flags & FLAG_DELEGATION_MANAGED) == 0
        ) {
            revert GrantBlockedByGovernanceBan();
        }
    }

    /// @dev Lifecycle authorization for grant/revoke. The executor is always authorized (returns
    ///      `delegated = false`). Otherwise the caller must wear the role's managerHat OR any
    ///      containing group's managerHat, each carrying `cap` — returns `delegated = true`. Reverts
    ///      {NotAuthorizedManager} when neither holds.
    function _authorizeLifecycle(Layout storage l, uint256 roleId, uint8 cap) private view returns (bool delegated) {
        address caller = _msgSender();
        if (caller == l.executor) return false;

        if (_isManager(l, l.roleManagerConfigs[roleId], caller, cap)) return true;
        uint256[] storage gids = l.roleGroupIds[roleId];
        uint256 len = gids.length;
        for (uint256 i; i < len;) {
            if (_isManager(l, l.groupManagerConfigs[gids[i]], caller, cap)) return true;
            unchecked {
                ++i;
            }
        }
        revert NotAuthorizedManager();
    }

    /// @dev A config authorizes `caller` for `cap` iff it names a manager hat, carries the cap bit,
    ///      and `caller` currently wears that hat (authority self-expires with the hat).
    function _isManager(Layout storage l, ManagerConfig storage c, address caller, uint8 cap)
        private
        view
        returns (bool)
    {
        if (c.managerHatId == 0 || c.caps & cap == 0) return false;
        return l.hats.isWearerOfHat(caller, c.managerHatId);
    }

    /// @dev Direct-cycle guard: revert {SelfManagedGroup} if `managerHatId` is the marker of a group
    ///      that contains `roleId`. `managerHatId == 0` (config clear) is a no-op (no marker maps to
    ///      group 0). Shared by both config setters and the addRoleToGroup re-check.
    function _requireNoSelfManageCycle(Layout storage l, uint256 roleId, uint256 managerHatId) private view {
        uint256 gid = l.groupIdOfMarker[managerHatId];
        if (gid != 0 && _arrayContains(l.roleGroupIds[roleId], gid)) revert SelfManagedGroup();
    }

    function _arrayContains(uint256[] storage arr, uint256 value) private view returns (bool) {
        uint256 len = arr.length;
        for (uint256 i; i < len;) {
            if (arr[i] == value) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _removeFromArray(uint256[] storage arr, uint256 value) private returns (bool) {
        uint256 len = arr.length;
        for (uint256 i; i < len;) {
            if (arr[i] == value) {
                arr[i] = arr[len - 1];
                arr.pop();
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
