// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) — paymaster rules for the TaskManager v6 deadline
 * selectors, via governance (proposal + creator vote in one broadcast)
 * ============================================================================
 *
 * Decentral Park twin of WhitelistTaskDeadlineRulesTest6KubiViaGovernance —
 * see WhitelistTaskDeadlineRulesPoaViaGovernance for the full rationale.
 * One proposal whose single Executor call is:
 *   paymaster.setRulesBatch(orgId, [TM x8], [4 v6 selectors, 4 dead v5],
 *                           [true x4, false x4], [0 x8])
 *
 *   allow  createTask          v6 0x4d0265d4   disallow v5 0x22fa79bc
 *   allow  createTasksBatch    v6 0xf31d148f   disallow v5 0xc18aa1c9
 *   allow  createAndAssignTask v6 0x98e30e89   disallow v5 0xaf425951
 *   allow  updateTask          v6 0xb7c288e8   disallow v5 0x48db6f65
 *
 * Usage:
 *   # Sim (run first)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesDecentralParkViaGovernance.s.sol:SimWhitelistTaskDeadlineDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the proposal AND votes)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesDecentralParkViaGovernance.s.sol:BroadcastWhitelistTaskDeadlineDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 30; HybridVoting min 10)
 * ============================================================================
 */

// PaymasterHub on Gnosis.
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Decentral Park (Gnosis) — same org constants as WhitelistTaskEditRulesDecentralParkViaGovernance.
bytes32 constant DECENTRAL_PARK_ORG_ID = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;

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

// Hudson — verified creator-hat wearer on Decentral Park's HybridVoting (see the edit-rules twin).
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

uint32 constant DEFAULT_PROPOSAL_DURATION_MINUTES = 30;

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

interface ITaskManagerLensMinimal {
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

abstract contract WhitelistTaskDeadlineDecentralParkBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    function _newSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_V6, SEL_CREATE_TASKS_BATCH_V6, SEL_CREATE_AND_ASSIGN_V6, SEL_UPDATE_TASK_V6];
    }

    function _oldSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_OLD, SEL_CREATE_TASKS_BATCH_OLD, SEL_CREATE_AND_ASSIGN_OLD, SEL_UPDATE_TASK_OLD];
    }

    function _buildBatch() internal pure returns (IExecutor.Call[] memory batch) {
        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();

        address[] memory targets = new address[](8);
        bytes4[] memory selectors = new bytes4[](8);
        bool[] memory allowed = new bool[](8);
        uint32[] memory hints = new uint32[](8);

        for (uint256 i; i < 4; ++i) {
            targets[i] = DECENTRAL_PARK_TM;
            selectors[i] = news[i];
            allowed[i] = true;
            targets[4 + i] = DECENTRAL_PARK_TM;
            selectors[4 + i] = olds[i];
            allowed[4 + i] = false;
        }

        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(
                IPaymasterHubMinimal.setRulesBatch, (DECENTRAL_PARK_ORG_ID, targets, selectors, allowed, hints)
            )
        });
    }

    function _ruleAllowed(bytes4 selector) internal view returns (bool) {
        return
            IPaymasterHubMinimal(GNOSIS_PAYMASTER_HUB)
            .getRule(DECENTRAL_PARK_ORG_ID, DECENTRAL_PARK_TM, selector)
            .allowed;
    }

    function _ballot() internal pure returns (uint8[] memory idxs, uint8[] memory weights) {
        idxs = new uint8[](1);
        weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
    }

    function _printPreview() internal view {
        console.log("\n=== v6 deadline-selector paymaster rules preview: Decentral Park (Gnosis) ===");
        console.log("  PaymasterHub:        ", GNOSIS_PAYMASTER_HUB);
        console.log("  TaskManager (target):", DECENTRAL_PARK_TM);
        console.log("  createTask v6 allowed now:         ", _ruleAllowed(SEL_CREATE_TASK_V6));
        console.log("  createTasksBatch v6 allowed now:   ", _ruleAllowed(SEL_CREATE_TASKS_BATCH_V6));
        console.log("  createAndAssignTask v6 allowed now:", _ruleAllowed(SEL_CREATE_AND_ASSIGN_V6));
        console.log("  updateTask v6 allowed now:         ", _ruleAllowed(SEL_UPDATE_TASK_V6));
        console.log("  -> 4 v6 selectors will be allowed, 4 dead v5 selectors disallowed");
    }

    /// @dev Full sim (real Hats, prank Hudson): create -> vote -> warp -> announceWinner -> assert.
    function _simFlow() internal {
        _printPreview();

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _buildBatch();

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: paymaster rules for TaskManager v6 deadline selectors (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);
        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(proposalId);
        require(valid, "Sim DecentralPark: proposal did not pass with the creator's single vote");
        console.log("  Winner option:", winner, " valid:", valid);

        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();
        for (uint256 i; i < 4; ++i) {
            require(_ruleAllowed(news[i]), "Sim: v6 selector still not allowed");
            require(!_ruleAllowed(olds[i]), "Sim: dead v5 selector still allowed");
        }
        console.log("PASS: Decentral Park v6 deadline selectors allowed, dead v5 selectors disallowed.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcast() internal {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Decentral Park v6 deadline-selector rules proposal + vote ===");
        console.log("  Sender:       ", sender);
        console.log("  HybridVoting: ", DECENTRAL_PARK_HV);
        console.log("  Duration:     ", minutesDuration, "minutes");
        _printPreview();

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hats =
            IHatsMinimal(abi.decode(ITaskManagerLensMinimal(DECENTRAL_PARK_TM).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(DECENTRAL_PARK_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender wears no creator hat on Decentral Park HybridVoting");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _buildBatch();

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: paymaster rules for TaskManager v6 deadline selectors"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);
        vm.stopBroadcast();

        console.log("  Proposal ID:", proposalId, "(vote cast)");
        console.log("  After the window expires, anyone calls announceWinner(", proposalId, ") to execute.");
    }
}

contract SimWhitelistTaskDeadlineDecentralPark is WhitelistTaskDeadlineDecentralParkBase {
    function run() public {
        _simFlow();
    }
}

contract BroadcastWhitelistTaskDeadlineDecentralPark is WhitelistTaskDeadlineDecentralParkBase {
    function run() public {
        _broadcast();
    }
}
