// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Grant v5 EDIT_FULL via real HybridVoting governance — Test6 + Decentral Park
 * ============================================================================
 *
 * TaskManager v5 added two new TaskPerm bits — EDIT_META (1 << 6) and EDIT_FULL
 * (1 << 7) — letting holders edit a task post-claim. This script creates a
 * single-call governance proposal on a target org that sets a chosen hat's
 * global rolePermGlobal mask to (current | EDIT_FULL), giving wearers org-wide
 * post-claim editing power across every project.
 *
 * Two orgs wired today (Sim + Broadcast contracts per org):
 *   - Test6 (Gnosis)          → Executive hat (default)
 *   - Decentral Park (Gnosis) → Delegate hat (default)
 *
 * Read-modify-write is mandatory: setConfig(ROLE_PERM, ...) REPLACES the mask
 * (it does not OR-merge). Overwriting with just EDIT_FULL would silently strip
 * any existing bits — Test6 EXEC currently has BUDGET (set by the v4 grant);
 * this script preserves it.
 *
 * Race-condition note: the proposal's calldata is fixed at create-time. If
 * another proposal mutates the mask between create and execute, this proposal
 * will overwrite that change. For Test6 (a test org) the risk is acceptable.
 * For production orgs, re-read the mask immediately before broadcast and
 * rebuild the proposal if drift is detected.
 *
 * Sim-first per CLAUDE.md: stages the proposal-pass-execute path on a Gnosis
 * fork (etch permissive Hats shim, createProposal, vote, advance time,
 * announceWinner -> executor.execute -> setConfig lands on TaskManager) and
 * asserts the post-state mask has the EDIT_FULL bit set AND the pre-existing
 * bits preserved.
 *
 * Usage (replace `Test6` with `DecentralPark` to target that org instead):
 *   # Sim (no broadcast, just validate end-to-end on a fork)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/GrantV5EditFullViaGovernance.s.sol:SimGrantEditFullTest6 \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the real proposal; members vote in normal cadence)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/GrantV5EditFullViaGovernance.s.sol:BroadcastGrantEditFullTest6 \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   GRANT_HAT_ID    — override the target hat (default = each org's own constant)
 *   GRANT_DURATION  — voting window in minutes (default 30)
 * ============================================================================
 */

// Test6 (Gnosis) — verified via Poa subgraph 2026-05-27
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
uint256 constant TEST6_EXEC_HAT = 29035862971903655490893272468226273664268038455176265325988018110070784;

// Decentral Park (Gnosis) — verified via Poa subgraph 2026-05-28
// orgId 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78
// Roles: (top hat unnamed), ELIGIBILITY_ADMIN, Delegate, Neighbor — Delegate is the default
// target since the requester wears it and it's already in HybridVoting.creatorHats().
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;
uint256 constant DECENTRAL_PARK_DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024;
// Other Decentral Park hats (for env override via GRANT_HAT_ID):
//   Neighbor          = 36180248838698575132261002770404529440178570924043841009651669962588160
//   ELIGIBILITY_ADMIN = 36180248838692297934744644785522640003358674060733414678036010791600128
//   Top hat (unnamed) = 36180248427316158604443134246780344364021047815049448269641044954447872

// Default voting window (minutes). HybridVoting MIN_DURATION = 10.
uint32 constant DEFAULT_DURATION_MINUTES = 30;

// Storage slot for rolePermGlobal in TaskManager.Layout (offset 6 from base).
// See AuditTaskPermBit5.s.sol / GrantV4PermsViaGovernance.s.sol for the reference.
bytes32 constant TM_STORAGE_SLOT = keccak256("poa.taskmanager.storage");
uint256 constant ROLE_PERM_GLOBAL_OFFSET = 6;

/// @dev Permissive Hats stand-in: returns 1 for a single configured "godmode" EOA on every
/// hat queried. Used during the sim only — etched over the org's real Hats Protocol address.
/// Configure via vm.store(addr, slot=0, godmode). Mirrors the helper in
/// GrantV4PermsViaGovernance.s.sol.
contract PermissiveHatsShim {
    function balanceOf(
        address user,
        uint256 /*hatId*/
    )
        external
        view
        returns (uint256)
    {
        address g;
        assembly {
            g := sload(0)
        }
        return user == g ? 1 : 0;
    }

    function balanceOfBatch(address[] calldata users, uint256[] calldata hatIds)
        external
        view
        returns (uint256[] memory bal)
    {
        require(users.length == hatIds.length, "len mismatch");
        address g;
        assembly {
            g := sload(0)
        }
        bal = new uint256[](users.length);
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == g) bal[i] = 1;
        }
    }

    function isWearerOfHat(
        address user,
        uint256 /*hatId*/
    )
        external
        view
        returns (bool)
    {
        address g;
        assembly {
            g := sload(0)
        }
        return user == g;
    }
}

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
}

