// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TaskManager} from "../src/TaskManager.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {EducationHub, IParticipationToken as IEduPT} from "../src/EducationHub.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {MockHats} from "./mocks/MockHats.sol";

/*//////////////////////////////////////////////////////////////
Minimal ParticipationToken stub for the EducationHub wiring check.
//////////////////////////////////////////////////////////////*/
contract MockEduPT is IEduPT {
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

    /*//////////////////////////////////////////////////////////////
    W4 — configAdmin auth-widening tests across the four modules.
    Each module gets: executor-only setConfigAdmin; the widened setter is
    reachable by executor AND configAdmin (after set) but never by a rando;
    before configAdmin is set the rando (would-be admin) is rejected.
    //////////////////////////////////////////////////////////////*/
    contract ConfigAdminModulesTest is Test {
        MockHats hats;

        address executor = address(0xE1);
        address configAdmin = address(0xCA11);
        address rando = address(0xBAD);

        uint256 constant HAT_A = 10;
        uint256 constant HAT_B = 11;

        function setUp() public {
            hats = new MockHats();
        }

        /*──────────── TaskManager ───────────*/

        function _deployTM() internal returns (TaskManager tm) {
            TaskManager impl = new TaskManager();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
            tm = TaskManager(address(new BeaconProxy(address(beacon), "")));
            uint256[] memory creatorHats = new uint256[](0);
            // token address only needs to be non-zero for the paths under test.
            tm.initialize(address(0xDEAD), address(hats), creatorHats, executor, address(0));
        }

        function _rolePermValue(uint256 hatId, uint8 mask) internal pure returns (bytes memory) {
            return abi.encode(hatId, mask);
        }

        function _tmHasPermHat(TaskManager tm, uint256 hatId) internal view returns (bool) {
            uint256[] memory ids = abi.decode(tm.getLensData(6, ""), (uint256[]));
            for (uint256 i; i < ids.length; ++i) {
                if (ids[i] == hatId) return true;
            }
            return false;
        }

        function testTMSetConfigAdminOnlyExecutor() public {
            TaskManager tm = _deployTM();

            vm.prank(rando);
            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfigAdmin(configAdmin);

            vm.prank(executor);
            tm.setConfigAdmin(configAdmin);
        }

        function testTMRolePermRejectsConfigAdminBeforeSet() public {
            TaskManager tm = _deployTM();
            vm.prank(configAdmin);
            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, _rolePermValue(HAT_A, 1));
        }

        function testTMRolePermAcceptsExecutorAndConfigAdmin() public {
            TaskManager tm = _deployTM();

            // executor path
            vm.prank(executor);
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, _rolePermValue(HAT_A, 1));
            assertTrue(_tmHasPermHat(tm, HAT_A));

            // grant configAdmin
            vm.prank(executor);
            tm.setConfigAdmin(configAdmin);

            // configAdmin path
            vm.prank(configAdmin);
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, _rolePermValue(HAT_B, 1));
            assertTrue(_tmHasPermHat(tm, HAT_B));

            // rando still rejected
            vm.prank(rando);
            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, _rolePermValue(HAT_A, 2));
        }

        /// @dev The widening is scoped to ROLE_PERM only — every other branch stays executor-strict.
        function testTMOtherBranchesRejectConfigAdmin() public {
            TaskManager tm = _deployTM();
            vm.prank(executor);
            tm.setConfigAdmin(configAdmin);

            vm.startPrank(configAdmin);

            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.CREATOR_HAT_ALLOWED, abi.encode(HAT_A, true));

            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(HAT_A, true));

            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.EXECUTOR, abi.encode(address(0x1234)));

            vm.stopPrank();
        }

        function testTMConfigAdminClearRevokes() public {
            TaskManager tm = _deployTM();
            vm.prank(executor);
            tm.setConfigAdmin(configAdmin);
            vm.prank(executor);
            tm.setConfigAdmin(address(0));

            vm.prank(configAdmin);
            vm.expectRevert(TaskManager.NotExecutor.selector);
            tm.setConfig(TaskManager.ConfigKey.ROLE_PERM, _rolePermValue(HAT_A, 1));
        }

        /*──────────── ParticipationToken ───────────*/

        function _deployPT() internal returns (ParticipationToken pt) {
            ParticipationToken impl = new ParticipationToken();
            uint256[] memory empty = new uint256[](0);
            bytes memory data =
                abi.encodeCall(ParticipationToken.initialize, (executor, "PToken", "PTK", address(hats), empty, empty));
            pt = ParticipationToken(address(new ERC1967Proxy(address(impl), data)));
        }

        function testPTSetConfigAdminOnlyExecutor() public {
            ParticipationToken pt = _deployPT();

            vm.prank(rando);
            vm.expectRevert(ParticipationToken.Unauthorized.selector);
            pt.setConfigAdmin(configAdmin);

            vm.prank(executor);
            pt.setConfigAdmin(configAdmin);
        }

        function testPTMemberApproverRejectBeforeSet() public {
            ParticipationToken pt = _deployPT();

            vm.startPrank(configAdmin);
            vm.expectRevert(ParticipationToken.Unauthorized.selector);
            pt.setMemberHatAllowed(HAT_A, true);
            vm.expectRevert(ParticipationToken.Unauthorized.selector);
            pt.setApproverHatAllowed(HAT_A, true);
            vm.stopPrank();
        }

        function testPTMemberApproverAcceptExecutorAndConfigAdmin() public {
            ParticipationToken pt = _deployPT();

            vm.startPrank(executor);
            pt.setMemberHatAllowed(HAT_A, true);
            pt.setApproverHatAllowed(HAT_A, true);
            pt.setConfigAdmin(configAdmin);
            vm.stopPrank();
            assertEq(pt.memberHatIds()[0], HAT_A);
            assertEq(pt.approverHatIds()[0], HAT_A);

            vm.startPrank(configAdmin);
            pt.setMemberHatAllowed(HAT_B, true);
            pt.setApproverHatAllowed(HAT_B, true);
            vm.stopPrank();
            assertEq(pt.memberHatIds()[1], HAT_B);
            assertEq(pt.approverHatIds()[1], HAT_B);

            vm.prank(rando);
            vm.expectRevert(ParticipationToken.Unauthorized.selector);
            pt.setMemberHatAllowed(HAT_A, false);
        }

        /*──────────── EducationHub ───────────*/

        function _deployEdu() internal returns (EducationHub hub) {
            MockEduPT token = new MockEduPT();
            EducationHub impl = new EducationHub();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
            hub = EducationHub(address(new BeaconProxy(address(beacon), "")));
            uint256[] memory empty = new uint256[](0);
            hub.initialize(address(token), address(hats), executor, empty, empty);
        }

        function testEduSetConfigAdminOnlyExecutor() public {
            EducationHub hub = _deployEdu();

            vm.prank(rando);
            vm.expectRevert(EducationHub.NotExecutor.selector);
            hub.setConfigAdmin(configAdmin);

            vm.prank(executor);
            hub.setConfigAdmin(configAdmin);
        }

        function testEduCreatorMemberRejectBeforeSet() public {
            EducationHub hub = _deployEdu();

            vm.startPrank(configAdmin);
            vm.expectRevert(EducationHub.NotExecutor.selector);
            hub.setCreatorHatAllowed(HAT_A, true);
            vm.expectRevert(EducationHub.NotExecutor.selector);
            hub.setMemberHatAllowed(HAT_A, true);
            vm.stopPrank();
        }

        function testEduCreatorMemberAcceptExecutorAndConfigAdmin() public {
            EducationHub hub = _deployEdu();

            vm.startPrank(executor);
            hub.setCreatorHatAllowed(HAT_A, true);
            hub.setMemberHatAllowed(HAT_A, true);
            hub.setConfigAdmin(configAdmin);
            vm.stopPrank();
            assertEq(hub.creatorHatIds()[0], HAT_A);
            assertEq(hub.memberHatIds()[0], HAT_A);

            vm.startPrank(configAdmin);
            hub.setCreatorHatAllowed(HAT_B, true);
            hub.setMemberHatAllowed(HAT_B, true);
            vm.stopPrank();
            assertEq(hub.creatorHatIds()[1], HAT_B);
            assertEq(hub.memberHatIds()[1], HAT_B);

            vm.prank(rando);
            vm.expectRevert(EducationHub.NotExecutor.selector);
            hub.setCreatorHatAllowed(HAT_A, false);
        }

        /*──────────── QuickJoin ───────────*/

        function _deployQJ() internal returns (QuickJoin qj) {
            QuickJoin impl = new QuickJoin();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
            qj = QuickJoin(address(new BeaconProxy(address(beacon), "")));
            uint256[] memory empty = new uint256[](0);
            qj.initialize(executor, address(hats), address(0xBEEF), address(0xF00D), empty);
        }

        function testQJSetConfigAdminOnlyExecutor() public {
            QuickJoin qj = _deployQJ();

            vm.prank(rando);
            vm.expectRevert(QuickJoin.Unauthorized.selector);
            qj.setConfigAdmin(configAdmin);

            vm.prank(executor);
            qj.setConfigAdmin(configAdmin);
        }

        function testQJUpdateMemberHatsRejectBeforeSet() public {
            QuickJoin qj = _deployQJ();
            uint256[] memory ids = new uint256[](1);
            ids[0] = HAT_A;

            vm.prank(configAdmin);
            vm.expectRevert(QuickJoin.Unauthorized.selector);
            qj.updateMemberHatIds(ids);
        }

        function testQJUpdateMemberHatsAcceptExecutorAndConfigAdmin() public {
            QuickJoin qj = _deployQJ();

            uint256[] memory idsA = new uint256[](1);
            idsA[0] = HAT_A;
            vm.prank(executor);
            qj.updateMemberHatIds(idsA);
            assertEq(qj.memberHatIds()[0], HAT_A);

            vm.prank(executor);
            qj.setConfigAdmin(configAdmin);

            uint256[] memory idsB = new uint256[](1);
            idsB[0] = HAT_B;
            vm.prank(configAdmin);
            qj.updateMemberHatIds(idsB);
            assertEq(qj.memberHatIds()[0], HAT_B);

            vm.prank(rando);
            vm.expectRevert(QuickJoin.Unauthorized.selector);
            qj.updateMemberHatIds(idsA);
        }
    }
