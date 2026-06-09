// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Poa (Arbitrum) — paymaster rules for the TaskManager v6 deadline selectors,
 * via governance (proposal + creator vote in one broadcast)
 * ============================================================================
 *
 * TaskManager v6 REPLACED four selectors (deadline params appended). For the
 * live Poa org the paymaster must:
 *   allow  createTask          v6 0x4d0265d4   disallow v5 0x22fa79bc
 *   allow  createTasksBatch    v6 0xf31d148f   disallow v5 0xc18aa1c9
 *   allow  createAndAssignTask v6 0x98e30e89   disallow v5 0xaf425951
 *   allow  updateTask          v6 0xb7c288e8   disallow v5 0x48db6f65
 * The dead selectors are disallowed in the same batch — they no longer exist
 * on the upgraded impl, and leaving them allowed lets griefers burn sponsored
 * gas on guaranteed-revert userops.
 *
 * NOTE: rules are keyed by (orgId, target, selector), so this proposal can be
 * created/executed BEFORE the v6 beacon upgrade lands — sponsorship for the old
 * selectors only degrades between announceWinner and the beacon upgrade, an
 * ops-controlled window of minutes (see UpgradeTaskManagerDeadlines runbook).
 *
 * Single governance proposal whose one call the Poa Executor runs on execution:
 *   paymaster.setRulesBatch(orgId, [TM x8], [4 new, 4 old], [true x4, false x4], [0 x8])
 * Auth: setRulesBatch is `onlyOrgOperator`, satisfied by the org's adminHat
 * wearer (the Executor) when announceWinner fires Executor.execute.
 *
 * The BROADCAST creates the proposal AND casts the creator's vote (option 0,
 * 100%) — same mechanics proven by WhitelistTaskEditRulesPoaViaGovernance.
 *
 * Usage:
 *   # Sim (run first — note --fork-url arbitrum)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesPoaViaGovernance.s.sol:SimWhitelistTaskDeadlinePoa \
 *     --fork-url arbitrum -vvv
 *
 *   # Broadcast (creates the proposal AND votes)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesPoaViaGovernance.s.sol:BroadcastWhitelistTaskDeadlinePoa \
 *     --rpc-url arbitrum --broadcast --slow
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// PaymasterHub on Arbitrum.
address constant ARB_PAYMASTER_HUB = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;

// Poa (Arbitrum) — same org constants as WhitelistTaskEditRulesPoaViaGovernance.
bytes32 constant POA_ORG = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;
address constant POA_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
address constant POA_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;

// TaskManager v6 selectors (cast sig verified 2026-06-09).
bytes4 constant SEL_CREATE_TASK_V6 = 0x4d0265d4;
bytes4 constant SEL_CREATE_TASKS_BATCH_V6 = 0xf31d148f;
bytes4 constant SEL_CREATE_AND_ASSIGN_V6 = 0x98e30e89;
bytes4 constant SEL_UPDATE_TASK_V6 = 0xb7c288e8;
// Dead v5 selectors (replaced by v6; disallowed in the same batch).
bytes4 constant SEL_CREATE_TASK_OLD = 0x22fa79bc;
bytes4 constant SEL_CREATE_TASKS_BATCH_OLD = 0xc18aa1c9;
bytes4 constant SEL_CREATE_AND_ASSIGN_OLD = 0xaf425951;
bytes4 constant SEL_UPDATE_TASK_OLD = 0x48db6f65;

// Hudson — verified wearer of Poa HybridVoting's sole creator hat (see the edit-rules
// twin). Pranked in the sim; also the expected broadcaster.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

uint32 constant DEFAULT_PROPOSAL_DURATION_MINUTES = 10;

interface IPaymasterHubMinimal {
    // Field order matches PaymasterHub.sol's Rule struct exactly: (uint32 maxCallGasHint, bool allowed).
    // Decoding as (bool, uint32) would silently swap the values — see CLAUDE.md.
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

interface ITaskManagerLensMinimal {
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

abstract contract WhitelistTaskDeadlinePoaBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    function _newSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_V6, SEL_CREATE_TASKS_BATCH_V6, SEL_CREATE_AND_ASSIGN_V6, SEL_UPDATE_TASK_V6];
    }

    function _oldSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_OLD, SEL_CREATE_TASKS_BATCH_OLD, SEL_CREATE_AND_ASSIGN_OLD, SEL_UPDATE_TASK_OLD];
    }

    /// @dev Single-call batch: setRulesBatch allowing the 4 v6 selectors and
    /// disallowing the 4 dead v5 ones on Poa's TaskManager.
    function _buildBatch() internal pure returns (IExecutor.Call[] memory batch) {
        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();

        address[] memory targets = new address[](8);
        bytes4[] memory selectors = new bytes4[](8);
        bool[] memory allowed = new bool[](8);
        uint32[] memory hints = new uint32[](8);

        for (uint256 i; i < 4; ++i) {
            targets[i] = POA_TM;
            selectors[i] = news[i];
            allowed[i] = true;
            targets[4 + i] = POA_TM;
            selectors[4 + i] = olds[i];
            allowed[4 + i] = false;
        }

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
        console.log("\n=== v6 deadline-selector paymaster rules preview: Poa (Arbitrum) ===");
        console.log("  PaymasterHub:        ", ARB_PAYMASTER_HUB);
        console.log("  TaskManager (target):", POA_TM);
        console.log("  createTask v6 allowed now:         ", _ruleAllowed(SEL_CREATE_TASK_V6));
        console.log("  createTasksBatch v6 allowed now:   ", _ruleAllowed(SEL_CREATE_TASKS_BATCH_V6));
        console.log("  createAndAssignTask v6 allowed now:", _ruleAllowed(SEL_CREATE_AND_ASSIGN_V6));
        console.log("  updateTask v6 allowed now:         ", _ruleAllowed(SEL_UPDATE_TASK_V6));
        console.log("  -> 4 v6 selectors will be allowed, 4 dead v5 selectors disallowed");
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
                bytes("Poa: paymaster rules for TaskManager v6 deadline selectors (sim)"),
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

        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();
        for (uint256 i; i < 4; ++i) {
            require(_ruleAllowed(news[i]), "Sim: v6 selector still not allowed");
            require(!_ruleAllowed(olds[i]), "Sim: dead v5 selector still allowed");
        }
        console.log("PASS: Poa v6 deadline selectors allowed, dead v5 selectors disallowed.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcast() internal {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Poa v6 deadline-selector rules proposal + vote ===");
        console.log("  Sender:       ", sender);
        console.log("  HybridVoting: ", POA_HV);
        console.log("  PaymasterHub: ", ARB_PAYMASTER_HUB);
        console.log("  Duration:     ", minutesDuration, "minutes");
        _printPreview();

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hats = IHatsMinimal(abi.decode(ITaskManagerLensMinimal(POA_TM).getLensData(3, ""), (address)));
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
                bytes("Poa: paymaster rules for TaskManager v6 deadline selectors"),
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

contract SimWhitelistTaskDeadlinePoa is WhitelistTaskDeadlinePoaBase {
    function run() public {
        _simFlow();
    }
}

contract BroadcastWhitelistTaskDeadlinePoa is WhitelistTaskDeadlinePoaBase {
    function run() public {
        _broadcast();
    }
}
