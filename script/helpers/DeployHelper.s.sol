// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Implementation contracts — single source of truth for the 13 application types
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
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";

import {PoaManager} from "../../src/PoaManager.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/**
 * @title DeployHelper
 * @notice Shared base for deployment scripts. Defines the canonical list of
 *         application contract types and provides helpers for deploying and
 *         registering them on a PoaManager — either directly (home chain)
 *         or via DeterministicDeployer (satellite chains).
 *
 *         To add a new contract type, update `_contractTypes()` below.
 */
abstract contract DeployHelper is Script {
    struct ContractType {
        string name;
        bytes creationCode;
    }

    address public constant HATS_PROTOCOL = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address public constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant POA_GUARDIAN = address(0);
    uint256 public constant INITIAL_SOLIDARITY_FUND = 0.005 ether;

    /// @notice Canonical list of the 14 application contract types.
    ///         Infrastructure types (ImplementationRegistry, OrgRegistry,
    ///         OrgDeployer, PaymasterHub) are handled separately because they
    ///         require special initialization (beacon proxies, ownership, etc.).
    /// @dev    ZkEmailInvites is registered here so its beacon exists on every chain.
    ///         The module only *activates* once OrgDeployer.setZkEmailInfrastructure wires the
    ///         verifier + DKIM registry; until then the per-org gate in ModulesFactory skips it.
    ///         Registering the beacon unconditionally costs one extra impl deploy but removes the
    ///         ordering hazard where enabling infra before the beacon would brick org deploys.
    function _contractTypes() internal pure returns (ContractType[] memory types) {
        types = new ContractType[](14);
        types[0] = ContractType("HybridVoting", type(HybridVoting).creationCode);
        types[1] = ContractType("DirectDemocracyVoting", type(DirectDemocracyVoting).creationCode);
        types[2] = ContractType("Executor", type(Executor).creationCode);
        types[3] = ContractType("QuickJoin", type(QuickJoin).creationCode);
        types[4] = ContractType("ParticipationToken", type(ParticipationToken).creationCode);
        types[5] = ContractType("TaskManager", type(TaskManager).creationCode);
        types[6] = ContractType("EducationHub", type(EducationHub).creationCode);
        types[7] = ContractType("PaymentManager", type(PaymentManager).creationCode);
        types[8] = ContractType("UniversalAccountRegistry", type(UniversalAccountRegistry).creationCode);
        types[9] = ContractType("EligibilityModule", type(EligibilityModule).creationCode);
        types[10] = ContractType("ToggleModule", type(ToggleModule).creationCode);
        types[11] = ContractType("PasskeyAccount", type(PasskeyAccount).creationCode);
        types[12] = ContractType("PasskeyAccountFactory", type(PasskeyAccountFactory).creationCode);
        types[13] = ContractType("ZkEmailInvites", type(ZkEmailInvites).creationCode);
    }

    /// @notice Infrastructure contract types that need beacon registration for cross-chain upgrades.
    ///         Handled separately from application types because they require special initialization.
    function _infraContractTypes() internal pure returns (ContractType[] memory types) {
        types = new ContractType[](3);
        types[0] = ContractType("OrgRegistry", type(OrgRegistry).creationCode);
        types[1] = ContractType("OrgDeployer", type(OrgDeployer).creationCode);
        types[2] = ContractType("PaymasterHub", type(PaymasterHub).creationCode);
    }

    /// @notice Deploy all application types directly and register on PoaManager (home chain).
    function _deployAndRegisterTypes(PoaManager pm) internal {
        ContractType[] memory types = _contractTypes();
        for (uint256 i = 0; i < types.length; i++) {
            bytes memory code = types[i].creationCode;
            address impl;
            assembly {
                impl := create(0, add(code, 0x20), mload(code))
            }
            require(impl != address(0), "Implementation deployment failed");
            pm.addContractType(types[i].name, impl);
        }
        console.log("Contract types registered:", types.length);
    }

    /// @notice Deploy all application types via DeterministicDeployer and register on PoaManager (satellite).
    function _deployAndRegisterTypesDD(PoaManager pm, DeterministicDeployer dd) internal {
        ContractType[] memory types = _contractTypes();
        for (uint256 i = 0; i < types.length; i++) {
            bytes32 salt = dd.computeSalt(types[i].name, "v3");
            address predicted = dd.computeAddress(salt);
            if (predicted.code.length == 0) {
                dd.deploy(salt, types[i].creationCode);
                console.log("  Deployed:", types[i].name);
            } else {
                console.log("  Already deployed:", types[i].name);
            }
            pm.addContractType(types[i].name, predicted);
        }
    }

    /// @notice Deploy infrastructure types via DeterministicDeployer and register on PoaManager (satellite).
    function _deployAndRegisterInfraTypesDD(PoaManager pm, DeterministicDeployer dd) internal {
        ContractType[] memory types = _infraContractTypes();
        for (uint256 i = 0; i < types.length; i++) {
            bytes32 salt = dd.computeSalt(types[i].name, "v3");
            address predicted = dd.computeAddress(salt);
            if (predicted.code.length == 0) {
                dd.deploy(salt, types[i].creationCode);
                console.log("  Deployed infra:", types[i].name);
            } else {
                console.log("  Already deployed infra:", types[i].name);
            }
            pm.addContractType(types[i].name, predicted);
        }
    }
}
