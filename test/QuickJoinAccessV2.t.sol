// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {QuickJoin} from "../src/QuickJoin.sol";
import {Executor} from "../src/Executor.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {MockRegistry} from "./QuickJoin.t.sol";
import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";

/// @title QuickJoinAccessV2Test
/// @notice Dual-path coverage for QuickJoin's Access v2 remap (freeze §4.6). Legacy path mints the
///         `memberHatIds` list through the (unchanged) Executor.mintHatsForUser loop; the authority
///         path enumerates the QJ_AUTOJOIN default-ALLOW subjects and mints them through the SAME
///         Executor loop, whose repointed `l.hats.mintHat` resolves against the authority. Includes
///         the frozen equality differential: the legacy hats list and the authority QJ_AUTOJOIN
///         subject list produce the same mints.
contract QuickJoinAccessV2Test is Test {
    Executor exec;
    QuickJoin qj;
    MockHats legacyHats;
    MockRegistry registry;
    MembershipAuthority auth;

    address master = address(0x2);
    address paymasterHub = address(0xBEEF);
    bytes32 constant ORG_ID = keccak256("qj.org");
    uint256 constant LEGACY_HAT = 1;

    address user = address(0x100);

    event MembershipAuthoritySet(address indexed authority);
    event QuickJoined(address indexed user, uint256[] hatIds);

    function setUp() public {
        legacyHats = new MockHats();
        registry = new MockRegistry();

        // Real Executor (owner = this = governance).
        Executor execImpl = new Executor();
        UpgradeableBeacon execBeacon = new UpgradeableBeacon(address(execImpl), address(this));
        exec = Executor(payable(address(new BeaconProxy(address(execBeacon), ""))));
        exec.initialize(address(this), address(legacyHats));
        exec.setCaller(address(this));

        // Real QuickJoin, minting through the real Executor.
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = LEGACY_HAT;
        QuickJoin qjImpl = new QuickJoin();
        UpgradeableBeacon qjBeacon = new UpgradeableBeacon(address(qjImpl), address(this));
        qj = QuickJoin(address(new BeaconProxy(address(qjBeacon), "")));
        qj.initialize(address(exec), address(legacyHats), address(registry), master, memberHats);

        exec.setHatMinterAuthorization(address(qj), true);
        registry.setUsername(user, "alice");
    }

    /*───────────────────── Legacy path (regression) ─────────────────────*/
    function testLegacyJoinMintsMemberHats() public {
        assertEq(qj.membershipAuthority(), address(0));
        vm.prank(user);
        qj.quickJoinWithUser();
        assertTrue(legacyHats.isWearerOfHat(user, LEGACY_HAT), "legacy member hat minted");
    }

    function testLegacyJoinEmitsLegacyList() public {
        uint256[] memory expected = new uint256[](1);
        expected[0] = LEGACY_HAT;
        vm.expectEmit(true, false, false, true, address(qj));
        emit QuickJoined(user, expected);
        vm.prank(user);
        qj.quickJoinWithUser();
    }

    /*───────────────────── setMembershipAuthority auth ─────────────────────*/
    function testSetMembershipAuthorityOnlyExecutor() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.setMembershipAuthority(address(0xdead));
    }

    function testSetMembershipAuthorityEmits() public {
        vm.expectEmit(true, false, false, false, address(qj));
        emit MembershipAuthoritySet(address(0xdead));
        vm.prank(address(exec));
        qj.setMembershipAuthority(address(0xdead));
        assertEq(qj.membershipAuthority(), address(0xdead));
    }

    /*───────────────────── Authority path ─────────────────────*/
    function testAuthorityJoinMintsAutojoinSubjects() public {
        uint256 baseRole = _migrateToAuthority();

        vm.prank(user);
        qj.quickJoinWithUser();

        assertTrue(auth.isMember(baseRole, user), "authority membership minted via QJ_AUTOJOIN subject");
    }

    function testAuthorityJoinEmitsAuthoritySubjectList() public {
        uint256 baseRole = _migrateToAuthority();
        uint256[] memory expected = new uint256[](1);
        expected[0] = baseRole;
        vm.expectEmit(true, false, false, true, address(qj));
        emit QuickJoined(user, expected);
        vm.prank(user);
        qj.quickJoinWithUser();
    }

    /*───────────────────── Rollback ─────────────────────*/
    function testRollbackRestoresLegacyList() public {
        _migrateToAuthority();

        // Roll QuickJoin back to legacy list (executor also rolls its hats pointer back).
        vm.prank(address(exec));
        qj.setMembershipAuthority(address(0));
        exec.setMembershipAuthority(address(0));

        vm.prank(user);
        qj.quickJoinWithUser();
        assertTrue(legacyHats.isWearerOfHat(user, LEGACY_HAT), "legacy member hat minted after rollback");
    }

    /*───────────────────── Equality differential (§5.2 / §4.6) ─────────────────────*/
    /// @notice The legacy hats list and the authority QJ_AUTOJOIN subject list produce the SAME mints:
    ///         each world configures exactly ONE auto-join membership, and the joining user ends up
    ///         holding exactly that one membership.
    function testJoinEqualityDifferential() public {
        // ── Legacy arm (fresh user, no authority) ──
        address legacyUser = address(0x1111);
        registry.setUsername(legacyUser, "legacy");
        uint256[] memory legacyList = qj.memberHatIds();
        assertEq(legacyList.length, 1, "one legacy auto-join hat");
        vm.prank(legacyUser);
        qj.quickJoinWithUser();
        bool legacyMember = legacyHats.isWearerOfHat(legacyUser, legacyList[0]);

        // ── Authority arm (fresh user, migrated) ──
        uint256 baseRole = _migrateToAuthority();
        uint256[] memory authList = auth.subjectsWithKey(AccessV2PermKeys.QJ_AUTOJOIN, bytes32(0));
        address authUser = address(0x2222);
        registry.setUsername(authUser, "auth");
        vm.prank(authUser);
        qj.quickJoinWithUser();
        bool authMember = auth.isMember(baseRole, authUser);

        // Same cardinality of auto-join memberships, same "user joined the configured base role".
        assertEq(authList.length, legacyList.length, "same auto-join set cardinality");
        assertEq(authList[0], baseRole, "authority list is the QJ_AUTOJOIN base role");
        assertTrue(legacyMember, "legacy arm: user joined the sole configured membership");
        assertTrue(authMember, "authority arm: user joined the sole configured membership");
    }

    /*───────────────────── Migration helper ─────────────────────*/
    /// @dev Stand up the real authority (executor == the Executor), seed ONE default-ALLOW base role
    ///      carrying the QJ_AUTOJOIN perm, repoint the Executor's hats to the authority, and point
    ///      QuickJoin at it. Config runs through Executor.configureModule (owner relay) so the
    ///      authority's executor gate (== the Executor) is satisfied exactly as a governance batch.
    function _migrateToAuthority() internal returns (uint256 baseRole) {
        MembershipAuthority implA = new MembershipAuthority();
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: address(exec), paymasterHub: paymasterHub, orgId: ORG_ID, seed: _emptySeed()
        });
        auth = MembershipAuthority(
            address(new ERC1967Proxy(address(implA), abi.encodeCall(MembershipAuthority.initialize, (cfg))))
        );

        exec.configureModule(address(auth), abi.encodeCall(MembershipAuthority.setPaused, (false)));
        bytes memory ret = exec.configureModule(
            address(auth), abi.encodeCall(MembershipAuthority.createRole, ("Base", bytes32(0), "", uint32(0)))
        );
        baseRole = abi.decode(ret, (uint256));
        exec.configureModule(
            address(auth), abi.encodeCall(MembershipAuthority.setSubjectDefault, (baseRole, true, false))
        );
        exec.configureModule(
            address(auth),
            abi.encodeCall(
                MembershipAuthority.setPerm,
                (baseRole, AccessV2PermKeys.QJ_AUTOJOIN, bytes32(0), uint256(1) | (uint256(1) << 255))
            )
        );

        // §4.7 repoint + QuickJoin switch.
        exec.setMembershipAuthority(address(auth));
        vm.prank(address(exec));
        qj.setMembershipAuthority(address(auth));
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
}
