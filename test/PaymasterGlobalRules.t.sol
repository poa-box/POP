// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubLens} from "../src/PaymasterHubLens.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {PaymasterRuleLib} from "../src/libs/PaymasterRuleLib.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {DefaultGlobalRules} from "../script/helpers/DefaultGlobalRules.sol";
import {PackedUserOperation} from "../src/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockEntryPoint, MockHats} from "./PaymasterHubSolidarity.t.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {ZkEmailInvites} from "../src/ZkEmailInvites.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";

/// @title PaymasterGlobalRulesTest
/// @notice Coverage for the type-keyed GLOBAL RULEBOOK (PaymasterRuleLib): rulebook admin +
///         enumeration, per-org target-type mapping, Mirror/Static rules mode, per-pair block
///         veto, validation-time resolution (single + batch paths), adopt/snapshot for Static
///         orgs, deploy-time wiring via registerAndConfigureOrg, and Lens parity.
contract PaymasterGlobalRulesTest is Test {
    PaymasterHub public hub;
    PaymasterHubLens public lens;
    MockEntryPoint public ep;
    MockHats public hats;

    address public poaManager = address(0xA0A);
    address public protocolAdmin = address(0xAD31);
    address public orgAdmin = address(0xADACE);
    address public orgOperator = address(0x09E7);
    address public user = address(0xCAFE);
    address public stranger = address(0xBAD);

    uint256 constant ADMIN_HAT = 1;
    uint256 constant OPERATOR_HAT = 2;
    bytes32 constant ORG = keccak256("GLOBAL_RULES_ORG");

    // Two org "module proxies" and a couple of selectors
    address constant TASK_MANAGER = address(0x7A5C);
    address constant QUICK_JOIN = address(0x9105);
    bytes4 constant SEL_CLAIM_TASK = bytes4(keccak256("claimTask(uint256)"));
    bytes4 constant SEL_UNCLAIM_TASK = bytes4(keccak256("unclaimTask(uint256)"));
    bytes4 constant SEL_QUICK_JOIN = bytes4(keccak256("quickJoinWithUser()"));

    uint8 constant SUBJECT_TYPE_ACCOUNT = 0x00;
    uint8 constant MODE_MIRROR = 0;
    uint8 constant MODE_STATIC = 1;

    function setUp() public {
        ep = new MockEntryPoint();
        hats = new MockHats();

        PaymasterHub impl = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(ep), address(hats), poaManager);
        hub = PaymasterHub(payable(address(new ERC1967Proxy(address(impl), initData))));
        lens = new PaymasterHubLens(address(hub));

        hats.mintHat(ADMIN_HAT, orgAdmin);
        hats.mintHat(OPERATOR_HAT, orgOperator);

        vm.startPrank(poaManager);
        hub.registerOrg(ORG, ADMIN_HAT, OPERATOR_HAT);
        hub.unpauseSolidarityDistribution();
        vm.stopPrank();

        // Budget for the account subject so rule checks are the binding constraint.
        bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user)))));
        vm.prank(orgAdmin);
        hub.setBudget(ORG, subjectKey, type(uint128).max, 7 days);

        // Solidarity so the fresh org's grace period can draw during validation.
        vm.deal(address(this), 100 ether);
        hub.donateToSolidarity{value: 10 ether}();
    }

    /*═══════════════════════ Global rulebook admin ═══════════════════════*/

    function testSetGlobalRules_PoaManagerCanSet() public {
        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.GlobalRuleSet(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 123);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 123);

        PaymasterHub.Rule memory r = hub.getGlobalRule(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK);
        assertTrue(r.allowed);
        assertEq(r.maxCallGasHint, 123);
        assertEq(hub.getGlobalRuleCount(), 1);

        (bytes32 typeId, bytes4 selector, PaymasterHub.Rule memory rule) = hub.getGlobalRuleAt(0);
        assertEq(typeId, ModuleTypes.TASK_MANAGER_ID);
        assertEq(selector, SEL_CLAIM_TASK);
        assertTrue(rule.allowed);
    }

    function testSetGlobalRules_ProtocolAdminCanSet() public {
        vm.prank(poaManager);
        hub.setProtocolAdmin(protocolAdmin);

        vm.prank(protocolAdmin);
        hub.setGlobalRulesBatch(_one32(ModuleTypes.QUICK_JOIN_ID), _one4(SEL_QUICK_JOIN), _oneBool(true), _oneU32(0));
        assertTrue(hub.getGlobalRule(ModuleTypes.QUICK_JOIN_ID, SEL_QUICK_JOIN).allowed);
    }

    function testSetGlobalRules_UnauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setGlobalRulesBatch(_one32(ModuleTypes.TASK_MANAGER_ID), _one4(SEL_CLAIM_TASK), _oneBool(true), _oneU32(0));

        // Org admins manage LOCAL rules only — the global rulebook is protocol-level.
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setGlobalRulesBatch(_one32(ModuleTypes.TASK_MANAGER_ID), _one4(SEL_CLAIM_TASK), _oneBool(true), _oneU32(0));
    }

    function testSetGlobalRules_ZeroTypeIdReverts() public {
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.InvalidTypeId.selector);
        hub.setGlobalRulesBatch(_one32(bytes32(0)), _one4(SEL_CLAIM_TASK), _oneBool(true), _oneU32(0));
    }

    function testSetGlobalRules_LengthMismatchReverts() public {
        bytes32[] memory typeIds = new bytes32[](2);
        typeIds[0] = ModuleTypes.TASK_MANAGER_ID;
        typeIds[1] = ModuleTypes.QUICK_JOIN_ID;
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.ArrayLengthMismatch.selector);
        hub.setGlobalRulesBatch(typeIds, _one4(SEL_CLAIM_TASK), _oneBool(true), _oneU32(0));
    }

    function testSetGlobalRules_UpsertDoesNotDuplicate() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 100);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 200);
        assertEq(hub.getGlobalRuleCount(), 1);
        assertEq(hub.getGlobalRule(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK).maxCallGasHint, 200);
    }

    function testSetGlobalRules_RemoveDeletesAndUnenumerates() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _setGlobal(ModuleTypes.QUICK_JOIN_ID, SEL_QUICK_JOIN, true, 0);
        assertEq(hub.getGlobalRuleCount(), 3);

        // Remove the middle entry — swap-remove must keep enumeration + index map consistent.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, false, 0);
        assertEq(hub.getGlobalRuleCount(), 2);
        assertFalse(hub.getGlobalRule(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK).allowed);

        // Remaining two entries are still enumerable exactly once each.
        bool sawClaim;
        bool sawQuickJoin;
        for (uint256 i = 0; i < 2; i++) {
            (bytes32 typeId, bytes4 selector,) = hub.getGlobalRuleAt(i);
            if (typeId == ModuleTypes.TASK_MANAGER_ID && selector == SEL_CLAIM_TASK) sawClaim = true;
            if (typeId == ModuleTypes.QUICK_JOIN_ID && selector == SEL_QUICK_JOIN) sawQuickJoin = true;
        }
        assertTrue(sawClaim && sawQuickJoin, "enumeration lost an entry after swap-remove");

        // The moved entry's index stays valid: removing it again must work.
        _setGlobal(ModuleTypes.QUICK_JOIN_ID, SEL_QUICK_JOIN, false, 0);
        assertEq(hub.getGlobalRuleCount(), 1);
        (bytes32 lastType, bytes4 lastSel,) = hub.getGlobalRuleAt(0);
        assertEq(lastType, ModuleTypes.TASK_MANAGER_ID);
        assertEq(lastSel, SEL_CLAIM_TASK);
    }

    function testSetGlobalRules_RemoveNonexistentIsNoop() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, false, 0);
        assertEq(hub.getGlobalRuleCount(), 0);
    }

    function testSeedDefaultGlobalRules_IdempotentAndComplete() public {
        (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints) =
            DefaultGlobalRules.defaults();
        vm.prank(poaManager);
        hub.setGlobalRulesBatch(typeIds, selectors, allowed, hints);
        assertEq(hub.getGlobalRuleCount(), typeIds.length);

        // Re-seeding is idempotent (pure upserts).
        vm.prank(poaManager);
        hub.setGlobalRulesBatch(typeIds, selectors, allowed, hints);
        assertEq(hub.getGlobalRuleCount(), typeIds.length);

        // Spot checks: TaskManager claim + the zk-email gas hint.
        assertTrue(hub.getGlobalRule(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK).allowed);
        // Real compiler-derived selector (the old string-derived one was a latent bug).
        bytes4 zkSel = ZkEmailInvites.claimRoleByDomain.selector;
        assertEq(hub.getGlobalRule(ModuleTypes.ZKEMAIL_INVITES_ID, zkSel).maxCallGasHint, 800_000);
    }

    /*═══════════════════════ Target types / mode / block admin ═══════════════════════*/

    function testSetTargetTypes_AdminOperatorAndPoaCanSet() public {
        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.TargetTypeSet(ORG, TASK_MANAGER, ModuleTypes.TASK_MANAGER_ID);
        vm.prank(orgAdmin);
        hub.setTargetTypesBatch(ORG, _oneAddr(TASK_MANAGER), _one32(ModuleTypes.TASK_MANAGER_ID));
        assertEq(hub.getTargetType(ORG, TASK_MANAGER), ModuleTypes.TASK_MANAGER_ID);

        vm.prank(orgOperator);
        hub.setTargetTypesBatch(ORG, _oneAddr(QUICK_JOIN), _one32(ModuleTypes.QUICK_JOIN_ID));
        assertEq(hub.getTargetType(ORG, QUICK_JOIN), ModuleTypes.QUICK_JOIN_ID);

        // poaManager bypass (migration path for existing orgs) + clearing with bytes32(0).
        vm.prank(poaManager);
        hub.setTargetTypesBatch(ORG, _oneAddr(QUICK_JOIN), _one32(bytes32(0)));
        assertEq(hub.getTargetType(ORG, QUICK_JOIN), bytes32(0));
    }

    function testSetTargetTypes_UnauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setTargetTypesBatch(ORG, _oneAddr(TASK_MANAGER), _one32(ModuleTypes.TASK_MANAGER_ID));
    }

    function testSetTargetTypes_UnregisteredOrgReverts() public {
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.OrgNotRegistered.selector);
        hub.setTargetTypesBatch(keccak256("nope"), _oneAddr(TASK_MANAGER), _one32(ModuleTypes.TASK_MANAGER_ID));
    }

    function testSetTargetTypes_ZeroTargetReverts() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.ZeroAddress.selector);
        hub.setTargetTypesBatch(ORG, _oneAddr(address(0)), _one32(ModuleTypes.TASK_MANAGER_ID));
    }

    function testSetRulesMode_SwitchAndEvents() public {
        assertEq(hub.getRulesMode(ORG), MODE_MIRROR);

        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.RulesModeSet(ORG, MODE_STATIC);
        vm.prank(orgAdmin);
        hub.setRulesMode(ORG, MODE_STATIC);
        assertEq(hub.getRulesMode(ORG), MODE_STATIC);

        vm.prank(orgAdmin);
        hub.setRulesMode(ORG, MODE_MIRROR);
        assertEq(hub.getRulesMode(ORG), MODE_MIRROR);
    }

    function testSetRulesMode_InvalidModeReverts() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.InvalidRulesMode.selector);
        hub.setRulesMode(ORG, 2);
    }

    function testSetRulesMode_UnauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setRulesMode(ORG, MODE_STATIC);
    }

    function testSetGlobalRuleBlock_SetUnsetAndAuth() public {
        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.GlobalRuleBlockSet(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        assertTrue(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK));

        vm.prank(orgOperator);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false);
        assertFalse(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK));

        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
    }

    /*═══════════════════════ Validation-time resolution ═══════════════════════*/

    function testValidate_GlobalFallbackAllows() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        // No local rule exists — resolution must come from the global rulebook.
        assertFalse(hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK).allowed);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testValidate_NoTargetTypeDenies() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        // targetTypes NOT registered — the global rule must be unreachable.
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
    }

    function testValidate_StaticModeIgnoresGlobal() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        vm.prank(orgAdmin);
        hub.setRulesMode(ORG, MODE_STATIC);

        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
    }

    function testValidate_BlockedGlobalDenies() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);

        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);

        // Other selectors of the same target still resolve globally.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _validate(_op(TASK_MANAGER, SEL_UNCLAIM_TASK));

        // Unblocking restores the fallback.
        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testValidate_LocalRuleStillWins() public {
        // Regression: pure local rule with no global machinery involved.
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 0);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testValidate_LocalAllowWinsOverBlock() public {
        // An explicit local allow beats a global-rule block (block only vetoes the fallback).
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        vm.startPrank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 0);
        vm.stopPrank();
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testValidate_GlobalHintEnforced() public {
        // Global hint caps callGasLimit exactly like a local hint.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 50_000);
        _mapTaskManager();

        PackedUserOperation memory op = _op(TASK_MANAGER, SEL_CLAIM_TASK);
        // callGas in _op is 100_000 > 50_000 hint
        vm.prank(address(ep));
        vm.expectRevert(PaymasterHubErrors.GasTooHigh.selector);
        hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);

        // Raise the hint above callGas (100k) but BELOW verificationGas (300k) — must pass.
        // A resolver comparing the wrong accountGasLimits half (300k > 150k) would revert here.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 150_000);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testValidate_GlobalRuleRemovalRevokes() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));

        // Central kill-switch: removing the rulebook entry revokes sponsorship instantly.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, false, 0);
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
    }

    function testValidate_UnknownSelectorStillDenied() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        _validateExpectDenied(_op(TASK_MANAGER, SEL_UNCLAIM_TASK), TASK_MANAGER, SEL_UNCLAIM_TASK);
    }

    function testValidate_BatchInnerCallsResolveGlobal() public {
        // Inner call 1 resolves via a LOCAL rule, inner call 2 via the GLOBAL rulebook.
        vm.prank(orgAdmin);
        hub.setRule(ORG, QUICK_JOIN, SEL_QUICK_JOIN, true, 0);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        _validate(_batchOp(QUICK_JOIN, SEL_QUICK_JOIN, TASK_MANAGER, SEL_CLAIM_TASK));

        // If the global entry disappears, the whole batch is denied.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, false, 0);
        PackedUserOperation memory op = _batchOp(QUICK_JOIN, SEL_QUICK_JOIN, TASK_MANAGER, SEL_CLAIM_TASK);
        _validateExpectDenied(op, TASK_MANAGER, SEL_CLAIM_TASK);
    }

    /*═══════════════════════ Adopt / snapshot (Static-org governance) ═══════════════════════*/

    function testAdoptGlobalRules_CopiesEntry() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 77);
        _mapTaskManager();

        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.RuleSet(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 77);
        vm.prank(orgAdmin);
        hub.adoptGlobalRules(ORG, _oneAddr(TASK_MANAGER), _one4(SEL_CLAIM_TASK));

        PaymasterHub.Rule memory local = hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertTrue(local.allowed);
        assertEq(local.maxCallGasHint, 77);
    }

    function testAdoptGlobalRules_MissingGlobalReverts() public {
        _mapTaskManager();
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.GlobalRuleUnknown.selector);
        hub.adoptGlobalRules(ORG, _oneAddr(TASK_MANAGER), _one4(SEL_CLAIM_TASK));
    }

    function testAdoptGlobalRules_MissingTargetTypeReverts() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.InvalidTypeId.selector);
        hub.adoptGlobalRules(ORG, _oneAddr(TASK_MANAGER), _one4(SEL_CLAIM_TASK));
    }

    function testSnapshotGlobalRules_CopiesAllMatching() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 11);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 22);
        _setGlobal(ModuleTypes.QUICK_JOIN_ID, SEL_QUICK_JOIN, true, 33);
        _setGlobal(ModuleTypes.EDUCATION_HUB_ID, bytes4(keccak256("completeModule(uint256,uint8)")), true, 44);
        _mapTaskManager();
        vm.prank(orgAdmin);
        hub.setTargetTypesBatch(ORG, _oneAddr(QUICK_JOIN), _one32(ModuleTypes.QUICK_JOIN_ID));

        address[] memory targets = new address[](2);
        targets[0] = TASK_MANAGER;
        targets[1] = QUICK_JOIN;
        vm.prank(orgAdmin);
        hub.snapshotGlobalRules(ORG, targets);

        assertEq(hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK).maxCallGasHint, 11);
        assertEq(hub.getRule(ORG, TASK_MANAGER, SEL_UNCLAIM_TASK).maxCallGasHint, 22);
        assertEq(hub.getRule(ORG, QUICK_JOIN, SEL_QUICK_JOIN).maxCallGasHint, 33);
        assertTrue(hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK).allowed);
        // The EducationHub entry has no matching target — nothing copied for it.
        assertFalse(hub.getRule(ORG, TASK_MANAGER, bytes4(keccak256("completeModule(uint256,uint8)"))).allowed);
    }

    function testSnapshotThenStatic_KeepsSponsoring() public {
        // The recommended "pin your paymaster rules" governance batch:
        // snapshotGlobalRules + setRulesMode(Static) → sponsorship continues via local copies,
        // and later global additions do NOT apply.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        vm.startPrank(orgAdmin);
        hub.snapshotGlobalRules(ORG, _oneAddr(TASK_MANAGER));
        hub.setRulesMode(ORG, MODE_STATIC);
        vm.stopPrank();

        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));

        // A new global rule added afterwards does not reach the Static org.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _validateExpectDenied(_op(TASK_MANAGER, SEL_UNCLAIM_TASK), TASK_MANAGER, SEL_UNCLAIM_TASK);
    }

    /*═══════════════════════ registerAndConfigureOrg wiring ═══════════════════════*/

    function testRegisterAndConfigure_MirrorOrgResolvesGlobalImmediately() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);

        bytes32 org2 = keccak256("MIRROR_ORG2");
        _registerWithTypes(org2, MODE_MIRROR);

        assertEq(hub.getRulesMode(org2), MODE_MIRROR);
        assertEq(hub.getTargetType(org2, TASK_MANAGER), ModuleTypes.TASK_MANAGER_ID);
        // Zero local rules were written…
        assertFalse(hub.getRule(org2, TASK_MANAGER, SEL_CLAIM_TASK).allowed);
        // …yet the op validates through the rulebook.
        _validate(_opFor(org2, TASK_MANAGER, SEL_CLAIM_TASK));

        // And a rule added later covers the org with NO further per-org action.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _validate(_opFor(org2, TASK_MANAGER, SEL_UNCLAIM_TASK));
    }

    function testRegisterAndConfigure_StaticOrgGetsSnapshot() public {
        // Hint above the op's 100k callGas so the copied hint doesn't trip GasTooHigh.
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 150_000);

        bytes32 org3 = keccak256("STATIC_ORG3");
        _registerWithTypes(org3, MODE_STATIC);

        assertEq(hub.getRulesMode(org3), MODE_STATIC);
        // Deploy-time snapshot wrote a LOCAL copy of the rulebook entry.
        PaymasterHub.Rule memory local = hub.getRule(org3, TASK_MANAGER, SEL_CLAIM_TASK);
        assertTrue(local.allowed);
        assertEq(local.maxCallGasHint, 150_000);
        _validate(_opFor(org3, TASK_MANAGER, SEL_CLAIM_TASK));

        // Later global additions do not reach the Static org…
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _validateExpectDenied(_opFor(org3, TASK_MANAGER, SEL_UNCLAIM_TASK), TASK_MANAGER, SEL_UNCLAIM_TASK);
    }

    function testRegisterAndConfigure_InvalidModeReverts() public {
        PaymasterRuleLib.DeployConfig memory config = _typeConfig(2);
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.InvalidRulesMode.selector);
        hub.registerAndConfigureOrg(keccak256("BAD_MODE_ORG"), ADMIN_HAT, config);
    }

    function testRegisterAndConfigure_TypeArrayMismatchReverts() public {
        PaymasterRuleLib.DeployConfig memory config = _typeConfig(MODE_MIRROR);
        config.typeIds = new bytes32[](2); // mismatch vs 1 typeTarget
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.ArrayLengthMismatch.selector);
        hub.registerAndConfigureOrg(keccak256("MISMATCH_TYPES_ORG"), ADMIN_HAT, config);
    }

    /*═══════════════════════ Lens parity ═══════════════════════*/

    function testLens_EffectiveRuleOf() public {
        // Denied
        (bool allowed,, uint8 source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertFalse(allowed);
        assertEq(source, 0);

        // Global
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 42);
        _mapTaskManager();
        uint32 hint;
        (allowed, hint, source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertTrue(allowed);
        assertEq(hint, 42);
        assertEq(source, 2);
        assertTrue(lens.isAllowed(ORG, TASK_MANAGER, SEL_CLAIM_TASK));

        // Local wins (different hint proves the source)
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 43);
        (allowed, hint, source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertTrue(allowed);
        assertEq(hint, 43);
        assertEq(source, 1);

        // Blocked global (after clearing the local rule)
        vm.startPrank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        vm.stopPrank();
        (allowed,, source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertFalse(allowed);
        assertEq(source, 0);
        assertFalse(lens.isAllowed(ORG, TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testLens_WouldValidateAgreesWithHub() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        (bool valid, string memory reason) = lens.wouldValidate(ORG, _op(TASK_MANAGER, SEL_CLAIM_TASK), 0.001 ether);
        assertTrue(valid, reason);

        // Static flip: the predictor must deny exactly like the hub.
        vm.prank(orgAdmin);
        hub.setRulesMode(ORG, MODE_STATIC);
        (valid, reason) = lens.wouldValidate(ORG, _op(TASK_MANAGER, SEL_CLAIM_TASK), 0.001 ether);
        assertFalse(valid);
        assertEq(reason, "RuleDenied");
    }

    /*═══════════════════════ Legacy ABI (live OrgDeployer compatibility) ═══════════════════════*/

    /// @dev The deployed OrgDeployer proxies call the pre-rulebook 13-field selector. The v20
    ///      hub must keep serving it (legacy overload) or org deployment bricks between the hub
    ///      upgrade and a deployer upgrade.
    function testLegacyRegisterAndConfigure_OldSelectorServed() public {
        bytes4 legacySel = bytes4(
            keccak256(
                "registerAndConfigureOrg(bytes32,uint256,(uint256,uint256,uint256,uint32,uint32,uint32,address[],bytes4[],bool[],uint32[],bytes32[],uint128[],uint32[]))"
            )
        );
        // Pin the exact selector the live OrgDeployer bytecode emits.
        assertEq(legacySel, bytes4(0xc6f422d9), "legacy selector drifted from live OrgDeployer ABI");

        bytes32 org2 = keccak256("LEGACY_ABI_ORG");
        bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user)))));

        PaymasterRuleLib.LegacyDeployConfig memory cfg;
        cfg.ruleTargets = _oneAddr(TASK_MANAGER);
        cfg.ruleSelectors = _one4(SEL_CLAIM_TASK);
        cfg.ruleAllowed = _oneBool(true);
        cfg.ruleMaxCallGasHints = _oneU32(0);
        cfg.budgetSubjectKeys = _one32(subjectKey);
        cfg.budgetCapsPerEpoch = new uint128[](1);
        cfg.budgetCapsPerEpoch[0] = 1 ether;
        cfg.budgetEpochLens = new uint32[](1);
        cfg.budgetEpochLens[0] = 7 days;

        vm.prank(poaManager);
        (bool ok,) = address(hub).call(abi.encodeWithSelector(legacySel, org2, ADMIN_HAT, cfg));
        assertTrue(ok, "legacy registerAndConfigureOrg reverted -- live OrgDeployer would brick");

        // Pre-rulebook behavior: org registered, LOCAL rule + budget applied, no types, Mirror.
        assertEq(hub.getOrgConfig(org2).adminHatId, ADMIN_HAT);
        assertTrue(hub.getRule(org2, TASK_MANAGER, SEL_CLAIM_TASK).allowed, "legacy local rule not seeded");
        assertEq(hub.getBudget(org2, subjectKey).capPerEpoch, 1 ether, "legacy budget not applied");
        assertEq(hub.getRulesMode(org2), MODE_MIRROR);
        assertEq(hub.getTargetType(org2, TASK_MANAGER), bytes32(0), "legacy path must not register types");

        // And the legacy-seeded org validates through its local rule.
        _validate(_opFor(org2, TASK_MANAGER, SEL_CLAIM_TASK));
    }

    /*═══════════════════════ Explicit deny / reset semantics ═══════════════════════*/

    function testSetRuleFalse_ExplicitlyDeniesGlobal() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK)); // sponsored via rulebook

        // setRule(false) is an EXPLICIT DENY: it must actually revoke for a Mirror org
        // (blocks the global fallback too), not silently fall through to the rulebook.
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false, 0);
        assertTrue(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK), "explicit deny must block fallback");
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);

        // Re-allowing clears the standing block.
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 0);
        assertFalse(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK), "fresh allow must clear the block");
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    function testClearRule_ResetsToProtocolDefault() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 150_000);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK)); // local

        // clearRule = reset to protocol default: the pair falls BACK to the rulebook
        // (documented Mirror-org footgun — pinned here on the hub, not just the Lens).
        vm.prank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        (bool allowed,, uint8 source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertTrue(allowed, "cleared pair must fall back to the global rulebook");
        assertEq(source, 2);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));

        // clearRule after an explicit deny also resets (removes the block).
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false, 0);
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
        vm.prank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertFalse(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK), "clear must remove the block");
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    /*═══════════════════════ Snapshot / deploy-config edge semantics ═══════════════════════*/

    function testSnapshotOverwritesCustomLocalHint() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 200_000);
        _mapTaskManager();
        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 50_000); // stricter custom hint

        // Documented catch-up semantics: snapshot unconditionally overwrites with the global copy.
        vm.prank(orgAdmin);
        hub.snapshotGlobalRules(ORG, _oneAddr(TASK_MANAGER));
        assertEq(
            hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK).maxCallGasHint,
            200_000,
            "snapshot must overwrite a customized local hint"
        );
    }

    function testDeployConfig_ExplicitRulesOverrideSnapshot() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 111);

        PaymasterRuleLib.DeployConfig memory config = _typeConfig(MODE_STATIC);
        config.ruleTargets = _oneAddr(TASK_MANAGER);
        config.ruleSelectors = _one4(SEL_CLAIM_TASK);
        config.ruleAllowed = _oneBool(true);
        config.ruleMaxCallGasHints = _oneU32(222);

        bytes32 org2 = keccak256("EXPLICIT_OVERRIDE_ORG");
        vm.prank(poaManager);
        hub.registerAndConfigureOrg(org2, ADMIN_HAT, config);

        // Explicit deploy-time rules are applied AFTER the Static snapshot and must win.
        assertEq(
            hub.getRule(org2, TASK_MANAGER, SEL_CLAIM_TASK).maxCallGasHint,
            222,
            "explicit deploy rule must override the snapshot copy"
        );
    }

    /*═══════════════════════ Isolation / mode / batch edges ═══════════════════════*/

    function testCrossOrgIsolation_SharedTarget() public {
        // The same physical address (a shared registry) typed by org A only: org B's resolution
        // for that address must be unaffected by anything org A does.
        _setGlobal(ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID, SEL_QUICK_JOIN, true, 0);
        address sharedReg = address(0x5EE9);
        bytes32 orgB = keccak256("ISOLATION_ORG_B");
        _registerWithTypes(orgB, MODE_MIRROR); // types TASK_MANAGER only, not sharedReg

        vm.prank(orgAdmin);
        hub.setTargetTypesBatch(ORG, _oneAddr(sharedReg), _one32(ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID));

        assertTrue(lens.isAllowed(ORG, sharedReg, SEL_QUICK_JOIN), "org A should resolve via rulebook");
        assertFalse(lens.isAllowed(orgB, sharedReg, SEL_QUICK_JOIN), "org B must NOT inherit org A's typing");
        _validate(_op(sharedReg, SEL_QUICK_JOIN));
        _validateExpectDenied(_opFor(orgB, sharedReg, SEL_QUICK_JOIN), sharedReg, SEL_QUICK_JOIN);

        // Org A's block is equally org-scoped.
        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, sharedReg, SEL_QUICK_JOIN, true);
        _validateExpectDenied(_op(sharedReg, SEL_QUICK_JOIN), sharedReg, SEL_QUICK_JOIN);
        assertFalse(hub.isGlobalRuleBlocked(orgB, sharedReg, SEL_QUICK_JOIN), "block must not leak across orgs");
    }

    function testCoarseMode_SenderScopedResolution() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        // Coarse mode checks (sender, outer selector). The sender has no typeId mapping, so the
        // TASK_MANAGER rulebook entry must NOT apply — fail-closed.
        PackedUserOperation memory op =
            _rawOpWithRuleId(ORG, abi.encodeWithSelector(SEL_CLAIM_TASK, uint256(1)), 0x000000FF);
        _validateExpectDenied(op, user, SEL_CLAIM_TASK);

        // A local rule keyed on the SENDER allows coarse ops (pre-existing behavior).
        vm.prank(orgAdmin);
        hub.setRule(ORG, user, SEL_CLAIM_TASK, true, 0);
        _validate(op);

        // Typing the sender address (unusual but legal) resolves coarse via the rulebook too.
        vm.startPrank(orgAdmin);
        hub.clearRule(ORG, user, SEL_CLAIM_TASK);
        hub.setTargetTypesBatch(ORG, _oneAddr(user), _one32(ModuleTypes.TASK_MANAGER_ID));
        vm.stopPrank();
        _validate(op);
    }

    function testBatch_RawInnerCallDenied() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        // Inner call with <4-byte data resolves as selector bytes4(0) — no rulebook entry uses
        // it (DefaultGlobalRules has none), so a raw ETH transfer inside a batch stays denied
        // even when the target itself is typed.
        address[] memory targets = new address[](2);
        targets[0] = TASK_MANAGER;
        targets[1] = TASK_MANAGER;
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(SEL_CLAIM_TASK, uint256(1));
        datas[1] = ""; // raw transfer -> bytes4(0)
        bytes memory callData =
            abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[])", targets, values, datas);
        _validateExpectDenied(_rawOp(ORG, callData), TASK_MANAGER, bytes4(0));
    }

    /*═══════════════════════ adminBatchAddRules event parity ═══════════════════════*/

    /// @notice adminBatchAddRules must EMIT RuleSet for every write (the old inline write was
    ///         event-less — subgraph-invisible state) and share writeLocalRule's allow
    ///         semantics: a fresh allow clears any standing global-rule block for the pair.
    ///         Unregistered orgs are still skipped silently (no write, no event).
    function testAdminBatchAddRules_EmitsAndClearsBlocks() public {
        // Standing block from an earlier explicit deny — the batch allow must clear it.
        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);

        bytes32[] memory orgIds = new bytes32[](2);
        address[] memory targets = new address[](2);
        bytes4[] memory selectors = new bytes4[](2);
        orgIds[0] = ORG;
        targets[0] = TASK_MANAGER;
        selectors[0] = SEL_CLAIM_TASK;
        orgIds[1] = keccak256("NEVER_REGISTERED_ORG"); // must be skipped: no write, no event
        targets[1] = TASK_MANAGER;
        selectors[1] = SEL_CLAIM_TASK;

        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.RuleSet(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 0);
        vm.expectEmit(true, true, true, true);
        emit PaymasterHubErrors.GlobalRuleBlockSet(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false);
        vm.prank(poaManager);
        hub.adminBatchAddRules(orgIds, targets, selectors);

        assertTrue(hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK).allowed);
        assertFalse(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK), "batch allow must clear the block");
        assertFalse(
            hub.getRule(keccak256("NEVER_REGISTERED_ORG"), TASK_MANAGER, SEL_CLAIM_TASK).allowed,
            "unregistered org must be skipped"
        );
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    /*═══════════════════════ Pre-v20 explicit-denial preservation (P1) ═══════════════════════*/

    /// @dev Storage slot of rules[ORG][target][selector] — used to plant PRE-v20 state that the
    ///      post-v20 setters can no longer produce (they pair every deny with a block).
    function _legacyRuleSlot(address target, bytes4 selector) internal pure returns (bytes32) {
        bytes32 rulesLoc = keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.rules")) - 1));
        return keccak256(abi.encode(selector, keccak256(abi.encode(target, keccak256(abi.encode(ORG, rulesLoc))))));
    }

    /// @notice A pre-v20 explicit deny that stored a hint ({allowed:false, hint!=0}) must NEVER
    ///         fall through to the rulebook — the resolver honors it with no block needed.
    function testPreV20DenyWithHint_NeverFallsThrough() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();

        // Plant the pre-v20 write directly: old setRule stored {false, 777} with NO block.
        vm.store(address(hub), _legacyRuleSlot(TASK_MANAGER, SEL_CLAIM_TASK), bytes32(uint256(777)));
        PaymasterHub.Rule memory planted = hub.getRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertFalse(planted.allowed);
        assertEq(planted.maxCallGasHint, 777, "fixture must model the hinted pre-v20 deny");
        assertFalse(hub.isGlobalRuleBlocked(ORG, TASK_MANAGER, SEL_CLAIM_TASK), "no block exists pre-v20");

        // Denied by the RESOLVER alone — and the Lens agrees.
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
        (bool allowed,, uint8 source) = lens.effectiveRuleOf(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        assertFalse(allowed, "hinted pre-v20 deny must not resurrect via the rulebook");
        assertEq(source, 0);

        // clearRule still resets the pair to protocol default afterwards.
        vm.prank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        _validate(_op(TASK_MANAGER, SEL_CLAIM_TASK));
    }

    /// @notice A pre-v20 explicit deny written with hint=0 leaves a ZERO struct — on-chain state
    ///         cannot distinguish it from unset, so the migration reconstructs it as a block from
    ///         the RuleSet event log, applied BEFORE the target is typed (no sponsorship window).
    function testPreV20DenyZeroHint_PreservedByReconstructedBlock() public {
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        // (Nothing to plant: {false, 0} IS the zero struct — exactly the migration's problem.)

        // Step4 order: reconstruct the denial as a block FIRST...
        vm.prank(poaManager);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        // ...then type the target (this is what arms the rulebook fallback).
        vm.prank(poaManager);
        hub.setTargetTypesBatch(ORG, _oneAddr(TASK_MANAGER), _one32(ModuleTypes.TASK_MANAGER_ID));

        // The denial survives typing; a sibling selector resolves via the rulebook as intended.
        _validateExpectDenied(_op(TASK_MANAGER, SEL_CLAIM_TASK), TASK_MANAGER, SEL_CLAIM_TASK);
        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_UNCLAIM_TASK, true, 0);
        _validate(_op(TASK_MANAGER, SEL_UNCLAIM_TASK));
    }

    /*═══════════════════════ Seed-list accuracy (reads DefaultGlobalRules itself) ═══════════════════════*/

    /// @dev Bijection check between DefaultGlobalRules.entries() and the REAL contract
    ///      selectors (`X.f.selector`, resolved by the compiler — not re-derived strings).
    ///      A typo'd signature string in the seed file fails here.
    function testDefaultGlobalRules_MatchRealContractSelectors() public {
        DefaultGlobalRules.Entry[] memory e = DefaultGlobalRules.entries();
        bytes32[] memory expected = _expectedRulebookPairs();
        assertEq(e.length, expected.length, "rulebook entry count drifted");

        for (uint256 i = 0; i < e.length; i++) {
            bytes32 pair = keccak256(abi.encodePacked(e[i].typeId, e[i].selector));
            bool found;
            for (uint256 j = 0; j < expected.length; j++) {
                if (expected[j] == pair) {
                    expected[j] = bytes32(0); // consume: catches duplicates too
                    found = true;
                    break;
                }
            }
            assertTrue(found, "rulebook entry does not match any real contract selector (typo?)");
        }
    }

    function _expectedRulebookPairs() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](52);
        uint256 n;
        bytes32 t = ModuleTypes.QUICK_JOIN_ID;
        p[n++] = _pair(t, QuickJoin.quickJoinWithUser.selector);
        p[n++] = _pair(t, QuickJoin.registerAndQuickJoin.selector);
        p[n++] = _pair(t, QuickJoin.registerAndQuickJoinWithPasskey.selector);
        p[n++] = _pair(t, QuickJoin.claimHatsWithUser.selector);
        p[n++] = _pair(t, QuickJoin.registerAndClaimHats.selector);
        p[n++] = _pair(t, QuickJoin.registerAndClaimHatsWithPasskey.selector);
        t = ModuleTypes.TASK_MANAGER_ID;
        p[n++] = _pair(t, TaskManager.createTask.selector);
        p[n++] = _pair(t, TaskManager.createTasksBatch.selector);
        p[n++] = _pair(t, TaskManager.claimTask.selector);
        p[n++] = _pair(t, TaskManager.unclaimTask.selector);
        p[n++] = _pair(t, TaskManager.submitTask.selector);
        p[n++] = _pair(t, TaskManager.completeTask.selector);
        p[n++] = _pair(t, TaskManager.applyForTask.selector);
        p[n++] = _pair(t, TaskManager.approveApplication.selector);
        p[n++] = _pair(t, TaskManager.assignTask.selector);
        p[n++] = _pair(t, TaskManager.rejectTask.selector);
        p[n++] = _pair(t, TaskManager.cancelTask.selector);
        p[n++] = _pair(t, TaskManager.createAndAssignTask.selector);
        p[n++] = _pair(t, TaskManager.createProject.selector);
        p[n++] = _pair(t, TaskManager.deleteProject.selector);
        p[n++] = _pair(t, TaskManager.setFolders.selector);
        p[n++] = _pair(t, TaskManager.updateTask.selector);
        p[n++] = _pair(t, TaskManager.updateTaskMetadata.selector);
        p[n++] = _pair(ModuleTypes.HYBRID_VOTING_ID, HybridVoting.vote.selector);
        p[n++] = _pair(ModuleTypes.HYBRID_VOTING_ID, HybridVoting.announceWinner.selector);
        p[n++] = _pair(ModuleTypes.HYBRID_VOTING_ID, HybridVoting.createProposal.selector);
        p[n++] = _pair(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, DirectDemocracyVoting.vote.selector);
        p[n++] = _pair(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, DirectDemocracyVoting.announceWinner.selector);
        p[n++] = _pair(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, DirectDemocracyVoting.createProposal.selector);
        t = ModuleTypes.PAYMENT_MANAGER_ID;
        p[n++] = _pair(t, PaymentManager.claimDistribution.selector);
        p[n++] = _pair(t, PaymentManager.claimMultiple.selector);
        p[n++] = _pair(t, PaymentManager.optOut.selector);
        p[n++] = _pair(t, PaymentManager.createDistribution.selector);
        p[n++] = _pair(t, PaymentManager.finalizeDistribution.selector);
        t = ModuleTypes.ELIGIBILITY_MODULE_ID;
        p[n++] = _pair(t, EligibilityModule.claimVouchedHat.selector);
        p[n++] = _pair(t, EligibilityModule.vouchFor.selector);
        p[n++] = _pair(t, EligibilityModule.revokeVouch.selector);
        p[n++] = _pair(t, EligibilityModule.applyForRole.selector);
        p[n++] = _pair(t, EligibilityModule.withdrawApplication.selector);
        t = ModuleTypes.PARTICIPATION_TOKEN_ID;
        p[n++] = _pair(t, ParticipationToken.requestTokens.selector);
        p[n++] = _pair(t, ParticipationToken.approveRequest.selector);
        p[n++] = _pair(t, ParticipationToken.cancelRequest.selector);
        p[n++] = _pair(ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID, UniversalAccountRegistry.setProfileMetadata.selector);
        p[n++] = _pair(ModuleTypes.ORG_REGISTRY_ID, OrgRegistry.updateOrgMetaAsAdmin.selector);
        t = ModuleTypes.EDUCATION_HUB_ID;
        p[n++] = _pair(t, EducationHub.completeModule.selector);
        p[n++] = _pair(t, EducationHub.createModule.selector);
        p[n++] = _pair(t, EducationHub.updateModule.selector);
        p[n++] = _pair(t, EducationHub.removeModule.selector);
        t = ModuleTypes.ZKEMAIL_INVITES_ID;
        p[n++] = _pair(t, ZkEmailInvites.claimRoleByDomain.selector);
        p[n++] = _pair(t, ZkEmailInvites.claimRoleByEmail.selector);
        p[n++] = _pair(t, ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector);
        p[n++] = _pair(t, ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector);
        require(n == p.length, "expected-pair count mismatch");
    }

    function _pair(bytes32 typeId, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(typeId, selector));
    }

    /*═══════════════════════ Differential Lens-vs-hub parity ═══════════════════════*/

    /// @dev The Lens's _effectiveRule is a hand-mirrored copy of PaymasterRuleLib._resolveRule.
    ///      Drive BOTH through every resolution state and require identical outcomes — a
    ///      divergence in either copy fails here regardless of which one is "right".
    function testLens_DifferentialAgainstHub() public {
        // Deposit so grace/solidarity limits never bound the repeated validations below.
        hub.depositForOrg{value: 1 ether}(ORG);

        _setGlobal(ModuleTypes.TASK_MANAGER_ID, SEL_CLAIM_TASK, true, 0);
        _mapTaskManager();
        PackedUserOperation memory op = _op(TASK_MANAGER, SEL_CLAIM_TASK);

        _assertLensMatchesHub(op, true); // global allowed
        _assertLensMatchesHub(_op(TASK_MANAGER, SEL_UNCLAIM_TASK), false); // no rulebook entry

        vm.prank(orgAdmin);
        hub.setGlobalRuleBlock(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true);
        _assertLensMatchesHub(op, false); // blocked

        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, true, 0);
        _assertLensMatchesHub(op, true); // local allow wins over block

        vm.prank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        _assertLensMatchesHub(op, true); // clear resets block -> global again

        vm.prank(orgAdmin);
        hub.setRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK, false, 0);
        _assertLensMatchesHub(op, false); // explicit deny

        vm.startPrank(orgAdmin);
        hub.clearRule(ORG, TASK_MANAGER, SEL_CLAIM_TASK);
        hub.setRulesMode(ORG, MODE_STATIC);
        vm.stopPrank();
        _assertLensMatchesHub(op, false); // static ignores global

        vm.prank(orgAdmin);
        hub.setRulesMode(ORG, MODE_MIRROR);
        _assertLensMatchesHub(op, true);
    }

    function _assertLensMatchesHub(PackedUserOperation memory op, bool expected) internal {
        (bool lensValid,) = lens.wouldValidate(ORG, op, 0.001 ether);
        vm.prank(address(ep));
        (bool hubOk,) =
            address(hub).call(abi.encodeCall(PaymasterHub.validatePaymasterUserOp, (op, bytes32(0), 0.001 ether)));
        assertEq(lensValid, hubOk, "lens/hub resolution divergence");
        assertEq(hubOk, expected, "hub outcome differs from scenario expectation");
    }

    /*═══════════════════════ Helpers ═══════════════════════*/

    function _setGlobal(bytes32 typeId, bytes4 selector, bool allowed, uint32 hint) internal {
        vm.prank(poaManager);
        hub.setGlobalRulesBatch(_one32(typeId), _one4(selector), _oneBool(allowed), _oneU32(hint));
    }

    function _mapTaskManager() internal {
        vm.prank(orgAdmin);
        hub.setTargetTypesBatch(ORG, _oneAddr(TASK_MANAGER), _one32(ModuleTypes.TASK_MANAGER_ID));
    }

    /// @dev Run validation as the EntryPoint; asserts success by absence of revert.
    function _validate(PackedUserOperation memory op) internal {
        vm.prank(address(ep));
        (, uint256 validationData) = hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
        assertEq(validationData, 0);
    }

    /// @dev Run validation as the EntryPoint expecting RuleDenied(target, selector).
    function _validateExpectDenied(PackedUserOperation memory op, address target, bytes4 selector) internal {
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(PaymasterHubErrors.RuleDenied.selector, target, selector));
        hub.validatePaymasterUserOp(op, bytes32(0), 0.001 ether);
    }

    function _op(address target, bytes4 selector) internal view returns (PackedUserOperation memory) {
        return _opFor(ORG, target, selector);
    }

    function _opFor(bytes32 orgId, address target, bytes4 selector) internal view returns (PackedUserOperation memory) {
        bytes memory innerCall = abi.encodeWithSelector(selector);
        bytes memory callData = abi.encodeWithSignature("execute(address,uint256,bytes)", target, 0, innerCall);
        return _rawOp(orgId, callData);
    }

    function _batchOp(address t1, bytes4 s1, address t2, bytes4 s2) internal view returns (PackedUserOperation memory) {
        address[] memory targets = new address[](2);
        targets[0] = t1;
        targets[1] = t2;
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(s1);
        datas[1] = abi.encodeWithSelector(s2);
        bytes memory callData =
            abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[])", targets, values, datas);
        return _rawOp(ORG, callData);
    }

    function _rawOp(bytes32 orgId, bytes memory callData) internal view returns (PackedUserOperation memory) {
        return _rawOpWithRuleId(orgId, callData, 0);
    }

    function _rawOpWithRuleId(bytes32 orgId, bytes memory callData, uint32 ruleId)
        internal
        view
        returns (PackedUserOperation memory)
    {
        // Asymmetric on purpose: verificationGas != callGas so any hint/cap check comparing the
        // WRONG half of accountGasLimits (the historical deployed-hub unpack swap) fails tests.
        uint128 verificationGas = 300_000;
        uint128 callGas = 100_000;
        uint128 pmVerificationGas = 200_000;
        uint128 pmPostOpGas = 100_000;

        bytes memory paymasterData =
            abi.encodePacked(uint8(1), orgId, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user))), ruleId, uint64(0));

        return PackedUserOperation({
            sender: user,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGas) << 128 | uint256(callGas)),
            preVerificationGas: 50_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(address(hub), pmVerificationGas, pmPostOpGas, paymasterData),
            signature: ""
        });
    }

    /// @dev Register `orgId` through the registrar path with TASK_MANAGER mapped and the given
    ///      rules mode, plus a max budget for `user` so rule checks stay the binding constraint.
    function _registerWithTypes(bytes32 orgId, uint8 mode) internal {
        PaymasterRuleLib.DeployConfig memory config = _typeConfig(mode);
        vm.prank(poaManager);
        hub.registerAndConfigureOrg(orgId, ADMIN_HAT, config);

        bytes32 subjectKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user)))));
        vm.prank(orgAdmin);
        hub.setBudget(orgId, subjectKey, type(uint128).max, 7 days);
    }

    function _typeConfig(uint8 mode) internal pure returns (PaymasterRuleLib.DeployConfig memory) {
        return PaymasterRuleLib.DeployConfig({
            operatorHatId: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            maxCallGas: 0,
            maxVerificationGas: 0,
            maxPreVerificationGas: 0,
            ruleTargets: new address[](0),
            ruleSelectors: new bytes4[](0),
            ruleAllowed: new bool[](0),
            ruleMaxCallGasHints: new uint32[](0),
            budgetSubjectKeys: new bytes32[](0),
            budgetCapsPerEpoch: new uint128[](0),
            budgetEpochLens: new uint32[](0),
            typeTargets: _oneAddr(TASK_MANAGER),
            typeIds: _one32(ModuleTypes.TASK_MANAGER_ID),
            rulesMode: mode
        });
    }

    // ── tiny array builders ──
    function _one32(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _one4(bytes4 v) internal pure returns (bytes4[] memory a) {
        a = new bytes4[](1);
        a[0] = v;
    }

    function _oneBool(bool v) internal pure returns (bool[] memory a) {
        a = new bool[](1);
        a[0] = v;
    }

    function _oneU32(uint32 v) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = v;
    }

    function _oneAddr(address v) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = v;
    }
}
