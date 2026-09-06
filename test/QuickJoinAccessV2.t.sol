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
/// @notice Authority QJ_AUTOJOIN subjects mint through the real Executor; zero rollback is rejected.
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
        exec.initialize(address(this));
        exec.setCaller(address(this));

        // Real QuickJoin, minting through the real Executor.
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = LEGACY_HAT;
        QuickJoin qjImpl = new QuickJoin();
        UpgradeableBeacon qjBeacon = new UpgradeableBeacon(address(qjImpl), address(this));
        qj = QuickJoin(address(new BeaconProxy(address(qjBeacon), "")));
        qj.initialize(address(exec), address(registry), master);

        exec.setHatMinterAuthorization(address(qj), true);
        registry.setUsername(user, "alice");
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

        vm.prank(address(exec));
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        qj.setMembershipAuthority(address(0));
        assertEq(qj.membershipAuthority(), address(0xdead), "failed rollback preserves authority");
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
