// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @title OrgDeployerPaymasterRules.t.sol
/// @notice Pins the paymaster auto-whitelist surface OrgDeployer produces — now the TARGET-TYPE
///         map consumed by the PaymasterHub global rulebook — plus the rulebook's zk-email
///         entries, to the live ABI of every module.
/// @dev    WHY THIS EXISTS (issue #188). The old per-selector rule table was built from
///         hand-hashed signature STRINGS; when `ZkEmailProof` gained `bytes32 fromDomainHash`
///         (Blocker-2), all four ZkEmailInvites claim selectors moved but the strings did not,
///         and the one test exercising them re-derived the SAME stale strings — asserting the
///         bug. The global-rulebook refactor replaced the deployer's selector table with
///         `_buildTargetTypes` (module → typeId), and the selector list moved to
///         `script/helpers/DefaultGlobalRules.sol`. This suite pins BOTH halves:
///           - `_buildTargetTypes` branch outputs (set equality in BOTH directions, per branch),
///           - the rulebook's zk-email entries against compiler-derived `.selector` values
///             (never literals — see also testDefaultGlobalRules_MatchRealContractSelectors in
///             PaymasterGlobalRules.t.sol for the full 52-entry bijection).
///
///         It needs no fork and no RPC — it calls the pure builder directly through a harness.

import "forge-std/Test.sol";

import {OrgDeployer} from "../src/OrgDeployer.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {DefaultGlobalRules} from "../script/helpers/DefaultGlobalRules.sol";
import {ZkEmailInvites} from "../src/ZkEmailInvites.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";

/// @dev `_buildTargetTypes` is `internal pure`, so a derived contract can expose it with no
///      initialization, no proxy and no infra. Deploying an over-EIP-170 contract is fine in tests.
contract OrgDeployerRulesHarness is OrgDeployer {
    function exposeTargetTypes(DeploymentResult memory result, address reg, address orgReg)
        external
        pure
        returns (address[] memory, bytes32[] memory)
    {
        return _buildTargetTypes(result, reg, orgReg);
    }
}

