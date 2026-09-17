// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @title ZkEmailOrgFlow.t.sol
/// @notice End-to-end integration test for ZkEmailInvites wiring through OrgDeployer.
/// @dev Inherits DeployerTest's setUp so we get the full infra (PoaManager, factories,
///      PaymasterHub, PasskeyFactory, OrgRegistry, real Hats Protocol fork). On top of
///      that we register the ZkEmailInvites contract type, wire BOTH mock verifiers (domain +
///      email) + DKIMRegistry via setZkEmailInfrastructure, deploy a new org DORMANT, then
///      activate a merkle allowlist via the executor and assert a real claim mints the org hat.
///
///      Reworked for the merkle-allowlist surface: two Groth16 verifier seams (3-signal domain
///      `verifyProof(...,uint256[3])` and 4-signal email `verifyProof(...,uint256[4])`, both mocked
///      to return true), proofs are `ZkEmailProof` / `ZkEmailProofV2` structs, and the allowlist is a
///      single merkle root committed via `setActiveAllowlist`. Claims supply a merkle proof per entry.

import "forge-std/Test.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import {DeployerTest} from "./DeployerTest.t.sol";

import {ZkEmailInvites} from "../src/ZkEmailInvites.sol";
import {
    IZkEmailGroth16Verifier,
    IZkEmailGroth16VerifierV2,
    ZkEmailProof,
    ZkEmailProofV2
} from "../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../src/zkemail/IDKIMRegistry.sol";

import {OrgDeployer, ITaskManagerBootstrap} from "../src/OrgDeployer.sol";
import {ModulesFactory} from "../src/factories/ModulesFactory.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {RoleConfigStructs} from "../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../src/libs/ModuleDeploymentLib.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubLens} from "../src/PaymasterHubLens.sol";

/*──────────────────────────────  Mocks  ──────────────────────────────*/

