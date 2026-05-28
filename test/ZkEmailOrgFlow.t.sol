// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @title ZkEmailOrgFlow.t.sol
/// @notice End-to-end integration test for ZkEmailInvites wiring through OrgDeployer.
/// @dev Inherits DeployerTest's setUp so we get the full infra (PoaManager, factories,
///      PaymasterHub, PasskeyFactory, OrgRegistry, real Hats Protocol fork). On top of
///      that we register the ZkEmailInvites contract type, wire mock Verifier + DKIMRegistry
///      via setZkEmailInfrastructure, deploy a new org, and assert every wiring point.

import "forge-std/Test.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import {DeployerTest} from "./DeployerTest.t.sol";

import {ZkEmailInvites} from "../src/ZkEmailInvites.sol";
import {EmailProof, IVerifier} from "../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../src/zkemail/IDKIMRegistry.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../src/OrgDeployer.sol";
import {ModulesFactory} from "../src/factories/ModulesFactory.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {RoleConfigStructs} from "../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../src/libs/ModuleDeploymentLib.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";

/*──────────────────────────────  Mocks  ──────────────────────────────*/

contract MockEmailVerifier is IVerifier {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function commandBytes() external pure returns (uint256) {
        return 605;
    }

    function verifyEmailProof(EmailProof memory) external view returns (bool) {
        return result;
    }
}

contract MockEmailDKIMRegistry is IDKIMRegistry {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function isKeyHashValid(bytes32, bytes32) external view returns (bool) {
        return result;
    }
}

/*──────────────────────────  Tests  ──────────────────────────*/

