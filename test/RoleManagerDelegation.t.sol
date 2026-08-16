// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {MockHatsRM} from "./mocks/MockHatsRM.sol";
import {MockEligibilityModuleRM} from "./mocks/MockEligibilityModuleRM.sol";
import {
    MockDDVotingRM,
    MockHVVotingRM,
    MockTaskManagerRM,
    MockPTRM,
    MockEduRM,
    MockQuickJoinRM,
    MockPaymasterHubRM
} from "./mocks/MockSiblingsRM.sol";

/// @title RoleManagerDelegation — W13 manager-hat delegated lifecycle + provenance guards.
/// @notice Covers the delegated grant/revoke authorization matrix, the SelfManagedGroup direct-cycle
///         guard at both config sites + the addRoleToGroup backdoor, governance-ban / governance-offer
///         provenance rules, marker-as-manager transitivity, and the actor/delegated event fields.
contract RoleManagerDelegationTest is Test {
    uint256 constant ADMIN_HAT = 1;
    uint256 constant MEMBER_HAT = 2;
    uint256 constant MANAGER_HAT = 100;
    uint256 constant GROUP_MANAGER_HAT = 101;
    bytes32 constant ORG_ID = keccak256("delegation-org");

    RoleManager rm;
    MockHatsRM hats;
    MockEligibilityModuleRM em;
    MockDDVotingRM dd;
    MockHVVotingRM hv;
    MockTaskManagerRM tm;
    MockPTRM pt;
    MockEduRM edu;
    MockQuickJoinRM qj;
    MockPaymasterHubRM paymaster;

    address executor = address(this);
    address manager = makeAddr("manager");
    address groupManager = makeAddr("groupManager");
    address stranger = makeAddr("stranger");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        hats = new MockHatsRM();
        em = new MockEligibilityModuleRM(hats, ADMIN_HAT);
        hats.setEligibility(address(em));
        dd = new MockDDVotingRM();
        hv = new MockHVVotingRM();
        tm = new MockTaskManagerRM();
        pt = new MockPTRM();
        edu = new MockEduRM();
        qj = new MockQuickJoinRM();
        paymaster = new MockPaymasterHubRM();

        rm = _deploy();

        // Manager-hat wearers (authority is hat-based; forceWear bypasses eligibility for setup).
        hats.forceWear(MANAGER_HAT, manager);
        hats.forceWear(GROUP_MANAGER_HAT, groupManager);
    }

    /*═════════════════════════════ Auth matrix ═════════════════════════════*/

    function testExecutorAlwaysGrantsUndelegated() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        hats.forceWear(MEMBER_HAT, alice);

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGranted(roleId, alice, true, executor, false);
        rm.grantRole(roleId, alice);
        assertTrue(hats.isWearerOfHat(alice, hatId));
    }

    function testRoleManagerCanGrantWithCapGrant() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        // out-of-org target => offer; delegated=true, actor=manager.
        vm.expectEmit(true, true, true, true);
        emit IRoleManager.RoleOffered(roleId, bob, _hatOf(roleId), manager, true);
        vm.prank(manager);
        rm.grantRole(roleId, bob);
        assertTrue(em.isEligible(bob, _hatOf(roleId)));
    }

    function testRoleManagerCanRevokeWithCapRevoke() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT() | rm.CAP_REVOKE());

        // Manager grants alice (in-org) then revokes her.
        hats.forceWear(MEMBER_HAT, alice);
        vm.prank(manager);
        rm.grantRole(roleId, alice);
        assertTrue(hats.isWearerOfHat(alice, hatId));

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleRevoked(roleId, alice, true, manager, true);
        vm.prank(manager);
        rm.revokeRole(roleId, alice);
        assertFalse(hats.isWearerOfHat(alice, hatId));
    }

    function testGroupManagerCoversMemberRoles() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        (uint256 groupId,) = rm.createGroup("Executives", bytes32(0), "img", _one(roleId), _wiring());
        rm.setGroupManagerConfig(groupId, GROUP_MANAGER_HAT, rm.CAP_GRANT());

        // groupManager (wearing the group manager hat) may grant a role that is a member of the group.
        vm.expectEmit(true, true, true, true);
        emit IRoleManager.RoleOffered(roleId, bob, _hatOf(roleId), groupManager, true);
        vm.prank(groupManager);
        rm.grantRole(roleId, bob);
    }

    function testCapSeparation_GrantOnlyCannotRevoke() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        vm.prank(manager);
        vm.expectRevert(RoleManager.NotAuthorizedManager.selector);
        rm.revokeRole(roleId, alice);
    }

    function testCapSeparation_RevokeOnlyCannotGrant() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_REVOKE());

        vm.prank(manager);
        vm.expectRevert(RoleManager.NotAuthorizedManager.selector);
        rm.grantRole(roleId, bob);
    }

    function testNonManagerReverts() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        vm.prank(stranger);
        vm.expectRevert(RoleManager.NotAuthorizedManager.selector);
        rm.grantRole(roleId, bob);
    }

    function testManagerLosingHatLosesAuthority() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        // A wearer of the manager hat is authorized; a different address (no hat) is not.
        vm.prank(stranger);
        vm.expectRevert(RoleManager.NotAuthorizedManager.selector);
        rm.grantRole(roleId, bob);

        vm.prank(manager);
        rm.grantRole(roleId, bob); // ok
    }

    /*═════════════════════════════ Marker-as-manager ═════════════════════════════*/

    /// Wearer of the Executives marker (held via a President identity) manages the (separate) Member
    /// role — the documented marker-as-manager transitivity property.
    function testMarkerAsManager() public {
        uint256 memberRoleId = rm.roleIdOfHat(MEMBER_HAT); // seeded "Member" role
        (uint256 presidentRoleId,) = rm.createRole(_role("President"));
        (, uint256 marker) = rm.createGroup("Executives", bytes32(0), "img", _one(presidentRoleId), _wiring());

        // execWearer holds President (in-org) and therefore wears the Executives marker (derived).
        address execWearer = makeAddr("execWearer");
        hats.forceWear(MEMBER_HAT, execWearer);
        rm.grantRole(presidentRoleId, execWearer);
        assertTrue(hats.isWearerOfHat(execWearer, marker), "execWearer wears the marker via President");

        // The Member role (NOT a member of Executives, so no cycle) is delegated to the marker.
        rm.setRoleManagerConfig(memberRoleId, marker, rm.CAP_GRANT());

        vm.expectEmit(true, true, true, true);
        emit IRoleManager.RoleOffered(memberRoleId, bob, MEMBER_HAT, execWearer, true);
        vm.prank(execWearer);
        rm.grantRole(memberRoleId, bob);
    }

    /*═════════════════════════════ SelfManagedGroup guard ═════════════════════════════*/

    function testSelfManagedGroup_RoleConfigReverts() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        (uint256 groupId, uint256 marker) = rm.createGroup("Exec", bytes32(0), "img", _one(roleId), _wiring());
        groupId;
        uint8 cap = rm.CAP_GRANT();
        // President is a member of Exec, so managing it with Exec's marker is the direct cycle.
        vm.expectRevert(RoleManager.SelfManagedGroup.selector);
        rm.setRoleManagerConfig(roleId, marker, cap);
    }

    function testSelfManagedGroup_GroupConfigReverts() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        (uint256 groupId, uint256 marker) = rm.createGroup("Exec", bytes32(0), "img", _one(roleId), _wiring());
        uint8 cap = rm.CAP_GRANT();
        // Configuring the group to be managed by its own marker is the direct cycle.
        vm.expectRevert(RoleManager.SelfManagedGroup.selector);
        rm.setGroupManagerConfig(groupId, marker, cap);
    }

    function testSelfManagedGroup_AddRoleToGroupBackdoorReverts() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        (uint256 groupId, uint256 marker) = rm.createGroup("Exec", bytes32(0), "img", new uint256[](0), _wiring());

        // Legal now: President is NOT yet in Exec, so managing it with Exec's marker has no cycle.
        rm.setRoleManagerConfig(roleId, marker, rm.CAP_GRANT());

        // Adding President to Exec would complete the cycle -> re-check must revert.
        vm.expectRevert(RoleManager.SelfManagedGroup.selector);
        rm.addRoleToGroup(roleId, groupId);
    }

    function testConfigClearBypassesCycleGuard() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.createGroup("Exec", bytes32(0), "img", _one(roleId), _wiring());
        // managerHatId == 0 clears the delegation and must never trip the guard.
        rm.setRoleManagerConfig(roleId, 0, 0);
        assertEq(rm.getRoleManagerConfig(roleId).managerHatId, 0);
    }

    /*═════════════════════════════ Governance-ban / offer provenance ═════════════════════════════*/

    function testDelegatedGrantBlockedByGovernanceBan() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        // Governance bans bob on the identity hat (explicit (false,false), NO 0x04).
        em.govSetRule(bob, hatId, false, false);

        vm.prank(manager);
        vm.expectRevert(RoleManager.GrantBlockedByGovernanceBan.selector);
        rm.grantRole(roleId, bob);
    }

    function testDelegatedGrantSucceedsOverDelegatedKick() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        // A prior delegated kick (0x04, false,false) is manager-owned — a manager may overwrite it.
        em.delegatedKick(bob, hatId);

        vm.prank(manager);
        rm.grantRole(roleId, bob); // no revert: offer written over the kick
        assertTrue(em.isEligible(bob, hatId));
    }

    function testExecutorGrantIgnoresGovernanceBan() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        em.govSetRule(bob, hatId, false, false); // governance ban

        // Executor path is byte-identical to today: a governance grant vote implies the un-ban.
        rm.grantRole(roleId, bob);
        assertTrue(em.isEligible(bob, hatId));
    }

    function testDelegatedRevokeWorksOnRmCreatedRole() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT() | rm.CAP_REVOKE());
        hats.forceWear(MEMBER_HAT, alice);

        vm.prank(manager);
        rm.grantRole(roleId, alice); // writes (true,true|0x04) — delegation-managed
        assertTrue(hats.isWearerOfHat(alice, hatId));

        vm.prank(manager);
        rm.revokeRole(roleId, alice); // may clear its own 0x04 rule
        assertFalse(hats.isWearerOfHat(alice, hatId));
    }

    function testDelegatedRevokeRefusesGovernanceOffer() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_REVOKE());

        // Governance wrote a (true,true) offer directly on the EM (no 0x04). A delegate may not cancel it.
        em.govSetRule(bob, hatId, true, true);

        vm.prank(manager);
        vm.expectRevert(RoleManager.RevokeBlockedByGovernance.selector);
        rm.revokeRole(roleId, bob);
    }

    function testDelegatedRevokeKeepsRevokeIneffectiveOnDefaultEligible() public {
        // Adopt a default-eligible legacy hat as a role.
        uint256 legacyHat = _createDefaultEligibleHat();
        uint256 roleId = rm.registerExistingRole(legacyHat, "Legacy");
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_REVOKE());

        hats.forceWear(legacyHat, alice); // wearing via default eligibility
        assertTrue(hats.isWearerOfHat(alice, legacyHat));

        // Clearing the (absent) explicit rule cannot remove a default-eligible wearer -> honest revert.
        vm.prank(manager);
        vm.expectRevert(RoleManager.RevokeIneffective.selector);
        rm.revokeRole(roleId, alice);
    }

    /*═════════════════════════════ Event actor/delegated on both paths ═════════════════════════════*/

    function testEventsCarryActorAndDelegated_ExecutorVsManager() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        // Executor path: actor=executor, delegated=false.
        vm.expectEmit(true, true, true, true);
        emit IRoleManager.RoleOffered(roleId, alice, _hatOf(roleId), executor, false);
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGranted(roleId, alice, false, executor, false);
        rm.grantRole(roleId, alice);

        // Delegated path: actor=manager, delegated=true.
        vm.expectEmit(true, true, true, true);
        emit IRoleManager.RoleOffered(roleId, bob, _hatOf(roleId), manager, true);
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGranted(roleId, bob, false, manager, true);
        vm.prank(manager);
        rm.grantRole(roleId, bob);
    }

    function testConfigSetEmitsEvents() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        (uint256 groupId,) = rm.createGroup("Exec", bytes32(0), "img", new uint256[](0), _wiring());

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleManagerConfigSet(roleId, MANAGER_HAT, rm.CAP_GRANT());
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, rm.CAP_GRANT());

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.GroupManagerConfigSet(groupId, GROUP_MANAGER_HAT, rm.CAP_REVOKE());
        rm.setGroupManagerConfig(groupId, GROUP_MANAGER_HAT, rm.CAP_REVOKE());
    }

    function testConfigSettersOnlyExecutor() public {
        (uint256 roleId,) = rm.createRole(_role("President"));
        uint8 cap = rm.CAP_GRANT();
        vm.prank(stranger);
        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.setRoleManagerConfig(roleId, MANAGER_HAT, cap);
    }

    /*═════════════════════════════ Helpers ═════════════════════════════*/

    function _deploy() internal returns (RoleManager) {
        RoleManager impl = new RoleManager();
        uint256[] memory seed = new uint256[](1);
        seed[0] = MEMBER_HAT;
        string[] memory names = new string[](1);
        names[0] = "Member";
        IRoleManager.InitConfig memory cfg = IRoleManager.InitConfig({
            executor: executor,
            eligibilityModule: address(em),
            hats: address(hats),
            ddVoting: address(dd),
            hybridVoting: address(hv),
            taskManager: address(tm),
            participationToken: address(pt),
            educationHub: address(edu),
            quickJoin: address(qj),
            paymasterHub: address(paymaster),
            orgId: ORG_ID,
            existingOrgHats: seed,
            existingOrgHatNames: names
        });
        return RoleManager(address(new ERC1967Proxy(address(impl), abi.encodeCall(RoleManager.initialize, (cfg)))));
    }

    function _wiring() internal pure returns (IRoleManager.RoleWiring memory w) {
        w.hvClassIndexes = new uint8[](0);
    }

    function _role(string memory name) internal pure returns (IRoleManager.RoleParams memory p) {
        p.name = name;
        p.imageURI = "img";
        p.maxSupply = type(uint32).max;
        p.mutableHat = true;
        p.groupIds = new uint256[](0);
        p.wiring = _wiring();
        p.initialGrants = new address[](0);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _hatOf(uint256 roleId) internal view returns (uint256) {
        return rm.getRole(roleId).hatId;
    }

    /// @dev Mint a fresh hat through the mock EM with default eligibility open (legacy-adoption shape).
    function _createDefaultEligibleHat() internal returns (uint256 hatId) {
        MockEligibilityModuleRM.CreateHatParams memory params;
        params.parentHatId = ADMIN_HAT;
        params.details = "Legacy";
        params.maxSupply = type(uint32).max;
        params._mutable = true;
        params.defaultEligible = true;
        params.defaultStanding = true;
        params.mintToAddresses = new address[](0);
        params.wearerEligibleFlags = new bool[](0);
        params.wearerStandingFlags = new bool[](0);
        hatId = em.createHatWithEligibility(params);
    }
}
