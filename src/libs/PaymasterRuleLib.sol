// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {PackedUserOperation, UserOpLib} from "../interfaces/PackedUserOperation.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {PaymasterHubErrors} from "./PaymasterHubErrors.sol";

/**
 * @title PaymasterRuleLib
 * @author POA Engineering
 * @notice PaymasterHub's sponsorship-rule engine: per-org rule validation (moved out of the hub),
 *         the protocol-managed GLOBAL RULEBOOK, and org rules-mode management. Extracted as an
 *         EXTERNAL (delegatecall) library to reclaim EIP-170 bytecode headroom, mirroring the
 *         PaymasterAdminLib / PaymasterSponsorshipLib pattern.
 *
 *         Global rulebook design (the SwitchableBeacon analog for sponsorship rules):
 *         - Local rules stay `orgId => target => selector => Rule` (unchanged, always win when set).
 *         - The rulebook is keyed by `(module typeId, selector)` where typeId is the same
 *           keccak256(moduleName) used by OrgRegistry/ModuleTypes — NOT by address — so one
 *           entry covers every org's proxy of that module type.
 *         - Each org maps its own proxy addresses to typeIds (`targetTypes`), registered at
 *           deploy by OrgDeployer and maintainable by org governance.
 *         - Rules mode per org: Mirror (0, default) resolves local-then-global; Static (1)
 *           resolves local only — the org votes new rules in, exactly like a pinned beacon.
 *         - Mirror orgs can veto a single global rule via `setGlobalRuleBlock` without leaving
 *           Mirror mode.
 *         Resolution order: local allowed → pass; org Static → deny; org block → deny;
 *         target typeId unset → deny; global rule allowed → pass; else deny. Fail-closed at
 *         every step, and fully inert for an org until its targetTypes are registered.
 *
 * @dev STORAGE: operates on the HUB's own ERC-7201 namespaced slots via delegatecall — struct
 *      definitions and slot derivations below MUST stay byte-identical to PaymasterHub's.
 *      Append-only, never reorder/remove fields. Events emitted here surface with the hub as
 *      `address` (delegatecall), so subgraph indexing is unchanged. All storage touched during
 *      `validateRules` is the hub's own, keeping ERC-7562 validation-time access rules intact.
 */