contract OrgDeployerPaymasterRulesTest is Test {
    OrgDeployerRulesHarness internal harness;

    /* Sentinel targets — distinct so a mapping written against the wrong module is visible. */
    address internal constant HV = address(0x1001);
    address internal constant DDV = address(0x1002);
    address internal constant EXEC = address(0x1003);
    address internal constant QJ = address(0x1004);
    address internal constant PT = address(0x1005);
    address internal constant TM = address(0x1006);
    address internal constant EDU = address(0x1007);
    address internal constant PAY = address(0x1008);
    address internal constant ELIG = address(0x1009);
    address internal constant ZK = address(0x100A);
    address internal constant ACCT_REG = address(0x100B);
    address internal constant ORG_REG = address(0x100C);

    function setUp() public {
        harness = new OrgDeployerRulesHarness();
    }

    /*────────────────────── the pin ──────────────────────*/

    /// @notice Full map (education + zk-email enabled) must equal the expectation exactly.
    function testTargetTypes_matchExpected_fullOrg() public view {
        (address[] memory targets, bytes32[] memory typeIds) =
            harness.exposeTargetTypes(_result(EDU, ZK), ACCT_REG, ORG_REG);
        (address[] memory expT, bytes32[] memory expTy) = _expected(true, true);
        assertEq(expT.length, 11, "expectation must cover 9 base + education + zk-email");
        _assertSameTypeSet(targets, typeIds, expT, expTy);

        for (uint256 i = 0; i < targets.length; i++) {
            assertTrue(targets[i] != address(0), "no zero target");
            assertTrue(typeIds[i] != bytes32(0), "no zero typeId");
        }
    }

    /// @notice The three optional-module branches each produce exactly the count they allocate.
    function testTargetTypes_countsPerBranch() public view {
        (address[] memory tBoth,) = harness.exposeTargetTypes(_result(EDU, ZK), ACCT_REG, ORG_REG);
        assertEq(tBoth.length, 11, "education + zk-email");

        (address[] memory tEdu,) = harness.exposeTargetTypes(_result(EDU, address(0)), ACCT_REG, ORG_REG);
        assertEq(tEdu.length, 10, "education only");

        (address[] memory tZk,) = harness.exposeTargetTypes(_result(address(0), ZK), ACCT_REG, ORG_REG);
        assertEq(tZk.length, 10, "zk-email only");

        (address[] memory tBase,) = harness.exposeTargetTypes(_result(address(0), address(0)), ACCT_REG, ORG_REG);
        assertEq(tBase.length, 9, "base only");
    }

    /// @notice Optional-module branches stay correct too (array sizing / trailing-slot bugs).
    function testTargetTypes_matchExpected_optionalBranches() public view {
        (address[] memory tEdu, bytes32[] memory tyEdu) =
            harness.exposeTargetTypes(_result(EDU, address(0)), ACCT_REG, ORG_REG);
        (address[] memory expTEdu, bytes32[] memory expTyEdu) = _expected(true, false);
        _assertSameTypeSet(tEdu, tyEdu, expTEdu, expTyEdu);

        (address[] memory tZk, bytes32[] memory tyZk) =
            harness.exposeTargetTypes(_result(address(0), ZK), ACCT_REG, ORG_REG);
        (address[] memory expTZk, bytes32[] memory expTyZk) = _expected(false, true);
        _assertSameTypeSet(tZk, tyZk, expTZk, expTyZk);

        (address[] memory tBase, bytes32[] memory tyBase) =
            harness.exposeTargetTypes(_result(address(0), address(0)), ACCT_REG, ORG_REG);
        (address[] memory expTBase, bytes32[] memory expTyBase) = _expected(false, false);
        _assertSameTypeSet(tBase, tyBase, expTBase, expTyBase);
    }

    /// @notice L-53 regression, type-map edition: updateOrgMetaAsAdmin resolves via the
    ///         OrgRegistry typeId on the OrgRegistry address, never the account registry.
    function testTargetTypes_registriesDistinct() public view {
        (address[] memory targets, bytes32[] memory typeIds) =
            harness.exposeTargetTypes(_result(EDU, ZK), ACCT_REG, ORG_REG);
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == ACCT_REG) {
                assertEq(typeIds[i], ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID, "acct reg type");
            }
            if (targets[i] == ORG_REG) assertEq(typeIds[i], ModuleTypes.ORG_REGISTRY_ID, "org reg type");
        }
    }

    /// @notice Every typeId the deployer maps has at least one entry in the default rulebook —
    ///         a typed module with zero sponsored selectors would be silently dead weight.
    function testTargetTypes_allTypesCoveredByRulebook() public view {
        (, bytes32[] memory typeIds) = harness.exposeTargetTypes(_result(EDU, ZK), ACCT_REG, ORG_REG);
        DefaultGlobalRules.Entry[] memory entries = DefaultGlobalRules.entries();
        for (uint256 i = 0; i < typeIds.length; i++) {
            bool covered;
            for (uint256 j = 0; j < entries.length; j++) {
                if (entries[j].typeId == typeIds[i]) {
                    covered = true;
                    break;
                }
            }
            assertTrue(covered, "typed module has no rulebook entries");
        }
    }

    /// @notice The rulebook's zk-email entries carry the gas hints the Groth16 verify + hat mint
    ///         actually need, keyed by compiler-derived selectors.
    function testRulebook_zkEmailGasHints() public pure {
        DefaultGlobalRules.Entry[] memory entries = DefaultGlobalRules.entries();
        assertEq(_hintOf(entries, ZkEmailInvites.claimRoleByDomain.selector), 800_000);
        assertEq(_hintOf(entries, ZkEmailInvites.claimRoleByEmail.selector), 800_000);
        assertEq(_hintOf(entries, ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector), 1_200_000);
        assertEq(_hintOf(entries, ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector), 1_200_000);

        // The EligibilityModule claim entries carry hints too (RoleManager rollout): claimHat is a
        // single guarded mint, claimHats loops up to 20 mints (identity + group markers).
        assertEq(_hintOfType(entries, ModuleTypes.ELIGIBILITY_MODULE_ID, EligibilityModule.claimHat.selector), 300_000);
        assertEq(
            _hintOfType(entries, ModuleTypes.ELIGIBILITY_MODULE_ID, EligibilityModule.claimHats.selector), 3_000_000
        );

        // Everything else is hint-free (0 = "no per-rule cap", the hub's default).
        for (uint256 i = 0; i < entries.length; i++) {
            bool isEmClaim = entries[i].typeId == ModuleTypes.ELIGIBILITY_MODULE_ID
                && (entries[i].selector == EligibilityModule.claimHat.selector
                    || entries[i].selector == EligibilityModule.claimHats.selector);
            if (entries[i].typeId != ModuleTypes.ZKEMAIL_INVITES_ID && !isEmClaim) {
                assertEq(entries[i].maxCallGasHint, 0, "only zk-email + EM claim entries carry gas hints");
            }
        }
    }

    /// @notice Tripwire on the four zk-email claim selectors' literal values.
    /// @dev    Not redundant with the ABI checks above: those move together if the struct changes
    ///         again, and a silent move is dangerous — every LIVE org's existing paymaster rules
    ///         (and the global rulebook) would keep pointing at the old selectors and gasless
    ///         claims would break in production. If this fails, the struct changed: update these
    ///         constants AND rebroadcast setGlobalRulesBatch in the same rollout. The stale
    ///         pre-Blocker-2 values #188 shipped were 0xc8864f92 / 0x50b2f726 / 0xcc1866ac /
    ///         0xebd847f2.
    function testZkEmailClaimSelectors_areUnchanged() public pure {
        assertEq(ZkEmailInvites.claimRoleByDomain.selector, bytes4(0x24b5e3ba), "claimRoleByDomain moved");
        assertEq(ZkEmailInvites.claimRoleByEmail.selector, bytes4(0x8c149bab), "claimRoleByEmail moved");
        assertEq(
            ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector,
            bytes4(0x6108482e),
            "registerAndClaimByDomainWithPasskey moved"
        );
        assertEq(
            ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector,
            bytes4(0x998dc9d6),
            "registerAndClaimByEmailWithPasskey moved"
        );
    }

    /*────────────────────── helpers ──────────────────────*/

    function _result(address educationHub, address zkEmailInvites)
        internal
        pure
        returns (OrgDeployer.DeploymentResult memory r)
    {
        r.hybridVoting = HV;
        r.directDemocracyVoting = DDV;
        r.executor = EXEC;
        r.quickJoin = QJ;
        r.participationToken = PT;
        r.taskManager = TM;
        r.educationHub = educationHub;
        r.paymentManager = PAY;
        r.eligibilityModule = ELIG;
        r.zkEmailInvites = zkEmailInvites;
    }

    function _expected(bool education, bool zkEmail)
        internal
        pure
        returns (address[] memory targets, bytes32[] memory typeIds)
    {
        uint256 count = 9;
        if (education) count += 1;
        if (zkEmail) count += 1;
        targets = new address[](count);
        typeIds = new bytes32[](count);
        uint256 n;
        (targets[n], typeIds[n]) = (QJ, ModuleTypes.QUICK_JOIN_ID);
        n++;
        (targets[n], typeIds[n]) = (TM, ModuleTypes.TASK_MANAGER_ID);
        n++;
        (targets[n], typeIds[n]) = (HV, ModuleTypes.HYBRID_VOTING_ID);
        n++;
        (targets[n], typeIds[n]) = (DDV, ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID);
        n++;
        (targets[n], typeIds[n]) = (PAY, ModuleTypes.PAYMENT_MANAGER_ID);
        n++;
        (targets[n], typeIds[n]) = (ELIG, ModuleTypes.ELIGIBILITY_MODULE_ID);
        n++;
        (targets[n], typeIds[n]) = (PT, ModuleTypes.PARTICIPATION_TOKEN_ID);
        n++;
        (targets[n], typeIds[n]) = (ACCT_REG, ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID);
        n++;
        (targets[n], typeIds[n]) = (ORG_REG, ModuleTypes.ORG_REGISTRY_ID);
        n++;
        if (education) {
            (targets[n], typeIds[n]) = (EDU, ModuleTypes.EDUCATION_HUB_ID);
            n++;
        }
        if (zkEmail) {
            (targets[n], typeIds[n]) = (ZK, ModuleTypes.ZKEMAIL_INVITES_ID);
            n++;
        }
    }

    /// @dev Set equality in BOTH directions via consume-on-match (catches drift, drops,
    ///      additions, and duplicated slots).
    function _assertSameTypeSet(
        address[] memory targets,
        bytes32[] memory typeIds,
        address[] memory expT,
        bytes32[] memory expTy
    ) internal pure {
        assertEq(targets.length, expT.length, "pair count");
        assertEq(typeIds.length, targets.length, "typeIds length");
        for (uint256 i = 0; i < targets.length; i++) {
            bool found;
            for (uint256 j = 0; j < expT.length; j++) {
                if (expT[j] == targets[i] && expTy[j] == typeIds[i]) {
                    expT[j] = address(0); // consume
                    found = true;
                    break;
                }
            }
            assertTrue(found, "unexpected or duplicated (target, typeId) pair");
        }
    }

    function _hintOf(DefaultGlobalRules.Entry[] memory entries, bytes4 selector) internal pure returns (uint32) {
        return _hintOfType(entries, ModuleTypes.ZKEMAIL_INVITES_ID, selector);
    }

    function _hintOfType(DefaultGlobalRules.Entry[] memory entries, bytes32 typeId, bytes4 selector)
        internal
        pure
        returns (uint32)
    {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].typeId == typeId && entries[i].selector == selector) {
                return entries[i].maxCallGasHint;
            }
        }
        revert("selector missing from DefaultGlobalRules");
    }
}
