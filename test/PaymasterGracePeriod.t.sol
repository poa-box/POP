// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterRuleLib} from "../src/libs/PaymasterRuleLib.sol";
import {IPaymaster} from "../src/interfaces/IPaymaster.sol";
import {IEntryPoint} from "../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../src/interfaces/PackedUserOperation.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {PaymasterGraceLib} from "../src/libs/PaymasterGraceLib.sol";

/**
 * @title PaymasterGracePeriodTest
 * @notice Tests for PaymasterHub grace period solidarity logic.
 *         Exercises _checkSolidarityAccess and _updateOrgFinancials
 *         to verify funded orgs use tier system during grace, while
 *         unfunded orgs get the grace subsidy.
 */
contract PaymasterGracePeriodTest is Test {
    PaymasterHub public paymaster;

    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    bytes32 constant ORG_ID = keccak256("test-org-grace");
    uint256 constant ADMIN_HAT = 1;
    uint256 constant MEMBER_HAT = 2;

    // The test sender address for UserOps
    address constant SENDER = address(0xABCD);

    // Grace config
    uint32 constant GRACE_DAYS = 90;
    uint128 constant MAX_SPEND_DURING_GRACE = 0.01 ether;
    uint128 constant MIN_DEPOSIT_REQUIRED = 0.003 ether;

    // Budget config
    uint128 constant BUDGET_CAP = 1 ether;
    uint32 constant BUDGET_EPOCH_LEN = 7 days;

    // Whitelist target / selector (dummy — we just need any allowed rule)
    address constant RULE_TARGET = address(0xBEEF);
    bytes4 constant RULE_SELECTOR = bytes4(keccak256("doSomething()"));

    // Use SUBJECT_TYPE_ACCOUNT (0x00) — simpler eligibility check (sender == subjectId)
    uint8 constant SUBJECT_TYPE_ACCOUNT = 0x00;

    // Subject key for the account-scoped budget
    bytes32 subjectKey;

    function setUp() public {
        vm.createSelectFork("hoodi");

        // Deploy PaymasterHub behind a UUPS proxy
        PaymasterHub impl = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, ENTRY_POINT, HATS, address(this));
        paymaster = PaymasterHub(payable(address(new ERC1967Proxy(address(impl), initData))));

        // address(this) is poaManager, so we can call admin functions

        // Set up the org registrar (address(this) so we can register orgs)
        paymaster.setOrgRegistrar(address(this));

        // Unpause solidarity distribution so grace/tier logic is active
        paymaster.unpauseSolidarityDistribution();

        // Seed the solidarity fund so it has liquidity
        paymaster.donateToSolidarity{value: 10 ether}();

        // Set grace period config
        paymaster.setGracePeriodConfig(GRACE_DAYS, MAX_SPEND_DURING_GRACE, MIN_DEPOSIT_REQUIRED);

        // Build deploy config with rules, budgets, and fee caps
        // Use SUBJECT_TYPE_ACCOUNT with the sender address as subjectId
        subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(SENDER)))));

        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        bool[] memory allowed = new bool[](1);
        uint32[] memory gasHints = new uint32[](1);
        targets[0] = RULE_TARGET;
        selectors[0] = RULE_SELECTOR;
        allowed[0] = true;

        bytes32[] memory budgetKeys = new bytes32[](1);
        uint128[] memory budgetCaps = new uint128[](1);
        uint32[] memory budgetEpochLens = new uint32[](1);
        budgetKeys[0] = subjectKey;
        budgetCaps[0] = BUDGET_CAP;
        budgetEpochLens[0] = BUDGET_EPOCH_LEN;

        PaymasterRuleLib.DeployConfig memory config = PaymasterRuleLib.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 100 gwei,
            maxPriorityFeePerGas: 100 gwei,
            maxCallGas: 5_000_000,
            maxVerificationGas: 5_000_000,
            maxPreVerificationGas: 500_000,
            ruleTargets: targets,
            ruleSelectors: selectors,
            ruleAllowed: allowed,
            ruleMaxCallGasHints: gasHints,
            budgetSubjectKeys: budgetKeys,
            budgetCapsPerEpoch: budgetCaps,
            budgetEpochLens: budgetEpochLens,
            typeTargets: new address[](0),
            typeIds: new bytes32[](0),
            rulesMode: 0
        });

        // Register and configure org (as registrar, this sets rules/budgets/caps)
        paymaster.registerAndConfigureOrg(ORG_ID, ADMIN_HAT, config);
    }

    /*═══════════════════════ HELPERS ═══════════════════════*/

    /// @dev Build a minimal PackedUserOperation that will pass validation.
    ///      Uses SUBJECT_TYPE_ACCOUNT so the sender is the subject (no Hats dependency).
    function _buildUserOp(address sender, uint256 maxCost) internal view returns (PackedUserOperation memory) {
        // Calculate gas limits to produce the desired maxCost
        // maxCost = (verificationGasLimit + callGasLimit + paymasterVerificationGasLimit + paymasterPostOpGasLimit) * maxFeePerGas + preVerificationGas * maxFeePerGas
        // Simplify: set maxFeePerGas = 1 gwei, distribute gas limits to hit maxCost
        uint256 maxFeePerGas = 1 gwei;
        uint256 totalGas = maxCost / maxFeePerGas;

        uint128 verificationGas = 100_000;
        uint128 callGas = uint128(totalGas > 400_000 ? totalGas - 400_000 : 100_000);
        uint128 pmVerificationGas = 200_000;
        uint128 pmPostOpGas = 100_000;
        uint256 preVerificationGas =
            totalGas - uint256(verificationGas) - uint256(callGas) - uint256(pmVerificationGas) - uint256(pmPostOpGas);
        if (preVerificationGas > totalGas) preVerificationGas = 0;

        // Pack accountGasLimits: verificationGasLimit (high 128) | callGasLimit (low 128)
        bytes32 accountGasLimits = bytes32(uint256(verificationGas) << 128 | uint256(callGas));

        // Pack gasFees: maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128)
        bytes32 gasFees = bytes32(uint256(maxFeePerGas) << 128 | uint256(maxFeePerGas));

        // Build callData: execute(RULE_TARGET, 0, abi.encodeWithSelector(RULE_SELECTOR))
        bytes memory innerCall = abi.encodeWithSelector(RULE_SELECTOR);
        bytes memory callData = abi.encodeWithSignature("execute(address,uint256,bytes)", RULE_TARGET, 0, innerCall);

        // Build paymasterAndData:
        // paymaster address (20 bytes) + version (1) + orgId (32) + subjectType (1) + subjectId (32) + ruleId (4) + mailboxCommit (8)
        bytes memory paymasterData = abi.encodePacked(
            uint8(1), // version
            ORG_ID, // orgId
            SUBJECT_TYPE_ACCOUNT, // subjectType = ACCOUNT
            bytes32(uint256(uint160(sender))), // subjectId = sender address
            uint32(0), // ruleId = GENERIC
            uint64(0) // mailboxCommit
        );
        bytes memory paymasterAndData =
            abi.encodePacked(address(paymaster), pmVerificationGas, pmPostOpGas, paymasterData);

        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: preVerificationGas,
            gasFees: gasFees,
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    /// @dev Call validatePaymasterUserOp as the EntryPoint
    function _validate(PackedUserOperation memory userOp, uint256 maxCost)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        vm.prank(ENTRY_POINT);
        return paymaster.validatePaymasterUserOp(userOp, bytes32(0), maxCost);
    }

    /// @dev Call postOp as the EntryPoint
    function _postOp(bytes memory context, uint256 actualGasCost) internal {
        vm.prank(ENTRY_POINT);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualGasCost, 0);
    }

    /// @dev Deposit ETH to the org's gas pool
    function _depositForOrg(uint256 amount) internal {
        paymaster.depositForOrg{value: amount}(ORG_ID);
    }

    /// @dev Get org financials
    function _getFinancials() internal view returns (PaymasterHub.OrgFinancials memory) {
        return paymaster.getOrgFinancials(ORG_ID);
    }

    /// @dev Get solidarity fund state
    function _getSolidarity() internal view returns (PaymasterHub.SolidarityFund memory) {
        return paymaster.getSolidarityFund();
    }

    /*═══════════════════════ UNFUNDED GRACE ORG TESTS ═══════════════════════*/

    function testUnfundedGraceOrg_SolidaritySubsidy() public {
        // Unfunded org in grace period should get solidarity subsidy
        uint256 maxCost = 0.001 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.0005 ether); // actual cost less than maxCost

        PaymasterHub.OrgFinancials memory fin = _getFinancials();
        uint256 solidarityAfter = _getSolidarity().balance;

        // Solidarity should have paid (balance decreased)
        assertLt(solidarityAfter, solidarityBefore, "Solidarity balance should decrease");
        // solidarityUsedThisPeriod should increase
        assertGt(fin.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should increase");
        // Org deposits should be untouched (was 0, still 0)
        assertEq(fin.deposited, 0, "Deposits should be 0");
    }

    function testUnfundedGraceOrg_HitsSpendLimit() public {
        // Use up most of the grace budget
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.005 ether);

        // Second op to use more
        PackedUserOperation memory userOp2 = _buildUserOp(SENDER, maxCost);
        userOp2.nonce = 1;
        (bytes memory context2,) = _validate(userOp2, maxCost);
        _postOp(context2, 0.005 ether);

        // solidarityUsedThisPeriod is now 0.01 ether = maxSpendDuringGrace
        // Third op should revert
        PackedUserOperation memory userOp3 = _buildUserOp(SENDER, 0.001 ether);
        userOp3.nonce = 2;

        vm.expectRevert(PaymasterHubErrors.GracePeriodSpendLimitReached.selector);
        _validate(userOp3, 0.001 ether);
    }

    /*═══════════════════════ FUNDED GRACE ORG — TIER 4 (SELF-FUNDED) ═══════════════════════*/

    function testFundedGraceOrg_Tier4_SelfFunded() public {
        // Deposit 5x minDeposit = 0.015 ether → Tier 4, zero solidarity match
        _depositForOrg(0.015 ether);

        uint256 maxCost = 0.004 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory finBefore = _getFinancials();

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();

        // No solidarity matching (tier 4 = self-funded), but 1% fee collected
        uint256 expectedFee = (0.002 ether * 100) / 10000;
        assertEq(solidarityAfter, solidarityBefore + expectedFee, "Solidarity gains 1% fee from funded grace org");
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should be 0");
        // Deposits should be drawn down
        assertGt(finAfter.spent, finBefore.spent, "Spent should increase (deposits used)");
    }

    function testFundedGraceOrg_Tier4_BypassesGraceLimit() public {
        // Run ops that accumulate solidarityUsedThisPeriod to max via the unfunded path first.
        // We deploy a SECOND org (unfunded) to exhaust grace subsidy,
        // proving that solidarity tracking is per-org and funded orgs are unaffected.

        // Register a second org (unfunded) to burn through grace subsidy on THIS org
        // Actually, solidarityUsedThisPeriod is per-org, so we can't exhaust it from another org.
        // Instead, we first use ops WITHOUT deposit (unfunded grace path) to exhaust the limit,
        // then deposit to become funded, and verify ops still work.

        // Phase 1: Use grace subsidy until it's near max
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory op1 = _buildUserOp(SENDER, maxCost);
        (bytes memory ctx1,) = _validate(op1, maxCost);
        _postOp(ctx1, 0.005 ether);

        PackedUserOperation memory op2 = _buildUserOp(SENDER, maxCost);
        op2.nonce = 1;
        (bytes memory ctx2,) = _validate(op2, maxCost);
        _postOp(ctx2, 0.005 ether);

        // solidarityUsedThisPeriod is now 0.01 = maxSpendDuringGrace
        // Unfunded op would revert here:
        PackedUserOperation memory op3 = _buildUserOp(SENDER, 0.001 ether);
        op3.nonce = 2;
        vm.expectRevert(PaymasterHubErrors.GracePeriodSpendLimitReached.selector);
        _validate(op3, 0.001 ether);

        // Phase 2: Deposit enough for Tier 4 (self-funded)
        _depositForOrg(1 ether);

        // Phase 3: The SAME op should now succeed — funded org bypasses grace limit
        PackedUserOperation memory op4 = _buildUserOp(SENDER, 0.005 ether);
        op4.nonce = 2;
        (bytes memory ctx4,) = _validate(op4, 0.005 ether);
        _postOp(ctx4, 0.002 ether);

        // Verify: solidarity not used (tier 4 = self-funded)
        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory fin = _getFinancials();
        assertGt(fin.spent, 0, "Deposits should be used");
    }

    function testFundedGraceOrg_Tier4_CollectsFee() public {
        _depositForOrg(1 ether);

        uint256 maxCost = 0.004 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        uint256 solidarityAfter = _getSolidarity().balance;

        // Funded grace orgs pay 1% fee from deposits (not circular — org pays, not solidarity)
        uint256 expectedFee = (0.002 ether * 100) / 10000;
        assertEq(solidarityAfter, solidarityBefore + expectedFee, "1% fee collected from funded grace org");
    }

    /*═══════════════════════ FUNDED GRACE ORG — TIER 1 (MATCHING) ═══════════════════════*/

    function testFundedGraceOrg_Tier1_GetsMatching() public {
        // Deposit exactly minDeposit → Tier 1: 2x match = 0.006 ether solidarity allowance
        _depositForOrg(MIN_DEPOSIT_REQUIRED);

        uint256 maxCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.001 ether);

        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // Solidarity SHOULD be used (tier 1 gets 50/50 split)
        assertLt(solidarityAfter, solidarityBefore, "Solidarity should decrease for tier 1");
        assertGt(fin.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should increase");
        // But deposits should also be used
        assertGt(fin.spent, 0, "Deposits should also be used (50/50 split)");
    }

    /*═══════════════════════ MATCHING EXHAUSTED → DEPOSITS ONLY ═══════════════════════*/

    function testFundedGraceOrg_ExhaustedMatching_FallsBackToDeposits() public {
        // Deposit enough for Tier 2 (between 1x and 2x minDeposit)
        // but enough absolute value to survive many ops
        // minDeposit = 0.003, so 2x = 0.006
        // Use exactly 0.006 → Tier 2: match = 0.003*2 + (0.006-0.003)*1 = 0.009 ether
        _depositForOrg(0.006 ether);

        // Run ops to exhaust the match allowance
        uint256 opsRun = 0;
        for (opsRun = 0; opsRun < 30; opsRun++) {
            PaymasterHub.OrgFinancials memory fin = _getFinancials();
            uint256 depositAvail = fin.deposited > fin.spent ? fin.deposited - fin.spent : 0;

            // Stop if deposits too low to continue
            if (depositAvail < MIN_DEPOSIT_REQUIRED) break;

            uint256 maxCost = 0.001 ether;
            PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
            userOp.nonce = opsRun;

            (bytes memory ctx,) = _validate(userOp, maxCost);
            _postOp(ctx, 0.0005 ether);
        }

        // Check: solidarity matching should be near exhaustion
        PaymasterHub.OrgFinancials memory finMid = _getFinancials();
        uint256 depositAvailMid = finMid.deposited > finMid.spent ? finMid.deposited - finMid.spent : 0;

        // If deposits are still above minDeposit, the next op should use deposits only
        if (depositAvailMid >= MIN_DEPOSIT_REQUIRED) {
            uint256 solidarityBefore = _getSolidarity().balance;

            PackedUserOperation memory finalOp = _buildUserOp(SENDER, 0.001 ether);
            finalOp.nonce = opsRun;
            (bytes memory ctx2,) = _validate(finalOp, 0.001 ether);
            _postOp(ctx2, 0.0005 ether);

            // Verify: with matching exhausted, deposits should cover 100%
            // and solidarity should not decrease (or decrease very little from residual matching)
            PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
            assertGt(finAfter.spent, finMid.spent, "Deposits should be used");
        }
    }

    /*═══════════════════════ DEPOSIT DURING GRACE PERIOD ═══════════════════════*/

    function testDepositDuringGrace_UnlocksOperations() public {
        // Start unfunded, use up grace subsidy
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.005 ether);

        PackedUserOperation memory userOp1b = _buildUserOp(SENDER, maxCost);
        userOp1b.nonce = 1;
        (bytes memory context1b,) = _validate(userOp1b, maxCost);
        _postOp(context1b, 0.005 ether);

        // Grace subsidy now exhausted (used 0.01 = maxSpendDuringGrace)
        PackedUserOperation memory userOp2 = _buildUserOp(SENDER, 0.001 ether);
        userOp2.nonce = 2;
        vm.expectRevert(PaymasterHubErrors.GracePeriodSpendLimitReached.selector);
        _validate(userOp2, 0.001 ether);

        // Deposit enough to cross minDepositRequired → enters tier system
        _depositForOrg(1 ether);

        // Now the same op should succeed (funded org uses tier system / deposits)
        PackedUserOperation memory userOp3 = _buildUserOp(SENDER, 0.001 ether);
        userOp3.nonce = 2;
        (bytes memory context2,) = _validate(userOp3, 0.001 ether);
        _postOp(context2, 0.0005 ether);

        // Success — deposit unlocked operations for funded org
    }

    /*═══════════════════════ POST-GRACE TESTS ═══════════════════════*/

    function testPostGrace_FundedOrg_TierSystem() public {
        _depositForOrg(MIN_DEPOSIT_REQUIRED); // Tier 1

        // Warp past grace period
        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.001 ether);

        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // Post-grace tier 1: gets solidarity matching
        assertLt(solidarityAfter, solidarityBefore, "Solidarity should decrease post-grace tier 1");
        assertGt(fin.spent, 0, "Deposits should be used post-grace");
    }

    function testPostGrace_UnfundedOrg_Reverts() public {
        // Don't deposit anything, warp past grace
        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.001 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        vm.expectRevert(PaymasterHubErrors.InsufficientDepositForSolidarity.selector);
        _validate(userOp, maxCost);
    }

    function testPostGrace_SelfFunded_NoSolidarity() public {
        _depositForOrg(0.015 ether); // Tier 4

        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.004 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // Post-grace with solidarity fee (1%)
        // Solidarity balance changes by fee collected minus 0 (no matching for tier 4)
        assertEq(fin.solidarityUsedThisPeriod, 0, "No solidarity used for tier 4");
    }

    /*═══════════════════════ DISTRIBUTION PAUSED ═══════════════════════*/

    function testDistributionPaused_SkipsSolidarity() public {
        _depositForOrg(0.01 ether);

        // Pause solidarity distribution
        paymaster.pauseSolidarityDistribution();

        uint256 maxCost = 0.004 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // When paused: 100% from deposits, 1% fee to solidarity
        assertGt(fin.spent, 0, "Should charge from deposits when paused");
        assertEq(fin.solidarityUsedThisPeriod, 0, "No solidarity usage when paused");
    }

    /*═══════════════════════ EDGE CASES ═══════════════════════*/

    function testGraceOrg_DepositBelowMin_StillGetsSubsidy() public {
        // Deposit less than minDepositRequired — should still use grace subsidy
        _depositForOrg(MIN_DEPOSIT_REQUIRED / 2);

        uint256 maxCost = 0.001 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.0005 ether);

        uint256 solidarityAfter = _getSolidarity().balance;

        // Below minDeposit in grace → grace subsidy (solidarity pays)
        assertLt(solidarityAfter, solidarityBefore, "Grace subsidy should apply below minDeposit");
    }

    function testGraceOrg_DepositExactlyMin_EntersTierSystem() public {
        // Deposit exactly minDepositRequired → Tier 1 (not grace subsidy)
        _depositForOrg(MIN_DEPOSIT_REQUIRED);

        uint256 maxCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.001 ether);

        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // Should use BOTH deposits and solidarity (tier 1 matching)
        assertGt(fin.spent, 0, "Deposits should be used");
        assertGt(fin.solidarityUsedThisPeriod, 0, "Solidarity matching should be used");
    }

    function testMultipleOpsAccumulate_SolidarityUsage() public {
        _depositForOrg(MIN_DEPOSIT_REQUIRED); // Tier 1

        uint256 maxCost = 0.001 ether;

        for (uint256 i = 0; i < 5; i++) {
            PackedUserOperation memory userOp = _buildUserOp(address(0xABCD), maxCost);
            userOp.nonce = i;
            (bytes memory context,) = _validate(userOp, maxCost);
            _postOp(context, 0.0005 ether);
        }

        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // After 5 ops, solidarityUsedThisPeriod should be accumulated
        assertGt(fin.solidarityUsedThisPeriod, 0, "Solidarity should accumulate over ops");
        assertGt(fin.spent, 0, "Deposits should accumulate over ops");
    }

    /*═══════════════════════ POSTOP FALLBACK TESTS ═══════════════════════*/

    /// @dev Helper to call postOp in postOpReverted mode
    function _postOpReverted(bytes memory context, uint256 actualGasCost) internal {
        vm.prank(ENTRY_POINT);
        paymaster.postOp(IPaymaster.PostOpMode.postOpReverted, context, actualGasCost, 0);
    }

    function testPostOpFallback_FundedOrg_ChargesDeposits_NoSolidarityCount() public {
        _depositForOrg(1 ether); // Tier 4

        PaymasterHub.OrgFinancials memory finStart = _getFinancials();
        uint256 solidarityBefore = _getSolidarity().balance;

        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        (bytes memory context,) = _validate(userOp, maxCost);

        // Simulate postOp revert → fallback path
        _postOpReverted(context, 0.002 ether);

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
        uint256 solidarityAfter = _getSolidarity().balance;

        // Funded org: deposits should be charged (spent increases from pre-validation baseline)
        assertGt(finAfter.spent, finStart.spent, "Deposits should be charged in fallback");
        // Solidarity should NOT be counted (funded org, solidarity didn't pay the gas)
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should stay 0 for funded org");
        // L-28: a FUNDED grace org self-funds, so the 1% solidarity fee is not circular and MUST
        // be collected in the fallback path too (only genuinely unfunded grace orgs skip the fee).
        // Solidarity balance therefore increases by exactly the fee on the actual gas cost.
        uint256 expectedFee = (0.002 ether * uint256(_getSolidarity().feePercentageBps)) / 10000;
        assertEq(solidarityAfter, solidarityBefore + expectedFee, "funded fallback should credit the 1% fee (L-28)");
    }

    function testPostOpFallback_UnfundedGraceOrg_NoPhantomDebt() public {
        // Unfunded grace org — no deposits
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        (bytes memory context,) = _validate(userOp, maxCost);

        PaymasterHub.OrgFinancials memory finBefore = _getFinancials();
        assertEq(finBefore.deposited, 0, "Should have no deposits");

        _postOpReverted(context, 0.002 ether);

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();

        // Key assertion: spent should NOT exceed deposited (no phantom debt)
        assertLe(finAfter.spent, finAfter.deposited, "spent should not exceed deposited (no phantom debt)");
        // solidarityUsedThisPeriod should be incremented (solidarity paid via clamped deduction)
        assertGt(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should increase for unfunded");
    }

    function testPostOpFallback_PartiallyFunded_SplitsCorrectly() public {
        // Deposit less than what the op costs
        _depositForOrg(0.001 ether);

        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        (bytes memory context,) = _validate(userOp, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        _postOpReverted(context, 0.003 ether);

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
        uint256 solidarityAfter = _getSolidarity().balance;

        // Deposits should be drawn down (partially covers the cost)
        assertGt(finAfter.spent, 0, "Deposits should be partially used");
        // Solidarity should cover the remainder
        assertLt(solidarityAfter, solidarityBefore, "Solidarity should cover remainder");
        // solidarityUsedThisPeriod should track the solidarity portion
        assertGt(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should track solidarity portion");
    }

    /*═══════════════════════ PERIOD RESET TESTS ═══════════════════════*/

    function testPeriodReset_DepositCrossesThreshold() public {
        // Start unfunded, use some grace subsidy
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.003 ether);

        PaymasterHub.OrgFinancials memory finBefore = _getFinancials();
        assertGt(finBefore.solidarityUsedThisPeriod, 0, "Should have solidarity usage");

        // Deposit crosses minDepositRequired → triggers period reset
        _depositForOrg(MIN_DEPOSIT_REQUIRED);

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should reset on deposit");
    }

    function testPeriodReset_TimeBasedAfter90Days() public {
        _depositForOrg(MIN_DEPOSIT_REQUIRED);

        // Use some matching
        uint256 maxCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.001 ether);

        PaymasterHub.OrgFinancials memory finMid = _getFinancials();
        assertGt(finMid.solidarityUsedThisPeriod, 0, "Should have solidarity usage");

        // Warp 91 days and deposit again → triggers time-based reset
        vm.warp(block.timestamp + 91 days);
        _depositForOrg(0.001 ether);

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "solidarityUsedThisPeriod should reset after 90 days");
    }

    function testPeriodReset_DepositBelowThreshold_NoReset() public {
        // Use some grace subsidy
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.003 ether);

        uint128 usageBefore = _getFinancials().solidarityUsedThisPeriod;
        assertGt(usageBefore, 0, "Should have solidarity usage");

        // Deposit below threshold — should NOT reset period
        _depositForOrg(MIN_DEPOSIT_REQUIRED / 10);

        uint128 usageAfter = _getFinancials().solidarityUsedThisPeriod;
        assertEq(usageAfter, usageBefore, "solidarityUsedThisPeriod should NOT reset for below-threshold deposit");
    }

    /*═══════════════════════ VALIDATION-POSTOP CONSISTENCY ═══════════════════════*/

    function testValidationPostOp_SpentReturnsToExpectedLevel() public {
        _depositForOrg(1 ether);

        PaymasterHub.OrgFinancials memory finStart = _getFinancials();
        uint128 spentStart = finStart.spent;

        uint256 maxCost = 0.005 ether;
        uint256 actualCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        (bytes memory context,) = _validate(userOp, maxCost);

        // During validation, spent should increase by reservation
        PaymasterHub.OrgFinancials memory finMid = _getFinancials();
        assertGt(finMid.spent, spentStart, "Spent should increase during validation (reservation)");

        _postOp(context, actualCost);

        // After postOp, spent should reflect only actualCost (not maxCost)
        PaymasterHub.OrgFinancials memory finEnd = _getFinancials();
        // For tier 4 during grace: spent increase = fromDeposits + 1% fee
        // (50/50 split but solidarity remaining = 0 for tier 4, so all from deposits + fee)
        assertGt(finEnd.spent, spentStart, "Spent should be higher than start");
        assertLt(finEnd.spent, finMid.spent, "Spent should be less than mid-validation (unreserved excess)");
    }

    function testValidationPostOp_UnfundedGrace_SpentUnchanged() public {
        // Unfunded grace: solidarity pays, org.spent should not change
        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        PaymasterHub.OrgFinancials memory finStart = _getFinancials();

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        PaymasterHub.OrgFinancials memory finEnd = _getFinancials();

        // Unfunded grace: 100% solidarity, 0 fee → spent should be unchanged
        assertEq(finEnd.spent, finStart.spent, "Spent should be unchanged for unfunded grace (solidarity pays)");
        assertEq(finEnd.deposited, 0, "Deposited should still be 0");
    }

    /*═══════════════════════ SOLIDARITY FEE BEHAVIOR ═══════════════════════*/

    function testPostGrace_SolidarityFeeCollected() public {
        _depositForOrg(MIN_DEPOSIT_REQUIRED); // Tier 1
        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.002 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.001 ether);

        uint256 solidarityAfter = _getSolidarity().balance;

        // Post-grace: solidarity balance changes due to fee collection + matching spend
        // Fee = 1% of 0.001 = 0.00001 ETH collected
        // Matching = some amount spent from solidarity
        // Net change = fee collected - matching spent
        // Since tier 1 gets matching, solidarity should decrease net
        // (matching spend > fee collected for small ops)
        assertTrue(solidarityAfter != solidarityBefore, "Solidarity balance should change post-grace");
    }

    function testGrace_FeeCollectedForFundedOrg() public {
        _depositForOrg(1 ether); // Tier 4

        uint256 maxCost = 0.004 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0.002 ether);

        uint256 solidarityAfter = _getSolidarity().balance;

        // Funded grace: 1% fee collected (tier 4 no matching, but fee still applies)
        uint256 expectedFee = (0.002 ether * 100) / 10000;
        assertEq(solidarityAfter, solidarityBefore + expectedFee, "1% fee collected even during grace for funded org");
    }

    /*═══════════════════════ SAME-BUNDLE BEHAVIOR ═══════════════════════*/

    function testSameBundle_TwoOpsReservations() public {
        _depositForOrg(0.01 ether);

        uint256 maxCost = 0.003 ether;

        // First op: validate (reserves maxCost from deposits)
        PackedUserOperation memory op1 = _buildUserOp(SENDER, maxCost);
        (bytes memory ctx1,) = _validate(op1, maxCost);

        // Second op: validate (should also succeed — deposits still available after reservation)
        PackedUserOperation memory op2 = _buildUserOp(SENDER, maxCost);
        op2.nonce = 1;
        (bytes memory ctx2,) = _validate(op2, maxCost);

        // Both postOps
        _postOp(ctx1, 0.001 ether);
        _postOp(ctx2, 0.001 ether);

        PaymasterHub.OrgFinancials memory fin = _getFinancials();
        // Both ops used deposits + solidarity matching
        assertGt(fin.spent, 0, "Deposits should be used for both ops");
    }

    /*═══════════════════════ FALLBACK ACCOUNTING PRECISION ═══════════════════════*/

    function testPostOpFallback_FullyFunded_PostGrace_FeeCollected() public {
        // Post-grace fully funded fallback should collect solidarity fee correctly
        _depositForOrg(1 ether);
        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory finStart = _getFinancials();

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOpReverted(context, 0.002 ether);

        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();

        // Post-grace: 1% fee = 0.00002 ETH should be collected
        uint256 expectedFee = (0.002 ether * 100) / 10000; // 1%
        assertEq(solidarityAfter, solidarityBefore + expectedFee, "Solidarity should gain fee from funded fallback");
        // Org should pay actualGasCost + fee
        assertEq(finAfter.spent - finStart.spent, 0.002 ether + expectedFee, "Org pays actualCost + fee");
        // No solidarity matching used in fallback
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "No solidarity matching in funded fallback");
    }

    function testPostOpFallback_PartiallyFunded_PostGrace_NoFee() public {
        // Post-grace partially funded: deposit >= minDeposit to pass validation,
        // but < actualGasCost + fee so fallback enters partial path.
        _depositForOrg(MIN_DEPOSIT_REQUIRED); // 0.003 ether
        vm.warp(block.timestamp + uint256(GRACE_DAYS) * 1 days + 1);

        uint256 maxCost = 0.005 ether;
        uint256 actualCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        uint256 solidarityBefore = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory finStart = _getFinancials();
        uint256 startDepositAvail = finStart.deposited > finStart.spent ? finStart.deposited - finStart.spent : 0;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOpReverted(context, actualCost);

        uint256 solidarityAfter = _getSolidarity().balance;
        PaymasterHub.OrgFinancials memory fin = _getFinancials();

        // Solidarity should DECREASE (absorbed the remainder), NO fee credited back
        assertLt(solidarityAfter, solidarityBefore, "Solidarity decreases for partially funded fallback");
        // solidarityUsedThisPeriod tracks only the solidarity portion
        uint256 expectedSolidarityUsed = actualCost - startDepositAvail;
        assertEq(fin.solidarityUsedThisPeriod, expectedSolidarityUsed, "solidarityUsed = actualCost - deposits");
        // Net accounting: deposits lost + solidarity lost = actualGasCost (no fee leak)
        uint256 depositsUsed = fin.spent - finStart.spent;
        uint256 solidarityUsed = solidarityBefore - solidarityAfter;
        assertEq(depositsUsed + solidarityUsed, actualCost, "Total accounting = actualGasCost exactly (no fee leak)");
    }

    /*═══════════════════════ ZERO SOLIDARITY BALANCE ═══════════════════════*/

    function testZeroSolidarityBalance_FundedGraceOrg_Succeeds() public {
        // Drain solidarity to 0, then verify funded org (tier 4) still works
        // (it doesn't need solidarity)

        // First, deploy a new paymaster with empty solidarity
        PaymasterHub impl2 = new PaymasterHub();
        bytes memory initData2 =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, ENTRY_POINT, HATS, address(this));
        PaymasterHub pm2 = PaymasterHub(payable(address(new ERC1967Proxy(address(impl2), initData2))));

        pm2.setOrgRegistrar(address(this));
        pm2.unpauseSolidarityDistribution();
        // Do NOT donate to solidarity — balance is 0
        pm2.setGracePeriodConfig(GRACE_DAYS, MAX_SPEND_DURING_GRACE, MIN_DEPOSIT_REQUIRED);

        bytes32 orgId2 = keccak256("zero-sol-org");

        // Build config
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        bool[] memory allowed = new bool[](1);
        uint32[] memory gasHints = new uint32[](1);
        targets[0] = RULE_TARGET;
        selectors[0] = RULE_SELECTOR;
        allowed[0] = true;

        bytes32 sk = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(SENDER)))));
        bytes32[] memory budgetKeys = new bytes32[](1);
        uint128[] memory budgetCaps = new uint128[](1);
        uint32[] memory budgetEpochLens = new uint32[](1);
        budgetKeys[0] = sk;
        budgetCaps[0] = BUDGET_CAP;
        budgetEpochLens[0] = BUDGET_EPOCH_LEN;

        PaymasterRuleLib.DeployConfig memory config = PaymasterRuleLib.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 100 gwei,
            maxPriorityFeePerGas: 100 gwei,
            maxCallGas: 5_000_000,
            maxVerificationGas: 5_000_000,
            maxPreVerificationGas: 500_000,
            ruleTargets: targets,
            ruleSelectors: selectors,
            ruleAllowed: allowed,
            ruleMaxCallGasHints: gasHints,
            budgetSubjectKeys: budgetKeys,
            budgetCapsPerEpoch: budgetCaps,
            budgetEpochLens: budgetEpochLens,
            typeTargets: new address[](0),
            typeIds: new bytes32[](0),
            rulesMode: 0
        });

        pm2.registerAndConfigureOrg{value: 0.1 ether}(orgId2, ADMIN_HAT, config);

        // Build UserOp targeting pm2
        uint256 maxCost = 0.004 ether;
        uint256 maxFeePerGas = 1 gwei;
        uint256 totalGas = maxCost / maxFeePerGas;
        uint128 verificationGas = 100_000;
        uint128 callGas = uint128(totalGas > 400_000 ? totalGas - 400_000 : 100_000);
        uint128 pmVerificationGas = 200_000;
        uint128 pmPostOpGas = 100_000;
        uint256 preVerificationGas =
            totalGas - uint256(verificationGas) - uint256(callGas) - uint256(pmVerificationGas) - uint256(pmPostOpGas);

        bytes memory paymasterData = abi.encodePacked(
            uint8(1), orgId2, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(SENDER))), uint32(0), uint64(0)
        );
        bytes memory paymasterAndData = abi.encodePacked(address(pm2), pmVerificationGas, pmPostOpGas, paymasterData);
        bytes memory innerCall = abi.encodeWithSelector(RULE_SELECTOR);
        bytes memory callData = abi.encodeWithSignature("execute(address,uint256,bytes)", RULE_TARGET, 0, innerCall);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: SENDER,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGas) << 128 | uint256(callGas)),
            preVerificationGas: preVerificationGas,
            gasFees: bytes32(uint256(maxFeePerGas) << 128 | uint256(maxFeePerGas)),
            paymasterAndData: paymasterAndData,
            signature: ""
        });

        // Validate should pass — tier 4 needs 0 solidarity
        vm.prank(ENTRY_POINT);
        (bytes memory context,) = pm2.validatePaymasterUserOp(userOp, bytes32(0), maxCost);

        // PostOp should pass — deposits cover everything
        vm.prank(ENTRY_POINT);
        pm2.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.002 ether, 0);

        // Solidarity gains 1% fee from funded org (even with 0 initial balance)
        uint256 expectedFee = (0.002 ether * 100) / 10000;
        assertEq(pm2.getSolidarityFund().balance, expectedFee, "Solidarity should gain 1% fee");
    }

    function testZeroSolidarityBalance_UnfundedGraceOrg_Reverts() public {
        // With 0 solidarity, unfunded grace org can't validate
        PaymasterHub impl2 = new PaymasterHub();
        bytes memory initData2 =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, ENTRY_POINT, HATS, address(this));
        PaymasterHub pm2 = PaymasterHub(payable(address(new ERC1967Proxy(address(impl2), initData2))));

        pm2.setOrgRegistrar(address(this));
        pm2.unpauseSolidarityDistribution();
        pm2.setGracePeriodConfig(GRACE_DAYS, MAX_SPEND_DURING_GRACE, MIN_DEPOSIT_REQUIRED);

        bytes32 orgId2 = keccak256("zero-sol-unfunded");

        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        bool[] memory allowed = new bool[](1);
        uint32[] memory gasHints = new uint32[](1);
        targets[0] = RULE_TARGET;
        selectors[0] = RULE_SELECTOR;
        allowed[0] = true;

        bytes32 sk = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(SENDER)))));
        bytes32[] memory budgetKeys = new bytes32[](1);
        uint128[] memory budgetCaps = new uint128[](1);
        uint32[] memory budgetEpochLens = new uint32[](1);
        budgetKeys[0] = sk;
        budgetCaps[0] = BUDGET_CAP;
        budgetEpochLens[0] = BUDGET_EPOCH_LEN;

        PaymasterRuleLib.DeployConfig memory config = PaymasterRuleLib.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 100 gwei,
            maxPriorityFeePerGas: 100 gwei,
            maxCallGas: 5_000_000,
            maxVerificationGas: 5_000_000,
            maxPreVerificationGas: 500_000,
            ruleTargets: targets,
            ruleSelectors: selectors,
            ruleAllowed: allowed,
            ruleMaxCallGasHints: gasHints,
            budgetSubjectKeys: budgetKeys,
            budgetCapsPerEpoch: budgetCaps,
            budgetEpochLens: budgetEpochLens,
            typeTargets: new address[](0),
            typeIds: new bytes32[](0),
            rulesMode: 0
        });

        // Register WITHOUT deposit
        pm2.registerAndConfigureOrg(orgId2, ADMIN_HAT, config);

        uint256 maxCost = 0.001 ether;
        uint256 maxFeePerGas = 1 gwei;
        uint256 totalGas = maxCost / maxFeePerGas;
        uint128 verificationGas = 100_000;
        uint128 callGas = uint128(totalGas > 400_000 ? totalGas - 400_000 : 100_000);
        uint128 pmVerificationGas = 200_000;
        uint128 pmPostOpGas = 100_000;
        uint256 preVerificationGas =
            totalGas - uint256(verificationGas) - uint256(callGas) - uint256(pmVerificationGas) - uint256(pmPostOpGas);

        bytes memory paymasterData = abi.encodePacked(
            uint8(1), orgId2, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(SENDER))), uint32(0), uint64(0)
        );

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: SENDER,
            nonce: 0,
            initCode: "",
            callData: abi.encodeWithSignature(
                "execute(address,uint256,bytes)", RULE_TARGET, 0, abi.encodeWithSelector(RULE_SELECTOR)
            ),
            accountGasLimits: bytes32(uint256(verificationGas) << 128 | uint256(callGas)),
            preVerificationGas: preVerificationGas,
            gasFees: bytes32(uint256(maxFeePerGas) << 128 | uint256(maxFeePerGas)),
            paymasterAndData: abi.encodePacked(address(pm2), pmVerificationGas, pmPostOpGas, paymasterData),
            signature: ""
        });

        // Should revert — solidarity has 0 balance, can't cover unfunded grace org
        vm.prank(ENTRY_POINT);
        vm.expectRevert(PaymasterHubErrors.InsufficientFunds.selector);
        pm2.validatePaymasterUserOp(userOp, bytes32(0), maxCost);
    }

    /*═══════════════════════ DEPOSITS DRAINED MID-PERIOD ═══════════════════════*/

    function testDepositsDrainedToZero_TransitionsToGraceSubsidy() public {
        // Start funded, drain deposits via ops, verify transition to grace subsidy
        _depositForOrg(0.004 ether);

        // Run ops to drain deposits
        for (uint256 i = 0; i < 3; i++) {
            uint256 maxCost = 0.002 ether;
            PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);
            userOp.nonce = i;
            (bytes memory context,) = _validate(userOp, maxCost);
            _postOp(context, 0.001 ether);
        }

        PaymasterHub.OrgFinancials memory finMid = _getFinancials();
        uint256 depositAvail = finMid.deposited > finMid.spent ? finMid.deposited - finMid.spent : 0;

        // If deposits are now below minDeposit, next op should use grace subsidy
        if (depositAvail < MIN_DEPOSIT_REQUIRED) {
            uint256 solidarityBefore = _getSolidarity().balance;

            PackedUserOperation memory userOp = _buildUserOp(SENDER, 0.001 ether);
            userOp.nonce = 3;
            (bytes memory context,) = _validate(userOp, 0.001 ether);
            _postOp(context, 0.0005 ether);

            uint256 solidarityAfter = _getSolidarity().balance;
            // Grace subsidy: solidarity should pay
            assertLt(solidarityAfter, solidarityBefore, "Should use grace subsidy after deposits drained");
        }
    }

    /*═══════════════════════ ACTUAL GAS COST = 0 ═══════════════════════*/

    function testActualGasCostZero_NoStateChanges() public {
        _depositForOrg(1 ether);

        uint256 maxCost = 0.005 ether;
        PackedUserOperation memory userOp = _buildUserOp(SENDER, maxCost);

        PaymasterHub.OrgFinancials memory finBefore = _getFinancials();
        uint256 solidarityBefore = _getSolidarity().balance;

        (bytes memory context,) = _validate(userOp, maxCost);
        _postOp(context, 0); // zero actual cost

        PaymasterHub.OrgFinancials memory finAfter = _getFinancials();
        uint256 solidarityAfter = _getSolidarity().balance;

        // With 0 actual cost: no deposits charged, no solidarity used, no fees
        assertEq(finAfter.spent, finBefore.spent, "No deposits charged for 0 gas cost");
        assertEq(solidarityAfter, solidarityBefore, "No solidarity change for 0 gas cost");
        assertEq(finAfter.solidarityUsedThisPeriod, 0, "No solidarity usage for 0 gas cost");
    }

    /*═══════════════════════ TIER BOUNDARY PRECISION ═══════════════════════*/

    function testTier1_ExactMinDeposit_MatchAllowance() public {
        // Tier 1: deposit = exactly minDeposit → match = 2x deposit
        uint256 matchAllowance = PaymasterGraceLib.calculateMatchAllowance(MIN_DEPOSIT_REQUIRED, MIN_DEPOSIT_REQUIRED);
        assertEq(matchAllowance, MIN_DEPOSIT_REQUIRED * 2, "Tier 1: match = 2x deposit");
    }

    function testTier4_FiveXMinDeposit_ZeroMatch() public {
        // Tier 4: deposit >= 5x minDeposit → 0 match (self-funded)
        uint256 matchAllowance =
            PaymasterGraceLib.calculateMatchAllowance(MIN_DEPOSIT_REQUIRED * 5, MIN_DEPOSIT_REQUIRED);
        assertEq(matchAllowance, 0, "Tier 4: 0 match at 5x minDeposit");
    }

    function testTier3_JustUnder5X_CappedMatch() public {
        // Tier 3: deposit = 5x - 1 wei → capped match = 3x minDeposit
        uint256 matchAllowance =
            PaymasterGraceLib.calculateMatchAllowance(MIN_DEPOSIT_REQUIRED * 5 - 1, MIN_DEPOSIT_REQUIRED);
        assertEq(matchAllowance, MIN_DEPOSIT_REQUIRED * 3, "Tier 3: capped match at 3x minDeposit");
    }

    function testBelowMinDeposit_ZeroMatch() public {
        // Below min: 0 match
        uint256 matchAllowance =
            PaymasterGraceLib.calculateMatchAllowance(MIN_DEPOSIT_REQUIRED - 1, MIN_DEPOSIT_REQUIRED);
        assertEq(matchAllowance, 0, "Below minDeposit: 0 match");
    }
}
