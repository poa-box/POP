// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Grant v4 permissions to recommended roles, via real governance proposals
 * ============================================================================
 *
 * Option B from the post-v4 rollout plan. For each live org, prepare a
 * governance proposal that grants the new TaskManager v4 powers
 * (TaskPerm.BUDGET + organizer-hat slot) to the recommended role:
 *
 *   KUBI  (Gnosis)   — Executive hat
 *   Test6 (Gnosis)   — Executive hat
 *   Poa   (Arbitrum) — CONTRIBUTOR hat
 *
 * This file is sim-first: it stages the FULL proposal-pass-execute path on a
 * forked chain (apply v4, etch a permissive Hats stub for a test voter,
 * createProposal, vote, advance time, announceWinner -> executor.execute
 * landing setConfig on TaskManager) and asserts the post-state. Once these
 * sims pass under FOUNDRY_PROFILE=production, the real flow is:
 *   1. v4 broadcast (UpgradeTaskManagerFolders Step 1/2/3) lands.
 *   2. A creator-hat-wearing member of each org submits the same proposal
 *      via the Poa-frontend `/votes` page (or directly via HybridVoting.
 *      createProposal). The frontend's "Propose change" flow on the
 *      organizer admin panel does this with the right calldata pre-filled.
 *   3. Org members vote per their normal cadence.
 *   4. Once the threshold is hit and `announceWinner` is called, the
 *      executor lands both setConfig calls atomically.
 *
 * Strategy notes (for the sim):
 *   - PermissiveHatsShim is etched over the org's Hats Protocol address. It
 *     grants a single designated EOA (`GODMODE`) all hats — sufficient for
 *     `onlyCreator` (createProposal) and class-hat (vote) checks. Other
 *     callers continue to get balance=0, so we don't accidentally pass
 *     unrelated checks for unrelated addresses.
 *   - We vote 100% for option 0 (only option) under a 10-minute duration.
 *     KUBI/Poa have quorum=0; Test6 has quorum=1 and we satisfy it with our
 *     single voter. Each org's threshold (35/25/50) is trivially met since
 *     100% > all of them.
 *   - The TaskManager beacon is upgraded BEFORE the proposal is created so
 *     the new `_requireExecutor` on `ORGANIZER_HAT_ALLOWED` (closes a merge
 *     gap in PR #159) and the new event emissions are exercised.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script script/fixes/GrantV4PermsViaGovernance.s.sol:SimGrantKubi   --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script script/fixes/GrantV4PermsViaGovernance.s.sol:SimGrantTest6  --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script script/fixes/GrantV4PermsViaGovernance.s.sol:SimGrantPoa    --fork-url arbitrum -vvv
 * ============================================================================
 */

address constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
address constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
string constant VERSION = "v4";

// ─── Org-specific addresses (resolved via subgraph) ──────────────────────────
// KUBI (Gnosis)
address constant KUBI_TM = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
address constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;
uint256 constant KUBI_EXEC_HAT = 29089782865237956770482606498400312925615312744021346470950225330569216; // Executive

// Test6 (Gnosis)
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
uint256 constant TEST6_EXEC_HAT = 29035862971903655490893272468226273664268038455176265325988018110070784; // Executive

// Poa (Arbitrum)
address constant POA_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
address constant POA_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;
uint256 constant POA_CONTRIBUTOR_HAT = 2507275451433703034676316303362792870832296009812444360026529659355136; // CONTRIBUTOR

// ─── Storage slot for rolePermGlobal in TaskManager.Layout (offset 6) ────────
// Same layout reference as script/audit/AuditTaskPermBit5.s.sol.
bytes32 constant TM_STORAGE_SLOT = keccak256("poa.taskmanager.storage");
uint256 constant ROLE_PERM_GLOBAL_OFFSET = 6;

/// @dev Permissive Hats stand-in: returns 1 for a single configured "godmode"
/// EOA on every hat queried. Used during the sim only — etched over the org's
/// real Hats Protocol address. Configure via vm.store(addr, slot=0, godmode).
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

abstract contract GrantBase is Script {
    /// @dev Apply v4 upgrade to the PoaManager beacon for TaskManager. Done
    /// before the proposal so the new ORGANIZER_HAT_ALLOWED branch + the
    /// RolePermSet event exist on the impl that the proposal will hit.
    function _applyV4Upgrade(PoaManager pm) internal {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("TaskManager", VERSION);
        address predicted = dd.computeAddress(salt);

        address deployed;
        if (predicted.code.length == 0) {
            vm.prank(DeterministicDeployer(DD).owner());
            deployed = dd.deploy(salt, type(TaskManager).creationCode);
        } else {
            deployed = predicted;
        }
        require(deployed == predicted, "v4 DD address mismatch");

        vm.prank(pm.owner());
        pm.upgradeBeacon("TaskManager", deployed, VERSION);
        require(
            pm.getCurrentImplementationById(keccak256("TaskManager")) == deployed, "v4 beacon upgrade did not stick"
        );
        console.log("  v4 impl swapped to:", deployed);
    }

    /// @dev Read the org's Hats contract from the TaskManager via lens key 3,
    /// then etch the permissive shim over it and configure godmode.
    function _etchHats(address taskManager, address godmode) internal returns (address hatsAddr) {
        hatsAddr = abi.decode(TaskManager(taskManager).getLensData(3, ""), (address));
        PermissiveHatsShim impl = new PermissiveHatsShim();
        vm.etch(hatsAddr, address(impl).code);
        vm.store(hatsAddr, bytes32(uint256(0)), bytes32(uint256(uint160(godmode))));
        console.log("  HatsShim etched at:", hatsAddr);
        console.log("  Godmode voter:    ", godmode);
    }

    /// @dev Read the current global mask for a hat directly from
    /// TaskManager.Layout.rolePermGlobal storage (no public getter).
    function _readRolePermGlobal(address taskManager, uint256 hatId) internal view returns (uint8 mask) {
        bytes32 base = bytes32(uint256(TM_STORAGE_SLOT) + ROLE_PERM_GLOBAL_OFFSET);
        bytes32 slot = keccak256(abi.encode(hatId, base));
        mask = uint8(uint256(vm.load(taskManager, slot)));
    }

    function _organizerHatIds(address taskManager) internal view returns (uint256[] memory ids) {
        ids = abi.decode(TaskManager(taskManager).getLensData(11, ""), (uint256[]));
    }

    /// @dev Build the two-call batch the proposal will execute:
    ///   1) setConfig(ROLE_PERM, abi.encode(hatId, TaskPerm.BUDGET))
    ///   2) setConfig(ORGANIZER_HAT_ALLOWED, abi.encode(hatId, true))
    function _buildGrantBatch(address taskManager, uint256 hatId) internal pure returns (IExecutor.Call[] memory) {
        IExecutor.Call[] memory batch = new IExecutor.Call[](2);

        batch[0] = IExecutor.Call({
            target: taskManager,
            value: 0,
            data: abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ROLE_PERM, abi.encode(hatId, uint8(TaskPerm.BUDGET)))
            )
        });

        batch[1] = IExecutor.Call({
            target: taskManager,
            value: 0,
            data: abi.encodeCall(
                TaskManager.setConfig, (TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(hatId, true))
            )
        });

        return batch;
    }

    function _runFullFlow(
        string memory orgName,
        PoaManager pm,
        address taskManager,
        address hybridVoting,
        uint256 targetHat
    ) internal {
        console.log("\n=== Governance grant sim:", orgName, "===");

        // 1. Apply v4 upgrade (so the new setConfig branches exist).
        _applyV4Upgrade(pm);

        // 2. Etch permissive Hats over the org's Hats Protocol address.
        address voter = makeAddr("gov-sim-voter");
        _etchHats(taskManager, voter);

        // 3. Snapshot pre-state.
        uint8 maskBefore = _readRolePermGlobal(taskManager, targetHat);
        uint256[] memory orgsBefore = _organizerHatIds(taskManager);
        console.log("  Pre-state mask for target hat: ", maskBefore);
        console.log("  Pre-state organizer-hat count: ", orgsBefore.length);

        // 4. Build the grant batch.
        IExecutor.Call[] memory batch = _buildGrantBatch(taskManager, targetHat);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        // 5. Create the proposal (10-minute duration = MIN_DURATION).
        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0); // unrestricted poll
        vm.prank(voter);
        HybridVoting(hybridVoting)
            .createProposal(
                bytes(string.concat("Grant v4 perms - ", orgName)),
                bytes32(0),
                minutesDuration,
                1, // single option
                batches,
                pollHats
            );
        uint256 proposalId = HybridVoting(hybridVoting).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        // 6. Vote 100% for option 0.
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(voter);
        HybridVoting(hybridVoting).vote(proposalId, idxs, weights);
        console.log("  Voted 100% for option 0");

        // 7. Advance time past the proposal's end. MIN_DURATION = 10 minutes;
        //    add a small buffer to land strictly after `endTimestamp`.
        vm.warp(block.timestamp + minutesDuration * 60 + 10);

        // 8. Anyone can call announceWinner. Executor.execute fires inside
        //    if the option won, landing the setConfig calls.
        (uint256 winner, bool valid) = HybridVoting(hybridVoting).announceWinner(proposalId);
        require(valid, "Proposal did not pass");
        console.log("  Winner option:", winner, " valid:", valid);

        // 9. Verify post-state.
        uint8 maskAfter = _readRolePermGlobal(taskManager, targetHat);
        require(maskAfter & uint8(TaskPerm.BUDGET) != 0, "BUDGET bit not set after execute");
        console.log("  Post-state mask: ", maskAfter, " (BUDGET bit set OK)");

        uint256[] memory orgsAfter = _organizerHatIds(taskManager);
        bool foundOrg;
        for (uint256 i; i < orgsAfter.length; ++i) {
            if (orgsAfter[i] == targetHat) {
                foundOrg = true;
                break;
            }
        }
        require(foundOrg, "Target hat not in organizerHatIds after execute");
        console.log("  Post-state organizer-hat count:", orgsAfter.length, "(target hat present)");

        console.log("PASS:", orgName, "governance grant fully executed end-to-end.");
    }

    /// @dev Real broadcast variant — creates the grant proposal on-chain.
    /// Assumes v4 has already been broadcast (run UpgradeTaskManagerFolders
    /// Step1+Step2+Step3 first). Does NOT simulate voting; that's done by
    /// org members in the normal cadence after this proposal exists.
    /// @param durationMinutes Voting window in minutes. MIN=10, MAX=43200.
    function _runBroadcast(string memory orgName, address tm, address hv, uint256 targetHat, uint32 durationMinutes)
        internal
    {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);

        console.log("\n=== Broadcasting grant proposal:", orgName, "===");
        console.log("  Sender:        ", sender);
        console.log("  TaskManager:   ", tm);
        console.log("  HybridVoting:  ", hv);
        console.log("  Target hat:    ", targetHat);
        console.log("  Duration:      ", durationMinutes, "minutes");

        // Sanity: sender must wear a creator hat or createProposal reverts NotCreator.
        IHatsMinimal hats = IHatsMinimal(abi.decode(TaskManager(tm).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(hv).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on this voting contract");

        // Build the same two-call batch the sim validated end-to-end.
        IExecutor.Call[] memory batch = _buildGrantBatch(tm, targetHat);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(hv).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(hv)
            .createProposal(
                bytes(string.concat("Grant v4 perms - ", orgName)),
                bytes32(0),
                durationMinutes,
                1, // single option
                batches,
                new uint256[](0) // unrestricted — anyone with class hats can vote
            );
        vm.stopBroadcast();

        uint256 newId = HybridVoting(hv).proposalsCount() - 1;
        require(newId == idBefore, "Proposal not created");
        console.log("  Proposal ID:   ", newId);
        console.log("  Next:          members vote; after expiry, anyone calls announceWinner(", newId, ")");
    }
}

