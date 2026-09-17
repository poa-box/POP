// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
import {MembershipAuthority} from "../../src/MembershipAuthority.sol";
import {AuthorityRouter} from "../../src/AuthorityRouter.sol";
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

    /// @notice Canonical list of the 15 application contract types.
    ///         Infrastructure types (ImplementationRegistry, OrgRegistry,
    ///         OrgDeployer, PaymasterHub, AuthorityRouter) are handled separately because they
    ///         require special initialization (beacon proxies, ownership, etc.).
    /// @dev    ZkEmailInvites is registered here so its beacon exists on every chain.
    ///         The module only *activates* once OrgDeployer.setZkEmailInfrastructure wires the
    ///         verifier + DKIM registry; until then the per-org gate in ModulesFactory skips it.
    ///         Registering the beacon unconditionally costs one extra impl deploy but removes the
    ///         ordering hazard where enabling infra before the beacon would brick org deploys.
    /// @dev    MembershipAuthority is MANDATORY for Access v2: `AccessFactory.deployAuthority`
    ///         resolves `MEMBERSHIP_AUTHORITY_ID` off the PoaManager, so every org deploy reverts
    ///         on a chain where this type was never registered.
    function _contractTypes() internal pure returns (ContractType[] memory types) {
        types = new ContractType[](15);
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
        types[14] = ContractType("MembershipAuthority", type(MembershipAuthority).creationCode);
    }

    /// @notice Infrastructure contract types that need beacon registration for cross-chain upgrades.
    ///         Handled separately from application types because they require special initialization.
    /// @dev    AuthorityRouter's registration is PROVENANCE only — the router singleton is an
    ///         ERC1967Proxy, not a BeaconProxy, so its beacon never mints instances (same convention
    ///         as the live-chain ceremony, script/accessv2/RegisterAccessV2Protocol.s.sol).
    function _infraContractTypes() internal pure returns (ContractType[] memory types) {
        types = new ContractType[](4);
        types[0] = ContractType("OrgRegistry", type(OrgRegistry).creationCode);
        types[1] = ContractType("OrgDeployer", type(OrgDeployer).creationCode);
        types[2] = ContractType("PaymasterHub", type(PaymasterHub).creationCode);
        types[3] = ContractType("AuthorityRouter", type(AuthorityRouter).creationCode);
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

    /// @notice Stand up the chain's AuthorityRouter singleton and repoint every Access-v2 reader at it.
    /// @dev Access v2 orgs carry NEW-STYLE subject ids (`uint160(authority) << 64 | seq`, always
    ///      < 2^224) as their PaymasterHub admin/operator "hats" and as the OrgRegistry metadata-admin
    ///      hat. Real Hats Protocol returns balance 0 for those ids, so without this repoint every
    ///      `onlyOrgAdmin` call (setPause / setOperatorHat / withdrawOrgDeposit) and every
    ///      `updateOrgMetaAsAdmin` call reverts forever on a freshly-deployed chain.
    ///      The router self-routes v2 ids to the embedded authority and passes legacy Hats ids
    ///      straight through, so the repoint is behaviour-neutral for adopted legacy orgs.
    /// @dev ORDERING: `AuthorityRouter.initialize` needs the OrgRegistry *and* PaymasterHub addresses,
    ///      and both of those are deployed before it — the dependency cycle is broken by initializing
    ///      them against real Hats and repointing here (never by leaving the router proxy
    ///      uninitialized, which would open a front-run window on `initialize`).
    /// @param pm The chain's PoaManager (owner of the hub's poaManager gate).
    /// @param routerImpl The AuthorityRouter implementation to put behind the singleton proxy.
    /// @param orgRegistry_ This chain's OrgRegistry proxy — must still be owned by the caller.
    /// @param paymasterHub_ This chain's PaymasterHub proxy.
    /// @param admin_ The router's protocol admin (bind/unbind + pointer maintenance).
    /// @return router The AuthorityRouter singleton (ERC1967Proxy).
    function _wireAuthorityRouter(
        PoaManager pm,
        address routerImpl,
        address orgRegistry_,
        address paymasterHub_,
        address admin_
    ) internal returns (address router) {
        router = address(
            new ERC1967Proxy(
                routerImpl,
                abi.encodeCall(AuthorityRouter.initialize, (HATS_PROTOCOL, orgRegistry_, paymasterHub_, admin_))
            )
        );
        pm.adminCall(paymasterHub_, abi.encodeWithSignature("setHats(address)", router));
        OrgRegistry(orgRegistry_).setHats(router);
        console.log("AuthorityRouter:", router);
        console.log("  PaymasterHub + OrgRegistry repointed to the router");
    }
}