contract ZkEmailOrgFlowTest is DeployerTest {
    MockEmailVerifier mockVerifier;
    MockEmailDKIMRegistry mockDkim;

    bytes32 constant ZK_ORG_ID = keccak256("ZKEMAIL-TEST-ORG");

    function setUp() public override {
        super.setUp();

        // Mock infra so the verifier always returns true and the DKIM registry accepts any key.
        mockVerifier = new MockEmailVerifier();
        mockDkim = new MockEmailDKIMRegistry();
        // NOTE: the ZkEmailInvites beacon is intentionally NOT registered here. Tests that
        // expect the module to deploy call `_registerZkBeacon()` explicitly (mirroring the
        // canonical infra-deploy step). The beacon-missing path leaves it unregistered.
    }

    /// @dev Registers the ZkEmailInvites beacon on PoaManager — the protocol-level prerequisite
    ///      that DeployHelper._contractTypes()/DeployInfrastructure perform on a real chain.
    function _registerZkBeacon() internal {
        ZkEmailInvites zkImpl = new ZkEmailInvites();
        vm.prank(poaAdmin);
        poaManager.addContractType("ZkEmailInvites", address(zkImpl));
    }

    /*──────────── Infra setter ────────────*/

    function testSetZkEmailInfrastructure_onlyPoaManager() public {
        vm.expectRevert(); // InvalidAddress (not from poaManager)
        deployer.setZkEmailInfrastructure(address(mockVerifier), address(mockDkim));
    }

    function testSetZkEmailInfrastructure_setsBothFields() public {
        // Wire infra via PoaManager.adminCall
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature(
                "setZkEmailInfrastructure(address,address)", address(mockVerifier), address(mockDkim)
            )
        );

        // Read via raw storage probe — OrgDeployer Layout slot.
        bytes32 layoutSlot = keccak256("poa.orgdeployer.storage");
        // Layout fields used by ZkEmail are after the original 10 fields:
        //   [0] GovernanceFactory governanceFactory
        //   [1] AccessFactory accessFactory
        //   [2] ModulesFactory modulesFactory
        //   [3] OrgRegistry orgRegistry
        //   [4] address poaManager
        //   [5] address hatsTreeSetup
        //   [6] address paymasterHub
        //   [7] address universalPasskeyFactory
        //   [8] uint256 _status
        //   [9] IHats hatsV2
        //   [10] address zkEmailVerifier  ← target
        //   [11] address zkEmailDkimRegistry  ← target
        bytes32 verifierSlot = bytes32(uint256(layoutSlot) + 10);
        bytes32 dkimSlot = bytes32(uint256(layoutSlot) + 11);
        address storedVerifier = address(uint160(uint256(vm.load(address(deployer), verifierSlot))));
        address storedDkim = address(uint160(uint256(vm.load(address(deployer), dkimSlot))));
        assertEq(storedVerifier, address(mockVerifier), "verifier slot");
        assertEq(storedDkim, address(mockDkim), "dkim slot");
    }

    /*──────────── Conditional deployment ────────────*/

    function testOrgDeploy_withoutInfra_skipsZkEmailModule() public {
        // Verify infra is NOT wired (we don't call setZkEmailInfrastructure)
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);
        assertEq(result.zkEmailInvites, address(0), "ZkEmailInvites should be skipped");

        // OrgRegistry should revert with ContractUnknown when querying for an unregistered module.
        vm.expectRevert(); // ContractUnknown()
        orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.ZKEMAIL_INVITES_ID);
    }

    function testOrgDeploy_withInfra_deploysAndWiresZkEmailModule() public {
        _registerZkBeacon();
        _wireZkInfra();

        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        // 1. ZkEmailInvites was deployed
        assertTrue(result.zkEmailInvites != address(0), "ZkEmailInvites deployed");

        // 2. ZkEmailInvites is registered in OrgRegistry
        address registered = orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.ZKEMAIL_INVITES_ID);
        assertEq(registered, result.zkEmailInvites, "registered in OrgRegistry");

        // 3. ZkEmailInvites was initialized with the right dependencies
        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);
        assertEq(zk.executor(), result.executor, "executor wired");
        assertEq(address(zk.verifier()), address(mockVerifier), "verifier wired");
        assertEq(address(zk.dkimRegistry()), address(mockDkim), "dkim wired");
        assertEq(address(zk.accountRegistry()), accountRegProxy, "account registry wired");
        assertEq(address(zk.universalFactory()), address(universalPasskeyFactory), "factory wired");
    }

    function testOrgDeploy_withInfra_butEducationDisabled_stillDeploysZkEmail() public {
        // Covers the registration-count combination not exercised elsewhere:
        // {edu = false, zk = true} — TaskManager + PaymentManager + ZkEmailInvites = 3 entries
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrgInner(ZK_ORG_ID, false, false);
        assertTrue(result.zkEmailInvites != address(0), "ZkEmailInvites deployed without edu hub");
        assertEq(result.educationHub, address(0), "EducationHub not deployed");

        // Both module types are queryable from OrgRegistry
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.TASK_MANAGER_ID), result.taskManager);
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.PAYMENT_MANAGER_ID), result.paymentManager);
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.ZKEMAIL_INVITES_ID), result.zkEmailInvites);
    }

    function testSetZkEmailInfrastructure_partialUpdatePreservesOtherField() public {
        address oldDkim = address(0xD1);
        address oldVerifier = address(0xCAFE);

        // Wire both initially
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setZkEmailInfrastructure(address,address)", oldVerifier, oldDkim)
        );

        // Update only the verifier (pass address(0) for dkim → no-op for that field)
        address newVerifier = address(mockVerifier);
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setZkEmailInfrastructure(address,address)", newVerifier, address(0))
        );

        bytes32 layoutSlot = keccak256("poa.orgdeployer.storage");
        address storedVerifier =
            address(uint160(uint256(vm.load(address(deployer), bytes32(uint256(layoutSlot) + 10)))));
        address storedDkim = address(uint160(uint256(vm.load(address(deployer), bytes32(uint256(layoutSlot) + 11)))));
        assertEq(storedVerifier, newVerifier, "verifier was updated");
        assertEq(storedDkim, oldDkim, "dkim preserved (passed address(0) is a no-op)");
    }

    function testSetZkEmailInfrastructure_onlyOneAddressSet_doesNotEnableModule() public {
        // Beacon present so the ONLY missing prerequisite under test is the second infra address.
        _registerZkBeacon();
        // Set verifier only; dkim stays unset. Module should still be skipped because the
        // ModulesFactory gate requires BOTH (+ accountRegistry).
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setZkEmailInfrastructure(address,address)", address(mockVerifier), address(0))
        );

        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);
        assertEq(result.zkEmailInvites, address(0), "Module should remain disabled with only one address");
    }

    /// @notice Regression test for the reported coupling bug: enabling ZK Email infra WITHOUT a
    ///         registered ZkEmailInvites beacon must NOT brick org deployment. Before the fix,
    ///         ModulesFactory called BeaconDeploymentLib.createBeacon -> getBeaconById, which
    ///         reverts TypeUnknown, failing the entire deployFullOrg. Now the gate probes
    ///         beaconRegistered() and degrades gracefully.
    function testOrgDeploy_infraWiredButBeaconMissing_skipsGracefully() public {
        // Wire infra but DELIBERATELY do not register the beacon.
        _wireZkInfra();

        // Must NOT revert — core deploy proceeds, ZK module is skipped.
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        assertEq(result.zkEmailInvites, address(0), "module skipped when beacon missing");
        // Core modules unaffected.
        assertTrue(result.executor != address(0), "executor deployed");
        assertTrue(result.taskManager != address(0), "task manager deployed");
        assertTrue(result.quickJoin != address(0), "quick join deployed");
        // OrgRegistry has no ZkEmailInvites entry.
        vm.expectRevert(); // ContractUnknown()
        orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.ZKEMAIL_INVITES_ID);
    }

    /// @notice Once the beacon is registered (the missing step from the bug report), the SAME
    ///         infra wiring now activates the module — proving the gate self-heals.
    function testOrgDeploy_beaconRegisteredAfterInfra_activatesModule() public {
        _wireZkInfra();
        _registerZkBeacon(); // beacon registered AFTER infra wiring — order-independent

        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);
        assertTrue(result.zkEmailInvites != address(0), "module activates once beacon present");
    }

    /*──────────── Hat-minter authorization ────────────*/

    function testZkEmailInvites_isAuthorizedHatMinterOnExecutor() public {
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        // Probe Executor's authorizedHatMinters mapping via storage.
        // Executor layout: { allowedCaller, hats, authorizedHatMinters, pendingCaller, callerChangeTimestamp }
        // authorizedHatMinters is the 3rd field (mapping). Mapping slot = baseSlot + 2.
        bytes32 execLayoutSlot = keccak256("poa.executor.storage");
        bytes32 mappingBase = bytes32(uint256(execLayoutSlot) + 2);
        bytes32 entrySlot = keccak256(abi.encode(result.zkEmailInvites, mappingBase));
        bool authorized = uint256(vm.load(result.executor, entrySlot)) != 0;
        assertTrue(authorized, "ZkEmailInvites must be authorized hat minter");
    }

    /*──────────── End-to-end claim ────────────*/

    function testEndToEndClaimByDomain_mintsHatViaExecutor() public {
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);

        // Pre-register a domain rule via the executor (orgOwner holds the toggle hat by virtue of
        // owning the top hat; in our tests setHatMinterAuthorization is gated on the executor's
        // allowed caller, but setDomainRule is gated on _msgSender() == executor address).
        // We prank as the executor contract address itself.
        uint256 targetHat = orgRegistry.getRoleHat(ZK_ORG_ID, 0); // DEFAULT role hat
        assertTrue(targetHat != 0, "default role hat exists");

        uint256[] memory hats = new uint256[](1);
        hats[0] = targetHat;

        vm.prank(result.executor);
        zk.setDomainRule("anthropic.com", hats, 0);

        // Build a proof addressed to a fresh claimer
        address claimer = address(0xC0FFEE);
        EmailProof memory p = _buildProof(claimer, "anthropic.com", bytes32(uint256(0xBEEF)));

        // Claim
        vm.prank(claimer);
        zk.claimRoleByDomain(p, claimer);

        // Confirm the claimer wears the hat now
        bool isWearer = IHats(SEPOLIA_HATS).isWearerOfHat(claimer, targetHat);
        assertTrue(isWearer, "claimer wears the role hat");

        // Nullifier was consumed
        assertTrue(zk.isNullifierUsed(p.emailNullifier), "nullifier consumed");
    }

    /*──────────── Paymaster auto-whitelist ────────────*/

    function testPaymasterRules_includeZkEmailSelectors_whenInfraWired() public {
        _registerZkBeacon();
        _wireZkInfra();

        // Deploy with autoWhitelistContracts = true and assert that all 4 ZkEmailInvites selectors
        // are now allowed rules on PaymasterHub for our org.
        OrgDeployer.DeploymentResult memory result = _deployZkOrgWithPaymaster(ZK_ORG_ID);

        bytes4 sel1 =
            bytes4(keccak256("claimRoleByDomain((string,bytes32,uint256,string,bytes32,bytes32,bool,bytes),address)"));
        bytes4 sel2 =
            bytes4(keccak256("claimRoleByEmail((string,bytes32,uint256,string,bytes32,bytes32,bool,bytes),address)"));
        bytes4 sel3 = bytes4(
            keccak256(
                "registerAndClaimByDomainWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(string,bytes32,uint256,string,bytes32,bytes32,bool,bytes))"
            )
        );
        bytes4 sel4 = bytes4(
            keccak256(
                "registerAndClaimByEmailWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(string,bytes32,uint256,string,bytes32,bytes32,bool,bytes))"
            )
        );

        PaymasterHub.Rule memory r1 = paymasterHub.getRule(ZK_ORG_ID, result.zkEmailInvites, sel1);
        PaymasterHub.Rule memory r2 = paymasterHub.getRule(ZK_ORG_ID, result.zkEmailInvites, sel2);
        PaymasterHub.Rule memory r3 = paymasterHub.getRule(ZK_ORG_ID, result.zkEmailInvites, sel3);
        PaymasterHub.Rule memory r4 = paymasterHub.getRule(ZK_ORG_ID, result.zkEmailInvites, sel4);

        assertTrue(r1.allowed, "claimRoleByDomain allowed");
        assertTrue(r2.allowed, "claimRoleByEmail allowed");
        assertTrue(r3.allowed, "registerAndClaimByDomainWithPasskey allowed");
        assertTrue(r4.allowed, "registerAndClaimByEmailWithPasskey allowed");

        assertEq(uint256(r1.maxCallGasHint), 800_000, "bare claim gas hint");
        assertEq(uint256(r2.maxCallGasHint), 800_000, "bare claim gas hint");
        assertEq(uint256(r3.maxCallGasHint), 1_200_000, "combined claim gas hint");
        assertEq(uint256(r4.maxCallGasHint), 1_200_000, "combined claim gas hint");
    }

    function testPaymasterRules_unaffected_whenInfraNotWired() public {
        // Without infra wiring: paymaster rules should still work; ZkEmailInvites selectors absent.
        OrgDeployer.DeploymentResult memory result = _deployZkOrgWithPaymaster(ZK_ORG_ID);
        assertEq(result.zkEmailInvites, address(0), "ZkEmailInvites not deployed");

        // Even if we query for the selectors, they should be unset (allowed=false, cap=0).
        bytes4 sel1 =
            bytes4(keccak256("claimRoleByDomain((string,bytes32,uint256,string,bytes32,bytes32,bool,bytes),address)"));
        PaymasterHub.Rule memory r1 = paymasterHub.getRule(ZK_ORG_ID, address(0), sel1);
        assertFalse(r1.allowed, "no rule for address(0)");
        assertEq(uint256(r1.maxCallGasHint), 0, "no gas hint");
    }

    /*──────────── Helpers ────────────*/

    function _wireZkInfra() internal {
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature(
                "setZkEmailInfrastructure(address,address)", address(mockVerifier), address(mockDkim)
            )
        );
    }

    function _deployZkOrg(bytes32 orgId) internal returns (OrgDeployer.DeploymentResult memory) {
        return _deployZkOrgInner(orgId, false, true);
    }

    function _deployZkOrgWithPaymaster(bytes32 orgId) internal returns (OrgDeployer.DeploymentResult memory) {
        return _deployZkOrgInner(orgId, true, true);
    }

    function _deployZkOrgInner(bytes32 orgId, bool autoWhitelist, bool enableEducation)
        internal
        returns (OrgDeployer.DeploymentResult memory)
    {
        vm.startPrank(orgOwner);
        string[] memory names = new string[](2);
        names[0] = "DEFAULT";
        names[1] = "EXECUTIVE";
        string[] memory images = new string[](2);
        images[0] = "ipfs://default-role-image";
        images[1] = "ipfs://executive-role-image";
        bool[] memory voting = new bool[](2);
        voting[0] = true;
        voting[1] = true;

        IHybridVotingInit.ClassConfig[] memory classes = _buildLegacyClasses(50, 50, false, 4 ether);

        OrgDeployer.PaymasterConfig memory pmCfg;
        if (autoWhitelist) {
            pmCfg = OrgDeployer.PaymasterConfig({
                operatorRoleIndex: type(uint256).max,
                autoWhitelistContracts: true,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                maxCallGas: 0,
                maxVerificationGas: 0,
                maxPreVerificationGas: 0,
                defaultBudgetCapPerEpoch: 0,
                defaultBudgetEpochLen: 0
            });
        } else {
            pmCfg = _defaultPaymasterConfig();
        }

        OrgDeployer.DeploymentParams memory params = OrgDeployer.DeploymentParams({
            orgId: orgId,
            orgName: "ZkEmail DAO",
            metadataHash: bytes32(0),
            registryAddr: accountRegProxy,
            deployerAddress: orgOwner,
            deployerUsername: "",
            regDeadline: 0,
            regNonce: 0,
            regSignature: "",
            autoUpgrade: true,
            hybridThresholdPct: 50,
            ddThresholdPct: 50,
            hybridClasses: classes,
            ddInitialTargets: new address[](0),
            roles: _buildSimpleRoleConfigs(names, images, voting),
            roleAssignments: _buildDefaultRoleAssignments(),
            metadataAdminRoleIndex: type(uint256).max,
            passkeyEnabled: false,
            educationHubConfig: ModulesFactory.EducationHubConfig({enabled: enableEducation}),
            bootstrap: _emptyBootstrap(),
            paymasterConfig: pmCfg
        });

        OrgDeployer.DeploymentResult memory result = deployer.deployFullOrg(params);
        vm.stopPrank();
        return result;
    }

    function _buildProof(address claimer, string memory domain, bytes32 nullifier)
        internal
        view
        returns (EmailProof memory p)
    {
        p.domainName = domain;
        p.publicKeyHash = bytes32(uint256(0xAA));
        p.timestamp = block.timestamp;
        p.maskedCommand = string.concat("Claim POP role for ", _addrToHex(claimer));
        p.emailNullifier = nullifier;
        p.accountSalt = bytes32(uint256(uint160(claimer)));
        p.isCodeExist = true;
        p.proof = hex"deadbeef";
    }

    function _addrToHex(address a) internal pure returns (string memory out) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint256 v = uint256(uint160(a));
        for (uint256 i = 0; i < 40; ++i) {
            s[41 - i] = alphabet[v & 0xf];
            v >>= 4;
        }
        out = string(s);
    }
}
