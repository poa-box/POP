// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {IRoleManager} from "../interfaces/IRoleManager.sol";

/*═════════════════════ Minimal module-call interfaces ═════════════════════*/
/// @dev Only the exact selectors RoleManager (and this library) fan out to. Enum parameters are
///      ABI-encoded as `uint8`, so these declarations share selectors with the concrete modules
///      (W1/W3/W4). Declared here at file scope so both {RoleManager} and {RoleManagerLogic} import
///      the SAME interface types (no duplicate/divergent declarations).

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
    function getDefaultRules(uint256 hatId) external view returns (bool eligible, bool standing);
    function clearWearerEligibility(address wearer, uint256 hatId) external;
    function grantWearerEligibility(address wearer, uint256 hatId) external;
    function mintHatToAddress(uint256 hatId, address wearer) external;
    function setGroupEligibility(uint256 groupHatId, uint256[] calldata memberHats) external;
    function getGroupMemberHats(uint256 groupHatId) external view returns (uint256[] memory);
    function configureVouching(uint256 hatId, uint32 quorum, uint256 membershipHatId, bool combineWithHierarchy)
        external;
    function updateHatConfig(uint256 hatId, uint32 newMaxSupply) external;
    /// @notice Provenance view (W12): whether an explicit per-wearer rule exists and its flags byte
    ///         (bit0 eligible, bit1 standing, bit2 0x04 = DELEGATION_MANAGED). RoleManager consumes it
    ///         to keep delegated grant/revoke from overwriting governance-owned rules.
    function getWearerRuleFlags(address wearer, uint256 hatId) external view returns (bool hasRule, uint8 flags);
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

/*════════════════════════════════ RoleManagerLogic ════════════════════════════════*/
/// @title RoleManagerLogic – DELEGATECALL library holding RoleManager's permission fan-out bodies.
/// @notice Offloaded to keep {RoleManager} under the EIP-170 runtime limit. Its functions are
///         `external`, so the linker deploys the library separately and the module reaches it via
///         DELEGATECALL — `msg.sender`, `msg.value` and storage context are the module's.
/// @dev The `Layout` struct + storage slot below MUST stay byte-identical to {RoleManager.Layout}
///      (append-only ERC-7201). Access modifiers / reentrancy guards are enforced by the module
///      wrappers before delegatecalling here; these bodies assume the caller was already authorized.
///      {RoleManagerLogicLayoutSyncTest} is the functional guard against Layout divergence.
library RoleManagerLogic {
    /*────────── Constants ─────────*/
    uint8 private constant SUBJECT_TYPE_HAT = 0x01; // PaymasterHub subject-key discriminator

    /*────────── Errors ─────────*/
    error WiringIncompatible();

    /*────────── Events (mirror {IRoleManager}) ─────────*/
    event RoleWiringApplied(uint256 indexed id, uint256 indexed hatId, bool isGroup);
    event BudgetSkipped(uint256 indexed hatId);

    /*────────── ERC-7201 Storage (mirror of RoleManager) ─────────*/
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
        mapping(uint256 => IRoleManager.RoleInfo) roles; // roleId (1-based) => role
        mapping(uint256 => uint256) roleIdOfHat; // hatId => roleId
        mapping(uint256 => uint256[]) roleGroupIds; // roleId => group ids it belongs to
        // groups
        uint256 groupCount;
        mapping(uint256 => IRoleManager.GroupInfo) groups; // groupId (1-based) => group
        mapping(uint256 => uint256) groupIdOfMarker; // marker hatId => groupId (one-to-one with groups)
        // delegation configs (W13 appends — append-only, keep byte-identical with RoleManager.Layout)
        mapping(uint256 => IRoleManager.ManagerConfig) roleManagerConfigs; // roleId => manager config
        mapping(uint256 => IRoleManager.ManagerConfig) groupManagerConfigs; // groupId => manager config
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.rolemanager.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═════════════════════════════ Wiring fan-out ═════════════════════════════*/

    /// @dev Typed permission fan-out. Applies the target state idempotently (no diff); a cleared
    ///      boolean re-applies the permission as `false`. `id` is a roleId or groupId (per isGroup).
    ///      Behaviour is byte-identical to the pre-offload inline `_applyWiring` — moved verbatim.
    function applyWiring(uint256 id, uint256 hatId, bool isGroup, IRoleManager.RoleWiring calldata w) external {
        Layout storage l = _layout();

        // Guard incompatible wiring up-front (cheap honest reverts beat silently-broken state):
        // 1. Vouching with combineWithHierarchy=false makes getWearerStatus IGNORE the explicit
        //    per-wearer rules that RoleManager's entire grant/offer/consent model rests on — every
        //    grant would revert NotEligible and every offer would be permanently unclaimable.
        //    Vouch-gated RM roles must keep combine=true (vouching as an ADDITIONAL path).
        if (w.vouchingEnabled && !w.vouchCombine) revert WiringIncompatible();
        // 2. Markers must keep the derived-eligibility path free: vouching on a marker either
        //    reverts in EM (derived<->vouch guard) or — for a still-empty group — sneaks in and
        //    permanently blocks every later addRoleToGroup. Reject at the source.
        if (isGroup && w.vouchingEnabled) revert WiringIncompatible();
        // 3. QuickJoin auto-mint requires an OPEN (default-eligible) hat: joins mint via
        //    Executor.mintHatsForUser -> Hats.mintHat, which reverts NotEligible for the
        //    default-closed hats RoleManager creates — wiring one in would brick every
        //    subsequent join org-wide. Only pre-existing open hats (e.g. a genesis MEMBER
        //    role) may be auto-minted on join.
        if (w.quickJoinAutoMint) {
            (bool defaultEligible,) = IEligibilityModuleRM(l.eligibilityModule).getDefaultRules(hatId);
            if (!defaultEligible) revert WiringIncompatible();
        }

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
            _applyHvClasses(l.hybridVoting, hatId, w.hvClassIndexes);
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

    /// @dev HybridVoting class memberships (apply-only ADD). Its own frame keeps the calldata-array
    ///      loop off the {applyWiring} stack (production via-IR stack-limit headroom).
    function _applyHvClasses(address hybridVoting, uint256 hatId, uint8[] calldata classIndexes) private {
        uint256 cLen = classIndexes.length;
        for (uint256 i; i < cLen;) {
            IHVVotingRM(hybridVoting).addHatToClass(classIndexes[i], hatId);
            unchecked {
                ++i;
            }
        }
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
}