library PaymasterRuleLib {
    // ============ Constants (mirror PaymasterHub) ============
    uint32 private constant RULE_ID_GENERIC = 0x00000000;
    uint32 private constant RULE_ID_COARSE = 0x000000FF;
    uint32 private constant MIN_EPOCH_LENGTH = 1 hours;
    uint32 private constant MAX_EPOCH_LENGTH = 365 days;

    /// @notice Org resolves rules locally, then falls through to the global rulebook (default).
    uint8 internal constant RULES_MODE_MIRROR = 0;
    /// @notice Org resolves rules locally only; global rulebook is ignored.
    uint8 internal constant RULES_MODE_STATIC = 1;

    // ============ Storage structs (byte-identical mirrors of PaymasterHub's) ============
    struct MainStorage {
        address entryPoint;
        address hats;
        address poaManager;
        address orgRegistrar;
        address protocolAdmin;
    }

    struct OrgConfig {
        uint256 adminHatId;
        uint256 operatorHatId;
        bool paused;
        uint40 registeredAt;
        bool bannedFromSolidarity;
    }

    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    struct FeeCaps {
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
    }

    struct Budget {
        uint128 capPerEpoch;
        uint128 usedInEpoch;
        uint32 epochLen;
        uint32 epochStart;
    }

    // ============ Global rulebook structs (owned by this lib, new namespaces) ============

    /// @notice Enumeration entry for one global rulebook rule.
    struct GlobalRuleKey {
        bytes32 typeId;
        bytes4 selector;
    }

    /// @dev Enumerable set of global rulebook entries. `indexPlusOne` is keyed by
    ///      keccak256(abi.encodePacked(typeId, selector)); 0 = absent.
    struct GlobalRulesEnum {
        GlobalRuleKey[] keys;
        mapping(bytes32 => uint256) indexPlusOne;
    }

    /**
     * @notice Legacy (pre-rulebook) deploy configuration — byte-identical to the DeployConfig
     *         tuple the LIVE OrgDeployer proxies were compiled against.
     * @dev Kept so `registerAndConfigureOrg(bytes32,uint256,LegacyDeployConfig)` retains the OLD
     *      function selector: the deployed OrgDeployer keeps working (seeding address-keyed local
     *      rules exactly as before) across the hub upgrade, with NO lockstep deployer upgrade
     *      required. Remove only after every chain's OrgDeployer is upgraded to the new ABI.
     */
    struct LegacyDeployConfig {
        uint256 operatorHatId;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        address[] ruleTargets;
        bytes4[] ruleSelectors;
        bool[] ruleAllowed;
        uint32[] ruleMaxCallGasHints;
        bytes32[] budgetSubjectKeys;
        uint128[] budgetCapsPerEpoch;
        uint32[] budgetEpochLens;
    }

    /**
     * @notice Configuration passed by OrgDeployer during org creation
     * @dev Moved here from PaymasterHub (same ABI tuple; new fields appended). Allows initial
     *      paymaster setup in the same transaction as org deployment.
     */
    struct DeployConfig {
        uint256 operatorHatId;
        // Fee caps (all zeros = skip)
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint32 maxCallGas;
        uint32 maxVerificationGas;
        uint32 maxPreVerificationGas;
        // Explicit rules batch (empty arrays = skip)
        address[] ruleTargets;
        bytes4[] ruleSelectors;
        bool[] ruleAllowed;
        uint32[] ruleMaxCallGasHints;
        // Budgets batch (empty arrays = skip)
        bytes32[] budgetSubjectKeys;
        uint128[] budgetCapsPerEpoch;
        uint32[] budgetEpochLens;
        // Target module-type registration for global rulebook resolution (empty arrays = skip)
        address[] typeTargets;
        bytes32[] typeIds;
        // Rules mode: 0 = Mirror (follow global rulebook), 1 = Static (local rules only;
        // current global rulebook entries are snapshotted into local rules at registration)
        uint8 rulesMode;
    }

    // ============ ERC-7201 slots ============
    // Mirrors of PaymasterHub's existing namespaces:
    bytes32 private constant MAIN_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.main")) - 1));
    bytes32 private constant ORGS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgs")) - 1));
    bytes32 private constant RULES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.rules")) - 1));
    bytes32 private constant FEECAPS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.feeCaps")) - 1));
    bytes32 private constant BUDGETS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.budgets")) - 1));
    // New namespaces owned by this lib (also mirrored by PaymasterHub's view getters):
    bytes32 private constant GLOBAL_RULES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalrules")) - 1));
    bytes32 private constant GLOBAL_RULE_KEYS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalrulekeys")) - 1));
    bytes32 private constant TARGET_TYPES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.targettypes")) - 1));
    bytes32 private constant RULES_MODES_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.rulesmodes")) - 1));
    bytes32 private constant GLOBAL_RULE_BLOCKS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.globalruleblocks")) - 1));

    // ═════════════════════════════════════════════════════════════════════════
    // Validation (ERC-4337 validation hot path — hub's own storage only)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Validate the userOp's (target, selector) against org rules with global fallback.
    /// @dev Moved from PaymasterHub._validateRules and extended with global rulebook resolution.
    ///      Reverts RuleDenied / GasTooHigh / InvalidRuleId / InvalidPaymasterData on failure.
    function validateRules(PackedUserOperation calldata userOp, uint32 ruleId, bytes32 orgId) external view {
        bytes calldata callData = userOp.callData;
        if (callData.length < 4) revert PaymasterHubErrors.InvalidPaymasterData();

        // For RULE_ID_GENERIC, executeBatch needs per-inner-call validation
        if (ruleId == RULE_ID_GENERIC) {
            bytes4 outerSelector = bytes4(callData[0:4]);
            // executeBatch(address[],uint256[],bytes[]) or executeBatch(address[],bytes[])
            if (outerSelector == bytes4(0x47e1da2a) || outerSelector == bytes4(0x18dfb3c7)) {
                _validateBatchRules(callData, outerSelector, orgId);
                return;
            }
        }

        // Single-call path
        (address target, bytes4 selector) = _extractTargetSelector(userOp, ruleId);

        (bool allowed, uint32 maxCallGasHint) = _resolveRule(orgId, target, selector);
        if (!allowed) revert PaymasterHubErrors.RuleDenied(target, selector);

        // Check gas hint if set
        if (maxCallGasHint > 0) {
            (, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);
            if (callGasLimit > maxCallGasHint) revert PaymasterHubErrors.GasTooHigh();
        }
    }

    /// @dev Resolve the effective rule for (org, target, selector): local rule wins when allowed;
    ///      otherwise the global rulebook applies only when the org is in Mirror mode, has not
    ///      blocked the pair, and has a typeId registered for the target. Fail-closed.
    function _resolveRule(bytes32 orgId, address target, bytes4 selector)
        private
        view
        returns (bool allowed, uint32 maxCallGasHint)
    {
        Rule storage local = _rules()[orgId][target][selector];
        if (local.allowed) return (true, local.maxCallGasHint);

        if (_rulesModes()[orgId] != RULES_MODE_MIRROR) return (false, 0);
        if (_globalRuleBlocks()[orgId][target][selector]) return (false, 0);

        bytes32 typeId = _targetTypes()[orgId][target];
        if (typeId == bytes32(0)) return (false, 0);

        Rule storage global = _globalRules()[typeId][selector];
        if (!global.allowed) return (false, 0);
        return (true, global.maxCallGasHint);
    }

    /// @dev Validates that every inner call in an executeBatch is allowed (local or global).
    ///      Gas hints are not checked per-call (total callGasLimit still applies via FeeCaps).
    ///      Inner calls with < 4 bytes of data use selector bytes4(0) (raw ETH transfer / fallback).
    function _validateBatchRules(bytes calldata callData, bytes4 outerSelector, bytes32 orgId) private view {
        // Decode targets and datas from either batch format
        address[] memory targets;
        bytes[] memory datas;
        if (outerSelector == bytes4(0x47e1da2a)) {
            // executeBatch(address[],uint256[],bytes[]) — PasskeyAccount pattern
            (targets,, datas) = abi.decode(callData[4:], (address[], uint256[], bytes[]));
        } else {
            // executeBatch(address[],bytes[]) — SimpleAccount pattern (0x18dfb3c7)
            (targets, datas) = abi.decode(callData[4:], (address[], bytes[]));
        }

        if (targets.length != datas.length) revert PaymasterHubErrors.ArrayLengthMismatch();
        for (uint256 i = 0; i < targets.length;) {
            bytes4 innerSelector;
            if (datas[i].length >= 4) {
                bytes memory d = datas[i];
                assembly {
                    innerSelector := mload(add(d, 0x20))
                }
            }
            (bool allowed,) = _resolveRule(orgId, targets[i], innerSelector);
            if (!allowed) revert PaymasterHubErrors.RuleDenied(targets[i], innerSelector);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Moved verbatim from PaymasterHub._extractTargetSelector.
    function _extractTargetSelector(PackedUserOperation calldata userOp, uint32 ruleId)
        private
        pure
        returns (address target, bytes4 selector)
    {
        bytes calldata callData = userOp.callData;

        if (callData.length < 4) revert PaymasterHubErrors.InvalidPaymasterData();

        if (ruleId == RULE_ID_GENERIC) {
            // ERC-4337 account execute patterns (SimpleAccount, PasskeyAccount, etc.)
            selector = bytes4(callData[0:4]);

            // Check for execute(address,uint256,bytes) - 0xb61d27f6
            // Used by SimpleAccount, PasskeyAccount, and most ERC-4337 wallets
            if (selector == 0xb61d27f6 && callData.length >= 0x64) {
                assembly {
                    // Extract target address at offset 0x04
                    target := calldataload(add(callData.offset, 0x04))

                    // Read the bytes data offset pointer at position 0x44
                    // This offset is relative to the start of params (0x04)
                    let dataOffset := calldataload(add(callData.offset, 0x44))

                    // Only extract inner selector if dataOffset is the standard 0x60
                    // (3rd dynamic param in ABI encoding). A non-standard offset could
                    // allow an attacker to point at arbitrary calldata.
                    if eq(dataOffset, 0x60) {
                        let dataStart := add(add(0x04, dataOffset), 0x20)
                        if lt(dataStart, callData.length) {
                            selector := calldataload(add(callData.offset, dataStart))
                        }
                    }
                }
                selector = bytes4(selector);
            }
            // For RULE_ID_GENERIC, executeBatch selectors (0x47e1da2a, 0x18dfb3c7) are
            // intercepted by validateRules → _validateBatchRules before reaching here.
            // Any other outer selector (including non-execute custom functions) falls through.
            else {
                target = userOp.sender;
            }
        } else if (ruleId == RULE_ID_COARSE) {
            // Coarse mode: only check account's selector
            target = userOp.sender;
            selector = bytes4(callData[0:4]);
        } else {
            revert PaymasterHubErrors.InvalidRuleId();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Global rulebook administration (poaManager / protocolAdmin)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Set or remove global rulebook entries keyed by (module typeId, selector).
    /// @dev `allowed[i] = true` upserts the entry (and adds it to the enumeration);
    ///      `allowed[i] = false` deletes it (and removes it from the enumeration).
    ///      One entry here covers the matching module of EVERY Mirror-mode org — this is the
    ///      lever that replaces per-org adminBatchAddRules fan-outs and OrgDeployer redeploys.
    function setGlobalRulesBatch(
        bytes32[] calldata typeIds,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) external {
        _requirePoaOrProtocolAdmin();
        uint256 len = typeIds.length;
        if (len != selectors.length || len != allowed.length || len != maxCallGasHints.length) {
            revert PaymasterHubErrors.ArrayLengthMismatch();
        }

        // Per-entry work lives in its own frame — the four calldata arrays plus the
        // enumeration locals overflow the stack under the production via-IR profile otherwise.
        for (uint256 i; i < len;) {
            _setGlobalRule(typeIds[i], selectors[i], allowed[i], maxCallGasHints[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _setGlobalRule(bytes32 typeId, bytes4 selector, bool allowed, uint32 maxCallGasHint) private {
        if (typeId == bytes32(0)) revert PaymasterHubErrors.InvalidTypeId();

        GlobalRulesEnum storage en = _globalRuleKeys();
        bytes32 enumKey = keccak256(abi.encodePacked(typeId, selector));

        if (allowed) {
            _globalRules()[typeId][selector] = Rule({maxCallGasHint: maxCallGasHint, allowed: true});
            if (en.indexPlusOne[enumKey] == 0) {
                en.keys.push(GlobalRuleKey({typeId: typeId, selector: selector}));
                en.indexPlusOne[enumKey] = en.keys.length;
            }
            emit PaymasterHubErrors.GlobalRuleSet(typeId, selector, true, maxCallGasHint);
        } else {
            delete _globalRules()[typeId][selector];
            uint256 idxPlusOne = en.indexPlusOne[enumKey];
            if (idxPlusOne != 0) {
                uint256 lastIdx = en.keys.length - 1;
                if (idxPlusOne - 1 != lastIdx) {
                    GlobalRuleKey memory last = en.keys[lastIdx];
                    en.keys[idxPlusOne - 1] = last;
                    en.indexPlusOne[keccak256(abi.encodePacked(last.typeId, last.selector))] = idxPlusOne;
                }
                en.keys.pop();
                delete en.indexPlusOne[enumKey];
            }
            emit PaymasterHubErrors.GlobalRuleSet(typeId, selector, false, 0);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Org-level configuration (org admin / operator / poaManager)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Map an org's target addresses to module typeIds for global rule resolution.
    /// @dev typeId = bytes32(0) clears the mapping (target stops resolving global rules).
    function setTargetTypesBatch(bytes32 orgId, address[] calldata targets, bytes32[] calldata typeIds) external {
        _requireOrgOperator(orgId);
        if (targets.length != typeIds.length) revert PaymasterHubErrors.ArrayLengthMismatch();
        _writeTargetTypes(orgId, targets, typeIds);
    }

    /// @notice Switch an org between Mirror (0, follow global rulebook) and Static (1, local only).
    /// @dev A Static switch does NOT snapshot global rules into local rules — pair it with
    ///      `snapshotGlobalRules` in the same governance batch to keep current sponsorships.
    function setRulesMode(bytes32 orgId, uint8 mode) external {
        _requireOrgOperator(orgId);
        if (mode > RULES_MODE_STATIC) revert PaymasterHubErrors.InvalidRulesMode();
        _rulesModes()[orgId] = mode;
        emit PaymasterHubErrors.RulesModeSet(orgId, mode);
    }

    /// @notice Block (or unblock) a single global rule for this org without leaving Mirror mode.
    /// @dev Only affects global fallback resolution; an explicit local allowed rule still wins.
    function setGlobalRuleBlock(bytes32 orgId, address target, bytes4 selector, bool blocked) external {
        _requireOrgOperator(orgId);
        if (target == address(0)) revert PaymasterHubErrors.ZeroAddress();
        _globalRuleBlocks()[orgId][target][selector] = blocked;
        emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, target, selector, blocked);
    }

    /// @notice Copy specific current global rulebook entries into the org's local rules.
    /// @dev For Static-mode orgs voting to adopt individual new functions: resolves each
    ///      target's typeId, requires the global entry to exist, and writes it as a local rule
    ///      (emitting RuleSet like any local rule change).
    function adoptGlobalRules(bytes32 orgId, address[] calldata targets, bytes4[] calldata selectors) external {
        _requireOrgOperator(orgId);
        uint256 len = targets.length;
        if (len != selectors.length) revert PaymasterHubErrors.ArrayLengthMismatch();

        for (uint256 i; i < len;) {
            bytes32 typeId = _targetTypes()[orgId][targets[i]];
            if (typeId == bytes32(0)) revert PaymasterHubErrors.InvalidTypeId();

            Rule storage global = _globalRules()[typeId][selectors[i]];
            if (!global.allowed) revert PaymasterHubErrors.GlobalRuleUnknown();

            _rules()[orgId][targets[i]][selectors[i]] = Rule({maxCallGasHint: global.maxCallGasHint, allowed: true});
            emit PaymasterHubErrors.RuleSet(orgId, targets[i], selectors[i], true, global.maxCallGasHint);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Copy ALL applicable global rulebook entries into the org's local rules.
    /// @dev Iterates the enumerable rulebook and writes a local rule for every entry whose
    ///      typeId matches one of `targets` (per the org's registered targetTypes). Use when
    ///      switching to Static mode to keep current sponsorships, or to catch a Static org
    ///      up to the current rulebook in one governance action.
    function snapshotGlobalRules(bytes32 orgId, address[] calldata targets) external {
        _requireOrgOperator(orgId);
        _snapshotGlobalRules(orgId, targets);
    }

    /// @notice Write a batch of local org rules (auth performed by the hub's onlyOrgOperator).
    /// @dev Body of the former PaymasterHub._setRulesBatch, shared with applyDeployConfig.
    ///      An entry with allowed=false is an EXPLICIT DENY: it also sets the global-rule block
    ///      so a Mirror org's revocation actually revokes (pre-rulebook, allowed=false was a
    ///      guaranteed deny; without the block it would silently fall through to the rulebook).
    ///      allowed=true clears any standing block for the pair (a fresh allow supersedes it).
    function writeLocalRulesBatch(
        bytes32 orgId,
        address[] calldata targets,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) external {
        _writeLocalRulesBatch(orgId, targets, selectors, allowed, maxCallGasHints);
    }

    /// @notice Write a single local org rule (auth performed by the hub's onlyOrgOperator).
    /// @dev Same explicit-deny semantics as writeLocalRulesBatch.
    function writeLocalRule(bytes32 orgId, address target, bytes4 selector, bool allowed, uint32 maxCallGasHint)
        external
    {
        if (target == address(0)) revert PaymasterHubErrors.ZeroAddress();

        _rules()[orgId][target][selector] = Rule({maxCallGasHint: maxCallGasHint, allowed: allowed});
        emit PaymasterHubErrors.RuleSet(orgId, target, selector, allowed, maxCallGasHint);

        bool blocked = _globalRuleBlocks()[orgId][target][selector];
        if (!allowed && !blocked) {
            _globalRuleBlocks()[orgId][target][selector] = true;
            emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, target, selector, true);
        } else if (allowed && blocked) {
            _globalRuleBlocks()[orgId][target][selector] = false;
            emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, target, selector, false);
        }
    }

    /// @notice Delete a local rule AND any standing block for the pair (auth by the hub).
    /// @dev "Reset to protocol default": for a Mirror org the pair falls back to the global
    ///      rulebook afterwards. Use setRule(...,false,...) to deny instead.
    function clearLocalRule(bytes32 orgId, address target, bytes4 selector) external {
        delete _rules()[orgId][target][selector];
        emit PaymasterHubErrors.RuleSet(orgId, target, selector, false, 0);
        if (_globalRuleBlocks()[orgId][target][selector]) {
            _globalRuleBlocks()[orgId][target][selector] = false;
            emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, target, selector, false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Deploy-time configuration (called from registrar-gated hub function)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Apply an OrgDeployer DeployConfig to a freshly registered org.
    /// @dev Body of the former PaymasterHub.registerAndConfigureOrg config application, extended
    ///      with target-type registration, rules mode, and the Static-mode snapshot. Caller
    ///      (PaymasterHub) has already enforced the registrar gate and registered the org.
    ///      Deploy-time state emits the same events as the setters (subgraph indexes from logs).
    function applyDeployConfig(bytes32 orgId, DeployConfig calldata config) external {
        _applyFeeCaps(
            orgId,
            config.maxFeePerGas,
            config.maxPriorityFeePerGas,
            config.maxCallGas,
            config.maxVerificationGas,
            config.maxPreVerificationGas
        );

        // Target module types for global rulebook resolution
        if (config.typeTargets.length > 0) {
            if (config.typeTargets.length != config.typeIds.length) {
                revert PaymasterHubErrors.ArrayLengthMismatch();
            }
            _writeTargetTypes(orgId, config.typeTargets, config.typeIds);
        }

        // Rules mode (0 = Mirror default; emit regardless so indexers see the deploy-time value)
        if (config.rulesMode > RULES_MODE_STATIC) revert PaymasterHubErrors.InvalidRulesMode();
        if (config.rulesMode != RULES_MODE_MIRROR) {
            _rulesModes()[orgId] = config.rulesMode;
        }
        emit PaymasterHubErrors.RulesModeSet(orgId, config.rulesMode);

        // Static orgs start from a local copy of the current global rulebook, then govern it.
        if (config.rulesMode == RULES_MODE_STATIC && config.typeTargets.length > 0) {
            _snapshotGlobalRules(orgId, config.typeTargets);
        }

        // Explicit rules if arrays provided (applied AFTER the snapshot so they can override it)
        if (config.ruleTargets.length > 0) {
            _writeLocalRulesBatch(
                orgId, config.ruleTargets, config.ruleSelectors, config.ruleAllowed, config.ruleMaxCallGasHints
            );
        }

        _applyBudgets(orgId, config.budgetSubjectKeys, config.budgetCapsPerEpoch, config.budgetEpochLens);
    }

    /// @notice Apply a pre-rulebook (13-field) DeployConfig — the ABI the LIVE OrgDeployer calls.
    /// @dev Same application semantics as before the upgrade: fee caps + address-keyed local
    ///      rules + budgets. No target types are registered and the org stays in default Mirror
    ///      mode (inert until types are mapped), so orgs deployed through an un-upgraded
    ///      OrgDeployer behave exactly as they did pre-v20.
    function applyLegacyDeployConfig(bytes32 orgId, LegacyDeployConfig calldata config) external {
        _applyFeeCaps(
            orgId,
            config.maxFeePerGas,
            config.maxPriorityFeePerGas,
            config.maxCallGas,
            config.maxVerificationGas,
            config.maxPreVerificationGas
        );

        if (config.ruleTargets.length > 0) {
            _writeLocalRulesBatch(
                orgId, config.ruleTargets, config.ruleSelectors, config.ruleAllowed, config.ruleMaxCallGasHints
            );
        }

        _applyBudgets(orgId, config.budgetSubjectKeys, config.budgetCapsPerEpoch, config.budgetEpochLens);
    }

    function _applyFeeCaps(
        bytes32 orgId,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint32 maxCallGas,
        uint32 maxVerificationGas,
        uint32 maxPreVerificationGas
    ) private {
        if (
            maxFeePerGas == 0 && maxPriorityFeePerGas == 0 && maxCallGas == 0 && maxVerificationGas == 0
                && maxPreVerificationGas == 0
        ) return;

        FeeCaps storage feeCaps = _feeCaps()[orgId];
        feeCaps.maxFeePerGas = maxFeePerGas;
        feeCaps.maxPriorityFeePerGas = maxPriorityFeePerGas;
        feeCaps.maxCallGas = maxCallGas;
        feeCaps.maxVerificationGas = maxVerificationGas;
        feeCaps.maxPreVerificationGas = maxPreVerificationGas;

        emit PaymasterHubErrors.FeeCapsSet(
            orgId, maxFeePerGas, maxPriorityFeePerGas, maxCallGas, maxVerificationGas, maxPreVerificationGas
        );
    }

    function _applyBudgets(
        bytes32 orgId,
        bytes32[] calldata budgetSubjectKeys,
        uint128[] calldata budgetCapsPerEpoch,
        uint32[] calldata budgetEpochLens
    ) private {
        uint256 budgetLen = budgetSubjectKeys.length;
        if (budgetLen == 0) return;
        if (budgetLen != budgetCapsPerEpoch.length || budgetLen != budgetEpochLens.length) {
            revert PaymasterHubErrors.ArrayLengthMismatch();
        }

        mapping(bytes32 => Budget) storage budgets = _budgets()[orgId];

        for (uint256 j; j < budgetLen;) {
            uint32 epochLen = budgetEpochLens[j];
            if (epochLen < MIN_EPOCH_LENGTH || epochLen > MAX_EPOCH_LENGTH) {
                revert PaymasterHubErrors.InvalidEpochLength();
            }

            Budget storage budget = budgets[budgetSubjectKeys[j]];
            budget.capPerEpoch = budgetCapsPerEpoch[j];
            budget.epochLen = epochLen;
            budget.epochStart = uint32(block.timestamp);

            emit PaymasterHubErrors.BudgetSet(
                orgId, budgetSubjectKeys[j], budgetCapsPerEpoch[j], epochLen, uint32(block.timestamp)
            );

            unchecked {
                ++j;
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _writeTargetTypes(bytes32 orgId, address[] calldata targets, bytes32[] calldata typeIds) private {
        uint256 len = targets.length;
        for (uint256 i; i < len;) {
            if (targets[i] == address(0)) revert PaymasterHubErrors.ZeroAddress();
            _targetTypes()[orgId][targets[i]] = typeIds[i];
            emit PaymasterHubErrors.TargetTypeSet(orgId, targets[i], typeIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _writeLocalRulesBatch(
        bytes32 orgId,
        address[] calldata targets,
        bytes4[] calldata selectors,
        bool[] calldata allowed,
        uint32[] calldata maxCallGasHints
    ) private {
        uint256 length = targets.length;
        if (length != selectors.length || length != allowed.length || length != maxCallGasHints.length) {
            revert PaymasterHubErrors.ArrayLengthMismatch();
        }

        mapping(address => mapping(bytes4 => Rule)) storage rules = _rules()[orgId];

        for (uint256 i; i < length;) {
            if (targets[i] == address(0)) revert PaymasterHubErrors.ZeroAddress();

            rules[targets[i]][selectors[i]] = Rule({maxCallGasHint: maxCallGasHints[i], allowed: allowed[i]});

            emit PaymasterHubErrors.RuleSet(orgId, targets[i], selectors[i], allowed[i], maxCallGasHints[i]);

            // Explicit deny must actually deny for Mirror orgs: allowed=false also blocks the
            // global fallback; allowed=true clears a standing block (fresh allow supersedes it).
            bool blocked = _globalRuleBlocks()[orgId][targets[i]][selectors[i]];
            if (!allowed[i] && !blocked) {
                _globalRuleBlocks()[orgId][targets[i]][selectors[i]] = true;
                emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, targets[i], selectors[i], true);
            } else if (allowed[i] && blocked) {
                _globalRuleBlocks()[orgId][targets[i]][selectors[i]] = false;
                emit PaymasterHubErrors.GlobalRuleBlockSet(orgId, targets[i], selectors[i], false);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _snapshotGlobalRules(bytes32 orgId, address[] calldata targets) private {
        uint256 tLen = targets.length;

        // Cache each target's typeId once (avoids re-reading storage per rulebook entry)
        bytes32[] memory targetTypeIds = new bytes32[](tLen);
        for (uint256 t; t < tLen;) {
            targetTypeIds[t] = _targetTypes()[orgId][targets[t]];
            unchecked {
                ++t;
            }
        }

        GlobalRulesEnum storage en = _globalRuleKeys();
        uint256 kLen = en.keys.length;
        for (uint256 k; k < kLen;) {
            GlobalRuleKey storage key = en.keys[k];
            for (uint256 t; t < tLen;) {
                if (targetTypeIds[t] == key.typeId) {
                    Rule storage global = _globalRules()[key.typeId][key.selector];
                    _rules()[orgId][targets[t]][key.selector] =
                        Rule({maxCallGasHint: global.maxCallGasHint, allowed: true});
                    emit PaymasterHubErrors.RuleSet(orgId, targets[t], key.selector, true, global.maxCallGasHint);
                }
                unchecked {
                    ++t;
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @dev Mirror of PaymasterHub.onlyOrgOperator: org must be registered; poaManager bypasses;
    ///      otherwise the caller must wear the org's admin or operator hat.
    function _requireOrgOperator(bytes32 orgId) private view {
        OrgConfig storage org = _orgs()[orgId];
        if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();

        MainStorage storage m = _main();
        if (msg.sender == m.poaManager) return;

        bool isAdmin = IHats(m.hats).isWearerOfHat(msg.sender, org.adminHatId);
        bool isOperator = org.operatorHatId != 0 && IHats(m.hats).isWearerOfHat(msg.sender, org.operatorHatId);
        if (!isAdmin && !isOperator) revert PaymasterHubErrors.NotOperator();
    }

    /// @dev Same gate as adminBatchAddRules / setSolidarityFee: poaManager or protocolAdmin.
    ///      protocolAdmin == address(0) can never authorize (msg.sender is nonzero).
    function _requirePoaOrProtocolAdmin() private view {
        MainStorage storage m = _main();
        if (msg.sender != m.poaManager && msg.sender != m.protocolAdmin) revert PaymasterHubErrors.NotOperator();
    }

    // ── Storage accessors ──
    function _main() private pure returns (MainStorage storage $) {
        bytes32 slot = MAIN_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _orgs() private pure returns (mapping(bytes32 => OrgConfig) storage $) {
        bytes32 slot = ORGS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _rules() private pure returns (mapping(bytes32 => mapping(address => mapping(bytes4 => Rule))) storage $) {
        bytes32 slot = RULES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _feeCaps() private pure returns (mapping(bytes32 => FeeCaps) storage $) {
        bytes32 slot = FEECAPS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _budgets() private pure returns (mapping(bytes32 => mapping(bytes32 => Budget)) storage $) {
        bytes32 slot = BUDGETS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _globalRules() private pure returns (mapping(bytes32 => mapping(bytes4 => Rule)) storage $) {
        bytes32 slot = GLOBAL_RULES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _globalRuleKeys() private pure returns (GlobalRulesEnum storage $) {
        bytes32 slot = GLOBAL_RULE_KEYS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _targetTypes() private pure returns (mapping(bytes32 => mapping(address => bytes32)) storage $) {
        bytes32 slot = TARGET_TYPES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _rulesModes() private pure returns (mapping(bytes32 => uint8) storage $) {
        bytes32 slot = RULES_MODES_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _globalRuleBlocks()
        private
        pure
        returns (mapping(bytes32 => mapping(address => mapping(bytes4 => bool))) storage $)
    {
        bytes32 slot = GLOBAL_RULE_BLOCKS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }
}
