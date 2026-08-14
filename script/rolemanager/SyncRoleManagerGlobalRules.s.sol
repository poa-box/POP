// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DefaultGlobalRules} from "../helpers/DefaultGlobalRules.sol";

/*
 * ============================================================================
 * Sync the paymaster GLOBAL RULEBOOK with the RoleManager self-claim selectors
 * ============================================================================
 *
 * Adds the four RoleManager-wave user-facing selectors to the type-keyed global rulebook
 * so they're gasless for passkey users:
 *
 *   (ELIGIBILITY_MODULE_ID, claimHat(uint256))     hint 300_000   — single self-mint
 *   (ELIGIBILITY_MODULE_ID, claimHats(uint256[]))   hint 3_000_000 — up to MAX_CLAIM_BATCH (20) mints
 *   (DIRECT_DEMOCRACY_VOTING_ID, createProposalV2(...,uint32))       hint 0 — quorum-override polls
 *   (HYBRID_VOTING_ID,           createProposalV2(...,uint32,bool))  hint 0 — + equalWeight proposals
 *
 * The delta is READ FROM DefaultGlobalRules.entries() (the single source of truth — hints and
 * selectors are derived there from the real ABI and cross-checked by
 * testDefaultGlobalRules_MatchRealContractSelectors), so this script never re-types a signature
 * string. setGlobalRulesBatch upserts are idempotent: re-running or overlapping the v20 base seed
 * is harmless. Every Mirror-mode org picks the entries up instantly.
 *
 * Routed through Satellite.adminCall (Gnosis) / Hub.adminCall (Arbitrum) → the local
 * PoaManager.adminCall, so the hub sees msg.sender == poaManager and the poaManager-gated
 * setGlobalRulesBatch passes independent of protocolAdmin state.
 *
 * Usage:
 *   # Sims (production profile, both chains):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/SyncRoleManagerGlobalRules.s.sol:SimGnosis  --fork-url gnosis   -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/SyncRoleManagerGlobalRules.s.sol:SimArbitrum --fork-url arbitrum -vvv
 *
 *   # Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/SyncRoleManagerGlobalRules.s.sol:BroadcastGnosis  --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/rolemanager/SyncRoleManagerGlobalRules.s.sol:BroadcastArbitrum --rpc-url arbitrum --broadcast --slow
 * ============================================================================
 */

interface IPoaAdmin {
    function owner() external view returns (address);
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

interface ISatelliteAdmin is IPoaAdmin {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
}

interface IHubAdmin is IPoaAdmin {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
}

abstract contract SyncBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_PAYMASTER = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;

    // Throwaway registry version for the sim-only PaymasterHub v20 beacon upgrade (see _ensureRulebook).
    string internal constant SIM_HUB_VERSION = "rm-w7-sim";

    /// @dev A rulebook entry belongs to THIS rollout's delta iff it is one of: the two EM claim
    ///      selectors, DD createProposalV2, or HV createProposalV2. Filtered from the canonical
    ///      DefaultGlobalRules seed so hints/selectors stay single-sourced.
    function _isDeltaEntry(DefaultGlobalRules.Entry memory entry) internal pure returns (bool) {
        if (entry.typeId == ModuleTypes.ELIGIBILITY_MODULE_ID) {
            return entry.selector == EligibilityModule.claimHat.selector
                || entry.selector == EligibilityModule.claimHats.selector;
        }
        if (entry.typeId == ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID) {
            return entry.selector == DirectDemocracyVoting.createProposalV2.selector;
        }
        if (entry.typeId == ModuleTypes.HYBRID_VOTING_ID) {
            return entry.selector == HybridVoting.createProposalV2.selector;
        }
        return false;
    }

    /// @dev The RoleManager-wave rule delta (2 EM claims + DD/HV createProposalV2).
    function _delta()
        internal
        pure
        returns (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints)
    {
        DefaultGlobalRules.Entry[] memory e = DefaultGlobalRules.entries();

        typeIds = new bytes32[](4);
        selectors = new bytes4[](4);
        allowed = new bool[](4);
        hints = new uint32[](4);
        uint256 n;
        for (uint256 i; i < e.length; i++) {
            if (_isDeltaEntry(e[i])) {
                typeIds[n] = e[i].typeId;
                selectors[n] = e[i].selector;
                allowed[n] = true;
                hints[n] = e[i].maxCallGasHint;
                n++;
            }
        }
        require(n == 4, "delta: expected exactly 4 RoleManager-wave rules in DefaultGlobalRules");
    }

