// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

/// @title OrgDeployerPaymasterRules.t.sol
/// @notice Pins the auto-whitelist rule table produced by `OrgDeployer._buildDefaultPaymasterRules`
///         to the live ABI of every target contract.
/// @dev    WHY THIS EXISTS (issue #188). The rule table is built from hand-hashed signature STRINGS.
///         When `ZkEmailProof` gained `bytes32 fromDomainHash` (Blocker-2 domain binding), all four
///         ZkEmailInvites claim selectors moved, but the strings did not — so every new org with
///         `autoWhitelistContracts: true` got four paymaster rules that no function answers, and gasless
///         zk-email claims silently failed rule validation. Nothing caught it: the one test that
///         exercised those rules re-derived the SAME stale strings ("copied verbatim from OrgDeployer"),
///         so it asserted the bug and stayed green.
///
///         This test is deliberately NOT a copy of the source literals. Every expected selector is a
///         compiler-derived `Contract.fn.selector`, so it is anchored to the ABI. Set equality is
///         asserted in BOTH directions, which makes it fail on drift, on a dropped rule, on an added
///         rule the test doesn't know about, and on a duplicated slot.
///
///         It needs no fork and no RPC — it calls the pure builder directly through a harness.

import "forge-std/Test.sol";

import {OrgDeployer} from "../src/OrgDeployer.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import {ZkEmailInvites} from "../src/ZkEmailInvites.sol";

/// @dev `_buildDefaultPaymasterRules` is `internal pure`, so a derived contract can expose it with no
///      initialization, no proxy and no infra. Deploying an over-EIP-170 contract is fine in tests.
contract OrgDeployerRulesHarness is OrgDeployer {
    function exposeRules(DeploymentResult memory result, bool educationEnabled, address reg, address orgReg)
        external
        pure
        returns (address[] memory, bytes4[] memory, bool[] memory, uint32[] memory)
    {
        return _buildDefaultPaymasterRules(result, educationEnabled, reg, orgReg);
    }
}

