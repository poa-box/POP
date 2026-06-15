// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Test6 + KUBI (Gnosis) — paymaster rules for the TaskManager v6 deadline
 * selectors, via governance (proposal + creator vote per org)
 * ============================================================================
 *
 * Gnosis twin of WhitelistTaskDeadlineRulesPoaViaGovernance — see that header
 * for the full rationale. Per org, one proposal whose single Executor call is:
 *   paymaster.setRulesBatch(orgId, [TM x8], [4 v6 selectors, 4 dead v5],
 *                           [true x4, false x4], [0 x8])
 *
 *   allow  createTask          v6 0x4d0265d4   disallow v5 0x22fa79bc
 *   allow  createTasksBatch    v6 0xf31d148f   disallow v5 0xc18aa1c9
 *   allow  createAndAssignTask v6 0x98e30e89   disallow v5 0xaf425951
 *   allow  updateTask          v6 0xb7c288e8   disallow v5 0x48db6f65
 *
 * Usage:
 *   # Sims (run first)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesTest6KubiViaGovernance.s.sol:SimWhitelistTaskDeadlineTest6 \
 *     --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesTest6KubiViaGovernance.s.sol:SimWhitelistTaskDeadlineKubi \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcasts (each creates its org's proposal AND votes)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesTest6KubiViaGovernance.s.sol:BroadcastWhitelistTaskDeadlineTest6 \
 *     --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskDeadlineRulesTest6KubiViaGovernance.s.sol:BroadcastWhitelistTaskDeadlineKubi \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// PaymasterHub on Gnosis.
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Test6 (Gnosis) — same org constants as WhitelistTaskEditRulesTest6KubiViaGovernance.
bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;

// KUBI (Gnosis).
bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
address constant KUBI_TM = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
address constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;

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

// Hudson — verified creator-hat wearer on both orgs' HybridVoting (see the edit-rules twin).
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

interface ITaskManagerLensMinimal {
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

abstract contract WhitelistTaskDeadlineGnosisBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    function _resolveKey() internal view returns (uint256 key) {
        key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _newSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_V6, SEL_CREATE_TASKS_BATCH_V6, SEL_CREATE_AND_ASSIGN_V6, SEL_UPDATE_TASK_V6];
    }

    function _oldSelectors() internal pure returns (bytes4[4] memory) {
        return [SEL_CREATE_TASK_OLD, SEL_CREATE_TASKS_BATCH_OLD, SEL_CREATE_AND_ASSIGN_OLD, SEL_UPDATE_TASK_OLD];
    }

    function _buildBatch(bytes32 orgId, address tm) internal pure returns (IExecutor.Call[] memory batch) {
        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();

        address[] memory targets = new address[](8);
        bytes4[] memory selectors = new bytes4[](8);
        bool[] memory allowed = new bool[](8);
        uint32[] memory hints = new uint32[](8);

        for (uint256 i; i < 4; ++i) {
            targets[i] = tm;
            selectors[i] = news[i];
            allowed[i] = true;
            targets[4 + i] = tm;
            selectors[4 + i] = olds[i];
            allowed[4 + i] = false;
        }

        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(IPaymasterHubMinimal.setRulesBatch, (orgId, targets, selectors, allowed, hints))
        });
    }

    function _ruleAllowed(bytes32 orgId, address tm, bytes4 selector) internal view returns (bool) {
        return IPaymasterHubMinimal(GNOSIS_PAYMASTER_HUB).getRule(orgId, tm, selector).allowed;
    }

    function _ballot() internal pure returns (uint8[] memory idxs, uint8[] memory weights) {
        idxs = new uint8[](1);
        weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
    }

    function _printPreview(string memory name, bytes32 orgId, address tm) internal view {
        console.log("\n=== v6 deadline-selector paymaster rules preview:", name, "(Gnosis) ===");
        console.log("  PaymasterHub:        ", GNOSIS_PAYMASTER_HUB);
        console.log("  TaskManager (target):", tm);
        console.log("  createTask v6 allowed now:         ", _ruleAllowed(orgId, tm, SEL_CREATE_TASK_V6));
        console.log("  createTasksBatch v6 allowed now:   ", _ruleAllowed(orgId, tm, SEL_CREATE_TASKS_BATCH_V6));
        console.log("  createAndAssignTask v6 allowed now:", _ruleAllowed(orgId, tm, SEL_CREATE_AND_ASSIGN_V6));
        console.log("  updateTask v6 allowed now:         ", _ruleAllowed(orgId, tm, SEL_UPDATE_TASK_V6));
        console.log("  -> 4 v6 selectors will be allowed, 4 dead v5 selectors disallowed");
    }

    /// @dev Full sim (real Hats, prank Hudson): create -> vote -> warp -> announceWinner -> assert.
    function _simFlow(string memory name, bytes32 orgId, address tm, address hv) internal {
        _printPreview(name, orgId, tm);

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _buildBatch(orgId, tm);

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(hv)
            .createProposal(
                bytes("Paymaster rules for TaskManager v6 deadline selectors (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(hv).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();
        vm.prank(HUDSON);
        HybridVoting(hv).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);
        (uint256 winner, bool valid) = HybridVoting(hv).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass with the creator's single vote");
        console.log("  Winner option:", winner, " valid:", valid);

        bytes4[4] memory news = _newSelectors();
        bytes4[4] memory olds = _oldSelectors();
        for (uint256 i; i < 4; ++i) {
            require(_ruleAllowed(orgId, tm, news[i]), "Sim: v6 selector still not allowed");
            require(!_ruleAllowed(orgId, tm, olds[i]), "Sim: dead v5 selector still allowed");
        }
        console.log("PASS:", name, "v6 deadline selectors allowed, dead v5 selectors disallowed.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcastCreateAndVote(uint256 key, string memory name, bytes32 orgId, address tm, address hv) internal {
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting", name, "v6 deadline-selector rules proposal + vote ===");
        console.log("  Sender:       ", sender);
        console.log("  HybridVoting: ", hv);
        console.log("  Duration:     ", minutesDuration, "minutes");
        _printPreview(name, orgId, tm);

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hats = IHatsMinimal(abi.decode(ITaskManagerLensMinimal(tm).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(hv).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender wears no creator hat on this org's HybridVoting");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _buildBatch(orgId, tm);

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();

        vm.startBroadcast(key);
        HybridVoting(hv)
            .createProposal(
                bytes("Paymaster rules for TaskManager v6 deadline selectors"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        uint256 proposalId = HybridVoting(hv).proposalsCount() - 1;
        HybridVoting(hv).vote(proposalId, idxs, weights);
        vm.stopBroadcast();

        console.log("  Proposal ID:", proposalId, "(vote cast)");
        console.log("  After the window expires, anyone calls announceWinner(", proposalId, ") to execute.");
    }
}

contract SimWhitelistTaskDeadlineTest6 is WhitelistTaskDeadlineGnosisBase {
    function run() public {
        _simFlow("Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

contract BroadcastWhitelistTaskDeadlineTest6 is WhitelistTaskDeadlineGnosisBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

contract SimWhitelistTaskDeadlineKubi is WhitelistTaskDeadlineGnosisBase {
    function run() public {
        _simFlow("KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}

contract BroadcastWhitelistTaskDeadlineKubi is WhitelistTaskDeadlineGnosisBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}
