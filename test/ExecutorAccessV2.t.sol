// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {Executor, IExecutor} from "../src/Executor.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/// @title ExecutorAccessV2Test
/// @notice Coverage for the §4.7 `l.hats` repoint: setMembershipAuthority switches the stored hats
///         pointer to the authority, stashes the ORIGINAL on the first repoint, and restores it on
///         rollback-to-zero. Auth mirrors setHatMinterAuthorization (owner / allowedCaller / self via
///         the execute() self-target allowlist).
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
        exec.initialize(owner, address(legacyHats));
        // First-time governor set (owner path).
        exec.setCaller(governance);
    }

    /*───────────────────── Default / legacy ─────────────────────*/
    function testDefaultHatsIsLegacy() public {
        assertEq(address(exec.hats()), address(legacyHats));
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

    function testSecondRepointKeepsOriginalLegacy() public {
        exec.setMembershipAuthority(authorityA);
        exec.setMembershipAuthority(authorityB);
        assertEq(address(exec.hats()), authorityB);
        assertEq(exec.membershipAuthority(), authorityB);

        // Rollback must restore the ORIGINAL legacy hats, not authorityA.
        exec.setMembershipAuthority(address(0));
        assertEq(address(exec.hats()), address(legacyHats), "original legacy restored");
        assertEq(exec.membershipAuthority(), address(0));
    }

    /*───────────────────── Rollback ─────────────────────*/
    function testRollbackRestoresLegacy() public {
        exec.setMembershipAuthority(authorityA);
        vm.expectEmit(true, false, false, false, address(exec));
        emit HatsRepointed(address(legacyHats));
        exec.setMembershipAuthority(address(0));
        assertEq(address(exec.hats()), address(legacyHats));
        assertEq(exec.membershipAuthority(), address(0));
    }

    function testRollbackWhenNeverRepointedIsNoop() public {
        exec.setMembershipAuthority(address(0));
        assertEq(address(exec.hats()), address(legacyHats));
        assertEq(exec.membershipAuthority(), address(0));
    }

    /*───────────────────── Auth matrix ─────────────────────*/
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
