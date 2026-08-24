// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {DefaultGlobalRules} from "../helpers/DefaultGlobalRules.sol";

/*
 * ============================================================================
 * Sync the paymaster GLOBAL RULEBOOK with the MembershipAuthority selectors (Wave D1)
 * ============================================================================
 *
 * Adds the ten Access-v2 user-facing / manager-delegate selectors to the type-keyed global
 * rulebook, keyed under MEMBERSHIP_AUTHORITY_ID, so they're gasless for passkey users on every
 * migrated org (Mirror mode picks them up instantly). MIRRORS the RoleManager-wave reasoning that
 * sponsored 5 delegation selectors — see DefaultGlobalRules for the per-selector inclusion/exclusion
 * rationale (executor path excluded; only user + manager-delegate calls appear):
 *
 *   (MEMBERSHIP_AUTHORITY_ID, claim(uint256))                     hint 300_000
 *   (MEMBERSHIP_AUTHORITY_ID, renounce(uint256))                  hint 200_000
 *   (MEMBERSHIP_AUTHORITY_ID, vouch(uint256,address))             hint 0
 *   (MEMBERSHIP_AUTHORITY_ID, revokeVouch(uint256,address))       hint 200_000
 *   (MEMBERSHIP_AUTHORITY_ID, delegatedGrant(uint256,address))    hint 250_000
 *   (MEMBERSHIP_AUTHORITY_ID, delegatedOffer(uint256,address))    hint 300_000
 *   (MEMBERSHIP_AUTHORITY_ID, delegatedRemove(uint256,address,bool)) hint 250_000
 *   (MEMBERSHIP_AUTHORITY_ID, delegatedUnremove(uint256,address)) hint 200_000
 *   (MEMBERSHIP_AUTHORITY_ID, finalize(uint256))                  hint 600_000
 *   (MEMBERSHIP_AUTHORITY_ID, cancel(uint256))                    hint 200_000
 *
 * The delta is READ FROM DefaultGlobalRules.entries() (the single source of truth — hints and
 * selectors live there and are cross-checked against the real IMembershipAuthority ABI by
 * testDefaultGlobalRules_MatchRealContractSelectors), so this script never re-types a signature
 * string. setGlobalRulesBatch upserts are idempotent.
 *
 * Routed through Satellite.adminCall (Gnosis) / Hub.adminCall (Arbitrum) → the local
 * PoaManager.adminCall, so the hub sees msg.sender == poaManager and the poaManager-gated
 * setGlobalRulesBatch passes independent of protocolAdmin state.
 *
 * The type-keyed rulebook ships with PaymasterHub v20 (RegisterAccessV2Protocol upgrades it). The
 * live hub is still v19 (getGlobalRuleCount reverts) as of writing; the sim stands v20 up on the
 * fork the same way RegisterAccessV2Protocol / UpgradePaymasterGlobalRules do, seeds the pre-delta
 * baseline, then applies + verifies the delta so the before/after is honest.
 *
 * Usage:
 *   # Sims (production profile, both chains):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/SyncAccessV2GlobalRules.s.sol:SimGnosis  --fork-url gnosis-gateway -vvv
 *   FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/SyncAccessV2GlobalRules.s.sol:SimArbitrum --fork-url arbitrum     -vvv
 *
 *   # Broadcast:
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/SyncAccessV2GlobalRules.s.sol:BroadcastGnosis  --rpc-url gnosis   --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/accessv2/SyncAccessV2GlobalRules.s.sol:BroadcastArbitrum --rpc-url arbitrum --broadcast --slow
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
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

    // Throwaway registry version for the sim-only PaymasterHub v20 stand-up (see _ensureRulebook).
    string internal constant SIM_HUB_VERSION = "av2-w1-sim";

    uint256 internal constant DELTA_COUNT = 10;

    /// @dev A rulebook entry belongs to THIS wave's delta iff it is keyed under the MembershipAuthority
    ///      typeId (all ten Access-v2 selectors). Filtered from the canonical DefaultGlobalRules seed
    ///      so hints/selectors stay single-sourced.
    function _isDeltaEntry(DefaultGlobalRules.Entry memory entry) internal pure returns (bool) {
        return entry.typeId == ModuleTypes.MEMBERSHIP_AUTHORITY_ID;
    }

    function _delta()
        internal
        pure
        returns (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints)
    {
        DefaultGlobalRules.Entry[] memory e = DefaultGlobalRules.entries();
        typeIds = new bytes32[](DELTA_COUNT);
        selectors = new bytes4[](DELTA_COUNT);
        allowed = new bool[](DELTA_COUNT);
        hints = new uint32[](DELTA_COUNT);
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
        require(n == DELTA_COUNT, "delta: expected exactly 10 MembershipAuthority rules in DefaultGlobalRules");
    }

    /// @dev The canonical seed MINUS the delta — the rulebook exactly as the v20 rollout seeds it
    ///      before this wave. Used only by the sims to reconstruct a pre-delta baseline on a fork that
    ///      has no live v20 rulebook yet.
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

    /// @dev Assert the rulebook carries every delta rule with the CORRECT Rule field order
    ///      (Rule { uint32 maxCallGasHint; bool allowed }). Decoding these swapped would silently pass
    ///      a zero-hint/false rule — the exact bug class CLAUDE.md warns about.
    function _assertApplied(PaymasterHub pm) internal view {
        (bytes32[] memory typeIds, bytes4[] memory selectors,, uint32[] memory hints) = _delta();
        for (uint256 i; i < selectors.length; i++) {
            PaymasterHub.Rule memory r = pm.getGlobalRule(typeIds[i], selectors[i]);
            require(r.allowed, "delta rule not allowed after sync");
            require(r.maxCallGasHint == hints[i], "delta rule gas hint mismatch after sync");
        }
    }

    function _adminCallAsHudson(bool gnosis, address target, bytes memory data) internal {
        vm.prank(HUDSON);
        if (gnosis) IPoaAdmin(GNOSIS_SATELLITE).adminCall(target, data);
        else IPoaAdmin(ARB_HUB).adminCall(target, data);
    }

    /// @dev Ensure the fork carries the v20 type-keyed rulebook. If the live PaymasterHub is still v19
    ///      (getGlobalRuleCount reverts), stand v20 up the same way RegisterAccessV2Protocol does (new
    ///      impl + beacon upgrade as the owner) and seed the pre-delta baseline. Once v20 is live this
    ///      branch no-ops against the real on-chain rulebook.
    function _ensureRulebook(PaymasterHub pm, bool gnosis) internal {
        try pm.getGlobalRuleCount() returns (uint256) {
            return; // v20 already live — use the real on-chain rulebook as the baseline.
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
            console.log("  (sim) stood up v20 rulebook + seeded pre-delta baseline entries:", bt.length);
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
        console.log("Gnosis: MembershipAuthority selectors synced into the global rulebook. PASS.");
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
        console.log("Arbitrum: MembershipAuthority selectors synced into the global rulebook. PASS.");
    }
}

/* ════════════════════════════ Sims — real forks, prank Hudson ════════════════════════════ */

contract SimGnosis is SyncBase {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(GNOSIS_PAYMASTER));
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        console.log("\n=== SIM: sync MembershipAuthority selectors (Gnosis fork) ===");
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
            "PASS: SimGnosis - MembershipAuthority selectors added to the global rulebook (correct field order)."
        );
    }
}

contract SimArbitrum is SyncBase {
    function run() public {
        PaymasterHub pm = PaymasterHub(payable(ARB_PAYMASTER));
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) = _delta();

        console.log("\n=== SIM: sync MembershipAuthority selectors (Arbitrum fork) ===");
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
            "PASS: SimArbitrum - MembershipAuthority selectors added to the global rulebook (correct field order)."
        );
    }
}