/// @notice Domain Groth16 verifier stub (4 signals) that always verifies. Lets the org-flow test
///         exercise a real domain claim end-to-end without a genuine proof.
contract MockZkEmailDomainVerifier is IZkEmailGroth16Verifier {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

/// @notice Email Groth16 verifier stub (5 signals) that always verifies.
contract MockZkEmailEmailVerifier is IZkEmailGroth16VerifierV2 {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

/// @notice DKIM registry stub. `isKeyHashValid` returns true for any (domainHash, keyHash) so the
///         chosen test domain + the proof's pubkeyHash always bind.
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
    MockZkEmailDomainVerifier mockDomainVerifier;
    MockZkEmailEmailVerifier mockEmailVerifier;
    MockEmailDKIMRegistry mockDkim;

    bytes32 constant ZK_ORG_ID = keccak256("ZKEMAIL-TEST-ORG");

    // Proof fixture constants.
    bytes32 constant KEY_HASH = bytes32(uint256(0xAA));
    bytes32 constant CID = bytes32(uint256(0xC1D));

    uint8 constant LEAF_DOMAIN = 0;
    uint8 constant LEAF_EMAIL = 1;

    function setUp() public override {
        super.setUp();

        // Mock infra so both verifiers always return true and the DKIM registry accepts any key.
        mockDomainVerifier = new MockZkEmailDomainVerifier();
        mockEmailVerifier = new MockZkEmailEmailVerifier();
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

    /*──────────── Merkle helpers ────────────*/

    /// @dev OZ StandardMerkleTree leaf (mirrors ZkEmailInvites._leaf).
    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /*──────────── Infra setter ────────────*/

    function testSetZkEmailInfrastructure_onlyPoaManager() public {
        vm.expectRevert(); // InvalidAddress (not from poaManager)
        deployer.setZkEmailInfrastructure(address(mockDomainVerifier), address(mockEmailVerifier), address(mockDkim));
    }

    function testSetZkEmailInfrastructure_setsAllThreeFields() public {
        // Wire infra via PoaManager.adminCall
        _wireZkInfra();

        // Read via raw storage probe — OrgDeployer Layout slot.
        bytes32 layoutSlot = keccak256("poa.orgdeployer.storage");
        // Layout fields used by ZkEmail are after the original 10 fields:
        //   [0..9]  original fields (factories, registries, status, hatsV2)
        //   [10] address zkEmailDomainVerifier  ← target
        //   [11] address zkEmailEmailVerifier   ← target
        //   [12] address zkEmailDkimRegistry    ← target
        address storedDomain = _readDeployerSlot(layoutSlot, 10);
        address storedEmail = _readDeployerSlot(layoutSlot, 11);
        address storedDkim = _readDeployerSlot(layoutSlot, 12);
        assertEq(storedDomain, address(mockDomainVerifier), "domain verifier slot");
        assertEq(storedEmail, address(mockEmailVerifier), "email verifier slot");
        assertEq(storedDkim, address(mockDkim), "dkim slot");
    }

    function testSetZkEmailInfrastructure_partialUpdatePreservesOtherFields() public {
        address oldDomain = address(0xCAFE);
        address oldEmail = address(0xEEEE);
        address oldDkim = address(0xD1);

        // Wire all three initially
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature("setZkEmailInfrastructure(address,address,address)", oldDomain, oldEmail, oldDkim)
        );

        // Update only the domain verifier (pass address(0) for the others → no-op for those fields)
        address newDomain = address(mockDomainVerifier);
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature(
                "setZkEmailInfrastructure(address,address,address)", newDomain, address(0), address(0)
            )
        );

        bytes32 layoutSlot = keccak256("poa.orgdeployer.storage");
        assertEq(_readDeployerSlot(layoutSlot, 10), newDomain, "domain verifier updated");
        assertEq(_readDeployerSlot(layoutSlot, 11), oldEmail, "email verifier preserved (address(0) no-op)");
        assertEq(_readDeployerSlot(layoutSlot, 12), oldDkim, "dkim preserved (address(0) no-op)");
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

        // 3. ZkEmailInvites was initialized with the right dependencies (both verifiers)
        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);
        assertEq(zk.executor(), result.executor, "executor wired");
        assertEq(address(zk.domainVerifier()), address(mockDomainVerifier), "domain verifier wired");
        assertEq(address(zk.emailVerifier()), address(mockEmailVerifier), "email verifier wired");
        assertEq(address(zk.dkimRegistry()), address(mockDkim), "dkim wired");
        assertEq(address(zk.accountRegistry()), accountRegProxy, "account registry wired");
        assertEq(address(zk.universalFactory()), address(universalPasskeyFactory), "factory wired");

        // 4. Deployed DORMANT (no initial root) — every claim reverts AllowlistNotActive until activated.
        assertEq(zk.merkleRoot(), bytes32(0), "deployed dormant");
        assertEq(zk.allowlistCid(), bytes32(0), "no cid while dormant");
    }

    function testOrgDeploy_withInfra_butEducationDisabled_stillDeploysZkEmail() public {
        // Covers the registration-count combination not exercised elsewhere:
        // {edu = false, zk = true} — TaskManager + PaymentManager + ZkEmailInvites = 3 entries
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrgInner(ZK_ORG_ID, false, false, _enabledZkConfig());
        assertTrue(result.zkEmailInvites != address(0), "ZkEmailInvites deployed without edu hub");
        assertEq(result.educationHub, address(0), "EducationHub not deployed");

        // Both module types are queryable from OrgRegistry
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.TASK_MANAGER_ID), result.taskManager);
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.PAYMENT_MANAGER_ID), result.paymentManager);
        assertEq(orgRegistry.getOrgContract(ZK_ORG_ID, ModuleTypes.ZKEMAIL_INVITES_ID), result.zkEmailInvites);
    }

    function testSetZkEmailInfrastructure_onlySomeAddressesSet_doesNotEnableModule() public {
        // Beacon present so the ONLY missing prerequisite under test is a second infra address.
        _registerZkBeacon();
        // Set domain verifier only; email verifier + dkim stay unset. Module should still be skipped
        // because the ModulesFactory gate requires BOTH verifiers + dkim + accountRegistry.
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature(
                "setZkEmailInfrastructure(address,address,address)", address(mockDomainVerifier), address(0), address(0)
            )
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

    /*──────────── End-to-end claim (post-deploy activation) ────────────*/

    function testEndToEndClaimByDomain_mintsHatViaExecutor() public {
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);

        // A zk-email invite grants a GATED subject, never an open one (the H-03 gate rejects
        // open-to-everyone subjects — see the reject test). The EXECUTIVE role is deny-by-default;
        // governance grants this claimer an explicit eligibility source on it.
        uint256 targetHat = orgRegistry.getRoleHat(ZK_ORG_ID, 1);
        assertTrue(targetHat != 0, "role subject exists");

        address claimer = address(0xC0FFEE);
        vm.prank(result.executor);
        IMembershipAuthority(result.membershipAuthority).grant(targetHat, claimer, true);

        uint256[] memory hats = new uint256[](1);
        hats[0] = targetHat;

        // Activate a single-leaf domain allowlist via the executor (governance). `setActiveAllowlist`
        // is gated on _msgSender() == executor, so prank as the executor contract address itself.
        bytes32 domainHash = keccak256(bytes("anthropic.com"));
        bytes32 root = _leaf(LEAF_DOMAIN, domainHash, hats);
        vm.prank(result.executor);
        zk.setActiveAllowlist(root, CID);

        // Build a proof addressed to a fresh claimer.
        ZkEmailProof memory p = _buildDomainProof("anthropic.com", bytes32(uint256(0xBEEF)));

        vm.prank(claimer);
        zk.claimRoleByDomain(p, claimer, hats, _emptyProof());

        // Confirm the claimer holds the subject now.
        assertTrue(
            IMembershipAuthority(result.membershipAuthority).isMember(targetHat, claimer), "claimer holds the role"
        );

        // Nullifier was consumed.
        assertTrue(zk.isNullifierUsed(p.emailNullifier), "nullifier consumed");
    }

    /// @notice H-03 parity: an allowlist that grants an OPEN-to-everyone hat (default-eligible for an
    ///         arbitrary address — e.g. the deployer's genesis index-0 role, or ELIGIBILITY_ADMIN on
    ///         live orgs) must be rejected on the claim path. Otherwise anyone in the domain could
    ///         self-mint an administrative hat and escalate to org takeover.
    function testEndToEndClaimByDomain_rejectsOpenHat() public {
        _registerZkBeacon();
        _wireZkInfra();
        OrgDeployer.DeploymentResult memory result = _deployZkOrg(ZK_ORG_ID);

        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);

        // The genesis index-0 role subject is default-ALLOW (open) in the deployer config — an
        // attacker's target. Allowlist it and try to claim: the gate must reject it fail-closed.
        uint256 openHat = orgRegistry.getRoleHat(ZK_ORG_ID, 0);
        assertTrue(openHat != 0, "default role subject exists");

        uint256[] memory hats = new uint256[](1);
        hats[0] = openHat;

        bytes32 domainHash = keccak256(bytes("anthropic.com"));
        bytes32 root = _leaf(LEAF_DOMAIN, domainHash, hats);
        vm.prank(result.executor);
        zk.setActiveAllowlist(root, CID);

        address claimer = address(0xC0FFEE);
        ZkEmailProof memory p = _buildDomainProof("anthropic.com", bytes32(uint256(0xBEEF)));

        vm.prank(claimer);
        vm.expectRevert(abi.encodeWithSignature("HatOpenlyClaimable(uint256)", openHat));
        zk.claimRoleByDomain(p, claimer, hats, _emptyProof());

        // Nothing minted, nullifier NOT consumed — the reject happened before the state write.
        assertFalse(
            IMembershipAuthority(result.membershipAuthority).isMember(openHat, claimer), "nothing granted on reject"
        );
        assertFalse(zk.isNullifierUsed(p.emailNullifier), "nullifier preserved on reject");
    }

    /*──────────── Deploy-time activation (ZkEmailConfig root/cid) end-to-end ────────────*/

    /// @notice An org deployer activates an allowlist AT GENESIS by passing a non-zero
    ///         `initialRoot` + `initialCid` in the deploy params — and a user claims that role via a
    ///         ZK proof with NO post-deploy governance call. The tree is built off-chain over the
    ///         org's genesis hat IDs, so we deploy first to learn the hat, then... rather, the
    ///         realistic flow is post-deploy activation (above). Here we assert the deploy-time
    ///         (root, cid) snapshot flows through to the module storage.
    function testOrgDeploy_withZkConfigRoot_activatesAtGenesis() public {
        _registerZkBeacon();
        _wireZkInfra();

        bytes32 genesisRoot = bytes32(uint256(0xDEADBEEF));
        ModulesFactory.ZkEmailConfig memory cfg =
            ModulesFactory.ZkEmailConfig({enabled: true, initialRoot: genesisRoot, initialCid: CID});

        OrgDeployer.DeploymentResult memory result = _deployZkOrgInner(ZK_ORG_ID, false, true, cfg);
        assertTrue(result.zkEmailInvites != address(0), "module deployed");

        ZkEmailInvites zk = ZkEmailInvites(result.zkEmailInvites);
        assertEq(zk.merkleRoot(), genesisRoot, "deploy-time root activated at genesis");
        assertEq(zk.allowlistCid(), CID, "deploy-time cid set at genesis");
    }

    function testOrgDeploy_zkConfigDisabled_skipsEvenWithInfra() public {
        _registerZkBeacon();
        _wireZkInfra();

        ModulesFactory.ZkEmailConfig memory disabled; // enabled defaults to false
        OrgDeployer.DeploymentResult memory result = _deployZkOrgInner(ZK_ORG_ID, false, true, disabled);
        assertEq(result.zkEmailInvites, address(0), "enabled=false skips module even with infra + beacon");
    }

    /*──────────── Paymaster auto-whitelist ────────────*/

    function testPaymasterRules_includeZkEmailSelectors_whenInfraWired() public {
        _registerZkBeacon();
        _wireZkInfra();

        // Deploy with autoWhitelistContracts = true and assert that all FOUR ZkEmailInvites claim
        // selectors resolve as allowed for our org via the global rulebook (the module gets the
        // ZKEMAIL_INVITES_ID target type at deploy; selector entries live in DefaultGlobalRules).
        OrgDeployer.DeploymentResult memory result = _deployZkOrgWithPaymaster(ZK_ORG_ID);
        assertEq(
            paymasterHub.getTargetType(ZK_ORG_ID, result.zkEmailInvites),
            ModuleTypes.ZKEMAIL_INVITES_ID,
            "zkEmailInvites target type registered at deploy"
        );
        _seedGlobalRulebook();

        // These selectors are derived from the ABI by the compiler — NOT hand-hashed strings.
        // That independence is the whole point: the previous version copied the deployer's
        // signature strings verbatim, so it stayed green through the Blocker-2 domain-binding
        // change that moved every claim selector (issue #188). Never reintroduce a literal here.
        bytes4 selClaimDomain = ZkEmailInvites.claimRoleByDomain.selector;
        bytes4 selClaimEmail = ZkEmailInvites.claimRoleByEmail.selector;
        bytes4 selRegisterClaimDomain = ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector;
        bytes4 selRegisterClaimEmail = ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector;

        (bool aDomain, uint32 hDomain,) = _pmLensZk().effectiveRuleOf(ZK_ORG_ID, result.zkEmailInvites, selClaimDomain);
        (bool aEmail, uint32 hEmail,) = _pmLensZk().effectiveRuleOf(ZK_ORG_ID, result.zkEmailInvites, selClaimEmail);
        (bool aRegDomain, uint32 hRegDomain,) =
            _pmLensZk().effectiveRuleOf(ZK_ORG_ID, result.zkEmailInvites, selRegisterClaimDomain);
        (bool aRegEmail, uint32 hRegEmail,) =
            _pmLensZk().effectiveRuleOf(ZK_ORG_ID, result.zkEmailInvites, selRegisterClaimEmail);

        assertTrue(aDomain, "claimRoleByDomain allowed");
        assertTrue(aEmail, "claimRoleByEmail allowed");
        assertTrue(aRegDomain, "registerAndClaimByDomainWithPasskey allowed");
        assertTrue(aRegEmail, "registerAndClaimByEmailWithPasskey allowed");

        assertEq(uint256(hDomain), 800_000, "domain claim gas hint");
        assertEq(uint256(hEmail), 800_000, "email claim gas hint");
        assertEq(uint256(hRegDomain), 1_200_000, "combined domain claim gas hint");
        assertEq(uint256(hRegEmail), 1_200_000, "combined email claim gas hint");
    }

    PaymasterHubLens private _zkLens;

    function _pmLensZk() internal returns (PaymasterHubLens) {
        if (address(_zkLens) == address(0)) _zkLens = new PaymasterHubLens(address(paymasterHub));
        return _zkLens;
    }

    function testPaymasterRules_unaffected_whenInfraNotWired() public {
        // Without infra wiring: paymaster rules should still work; ZkEmailInvites selectors absent.
        OrgDeployer.DeploymentResult memory result = _deployZkOrgWithPaymaster(ZK_ORG_ID);
        assertEq(result.zkEmailInvites, address(0), "ZkEmailInvites not deployed");

        // The claim selectors must not be sponsored anywhere. Probing address(0) proves nothing
        // (a rule can never exist there), so probe the modules that WERE deployed — including via
        // effective resolution, which covers the global-rulebook tier too.
        bytes4 selClaimDomain = ZkEmailInvites.claimRoleByDomain.selector;
        assertFalse(
            paymasterHub.getRule(ZK_ORG_ID, result.quickJoin, selClaimDomain).allowed, "no zk rule on QuickJoin"
        );
        assertFalse(
            paymasterHub.getRule(ZK_ORG_ID, result.taskManager, selClaimDomain).allowed, "no zk rule on TaskManager"
        );
        (bool zkAllowed,,) = _pmLensZk().effectiveRuleOf(ZK_ORG_ID, result.quickJoin, selClaimDomain);
        assertFalse(zkAllowed, "no effective zk rule on QuickJoin");
    }

    /*──────────── Helpers ────────────*/

    function _readDeployerSlot(bytes32 layoutSlot, uint256 offset) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(deployer), bytes32(uint256(layoutSlot) + offset)))));
    }

    function _wireZkInfra() internal {
        vm.prank(poaAdmin);
        poaManager.adminCall(
            address(deployer),
            abi.encodeWithSignature(
                "setZkEmailInfrastructure(address,address,address)",
                address(mockDomainVerifier),
                address(mockEmailVerifier),
                address(mockDkim)
            )
        );
    }

    /// @dev ZkEmailConfig opted-in, deployed dormant (no initial root).
    function _enabledZkConfig() internal pure returns (ModulesFactory.ZkEmailConfig memory cfg) {
        cfg.enabled = true;
        // initialRoot / initialCid default to 0 → module deploys dormant.
    }

    function _deployZkOrg(bytes32 orgId) internal returns (OrgDeployer.DeploymentResult memory) {
        return _deployZkOrgInner(orgId, false, true, _enabledZkConfig());
    }

    function _deployZkOrgWithPaymaster(bytes32 orgId) internal returns (OrgDeployer.DeploymentResult memory) {
        return _deployZkOrgInner(orgId, true, true, _enabledZkConfig());
    }

    function _deployZkOrgInner(
        bytes32 orgId,
        bool autoWhitelist,
        bool enableEducation,
        ModulesFactory.ZkEmailConfig memory zkCfg
    ) internal returns (OrgDeployer.DeploymentResult memory) {
        OrgDeployer.DeploymentParams memory params = _defaultParams(orgId);
        params.educationHubConfig = ModulesFactory.EducationHubConfig({enabled: enableEducation});
        if (!autoWhitelist) {
            params.paymasterConfig.autoWhitelistContracts = false;
            params.paymasterConfig.operatorRoleIndex = type(uint256).max;
        }

        vm.prank(orgOwner);
        return deployer.deployFullOrgWithZkEmail(params, zkCfg);
    }

    /// @dev Builds a `ZkEmailProof` for the domain circuit. The Groth16 points are dummy bytes (the
    ///      mock verifier ignores them); `pubkeyHash` matches the DKIM fixture and `fromDomainHash` is
    ///      the circuit-proven domain commitment the registry + domain leaf bind to. Leaves here key the
    ///      domain by `keccak256(bytes(domain))`, so mirror that (any consistent bytes32 works with the
    ///      mock verifier + mock DKIM registry). The claimer address is the third public signal.
    function _buildDomainProof(string memory domain, bytes32 nullifier) internal pure returns (ZkEmailProof memory p) {
        p.pA = [uint256(1), uint256(2)];
        p.pB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
        p.pC = [uint256(7), uint256(8)];
        p.pubkeyHash = KEY_HASH;
        p.emailNullifier = nullifier;
        p.fromDomainHash = keccak256(bytes(domain));
    }
}
