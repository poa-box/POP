// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────── OpenZeppelin v5.3 Upgradeables ────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";

/*──────── External interfaces / libs ────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";
import {IRoleManager} from "./interfaces/IRoleManager.sol";

/*═════════════════════ Minimal module-call interfaces ═════════════════════*/
/// @dev Only the exact selectors RoleManager fans out to. Enum parameters are ABI-encoded as
///      `uint8`, so these declarations share selectors with the concrete modules (W1/W3/W4).

interface IEligibilityModuleRM {
    struct CreateHatParams {
        uint256 parentHatId;
        string details;
        uint32 maxSupply;
        bool _mutable;
        string imageURI;
        bool defaultEligible;
        bool defaultStanding;
        address[] mintToAddresses;
        bool[] wearerEligibleFlags;
        bool[] wearerStandingFlags;
    }

    function createHatWithEligibility(CreateHatParams calldata params) external returns (uint256);
    function eligibilityModuleAdminHat() external view returns (uint256);
    function clearWearerEligibility(address wearer, uint256 hatId) external;
    function grantWearerEligibility(address wearer, uint256 hatId) external;
    function mintHatToAddress(uint256 hatId, address wearer) external;
    function setGroupEligibility(uint256 groupHatId, uint256[] calldata memberHats) external;
    function getGroupMemberHats(uint256 groupHatId) external view returns (uint256[] memory);
    function configureVouching(uint256 hatId, uint32 quorum, uint256 membershipHatId, bool combineWithHierarchy)
        external;
    function updateHatConfig(uint256 hatId, uint32 newMaxSupply) external;
}

interface IDDVotingRM {
    enum HatType {
        VOTING,
        CREATOR
    }

    enum ConfigKey {
        THRESHOLD,
        EXECUTOR,
        TARGET_ALLOWED,
        HAT_ALLOWED,
        QUORUM
    }

    function setConfig(ConfigKey key, bytes calldata value) external;
}

interface IHVVotingRM {
    function setCreatorHatAllowed(uint256 h, bool ok) external;
    function addHatToClass(uint8 classIdx, uint256 hatId) external;
    function removeHatFromClass(uint8 classIdx, uint256 hatId) external;
}

interface ITaskManagerRM {
    enum ConfigKey {
        EXECUTOR,
        CREATOR_HAT_ALLOWED,
        ROLE_PERM,
        PROJECT_ROLE_PERM,
        BOUNTY_CAP,
        PROJECT_MANAGER,
        PROJECT_CAP,
        ORGANIZER_HAT_ALLOWED
    }

    function setConfig(ConfigKey key, bytes calldata value) external;
}

interface IParticipationTokenRM {
    function setMemberHatAllowed(uint256 h, bool ok) external;
    function setApproverHatAllowed(uint256 h, bool ok) external;
}

interface IEducationHubRM {
    function setCreatorHatAllowed(uint256 h, bool ok) external;
    function setMemberHatAllowed(uint256 h, bool ok) external;
}

interface IQuickJoinRM {
    function updateMemberHatIds(uint256[] calldata memberHatIds_) external;
    function memberHatIds() external view returns (uint256[] memory);
}

interface IPaymasterHubRM {
    function setBudget(bytes32 orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen) external;
}

