// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {PaymasterHubLens} from "../src/PaymasterHubLens.sol";
import {IPaymaster} from "../src/interfaces/IPaymaster.sol";
import {IEntryPoint} from "../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation, UserOpLib} from "../src/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockEntryPointClaim is IEntryPoint {
    mapping(address => uint256) private _deposits;

    function depositTo(address account) external payable override {
        _deposits[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(_deposits[msg.sender] >= withdrawAmount, "Insufficient deposit");
        _deposits[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _deposits[account];
    }
}

/// @dev Minimal Hats stand-in with just the selectors the hub calls (isWearerOfHat/isEligible/viewHat).
///      EVERY wearer is ineligible for every hat — proving the CLAIM path truly skips eligibility.
contract MockHatsClaim {
    mapping(address => mapping(uint256 => bool)) public wearers;

    function mintHat(uint256 hatId, address wearer) external {
        wearers[wearer][hatId] = true;
    }

    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool) {
        return wearers[wearer][hatId];
    }

    function isEligible(address, uint256) external pure returns (bool) {
        return false; // nobody is eligible — the CLAIM subject must not care
    }

    function viewHat(uint256)
        external
        pure
        returns (string memory, uint32, uint32, address, address, string memory, uint16, bool, bool)
    {
        return ("", 0, 0, address(0), address(0), "", 0, true, true);
    }
}

/**
 * @title PaymasterHubClaimSubjectTest
 * @notice SUBJECT_TYPE_CLAIM (0x05): sponsors calls TO an org-designated claim contract with NO
 *         validation-time wearer-eligibility check — the claim contract is the gate. Spend is bounded
 *         by the org's Budget for keccak(0x05, claimTarget) and by target/selector Rules; callData is
 *         BOUND to execute(claimTarget, 0, ...). Also covers the v0.7 UserOpLib packing-spec fix.
 */
contract PaymasterHubClaimSubjectTest is Test {
    PaymasterHub public hub;
    MockEntryPointClaim public entryPoint;
    MockHatsClaim public hats;

    address public poaManager = address(0x1);
    address public orgAdmin = address(0x2);
    address public freshClaimer = address(0xF7e5); // wears nothing, eligible for nothing
    address public claimTarget = address(0xC1A1); // the org's ZkEmailInvites-style claim contract

    uint256 constant ADMIN_HAT = 1;
    uint256 constant OPERATOR_HAT = 2;
    bytes32 constant ORG = keccak256("CLAIM_ORG");

    uint8 constant PAYMASTER_DATA_VERSION = 1;
    uint8 constant SUBJECT_TYPE_HAT = 0x01;
    uint8 constant SUBJECT_TYPE_CLAIM = 0x05;
    uint256 constant MAX_COST = 0.001 ether;
    bytes4 constant CLAIM_SELECTOR = bytes4(0x24b5e3ba); // claimRoleByDomain (post-Blocker-2)

    function setUp() public {
        entryPoint = new MockEntryPointClaim();
        hats = new MockHatsClaim();

        PaymasterHub implementation = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(entryPoint), address(hats), poaManager);
        hub = PaymasterHub(payable(address(new ERC1967Proxy(address(implementation), initData))));

        hats.mintHat(ADMIN_HAT, orgAdmin);
        vm.deal(poaManager, 100 ether);
        vm.deal(orgAdmin, 100 ether);

        vm.startPrank(poaManager);
        hub.registerOrg(ORG, ADMIN_HAT, OPERATOR_HAT);
        hub.unpauseSolidarityDistribution();
        vm.stopPrank();

        // Fund the org so _checkOrgBalance passes outside grace nuances.
        hub.depositForOrg{value: 1 ether}(ORG);
    }

    /* ───────────────────────────── helpers ───────────────────────────── */

    function _subjectKey(address target) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SUBJECT_TYPE_CLAIM, bytes32(uint256(uint160(target)))));
    }

    function _allowRuleAndBudget() internal {
        vm.startPrank(poaManager);
        hub.setRule(ORG, claimTarget, CLAIM_SELECTOR, true, 0);
        hub.setBudget(ORG, _subjectKey(claimTarget), uint128(1 ether), uint32(7 days));
        vm.stopPrank();
    }

    function _claimCallData(address target, uint256 value) internal pure returns (bytes memory) {
        // execute(address,uint256,bytes) with a claim-selector inner payload (standard 0x60 offset).
        bytes memory inner = abi.encodeWithSelector(CLAIM_SELECTOR, uint256(1));
        return abi.encodeWithSelector(bytes4(0xb61d27f6), target, value, inner);
    }

    function _paymasterData(bytes32 orgId, uint8 subjectType, bytes32 subjectId) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(hub),
            uint128(200_000),
            uint128(100_000),
            PAYMASTER_DATA_VERSION,
            orgId,
            subjectType,
            subjectId,
            uint32(0)
        );
    }

    function _claimUserOp(address sender, bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: UserOpLib.packAccountGasLimits(100_000, 100_000),
            preVerificationGas: 100_000,
            gasFees: UserOpLib.packGasFees(1, 1),
            paymasterAndData: _paymasterData(ORG, SUBJECT_TYPE_CLAIM, bytes32(uint256(uint160(claimTarget)))),
            signature: ""
        });
    }

    function _validate(PackedUserOperation memory op) internal returns (bytes memory context, uint256 vd) {
        vm.prank(address(entryPoint));
        return hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    /* ─────────────────────── CLAIM subject: happy path ─────────────────────── */

    function testClaimSubjectSponsorsFreshIneligibleSender() public {
        _allowRuleAndBudget();
        // Sanity: the sender is eligible for NOTHING (MockHats.isEligible == false for all).
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));

        (bytes memory context, uint256 vd) = _validate(op);
        assertEq(vd, 0, "validation should pass with no time restrictions");
        assertGt(context.length, 0, "context returned for postOp");

        // Budget reserved at maxCost during validation.
        PaymasterHub.Budget memory b = hub.getBudget(ORG, _subjectKey(claimTarget));
        assertEq(uint256(b.usedInEpoch), MAX_COST, "maxCost reserved in claim budget");

        // postOp settles at actual cost.
        uint256 actual = MAX_COST / 4;
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, context, actual, 1);
        b = hub.getBudget(ORG, _subjectKey(claimTarget));
        assertEq(uint256(b.usedInEpoch), actual, "budget adjusted to actual cost in postOp");
    }

    function testClaimBudgetIsIsolatedFromHatSubjects() public {
        _allowRuleAndBudget();
        bytes32 hatKey = keccak256(abi.encodePacked(SUBJECT_TYPE_HAT, bytes32(uint256(42))));
        PaymasterHub.Budget memory hatBudget = hub.getBudget(ORG, hatKey);
        assertEq(uint256(hatBudget.capPerEpoch), 0, "hat subject budget untouched by claim budget");
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        _validate(op); // consumes the CLAIM budget only
        assertEq(uint256(hub.getBudget(ORG, hatKey).usedInEpoch), 0, "hat budget unaffected");
    }

    /* ─────────────────────── CLAIM subject: bindings ─────────────────────── */

    function testRevertWhenCallDataTargetsAnotherContract() public {
        _allowRuleAndBudget();
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(address(0xBEEF), 0));
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.Ineligible.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    function testRevertWhenValueNonZero() public {
        _allowRuleAndBudget();
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 1 wei));
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.Ineligible.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    function testRevertOnExecuteBatch() public {
        _allowRuleAndBudget();
        // executeBatch(address[],uint256[],bytes[]) — CLAIM binding rejects batch outright.
        address[] memory targets = new address[](1);
        targets[0] = claimTarget;
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(CLAIM_SELECTOR, uint256(1));
        bytes memory callData = abi.encodeWithSelector(bytes4(0x47e1da2a), targets, values, datas);

        PackedUserOperation memory op = _claimUserOp(freshClaimer, callData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.Ineligible.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    /* ─────────────────────── CLAIM subject: org gates still apply ─────────────────────── */

    function testRevertWithoutBudget() public {
        vm.prank(poaManager);
        hub.setRule(ORG, claimTarget, CLAIM_SELECTOR, true, 0); // rule but NO budget
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.BudgetExceeded.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    function testRevertWithoutRule() public {
        vm.prank(poaManager);
        hub.setBudget(ORG, _subjectKey(claimTarget), uint128(1 ether), uint32(7 days)); // budget but NO rule
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(PaymasterHubErrors.RuleDenied.selector, claimTarget, CLAIM_SELECTOR));
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    function testRevertUnregisteredOrg() public {
        _allowRuleAndBudget();
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        op.paymasterAndData = abi.encodePacked(
            address(hub),
            uint128(200_000),
            uint128(100_000),
            PAYMASTER_DATA_VERSION,
            keccak256("NOT_AN_ORG"),
            SUBJECT_TYPE_CLAIM,
            bytes32(uint256(uint160(claimTarget))),
            uint32(0)
        );
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgNotRegistered.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }

    /* ─────────────────────── Lens preflight mirrors the hub ─────────────────────── */

    function testLensWouldValidateMirrorsClaimBranch() public {
        PaymasterHubLens lens = new PaymasterHubLens(address(hub));
        _allowRuleAndBudget();

        // Valid claim op → preflight passes (would return InvalidSubjectType before the CLAIM arm).
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        (bool valid, string memory reason) = lens.wouldValidate(ORG, op, MAX_COST);
        assertTrue(valid, reason);

        // Op redirected to another target → preflight rejects like the hub does.
        PackedUserOperation memory evil = _claimUserOp(freshClaimer, _claimCallData(address(0xBEEF), 0));
        (bool evilValid, string memory evilReason) = lens.wouldValidate(ORG, evil, MAX_COST);
        assertFalse(evilValid);
        assertEq(evilReason, "Ineligible");
    }

    /* ─────────────────────── UserOpLib v0.7 spec-packing fix ─────────────────────── */

    function testUnpackAccountGasLimitsMatchesV07Spec() public pure {
        // v0.7: accountGasLimits = verificationGasLimit (HIGH 128) || callGasLimit (LOW 128).
        uint128 verification = 400_000;
        uint128 call = 123_456;
        bytes32 packed = bytes32((uint256(verification) << 128) | uint256(call)); // hand-packed per spec
        (uint128 v, uint128 c) = UserOpLib.unpackAccountGasLimits(packed);
        assertEq(v, verification, "verificationGasLimit must come from the HIGH 128 bits");
        assertEq(c, call, "callGasLimit must come from the LOW 128 bits");
        // Library pack round-trips against the spec layout.
        assertEq(UserOpLib.packAccountGasLimits(verification, call), packed, "pack must produce spec layout");
    }

    function testUnpackGasFeesMatchesV07Spec() public pure {
        // v0.7: gasFees = maxPriorityFeePerGas (HIGH 128) || maxFeePerGas (LOW 128).
        uint128 priority = 2 gwei;
        uint128 maxFee = 30 gwei;
        bytes32 packed = bytes32((uint256(priority) << 128) | uint256(maxFee));
        (uint128 p, uint128 m) = UserOpLib.unpackGasFees(packed);
        assertEq(p, priority, "maxPriorityFeePerGas must come from the HIGH 128 bits");
        assertEq(m, maxFee, "maxFeePerGas must come from the LOW 128 bits");
        assertEq(UserOpLib.packGasFees(priority, maxFee), packed, "pack must produce spec layout");
    }

    /// @dev The deployed-bug regression: a rule gas hint must cap the CALL gas (low bits), not the
    ///      verification gas — with a spec-packed op, a hint below callGasLimit rejects, and a hint
    ///      between callGasLimit and verificationGasLimit passes.
    function testRuleGasHintCapsCallGasNotVerificationGas() public {
        vm.startPrank(poaManager);
        hub.setRule(ORG, claimTarget, CLAIM_SELECTOR, true, 150_000); // hint
        hub.setBudget(ORG, _subjectKey(claimTarget), uint128(1 ether), uint32(7 days));
        vm.stopPrank();

        // verification 400k (over hint), call 100k (under hint) → must PASS (hint applies to call gas).
        PackedUserOperation memory op = _claimUserOp(freshClaimer, _claimCallData(claimTarget, 0));
        op.accountGasLimits = UserOpLib.packAccountGasLimits(400_000, 100_000);
        (bytes memory context,) = _validate(op);
        assertGt(context.length, 0);

        // call 200k (over hint) → must REVERT GasTooHigh regardless of verification being small.
        op.accountGasLimits = UserOpLib.packAccountGasLimits(50_000, 200_000);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.GasTooHigh.selector);
        hub.validatePaymasterUserOp(op, keccak256("op"), MAX_COST);
    }
}