contract OrgDeployerPaymasterRulesTest is Test {
    OrgDeployerRulesHarness internal harness;

    /* Sentinel targets — distinct so a rule written against the wrong module is visible. */
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

    /// @notice Full table (education + zk-email enabled) must equal the ABI-derived expectation exactly.
    function testDefaultRules_matchAbi_fullOrg() public view {
        (address[] memory targets, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory gasHints) =
            harness.exposeRules(_result(EDU, ZK), true, ACCT_REG, ORG_REG);

        (address[] memory expT, bytes4[] memory expS) = _expected(true, true);
        assertEq(expT.length, 52, "expectation must cover 44 base + 4 education + 4 zk-email");
        _assertSameRuleSet(targets, selectors, expT, expS);

        for (uint256 i = 0; i < allowed.length; i++) {
            assertTrue(allowed[i], "every default rule is allowed");
            assertTrue(targets[i] != address(0), "no zero target");
            assertTrue(selectors[i] != bytes4(0), "no zero selector");
        }
        assertEq(gasHints.length, targets.length, "gasHints array length");
    }

    /// @notice The zk-email rules carry the gas hints the Groth16 verify + hat mint actually need.
    function testDefaultRules_zkEmailGasHints() public view {
        (address[] memory targets, bytes4[] memory selectors,, uint32[] memory gasHints) =
            harness.exposeRules(_result(EDU, ZK), true, ACCT_REG, ORG_REG);

        assertEq(_hintOf(targets, selectors, gasHints, ZK, ZkEmailInvites.claimRoleByDomain.selector), 800_000);
        assertEq(_hintOf(targets, selectors, gasHints, ZK, ZkEmailInvites.claimRoleByEmail.selector), 800_000);
        assertEq(
            _hintOf(targets, selectors, gasHints, ZK, ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector),
            1_200_000
        );
        assertEq(
            _hintOf(targets, selectors, gasHints, ZK, ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector),
            1_200_000
        );

        // Everything else is hint-free (0 = "no per-rule cap", the hub's default).
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != ZK) assertEq(gasHints[i], 0, "only zk-email rules carry gas hints");
        }
    }

    /// @notice The three optional-module branches each produce exactly the count they allocate.
    function testDefaultRules_countsPerBranch() public view {
        (address[] memory tBoth,,,) = harness.exposeRules(_result(EDU, ZK), true, ACCT_REG, ORG_REG);
        assertEq(tBoth.length, 52, "education + zk-email");

        (address[] memory tEdu,,,) = harness.exposeRules(_result(EDU, address(0)), true, ACCT_REG, ORG_REG);
        assertEq(tEdu.length, 48, "education only");

        (address[] memory tZk,,,) = harness.exposeRules(_result(address(0), ZK), false, ACCT_REG, ORG_REG);
        assertEq(tZk.length, 48, "zk-email only");

        (address[] memory tBase,,,) = harness.exposeRules(_result(address(0), address(0)), false, ACCT_REG, ORG_REG);
        assertEq(tBase.length, 44, "base only");
    }

    /// @notice Optional-module branches stay ABI-correct too (the zk-only branch is the one #188 broke).
    function testDefaultRules_matchAbi_optionalBranches() public view {
        (address[] memory tEdu, bytes4[] memory sEdu,,) =
            harness.exposeRules(_result(EDU, address(0)), true, ACCT_REG, ORG_REG);
        (address[] memory expTEdu, bytes4[] memory expSEdu) = _expected(true, false);
        _assertSameRuleSet(tEdu, sEdu, expTEdu, expSEdu);

        (address[] memory tZk, bytes4[] memory sZk,,) =
            harness.exposeRules(_result(address(0), ZK), false, ACCT_REG, ORG_REG);
        (address[] memory expTZk, bytes4[] memory expSZk) = _expected(false, true);
        _assertSameRuleSet(tZk, sZk, expTZk, expSZk);

        (address[] memory tBase, bytes4[] memory sBase,,) =
            harness.exposeRules(_result(address(0), address(0)), false, ACCT_REG, ORG_REG);
        (address[] memory expTBase, bytes4[] memory expSBase) = _expected(false, false);
        _assertSameRuleSet(tBase, sBase, expTBase, expSBase);
    }

    /// @notice Tripwire on the four zk-email claim selectors' literal values.
    /// @dev    Not redundant with the ABI check above: those move together if the struct changes again,
    ///         and a silent move is dangerous — every LIVE org's existing paymaster rules would keep
    ///         pointing at the old selectors and gasless claims would break in production. If this fails,
    ///         the struct changed: update these constants AND migrate the deployed orgs' rules
    ///         (PaymasterHub.setRulesBatch) in the same rollout. The stale pre-Blocker-2 values #188
    ///         shipped were 0xc8864f92 / 0x50b2f726 / 0xcc1866ac / 0xebd847f2.
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

    /// @dev Expected (target, selector) pairs, every selector derived by the compiler from the target
    ///      contract's ABI. Order is irrelevant — the assertion is set equality.
    function _expected(bool educationEnabled, bool zkEmailEnabled)
        internal
        pure
        returns (address[] memory targets, bytes4[] memory selectors)
    {
        uint256 n = 44;
        if (educationEnabled) n += 4;
        if (zkEmailEnabled) n += 4;
        targets = new address[](n);
        selectors = new bytes4[](n);
        uint256 i;

        // QuickJoin (6)
        (targets[i], selectors[i++]) = (QJ, QuickJoin.quickJoinWithUser.selector);
        (targets[i], selectors[i++]) = (QJ, QuickJoin.registerAndQuickJoin.selector);
        (targets[i], selectors[i++]) = (QJ, QuickJoin.registerAndQuickJoinWithPasskey.selector);
        (targets[i], selectors[i++]) = (QJ, QuickJoin.claimHatsWithUser.selector);
        (targets[i], selectors[i++]) = (QJ, QuickJoin.registerAndClaimHats.selector);
        (targets[i], selectors[i++]) = (QJ, QuickJoin.registerAndClaimHatsWithPasskey.selector);

        // TaskManager (17)
        (targets[i], selectors[i++]) = (TM, TaskManager.createTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.createTasksBatch.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.claimTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.unclaimTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.submitTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.completeTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.applyForTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.approveApplication.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.assignTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.rejectTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.cancelTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.createAndAssignTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.createProject.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.deleteProject.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.setFolders.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.updateTask.selector);
        (targets[i], selectors[i++]) = (TM, TaskManager.updateTaskMetadata.selector);

        // Voting (3 + 3)
        (targets[i], selectors[i++]) = (HV, HybridVoting.vote.selector);
        (targets[i], selectors[i++]) = (HV, HybridVoting.announceWinner.selector);
        (targets[i], selectors[i++]) = (HV, HybridVoting.createProposal.selector);
        (targets[i], selectors[i++]) = (DDV, DirectDemocracyVoting.vote.selector);
        (targets[i], selectors[i++]) = (DDV, DirectDemocracyVoting.announceWinner.selector);
        (targets[i], selectors[i++]) = (DDV, DirectDemocracyVoting.createProposal.selector);

        // PaymentManager (5)
        (targets[i], selectors[i++]) = (PAY, PaymentManager.claimDistribution.selector);
        (targets[i], selectors[i++]) = (PAY, PaymentManager.claimMultiple.selector);
        (targets[i], selectors[i++]) = (PAY, PaymentManager.optOut.selector);
        (targets[i], selectors[i++]) = (PAY, PaymentManager.createDistribution.selector);
        (targets[i], selectors[i++]) = (PAY, PaymentManager.finalizeDistribution.selector);

        // EligibilityModule (5)
        (targets[i], selectors[i++]) = (ELIG, EligibilityModule.claimVouchedHat.selector);
        (targets[i], selectors[i++]) = (ELIG, EligibilityModule.vouchFor.selector);
        (targets[i], selectors[i++]) = (ELIG, EligibilityModule.revokeVouch.selector);
        (targets[i], selectors[i++]) = (ELIG, EligibilityModule.applyForRole.selector);
        (targets[i], selectors[i++]) = (ELIG, EligibilityModule.withdrawApplication.selector);

        // ParticipationToken (3)
        (targets[i], selectors[i++]) = (PT, ParticipationToken.requestTokens.selector);
        (targets[i], selectors[i++]) = (PT, ParticipationToken.approveRequest.selector);
        (targets[i], selectors[i++]) = (PT, ParticipationToken.cancelRequest.selector);

        // Registries (2) — setProfileMetadata is on the account registry, updateOrgMetaAsAdmin on
        // OrgRegistry. These being two DIFFERENT contracts is the L-53 fix; assert it stays that way.
        (targets[i], selectors[i++]) = (ACCT_REG, UniversalAccountRegistry.setProfileMetadata.selector);
        (targets[i], selectors[i++]) = (ORG_REG, OrgRegistry.updateOrgMetaAsAdmin.selector);

        if (educationEnabled) {
            (targets[i], selectors[i++]) = (EDU, EducationHub.completeModule.selector);
            (targets[i], selectors[i++]) = (EDU, EducationHub.createModule.selector);
            (targets[i], selectors[i++]) = (EDU, EducationHub.updateModule.selector);
            (targets[i], selectors[i++]) = (EDU, EducationHub.removeModule.selector);
        }

        if (zkEmailEnabled) {
            (targets[i], selectors[i++]) = (ZK, ZkEmailInvites.claimRoleByDomain.selector);
            (targets[i], selectors[i++]) = (ZK, ZkEmailInvites.claimRoleByEmail.selector);
            (targets[i], selectors[i++]) = (ZK, ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector);
            (targets[i], selectors[i++]) = (ZK, ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector);
        }

        require(i == n, "expectation length mismatch");
    }

    /// @dev Set equality in both directions, plus a duplicate check on the actual table.
    function _assertSameRuleSet(
        address[] memory actualT,
        bytes4[] memory actualS,
        address[] memory expT,
        bytes4[] memory expS
    ) internal pure {
        assertEq(actualT.length, expT.length, "rule count");
        assertEq(actualS.length, actualT.length, "selectors array length");

        for (uint256 e = 0; e < expT.length; e++) {
            uint256 hits;
            for (uint256 a = 0; a < actualT.length; a++) {
                if (actualT[a] == expT[e] && actualS[a] == expS[e]) hits++;
            }
            assertEq(hits, 1, string.concat("expected rule missing or duplicated at index ", vm.toString(e)));
        }
        for (uint256 a = 0; a < actualT.length; a++) {
            bool found;
            for (uint256 e = 0; e < expT.length; e++) {
                if (actualT[a] == expT[e] && actualS[a] == expS[e]) found = true;
            }
            assertTrue(
                found,
                string.concat(
                    "unexpected rule ",
                    vm.toString(actualT[a]),
                    " / ",
                    vm.toString(bytes32(actualS[a])),
                    ": either a new rule was added without updating this test, or its selector drifted from the ABI"
                )
            );
        }
    }

    function _hintOf(
        address[] memory targets,
        bytes4[] memory selectors,
        uint32[] memory gasHints,
        address target,
        bytes4 selector
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == target && selectors[i] == selector) return gasHints[i];
        }
        revert("rule not found");
    }
}
