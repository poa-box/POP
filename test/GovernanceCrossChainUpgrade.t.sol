// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {PoaManager} from "../src/PoaManager.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {PoaManagerHub} from "../src/crosschain/PoaManagerHub.sol";
import {PoaManagerSatellite} from "../src/crosschain/PoaManagerSatellite.sol";
import {MockMailbox} from "./mocks/MockMailbox.sol";
import {Executor, IExecutor} from "../src/Executor.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {MockHats} from "./mocks/MockHats.sol";

/*──────────── Dummy implementations ───────────*/
contract GovDummyV1 {
    function version() external pure returns (string memory) {
        return "v1";
    }
}

contract GovDummyV2 {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

/*──────────── Mock ERC20 (minimal) ───────────*/
contract GovMockERC20 {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

/**
 * @title GovernanceCrossChainUpgradeTest
 * @notice Integration test: governance org votes to upgrade a beacon, and the
 *         upgrade propagates from home chain to satellite via Hyperlane.
 *
 *  Ownership chain:
 *    HybridVoting → Executor → PoaManagerHub → PoaManager (home)
 *                                    ↓ Hyperlane
 *                              PoaManagerSatellite → PoaManager (satellite)
 */
contract GovernanceCrossChainUpgradeTest is Test {
    /* ──────── Home chain ──────── */
    ImplementationRegistry homeReg;
    PoaManager homePM;
    PoaManagerHub hub;

    /* ──────── Satellite chain ──────── */
    ImplementationRegistry satReg;
    PoaManager satPM;
    PoaManagerSatellite satellite;

    /* ──────── Messaging ──────── */
    MockMailbox mailbox;

    /* ──────── Governance ──────── */
    Executor executor;
    HybridVoting hv;
    MockHats hats;
    GovMockERC20 token;

    /* ──────── Implementations ──────── */
    GovDummyV1 implV1;
    GovDummyV2 implV2;

    /* ──────── Actors ──────── */
    address alice = vm.addr(2);
    address carol = vm.addr(4);

    /* ──────── Hat constants ──────── */
    uint256 constant MEMBER_HAT = 1;
    uint256 constant CREATOR_HAT = 2;

    uint32 constant HOME_DOMAIN = 1;
    uint32 constant SAT_DOMAIN = 42;

    function setUp() public {
        implV1 = new GovDummyV1();
        implV2 = new GovDummyV2();

        // ── Messaging ──
        mailbox = new MockMailbox(HOME_DOMAIN);

        // ── Home chain infrastructure ──
        homeReg = _deployRegistry();
        homePM = new PoaManager(address(homeReg));
        homeReg.transferOwnership(address(homePM));

        // ── Satellite chain infrastructure ──
        satReg = _deployRegistry();
        satPM = new PoaManager(address(satReg));
        satReg.transferOwnership(address(satPM));

        // ── Hub (initially owned by this test contract) ──
        hub = new PoaManagerHub(address(homePM), address(mailbox));
        homePM.transferOwnership(address(hub));

        // ── Satellite ──
        satellite = new PoaManagerSatellite(address(satPM), address(mailbox), HOME_DOMAIN, address(hub));
        satPM.transferOwnership(address(satellite));

        // Register satellite on hub and add contract type on both chains
        hub.registerSatellite(SAT_DOMAIN, address(satellite));
        hub.addContractTypeCrossChain("Widget", address(implV1));

        // ── Governance: Executor (behind beacon proxy) ──
        hats = new MockHats();
        Executor execImpl = new Executor();
        UpgradeableBeacon execBeacon = new UpgradeableBeacon(address(execImpl), address(this));
        executor = Executor(
            payable(address(
                    new BeaconProxy(
                        address(execBeacon), abi.encodeCall(Executor.initialize, (address(this), address(hats)))
                    )
                ))
        );

        // ── Governance: HybridVoting (behind beacon proxy) ──
        token = new GovMockERC20();

        hats.mintHat(MEMBER_HAT, alice);
        hats.mintHat(CREATOR_HAT, alice);
        hats.mintHat(MEMBER_HAT, carol);
        hats.mintHat(CREATOR_HAT, carol);
        token.mint(alice, 100 ether);
        token.mint(carol, 100 ether);

        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = CREATOR_HAT;

        address[] memory targets = new address[](1);
        targets[0] = address(hub);

        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = MEMBER_HAT;

        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.DIRECT,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(0),
            hatIds: memberHats
        });

        HybridVoting hvImpl = new HybridVoting();
        UpgradeableBeacon hvBeacon = new UpgradeableBeacon(address(hvImpl), address(this));
        hv = HybridVoting(
            payable(address(
                    new BeaconProxy(
                        address(hvBeacon),
                        abi.encodeCall(
                            HybridVoting.initialize,
                            (address(hats), address(executor), creatorHats, targets, uint8(50), uint8(50), classes)
                        )
                    )
                ))
        );

        // Wire governance: HybridVoting is the Executor's allowed caller
        executor.setCaller(address(hv));

        // Transfer Hub ownership to Executor (two-step: propose then accept)
        hub.transferOwnership(address(executor));
        vm.prank(address(executor));
        hub.acceptOwnership();

        // Fund Executor so it can pay Hyperlane fees on behalf of governance
        vm.deal(address(executor), 1 ether);
    }

    // ══════════════════════════════════════════════════════════
    //  Governance vote triggers cross-chain upgrade
    // ══════════════════════════════════════════════════════════

    function testGovernanceVoteTriggersCrossChainUpgrade() public {
        // 1. Create proposal: batch calls hub.upgradeBeaconCrossChain
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);

        batches[0] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({
            target: address(hub),
            value: 0.001 ether,
            data: abi.encodeCall(PoaManagerHub.upgradeBeaconCrossChain, ("Widget", address(implV2), "v2"))
        });

        batches[1] = new IExecutor.Call[](0); // NO option: empty batch

        vm.prank(alice);
        uint256[] memory hatIds = new uint256[](0);
        hv.createProposal(bytes("Upgrade Widget to v2"), bytes32(0), 15, 2, batches, hatIds);

        // 2. Vote YES (alice + carol = 100% threshold, all YES)
        uint8[] memory yesIdx = new uint8[](1);
        yesIdx[0] = 0;
        uint8[] memory weight = new uint8[](1);
        weight[0] = 100;

        vm.prank(alice);
        hv.vote(0, yesIdx, weight);
        vm.prank(carol);
        hv.vote(0, yesIdx, weight);

        // 3. Advance past voting period and announce winner
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(alice);
        (uint256 winner, bool valid) = hv.announceWinner(0);

        assertTrue(valid, "threshold should be met");
        assertEq(winner, 0, "YES should win");

        // 4. Verify: home chain beacon upgraded to V2
        bytes32 typeId = keccak256(bytes("Widget"));
        assertEq(homePM.getCurrentImplementationById(typeId), address(implV2), "Home beacon should point to V2");

        // 5. Verify: satellite chain beacon ALSO upgraded to V2 (via MockMailbox synchronous delivery)
        assertEq(satPM.getCurrentImplementationById(typeId), address(implV2), "Satellite beacon should point to V2");

        // 6. Verify Hyperlane message was dispatched
        assertEq(mailbox.dispatchedCount(), 2, "1 from addContractTypeCrossChain + 1 from upgrade");
    }

    // ══════════════════════════════════════════════════════════
    //  Failed vote does NOT trigger upgrade
    // ══════════════════════════════════════════════════════════

    function testTiedVoteDoesNotUpgrade() public {
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);

        batches[0] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({
            target: address(hub),
            value: 0.001 ether,
            data: abi.encodeCall(PoaManagerHub.upgradeBeaconCrossChain, ("Widget", address(implV2), "v2"))
        });
        batches[1] = new IExecutor.Call[](0);

        vm.prank(alice);
        uint256[] memory hatIds = new uint256[](0);
        hv.createProposal(bytes("Upgrade Widget to v2"), bytes32(0), 15, 2, batches, hatIds);

        // Split vote: alice YES, carol NO → tie → invalid
        uint8[] memory yesIdx = new uint8[](1);
        yesIdx[0] = 0;
        uint8[] memory noIdx = new uint8[](1);
        noIdx[0] = 1;
        uint8[] memory weight = new uint8[](1);
        weight[0] = 100;

        vm.prank(alice);
        hv.vote(0, yesIdx, weight);
        vm.prank(carol);
        hv.vote(0, noIdx, weight);

        vm.warp(block.timestamp + 16 minutes);
        vm.prank(alice);
        (, bool valid) = hv.announceWinner(0);

        assertFalse(valid, "tie should be invalid");

        // Beacon should still point to V1
        bytes32 typeId = keccak256(bytes("Widget"));
        assertEq(homePM.getCurrentImplementationById(typeId), address(implV1), "Home beacon should still be V1");
        assertEq(satPM.getCurrentImplementationById(typeId), address(implV1), "Satellite beacon should still be V1");
    }

    // ══════════════════════════════════════════════════════════
    //  Direct call to Hub from non-Executor reverts
    // ══════════════════════════════════════════════════════════

    function testDirectCallToHubFromNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        hub.upgradeBeaconCrossChain("Widget", address(implV2), "v2");
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    function _deployRegistry() internal returns (ImplementationRegistry) {
        ImplementationRegistry regImpl = new ImplementationRegistry();
        UpgradeableBeacon regBeacon = new UpgradeableBeacon(address(regImpl), address(this));
        ImplementationRegistry reg = ImplementationRegistry(address(new BeaconProxy(address(regBeacon), "")));
        reg.initialize(address(this));
        return reg;
    }
}
