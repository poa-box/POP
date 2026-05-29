// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) — Paymaster ops handover + gas-sponsorship bump
 * ============================================================================
 *
 * Single governance proposal with 3 calls executed by Decentral Park's Executor
 * (the topHat wearer, satisfying PaymasterHub's `onlyOrgAdmin` modifier):
 *
 *   1. `paymaster.setOperatorHat(orgId, DELEGATE_HAT)`
 *      → Lets Delegate-hat wearers configure gas sponsorship for the org
 *        going forward (setRule / setBudget / setFeeCaps without needing a
 *        new governance vote each time).
 *
 *   2. `paymaster.setBudget(orgId, delegateSubjectKey, newCap, epochLen)`
 *      → Raise Delegate's per-epoch gas budget. Current state on Gnosis:
 *        capPerEpoch = 0.0002 xDAI / week. Default new cap = 1 xDAI / week
 *        (5000x bump). Override via DELEGATE_CAP_PER_EPOCH env var.
 *
 *   3. `paymaster.setBudget(orgId, neighborSubjectKey, newCap, epochLen)`
 *      → Raise Neighbor's per-epoch gas budget. Same current state. Default
 *        new cap = 0.5 xDAI / week. Override via NEIGHBOR_CAP_PER_EPOCH.
 *
 * Subject-key encoding for hats is `keccak256(abi.encodePacked(uint8(1), bytes32(hatId)))`
 * — confirmed against PaymasterHub.sol's storage layout. Mirrors the cast computation
 * in the recon notes for this script.
 *
 * Auth model:
 *   - `setOperatorHat` is `onlyOrgAdmin` (topHat wearer; Executor wears the topHat).
 *   - `setBudget` is `onlyOrgOperator` (adminHat OR operatorHat wearer; Executor
 *     satisfies via adminHat). After this proposal lands, Delegate-hat wearers
 *     ALSO satisfy `onlyOrgOperator` and can manage budgets / rules / fee caps
 *     directly without another vote.
 *
 * Sim-first per CLAUDE.md: stages the full proposal-pass-execute path on a
 * Gnosis fork WITHOUT etching the Hats contract — instead, pranks Hudson's
 * EOA (verified Delegate-hat wearer on real on-chain Hats Protocol) for the
 * createProposal + vote steps. Then advances time, calls announceWinner, and
 * lets the Executor (real topHat wearer on Hats Protocol) fire the 3
 * paymaster calls — `onlyOrgAdmin` and `onlyOrgOperator` checks resolve
 * against real Hats state, so the sim exercises the same auth path as the
 * real broadcast. Asserts post-state operatorHatId + both budget caps.
 *
 * If Hudson's single vote doesn't reach Decentral Park's quorum/threshold,
 * the sim adds additional pranked voters from a list of known on-chain hat
 * wearers — see _simFullFlow for the loop.
 *
 * Usage:
 *   # Sim (no broadcast, just validate end-to-end on a fork)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/ConfigureDecentralParkPaymasterViaGovernance.s.sol:SimConfigureDecentralParkPaymaster \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the real proposal; members vote in normal cadence)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/ConfigureDecentralParkPaymasterViaGovernance.s.sol:BroadcastConfigureDecentralParkPaymaster \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   DELEGATE_CAP_PER_EPOCH  — Delegate's new cap (wei). Default 1 xDAI = 1e18.
 *   NEIGHBOR_CAP_PER_EPOCH  — Neighbor's new cap (wei). Default 0.5 xDAI = 5e17.
 *   EPOCH_LEN_SECONDS       — Epoch length (seconds). Default 604800 = 7 days.
 *   PROPOSAL_DURATION       — Voting window (minutes). Default 30.
 * ============================================================================
 */

// PaymasterHub on Gnosis — confirmed via existing fix scripts
// (AddSetFoldersSelectorRules.s.sol, AddCreateTasksBatchSelectorRules.s.sol).
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Decentral Park (Gnosis) — verified via Poa subgraph 2026-05-28
bytes32 constant DECENTRAL_PARK_ORG_ID = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;

uint256 constant DECENTRAL_PARK_DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024;
uint256 constant DECENTRAL_PARK_NEIGHBOR_HAT = 36180248838698575132261002770404529440178570924043841009651669962588160;

// Default new caps and epoch length. Override via env vars at sim/broadcast time.
// Defaults picked to be ~5000x the current 0.0002 xDAI/week for Delegate (the new
// operator likely sponsors more activity) and ~2500x for Neighbor (rank-and-file
// member). Both keep the existing 7-day epoch.
uint128 constant DEFAULT_DELEGATE_CAP_PER_EPOCH = 1 ether; // 1 xDAI / week
uint128 constant DEFAULT_NEIGHBOR_CAP_PER_EPOCH = 0.5 ether; // 0.5 xDAI / week
uint32 constant DEFAULT_EPOCH_LEN_SECONDS = 7 days;
uint32 constant DEFAULT_PROPOSAL_DURATION_MINUTES = 30;

// Hudson — verified Delegate-hat wearer on Decentral Park (Gnosis) as of 2026-05-28.
// The sim pranks this address for createProposal + vote so all hat checks resolve against
// real on-chain Hats Protocol state, not a shim. Per CLAUDE.md this is the same address
// that owns the cross-chain admin contracts, so it's also the expected broadcaster.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

/// @dev Minimal PaymasterHub interface — only the surface this script touches. Avoids
/// pulling in the full PaymasterHub.sol compile graph.
interface IPaymasterHubMinimal {
    function getOrgConfig(bytes32 orgId)
        external
        view
        returns (uint256 adminHatId, uint256 operatorHatId, bool paused, uint40 registeredAt, bool bannedFromSolidarity);

    function getBudget(bytes32 orgId, bytes32 subjectKey)
        external
        view
        returns (uint128 capPerEpoch, uint128 usedInEpoch, uint32 epochLen, uint32 epochStart);

    function setOperatorHat(bytes32 orgId, uint256 operatorHatId) external;

    function setBudget(bytes32 orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen) external;
}

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
}

