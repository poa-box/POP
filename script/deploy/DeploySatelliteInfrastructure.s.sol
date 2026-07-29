// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

// Infrastructure
import {PoaManager} from "../../src/PoaManager.sol";
import {ImplementationRegistry} from "../../src/ImplementationRegistry.sol";
import {PoaManagerSatellite} from "../../src/crosschain/PoaManagerSatellite.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

// Implementations
import {HybridVoting} from "../../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {Executor} from "../../src/Executor.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {PaymentManager} from "../../src/PaymentManager.sol";
import {UniversalAccountRegistry} from "../../src/UniversalAccountRegistry.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";
import {ToggleModule} from "../../src/ToggleModule.sol";
import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../src/PasskeyAccountFactory.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";

/**
 * @title DeploySatelliteInfrastructure
 * @notice Deploys protocol infrastructure on a satellite chain with deterministic
 *         implementation addresses and a PoaManagerSatellite for receiving cross-chain upgrades.
 *
 * Usage:
 *   DETERMINISTIC_DEPLOYER=0x... HUB_DOMAIN=1 HUB_ADDRESS=0x... MAILBOX=0x... \
 *   forge script script/DeploySatelliteInfrastructure.s.sol:DeploySatelliteInfrastructure \
 *     --rpc-url $RPC_URL --broadcast --verify
 */
contract DeploySatelliteInfrastructure is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address deterministicDeployer = vm.envAddress("DETERMINISTIC_DEPLOYER");
        uint32 hubDomain = uint32(vm.envUint("HUB_DOMAIN"));
        address hubAddress = vm.envAddress("HUB_ADDRESS");
        address mailboxAddr = vm.envAddress("MAILBOX");

        console.log("\n=== Deploying Satellite Infrastructure ===");
        console.log("Deployer:", deployer);
        console.log("Hub domain:", hubDomain);
        console.log("Hub address:", hubAddress);

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementations via DeterministicDeployer (same addresses as all chains)
        DeterministicDeployer dd = DeterministicDeployer(deterministicDeployer);
        _deployImplementations(dd);

        // 2. Deploy local ImplementationRegistry
        ImplementationRegistry regImpl = new ImplementationRegistry();
        address regImplAddr = address(regImpl);

        // 3. Deploy local PoaManager
        PoaManager pm = new PoaManager(address(0));

        // 4. Setup ImplementationRegistry behind a beacon
        pm.addContractType("ImplementationRegistry", regImplAddr);
        address regBeacon = pm.getBeaconById(keccak256("ImplementationRegistry"));
        bytes memory regInit = abi.encodeWithSignature("initialize(address)", deployer);
        ImplementationRegistry reg = ImplementationRegistry(address(new BeaconProxy(regBeacon, regInit)));
        pm.updateImplRegistry(address(reg));
        reg.registerImplementation("ImplementationRegistry", "v1", regImplAddr, true);
        reg.transferOwnership(address(pm));

        // 5. Register all contract types (using deterministic addresses)
        _registerContractTypes(pm, dd);

        // 6. Deploy PoaManagerSatellite
        PoaManagerSatellite satellite = new PoaManagerSatellite(address(pm), mailboxAddr, hubDomain, hubAddress);

        // 7. Transfer PoaManager ownership to Satellite
        pm.transferOwnership(address(satellite));

        vm.stopBroadcast();

        console.log("\n=== Satellite Infrastructure Complete ===");
        console.log("PoaManager:", address(pm));
        console.log("ImplementationRegistry:", address(reg));
        console.log("PoaManagerSatellite:", address(satellite));
        console.log("\nNext: Register this satellite on the Hub:");
        console.log("  hub.registerSatellite(<this_chain_domain>, ", address(satellite), ")");
    }

    function _deployImplementations(DeterministicDeployer dd) internal {
        // Each implementation is deployed via CREATE3 with a standardized salt.
        // If the implementation already exists at the predicted address, skip it.
        _deployIfNeeded(dd, "HybridVoting", "v1", type(HybridVoting).creationCode);
        _deployIfNeeded(dd, "DirectDemocracyVoting", "v1", type(DirectDemocracyVoting).creationCode);
        _deployIfNeeded(dd, "Executor", "v1", type(Executor).creationCode);
        _deployIfNeeded(dd, "QuickJoin", "v1", type(QuickJoin).creationCode);
        _deployIfNeeded(dd, "ParticipationToken", "v1", type(ParticipationToken).creationCode);
        _deployIfNeeded(dd, "TaskManager", "v1", type(TaskManager).creationCode);
        _deployIfNeeded(dd, "EducationHub", "v1", type(EducationHub).creationCode);
        _deployIfNeeded(dd, "PaymentManager", "v1", type(PaymentManager).creationCode);
        _deployIfNeeded(dd, "UniversalAccountRegistry", "v1", type(UniversalAccountRegistry).creationCode);
        _deployIfNeeded(dd, "EligibilityModule", "v1", type(EligibilityModule).creationCode);
        _deployIfNeeded(dd, "ToggleModule", "v1", type(ToggleModule).creationCode);
        _deployIfNeeded(dd, "PasskeyAccount", "v1", type(PasskeyAccount).creationCode);
        _deployIfNeeded(dd, "PasskeyAccountFactory", "v1", type(PasskeyAccountFactory).creationCode);
        _deployIfNeeded(dd, "ZkEmailInvites", "v1", type(ZkEmailInvites).creationCode);
    }

    function _deployIfNeeded(DeterministicDeployer dd, string memory typeName, string memory version, bytes memory code)
        internal
    {
        bytes32 salt = dd.computeSalt(typeName, version);
        address predicted = dd.computeAddress(salt);

        if (predicted.code.length > 0) {
            console.log("  Already deployed:", typeName, "at", predicted);
            return;
        }

        address deployed = dd.deploy(salt, code);
        console.log("  Deployed:", typeName, "at", deployed);
    }

    function _registerContractTypes(PoaManager pm, DeterministicDeployer dd) internal {
        _registerType(pm, dd, "HybridVoting", "v1");
        _registerType(pm, dd, "DirectDemocracyVoting", "v1");
        _registerType(pm, dd, "Executor", "v1");
        _registerType(pm, dd, "QuickJoin", "v1");
        _registerType(pm, dd, "ParticipationToken", "v1");
        _registerType(pm, dd, "TaskManager", "v1");
        _registerType(pm, dd, "EducationHub", "v1");
        _registerType(pm, dd, "PaymentManager", "v1");
        _registerType(pm, dd, "UniversalAccountRegistry", "v1");
        _registerType(pm, dd, "EligibilityModule", "v1");
        _registerType(pm, dd, "ToggleModule", "v1");
        _registerType(pm, dd, "PasskeyAccount", "v1");
        _registerType(pm, dd, "PasskeyAccountFactory", "v1");
        // ZkEmailInvites beacon registered unconditionally; the per-org module stays dormant
        // until OrgDeployer.setZkEmailInfrastructure wires the verifier + DKIM registry.
        _registerType(pm, dd, "ZkEmailInvites", "v1");
    }

    function _registerType(PoaManager pm, DeterministicDeployer dd, string memory typeName, string memory version)
        internal
    {
        bytes32 salt = dd.computeSalt(typeName, version);
        address impl = dd.computeAddress(salt);
        pm.addContractType(typeName, impl);
    }
}