/*════════════════════════════════ RoleManager ════════════════════════════════*/
/// @title RoleManager – first-class named roles & role groups, orchestrated via governance.
/// @notice Scoped orchestrator (never superAdmin). Creates identity/marker hats through the
///         EligibilityModule, fans permission changes out to the org's sibling modules and drives
///         the consent-safe grant/offer flow. Every mutating function is `onlyExecutor`; there are
///         no user-facing mutations (offer acceptance happens on the EligibilityModule).
contract RoleManager is Initializable, ContextUpgradeable, IRoleManager {
    /*────────── Constants ─────────*/
    bytes4 public constant MODULE_ID = 0x524f4c45; /* "ROLE" */
    uint8 private constant SUBJECT_TYPE_HAT = 0x01; // PaymasterHub subject-key discriminator

    /*────────── Errors ─────────*/
    error ZeroAddress();
    error NotExecutor();
    error ArrayLengthMismatch();
    error UnknownRole();
    error UnknownGroup();
    error AlreadyInGroup();
    error NotInGroup();

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
        _applyWiring(l, roleId, hatId, false, p.wiring);

        // Group memberships.
        uint256 gLen = p.groupIds.length;
        for (uint256 i; i < gLen;) {
            _addRoleToGroup(l, roleId, p.groupIds[i]);
            unchecked {
                ++i;
            }
        }

        // Initial grants routed through the consent model.
        uint256 grantLen = p.initialGrants.length;
        for (uint256 i; i < grantLen;) {
            _grantRole(l, roleId, p.initialGrants[i]);
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
        _applyWiring(l, roleId, r.hatId, false, w);
    }

    /// @notice Grant `roleId` to `user`. Consent model (PLAN §1.4b): in-org members are minted the
    ///         identity + group marker hats directly; non-members receive an explicit eligibility
    ///         OFFER only (they accept via EligibilityModule.claimHats). Nothing is minted for a
    ///         non-member — RoleManager never makes anyone a wearer without consent.
    function grantRole(uint256 roleId, address user) external onlyExecutor {
        _grantRole(_layout(), roleId, user);
    }

    /// @notice Revoke `roleId` from `user`. Clears the explicit eligibility rule on the identity hat;
    ///         because identity hats are `defaultEligible=false` this dynamically zeroes the balance,
    ///         and any group markers auto-follow via derived eligibility when this was the wearer's
    ///         last member role. Also revokes an unclaimed offer (the explicit rule IS the offer).
    function revokeRole(uint256 roleId, address user) external onlyExecutor {
        Layout storage l = _layout();
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();

        bool wasWearing = l.hats.isWearerOfHat(user, r.hatId);
        IEligibilityModuleRM(l.eligibilityModule).clearWearerEligibility(user, r.hatId);
        emit RoleRevoked(roleId, user, wasWearing);
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

        l.orgHats.push(markerHatId);
        emit GroupCreated(groupId, markerHatId, name, metadataCID);

        // Attach member roles + derive eligibility.
        uint256 len = memberRoleIds.length;
        for (uint256 i; i < len;) {
            uint256 roleId = memberRoleIds[i];
            if (!l.roles[roleId].exists) revert UnknownRole();
            g.memberRoleIds.push(roleId);
            l.roleGroupIds[roleId].push(groupId);
            emit RoleGroupMembershipChanged(roleId, groupId, true);
            unchecked {
                ++i;
            }
        }
        _syncGroupEligibility(l, groupId);

        // Shared permission fan-out onto the marker hat.
        _applyWiring(l, groupId, markerHatId, true, sharedWiring);
    }

    /// @notice Register an existing hat as a group marker (adoption path, e.g. KUBI's Executive hat).
    function registerExistingGroup(uint256 markerHatId, string calldata name, uint256[] calldata memberRoleIds)
        external
        onlyExecutor
        returns (uint256 groupId)
    {
        Layout storage l = _layout();

        groupId = ++l.groupCount;
        GroupInfo storage g = l.groups[groupId];
        g.markerHatId = markerHatId;
        g.name = name;
        g.exists = true;

        l.orgHats.push(markerHatId);
        // Adopted pre-existing hats have no metadata registration path here; subgraph reads bytes32(0).
        emit GroupCreated(groupId, markerHatId, name, bytes32(0));

        uint256 len = memberRoleIds.length;
        for (uint256 i; i < len;) {
            uint256 roleId = memberRoleIds[i];
            if (!l.roles[roleId].exists) revert UnknownRole();
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
        _applyWiring(l, groupId, g.markerHatId, true, w);
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
            maxSupply: maxSupply,
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
    ///      OFFER only — mints nothing.
    function _grantRole(Layout storage l, uint256 roleId, address user) private {
        RoleInfo storage r = l.roles[roleId];
        if (!r.exists) revert UnknownRole();
        uint256 identityHat = r.hatId;
        IEligibilityModuleRM em = IEligibilityModuleRM(l.eligibilityModule);
        uint256[] storage groupIds = l.roleGroupIds[roleId];

        if (HatManager.hasAnyHat(l.hats, l.orgHats, user)) {
            // Clear any stale explicit rules on the identity + markers (crit-integration 1.4).
            em.clearWearerEligibility(user, identityHat);
            uint256 gLen = groupIds.length;
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

            emit RoleGranted(roleId, user, true);
        } else {
            // OFFER: explicit eligibility rule is the offer state; user accepts via EM.claimHats.
            em.grantWearerEligibility(user, identityHat);
            emit RoleOffered(roleId, user, identityHat);
            emit RoleGranted(roleId, user, false);
        }
    }

    /// @dev Typed permission fan-out. Applies the target state idempotently (no diff); a cleared
    ///      boolean re-applies the permission as `false`. `id` is a roleId or groupId (per isGroup).
    function _applyWiring(Layout storage l, uint256 id, uint256 hatId, bool isGroup, RoleWiring memory w) private {
        // TaskManager global ROLE_PERM (mask==0 removes all perms — gated by the explicit flag).
        if (w.setTaskPerm && l.taskManager != address(0)) {
            ITaskManagerRM(l.taskManager)
                .setConfig(ITaskManagerRM.ConfigKey.ROLE_PERM, abi.encode(hatId, w.taskPermMask));
        }

        // DirectDemocracy voter / creator rights.
        if (l.ddVoting != address(0)) {
            IDDVotingRM(l.ddVoting)
                .setConfig(IDDVotingRM.ConfigKey.HAT_ALLOWED, abi.encode(IDDVotingRM.HatType.VOTING, hatId, w.ddVoter));
            IDDVotingRM(l.ddVoting)
                .setConfig(
                    IDDVotingRM.ConfigKey.HAT_ALLOWED, abi.encode(IDDVotingRM.HatType.CREATOR, hatId, w.ddCreator)
                );
        }

        // HybridVoting creator right + class memberships.
        if (l.hybridVoting != address(0)) {
            IHVVotingRM(l.hybridVoting).setCreatorHatAllowed(hatId, w.hvCreator);
            uint256 cLen = w.hvClassIndexes.length;
            for (uint256 i; i < cLen;) {
                IHVVotingRM(l.hybridVoting).addHatToClass(w.hvClassIndexes[i], hatId);
                unchecked {
                    ++i;
                }
            }
        }

        // ParticipationToken member / approver rights.
        if (l.participationToken != address(0)) {
            IParticipationTokenRM(l.participationToken).setMemberHatAllowed(hatId, w.ptMember);
            IParticipationTokenRM(l.participationToken).setApproverHatAllowed(hatId, w.ptApprover);
        }

        // EducationHub creator / member rights.
        if (l.educationHub != address(0)) {
            IEducationHubRM(l.educationHub).setCreatorHatAllowed(hatId, w.eduCreator);
            IEducationHubRM(l.educationHub).setMemberHatAllowed(hatId, w.eduMember);
        }

        // QuickJoin auto-mint list (read-modify-write, full-replacement setter).
        if (l.quickJoin != address(0)) {
            _applyQuickJoin(l.quickJoin, hatId, w.quickJoinAutoMint);
        }

        // Vouching config (only when enabled — a marker hat with derived config cannot vouch).
        if (w.vouchingEnabled) {
            IEligibilityModuleRM(l.eligibilityModule)
                .configureVouching(hatId, w.vouchQuorum, w.vouchMembershipHatId, w.vouchCombine);
        }

        // Per-hat paymaster budget (best-effort — never reverts the governance batch).
        if ((w.budgetCapPerEpoch > 0 || w.budgetEpochLen > 0) && l.paymasterHub != address(0)) {
            bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_HAT, bytes32(hatId)));
            try IPaymasterHubRM(l.paymasterHub).setBudget(l.orgId, subjectKey, w.budgetCapPerEpoch, w.budgetEpochLen) {}
            catch {
                emit BudgetSkipped(hatId);
            }
        }

        emit RoleWiringApplied(id, hatId, isGroup);
    }

    function _applyQuickJoin(address quickJoin, uint256 hatId, bool include) private {
        uint256[] memory current = IQuickJoinRM(quickJoin).memberHatIds();
        uint256 len = current.length;
        bool present;
        uint256 idx;
        for (uint256 i; i < len;) {
            if (current[i] == hatId) {
                present = true;
                idx = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (include && !present) {
            uint256[] memory next = new uint256[](len + 1);
            for (uint256 i; i < len;) {
                next[i] = current[i];
                unchecked {
                    ++i;
                }
            }
            next[len] = hatId;
            IQuickJoinRM(quickJoin).updateMemberHatIds(next);
        } else if (!include && present) {
            uint256[] memory next = new uint256[](len - 1);
            uint256 j;
            for (uint256 i; i < len;) {
                if (i != idx) {
                    next[j] = current[i];
                    unchecked {
                        ++j;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            IQuickJoinRM(quickJoin).updateMemberHatIds(next);
        }
        // else: already in desired state — no write.
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
