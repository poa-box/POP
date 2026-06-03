// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Grant the Delegate hat FULL org permissions via HybridVoting governance
 * ============================================================================
 *
 * Target org: Decentral Park (Gnosis).
 *
 * Goal: make the "Delegate" role hat fully empowered to run the TaskManager —
 * create tasks, claim, review, assign, self-review, edit budgets, edit
 * metadata/payouts post-claim — plus organize the folder tree. Today the
 * Delegate hat's global TaskManager mask is only EDIT_FULL (0x80); it cannot
 * create or assign tasks at the org-wide level. This proposal sets the mask to
 * 0xFF (all 8 TaskPerm bits) and adds the Delegate hat as an organizer hat.
 *
 * The Delegate hat is ALREADY:
 *   - a TaskManager creator hat   -> can create projects
 *   - a HybridVoting creator hat  -> can create proposals
 * so those powers need no change. PaymentManager is Ownable (Executor-only) and
 * exposes no hat-grantable role, so treasury/distribution actions intentionally
 * remain governance-only and are out of scope for a hat grant.
 *
 * The batch (single proposal option, executed by the Executor on pass):
 *   1. setConfig(ROLE_PERM,             abi.encode(DELEGATE_HAT, 0xFF))
 *   2. setConfig(ORGANIZER_HAT_ALLOWED, abi.encode(DELEGATE_HAT, true))
 *
 * setConfig(ROLE_PERM, ...) REPLACES the mask (it does not OR-merge), but 0xFF
 * is a superset of every bit so nothing is lost.
 *
 * Sim-first per CLAUDE.md: stages the full create -> vote -> execute path on a
 * Gnosis fork (etch a permissive Hats shim so one test voter satisfies the
 * onlyCreator + class-hat checks) and asserts the post-state: Delegate mask is
 * exactly 0xFF and the Delegate hat is now present in the organizer-hat array.
 *
 * Usage:
 *   # Sim (no broadcast — validate end-to-end on a fork)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/GrantDelegateFullPermsViaGovernance.s.sol:SimGrantDelegateFullDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the real proposal; members vote in normal cadence)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/GrantDelegateFullPermsViaGovernance.s.sol:BroadcastGrantDelegateFullDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   GRANT_HAT_ID    — override the target hat (default = Decentral Park Delegate)
 *   GRANT_DURATION  — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// Decentral Park (Gnosis) — verified via Poa subgraph + on-chain reads 2026-05-31
// orgId 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78
// Roles: (top hat unnamed), ELIGIBILITY_ADMIN, Delegate, Neighbor, Agent.
// Delegate is the target: the requester wears it and it's already in
// HybridVoting.creatorHats(), so any Delegate/Neighbor wearer can broadcast.
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;
uint256 constant DECENTRAL_PARK_DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024;

// Full TaskManager permission mask: all 8 TaskPerm bits set.
// CREATE|CLAIM|REVIEW|ASSIGN|SELF_REVIEW|BUDGET|EDIT_META|EDIT_FULL == 0xFF.
uint8 constant FULL_PERM_MASK = 0xFF;

// Default voting window (minutes). HybridVoting MIN_DURATION = 10 (this is the minimum).
uint32 constant DEFAULT_DURATION_MINUTES = 10;

/// @dev Permissive Hats stand-in: returns 1 for a single configured "godmode" EOA on every
/// hat queried. Used during the sim only — etched over the org's real Hats Protocol address.
/// Configure via vm.store(addr, slot=0, godmode). Mirrors the helper in
/// GrantV5EditFullViaGovernance.s.sol.
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

