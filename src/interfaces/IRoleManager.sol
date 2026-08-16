// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @title IRoleManager
/// @notice External ABI, structs and events for the per-org RoleManager orchestrator.
/// @dev Behavioural spec: .context/rolemanager/PLAN.md §1.2 / §1.4b. All mutating functions are
///      executor-gated; RoleManager has ZERO user-facing mutating functions (consent-safe by design).
interface IRoleManager {
    /*────────────────── Structs ──────────────────*/

    /// @notice One-time initialise config: module wiring + genesis role seed.
    struct InitConfig {
        address executor;
        address eligibilityModule;
        address hats;
        address ddVoting;
        address hybridVoting;
        address taskManager;
        address participationToken;
        address educationHub;
        address quickJoin;
        address paymasterHub;
        bytes32 orgId;
        uint256[] existingOrgHats; // seed for orgHats[] (existing role + member hats)
        string[] existingOrgHatNames; // parallel; registered as roles (index-aligned)
    }

    /// @notice Typed permission fan-out applied to a role's identity hat or a group's marker hat.
    /// @dev Applied idempotently; boolean module flags express the target state (a cleared flag
    ///      re-applies the permission as `false` — an explicit removal). TWO FIELDS ARE APPLY-ONLY,
    ///      not target-state: `hvClassIndexes` only ADDS class memberships (remove via a governance
    ///      call to HybridVoting.removeHatFromClass), and `vouchingEnabled=false` leaves an existing
    ///      vouch config untouched (disable via EligibilityModule.configureVouching(hat, 0, 0, false)).
    ///      Incompatible combinations revert `WiringIncompatible`: vouching with combine=false
    ///      (breaks the grant/offer consent model), vouching on a group marker (blocks the derived
    ///      path), and quickJoinAutoMint on a non-default-eligible hat (bricks QuickJoin joins).
    struct RoleWiring {
        bool setTaskPerm;
        uint8 taskPermMask;
        bool ddVoter;
        bool ddCreator;
        bool hvCreator;
        uint8[] hvClassIndexes; // HV classes to join (via addHatToClass)
        bool ptMember;
        bool ptApprover;
        bool eduCreator;
        bool eduMember;
        bool quickJoinAutoMint;
        bool vouchingEnabled;
        uint32 vouchQuorum;
        uint256 vouchMembershipHatId;
        bool vouchCombine;
        uint128 budgetCapPerEpoch; // 0/0 = skip paymaster budget
        uint32 budgetEpochLen;
    }

    /// @notice Parameters for creating a first-class named role.
    struct RoleParams {
        string name;
        bytes32 metadataCID;
        string imageURI;
        uint32 maxSupply;
        bool mutableHat;
        uint256[] groupIds; // groups this role belongs to
        RoleWiring wiring;
        address[] initialGrants; // routed through grantRole consent logic
    }

    /// @notice Stored role record (also the view return shape).
    struct RoleInfo {
        uint256 hatId;
        string name;
        bytes32 metadataCID;
        uint256 flags;
        bool exists;
    }

    /// @notice Stored group record (also the view return shape).
    struct GroupInfo {
        uint256 markerHatId;
        string name;
        uint256[] memberRoleIds;
        bool exists;
    }

    /// @notice Manager-hat delegation config for a role or group (W13 delegated lifecycle).
    /// @dev `caps` is a bitmask of {CAP_GRANT} (1) / {CAP_REVOKE} (2); the two are separable. A
    ///      wearer of `managerHatId` may perform the capped lifecycle action WITHOUT a governance
    ///      vote. `managerHatId == 0` means no delegation (executor-only).
    struct ManagerConfig {
        uint256 managerHatId;
        uint8 caps;
    }

    /*────────────────── Events ──────────────────*/

    event RoleManagerInitialized(address indexed executor, bytes32 indexed orgId, address eligibilityModule);
    event ModulesWired(
        address ddVoting,
        address hybridVoting,
        address taskManager,
        address participationToken,
        address educationHub,
        address quickJoin,
        address paymasterHub,
        address hats
    );
    event RoleCreated(uint256 indexed roleId, uint256 indexed hatId, string name, bytes32 metadataCID, bool isExisting);
    event GroupCreated(uint256 indexed groupId, uint256 indexed markerHatId, string name, bytes32 metadataCID);
    event RoleGroupMembershipChanged(uint256 indexed roleId, uint256 indexed groupId, bool added);
    event RoleWiringApplied(uint256 indexed id, uint256 indexed hatId, bool isGroup);
    // Lifecycle events carry `actor` (the caller that performed the action) + `delegated` (true when a
    // manager-hat wearer acted instead of the executor) so the subgraph feed reads truthfully under
    // W13 delegation. Signatures REPLACED pre-broadcast (INTERFACES.md W13, 2026-08-16).
    event RoleOffered(
        uint256 indexed roleId, address indexed user, uint256 indexed hatId, address actor, bool delegated
    );
    event RoleGranted(uint256 indexed roleId, address indexed user, bool minted, address actor, bool delegated);
    event RoleRevoked(uint256 indexed roleId, address indexed user, bool wasWearing, address actor, bool delegated);
    event RoleManagerConfigSet(uint256 indexed roleId, uint256 indexed managerHatId, uint8 caps);
    event GroupManagerConfigSet(uint256 indexed groupId, uint256 indexed managerHatId, uint8 caps);
    event BudgetSkipped(uint256 indexed hatId);

    /*────────────────── Mutations (onlyExecutor) ──────────────────*/

    function initialize(InitConfig calldata cfg) external;

    function createRole(RoleParams calldata p) external returns (uint256 roleId, uint256 hatId);

    function createGroup(
        string calldata name,
        bytes32 metadataCID,
        string calldata imageURI,
        uint256[] calldata memberRoleIds,
        RoleWiring calldata sharedWiring
    ) external returns (uint256 groupId, uint256 markerHatId);

    function addRoleToGroup(uint256 roleId, uint256 groupId) external;

    function removeRoleFromGroup(uint256 roleId, uint256 groupId) external;

    function setGroupWiring(uint256 groupId, RoleWiring calldata w) external;

    function setRoleWiring(uint256 roleId, RoleWiring calldata w) external;

    function setRoleManagerConfig(uint256 roleId, uint256 managerHatId, uint8 caps) external;

    function setGroupManagerConfig(uint256 groupId, uint256 managerHatId, uint8 caps) external;

    function grantRole(uint256 roleId, address user) external;

    function revokeRole(uint256 roleId, address user) external;

    function registerExistingRole(uint256 hatId, string calldata name) external returns (uint256 roleId);

    function registerExistingGroup(uint256 markerHatId, string calldata name, uint256[] calldata memberRoleIds)
        external
        returns (uint256 groupId);

    /*────────────────── Views ──────────────────*/

    function isInOrg(address user) external view returns (bool);
    function getRole(uint256 roleId) external view returns (RoleInfo memory);
    function getGroup(uint256 groupId) external view returns (GroupInfo memory);
    function getRoleManagerConfig(uint256 roleId) external view returns (ManagerConfig memory);
    function getGroupManagerConfig(uint256 groupId) external view returns (ManagerConfig memory);
    function roleIdOfHat(uint256 hatId) external view returns (uint256);
    function roleCount() external view returns (uint256);
    function groupCount() external view returns (uint256);
    function orgHats() external view returns (uint256[] memory);
}
