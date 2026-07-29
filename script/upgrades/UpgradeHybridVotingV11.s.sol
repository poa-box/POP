// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {IExecutor} from "../../src/Executor.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {VotingErrors} from "../../src/libs/VotingErrors.sol";

/// HybridVoting v11: configurable turnout-pct early-close gate.
/// Run SimulateHybridVotingV11Upgrade against an Arbitrum fork first,
/// then Step1 (gnosis) -> Step2 (arbitrum, dispatches cross-chain) ->
/// wait ~5 min for Hyperlane -> Step3 (verify gnosis). See PR #163.
contract Step1_DeployOnGnosis is Script {
    address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    string constant VERSION = "v11";

    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        DeterministicDeployer dd = DeterministicDeployer(DD);
        console.log("\n=== Step 1: Deploy HybridVoting v11 on Gnosis ===");
        console.log("Deployer:", deployer);

        bytes32 salt = dd.computeSalt("HybridVoting", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("Predicted address:", predicted);

        if (predicted.code.length > 0) {
            console.log("HybridVoting v11 already deployed:", predicted);
            return;
        }

        vm.startBroadcast(deployerKey);
        address deployed = dd.deploy(salt, type(HybridVoting).creationCode);
        vm.stopBroadcast();

        require(deployed == predicted, "HV address mismatch");
        console.log("HybridVoting v11 deployed:", deployed);
        console.log("\nNext: Run Step2_UpgradeFromArbitrum on Arbitrum");
    }
}

contract Step2_UpgradeFromArbitrum is Script {
    address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    string constant VERSION = "v11";
    uint256 constant HYPERLANE_FEE = 0.005 ether;

    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);

        console.log("\n=== Step 2: Upgrade HybridVoting from Arbitrum ===");
        console.log("Deployer:", deployer);
        require(hub.owner() == deployer, "Deployer must own Hub");
        require(!hub.paused(), "Hub is paused");

        bytes32 salt = dd.computeSalt("HybridVoting", VERSION);
        address impl = dd.computeAddress(salt);
        console.log("HybridVoting v11 impl:", impl);

        // Pre-upgrade snapshot of current Arbitrum impl
        address pm = address(hub.poaManager());
        address before = PoaManager(pm).getCurrentImplementationById(keccak256("HybridVoting"));
        console.log("Current Arbitrum impl:", before);

        vm.startBroadcast(deployerKey);

        if (impl.code.length == 0) {
            address deployed = dd.deploy(salt, type(HybridVoting).creationCode);
            require(deployed == impl, "Address mismatch on Arbitrum");
            console.log("HybridVoting deployed on Arbitrum");
        } else {
            console.log("HybridVoting already deployed on Arbitrum");
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("HybridVoting", impl, VERSION);
        console.log("HybridVoting beacon upgrade dispatched (Arbitrum local + Gnosis cross-chain)");

        vm.stopBroadcast();

        // Verify Arbitrum local upgrade (Gnosis verifies after Hyperlane relay)
        address current = PoaManager(pm).getCurrentImplementationById(keccak256("HybridVoting"));
        require(current == impl, "Arbitrum impl not upgraded");
        console.log("Arbitrum upgrade: PASS");
        console.log("Before:", before);
        console.log("After: ", current);
        console.log("\nWait ~5 min for Hyperlane relay, then run Step3_Verify on Gnosis");
    }
}

contract Step3_Verify is Script {
    address constant GNOSIS_PM = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    string constant VERSION = "v11";

    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address expected = dd.computeAddress(dd.computeSalt("HybridVoting", VERSION));
        address current = PoaManager(GNOSIS_PM).getCurrentImplementationById(keccak256("HybridVoting"));

        console.log("\n=== Verify Gnosis HybridVoting Upgrade ===");
        console.log("Expected:", expected);
        console.log("Current: ", current);
        console.log("Status:  ", current == expected ? "PASS" : "WAITING (Hyperlane not relayed yet)");
    }
}

