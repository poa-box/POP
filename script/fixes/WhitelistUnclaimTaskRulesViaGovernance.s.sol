// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Live orgs — paymaster rule for the TaskManager v7 unclaimTask selector,
 * via governance (proposal + creator vote per org)
 * ============================================================================
 *
 * TaskManager v7 added unclaimTask(uint256) = 0x6103955a (release a claimed task
 * back to the pool). OrgDeployer v18 puts it in the default rule batch, but that is
 * forward-only: already-deployed orgs keep the rules they were bootstrapped with, so
 * without this their passkey/smart-account users hit AA validation failure (not a
 * contract revert) when they try to release a task.
 *
 * Per org, one proposal whose single Executor call is:
 *   paymaster.setRulesBatch(orgId, [TM], [0x6103955a], [true], [0])
 *
 * Purely additive — unlike the v5->v6 deadline migration, v7 replaced no selectors,
 * so there is nothing to disallow in the same batch.
 *
 * Gas hint stays 0 deliberately: the hint is a CAP, not a budget, and the deployed
 * PaymasterHub unpacks v0.7 accountGasLimits reversed (docs/PAYMASTERHUB_GAS_UNPACK_BUG.md),
 * so a non-zero hint caps the WRONG gas field and yields AA33 GasTooHigh.
 *
 * Prerequisite: the org's chain must already be running TaskManager v7, or the rule
 * points at a selector the beacon does not implement. Verified live 2026-08-01:
 * Gnosis and Arbitrum are both on v7 (0xcfAe1DAdF1A48b363aAD3BbB8f94f67bb3785988).
 *
 * Usage:
 *   # Sims (run first — CLAUDE.md requires PASS before broadcast)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistUnclaimTaskRulesViaGovernance.s.sol:SimWhitelistUnclaimTest6 \
 *     --fork-url gnosis -vvv
 *   ... :SimWhitelistUnclaimKubi          --fork-url gnosis   -vvv
 *   ... :SimWhitelistUnclaimDecentralPark --fork-url gnosis   -vvv
 *   ... :SimWhitelistUnclaimPoa           --fork-url arbitrum -vvv
 *
 *   # Broadcasts (each creates its org's proposal AND votes)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/WhitelistUnclaimTaskRulesViaGovernance.s.sol:BroadcastWhitelistUnclaimTest6 \
 *     --rpc-url gnosis --broadcast --slow
 *   ... :BroadcastWhitelistUnclaimKubi          --rpc-url gnosis   --broadcast --slow
 *   ... :BroadcastWhitelistUnclaimDecentralPark --rpc-url gnosis   --broadcast --slow
 *   ... :BroadcastWhitelistUnclaimPoa           --rpc-url arbitrum --broadcast --slow
 *
 * After the voting window closes, execute with an EXPLICIT gas limit — announceWinner
 * wraps the batch in try/catch, so estimation prices only the cheap caught-failure path
 * and the call silently no-ops (see CLAUDE.md):
 *   cast send <HV> 'announceWinner(uint256)' <id> --gas-limit 3000000 --rpc-url <chain>
 *
 * Optional env override:
 *   PROPOSAL_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

// PaymasterHubs.
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
address constant ARB_PAYMASTER_HUB = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;

// Test6 (Gnosis).
bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
address constant TEST6_TM = 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc;
address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;

// KUBI (Gnosis).
bytes32 constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
address constant KUBI_TM = 0xF57024fC77915Fce8f2608afdd027941bCEE3336;
address constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;

// Decentral Park (Gnosis).
bytes32 constant DECENTRAL_PARK_ORG = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;

// Poa (Arbitrum).
bytes32 constant POA_ORG = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;
address constant POA_TM = 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0;
address constant POA_HV = 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5;

// TaskManager v7 selector (cast sig "unclaimTask(uint256)").
bytes4 constant SEL_UNCLAIM_TASK = 0x6103955a;

// Hudson — verified creator-hat wearer on every org's HybridVoting (see the deadline twins).
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

