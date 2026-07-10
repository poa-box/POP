// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubLens} from "../src/PaymasterHubLens.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {IPaymaster} from "../src/interfaces/IPaymaster.sol";
import {IEntryPoint} from "../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../src/interfaces/PackedUserOperation.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// Reuse the mature MockEntryPoint (pays real ETH via .transfer) and MockHats from the solidarity suite.
import {MockEntryPoint, MockHats} from "./PaymasterHubSolidarity.t.sol";

/// @title PaymasterHubSecurityTest
/// @notice Regression coverage for the WS-C security remediation: M-04 (withdraw paths),
///         M-05 (solidarity reservation), M-10 (setProtocolAdmin auth), M-12 (depositToEntryPoint
///         credits the org), plus L-29 (adminBatchAddRules checks).
contract PaymasterHubSecurityTest is Test {
    PaymasterHub public hub;
    PaymasterHubLens public lens;
    MockEntryPoint public ep;
    MockHats public hats;

    address public poaManager = address(0xA0A);
    address public orgAdmin = address(0xADACE);
    address public stranger = address(0xBAD);
    address payable public recipient = payable(address(0xEC));

    uint256 constant ADMIN_HAT = 1;
    bytes32 constant ORG = keccak256("SEC_ORG");

    address constant RULE_TARGET = address(0xBEEF);
    bytes4 constant RULE_SELECTOR = bytes4(keccak256("doSomething()"));
    uint8 constant SUBJECT_TYPE_ACCOUNT = 0x00;
    uint8 constant SUBJECT_TYPE_POA_ONBOARDING = 0x03;

    function setUp() public {
        ep = new MockEntryPoint();
        hats = new MockHats();

        PaymasterHub impl = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(ep), address(hats), poaManager);
        hub = PaymasterHub(payable(address(new ERC1967Proxy(address(impl), initData))));
        lens = new PaymasterHubLens(address(hub));

        hats.mintHat(ADMIN_HAT, orgAdmin);

        vm.startPrank(poaManager);
        hub.registerOrg(ORG, ADMIN_HAT, 0);
        hub.unpauseSolidarityDistribution();
        // Allow the rule target/selector for validation tests.
        vm.stopPrank();

        vm.startPrank(orgAdmin);
        hub.setRule(ORG, RULE_TARGET, RULE_SELECTOR, true, 0);
        // Budget for the account subject used in the sponsored-op helper (large cap so budget
        // is never the binding constraint in the M-04/M-05 tests).
        bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(orgAdmin)))));
        hub.setBudget(ORG, subjectKey, type(uint128).max, 7 days);
        vm.stopPrank();

        hub.donateToSolidarity{value: 10 ether}();
        vm.deal(address(this), 1000 ether);
        vm.deal(orgAdmin, 100 ether);
    }

    /*═══════════════════════ M-04: withdrawOrgDeposit ═══════════════════════*/

    function testWithdrawOrgDeposit_AdminRecoversUnspent() public {
        hub.depositForOrg{value: 5 ether}(ORG);
        assertEq(hub.getOrgFinancials(ORG).deposited, 5 ether);

        uint256 recipientBefore = recipient.balance;
        vm.prank(orgAdmin);
        hub.withdrawOrgDeposit(ORG, recipient, 2 ether);

        assertEq(recipient.balance, recipientBefore + 2 ether, "recipient did not receive ETH");
        assertEq(hub.getOrgFinancials(ORG).deposited, 3 ether, "deposited not reduced");
    }

    function testWithdrawOrgDeposit_ExceedingAvailableReverts() public {
        hub.depositForOrg{value: 1 ether}(ORG);
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.withdrawOrgDeposit(ORG, recipient, 1 ether + 1);
    }

    function testWithdrawOrgDeposit_BoundedByDepositedMinusSpent() public {
        // Deposit 2, simulate 0.5 spent via a sponsored op so available = 1.5.
        hub.depositForOrg{value: 2 ether}(ORG);
        _sponsorOnce(0.5 ether, 0.5 ether);
        uint256 spent = hub.getOrgFinancials(ORG).spent;
        uint256 available = uint256(hub.getOrgFinancials(ORG).deposited) - spent;

        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.withdrawOrgDeposit(ORG, recipient, available + 1);

        // Exactly-available succeeds.
        vm.prank(orgAdmin);
        hub.withdrawOrgDeposit(ORG, recipient, available);
    }

    function testWithdrawOrgDeposit_NonAdminReverts() public {
        hub.depositForOrg{value: 1 ether}(ORG);
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotAdmin.selector);
        hub.withdrawOrgDeposit(ORG, recipient, 0.5 ether);
    }

    function testWithdrawOrgDeposit_ZeroRecipientReverts() public {
        hub.depositForOrg{value: 1 ether}(ORG);
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.ZeroAddress.selector);
        hub.withdrawOrgDeposit(ORG, payable(address(0)), 0.5 ether);
    }

    function testWithdrawOrgDeposit_UnregisteredOrgReverts() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.OrgNotRegistered.selector);
        hub.withdrawOrgDeposit(keccak256("nope"), recipient, 1);
    }

    /*═══════════════════════ M-04: withdrawSolidarity ═══════════════════════*/

    function testWithdrawSolidarity_PoaManagerRecovers() public {
        uint256 before = hub.getSolidarityFund().balance;
        uint256 recipientBefore = recipient.balance;

        vm.prank(poaManager);
        hub.withdrawSolidarity(recipient, 1 ether);

        assertEq(hub.getSolidarityFund().balance, before - 1 ether, "solidarity balance not reduced");
        assertEq(recipient.balance, recipientBefore + 1 ether, "recipient did not receive ETH");
    }

    function testWithdrawSolidarity_NonManagerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.withdrawSolidarity(recipient, 1 ether);
    }

    function testWithdrawSolidarity_ExceedingBalanceReverts() public {
        uint256 bal = hub.getSolidarityFund().balance;
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.InsufficientFunds.selector);
        hub.withdrawSolidarity(recipient, bal + 1);
    }

    /*═══════════════════════ M-10: setProtocolAdmin ═══════════════════════*/

    function testSetProtocolAdmin_NonManagerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setProtocolAdmin(stranger);
    }

    function testSetProtocolAdmin_ManagerSucceeds() public {
        vm.prank(poaManager);
        hub.setProtocolAdmin(address(0xA11CE));
        // protocolAdmin now authorizes adminBatchAddRules (no revert path).
        bytes32[] memory orgs = new bytes32[](1);
        address[] memory targets = new address[](1);
        bytes4[] memory sels = new bytes4[](1);
        orgs[0] = ORG;
        targets[0] = RULE_TARGET;
        sels[0] = bytes4(0x12345678);
        vm.prank(address(0xA11CE));
        hub.adminBatchAddRules(orgs, targets, sels);
        assertTrue(hub.getRule(ORG, RULE_TARGET, bytes4(0x12345678)).allowed);
    }

    function testSetProtocolAdmin_IsReRunnable() public {
        vm.startPrank(poaManager);
        hub.setProtocolAdmin(address(0x1));
        hub.setProtocolAdmin(address(0x2)); // not a one-shot reinitializer
        vm.stopPrank();
    }

    /*═══════════════════════ M-12: depositToEntryPoint credits org ═══════════════════════*/

    function testDepositToEntryPoint_CreditsOrg() public {
        assertEq(hub.getOrgFinancials(ORG).deposited, 0);
        vm.prank(orgAdmin);
        hub.depositToEntryPoint{value: 3 ether}(ORG);
        assertEq(hub.getOrgFinancials(ORG).deposited, 3 ether, "org not credited");
        // And is now recoverable — proving it is truly org-scoped, not lost to the shared pool.
        vm.prank(orgAdmin);
        hub.withdrawOrgDeposit(ORG, recipient, 3 ether);
        assertEq(hub.getOrgFinancials(ORG).deposited, 0);
    }

    function testDepositToEntryPoint_ZeroReverts() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.ZeroAmount.selector);
        hub.depositToEntryPoint{value: 0}(ORG);
    }

    /*═══════════════════════ L-29: adminBatchAddRules checks ═══════════════════════*/

    function testAdminBatchAddRules_LengthMismatchReverts() public {
        bytes32[] memory orgs = new bytes32[](2);
        address[] memory targets = new address[](1);
        bytes4[] memory sels = new bytes4[](2);
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.ArrayLengthMismatch.selector);
        hub.adminBatchAddRules(orgs, targets, sels);
    }

    function testAdminBatchAddRules_ZeroTargetReverts() public {
        bytes32[] memory orgs = new bytes32[](1);
        address[] memory targets = new address[](1);
        bytes4[] memory sels = new bytes4[](1);
        orgs[0] = ORG;
        targets[0] = address(0);
        sels[0] = bytes4(0x11111111);
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.ZeroAddress.selector);
        hub.adminBatchAddRules(orgs, targets, sels);
    }

    /*═══════════════════════ M-11: Lens.wouldValidate onboarding branch ═══════════════════════*/

    /// @notice Before M-11 the onboarding branch was unreachable (OrgNotRegistered/OrgIdMismatch
    ///         fired first for the required orgId==0). Onboarding must be enabled by default here.
    function testM11_WouldValidate_OnboardingReturnsSane() public {
        // Fund onboarding-usable solidarity (already 10 ether donated) and keep distribution live.
        PackedUserOperation memory op = _buildOnboardingUserOp(address(0xCAFE));
        (bool valid, string memory reason) = lens.wouldValidate(bytes32(0), op, 0.001 ether);
        assertTrue(valid, "onboarding op should validate via the lens");
        assertEq(reason, "Onboarding");
    }

    /// @notice When distribution is paused, onboarding cannot be sponsored — the lens must say so
    ///         (previously it could never even reach this branch).
    function testM11_WouldValidate_OnboardingPausedRejected() public {
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();
        PackedUserOperation memory op = _buildOnboardingUserOp(address(0xCAFE));
        (bool valid, string memory reason) = lens.wouldValidate(bytes32(0), op, 0.001 ether);
        assertFalse(valid);
        assertEq(reason, "SolidarityDistributionIsPaused");
    }

    /// @notice A gas cost above the onboarding cap is predicted as GasTooHigh (was unreachable).
    function testM11_WouldValidate_OnboardingGasTooHigh() public view {
        PackedUserOperation memory op = _buildOnboardingUserOp(address(0xCAFE));
        PaymasterHub.OnboardingConfig memory onb = hub.getOnboardingConfig();
        (bool valid, string memory reason) = lens.wouldValidate(bytes32(0), op, uint256(onb.maxGasPerCreation) + 1);
        assertFalse(valid);
        assertEq(reason, "GasTooHigh");
    }

    /*═══════════════════════ M-05: solidarity bundle reservation ═══════════════════════*/

    /// @notice Two grace-org UserOps validated back-to-back (no postOp between, i.e. a bundle)
    ///         cannot together exceed maxSpendDuringGrace. Before M-05 both would validate against
    ///         the same un-reserved counter; now the first reserves and the second is bounded.
    function testM05_TwoGraceUserOpsInBundleCannotExceedGraceLimit() public {
        // Grace org, zero deposit: draws entirely from solidarity, capped at maxSpendDuringGrace.
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        uint256 half = uint256(grace.maxSpendDuringGrace) / 2;
        uint256 maxCost = half + 1; // two of these exceed the grace limit

        PackedUserOperation memory op1 = _buildUserOp(orgAdmin, maxCost, 0);
        vm.prank(address(ep));
        hub.validatePaymasterUserOp(op1, bytes32(0), maxCost);

        // Second op in the SAME bundle (no postOp ran) must now see the reservation and revert.
        PackedUserOperation memory op2 = _buildUserOp(orgAdmin, maxCost, 1);
        vm.prank(address(ep));
        vm.expectRevert(PaymasterHubErrors.GracePeriodSpendLimitReached.selector);
        hub.validatePaymasterUserOp(op2, bytes32(0), maxCost);
    }

    /// @notice The reservation is reconciled in postOp: after the first op's postOp runs with a
    ///         smaller actual cost, the reserved amount is released and solidarityUsedThisPeriod
    ///         reflects only the actual draw.
    function testM05_ReservationReconciledInPostOp() public {
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        uint256 maxCost = uint256(grace.maxSpendDuringGrace) / 2;

        PackedUserOperation memory op1 = _buildUserOp(orgAdmin, maxCost, 0);
        vm.prank(address(ep));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(op1, bytes32(0), maxCost);

        // During validation the whole maxCost is reserved.
        assertEq(hub.getOrgFinancials(ORG).solidarityUsedThisPeriod, maxCost, "reservation not applied");

        // PostOp with a smaller actual cost unreserves and applies the actual.
        uint256 actual = maxCost / 4;
        vm.prank(address(ep));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actual, 0);
        assertEq(hub.getOrgFinancials(ORG).solidarityUsedThisPeriod, actual, "not reconciled to actual");
    }

    /*═════════ WS-C gas/fee unpack regression (ERC-4337 v0.7 canonical) ═════════*/
    // These validatePaymasterUserOp tests reproduce the zk-email scenario that exposed the reversed
    // UserOpLib helpers. The gas/fee words are built as RAW canonical bytes32 (verification in the
    // HIGH 128 bits, callGas in the LOW; maxPriorityFeePerGas HIGH, maxFeePerGas LOW) — NEVER via the
    // repo's pack helper — with ASYMMETRIC halves, so a re-introduced swap cannot round-trip to green.
    // Reference: ERC-4337 v0.7 / eth-infinitism UserOperationLib.

    /// @notice zk-email scenario: rule hint 1.2M, op has callGas 500k (< hint) but verification 1.5M.
    ///         Canonical: rule compares maxCallGasHint vs callGasLimit (LOW half = 500k) → PASSES.
    ///         Pre-fix (reversed) lib compared the HIGH half (verification 1.5M > 1.2M) → false GasTooHigh.
    function testWSC_RuleHint_ComparesCallGasNotVerification_Passes() public {
        // Rule hint 1.2M callGas. (setUp registered ORG with adminHat only; orgAdmin is admin.)
        vm.prank(orgAdmin);
        hub.setRule(ORG, RULE_TARGET, RULE_SELECTOR, true, 1_200_000);

        // Raw canonical accountGasLimits: verification = 1_500_000 (HIGH), callGas = 500_000 (LOW).
        bytes32 accountGasLimits = bytes32((uint256(1_500_000) << 128) | uint256(500_000));
        PackedUserOperation memory op = _buildRawGasUserOp(orgAdmin, 0, accountGasLimits, _gasFees(1 gwei, 1 gwei));

        // callGas 500k < 1.2M hint → must succeed. Buggy lib would revert GasTooHigh on verification 1.5M.
        vm.prank(address(ep));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
        assertTrue(ctx.length > 0, "op with callGas below the rule hint must validate");
    }

    /// @notice Mirror: swap the halves — verification 500k, callGas 1.5M — so the SAME 1.2M hint now
    ///         binds on the callGas half. Canonical compares callGas 1.5M > 1.2M → GasTooHigh (correct).
    ///         Proves the hint really binds on callGas, not verification.
    function testWSC_RuleHint_ComparesCallGasNotVerification_RevertsWhenCallGasExceeds() public {
        vm.prank(orgAdmin);
        hub.setRule(ORG, RULE_TARGET, RULE_SELECTOR, true, 1_200_000);

        // Raw canonical: verification = 500_000 (HIGH), callGas = 1_500_000 (LOW).
        bytes32 accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(1_500_000));
        PackedUserOperation memory op = _buildRawGasUserOp(orgAdmin, 0, accountGasLimits, _gasFees(1 gwei, 1 gwei));

        vm.prank(address(ep));
        vm.expectRevert(PaymasterHubErrors.GasTooHigh.selector);
        hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
    }

    /// @notice Fee-cap asymmetry: cap maxFeePerGas = 50 gwei; op has maxPriorityFeePerGas = 100 gwei
    ///         (HIGH) and maxFeePerGas = 10 gwei (LOW). Canonical compares the real maxFee (LOW = 10)
    ///         against the cap → 10 < 50 → PASSES. The pre-fix lib compared the priority (100) against
    ///         the maxFee cap → false FeeTooHigh.
    function testWSC_FeeCap_ComparesMaxFeeNotPriority_Passes() public {
        // maxFeePerGas cap 50 gwei; leave priority cap at 0 (unset → skipped) and gas caps at 0.
        vm.prank(orgAdmin);
        hub.setFeeCaps(ORG, 50 gwei, 0, 0, 0, 0);
        // Rule with no hint so only the fee-cap path can gate this op.
        vm.prank(orgAdmin);
        hub.setRule(ORG, RULE_TARGET, RULE_SELECTOR, true, 0);

        // Raw canonical gasFees: maxPriorityFeePerGas = 100 gwei (HIGH), maxFeePerGas = 10 gwei (LOW).
        bytes32 gasFees = bytes32((uint256(uint128(100 gwei)) << 128) | uint256(uint128(10 gwei)));
        bytes32 accountGasLimits = bytes32((uint256(100_000) << 128) | uint256(100_000));
        PackedUserOperation memory op = _buildRawGasUserOp(orgAdmin, 0, accountGasLimits, gasFees);

        // real maxFee 10 gwei < 50 gwei cap → must pass. Buggy lib checked priority 100 gwei > 50 → revert.
        vm.prank(address(ep));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
        assertTrue(ctx.length > 0, "op whose real maxFee is under the cap must validate");
    }

    /*═══════════════════════ helpers ═══════════════════════*/

    /// @dev Build a single-call (execute → RULE_TARGET.RULE_SELECTOR) op with RAW gas words supplied by
    ///      the caller. Unlike _buildUserOp this does NOT derive gas from maxCost — the point is to feed
    ///      hardcoded canonical accountGasLimits/gasFees so a reversed UserOpLib is observable.
    function _buildRawGasUserOp(address sender, uint256 nonce, bytes32 accountGasLimits, bytes32 gasFees)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes memory innerCall = abi.encodeWithSelector(RULE_SELECTOR);
        bytes memory callData = abi.encodeWithSignature("execute(address,uint256,bytes)", RULE_TARGET, 0, innerCall);
        bytes memory paymasterData = abi.encodePacked(
            uint8(1), ORG, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(sender))), uint32(0), uint64(0)
        );
        bytes memory paymasterAndData =
            abi.encodePacked(address(hub), uint128(200_000), uint128(100_000), paymasterData);
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: 50_000,
            gasFees: gasFees,
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    /// @dev Raw canonical gasFees word: maxPriorityFeePerGas HIGH, maxFeePerGas LOW (ERC-4337 v0.7).
    function _gasFees(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) internal pure returns (bytes32) {
        return bytes32((uint256(maxPriorityFeePerGas) << 128) | uint256(maxFeePerGas));
    }

    /// @dev Build an onboarding UserOp (subjectType 0x03, orgId 0) for lens-prediction tests.
    ///      callData / initCode content is irrelevant to the lens (it does not parse them), so a
    ///      minimal envelope suffices to exercise the onboarding branch of wouldValidate.
    function _buildOnboardingUserOp(address sender) internal view returns (PackedUserOperation memory) {
        bytes memory paymasterData = abi.encodePacked(
            uint8(1), // version
            bytes32(0), // orgId = 0 (required for onboarding)
            SUBJECT_TYPE_POA_ONBOARDING, // subjectType 0x03
            bytes32(0), // subjectId = 0
            uint32(0), // ruleId = GENERIC
            uint64(0) // trailing
        );
        bytes memory paymasterAndData =
            abi.encodePacked(address(hub), uint128(200_000), uint128(100_000), paymasterData);
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100_000) << 128 | uint256(100_000)),
            preVerificationGas: 50_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    /// @dev Run one full validate+postOp cycle so org.spent increments by `actual`.
    function _sponsorOnce(uint256 maxCost, uint256 actual) internal {
        PackedUserOperation memory op = _buildUserOp(orgAdmin, maxCost, 0);
        vm.prank(address(ep));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(op, bytes32(0), maxCost);
        vm.prank(address(ep));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actual, 0);
    }

    function _buildUserOp(address sender, uint256 maxCost, uint256 nonce)
        internal
        view
        returns (PackedUserOperation memory)
    {
        uint256 maxFeePerGas = 1 gwei;
        uint256 totalGas = maxCost / maxFeePerGas;
        uint128 verificationGas = 100_000;
        uint128 callGas = uint128(totalGas > 400_000 ? totalGas - 400_000 : 100_000);
        uint128 pmVerificationGas = 200_000;
        uint128 pmPostOpGas = 100_000;
        uint256 preVerificationGas = totalGas > (uint256(verificationGas) + callGas + pmVerificationGas + pmPostOpGas)
            ? totalGas - uint256(verificationGas) - callGas - pmVerificationGas - pmPostOpGas
            : 0;

        bytes32 accountGasLimits = bytes32(uint256(verificationGas) << 128 | uint256(callGas));
        bytes32 gasFees = bytes32(uint256(maxFeePerGas) << 128 | uint256(maxFeePerGas));

        bytes memory innerCall = abi.encodeWithSelector(RULE_SELECTOR);
        bytes memory callData = abi.encodeWithSignature("execute(address,uint256,bytes)", RULE_TARGET, 0, innerCall);

        bytes memory paymasterData = abi.encodePacked(
            uint8(1), ORG, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(sender))), uint32(0), uint64(0)
        );
        bytes memory paymasterAndData = abi.encodePacked(address(hub), pmVerificationGas, pmPostOpGas, paymasterData);

        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: preVerificationGas,
            gasFees: gasFees,
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }
}