/// Fork-simulates the upgrade end-to-end on Arbitrum under Hudson's prank.
/// Gnosis cross-chain relay isn't simulated; Step3_Verify covers that post-broadcast.
contract SimulateHybridVotingV11Upgrade is Script {
    // Hub admin EOA per CLAUDE.md — Hudson. Owns PoaManagerHub on Arbitrum.
    address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    address constant HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    string constant VERSION = "v11";
    uint256 constant HYPERLANE_FEE = 0.005 ether;

    // KUBI org on Arbitrum — used for live-proxy verification of the new impl.
    address constant KUBI_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;
    address constant KUBI_EXEC = 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41;

    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(HUB));
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address pm = address(hub.poaManager());

        console.log("\n========================================");
        console.log("  HybridVoting v11 Upgrade Simulation");
        console.log("========================================");
        console.log("Hub admin (prank):", HUDSON);
        require(hub.owner() == HUDSON, "Hub owner != Hudson; CLAUDE.md address stale");

        // ── 1. Pre-upgrade state ──
        bytes32 hvTypeId = keccak256("HybridVoting");
        address implBefore = PoaManager(pm).getCurrentImplementationById(hvTypeId);
        console.log("\n--- Pre-upgrade ---");
        console.log("HV impl:", implBefore);
        require(implBefore != address(0), "no current HV impl");

        // ── 2. Compute v11 DD address ──
        bytes32 salt = dd.computeSalt("HybridVoting", VERSION);
        address predicted = dd.computeAddress(salt);
        console.log("\n--- v11 impl prediction ---");
        console.log("Predicted address:", predicted);
        require(predicted != implBefore, "v11 salt collides with v10 impl");

        // ── 3. Deploy v11 + upgrade beacon under Hudson's prank ──
        vm.deal(HUDSON, 1 ether); // hyperlane fee
        vm.startPrank(HUDSON);

        if (predicted.code.length == 0) {
            address deployed = dd.deploy(salt, type(HybridVoting).creationCode);
            require(deployed == predicted, "v11 address mismatch");
            console.log("v11 deployed at:", deployed);
        } else {
            console.log("v11 already deployed at:", predicted);
        }

        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("HybridVoting", predicted, VERSION);

        vm.stopPrank();

        // ── 4. Verify Arbitrum impl swapped ──
        address implAfter = PoaManager(pm).getCurrentImplementationById(hvTypeId);
        require(implAfter == predicted, "Arbitrum impl not upgraded");
        require(implAfter.code.length > 0, "Impl has no code");
        console.log("\n--- Upgrade verification ---");
        console.log("HV impl after:", implAfter);
        console.log("Codesize:", implAfter.code.length, "bytes");
        console.log("Arbitrum upgrade: PASS");

        // ── 5. KUBI proxy now resolves new impl ──
        HybridVoting hv = HybridVoting(KUBI_HV);
        console.log("\n--- KUBI HV proxy verification ---");
        uint256 count = hv.proposalsCount();
        console.log("KUBI proposalsCount:", count);
        uint8 threshold = hv.thresholdPct();
        console.log("KUBI thresholdPct:", threshold);

        // ── 6. New view function is reachable through the proxy ──
        console.log("\n--- Test: isEarlyCloseEligible view ---");
        if (count > 0) {
            bool eligible = hv.isEarlyCloseEligible(count - 1);
            console.log("isEarlyCloseEligible(latest):", eligible ? "true" : "false");
        } else {
            console.log("No proposals on KUBI; skipping live read.");
        }
        bool outOfRange = hv.isEarlyCloseEligible(type(uint256).max);
        require(!outOfRange, "out-of-range id must return false");
        console.log("isEarlyCloseEligible(out-of-range): false (PASS)");

        // ── 7. End-to-end: new proposal lifecycle under v11 impl ──
        console.log("\n--- Test: end-to-end create + vote + announce ---");
        _testProposalLifecycle(hv);

        // ── 8. Test the new gate: unanimous vote triggers early-close ──
        console.log("\n--- Test: full-turnout vote triggers early-close gate ---");
        _testEarlyCloseFires(hv);

        console.log("\n========================================");
        console.log("  ALL SIMULATION CHECKS PASSED");
        console.log("========================================");
    }

    /// Mocks the IHats.isWearerOfHat path so `who` is treated as wearing every
    /// hat the HybridVoting instance uses for creator / class gating.
    function _mockHats(address who, HybridVoting hv) internal {
        uint256[] memory creatorHats = hv.creatorHats();
        require(creatorHats.length > 0, "No creator hats on proxy");
        for (uint256 i = 0; i < creatorHats.length; i++) {
            vm.mockCall(
                HATS, abi.encodeWithSelector(IHats.isWearerOfHat.selector, who, creatorHats[i]), abi.encode(true)
            );
        }
        HybridVoting.ClassConfig[] memory classes = hv.getClasses();
        for (uint256 i = 0; i < classes.length; i++) {
            for (uint256 j = 0; j < classes[i].hatIds.length; j++) {
                vm.mockCall(
                    HATS,
                    abi.encodeWithSelector(IHats.isWearerOfHat.selector, who, classes[i].hatIds[j]),
                    abi.encode(true)
                );
                vm.mockCall(
                    HATS, abi.encodeWithSelector(IHats.hatSupply.selector, classes[i].hatIds[j]), abi.encode(uint32(1))
                );
            }
            // Force balanceOf for ERC20 classes so the prank voter has power.
            if (classes[i].strategy == HybridVoting.ClassStrategy.ERC20_BAL && classes[i].asset != address(0)) {
                vm.mockCall(
                    classes[i].asset, abi.encodeWithSignature("balanceOf(address)", who), abi.encode(uint256(1000e18))
                );
            }
        }
        // Force creator-hat supply to a known value so the gate's threshold is
        // computable. Treats Hudson as a 1-of-1 eligible voter for sim purposes.
        for (uint256 i = 0; i < creatorHats.length; i++) {
            vm.mockCall(HATS, abi.encodeWithSelector(IHats.hatSupply.selector, creatorHats[i]), abi.encode(uint32(1)));
        }
    }

    function _testProposalLifecycle(HybridVoting hv) internal {
        _mockHats(HUDSON, hv);

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);

        vm.startPrank(HUDSON);

        uint256 id = hv.proposalsCount();
        hv.createProposal(bytes("v11 sim proposal"), keccak256(abi.encode(id)), 10, 2, batches, new uint256[](0));
        console.log("  Created proposal id:", id);

        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;
        hv.vote(id, idxs, weights);
        console.log("  Voted YES");

        vm.stopPrank();

        // Warp past timer (MIN_DURATION = 10 minutes).
        vm.warp(block.timestamp + 11 minutes);

        (uint256 winner, bool valid) = hv.announceWinner(id);
        require(valid, "announceWinner should be valid");
        require(winner == 0, "Winner should be option 0");
        console.log("  Announced: winner=%d valid=%s", winner, valid ? "true" : "false");
        console.log("  PASS: end-to-end lifecycle works under v11");
    }

    function _testEarlyCloseFires(HybridVoting hv) internal {
        _mockHats(HUDSON, hv);

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](0);
        batches[1] = new IExecutor.Call[](0);

        vm.startPrank(HUDSON);

        uint256 id = hv.proposalsCount();
        hv.createProposal(
            bytes("v11 early-close test"), keccak256(abi.encode(id, "ec")), 10, 2, batches, new uint256[](0)
        );

        // Single vote with mocked 1-of-1 creator-hat supply -> threshold = 1
        // -> unanimous YES at 100% turnout (the upgrade default) triggers the gate.
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        uint8[] memory weights = new uint8[](1);
        weights[0] = 100;
        hv.vote(id, idxs, weights);

        vm.stopPrank();

        // Should be early-close eligible BEFORE the timer expires.
        bool eligible = hv.isEarlyCloseEligible(id);
        require(eligible, "v11 turnout-only gate did not fire on unanimous single-voter vote");
        console.log("  isEarlyCloseEligible: true (PASS)");

        // announceWinner must succeed before timer expiry via the gate path.
        (uint256 winner, bool valid) = hv.announceWinner(id);
        require(valid && winner == 0, "early-close announce mismatch");
        console.log("  Early-closed: winner=%d valid=%s", winner, valid ? "true" : "false");
        console.log("  PASS: turnout-only gate fires correctly");
    }
}