abstract contract WhitelistUnclaimBase is Script {
    function _hub() internal pure virtual returns (address);

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION", uint256(DEFAULT_PROPOSAL_DURATION_MINUTES)));
    }

    function _resolveKey() internal view returns (uint256 key) {
        key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _buildBatch(bytes32 orgId, address tm) internal pure returns (IExecutor.Call[] memory batch) {
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        bool[] memory allowed = new bool[](1);
        uint32[] memory hints = new uint32[](1);

        targets[0] = tm;
        selectors[0] = SEL_UNCLAIM_TASK;
        allowed[0] = true;
        // hints[0] stays 0 — see the header note on the accountGasLimits unpack bug.

        batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: _hub(),
            value: 0,
            data: abi.encodeCall(IPaymasterHubMinimal.setRulesBatch, (orgId, targets, selectors, allowed, hints))
        });
    }

    function _ruleAllowed(bytes32 orgId, address tm, bytes4 selector) internal view returns (bool) {
        return IPaymasterHubMinimal(_hub()).getRule(orgId, tm, selector).allowed;
    }

    function _ballot() internal pure returns (uint8[] memory idxs, uint8[] memory weights) {
        idxs = new uint8[](1);
        weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
    }

    /// @dev Guards against whitelisting a selector the org's beacon cannot serve. A live v7
    ///      impl reverts BadStatus() on task id 0 (not CLAIMED); a pre-v7 impl reverts with
    ///      EMPTY data (no such function), which is what this distinguishes.
    function _requireV7(address tm) internal view {
        (bool ok, bytes memory ret) = tm.staticcall(abi.encodeWithSelector(SEL_UNCLAIM_TASK, uint256(0)));
        require(!ok, "unclaimTask(0) unexpectedly succeeded");
        require(ret.length >= 4, "TaskManager is not v7 (unclaimTask missing) - upgrade the beacon first");
    }

    function _printPreview(string memory name, bytes32 orgId, address tm) internal view {
        console.log("\n=== v7 unclaimTask paymaster rule preview:", name, "===");
        console.log("  PaymasterHub:        ", _hub());
        console.log("  TaskManager (target):", tm);
        console.log("  unclaimTask allowed now:", _ruleAllowed(orgId, tm, SEL_UNCLAIM_TASK));
        console.log("  -> will be allowed (additive; nothing is disallowed)");
    }

    /// @dev Full sim (real Hats, prank Hudson): create -> vote -> warp -> announceWinner -> assert.
    function _simFlow(string memory name, bytes32 orgId, address tm, address hv) internal {
        _requireV7(tm);
        _printPreview(name, orgId, tm);
        require(!_ruleAllowed(orgId, tm, SEL_UNCLAIM_TASK), "Sim: unclaimTask already allowed (nothing to prove)");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _buildBatch(orgId, tm);

        uint32 minutesDuration = 10;
        vm.prank(HUDSON);
        HybridVoting(hv)
            .createProposal(
                bytes("Paymaster rule for TaskManager v7 unclaimTask (sim)"),
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

        vm.warp(vm.getBlockTimestamp() + uint256(minutesDuration) * 60 + 10);
        (uint256 winner, bool valid) = HybridVoting(hv).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass with the creator's single vote");
        console.log("  Winner option:", winner, " valid:", valid);

        require(_ruleAllowed(orgId, tm, SEL_UNCLAIM_TASK), "Sim: unclaimTask still not allowed after execution");
        console.log("PASS:", name, "unclaimTask 0x6103955a is now sponsored.");
    }

    /// @dev Broadcast: create the proposal AND cast the creator's vote, in one signed session.
    function _broadcastCreateAndVote(uint256 key, string memory name, bytes32 orgId, address tm, address hv) internal {
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        _requireV7(tm);

        console.log("\n=== Broadcasting", name, "v7 unclaimTask rule proposal + vote ===");
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
                bytes("Paymaster rule for TaskManager v7 unclaimTask"),
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
        console.log("  After the window expires, execute it with an EXPLICIT gas limit:");
        console.log("    cast send <HV> 'announceWinner(uint256)' <id> --gas-limit 3000000");
    }
}

abstract contract WhitelistUnclaimGnosisBase is WhitelistUnclaimBase {
    function _hub() internal pure override returns (address) {
        return GNOSIS_PAYMASTER_HUB;
    }
}

abstract contract WhitelistUnclaimArbitrumBase is WhitelistUnclaimBase {
    function _hub() internal pure override returns (address) {
        return ARB_PAYMASTER_HUB;
    }
}

contract SimWhitelistUnclaimTest6 is WhitelistUnclaimGnosisBase {
    function run() public {
        _simFlow("Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

contract BroadcastWhitelistUnclaimTest6 is WhitelistUnclaimGnosisBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "Test6", TEST6_ORG, TEST6_TM, TEST6_HV);
    }
}

contract SimWhitelistUnclaimKubi is WhitelistUnclaimGnosisBase {
    function run() public {
        _simFlow("KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}

contract BroadcastWhitelistUnclaimKubi is WhitelistUnclaimGnosisBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "KUBI", KUBI_ORG, KUBI_TM, KUBI_HV);
    }
}

contract SimWhitelistUnclaimDecentralPark is WhitelistUnclaimGnosisBase {
    function run() public {
        _simFlow("Decentral Park", DECENTRAL_PARK_ORG, DECENTRAL_PARK_TM, DECENTRAL_PARK_HV);
    }
}

contract BroadcastWhitelistUnclaimDecentralPark is WhitelistUnclaimGnosisBase {
    function run() public {
        _broadcastCreateAndVote(
            _resolveKey(), "Decentral Park", DECENTRAL_PARK_ORG, DECENTRAL_PARK_TM, DECENTRAL_PARK_HV
        );
    }
}

contract SimWhitelistUnclaimPoa is WhitelistUnclaimArbitrumBase {
    function run() public {
        _simFlow("Poa", POA_ORG, POA_TM, POA_HV);
    }
}

contract BroadcastWhitelistUnclaimPoa is WhitelistUnclaimArbitrumBase {
    function run() public {
        _broadcastCreateAndVote(_resolveKey(), "Poa", POA_ORG, POA_TM, POA_HV);
    }
}
