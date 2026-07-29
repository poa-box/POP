// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {HybridVoting} from "../src/HybridVoting.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IExecutor} from "../src/Executor.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract MockERC20RE is IERC20 {
    string public name = "PT";
    string public symbol = "PT";
    uint8 public decimals = 18;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

    contract MockExecutorRE is IExecutor {
        Call[] public lastBatch;
        uint256 public lastId;

        function execute(uint256 id, Call[] calldata batch) external {
            lastId = id;
            delete lastBatch;
            for (uint256 i; i < batch.length; ++i) {
                lastBatch.push(batch[i]);
            }
        }
    }

    /// CEI ordering property tests for HybridVoting.vote(). The cited balanceOf-
    /// callback attack isn't exploitable today (STATICCALL blocks it); these tests
    /// pin the observable post-condition + atomic-rollback property of CEI.
    contract HybridVotingReentrancyTest is Test {
        address owner = vm.addr(1);
        address alice = vm.addr(2);
        address bob = vm.addr(3);

        MockERC20RE token;
        MockHats hats;
        MockExecutorRE exec;
        HybridVoting hv;

        uint256 constant DEFAULT_HAT_ID = 1;
        uint256 constant CREATOR_HAT_ID = 3;

        function setUp() public {
            token = new MockERC20RE();
            hats = new MockHats();
            exec = new MockExecutorRE();

            hats.mintHat(DEFAULT_HAT_ID, alice);
            hats.mintHat(CREATOR_HAT_ID, alice);
            hats.mintHat(DEFAULT_HAT_ID, bob);
            hats.mintHat(CREATOR_HAT_ID, bob);

            token.mint(alice, 100e18);
            token.mint(bob, 100e18);

            uint256[] memory votingHats = new uint256[](1);
            votingHats[0] = DEFAULT_HAT_ID;
            uint256[] memory creatorHats = new uint256[](1);
            creatorHats[0] = CREATOR_HAT_ID;
            address[] memory targets = new address[](1);
            targets[0] = address(0xCA11);

            HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
            classes[0] = HybridVoting.ClassConfig({
                strategy: HybridVoting.ClassStrategy.ERC20_BAL,
                slicePct: 100,
                quadratic: false,
                minBalance: 1 ether,
                asset: address(token),
                hatIds: votingHats
            });

            bytes memory initData = abi.encodeCall(
                HybridVoting.initialize,
                (address(hats), address(exec), creatorHats, targets, uint8(50), uint8(50), classes)
            );

            HybridVoting impl = new HybridVoting();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
            BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
            hv = HybridVoting(payable(address(proxy)));

            IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
            batches[0] = new IExecutor.Call[](0);
            batches[1] = new IExecutor.Call[](0);
            vm.prank(alice);
            hv.createProposal("CEI Test", bytes32(0), 60, 2, batches, new uint256[](0));
        }

        function _vote(address voter, uint8 option) internal {
            uint8[] memory idx = new uint8[](1);
            idx[0] = option;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(voter);
            hv.vote(0, idx, w);
        }

        function test_CEI_voteSetsHasVotedAtomically_subsequentVoteReverts() public {
            _vote(alice, 0);

            // Second vote attempt from same voter must revert with AlreadyVoted.
            uint8[] memory idx = new uint8[](1);
            idx[0] = 1;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(alice);
            vm.expectRevert(VotingErrors.AlreadyVoted.selector);
            hv.vote(0, idx, w);
        }

        /// Reverted vote() must roll back hasVoted so the voter can retry.
        function test_CEI_revertedVoteRollsBackHasVoted() public {
            // Construct a scenario where the first vote attempt reverts:
            // alice's balance is below minBalance for a transient moment.
            // Easiest path: drain alice's balance so balanceOf returns 0, which
            // triggers the no-power revert (Unauthorized) inside vote().
            vm.prank(alice);
            token.transfer(bob, 100e18);

            // Alice attempts to vote with no balance → reverts on no-power check.
            uint8[] memory idx = new uint8[](1);
            idx[0] = 0;
            uint8[] memory w = new uint8[](1);
            w[0] = 100;
            vm.prank(alice);
            vm.expectRevert(VotingErrors.Unauthorized.selector);
            hv.vote(0, idx, w);

            // Restore alice's balance.
            vm.prank(bob);
            token.transfer(alice, 100e18);

            // Alice can now vote successfully — the earlier hasVoted=true was
            // rolled back by the revert. If CEI's early flip were sticky across
            // reverts, this call would fail with AlreadyVoted.
            vm.prank(alice);
            hv.vote(0, idx, w);
        }
    }
