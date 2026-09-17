// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EducationHub, IParticipationToken} from "../src/EducationHub.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

/// @dev Minimal ParticipationToken mock (mint only; no wiring gate needed for these tests).
contract MockPTV2 is IParticipationToken {
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;
    address public edu;

    function mint(address to, uint256 amount) external override {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setEducationHub(address eh) external override {
        edu = eh;
    }

    function educationHub() external view override returns (address) {
        return edu;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

    /// @title EducationHubAccessV2Test
    /// @notice EDU_CREATE/EDU_MEMBER authority gates, completed-module continuity and rejected rollback.
    contract EducationHubAccessV2Test is Test {
        EducationHub hub;
        MockPTV2 token;
        MockHats hats;
        MembershipAuthority auth;

        address executor = address(0xEF);
        address paymasterHub = address(0xBEEF);
        bytes32 constant ORG_ID = keccak256("edu.org");

        uint256 constant CREATOR_HAT = 1;
        uint256 constant MEMBER_HAT = 2;
        address creator = address(0xCA);
        address learner = address(0x1);
        address stranger = address(0xBAD);

        // Authority-side default-ALLOW role subjects carrying the EDU perms.
        uint256 creatorRole;
        uint256 memberRole;

        event MembershipAuthoritySet(address indexed authority);

        function setUp() public {
            token = new MockPTV2();
            hats = new MockHats();

            // Legacy wearers.
            hats.mintHat(CREATOR_HAT, creator);
            hats.mintHat(MEMBER_HAT, creator);
            hats.mintHat(MEMBER_HAT, learner);

            EducationHub impl = new EducationHub();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
            hub = EducationHub(address(new BeaconProxy(address(beacon), "")));
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT;
            uint256[] memory memberHats = new uint256[](1);
            memberHats[0] = MEMBER_HAT;
            hub.initialize(address(token), executor);

            // Real authority (executor = this test contract so config calls are direct).
            auth = _deployAuthority();
            creatorRole = _defaultAllowRoleWithPerm("EduCreators", AccessV2PermKeys.EDU_CREATE);
            memberRole = _defaultAllowRoleWithPerm("EduMembers", AccessV2PermKeys.EDU_MEMBER);
        }

        /*───────────────────── Authority harness helpers ─────────────────────*/
        function _deployAuthority() internal returns (MembershipAuthority a) {
            MembershipAuthority implA = new MembershipAuthority();
            IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
                executor: address(this), paymasterHub: paymasterHub, orgId: ORG_ID, seed: _emptySeed()
            });
            ERC1967Proxy proxy = new ERC1967Proxy(address(implA), abi.encodeCall(MembershipAuthority.initialize, (cfg)));
            a = MembershipAuthority(address(proxy));
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

        function _defaultAllowRoleWithPerm(string memory name, bytes32 permKey) internal returns (uint256 id) {
            id = auth.createRole(name, bytes32(0), "", 0);
            auth.setSubjectDefault(id, true, false);
            auth.setPerm(id, permKey, bytes32(0), 1 | (uint256(1) << 255)); // {exists, value=1}
        }

        function _joinAuthority(address user, uint256 subject) internal {
            vm.prank(user);
            auth.claim(subject);
        }

        function _setAuthority(address a) internal {
            vm.prank(executor);
            hub.setMembershipAuthority(a);
        }

        /*───────────────────── setMembershipAuthority auth ─────────────────────*/
        function testSetMembershipAuthorityOnlyExecutor() public {
            vm.prank(stranger);
            vm.expectRevert(EducationHub.NotExecutor.selector);
            hub.setMembershipAuthority(address(auth));
        }

        function testSetMembershipAuthorityEmits() public {
            vm.expectEmit(true, false, false, false, address(hub));
            emit MembershipAuthoritySet(address(auth));
            _setAuthority(address(auth));
            assertEq(hub.membershipAuthority(), address(auth));

            vm.prank(executor);
            vm.expectRevert(EducationHub.ZeroAddress.selector);
            hub.setMembershipAuthority(address(0));
            assertEq(hub.membershipAuthority(), address(auth), "failed rollback preserves authority");
        }

        /*───────────────────── Authority path (frozen key shapes) ─────────────────────*/
        function testAuthorityPathCreatorGate() public {
            _setAuthority(address(auth));
            _joinAuthority(creator, creatorRole);

            // creator is now an EDU_CREATE holder via the authority; MockHats wearership is irrelevant.
            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);
            (uint256 payout, bool exists) = hub.getModule(0);
            assertEq(payout, 5);
            assertTrue(exists);
        }

        function testAuthorityPathNonCreatorRejected() public {
            _setAuthority(address(auth));
            // stranger holds neither a legacy creator hat nor the EDU_CREATE subject.
            vm.prank(stranger);
            vm.expectRevert(EducationHub.NotCreator.selector);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);
        }

        function testAuthorityPathMemberGate() public {
            _setAuthority(address(auth));
            _joinAuthority(creator, creatorRole);
            _joinAuthority(learner, memberRole);

            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);
            vm.prank(learner);
            hub.completeModule(0, 2);
            assertEq(token.balanceOf(learner), 5);
        }

        function testAuthorityPathNonMemberRejected() public {
            _setAuthority(address(auth));
            _joinAuthority(creator, creatorRole);
            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);

            // learner wears MEMBER_HAT (legacy) but is NOT an EDU_MEMBER subject member → rejected.
            vm.prank(learner);
            vm.expectRevert(EducationHub.NotMember.selector);
            hub.completeModule(0, 2);
        }

        /// @notice Same org state expressed both ways gives identical create/complete outcomes: a legacy
        ///         MEMBER_HAT wearer and an authority EDU_MEMBER subject member both complete a module for
        ///         the same payout.
    }