    /// @dev Assert the rulebook carries every delta rule with the CORRECT Rule field order
    ///      (Rule { uint32 maxCallGasHint; bool allowed }). Decoding these swapped would silently
    ///      pass a zero-hint/false rule — the exact bug class CLAUDE.md warns about.
    function _assertApplied(PaymasterHub pm) internal view {
        (bytes32[] memory typeIds, bytes4[] memory selectors,, uint32[] memory hints) = _delta();
        for (uint256 i; i < selectors.length; i++) {
            PaymasterHub.Rule memory r = pm.getGlobalRule(typeIds[i], selectors[i]);
            require(r.allowed, "delta rule not allowed after sync");
            require(r.maxCallGasHint == hints[i], "delta rule gas hint mismatch after sync");
        }
    }

    /// @dev The canonical seed MINUS the delta — i.e. the rulebook exactly as the v20 rollout
    ///      (UpgradePaymasterGlobalRules) seeded it, before this W7 change. Used by the sims to
    ///      reconstruct the pre-W7 baseline so the before/after delta is honest.
    function _baseMinusDelta()
        internal
        pure
        returns (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints)
    {
        DefaultGlobalRules.Entry[] memory e = DefaultGlobalRules.entries();
        uint256 m;
        for (uint256 i; i < e.length; i++) {
            if (!_isDeltaEntry(e[i])) m++;
        }
        typeIds = new bytes32[](m);
        selectors = new bytes4[](m);
        allowed = new bool[](m);
        hints = new uint32[](m);
        uint256 n;
        for (uint256 i; i < e.length; i++) {
            if (_isDeltaEntry(e[i])) continue;
            typeIds[n] = e[i].typeId;
            selectors[n] = e[i].selector;
            allowed[n] = true;
            hints[n] = e[i].maxCallGasHint;
            n++;
        }
    }

    function _adminCallAsHudson(bool gnosis, address target, bytes memory data) internal {
        vm.prank(HUDSON);
        if (gnosis) IPoaAdmin(GNOSIS_SATELLITE).adminCall(target, data);
        else IPoaAdmin(ARB_HUB).adminCall(target, data);
    }

    /// @dev Ensure the fork carries the v20 type-keyed rulebook. The live PaymasterHub is still v19
    ///      (pre-rulebook) as of 2026-08-13, so getGlobalRuleCount reverts; in that case stand up v20
    ///      the same way UpgradePaymasterGlobalRules does (new impl + beacon upgrade as the owner) and
    ///      seed the pre-W7 baseline. Once v20 is actually live this branch no-ops and the sim runs
    ///      against the real on-chain rulebook. Returns the paymaster the caller should read.
    function _ensureRulebook(PaymasterHub pm, bool gnosis) internal {
        try pm.getGlobalRuleCount() returns (uint256) {
            // v20 already live — use the real on-chain rulebook state as the baseline.
            return;
        } catch {
            address impl = address(new PaymasterHub());
            require(impl.code.length <= 24576, "sim: impl exceeds EIP-170");
            vm.prank(HUDSON);
            if (gnosis) ISatelliteAdmin(GNOSIS_SATELLITE).upgradeBeaconDirect("PaymasterHub", impl, SIM_HUB_VERSION);
            else IHubAdmin(ARB_HUB).upgradeBeaconLocal("PaymasterHub", impl, SIM_HUB_VERSION);
            require(pm.getGlobalRuleCount() == 0, "sim: fresh v20 rulebook should be empty");
            (bytes32[] memory bt, bytes4[] memory bs, bool[] memory ba, uint32[] memory bh) = _baseMinusDelta();
            _adminCallAsHudson(gnosis, address(pm), abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (bt, bs, ba, bh)));
            require(pm.getGlobalRuleCount() == bt.length, "sim: baseline seed count mismatch");
            console.log("  (sim) stood up v20 rulebook + seeded pre-W7 baseline entries:", bt.length);
        }
    }
}

