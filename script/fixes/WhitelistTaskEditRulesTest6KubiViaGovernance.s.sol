// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Test6 + KUBI (Gnosis) — whitelist the TaskManager EDIT-task functions in the
 * PaymasterHub via governance, and cast the creator's vote in the same script
 * ============================================================================
 *
 * Same fix as WhitelistTaskEditRulesDecentralParkViaGovernance, for Test6 and
 * KUBI. PaymasterHub only sponsors (orgId, target, selector) calls whose Rule
 * is allowed=true. Both orgs already have the creation selectors (createTask /
 * createTasksBatch, the latter via PR #155) but NOT the two edit selectors:
 *
 *   updateTask(uint256,uint256,bytes,bytes32,address,uint256)  0x48db6f65
 *   updateTaskMetadata(uint256,bytes,bytes32)                  0x26fa4e70
 *
 * Verified allowed=false for both orgs on Gnosis 2026-06-02 via getRule.
 *
 * Each org gets a single governance proposal whose one call the org's Executor
 * runs on execution:
 *   paymaster.setRulesBatch(orgId, [TM, TM], [updateTask, updateTaskMetadata],
 *                           [true, true], [0, 0])
 * Auth: setRulesBatch is `onlyOrgOperator`, satisfied by the org's adminHat
 * wearer (the Executor) when announceWinner fires Executor.execute.
 *
 * Unlike the other governance scripts, the BROADCAST here also CASTS THE VOTE
 * (option 0, 100%) right after creating the proposal — the broadcaster wears a
 * creator hat on both HVs (verified). Whether that single vote is enough to
 * pass is org-specific (Test6: 25% threshold / quorum 1; KUBI: 35% / quorum 0)
 * and is proven by the sim's announceWinner assertion below. If a sim reports
 * "did not pass", the org needs more voters than just the broadcaster.
 *
 * Sim-first per CLAUDE.md: stages create -> vote -> warp -> execute on a Gnosis
 * fork with REAL Hats (prank Hudson, a verified creator-hat wearer on both HVs);
 * the real Executor satisfies onlyOrgOperator on execution. Asserts both
 * selectors flip allowed=false -> true.
 *
 * Usage:
 *   # Sims (run first)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesTest6KubiViaGovernance.s.sol:SimWhitelistTaskEditTest6 \
 *     --fork-url gnosis -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesTest6KubiViaGovernance.s.sol:SimWhitelistTaskEditKubi \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (creates the proposal AND votes, per org or both at once)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistTaskEditRulesTest6KubiViaGovernance.s.sol:BroadcastWhitelistTaskEditBothGnosis \
 *     --rpc-url gnosis --broadcast --slow
 *   # (or :BroadcastWhitelistTaskEditTest6 / :BroadcastWhitelistTaskEditKubi for one org)
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// PaymasterHub on Gnosis.
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Test6 (Gnosis) — verified via Poa subgraph 2026-06-02.
bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;

// KUBI (Gnosis) — verified via Poa subgraph 2026-06-02.
bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
address constant KUBI_TM = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
address constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;

// TaskManager edit-task selectors.
bytes4 constant SEL_UPDATE_TASK = 0x48db6f65; // updateTask(uint256,uint256,bytes,bytes32,address,uint256)
bytes4 constant SEL_UPDATE_TASK_METADATA = 0x26fa4e70; // updateTaskMetadata(uint256,bytes,bytes32)

// Hudson — verified creator-hat wearer on BOTH Test6 and KUBI HybridVoting. Pranked in the sim so
// create + vote resolve against real on-chain Hats state; also the expected broadcaster.
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

abstract contract WhitelistTaskEditGovBase is Script {
    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    /// @dev Single-call batch: setRulesBatch enabling both edit selectors on the org's TaskManager.
    function _buildBatch(bytes32 orgId, address tm) internal pure returns (IExecutor.Call[] memory batch) {
        address[] memory targets = new address[](2);
        bytes4[] memory selectors = new bytes4[](2);
        bool[] memory allowed = new bool[](2);
        uint32[] memory hints = new uint32[](2);

        targets[0] = tm;
        selectors[0] = SEL_UPDATE_TASK;
        allowed[0] = true;
        targets[1] = tm;
        selectors[1] = SEL_UPDATE_TASK_METADATA;
        allowed[1] = true;

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
        console.log("\n=== Edit-task paymaster whitelist preview:", name, "===");
        console.log("  TaskManager (target):", tm);
        console.log("  updateTask allowed now:        ", _ruleAllowed(orgId, tm, SEL_UPDATE_TASK));
        console.log("  updateTaskMetadata allowed now:", _ruleAllowed(orgId, tm, SEL_UPDATE_TASK_METADATA));
        console.log("  -> both will be set allowed = true");
    }

    /// @dev Full sim (real Hats, prank Hudson): create -> vote -> warp -> announceWinner -> assert.
    function _simFlow(string memory name, bytes32 orgId, address tm, address hv) internal {
        _printPreview(name, orgId, tm);

        IExecutor.Call[] memory batch = _buildBatch(orgId, tm);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(hv)
            .createProposal(
                bytes(string.concat(name, ": whitelist updateTask + updateTaskMetadata (sim)")),
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
        require(valid, string.concat("Sim ", name, ": proposal did not pass with the creator's single vote"));
        console.log("  Winner option:", winner, " valid:", valid);

        require(_ruleAllowed(orgId, tm, SEL_UPDATE_TASK), "Sim: updateTask still not allowed");
        require(_ruleAllowed(orgId, tm, SEL_UPDATE_TASK_METADATA), "Sim: updateTaskMetadata still not allowed");
        console.log("PASS:", name, "edit-task sponsorship whitelisted end-to-end.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcastCreateAndVote(uint256 key, string memory name, bytes32 orgId, address tm, address hv) internal {
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting edit-task whitelist proposal + vote:", name, "===");
        console.log("  Sender:       ", sender);
        console.log("  HybridVoting: ", hv);
        console.log("  Duration:     ", minutesDuration, "minutes");
        _printPreview(name, orgId, tm);

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hats = IHatsMinimal(abi.decode(TaskManager(tm).getLensData(3, ""), (address)));
        uint256[] memory creatorHats = HybridVoting(hv).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hats.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, string.concat("Sender wears no creator hat on ", name, " HybridVoting"));

        IExecutor.Call[] memory batch = _buildBatch(orgId, tm);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        (uint8[] memory idxs, uint8[] memory weights) = _ballot();

        vm.startBroadcast(key);
        HybridVoting(hv)
            .createProposal(
                bytes(string.concat(name, ": whitelist updateTask + updateTaskMetadata for gas sponsorship")),
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

    function _resolveKey() internal view returns (uint256 key) {
        key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
    }
}

/* ───────────────────────────── Test6 ───────────────────────────── */

contract SimWhitelistTaskEditTest6 is WhitelistTaskEditGovBase {
    function run() public {
        _simFlow("Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

contract BroadcastWhitelistTaskEditTest6 is WhitelistTaskEditGovBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

/* ───────────────────────────── KUBI ───────────────────────────── */

contract SimWhitelistTaskEditKubi is WhitelistTaskEditGovBase {
    function run() public {
        _simFlow("KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}

contract BroadcastWhitelistTaskEditKubi is WhitelistTaskEditGovBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}

/* ─────────────────────── Both orgs in one run ─────────────────────── */

contract BroadcastWhitelistTaskEditBothGnosis is WhitelistTaskEditGovBase {
    function run() public {
        uint256 key = _resolveKey();
        _broadcastCreateAndVote(key, "Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
        _broadcastCreateAndVote(key, "KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}
