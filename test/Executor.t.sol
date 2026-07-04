// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/Executor.sol";
import "./mocks/MockHats.sol";

contract Target {
    uint256 public val;

    function setVal(uint256 v) external payable {
        val = v;
    }
}

/// @dev Recipient whose receive() writes storage — costs far more than the 2300-gas
///      stipend that `.transfer` forwards. L-11: sweeps to such recipients would have
///      reverted under `.transfer`; they succeed under `call{value:}`.
contract GreedyReceiver {
    uint256 public received;
    uint256 public pings;

    receive() external payable {
        // Multiple SSTOREs blow past the 2300-gas stipend.
        received += msg.value;
        pings += 1;
    }
}

/// @dev Recipient that rejects ETH — used to prove sweep reverts SweepFailed.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev Minimal ParticipationToken stand-in that records the wiring calls
///      Executor.configureParticipationToken makes, and lets the test assert which
///      setters fired. Mirrors ParticipationToken's executor-only setters by simply
///      recording the values (the Executor is the caller, so no gate needed here).
contract MockConfigToken {
    address public taskManager;
    address public educationHub;
    uint256 public taskManagerSetCount;
    uint256 public educationHubSetCount;

    function setTaskManager(address tm) external {
        taskManager = tm;
        taskManagerSetCount += 1;
    }

    function setEducationHub(address eh) external {
        educationHub = eh;
        educationHubSetCount += 1;
    }
}