/* ════════════════════════════ Broadcast ════════════════════════════ */

contract BroadcastGnosis is SyncBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IPoaAdmin(GNOSIS_SATELLITE).owner() == vm.addr(key), "signer must own the Satellite");
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        vm.startBroadcast(key);
        IPoaAdmin(GNOSIS_SATELLITE)
            .adminCall(
                GNOSIS_PAYMASTER, abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
            );
        vm.stopBroadcast();

        _assertApplied(PaymasterHub(payable(GNOSIS_PAYMASTER)));
        console.log("Gnosis: RoleManager claim rules synced into the global rulebook. PASS.");
    }
}

contract BroadcastArbitrum is SyncBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(IPoaAdmin(ARB_HUB).owner() == vm.addr(key), "signer must own the Hub");
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        vm.startBroadcast(key);
        IPoaAdmin(ARB_HUB)
            .adminCall(
                ARB_PAYMASTER, abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
            );
        vm.stopBroadcast();

        _assertApplied(PaymasterHub(payable(ARB_PAYMASTER)));
        console.log("Arbitrum: RoleManager claim rules synced into the global rulebook. PASS.");
    }
}

/* ════════════════════════════ Sims — real forks, prank Hudson ════════════════════════════ */

contract SimGnosis is SyncBase {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(GNOSIS_PAYMASTER));
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        console.log("\n=== SIM: sync RoleManager-wave rules (Gnosis fork) ===");
        _ensureRulebook(pm, true);
        uint256 countBefore = pm.getGlobalRuleCount();
        for (uint256 i; i < selectors.length; i++) {
            PaymasterHub.Rule memory r = pm.getGlobalRule(typeIds[i], selectors[i]);
            require(!r.allowed, "sim: delta rule already present (unexpected)");
        }
        console.log("  rulebook entries before:", countBefore);

        _adminCallAsHudson(
            true,
            GNOSIS_PAYMASTER,
            abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
        );

        _assertApplied(pm);
        uint256 countAfter = pm.getGlobalRuleCount();
        require(countAfter == countBefore + typeIds.length, "sim: rulebook did not grow by the delta size");
        console.log("  rulebook entries after: ", countAfter);
        for (uint256 i; i < selectors.length; i++) {
            console.log("  delta rule hint:", pm.getGlobalRule(typeIds[i], selectors[i]).maxCallGasHint);
        }
        console.log(
            "PASS: SimGnosis - claimHat/claimHats + DD/HV createProposalV2 added to the global rulebook (correct field order)."
        );
    }
}

contract SimArbitrum is SyncBase {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(ARB_PAYMASTER));
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        console.log("\n=== SIM: sync RoleManager-wave rules (Arbitrum fork) ===");
        _ensureRulebook(pm, false);
        uint256 countBefore = pm.getGlobalRuleCount();
        for (uint256 i; i < selectors.length; i++) {
            PaymasterHub.Rule memory r = pm.getGlobalRule(typeIds[i], selectors[i]);
            require(!r.allowed, "sim: delta rule already present (unexpected)");
        }
        console.log("  rulebook entries before:", countBefore);

        _adminCallAsHudson(
            false, ARB_PAYMASTER, abi.encodeCall(PaymasterHub.setGlobalRulesBatch, (typeIds, selectors, allowed, hints))
        );

        _assertApplied(pm);
        uint256 countAfter = pm.getGlobalRuleCount();
        require(countAfter == countBefore + typeIds.length, "sim: rulebook did not grow by the delta size");
        console.log("  rulebook entries after: ", countAfter);
        for (uint256 i; i < selectors.length; i++) {
            console.log("  delta rule hint:", pm.getGlobalRule(typeIds[i], selectors[i]).maxCallGasHint);
        }
        console.log(
            "PASS: SimArbitrum - claimHat/claimHats + DD/HV createProposalV2 added to the global rulebook (correct field order)."
        );
    }
}