// Per-org durations. KUBI was broadcast at 4320 (3 days); kept at that value
// for the source-history record. Test6 + Poa are short-lived test/governance
// orgs so the proposals can run on a tighter cadence.
uint32 constant KUBI_DURATION_MINUTES = 4320; // 3 days
uint32 constant TEST6_DURATION_MINUTES = 30; // 30 minutes
uint32 constant POA_DURATION_MINUTES = 30; // 30 minutes

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
}

/* ───────────────────────── KUBI on Gnosis ───────────────────────── */

contract SimGrantKubi is GrantBase {
    function run() public {
        _runFullFlow("KUBI", PoaManager(GNOSIS_POA_MANAGER), KUBI_TM, KUBI_HV, KUBI_EXEC_HAT);
    }
}

contract BroadcastGrantKubi is GrantBase {
    function run() public {
        _runBroadcast("KUBI", KUBI_TM, KUBI_HV, KUBI_EXEC_HAT, KUBI_DURATION_MINUTES);
    }
}

/* ───────────────────────── Test6 on Gnosis ──────────────────────── */

contract SimGrantTest6 is GrantBase {
    function run() public {
        _runFullFlow("Test6", PoaManager(GNOSIS_POA_MANAGER), TEST6_TM, TEST6_HV, TEST6_EXEC_HAT);
    }
}

contract BroadcastGrantTest6 is GrantBase {
    function run() public {
        _runBroadcast("Test6", TEST6_TM, TEST6_HV, TEST6_EXEC_HAT, TEST6_DURATION_MINUTES);
    }
}

/* ───────────────────────── Poa on Arbitrum ──────────────────────── */

contract SimGrantPoa is GrantBase {
    function run() public {
        _runFullFlow("Poa", PoaManager(ARB_POA_MANAGER), POA_TM, POA_HV, POA_CONTRIBUTOR_HAT);
    }
}

contract BroadcastGrantPoa is GrantBase {
    function run() public {
        _runBroadcast("Poa", POA_TM, POA_HV, POA_CONTRIBUTOR_HAT, POA_DURATION_MINUTES);
    }
}