abstract contract GrantDelegateFullBase is Script {
    /// @dev Read the current rolePermGlobal mask for a hat directly from TaskManager.Layout
    /// storage (no public getter). rolePermGlobal is at offset 6 from the namespaced base slot.
    function _readRolePermGlobal(address taskManager, uint256 hatId) internal view returns (uint8) {
        bytes32 base = bytes32(uint256(keccak256("poa.taskmanager.storage")) + 6);
        bytes32 slot = keccak256(abi.encode(hatId, base));
        return uint8(uint256(vm.load(taskManager, slot)));
    }

    /// @dev True if `hatId` is present in TaskManager's organizer-hat enumeration (lens 11).
    function _isOrganizerHat(address taskManager, uint256 hatId) internal view returns (bool) {
        uint256[] memory organizers = abi.decode(TaskManager(taskManager).getLensData(11, ""), (uint256[]));
        for (uint256 i; i < organizers.length; ++i) {
            if (organizers[i] == hatId) return true;
        }
        return false;
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

    /// @dev Build the 2-call batch: set the hat's global mask to FULL_PERM_MASK and register it
    /// as an organizer hat.
    function _buildBatch(address taskManager, uint256 hatId) internal pure returns (IExecutor.Call[] memory batch) {
        batch = new IExecutor.Call[](2);
        batch[0] = IExecutor.Call({
            target: taskManager,
            value: 0,
            data: abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ROLE_PERM, abi.encode(hatId, FULL_PERM_MASK))
            )
        });
        batch[1] = IExecutor.Call({
            target: taskManager,
            value: 0,
            data: abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(hatId, true))
            )
        });
    }

    function _resolveTargetHat(uint256 defaultHat) internal view returns (uint256) {
        return vm.envOr("GRANT_HAT_ID", defaultHat);
    }

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("GRANT_DURATION", uint256(DEFAULT_DURATION_MINUTES)));
    }

    function _printPreview(address taskManager, uint256 hatId, uint8 currentMask) internal view {
        console.log("  Target hat:          ", hatId);
        console.log("  Current ROLE_PERM:   ", currentMask);
        console.log(
            "  New ROLE_PERM:       ",
            FULL_PERM_MASK,
            "(CREATE|CLAIM|REVIEW|ASSIGN|SELF_REVIEW|BUDGET|EDIT_META|EDIT_FULL)"
        );
        console.log("  Currently organizer: ", _isOrganizerHat(taskManager, hatId));
        console.log("  Becomes organizer:    true");
    }

    /// @dev Full sim: etch Hats shim, create proposal, vote, advance time, announceWinner, assert.
    function _simFullFlow(string memory orgName, address taskManager, address hybridVoting, uint256 targetHat)
        internal
    {
        console.log("\n=== Delegate FULL-perm grant sim:", orgName, "===");
        console.log("  TaskManager:  ", taskManager);
        console.log("  HybridVoting: ", hybridVoting);

        // 1. Snapshot pre-state.
        uint8 currentMask = _readRolePermGlobal(taskManager, targetHat);
        _printPreview(taskManager, targetHat, currentMask);
        require(currentMask != FULL_PERM_MASK || !_isOrganizerHat(taskManager, targetHat), "Sim: proposal is a no-op");

        // 2. Etch permissive Hats over the org's Hats Protocol address so a single test voter
        //    can satisfy onlyCreator (createProposal) and class-hat (vote) checks.
        address voter = makeAddr("delegate-full-sim-voter");
        _etchHats(taskManager, voter);

        // 3. Build the batch.
        IExecutor.Call[] memory batch = _buildBatch(taskManager, targetHat);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        // 4. Create the proposal (MIN_DURATION = 10 minutes for sim speed).
        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0); // unrestricted poll
        vm.prank(voter);
        HybridVoting(hybridVoting)
            .createProposal(
                bytes(string.concat("Grant Delegate full org perms - ", orgName)),
                bytes32(0),
                minutesDuration,
                1, // single option
                batches,
                pollHats
            );
        uint256 proposalId = HybridVoting(hybridVoting).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        // 5. Vote 100% for option 0.
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(voter);
        HybridVoting(hybridVoting).vote(proposalId, idxs, weights);

        // 6. Advance time past the proposal's end + small buffer.
        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        // 7. Anyone can call announceWinner. Executor.execute fires inside if the option won.
        (uint256 winner, bool valid) = HybridVoting(hybridVoting).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass");
        console.log("  Winner option:", winner, " valid:", valid);

        // 8. Verify post-state.
        uint8 maskAfter = _readRolePermGlobal(taskManager, targetHat);
        require(maskAfter == FULL_PERM_MASK, "Sim: post-state mask is not 0xFF");
        require(_isOrganizerHat(taskManager, targetHat), "Sim: Delegate hat not added as organizer");
        console.log("  Post-state mask:", maskAfter, "(all 8 TaskPerm bits set)");
        console.log("  Post-state organizer:", _isOrganizerHat(taskManager, targetHat));
        console.log("PASS:", orgName, "Delegate full-perm governance grant executed end-to-end.");
    }

    /// @dev Real broadcast: creates the proposal on-chain. Members vote in normal cadence.
    function _broadcastProposal(string memory orgName, address taskManager, address hybridVoting, uint256 targetHat)
        internal
    {
        // Prefer PRIVATE_KEY; fall back to DEPLOYER_PRIVATE_KEY. Resolved lazily so setting only
        // PRIVATE_KEY does not trip an eager vm.envUint revert on a missing DEPLOYER_PRIVATE_KEY.
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Delegate full-perm grant proposal:", orgName, "===");
        console.log("  Sender:        ", sender);
        console.log("  TaskManager:   ", taskManager);
        console.log("  HybridVoting:  ", hybridVoting);
        console.log("  Duration:      ", minutesDuration, "minutes");

        // Sanity: sender must wear a creator hat or createProposal reverts.
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

        uint8 currentMask = _readRolePermGlobal(taskManager, targetHat);
        _printPreview(taskManager, targetHat, currentMask);
        require(
            currentMask != FULL_PERM_MASK || !_isOrganizerHat(taskManager, targetHat), "Broadcast: proposal is a no-op"
        );

        IExecutor.Call[] memory batch = _buildBatch(taskManager, targetHat);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(hybridVoting).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(hybridVoting)
            .createProposal(
                bytes(string.concat("Grant Delegate full org perms - ", orgName)),
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
        console.log("  Next: members vote; after expiry, anyone calls announceWinner(", newId, ")");
    }
}

/* ─────────────────── Decentral Park on Gnosis ────────────────────── */

contract SimGrantDelegateFullDecentralPark is GrantDelegateFullBase {
    function run() public {
        _simFullFlow(
            "Decentral Park", DECENTRAL_PARK_TM, DECENTRAL_PARK_HV, _resolveTargetHat(DECENTRAL_PARK_DELEGATE_HAT)
        );
    }
}

contract BroadcastGrantDelegateFullDecentralPark is GrantDelegateFullBase {
    function run() public {
        _broadcastProposal(
            "Decentral Park", DECENTRAL_PARK_TM, DECENTRAL_PARK_HV, _resolveTargetHat(DECENTRAL_PARK_DELEGATE_HAT)
        );
    }
}
