// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Executor} from "../../src/Executor.sol";

/*
 * ============================================================================
 * Upgrade the Executor beacon for ZK Email (per chain)  —  SECURITY-CRITICAL
 * ============================================================================
 *
 * Upgrades the protocol "Executor" beacon to an impl that lets a governance batch self-target
 * EXACTLY ONE admin function — setHatMinterAuthorization — so existing orgs (whose Executor
 * ownership is already renounced) can authorize ZkEmailInvites as a hat minter via a normal vote.
 * Every other self-targeting call still reverts TargetSelf; the change is otherwise behavior-
 * preserving and adds no storage (logic-only upgrade).
 *
 * Blast radius: this is the most security-critical contract in the system and every org's executor
 * follows this beacon in Mirror mode. Verified on-chain (2026-05-31) that Test6's executor mirrors
 * the protocol Executor beacon, so the upgrade reaches it. Review + sim before broadcasting.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeExecutorForZkEmail.s.sol:SimUpgradeExecutorGnosis --fork-url gnosis -vvv
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeExecutorForZkEmail.s.sol:BroadcastUpgradeExecutorGnosis --rpc-url gnosis --broadcast --slow
 * ============================================================================
 */

interface ISatelliteExec {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IHubExec {
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewExec {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

interface IBeaconImpl {
    function implementation() external view returns (address);
}

abstract contract UpgradeExecutorBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    // ── Gnosis (satellite) ──
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    // Test6 executor (Mirror-mode beacon proxy) — used to prove the upgrade reaches an existing org.
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;

    // ── Arbitrum (hub) ──
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;

    string internal constant VERSION = "v-zkemail-1";
    bytes32 internal constant EXECUTOR_ID = keccak256("Executor");
    // ERC-1967 beacon slot: keccak256("eip1967.proxy.beacon") - 1
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function _beaconOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
    }
}

contract SimUpgradeExecutorGnosis is UpgradeExecutorBase {
    function run() public {
        console.log("\n=== SIM: Upgrade Executor for ZK Email (Gnosis) ===");
        require(ISatelliteExec(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        address newImpl = address(new Executor());
        address before = IPoaManagerViewExec(GNOSIS_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID);
        require(before != newImpl, "already on new impl?");
        console.log("  new Executor impl:", newImpl);

        vm.prank(HUDSON);
        ISatelliteExec(GNOSIS_SATELLITE).upgradeBeaconDirect("Executor", newImpl, VERSION);

        require(
            IPoaManagerViewExec(GNOSIS_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == newImpl,
            "Executor beacon not upgraded"
        );
        console.log("  Executor beacon -> new impl OK");

        // Mirror-mode reach: Test6's executor SwitchableBeacon now resolves to the new impl.
        address test6Beacon = _beaconOf(TEST6_EXECUTOR);
        require(IBeaconImpl(test6Beacon).implementation() == newImpl, "Test6 executor did not follow beacon");
        console.log("  Test6 executor SwitchableBeacon (Mirror) -> new impl OK");

        console.log("PASS: Executor upgrade verified on Gnosis fork (reaches existing orgs).");
    }
}

contract BroadcastUpgradeExecutorGnosis is UpgradeExecutorBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");

        vm.startBroadcast(key);
        address newImpl = address(new Executor());
        ISatelliteExec(GNOSIS_SATELLITE).upgradeBeaconDirect("Executor", newImpl, VERSION);
        vm.stopBroadcast();

        require(
            IPoaManagerViewExec(GNOSIS_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == newImpl,
            "upgrade did not stick"
        );
        console.log("Gnosis Executor upgraded. new impl:", newImpl);
    }
}

contract BroadcastUpgradeExecutorArbitrum is UpgradeExecutorBase {
    function run() public {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Hub owner)");

        vm.startBroadcast(key);
        address newImpl = address(new Executor());
        IHubExec(ARB_HUB).upgradeBeaconLocal("Executor", newImpl, VERSION);
        vm.stopBroadcast();

        require(
            IPoaManagerViewExec(ARB_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == newImpl,
            "upgrade did not stick"
        );
        console.log("Arbitrum Executor upgraded. new impl:", newImpl);
    }
}