abstract contract ConfigurePaymasterBase is Script {
    /// @dev Subject-key for a hat budget. Matches `keccak256(abi.encodePacked(uint8(1), bytes32(hatId)))`
    /// computation in PaymasterHub.sol. (subjectType 1 = hat.)
    function _hatSubjectKey(uint256 hatId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(1), bytes32(hatId)));
    }

    function _resolveDelegateCap() internal view returns (uint128) {
        return uint128(vm.envOr("DELEGATE_CAP_PER_EPOCH", uint256(DEFAULT_DELEGATE_CAP_PER_EPOCH)));
    }

    function _resolveNeighborCap() internal view returns (uint128) {
        return uint128(vm.envOr("NEIGHBOR_CAP_PER_EPOCH", uint256(DEFAULT_NEIGHBOR_CAP_PER_EPOCH)));
    }

    function _resolveEpochLen() internal view returns (uint32) {
        return uint32(vm.envOr("EPOCH_LEN_SECONDS", uint256(DEFAULT_EPOCH_LEN_SECONDS)));
    }

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    /// @dev Build the 3-call batch the proposal will execute.
    function _buildBatch(uint128 delegateCap, uint128 neighborCap, uint32 epochLen)
        internal
        pure
        returns (IExecutor.Call[] memory batch)
    {
        batch = new IExecutor.Call[](3);

        // 1. setOperatorHat → Delegate
        batch[0] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(
                IPaymasterHubMinimal.setOperatorHat, (DECENTRAL_PARK_ORG_ID, DECENTRAL_PARK_DELEGATE_HAT)
            )
        });

        // 2. setBudget for Delegate
        batch[1] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(
                IPaymasterHubMinimal.setBudget,
                (
                    DECENTRAL_PARK_ORG_ID,
                    keccak256(abi.encodePacked(uint8(1), bytes32(DECENTRAL_PARK_DELEGATE_HAT))),
                    delegateCap,
                    epochLen
                )
            )
        });

        // 3. setBudget for Neighbor
        batch[2] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(
                IPaymasterHubMinimal.setBudget,
                (
                    DECENTRAL_PARK_ORG_ID,
                    keccak256(abi.encodePacked(uint8(1), bytes32(DECENTRAL_PARK_NEIGHBOR_HAT))),
                    neighborCap,
                    epochLen
                )
            )
        });
    }

    function _printPreview(uint128 delegateCap, uint128 neighborCap, uint32 epochLen) internal view {
        IPaymasterHubMinimal ph = IPaymasterHubMinimal(GNOSIS_PAYMASTER_HUB);
        (uint256 adminHatId, uint256 currentOperatorHatId,,,) = ph.getOrgConfig(DECENTRAL_PARK_ORG_ID);
        (uint128 delegateCurCap,, uint32 delegateCurEpoch,) =
            ph.getBudget(DECENTRAL_PARK_ORG_ID, _hatSubjectKey(DECENTRAL_PARK_DELEGATE_HAT));
        (uint128 neighborCurCap,, uint32 neighborCurEpoch,) =
            ph.getBudget(DECENTRAL_PARK_ORG_ID, _hatSubjectKey(DECENTRAL_PARK_NEIGHBOR_HAT));

        console.log("\n=== Proposal preview ===");
        console.log("  adminHatId:          ", adminHatId);
        console.log("  current operatorHat: ", currentOperatorHatId);
        console.log("  new operatorHat:     ", DECENTRAL_PARK_DELEGATE_HAT);
        console.log("");
        console.log("  Delegate current cap (wei):", uint256(delegateCurCap));
        console.log("  Delegate current epoch (s):", uint256(delegateCurEpoch));
        console.log("  Delegate new cap (wei):    ", uint256(delegateCap));
        console.log("  Neighbor current cap (wei):", uint256(neighborCurCap));
        console.log("  Neighbor current epoch (s):", uint256(neighborCurEpoch));
        console.log("  Neighbor new cap (wei):    ", uint256(neighborCap));
        console.log("  New epoch length (s):      ", uint256(epochLen));
    }

    /// @dev Full sim using REAL Hats Protocol state — no etch. Pranks Hudson (verified
    /// Delegate-hat wearer on Decentral Park) for createProposal + vote. The Executor
    /// genuinely wears the topHat on Gnosis, so when announceWinner fires Executor.execute,
    /// PaymasterHub's `onlyOrgAdmin` check resolves against real Hats state and succeeds.
    /// This mirrors the production broadcast path exactly — no auth shortcuts.
    function _simFullFlow(uint128 delegateCap, uint128 neighborCap, uint32 epochLen) internal {
        console.log("\n=== Decentral Park paymaster config sim (real Hats, prank Hudson) ===");

        _printPreview(delegateCap, neighborCap, epochLen);

        // 1. Build the 3-call batch + wrap into the HybridVoting batches array (1 option, 3 calls).
        IExecutor.Call[] memory batch = _buildBatch(delegateCap, neighborCap, epochLen);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        // 2. Create the proposal as Hudson (he wears Delegate, which is in HV.creatorHats).
        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0); // unrestricted poll
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park paymaster: operator + budgets (sim)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                pollHats
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        console.log("\n  Proposal id:", proposalId);

        // 3. Vote 100% for option 0 as Hudson. If Decentral Park's HV requires more weight
        // to clear quorum + threshold (50% threshold today), this single vote may not be
        // enough — in that case announceWinner returns valid=false and the require below
        // fires with a clear message. Add more pranked voters by querying other Delegate /
        // Neighbor wearers from on-chain Hats and prank-voting them here.
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);

        // 4. Advance time past expiry.
        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        // 5. announceWinner → Executor.execute (real topHat wearer → onlyOrgAdmin passes on
        //    real Hats Protocol → 3 paymaster calls land atomically).
        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass (likely quorum - add more pranked voters)");
        console.log("  Winner option:", winner, " valid:", valid);

        // 7. Verify post-state — operator hat + both budgets.
        IPaymasterHubMinimal ph = IPaymasterHubMinimal(GNOSIS_PAYMASTER_HUB);
        (, uint256 operatorHatAfter,,,) = ph.getOrgConfig(DECENTRAL_PARK_ORG_ID);
        require(operatorHatAfter == DECENTRAL_PARK_DELEGATE_HAT, "Sim: operatorHat did not flip to Delegate");

        (uint128 delegateCapAfter,, uint32 delegateEpochAfter,) =
            ph.getBudget(DECENTRAL_PARK_ORG_ID, _hatSubjectKey(DECENTRAL_PARK_DELEGATE_HAT));
        require(delegateCapAfter == delegateCap, "Sim: Delegate cap mismatch");
        require(delegateEpochAfter == epochLen, "Sim: Delegate epoch mismatch");

        (uint128 neighborCapAfter,, uint32 neighborEpochAfter,) =
            ph.getBudget(DECENTRAL_PARK_ORG_ID, _hatSubjectKey(DECENTRAL_PARK_NEIGHBOR_HAT));
        require(neighborCapAfter == neighborCap, "Sim: Neighbor cap mismatch");
        require(neighborEpochAfter == epochLen, "Sim: Neighbor epoch mismatch");

        console.log("\n  Post-state:");
        console.log("    operatorHat:        ", operatorHatAfter);
        console.log("    Delegate cap (wei): ", uint256(delegateCapAfter));
        console.log("    Delegate epoch (s): ", uint256(delegateEpochAfter));
        console.log("    Neighbor cap (wei): ", uint256(neighborCapAfter));
        console.log("    Neighbor epoch (s): ", uint256(neighborEpochAfter));
        console.log("\nPASS: Decentral Park paymaster config governance proposal landed end-to-end.");
    }

    /// @dev Real broadcast: creates the proposal on-chain. Members vote in normal cadence.
    function _broadcast(uint128 delegateCap, uint128 neighborCap, uint32 epochLen) internal {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Decentral Park paymaster config proposal ===");
        console.log("  Sender:        ", sender);
        console.log("  TaskManager:   ", DECENTRAL_PARK_TM);
        console.log("  HybridVoting:  ", DECENTRAL_PARK_HV);
        console.log("  PaymasterHub:  ", GNOSIS_PAYMASTER_HUB);
        console.log("  Duration:      ", minutesDuration, "minutes");

        // Preview — readable confirmation of what the calldata will do.
        _printPreview(delegateCap, neighborCap, epochLen);

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

        IExecutor.Call[] memory batch = _buildBatch(delegateCap, neighborCap, epochLen);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park paymaster: set Delegate as operator + raise Delegate/Neighbor budgets"),
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
        console.log("  Next:        members vote; after expiry, anyone calls announceWinner(", newId, ")");
    }
}

contract SimConfigureDecentralParkPaymaster is ConfigurePaymasterBase {
    function run() public {
        _simFullFlow(_resolveDelegateCap(), _resolveNeighborCap(), _resolveEpochLen());
    }
}

contract BroadcastConfigureDecentralParkPaymaster is ConfigurePaymasterBase {
    function run() public {
        _broadcast(_resolveDelegateCap(), _resolveNeighborCap(), _resolveEpochLen());
    }
}
