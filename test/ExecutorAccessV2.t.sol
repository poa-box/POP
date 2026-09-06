// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {Executor, IExecutor} from "../src/Executor.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {MockModuleAuthority} from "./mocks/MockModuleAuthority.sol";
import {MockHats} from "./mocks/MockHats.sol";

/// @title ExecutorAccessV2Test
/// @notice Authority repoints require matching executor ownership, and zero cannot restore Hats.
contract ExecutorAccessV2Test is Test {
    Executor exec;
    MockHats legacyHats;

    address owner = address(this);
    address governance = address(0x6041);
    address authorityA = address(0xA401);
    address authorityB = address(0xB402);
    address stranger = address(0xBAD);

    event HatsRepointed(address indexed hats);

    function setUp() public {
        legacyHats = new MockHats();
        Executor impl = new Executor();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        exec = Executor(payable(address(new BeaconProxy(address(beacon), ""))));
        exec.initialize(owner);
        authorityA = address(new MockModuleAuthority(address(legacyHats), address(exec)));
        authorityB = address(new MockModuleAuthority(address(legacyHats), address(exec)));
        // First-time governor set (owner path).
        exec.setCaller(governance);
    }

    /*───────────────────── Default / legacy ─────────────────────*/
    function testFreshExecutorHasNoAuthority() public {
        assertEq(address(exec.hats()), address(0));
        assertEq(exec.membershipAuthority(), address(0));
    }

    /*───────────────────── Repoint ─────────────────────*/
    function testRepointSwitchesHatsPointer() public {
        vm.expectEmit(true, false, false, false, address(exec));
        emit HatsRepointed(authorityA);
        exec.setMembershipAuthority(authorityA);

        assertEq(address(exec.hats()), authorityA, "hats() now resolves to the authority");
        assertEq(exec.membershipAuthority(), authorityA);
    }

    function testSecondRepointCannotRestoreLegacy() public {
        exec.setMembershipAuthority(authorityA);
        exec.setMembershipAuthority(authorityB);
        assertEq(address(exec.hats()), authorityB);
        assertEq(exec.membershipAuthority(), authorityB);

        // Zero cannot restore Hats or clear the current authority.
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.setMembershipAuthority(address(0));
        assertEq(exec.membershipAuthority(), authorityB);
    }

    /*───────────────────── Auth matrix ─────────────────────*/
    function testCannotRepointToAnotherOrgsAuthority() public {
        exec.setMembershipAuthority(authorityA);
        address foreignAuthority = address(new MockModuleAuthority(address(legacyHats), stranger));
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.setMembershipAuthority(foreignAuthority);
        assertEq(exec.membershipAuthority(), authorityA);
    }

    function testUnmigratedLegacyHatsCannotMint() public {
        // Model an upgraded V1 proxy: its first namespaced slot still holds real Hats.
        vm.store(address(exec), keccak256("poa.executor.storage"), bytes32(uint256(uint160(address(legacyHats)))));
        assertEq(exec.membershipAuthority(), address(0));
        exec.setHatMinterAuthorization(stranger, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(stranger);
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.mintHatsForUser(stranger, ids);
        assertFalse(legacyHats.isWearerOfHat(stranger, 1));
    }

    function testOwnerCanRepoint() public {
        exec.setMembershipAuthority(authorityA); // owner == address(this)
        assertEq(address(exec.hats()), authorityA);
    }

    function testAllowedCallerCanRepoint() public {
        vm.prank(governance);
        exec.setMembershipAuthority(authorityA);
        assertEq(address(exec.hats()), authorityA);
    }

    function testStrangerCannotRepoint() public {
        vm.prank(stranger);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.setMembershipAuthority(authorityA);
    }

    /*───────────────────── Self-target via execute() (renounced-org path) ─────────────────────*/
    function testGovernanceSelfTargetRepoint() public {
        // Simulate a renounced org: governance batches a self-call to repoint hats.
        IExecutor.Call[] memory batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: address(exec), value: 0, data: abi.encodeCall(Executor.setMembershipAuthority, (authorityA))
        });
        vm.prank(governance);
        exec.execute(1, batch);
        assertEq(address(exec.hats()), authorityA, "self-targeted repoint applied");
    }

    function testNonAllowlistedSelfTargetStillReverts() public {
        // pause() is NOT in the self-target allowlist → TargetSelf even for governance.
        IExecutor.Call[] memory batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({target: address(exec), value: 0, data: abi.encodeCall(Executor.pause, ())});
        vm.prank(governance);
        vm.expectRevert(Executor.TargetSelf.selector);
        exec.execute(1, batch);
    }
}
