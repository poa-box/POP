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

contract RoleManagerTest is Test {
    uint256 constant ADMIN_HAT = 1;
    uint256 constant MEMBER_HAT = 2;
    uint256 constant FIRST_CREATED_HAT = 1000; // MockEligibilityModuleRM.nextHatId start
    bytes32 constant ORG_ID = keccak256("org");

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

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address stranger = address(0x5713A6);

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

        rm = _deploy(_baseConfig(_arr1(MEMBER_HAT), _names1("Member")));
    }

    /*────────────────── Helpers ──────────────────*/

    function _deploy(IRoleManager.InitConfig memory cfg) internal returns (RoleManager) {
        RoleManager impl = new RoleManager();
        bytes memory data = abi.encodeCall(RoleManager.initialize, (cfg));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        return RoleManager(address(proxy));
    }

    function _baseConfig(uint256[] memory seedHats, string[] memory seedNames)
        internal
        view
        returns (IRoleManager.InitConfig memory cfg)
    {
        cfg = IRoleManager.InitConfig({
            executor: address(this),
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
            existingOrgHats: seedHats,
            existingOrgHatNames: seedNames
        });
    }

    function _emptyWiring() internal pure returns (IRoleManager.RoleWiring memory w) {
        w.hvClassIndexes = new uint8[](0);
    }

    function _roleParams(string memory name) internal pure returns (IRoleManager.RoleParams memory p) {
        p.name = name;
        p.imageURI = "img";
        p.maxSupply = type(uint32).max;
        p.mutableHat = true;
        p.groupIds = new uint256[](0);
        p.wiring = _emptyWiring();
        p.initialGrants = new address[](0);
    }

    function _arr1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _names1(string memory a) internal pure returns (string[] memory r) {
        r = new string[](1);
        r[0] = a;
    }

    /*────────────────── initialize ──────────────────*/

    function testInitializeSeedsRolesAndEmitsExisting() public {
        uint256[] memory seeds = _arr2(11, 22);
        string[] memory names = new string[](2);
        names[0] = "President";
        names[1] = "Member";

        RoleManager fresh = new RoleManager();
        bytes memory data = abi.encodeCall(RoleManager.initialize, (_baseConfig(seeds, names)));

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleCreated(1, 11, "President", bytes32(0), true);
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleCreated(2, 22, "Member", bytes32(0), true);
        ERC1967Proxy proxy = new ERC1967Proxy(address(fresh), data);
        RoleManager r = RoleManager(address(proxy));

        assertEq(r.roleCount(), 2);
        assertEq(r.roleIdOfHat(11), 1);
        assertEq(r.roleIdOfHat(22), 2);
        assertEq(r.orgHats().length, 2);
        assertEq(r.getRole(1).name, "President");
    }

    function testInitializeArrayMismatchReverts() public {
        uint256[] memory seeds = _arr2(11, 22);
        string[] memory names = _names1("only-one");
        RoleManager fresh = new RoleManager();
        bytes memory data = abi.encodeCall(RoleManager.initialize, (_baseConfig(seeds, names)));
        vm.expectRevert(RoleManager.ArrayLengthMismatch.selector);
        new ERC1967Proxy(address(fresh), data);
    }

    function testCannotReinitialize() public {
        vm.expectRevert();
        rm.initialize(_baseConfig(new uint256[](0), new string[](0)));
    }

    /*────────────────── createRole ──────────────────*/

    function testCreateRoleRegistersAndIndexes() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));
        assertEq(hatId, FIRST_CREATED_HAT);
        assertEq(roleId, 2); // roleId 1 is the seeded Member
        assertEq(rm.roleIdOfHat(hatId), roleId);
        assertEq(rm.getRole(roleId).name, "President");
        assertEq(rm.getRole(roleId).hatId, hatId);
        // identity hat is defaultEligible=false (LOCKED)
        assertFalse(em.defaultEligible(hatId));
        // auto-appended to orgHats
        assertEq(rm.orgHats().length, 2);
        assertEq(rm.orgHats()[1], hatId);
    }

    function testCreateRoleWiringFanOut() public {
        IRoleManager.RoleParams memory p = _roleParams("President");
        p.wiring.setTaskPerm = true;
        p.wiring.taskPermMask = 0x07;
        p.wiring.ddVoter = true;
        p.wiring.ddCreator = true;
        p.wiring.hvCreator = true;
        p.wiring.hvClassIndexes = new uint8[](2);
        p.wiring.hvClassIndexes[0] = 0;
        p.wiring.hvClassIndexes[1] = 1;
        p.wiring.ptMember = true;
        p.wiring.ptApprover = true;
        p.wiring.eduCreator = true;
        p.wiring.eduMember = true;
        // quickJoinAutoMint deliberately absent: identity hats are defaultEligible=false, and the
        // WiringIncompatible guard rejects auto-mint wiring for closed hats (see the guard tests).
        p.wiring.vouchingEnabled = true;
        p.wiring.vouchQuorum = 3;
        p.wiring.vouchCombine = true; // combine=false is rejected (breaks the grant/offer model)
        p.wiring.budgetCapPerEpoch = 1 ether;
        p.wiring.budgetEpochLen = 86400;

        (, uint256 hatId) = rm.createRole(p);

        // TaskManager ROLE_PERM (key index 2)
        assertEq(tm.callCount(), 1);
        (uint8 tmKey, bytes memory tmVal) = tm.callAt(0);
        assertEq(tmKey, 2);
        (uint256 tmHat, uint8 mask) = abi.decode(tmVal, (uint256, uint8));
        assertEq(tmHat, hatId);
        assertEq(mask, 0x07);

        // DD: VOTING then CREATOR, both key HAT_ALLOWED (index 3), allowed=true
        assertEq(dd.callCount(), 2);
        (uint8 ddKey0, bytes memory ddVal0) = dd.callAt(0);
        assertEq(ddKey0, 3);
        (uint8 hatType0, uint256 ddHat0, bool ok0) = abi.decode(ddVal0, (uint8, uint256, bool));
        assertEq(hatType0, 0); // VOTING
        assertEq(ddHat0, hatId);
        assertTrue(ok0);
        (, bytes memory ddVal1) = dd.callAt(1);
        (uint8 hatType1,, bool ok1) = abi.decode(ddVal1, (uint8, uint256, bool));
        assertEq(hatType1, 1); // CREATOR
        assertTrue(ok1);

        // HV creator + 2 class edits
        assertTrue(hv.creatorAllowed(hatId));
        assertEq(hv.classEditCount(), 2);

        // PT + Edu
        assertTrue(pt.memberAllowed(hatId));
        assertTrue(pt.approverAllowed(hatId));
        assertTrue(edu.creatorAllowed(hatId));
        assertTrue(edu.memberAllowed(hatId));

        // QuickJoin untouched (auto-mint wiring is invalid for default-closed identity hats)
        assertEq(qj.memberHatIds().length, 0);

        // Vouching configured
        assertTrue(em.vouchConfigured(hatId));
        assertEq(em.lastVouchQuorum(hatId), 3);

        // Paymaster budget recorded
        assertEq(paymaster.callCount(), 1);
    }

    function testCreateRoleEmitsRoleCreated() public {
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleCreated(2, FIRST_CREATED_HAT, "VP", bytes32(uint256(0xCAFE)), false);
        IRoleManager.RoleParams memory p = _roleParams("VP");
        p.metadataCID = bytes32(uint256(0xCAFE));
        rm.createRole(p);
    }

    /*────────────────── createGroup + derived eligibility ──────────────────*/

    function testCreateGroupConfiguresDerivedEligibility() public {
        (uint256 r1, uint256 h1) = rm.createRole(_roleParams("President"));
        (uint256 r2, uint256 h2) = rm.createRole(_roleParams("VP"));

        // groupId topic + data (name, metadataCID) are asserted; markerHatId topic is unknown pre-call.
        vm.expectEmit(true, false, false, true);
        emit IRoleManager.GroupCreated(1, 0, "Executives", bytes32(0));
        (uint256 groupId, uint256 markerHat) =
            rm.createGroup("Executives", bytes32(0), "img", _arr2(r1, r2), _emptyWiring());

        assertEq(rm.groupCount(), 1);
        assertEq(rm.getGroup(groupId).markerHatId, markerHat);
        uint256[] memory members = em.getGroupMemberHats(markerHat);
        assertEq(members.length, 2);
        assertEq(members[0], h1);
        assertEq(members[1], h2);
        // marker appended to orgHats
        assertEq(rm.orgHats()[rm.orgHats().length - 1], markerHat);
        // marker maxSupply = type(uint32).max
        assertEq(em.lastMaxSupply(markerHat), type(uint32).max);
    }

    /*────────────────── consent model ──────────────────*/

    function testGrantInOrgMintsIdentity() public {
        hats.forceWear(MEMBER_HAT, alice); // alice is in org
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGranted(roleId, alice, true);
        rm.grantRole(roleId, alice);

        assertTrue(hats.isWearerOfHat(alice, hatId));
        assertEq(hats.balanceOf(alice, hatId), 1);
    }

    function testGrantOutOfOrgOffersAndMintsNothing() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));

        vm.expectEmit(true, true, true, false);
        emit IRoleManager.RoleOffered(roleId, bob, hatId);
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGranted(roleId, bob, false);
        rm.grantRole(roleId, bob); // bob NOT in org

        // eligible via explicit rule, but NOT a wearer — nothing minted
        assertTrue(em.isEligible(bob, hatId));
        assertFalse(hats.isWearerOfHat(bob, hatId));
        assertEq(hats.balanceOf(bob, hatId), 0);
    }

    function testGrantAgainAfterJoiningMints() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));

        // 1) out-of-org: offer only
        rm.grantRole(roleId, bob);
        assertEq(hats.balanceOf(bob, hatId), 0);

        // 2) bob joins the org, re-grant -> minted
        hats.forceWear(MEMBER_HAT, bob);
        rm.grantRole(roleId, bob);
        assertEq(hats.balanceOf(bob, hatId), 1);
    }

    function testGrantInGroupMintsMarker() public {
        hats.forceWear(MEMBER_HAT, alice);
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));
        (, uint256 markerHat) = rm.createGroup("Executives", bytes32(0), "img", _arr1(roleId), _emptyWiring());

        rm.grantRole(roleId, alice);

        assertEq(hats.balanceOf(alice, hatId), 1);
        assertEq(hats.balanceOf(alice, markerHat), 1); // derived-eligible via identity, minted
    }

    /*────────────────── revoke ──────────────────*/

    function testRevokeZeroesIdentityAndMarkerAutoFollows() public {
        hats.forceWear(MEMBER_HAT, alice);
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));
        (, uint256 markerHat) = rm.createGroup("Executives", bytes32(0), "img", _arr1(roleId), _emptyWiring());
        rm.grantRole(roleId, alice);
        assertEq(hats.balanceOf(alice, hatId), 1);
        assertEq(hats.balanceOf(alice, markerHat), 1);

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleRevoked(roleId, alice, true);
        rm.revokeRole(roleId, alice);

        assertEq(hats.balanceOf(alice, hatId), 0); // identity eligibility cleared
        assertEq(hats.balanceOf(alice, markerHat), 0); // marker auto-follows (derived) - no burn
    }

    function testRevokeUnclaimedOfferClearsRule() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));
        rm.grantRole(roleId, bob); // offer
        assertTrue(em.isEligible(bob, hatId));

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleRevoked(roleId, bob, false); // never wearing
        rm.revokeRole(roleId, bob);

        assertFalse(em.isEligible(bob, hatId)); // offer withdrawn
    }

    /*────────────────── registerExisting ──────────────────*/

    function testRegisterExistingRole() public {
        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleCreated(2, 777, "Treasurer", bytes32(0), true);
        uint256 roleId = rm.registerExistingRole(777, "Treasurer");
        assertEq(roleId, 2);
        assertEq(rm.roleIdOfHat(777), 2);
        assertEq(rm.getRole(2).name, "Treasurer");
    }

    function testRegisterExistingGroup() public {
        (uint256 r1, uint256 h1) = rm.createRole(_roleParams("President"));
        (uint256 r2, uint256 h2) = rm.createRole(_roleParams("VP"));

        uint256 groupId = rm.registerExistingGroup(555, "Executives", _arr2(r1, r2));
        assertEq(groupId, 1);
        assertEq(rm.getGroup(groupId).markerHatId, 555);
        uint256[] memory members = em.getGroupMemberHats(555);
        assertEq(members.length, 2);
        assertEq(members[0], h1);
        assertEq(members[1], h2);
    }

    /*────────────────── group membership edits ──────────────────*/

    function testAddAndRemoveRoleFromGroup() public {
        (uint256 r1, uint256 h1) = rm.createRole(_roleParams("President"));
        (uint256 groupId, uint256 markerHat) =
            rm.createGroup("Executives", bytes32(0), "img", new uint256[](0), _emptyWiring());
        assertEq(em.getGroupMemberHats(markerHat).length, 0);

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGroupMembershipChanged(r1, groupId, true);
        rm.addRoleToGroup(r1, groupId);
        assertEq(em.getGroupMemberHats(markerHat).length, 1);
        assertEq(em.getGroupMemberHats(markerHat)[0], h1);

        vm.expectEmit(true, true, false, true);
        emit IRoleManager.RoleGroupMembershipChanged(r1, groupId, false);
        rm.removeRoleFromGroup(r1, groupId);
        assertEq(em.getGroupMemberHats(markerHat).length, 0);
    }

    function testAddRoleToGroupTwiceReverts() public {
        (uint256 r1,) = rm.createRole(_roleParams("President"));
        (uint256 groupId,) = rm.createGroup("Executives", bytes32(0), "img", _arr1(r1), _emptyWiring());
        vm.expectRevert(RoleManager.AlreadyInGroup.selector);
        rm.addRoleToGroup(r1, groupId);
    }

    function testRemoveRoleNotInGroupReverts() public {
        (uint256 r1,) = rm.createRole(_roleParams("President"));
        (uint256 groupId,) = rm.createGroup("Executives", bytes32(0), "img", new uint256[](0), _emptyWiring());
        vm.expectRevert(RoleManager.NotInGroup.selector);
        rm.removeRoleFromGroup(r1, groupId);
    }

    /*────────────────── re-apply wiring ──────────────────*/

    function testSetRoleWiringReapplies() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_roleParams("President"));
        // grant ddVoter=true
        IRoleManager.RoleWiring memory w = _emptyWiring();
        w.ddVoter = true;
        rm.setRoleWiring(roleId, w);
        uint256 countBefore = dd.callCount();

        // now remove it via explicit false flag
        IRoleManager.RoleWiring memory w2 = _emptyWiring();
        w2.ddVoter = false;
        rm.setRoleWiring(roleId, w2);

        // last VOTING call carries allowed=false
        (, bytes memory val) = dd.callAt(dd.callCount() - 2); // VOTING is emitted before CREATOR
        (uint8 hatType,, bool ok) = abi.decode(val, (uint8, uint256, bool));
        assertEq(hatType, 0);
        assertFalse(ok);
        assertGt(dd.callCount(), countBefore);
        hatId; // silence
    }

    function testSetGroupWiringReverts_UnknownGroup() public {
        vm.expectRevert(RoleManager.UnknownGroup.selector);
        rm.setGroupWiring(99, _emptyWiring());
    }

    function testSetRoleWiringReverts_UnknownRole() public {
        vm.expectRevert(RoleManager.UnknownRole.selector);
        rm.setRoleWiring(99, _emptyWiring());
    }

    /*────────────────── paymaster budget best-effort ──────────────────*/

    function testBudgetSkippedOnPaymasterRevert() public {
        paymaster.setShouldRevert(true);
        IRoleManager.RoleParams memory p = _roleParams("President");
        p.wiring.budgetCapPerEpoch = 1 ether;
        p.wiring.budgetEpochLen = 3600;

        vm.expectEmit(true, false, false, false);
        emit IRoleManager.BudgetSkipped(FIRST_CREATED_HAT);
        rm.createRole(p); // must NOT revert
        assertEq(paymaster.callCount(), 0);
    }

    /*────────────────── auth ──────────────────*/

    function testOnlyExecutorMutations() public {
        (uint256 roleId,) = rm.createRole(_roleParams("President"));
        (uint256 groupId,) = rm.createGroup("Executives", bytes32(0), "img", new uint256[](0), _emptyWiring());

        vm.startPrank(stranger);

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.createRole(_roleParams("X"));

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.createGroup("Y", bytes32(0), "img", new uint256[](0), _emptyWiring());

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.grantRole(roleId, alice);

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.revokeRole(roleId, alice);

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.addRoleToGroup(roleId, groupId);

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.removeRoleFromGroup(roleId, groupId);

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.setRoleWiring(roleId, _emptyWiring());

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.setGroupWiring(groupId, _emptyWiring());

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.registerExistingRole(1234, "Z");

        vm.expectRevert(RoleManager.NotExecutor.selector);
        rm.registerExistingGroup(1234, "Z", new uint256[](0));

        vm.stopPrank();
    }

    function testGrantUnknownRoleReverts() public {
        vm.expectRevert(RoleManager.UnknownRole.selector);
        rm.grantRole(99, alice);
    }
}
