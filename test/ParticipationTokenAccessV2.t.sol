// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ParticipationToken} from "../src/ParticipationToken.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

/// @title ParticipationTokenAccessV2Test
/// @notice PT_MEMBER/PT_APPROVE authority gates and rejected rollback.
contract ParticipationTokenAccessV2Test is Test {
    ParticipationToken internal pt;
    MockHats internal hats;
    MembershipAuthority internal auth;

    address internal executor = makeAddr("executor");
    address internal paymasterHub = address(0xBEEF);
    bytes32 internal constant ORG_ID = keccak256("org.pt.accessv2");

    address internal alice = makeAddr("alice"); // member
    address internal bob = makeAddr("bob"); // approver
    address internal outsider = makeAddr("outsider");

    uint256 internal constant MEMBER_HAT = 11;
    uint256 internal constant APPROVER_HAT = 22;

    event MembershipAuthoritySet(address indexed authority);

    function setUp() public {
        hats = new MockHats();

        ParticipationToken impl = new ParticipationToken();
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = MEMBER_HAT;
        uint256[] memory approverHats = new uint256[](1);
        approverHats[0] = APPROVER_HAT;
        bytes memory initCall = abi.encodeCall(ParticipationToken.initialize, (executor, "Participation", "PT"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initCall);
        pt = ParticipationToken(address(proxy));

        auth = _deployAuthority();
    }

    /*──────────────────── authority helpers ────────────────────*/

    function _deployAuthority() internal returns (MembershipAuthority a) {
        MembershipAuthority implA = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: executor, paymasterHub: paymasterHub, orgId: ORG_ID, seed: _emptySeed()
        });
        ERC1967Proxy proxy = new ERC1967Proxy(address(implA), abi.encodeCall(MembershipAuthority.initialize, (cfg)));
        a = MembershipAuthority(address(proxy));
        vm.prank(executor);
        a.setPaused(false);
    }

    function _emptySeed() internal pure returns (AccessV2Types.OrgAccessSeed memory s) {
        s.subjectIds = new uint256[](0);
        s.subjectKinds = new AccessV2Types.SubjectKind[](0);
        s.subjectNames = new string[](0);
        s.subjectMaxMembers = new uint32[](0);
        s.subjectDefaults = new bool[](0);
        s.groupMemberRoles = new uint256[][](0);
        s.vouchSubjects = new uint256[](0);
        s.vouchQuorums = new uint32[](0);
        s.vouchVoucherSubjects = new uint256[](0);
        s.permSubjects = new uint256[](0);
        s.permKeys = new bytes32[](0);
        s.permCtxs = new bytes32[](0);
        s.permWords = new uint256[](0);
    }

    function _role(string memory name) internal returns (uint256 id) {
        vm.prank(executor);
        id = auth.createRole(name, bytes32(0), "", 0);
    }

    function _makeMember(uint256 subject, address user) internal {
        vm.prank(executor);
        auth.setRule(subject, user, AccessV2Types.RuleKind.Grant, false);
        uint256[] memory subs = new uint256[](1);
        address[] memory users = new address[](1);
        subs[0] = subject;
        users[0] = user;
        vm.prank(executor);
        auth.seedMemberships(subs, users);
    }

    function _grantPerm(uint256 subject, bytes32 key) internal {
        vm.prank(executor);
        auth.setPerm(subject, key, bytes32(0), uint256(1) | AccessV2PermKeys.EXISTS_BIT);
    }

    /*──────────────────── setter auth + getter ────────────────────*/

    function test_setMembershipAuthority_onlyExecutor() public {
        vm.prank(outsider);
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        pt.setMembershipAuthority(address(auth));
    }

    function test_setMembershipAuthority_setsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(pt));
        emit MembershipAuthoritySet(address(auth));
        vm.prank(executor);
        pt.setMembershipAuthority(address(auth));
        assertEq(pt.membershipAuthority(), address(auth), "getter mismatch");

        vm.prank(executor);
        vm.expectRevert(ParticipationToken.InvalidAddress.selector);
        pt.setMembershipAuthority(address(0));
        assertEq(pt.membershipAuthority(), address(auth), "failed rollback preserves authority");
    }

    /*──────────────────── authority path ────────────────────*/

    function test_authorityPath_memberAndApprover() public {
        uint256 sMember = _role("Members");
        uint256 sApprover = _role("Approvers");
        _makeMember(sMember, alice);
        _makeMember(sApprover, bob);
        _grantPerm(sMember, AccessV2PermKeys.PT_MEMBER);
        _grantPerm(sApprover, AccessV2PermKeys.PT_APPROVE);

        vm.prank(executor);
        pt.setMembershipAuthority(address(auth));

        // Legacy hat wearers are now IGNORED — authority is the source of truth.
        hats.mintHat(MEMBER_HAT, outsider);
        vm.prank(outsider);
        vm.expectRevert(ParticipationToken.NotMember.selector);
        pt.requestTokens(1, "ipfs://z");

        // alice (PT_MEMBER via authority) can request.
        vm.prank(alice);
        pt.requestTokens(100, "ipfs://x");

        // bob lacking PT_MEMBER but holding PT_APPROVE can approve.
        vm.prank(bob);
        pt.approveRequest(1);
        assertEq(pt.balanceOf(alice), 100, "mint on approve (authority)");

        // A member without PT_APPROVE cannot approve.
        vm.prank(alice);
        pt.requestTokens(50, "ipfs://x2");
        vm.prank(alice);
        vm.expectRevert(ParticipationToken.NotApprover.selector);
        pt.approveRequest(2);
    }

    /*──────────────────── rollback ────────────────────*/
}
