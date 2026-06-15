// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) — whitelist the TaskManager EDIT-task functions in
 * the PaymasterHub so passkey / smart accounts can edit tasks gas-sponsored
 * ============================================================================
 *
 * PaymasterHub only sponsors (orgId, target, selector) calls whose Rule is
 * `allowed = true`. Decentral Park's creation selectors are already whitelisted
 * (createTask 0x22fa79bc, createAndAssignTask 0xaf425951, createTasksBatch
 * 0xc18aa1c9 — the last via PR #155), but the two EDIT selectors are NOT, so a
 * sponsored passkey account reverts when trying to edit a task:
 *
 *   updateTask(uint256,uint256,bytes,bytes32,address,uint256)  0x48db6f65  allowed=false
 *   updateTaskMetadata(uint256,bytes,bytes32)                  0x26fa4e70  allowed=false
 *
 * Verified on Gnosis 2026-06-02 via getRule(orgId, taskManager, selector).
 *
 * This is a single governance proposal whose one call is executed by Decentral
 * Park's Executor:
 *
 *   paymaster.setRulesBatch(orgId, [TM, TM], [updateTask, updateTaskMetadata],
 *                           [true, true], [0, 0])
 *
 * Auth: setRulesBatch is `onlyOrgOperator` — satisfied by the org's adminHat
 * wearer (the Executor) OR the operatorHat wearer. The Executor wears the
 * adminHat, so when announceWinner fires Executor.execute the call passes
 * against real Hats Protocol state. (maxCallGasHint = 0 = no hint, matching the
 * existing creation-selector rules; allowed=true is the only thing that gates
 * sponsorship.)
 *
 * Sim-first per CLAUDE.md: stages the full create -> vote -> execute path on a
 * Gnosis fork using REAL Hats (no etch). Pranks Hudson (verified Delegate-hat
 * wearer, a HybridVoting creator hat) for createProposal + vote; the real
 * Executor (real adminHat wearer) satisfies onlyOrgOperator when it executes,
 * so the sim exercises the exact production auth path. Asserts both selectors
 * flip allowed=false -> true.
 *
 * Usage:
 *   # Sim (no broadcast — validate end-to-end on a fork)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesDecentralParkViaGovernance.s.sol:SimWhitelistTaskEditDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the real proposal; members vote in normal cadence)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesDecentralParkViaGovernance.s.sol:BroadcastWhitelistTaskEditDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 30; HybridVoting min 10)
 * ============================================================================
 */

// PaymasterHub on Gnosis — confirmed via ConfigureDecentralParkPaymasterViaGovernance.s.sol
// and AddCreateTasksBatchSelectorRules.s.sol.
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Decentral Park (Gnosis) — verified via Poa subgraph + on-chain reads.
bytes32 constant DECENTRAL_PARK_ORG_ID = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;

// TaskManager edit-task selectors (verify with: cast sig '<signature>').
//   cast sig 'updateTask(uint256,uint256,bytes,bytes32,address,uint256)' = 0x48db6f65
//   cast sig 'updateTaskMetadata(uint256,bytes,bytes32)'                  = 0x26fa4e70
bytes4 constant SEL_UPDATE_TASK = 0x48db6f65;
bytes4 constant SEL_UPDATE_TASK_METADATA = 0x26fa4e70;

// Hudson — verified Delegate-hat wearer on Decentral Park (Gnosis). The sim pranks this address
// for createProposal + vote so all hat checks resolve against real on-chain Hats state, not a
// shim. He's also the expected broadcaster (wears a HybridVoting creator hat).
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

uint32 constant DEFAULT_PROPOSAL_DURATION_MINUTES = 30;

/// @dev Minimal PaymasterHub surface this script touches.
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

abstract contract WhitelistTaskEditBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    /// @dev Build the single-call batch: setRulesBatch enabling the two edit selectors on the
    /// org's TaskManager. maxCallGasHint = 0 (no hint), matching the existing creation rules.
    function _buildBatch() internal pure returns (IExecutor.Call[] memory batch) {
        address[] memory targets = new address[](2);
        bytes4[] memory selectors = new bytes4[](2);
        bool[] memory allowed = new bool[](2);
        uint32[] memory hints = new uint32[](2);

        targets[0] = DECENTRAL_PARK_TM;
        selectors[0] = SEL_UPDATE_TASK;
        allowed[0] = true;
        hints[0] = 0;

        targets[1] = DECENTRAL_PARK_TM;
        selectors[1] = SEL_UPDATE_TASK_METADATA;
        allowed[1] = true;
        hints[1] = 0;

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

    function _printPreview() internal view {
        console.log("\n=== Edit-task paymaster whitelist preview (Decentral Park) ===");
        console.log("  PaymasterHub:        ", GNOSIS_PAYMASTER_HUB);
        console.log("  TaskManager (target):", DECENTRAL_PARK_TM);
        console.log("  updateTask allowed now:        ", _ruleAllowed(SEL_UPDATE_TASK));
        console.log("  updateTaskMetadata allowed now:", _ruleAllowed(SEL_UPDATE_TASK_METADATA));
        console.log("  -> both will be set allowed = true");
    }

    /// @dev Full sim using REAL Hats (no etch): prank Hudson for createProposal + vote; the real
    /// Executor (adminHat wearer) satisfies onlyOrgOperator when it executes setRulesBatch.
    function _simFullFlow() internal {
        _printPreview();

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0); // unrestricted poll
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: whitelist updateTask + updateTaskMetadata for sponsorship (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                pollHats
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        console.log("\n  Proposal id:", proposalId);

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass (likely quorum - add more pranked voters)");
        console.log("  Winner option:", winner, " valid:", valid);

        // Post-state: both edit selectors are now sponsored.
        require(_ruleAllowed(SEL_UPDATE_TASK), "Sim: updateTask still not allowed");
        require(_ruleAllowed(SEL_UPDATE_TASK_METADATA), "Sim: updateTaskMetadata still not allowed");
        console.log("\n  Post-state: updateTask allowed =", _ruleAllowed(SEL_UPDATE_TASK));
        console.log("  Post-state: updateTaskMetadata allowed =", _ruleAllowed(SEL_UPDATE_TASK_METADATA));
        console.log("PASS: Decentral Park edit-task sponsorship whitelisted end-to-end.");
    }

    /// @dev Real broadcast: creates the proposal on-chain. Members vote in normal cadence.
    function _broadcast() internal {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Decentral Park edit-task whitelist proposal ===");
        console.log("  Sender:        ", sender);
        console.log("  HybridVoting:  ", DECENTRAL_PARK_HV);
        console.log("  PaymasterHub:  ", GNOSIS_PAYMASTER_HUB);
        console.log("  Duration:      ", minutesDuration, "minutes");
        _printPreview();

        // Sanity: sender must wear a creator hat or createProposal reverts NotCreator.
        IHatsMinimal hats = IHatsMinimal(abi.decode(TaskManager(DECENTRAL_PARK_TM).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(DECENTRAL_PARK_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on Decentral Park HybridVoting");

        IExecutor.Call[] memory batch = _buildBatch();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: whitelist updateTask + updateTaskMetadata for gas sponsorship"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        uint256 newId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        require(newId == idBefore, "Proposal not created");
        console.log("\n  Proposal ID:", newId);
        console.log("  Next: members vote; after expiry, anyone calls announceWinner(", newId, ")");
    }
}

contract SimWhitelistTaskEditDecentralPark is WhitelistTaskEditBase {
    function run() public {
        _simFullFlow();
    }
}

contract BroadcastWhitelistTaskEditDecentralPark is WhitelistTaskEditBase {
    function run() public {
        _broadcast();
    }
}