contract ExecutorTest is Test {
    Executor exec;
    MockHats hats;
    address owner = address(this);
    address caller = address(0x1);
    Target target;

    function setUp() public {
        hats = new MockHats();
        Executor impl = new Executor();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        exec = Executor(payable(address(new BeaconProxy(address(beacon), ""))));
        exec.initialize(owner, address(hats));
        target = new Target();
        exec.setCaller(caller);
    }

    function testExecuteBatch() public {
        IExecutor.Call[] memory batch = new IExecutor.Call[](1);
        batch[0] =
            IExecutor.Call({target: address(target), value: 0, data: abi.encodeWithSignature("setVal(uint256)", 42)});
        vm.prank(caller);
        exec.execute(1, batch);
        assertEq(target.val(), 42);
    }

    function testUnauthorizedReverts() public {
        IExecutor.Call[] memory batch = new IExecutor.Call[](0);
        vm.expectRevert(Executor.EmptyBatch.selector);
        vm.prank(caller);
        exec.execute(1, batch);
    }

    function testHatMintingAuthorization() public {
        address minter = address(0x2);
        address user = address(0x3);
        uint256 hatId = 1;

        // Test unauthorized minting fails
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = hatId;
        vm.prank(minter);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.mintHatsForUser(user, hatIds);

        // Authorize minter
        exec.setHatMinterAuthorization(minter, true);

        // Test authorized minting succeeds
        vm.prank(minter);
        exec.mintHatsForUser(user, hatIds);
        assertTrue(hats.isWearerOfHat(user, hatId));

        // Test deauthorization
        exec.setHatMinterAuthorization(minter, false);
        vm.prank(minter);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.mintHatsForUser(user, hatIds);
    }

    function testSetCallerUnauthorizedReverts() public {
        address random = address(0x99);
        vm.prank(random);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.setCaller(address(0x5));
    }

    function testSetCallerZeroAddressReverts() public {
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.setCaller(address(0));
    }

    function testAllowedCallerCanSetNewCaller() public {
        address newCaller = address(0x5);
        vm.prank(caller);
        exec.proposeCaller(newCaller);

        vm.warp(block.timestamp + 2 days);

        vm.prank(caller);
        exec.acceptCaller();
        assertEq(exec.allowedCaller(), newCaller);
    }

    function testProposeCallerUnauthorizedReverts() public {
        address random = address(0x99);
        vm.prank(random);
        vm.expectRevert(Executor.UnauthorizedCaller.selector);
        exec.proposeCaller(address(0x5));
    }

    function testAcceptCallerBeforeTimelockReverts() public {
        vm.prank(caller);
        exec.proposeCaller(address(0x5));

        // Try to accept immediately (before 2-day delay)
        vm.prank(caller);
        vm.expectRevert(Executor.TimelockNotExpired.selector);
        exec.acceptCaller();
    }

    function testCancelCallerChange() public {
        address newCaller = address(0x5);
        vm.prank(caller);
        exec.proposeCaller(newCaller);

        // Cancel the change
        vm.prank(caller);
        exec.cancelCallerChange();

        // Warp past delay and try to accept — should fail (pending cleared)
        vm.warp(block.timestamp + 2 days);
        vm.prank(caller);
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.acceptCaller();

        // Caller should be unchanged
        assertEq(exec.allowedCaller(), caller);
    }

    function testProposeCallerZeroAddressReverts() public {
        vm.prank(caller);
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.proposeCaller(address(0));
    }

    /*══════════════════════════════════════════════════════
     * C-01: configureParticipationToken (owner-gated bootstrap wiring)
     *══════════════════════════════════════════════════════*/

    // Owner wires both taskManager + educationHub through the Executor.
    function testConfigureParticipationTokenWiresBoth() public {
        MockConfigToken token = new MockConfigToken();
        address tm = address(0x111);
        address eh = address(0x222);

        exec.configureParticipationToken(address(token), tm, eh);

        assertEq(token.taskManager(), tm, "taskManager should be wired");
        assertEq(token.educationHub(), eh, "educationHub should be wired");
        assertEq(token.taskManagerSetCount(), 1);
        assertEq(token.educationHubSetCount(), 1);
    }

    // educationHub == 0 → setEducationHub is skipped (hub stays as-is / never touched).
    function testConfigureParticipationTokenSkipsEducationHubWhenZero() public {
        MockConfigToken token = new MockConfigToken();
        address tm = address(0x111);

        exec.configureParticipationToken(address(token), tm, address(0));

        assertEq(token.taskManager(), tm, "taskManager should be wired");
        assertEq(token.taskManagerSetCount(), 1);
        assertEq(token.educationHubSetCount(), 0, "setEducationHub must be skipped when hub == 0");
    }

    // Non-owner cannot call configureParticipationToken.
    function testConfigureParticipationTokenRevertsForNonOwner() public {
        MockConfigToken token = new MockConfigToken();
        vm.prank(address(0x99));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x99)));
        exec.configureParticipationToken(address(token), address(0x111), address(0x222));
    }

    // token == address(0) reverts ZeroAddress.
    function testConfigureParticipationTokenRevertsForZeroToken() public {
        vm.expectRevert(Executor.ZeroAddress.selector);
        exec.configureParticipationToken(address(0), address(0x111), address(0x222));
    }

    /*══════════════════════════════════════════════════════
     * L-11: sweep uses call{value:} instead of .transfer
     *══════════════════════════════════════════════════════*/

    // Sweep succeeds to a contract recipient whose receive() burns >2300 gas
    // (would have reverted under the old `.transfer`).
    function testSweepToGreedyReceiverSucceeds() public {
        GreedyReceiver greedy = new GreedyReceiver();
        vm.deal(address(exec), 3 ether);

        exec.sweep(payable(address(greedy)));

        assertEq(address(exec).balance, 0, "executor balance should be swept to zero");
        assertEq(address(greedy).balance, 3 ether, "greedy receiver should hold the swept ETH");
        assertEq(greedy.received(), 3 ether, "receive() storage write should have run");
        assertEq(greedy.pings(), 1);
    }

    // Sweep reverts SweepFailed when the recipient rejects ETH.
    function testSweepRevertsSweepFailedWhenRecipientReverts() public {
        RejectingReceiver bad = new RejectingReceiver();
        vm.deal(address(exec), 1 ether);

        vm.expectRevert(Executor.SweepFailed.selector);
        exec.sweep(payable(address(bad)));

        assertEq(address(exec).balance, 1 ether, "balance should be unchanged after failed sweep");
    }

    /*══════════════════════════════════════════════════════
     * L-60: mintHatsForUser caps the hat array at MAX_HATS_PER_MINT
     *══════════════════════════════════════════════════════*/

    // 21 hat ids reverts TooManyHats (MAX_HATS_PER_MINT == 20).
    function testMintHatsForUserRevertsWhenTooManyHats() public {
        address minter = address(0x2);
        address user = address(0x3);
        exec.setHatMinterAuthorization(minter, true);

        uint256[] memory hatIds = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            hatIds[i] = i + 1;
        }

        vm.prank(minter);
        vm.expectRevert(Executor.TooManyHats.selector);
        exec.mintHatsForUser(user, hatIds);
    }

    // 20 hat ids (exactly MAX_HATS_PER_MINT) succeeds.
    function testMintHatsForUserAtMaxSucceeds() public {
        address minter = address(0x2);
        address user = address(0x3);
        exec.setHatMinterAuthorization(minter, true);

        uint256[] memory hatIds = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            hatIds[i] = i + 1;
        }

        vm.prank(minter);
        exec.mintHatsForUser(user, hatIds);

        for (uint256 i = 0; i < 20; i++) {
            assertTrue(hats.isWearerOfHat(user, i + 1), "each hat within the cap should be minted");
        }
    }
}
