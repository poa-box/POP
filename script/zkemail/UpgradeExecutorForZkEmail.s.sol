// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Executor} from "../../src/Executor.sol";
import {PoaManagerHub} from "../../src/crosschain/PoaManagerHub.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * Upgrade the Executor beacon for ZK Email — CROSS-CHAIN  —  SECURITY-CRITICAL
 * ============================================================================
 *
 * Upgrades the protocol "Executor" beacon (on BOTH Arbitrum hub + Gnosis satellite, via one Hyperlane
 * dispatch) to an impl that lets a governance batch self-target EXACTLY ONE admin function —
 * setHatMinterAuthorization — so existing orgs (whose Executor ownership is already renounced) can
 * authorize ZkEmailInvites as a hat minter via a normal vote. Every other self-targeting call still
 * reverts TargetSelf; the change is otherwise behavior-preserving and adds no storage (logic-only).
 *
 * Follows the canonical cross-chain pattern (UpgradeOrgDeployerDeadlineRules.s.sol): the impl is
 * DD-deployed at the SAME address on both chains, then PoaManagerHub.upgradeBeaconCrossChain upgrades
 * the Arbitrum beacon locally AND broadcasts to Gnosis.
 *
 * Blast radius: this is the most security-critical contract in the system; every org's executor follows
 * this beacon in Mirror mode. Verified (2026-05-31) Test6's executor mirrors the protocol Executor
 * beacon, so the upgrade reaches it — Step3 re-asserts that on Gnosis after the relay.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeExecutorForZkEmail.s.sol:SimUpgradeExecutorArbitrum --fork-url arbitrum -vvv
 *
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeExecutorForZkEmail.s.sol:Step1_DeployExecutorOnGnosis --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/UpgradeExecutorForZkEmail.s.sol:Step2_UpgradeExecutorFromArbitrum --rpc-url arbitrum --broadcast --slow
 *   forge script script/zkemail/UpgradeExecutorForZkEmail.s.sol:Step3_VerifyExecutorGnosis --rpc-url gnosis
 * ============================================================================
 */

interface IPoaManagerViewExec {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

interface IBeaconImpl {
    function implementation() external view returns (address);
}

abstract contract UpgradeExecutorBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;

    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    // Test6 executor (Mirror-mode beacon proxy) — proves the upgrade reaches an existing org (Gnosis).
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;

    uint256 internal constant HYPERLANE_FEE = 0.005 ether;
    string internal constant VERSION = "v-zkemail-1";
    bytes32 internal constant EXECUTOR_ID = keccak256("Executor");
    // ERC-1967 beacon slot: keccak256("eip1967.proxy.beacon") - 1
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function _beaconOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
    }

    function _ddDeployExecutor() internal returns (address addr) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt("Executor", VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, type(Executor).creationCode);
            require(deployed == addr, "DD address mismatch");
        }
    }
}

contract Step1_DeployExecutorOnGnosis is UpgradeExecutorBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("\n=== Step 1: DD-deploy the Executor impl on Gnosis ===");
        vm.startBroadcast(key);
        address impl = _ddDeployExecutor();
        vm.stopBroadcast();
        require(impl.code.length > 0, "impl has no code");
        console.log("  Executor impl:", impl);
        console.log("\nNext: Step2_UpgradeExecutorFromArbitrum");
    }
}

contract Step2_UpgradeExecutorFromArbitrum is UpgradeExecutorBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        require(hub.owner() == sender, "Sender must own the Hub");
        require(!hub.paused(), "Hub is paused");
        require(sender.balance >= HYPERLANE_FEE, "need >= 0.005 ETH on Arbitrum for the Hyperlane msg");

        console.log("\n=== Step 2: deploy Executor impl on Arbitrum + upgrade beacon cross-chain ===");
        vm.startBroadcast(key);
        address impl = _ddDeployExecutor();
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("Executor", impl, VERSION);
        vm.stopBroadcast();

        require(
            IPoaManagerViewExec(ARB_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == impl,
            "arb: Executor beacon not upgraded"
        );
        console.log("  Executor impl:", impl);
        console.log("Arbitrum Executor upgrade: PASS. Wait ~5 min for relay, then Step3_VerifyExecutorGnosis.");
    }
}

contract Step3_VerifyExecutorGnosis is UpgradeExecutorBase {
    function run() public view {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        address impl = dd.computeAddress(dd.computeSalt("Executor", VERSION));

        bool beaconOk = IPoaManagerViewExec(GNOSIS_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == impl;
        bool test6Ok = IBeaconImpl(_beaconOf(TEST6_EXECUTOR)).implementation() == impl;

        console.log("\n=== Verify Gnosis Executor upgrade ===");
        console.log("  Gnosis Executor beacon -> new impl:        ", beaconOk);
        console.log("  Test6 executor (Mirror) follows the beacon:", test6Ok);
        if (beaconOk && test6Ok) {
            console.log("PASS: Gnosis Executor upgraded; existing orgs can self-authorize the ZkEmail minter.");
        } else {
            console.log("WAITING: Hyperlane message not yet relayed (retry in a few min).");
        }
    }
}

/// @notice Fork-sim on Arbitrum: DD-deploy the Executor impl, upgradeBeaconCrossChain as Hudson, and
///         assert the Arbitrum-local beacon switched. Gnosis relay + Test6 mirror reach are verified by
///         Step3 after broadcast (the Test6 executor is a Gnosis proxy, not on this fork).
contract SimUpgradeExecutorArbitrum is UpgradeExecutorBase {
    function run() public {
        PoaManagerHub hub = PoaManagerHub(payable(ARB_HUB));
        console.log("\n=== SIM: Executor upgrade for ZK Email (Arbitrum fork, cross-chain) ===");

        address before = IPoaManagerViewExec(ARB_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID);
        vm.deal(HUDSON, 1 ether);
        vm.startPrank(HUDSON);
        address impl = _ddDeployExecutor();
        require(impl != before, "sim: Executor v-zkemail-1 already live");
        hub.upgradeBeaconCrossChain{value: HYPERLANE_FEE}("Executor", impl, VERSION);
        vm.stopPrank();

        require(
            IPoaManagerViewExec(ARB_POA_MANAGER).getCurrentImplementationById(EXECUTOR_ID) == impl,
            "sim: Executor beacon not upgraded"
        );
        console.log("  Executor impl before:", before);
        console.log("  Executor impl after: ", impl);
        console.log("PASS: cross-chain Executor upgrade verified on an Arbitrum fork (local hub effect).");
    }
}
