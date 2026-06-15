// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Poa (Arbitrum) — whitelist the TaskManager EDIT-task functions in the
 * PaymasterHub via governance, and cast the creator's vote in the same script
 * ============================================================================
 *
 * Arbitrum twin of WhitelistTaskEditRulesTest6KubiViaGovernance (Gnosis). Poa is
 * the home-chain governance org and lives on Arbitrum, so this targets the
 * Arbitrum PaymasterHub. The two edit selectors are not yet sponsored:
 *
 *   updateTask(uint256,uint256,bytes,bytes32,address,uint256)  0x48db6f65
 *   updateTaskMetadata(uint256,bytes,bytes32)                  0x26fa4e70
 *
 * Verified allowed=false on Arbitrum 2026-06-02 via getRule (createTasksBatch is
 * already allowed=true, so the rule set otherwise works).
 *
 * Single governance proposal whose one call the Poa Executor runs on execution:
 *   paymaster.setRulesBatch(orgId, [TM, TM], [updateTask, updateTaskMetadata],
 *                           [true, true], [0, 0])
 * Auth: setRulesBatch is `onlyOrgOperator`, satisfied by the org's adminHat
 * wearer (the Executor) when announceWinner fires Executor.execute.
 *
 * The BROADCAST creates the proposal AND casts the creator's vote (option 0,
 * 100%). Poa HV is threshold 50% / quorum 0 and the broadcaster wears its sole
 * creator hat (verified), so the single vote passes — proven by the sim's
 * announceWinner assertion.
 *
 * Sim-first per CLAUDE.md: stages create -> vote -> warp -> execute on an
 * ARBITRUM fork with REAL Hats (prank Hudson, verified creator-hat wearer); the
 * real Executor satisfies onlyOrgOperator on execution. Asserts both selectors
 * flip allowed=false -> true.
 *
 * Usage:
 *   # Sim (run first — note --fork-url arbitrum)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesPoaViaGovernance.s.sol:SimWhitelistTaskEditPoa \
 *     --fork-url arbitrum -vvv
 *
 *   # Broadcast (creates the proposal AND votes)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesPoaViaGovernance.s.sol:BroadcastWhitelistTaskEditPoa \
 *     --rpc-url arbitrum --broadcast --slow
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// PaymasterHub on Arbitrum.
address constant ARB_PAYMASTER_HUB = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;

// Poa (Arbitrum) — verified via Poa subgraph + on-chain reads 2026-06-02.
bytes32 constant POA_ORG = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;
address constant POA_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
address constant POA_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;

// TaskManager edit-task selectors.
bytes4 constant SEL_UPDATE_TASK = 0x48db6f65; // updateTask(uint256,uint256,bytes,bytes32,address,uint256)
bytes4 constant SEL_UPDATE_TASK_METADATA = 0x26fa4e70; // updateTaskMetadata(uint256,bytes,bytes32)

// Hudson — verified wearer of Poa HybridVoting's sole creator hat. Pranked in the sim so create +
// vote resolve against real on-chain Hats state; also the expected broadcaster.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

uint32 constant DEFAULT_PROPOSAL_DURATION_MINUTES = 10;

interface IPaymasterHubMinimal {
    // Field order matches PaymasterHub.sol's Rule struct exactly: (uint32 maxCallGasHint, bool allowed).
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function setRulesBatch(
        bytes32 orgId,
        address[] calldata targets,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) external;

    function getRule(bytes32 orgId, address target, bytes4 selector) external view returns (Rule memory);
}

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
}

abstract contract WhitelistTaskEditPoaBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    /// @dev Single-call batch: setRulesBatch enabling both edit selectors on Poa's TaskManager.
    function _buildBatch() internal pure returns (IExecutor.Call[] memory batch) {
        address[] memory targets = new address[](2);
        bytes4[] memory selectors = new bytes4[](2);
        bool[] memory allowed = new bool[](2);
        uint32[] memory hints = new uint32[](2);

        targets[0] = POA_TM;
        selectors[0] = SEL_UPDATE_TASK;
        allowed[0] = true;
        targets[1] = POA_TM;
        selectors[1] = SEL_UPDATE_TASK_METADATA;
        allowed[1] = true;

        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: ARB_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(IPaymasterHubMinimal.setRulesBatch, (POA_ORG, targets, selectors, allowed, hints))
        });
    }

    function _ruleAllowed(bytes4 selector) internal view returns (bool) {
        return IPaymasterHubMinimal(ARB_PAYMASTER_HUB).getRule(POA_ORG, POA_TM, selector).allowed;
    }

    function _ballot() internal pure returns (uint8[] memory idxs, uint8[] memory weights) {
        idxs = new uint8[](1);
        weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
    }

    function _printPreview() internal view {
        console.log("\n=== Edit-task paymaster whitelist preview: Poa (Arbitrum) ===");
        console.log("  PaymasterHub:        ", ARB_PAYMASTER_HUB);
        console.log("  TaskManager (target):", POA_TM);
        console.log("  updateTask allowed now:        ", _ruleAllowed(SEL_UPDATE_TASK));
        console.log("  updateTaskMetadata allowed now:", _ruleAllowed(SEL_UPDATE_TASK_METADATA));
        console.log("  -> both will be set allowed = true");
    }

    /// @dev Full sim (real Hats, prank Hudson): create -> vote -> warp -> announceWinner -> assert.
    function _simFlow() internal {
        _printPreview();

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(POA_HV)
            .createProposal(
                bytes("Poa: whitelist updateTask + updateTaskMetadata for sponsorship (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(POA_HV).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();
        vm.prank(HUDSON);
        HybridVoting(POA_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);
        (uint256 winner, bool valid) = HybridVoting(POA_HV).announceWinner(proposalId);
        require(valid, "Sim Poa: proposal did not pass with the creator's single vote");
        console.log("  Winner option:", winner, " valid:", valid);

        require(_ruleAllowed(SEL_UPDATE_TASK), "Sim: updateTask still not allowed");
        require(_ruleAllowed(SEL_UPDATE_TASK_METADATA), "Sim: updateTaskMetadata still not allowed");
        console.log("PASS: Poa edit-task sponsorship whitelisted end-to-end.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcast() internal {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Poa edit-task whitelist proposal + vote ===");
        console.log("  Sender:       ", sender);
        console.log("  HybridVoting: ", POA_HV);
        console.log("  PaymasterHub: ", ARB_PAYMASTER_HUB);
        console.log("  Duration:     ", minutesDuration, "minutes");
        _printPreview();

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hats = IHatsMinimal(abi.decode(TaskManager(POA_TM).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(POA_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender wears no creator hat on Poa HybridVoting");

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();

        vm.startBroadcast(key);
        HybridVoting(POA_HV)
            .createProposal(
                bytes("Poa: whitelist updateTask + updateTaskMetadata for gas sponsorship"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(POA_HV).proposalsCount() - 1;
        HybridVoting(POA_HV).vote(proposalId, idxs, weights);
        vm.stopBroadcast();

        console.log("  Proposal ID:", proposalId, "(vote cast)");
        console.log("  After the window expires, anyone calls announceWinner(", proposalId, ") to execute.");
    }
}

contract SimWhitelistTaskEditPoa is WhitelistTaskEditPoaBase {
    function run() public {
        _simFlow();
    }
}

contract BroadcastWhitelistTaskEditPoa is WhitelistTaskEditPoaBase {
    function run() public {
        _broadcast();
    }
}