abstract contract GrantEditFullBase is Script {
    /// @dev Read the current rolePermGlobal mask for a hat directly from TaskManager.Layout
    /// storage (no public getter).
    function _readRolePermGlobal(address taskManager, uint256 hatId) internal view returns (uint8) {
        bytes32 base = bytes32(uint256(TM_STORAGE_SLOT) + ROLE_PERM_GLOBAL_OFFSET);
        bytes32 slot = keccak256(abi.encode(hatId, base));
        return uint8(uint256(vm.load(taskManager, slot)));
    }

    /// @dev Etch the permissive shim over the org's Hats contract and configure `voter` as godmode.
    function _etchHats(address taskManager, address voter) internal returns (address hatsAddr) {
        hatsAddr = abi.decode(TaskManager(taskManager).getLensData(3, ""), (address));
        PermissiveHatsShim impl = new PermissiveHatsShim();
        vm.etch(hatsAddr, address(impl).code);
        vm.store(hatsAddr, bytes32(uint256(0)), bytes32(uint256(uint160(voter))));
        console.log("  HatsShim etched at:", hatsAddr);
        console.log("  Godmode voter:    ", voter);
    }

    /// @dev Build the single-call batch the proposal will execute: setConfig(ROLE_PERM, ...) with
    /// the new combined mask. Reads current mask and OR's EDIT_FULL in to preserve existing bits.
    function _buildBatch(address taskManager, uint256 hatId)
        internal
        view
        returns (IExecutor.Call[] memory batch, uint8 currentMask, uint8 newMask)
    {
        currentMask = _readRolePermGlobal(taskManager, hatId);
        newMask = currentMask | TaskPerm.EDIT_FULL;

        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: taskManager,
            value: 0,
            data: abi.encodeCall(TaskManager.setConfig, (TaskManager.ConfigKey.ROLE_PERM, abi.encode(hatId, newMask)))
        });
    }

    /// @dev Per-org default hat; override via GRANT_HAT_ID env var (e.g. to target a
    /// different role in the same org).
    function _resolveTargetHat(uint256 defaultHat) internal view returns (uint256) {
        return vm.envOr("GRANT_HAT_ID", defaultHat);
    }

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("GRANT_DURATION", uint256(DEFAULT_DURATION_MINUTES)));
    }

    function _printGrantPreview(uint8 currentMask, uint8 newMask) internal pure {
        console.log("  Current mask:", currentMask);
        console.log("  New mask:    ", newMask);
        console.log("  Bits added:  EDIT_FULL (bit 7)");
        if (currentMask != 0) {
            console.log("  Preserved bits in current mask:");
            if (currentMask & TaskPerm.CREATE != 0) console.log("    - CREATE");
            if (currentMask & TaskPerm.CLAIM != 0) console.log("    - CLAIM");
            if (currentMask & TaskPerm.REVIEW != 0) console.log("    - REVIEW");
            if (currentMask & TaskPerm.ASSIGN != 0) console.log("    - ASSIGN");
            if (currentMask & TaskPerm.SELF_REVIEW != 0) console.log("    - SELF_REVIEW");
            if (currentMask & TaskPerm.BUDGET != 0) console.log("    - BUDGET");
            if (currentMask & TaskPerm.EDIT_META != 0) console.log("    - EDIT_META");
            if (currentMask & TaskPerm.EDIT_FULL != 0) console.log("    - EDIT_FULL (already set; proposal is no-op)");
        }
    }

    /// @dev Full sim: etch Hats shim, create proposal, vote, advance time, announceWinner,
    /// assert post-state. Mirrors GrantV4PermsViaGovernance.s.sol's `_runFullFlow`.
    function _simFullFlow(string memory orgName, address taskManager, address hybridVoting, uint256 targetHat)
        internal
    {
        console.log("\n=== EDIT_FULL grant sim:", orgName, "===");
        console.log("  TaskManager:  ", taskManager);
        console.log("  HybridVoting: ", hybridVoting);
        console.log("  Target hat:   ", targetHat);

        // 1. Etch permissive Hats over the org's Hats Protocol address so a single test voter
        //    can satisfy onlyCreator (createProposal) and class-hat (vote) checks.
        address voter = makeAddr("v5-grant-sim-voter");
        _etchHats(taskManager, voter);

        // 2. Snapshot pre-state and build the proposal batch.
        (IExecutor.Call[] memory batch, uint8 currentMask, uint8 newMask) = _buildBatch(taskManager, targetHat);
        require(newMask != currentMask, "Sim: proposal is a no-op (EDIT_FULL already set)");
        _printGrantPreview(currentMask, newMask);

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        // 3. Create the proposal (use MIN_DURATION = 10 minutes for sim speed).
        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0); // unrestricted poll
        vm.prank(voter);
        HybridVoting(hybridVoting)
            .createProposal(
                bytes(string.concat("Grant v5 EDIT_FULL - ", orgName)),
                bytes32(0),
                minutesDuration,
                1, // single option
                batches,
                pollHats
            );
        uint256 proposalId = HybridVoting(hybridVoting).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        // 4. Vote 100% for option 0.
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(voter);
        HybridVoting(hybridVoting).vote(proposalId, idxs, weights);

        // 5. Advance time past the proposal's end + small buffer.
        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        // 6. Anyone can call announceWinner. Executor.execute fires inside if the option won.
        (uint256 winner, bool valid) = HybridVoting(hybridVoting).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass");
        console.log("  Winner option:", winner, " valid:", valid);

        // 7. Verify post-state: mask matches newMask exactly (BUDGET preserved, EDIT_FULL added).
        uint8 maskAfter = _readRolePermGlobal(taskManager, targetHat);
        require(maskAfter == newMask, "Sim: post-state mask mismatch");
        require(maskAfter & TaskPerm.EDIT_FULL != 0, "Sim: EDIT_FULL bit not set");
        if (currentMask & TaskPerm.BUDGET != 0) {
            require(maskAfter & TaskPerm.BUDGET != 0, "Sim: BUDGET bit lost (read-modify-write failed)");
        }
        console.log("  Post-state mask:", maskAfter, "(EDIT_FULL set, prior bits preserved)");

        console.log("PASS:", orgName, "EDIT_FULL governance grant fully executed end-to-end.");
    }

    /// @dev Real broadcast: creates the proposal on-chain. Members vote in normal cadence.
    function _broadcastProposal(string memory orgName, address taskManager, address hybridVoting, uint256 targetHat)
        internal
    {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting EDIT_FULL grant proposal:", orgName, "===");
        console.log("  Sender:        ", sender);
        console.log("  TaskManager:   ", taskManager);
        console.log("  HybridVoting:  ", hybridVoting);
        console.log("  Target hat:    ", targetHat);
        console.log("  Duration:      ", minutesDuration, "minutes");

        // Sanity: sender must wear a creator hat or createProposal reverts NotCreator.
        IHatsMinimal hats = IHatsMinimal(abi.decode(TaskManager(taskManager).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(hybridVoting).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on this voting contract");

        // Build the batch and preview the change so the broadcaster can sanity-check before the
        // tx lands.
        (IExecutor.Call[] memory batch, uint8 currentMask, uint8 newMask) = _buildBatch(taskManager, targetHat);
        require(newMask != currentMask, "Broadcast: proposal is a no-op (EDIT_FULL already set on target hat)");
        _printGrantPreview(currentMask, newMask);

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(hybridVoting).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(hybridVoting)
            .createProposal(
                bytes(string.concat("Grant v5 EDIT_FULL - ", orgName)),
                bytes32(0),
                minutesDuration,
                1, // single option
                batches,
                new uint256[](0) // unrestricted — any class-hat wearer can vote
            );
        vm.stopBroadcast();

        uint256 newId = HybridVoting(hybridVoting).proposalsCount() - 1;
        require(newId == idBefore, "Proposal not created");
        console.log("\n  Proposal ID:", newId);
        console.log("  Next:        members vote; after expiry, anyone calls announceWinner(", newId, ")");
    }
}

/* ───────────────────────── Test6 on Gnosis ──────────────────────── */

contract SimGrantEditFullTest6 is GrantEditFullBase {
    function run() public {
        _simFullFlow("Test6", TEST6_TM, TEST6_HV, _resolveTargetHat(TEST6_EXEC_HAT));
    }
}

contract BroadcastGrantEditFullTest6 is GrantEditFullBase {
    function run() public {
        _broadcastProposal("Test6", TEST6_TM, TEST6_HV, _resolveTargetHat(TEST6_EXEC_HAT));
    }
}

/* ─────────────────── Decentral Park on Gnosis ────────────────────── */
// Default target = Delegate hat. Decentral Park's HybridVoting.creatorHats() includes
// both Delegate and Neighbor, so any wearer of either can broadcast the proposal.

contract SimGrantEditFullDecentralPark is GrantEditFullBase {
    function run() public {
        _simFullFlow(
            "Decentral Park", DECENTRAL_PARK_TM, DECENTRAL_PARK_HV, _resolveTargetHat(DECENTRAL_PARK_DELEGATE_HAT)
        );
    }
}

contract BroadcastGrantEditFullDecentralPark is GrantEditFullBase {
    function run() public {
        _broadcastProposal(
            "Decentral Park", DECENTRAL_PARK_TM, DECENTRAL_PARK_HV, _resolveTargetHat(DECENTRAL_PARK_DELEGATE_HAT)
        );
    }
}
