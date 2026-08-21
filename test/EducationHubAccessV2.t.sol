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
    /// @notice Dual-path coverage for EducationHub's Access v2 remap (freeze §4.5): legacy Hats path
    ///         unchanged when the authority is unset, EDU_CREATE / EDU_MEMBER perm folds when set,
    ///         setMembershipAuthority auth + rollback-to-zero, and a legacy-vs-authority equality
    ///         differential (same conceptual membership, identical create/complete outcomes).
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
            hub.initialize(address(token), address(hats), executor, creatorHats, memberHats);

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

        /*───────────────────── Legacy path (regression) ─────────────────────*/
        function testLegacyPathUnchangedByDefault() public {
            assertEq(hub.membershipAuthority(), address(0));
            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);
            vm.prank(learner);
            hub.completeModule(0, 2);
            assertEq(token.balanceOf(learner), 5);
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

        /*───────────────────── Rollback to zero ─────────────────────*/
        function testRollbackRestoresLegacyPath() public {
            _setAuthority(address(auth));
            // Under the authority, the legacy learner (MEMBER_HAT only) cannot complete.
            _joinAuthority(creator, creatorRole);
            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 5, 2);
            vm.prank(learner);
            vm.expectRevert(EducationHub.NotMember.selector);
            hub.completeModule(0, 2);

            // Roll back.
            _setAuthority(address(0));
            assertEq(hub.membershipAuthority(), address(0));

            // Legacy MEMBER_HAT wearer completes again (byte-identical legacy path). Need a creator too:
            // the module already exists (created by the authority-side creator), so the legacy learner
            // just completes it.
            vm.prank(learner);
            hub.completeModule(0, 2);
            assertEq(token.balanceOf(learner), 5);
        }

        /*───────────────────── Equality differential (§5.2) ─────────────────────*/
        /// @notice Same org state expressed both ways gives identical create/complete outcomes: a legacy
        ///         MEMBER_HAT wearer and an authority EDU_MEMBER subject member both complete a module for
        ///         the same payout.
        function testEqualityDifferentialLegacyVsAuthority() public {
            // Legacy arm: learner wears MEMBER_HAT, creator wears CREATOR_HAT.
            vm.prank(creator);
            hub.createModule(bytes("data"), bytes32(0), 7, 2);
            vm.prank(learner);
            hub.completeModule(0, 2);
            uint256 legacyPayout = token.balanceOf(learner);

            // Authority arm: express the same membership via subjects. Fresh users, fresh hub.
            EducationHub impl = new EducationHub();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
            EducationHub hub2 = EducationHub(address(new BeaconProxy(address(beacon), "")));
            MockPTV2 token2 = new MockPTV2();
            uint256[] memory empty = new uint256[](0);
            hub2.initialize(address(token2), address(hats), executor, empty, empty);
            vm.prank(executor);
            hub2.setMembershipAuthority(address(auth));

            address creator2 = address(0xC2);
            address learner2 = address(0x12);
            _joinAuthority(creator2, creatorRole);
            _joinAuthority(learner2, memberRole);

            vm.prank(creator2);
            hub2.createModule(bytes("data"), bytes32(0), 7, 2);
            vm.prank(learner2);
            hub2.completeModule(0, 2);
            uint256 authorityPayout = token2.balanceOf(learner2);

            assertEq(authorityPayout, legacyPayout, "legacy and authority arms mint identically");
        }
    }
