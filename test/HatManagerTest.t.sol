// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/libs/HatManager.sol";
import "../src/DirectDemocracyVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract MockExecutor is IExecutor {
    Call[] public last;

    function execute(uint256, Call[] calldata batch) external {
        delete last;
        for (uint256 i; i < batch.length; ++i) {
            last.push(batch[i]);
            (bool success,) = batch[i].target.call{value: batch[i].value}(batch[i].data);
            require(success, "MockExecutor: call failed");
        }
    }
}

contract HatManagerTest is Test {
    DirectDemocracyVoting dd;
    MockHats hats;
    MockExecutor exec;
    address creator = address(0x1);
    address voter = address(0x2);
    address admin = address(0x3);

    uint256 constant VOTING_HAT_1 = 1;
    uint256 constant VOTING_HAT_2 = 2;
    uint256 constant CREATOR_HAT_1 = 10;
    uint256 constant CREATOR_HAT_2 = 20;

    function setUp() public {
        hats = new MockHats();
        exec = new MockExecutor();

        // Mint hats to users
        hats.mintHat(VOTING_HAT_1, creator);
        hats.mintHat(VOTING_HAT_1, voter);
        hats.mintHat(CREATOR_HAT_1, creator);

        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory initialHats = new uint256[](1);
        initialHats[0] = VOTING_HAT_1;
        uint256[] memory initialCreatorHats = new uint256[](1);
        initialCreatorHats[0] = CREATOR_HAT_1;

        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize,
            (address(hats), address(exec), initialHats, initialCreatorHats, new address[](0), 50, 0)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        dd = DirectDemocracyVoting(address(proxy));
    }

    function testInitialHatConfiguration() public {
        // Test initial hat setup
        uint256[] memory votingHats = dd.votingHats();
        uint256[] memory creatorHats = dd.creatorHats();

        assertEq(votingHats.length, 1);
        assertEq(votingHats[0], VOTING_HAT_1);
        assertEq(creatorHats.length, 1);
        assertEq(creatorHats[0], CREATOR_HAT_1);

        assertEq(dd.votingHatCount(), 1);
        assertEq(dd.creatorHatCount(), 1);
    }

    function testAddVotingHat() public {
        // Add a second voting hat
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_2, true)
        );

        uint256[] memory votingHats = dd.votingHats();
        assertEq(votingHats.length, 2);
        assertEq(dd.votingHatCount(), 2);

        // Verify both hats are present
        bool foundHat1 = false;
        bool foundHat2 = false;
        for (uint256 i = 0; i < votingHats.length; i++) {
            if (votingHats[i] == VOTING_HAT_1) foundHat1 = true;
            if (votingHats[i] == VOTING_HAT_2) foundHat2 = true;
        }
        assertTrue(foundHat1);
        assertTrue(foundHat2);
    }

    function testRemoveVotingHat() public {
        // Add a second hat first
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_2, true)
        );
        assertEq(dd.votingHatCount(), 2);

        // Remove the first hat
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_1, false)
        );

        uint256[] memory votingHats = dd.votingHats();
        assertEq(votingHats.length, 1);
        assertEq(votingHats[0], VOTING_HAT_2);
        assertEq(dd.votingHatCount(), 1);
    }

    function testAddCreatorHat() public {
        // Add a second creator hat
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.CREATOR, CREATOR_HAT_2, true)
        );

        uint256[] memory creatorHats = dd.creatorHats();
        assertEq(creatorHats.length, 2);
        assertEq(dd.creatorHatCount(), 2);
    }

    function testVotingPermissions() public {
        // Creator should be able to create proposals
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = new IExecutor.Call[](0);

        vm.prank(creator);
        dd.createProposal(bytes("test"), bytes32(0), 10, 1, batches, new uint256[](0));
        assertEq(dd.proposalsCount(), 1);

        // Voter should be able to vote
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;

        vm.prank(voter);
        dd.vote(0, idx, weights);
    }

    function testPermissionDeniedAfterHatRemoval() public {
        // Remove voting hat from creator
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_1, false)
        );

        // Creator should still be able to create (has creator hat)
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = new IExecutor.Call[](0);

        vm.prank(creator);
        dd.createProposal(bytes("test"), bytes32(0), 10, 1, batches, new uint256[](0));

        // But voter should not be able to vote (no voting hat)
        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;

        vm.prank(voter);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.vote(0, idx, weights);
    }

    function testMultipleHatPermissions() public {
        // Add second voting hat and give it to admin
        hats.mintHat(VOTING_HAT_2, admin);
        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_2, true)
        );

        // Admin should now be able to vote with the new hat
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = new IExecutor.Call[](0);
        vm.prank(creator);
        dd.createProposal(bytes("test"), bytes32(0), 10, 1, batches, new uint256[](0));

        uint8[] memory idx = new uint8[](1);
        idx[0] = 0;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;

        vm.prank(admin);
        dd.vote(0, idx, weights);
    }

    function testHatManagerEvents() public {
        // Test that events are emitted correctly when managing hats
        vm.expectEmit(true, true, false, false);
        emit HatManager.HatToggled(VOTING_HAT_2, true);

        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.VOTING, VOTING_HAT_2, true)
        );

        // Test creator hat event
        vm.expectEmit(true, true, false, false);
        emit HatManager.HatToggled(CREATOR_HAT_2, true);

        vm.prank(address(exec));
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED,
            abi.encode(DirectDemocracyVoting.HatType.CREATOR, CREATOR_HAT_2, true)
        );
    }

    function testUnauthorizedHatManagement() public {
        // Non-executor should not be able to manage hats
        vm.prank(voter);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED, abi.encode(DirectDemocracyVoting.HatType.VOTING, 999, true)
        );

        vm.prank(creator);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        dd.setConfig(
            DirectDemocracyVoting.ConfigKey.HAT_ALLOWED, abi.encode(DirectDemocracyVoting.HatType.CREATOR, 999, true)
        );
    }

    function testHatArraysEmptyInitially() public {
        // Deploy new contract with no initial hats
        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        bytes memory data = abi.encodeCall(
            DirectDemocracyVoting.initialize,
            (address(hats), address(exec), new uint256[](0), new uint256[](0), new address[](0), 50, 0)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        DirectDemocracyVoting newDD = DirectDemocracyVoting(address(proxy));

        assertEq(newDD.votingHatCount(), 0);
        assertEq(newDD.creatorHatCount(), 0);

        uint256[] memory votingHats = newDD.votingHats();
        uint256[] memory creatorHats = newDD.creatorHats();

        assertEq(votingHats.length, 0);
        assertEq(creatorHats.length, 0);
    }
}
