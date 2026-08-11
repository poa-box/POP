// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation, UserOpLib} from "./interfaces/PackedUserOperation.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PaymasterHubErrors} from "./libs/PaymasterHubErrors.sol";
import {PaymasterGraceLib} from "./libs/PaymasterGraceLib.sol";
import {PaymasterCalldataLib} from "./libs/PaymasterCalldataLib.sol";

// Storage structs matching PaymasterHub
struct OrgConfig {
    uint256 adminHatId;
    uint256 operatorHatId;
    bool paused;
    uint40 registeredAt;
    bool bannedFromSolidarity;
}

struct OrgFinancials {
    uint128 deposited;
    uint128 spent;
    uint128 solidarityUsedThisPeriod;
    uint32 periodStart;
}

struct SolidarityFund {
    uint128 balance;
    uint32 numActiveOrgs;
    uint16 feePercentageBps;
    bool distributionPaused;
}

struct GracePeriodConfig {
    uint32 initialGraceDays;
    uint128 maxSpendDuringGrace;
    uint128 minDepositRequired;
}

struct FeeCaps {
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint32 maxCallGas;
    uint32 maxVerificationGas;
    uint32 maxPreVerificationGas;
}

struct Rule {
    uint32 maxCallGasHint;
    bool allowed;
}

struct Budget {
    uint128 capPerEpoch;
    uint128 usedInEpoch;
    uint32 epochLen;
    uint32 epochStart;
}

struct OrgDeployConfig {
    uint128 maxGasPerDeploy;
    uint128 dailyDeployLimit;
    uint128 attemptsToday;
    uint32 currentDay;
    uint8 maxDeploysPerAccount;
    bool enabled;
    address orgDeployer;
}

struct OnboardingConfig {
    uint128 maxGasPerCreation;
    uint128 dailyCreationLimit;
    uint128 attemptsToday;
    uint32 currentDay;
    bool enabled;
    address accountRegistry;
    uint8 maxOnboardingsPerAccount;
}

// Interface for PaymasterHub Storage Getters — matches org-scoped signatures
interface IPaymasterHubStorage {
    function getOrgConfig(bytes32 orgId) external view returns (OrgConfig memory);
    function getBudget(bytes32 orgId, bytes32 key) external view returns (Budget memory);
    function getRule(bytes32 orgId, address target, bytes4 selector) external view returns (Rule memory);
    function getFeeCaps(bytes32 orgId) external view returns (FeeCaps memory);
    function getOrgFinancials(bytes32 orgId) external view returns (OrgFinancials memory);
    function getSolidarityFund() external view returns (SolidarityFund memory);
    function getGracePeriodConfig() external view returns (GracePeriodConfig memory);
    function getOrgDeployConfig() external view returns (OrgDeployConfig memory);
    function getOnboardingConfig() external view returns (OnboardingConfig memory);
    function getOrgDeployCount(address account) external view returns (uint8);
    function ENTRY_POINT() external view returns (address);
    function HATS() external view returns (address);
    // Global rulebook getters (PaymasterRuleLib feature)
    function getGlobalRule(bytes32 typeId, bytes4 selector) external view returns (Rule memory);
    function getGlobalRuleCount() external view returns (uint256);
    function getGlobalRuleAt(uint256 index) external view returns (bytes32 typeId, bytes4 selector, Rule memory rule);
    function getTargetType(bytes32 orgId, address target) external view returns (bytes32);
    function getRulesMode(bytes32 orgId) external view returns (uint8);
    function isGlobalRuleBlocked(bytes32 orgId, address target, bytes4 selector) external view returns (bool);
}

/**
 * @title PaymasterHubLens
 * @author POA Engineering
 * @notice View-only lens contract for PaymasterHub to reduce main contract bytecode size
 * @dev Calls storage getters on PaymasterHub to read state and implement view logic.
 *      All public functions take bytes32 orgId to match PaymasterHub's org-scoped storage.
 */
contract PaymasterHubLens {
    // ============ Constants ============
    uint8 private constant PAYMASTER_DATA_VERSION = 1;
    uint8 private constant SUBJECT_TYPE_ACCOUNT = 0x00;
    uint8 private constant SUBJECT_TYPE_HAT = 0x01;
    uint8 private constant SUBJECT_TYPE_POA_ONBOARDING = 0x03;
    uint8 private constant SUBJECT_TYPE_ORG_DEPLOY = 0x04;
    uint8 private constant SUBJECT_TYPE_CLAIM = 0x05; // sponsor calls TO an org claim contract (no eligibility pre-check)

    uint32 private constant RULE_ID_GENERIC = 0x00000000;
    uint32 private constant RULE_ID_COARSE = 0x000000FF;

    // ============ Immutable ============
    IPaymasterHubStorage public immutable hub;

    // ============ Constructor ============
    constructor(address _hub) {
        if (_hub == address(0)) revert PaymasterHubErrors.ZeroAddress();
        hub = IPaymasterHubStorage(_hub);
    }

    // ============ View Functions ============

    function budgetOf(bytes32 orgId, bytes32 subjectKey) external view returns (Budget memory) {
        Budget memory budget = hub.getBudget(orgId, subjectKey);

        // Calculate current epoch if needed (L-37: widen to uint256 to avoid uint32 overflow)
        uint256 currentTime = block.timestamp;
        if (budget.epochLen > 0 && currentTime >= uint256(budget.epochStart) + uint256(budget.epochLen)) {
            uint32 epochsPassed = uint32((currentTime - budget.epochStart) / budget.epochLen);
            return Budget({
                capPerEpoch: budget.capPerEpoch,
                usedInEpoch: 0, // Reset after epoch roll
                epochLen: budget.epochLen,
                epochStart: budget.epochStart + (epochsPassed * budget.epochLen)
            });
        }

        return budget;
    }

    function remaining(bytes32 orgId, bytes32 subjectKey) external view returns (uint256) {
        Budget memory budget = hub.getBudget(orgId, subjectKey);

        // Check if epoch needs rolling (L-37: widen to uint256 to avoid uint32 overflow)
        if (budget.epochLen > 0 && block.timestamp >= uint256(budget.epochStart) + uint256(budget.epochLen)) {
            return budget.capPerEpoch; // Full budget available after epoch roll
        }

        return budget.capPerEpoch > budget.usedInEpoch ? budget.capPerEpoch - budget.usedInEpoch : 0;
    }

    /// @notice The org's LOCAL rule only (no global fallback) — see effectiveRuleOf for resolution
    function ruleOf(bytes32 orgId, address target, bytes4 selector) external view returns (Rule memory) {
        return hub.getRule(orgId, target, selector);
    }

    /// @notice Whether (target, selector) is sponsored for the org — local rule OR global fallback
    function isAllowed(bytes32 orgId, address target, bytes4 selector) external view returns (bool) {
        (bool allowed,,) = _effectiveRule(orgId, target, selector);
        return allowed;
    }

    /// @notice Resolve the rule the hub would enforce for (org, target, selector)
    /// @return allowed Whether the pair is sponsored
    /// @return maxCallGasHint The gas hint that applies (from whichever rule resolved)
    /// @return source 0 = denied, 1 = local rule, 2 = global rulebook
    function effectiveRuleOf(bytes32 orgId, address target, bytes4 selector)
        external
        view
        returns (bool allowed, uint32 maxCallGasHint, uint8 source)
    {
        return _effectiveRule(orgId, target, selector);
    }

    /// @dev Mirrors PaymasterRuleLib._resolveRule exactly: local allowed wins; global rulebook
    ///      applies only for Mirror-mode orgs, not blocked, with a registered target typeId.
    function _effectiveRule(bytes32 orgId, address target, bytes4 selector)
        private
        view
        returns (bool allowed, uint32 maxCallGasHint, uint8 source)
    {
        Rule memory local = hub.getRule(orgId, target, selector);
        if (local.allowed) return (true, local.maxCallGasHint, 1);

        // Explicit pre-v20 deny ({allowed:false, hint != 0}) — mirrors PaymasterRuleLib.
        if (local.maxCallGasHint != 0) return (false, 0, 0);

        if (hub.getRulesMode(orgId) != 0) return (false, 0, 0); // Static: local only
        if (hub.isGlobalRuleBlocked(orgId, target, selector)) return (false, 0, 0);

        bytes32 typeId = hub.getTargetType(orgId, target);
        if (typeId == bytes32(0)) return (false, 0, 0);

        Rule memory global = hub.getGlobalRule(typeId, selector);
        if (!global.allowed) return (false, 0, 0);
        return (true, global.maxCallGasHint, 2);
    }

    function orgConfig(bytes32 orgId) external view returns (OrgConfig memory) {
        return hub.getOrgConfig(orgId);
    }

    function feeCaps(bytes32 orgId) external view returns (FeeCaps memory) {
        return hub.getFeeCaps(orgId);
    }

    function entryPointDeposit() external view returns (uint256) {
        address entryPoint = hub.ENTRY_POINT();
        return IEntryPoint(entryPoint).balanceOf(address(hub));
    }

    /**
     * @notice Get org's grace period status and limits
     * @dev Moved from PaymasterHub to reduce main contract bytecode size
     * @param orgId The organization identifier
     * @return inGrace True if in initial grace period
     * @return spendRemaining Spending remaining during grace (0 if not in grace)
     * @return requiresDeposit True if org needs to deposit to access solidarity
     * @return solidarityLimit Current solidarity allocation for org (per 90-day period)
     */
    function getOrgGraceStatus(bytes32 orgId)
        external
        view
        returns (bool inGrace, uint128 spendRemaining, bool requiresDeposit, uint256 solidarityLimit)
    {
        OrgConfig memory config = hub.getOrgConfig(orgId);
        OrgFinancials memory org = hub.getOrgFinancials(orgId);
        GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        SolidarityFund memory solidarity = hub.getSolidarityFund();

        inGrace = PaymasterGraceLib.isInGracePeriod(config.registeredAt, grace.initialGraceDays);

        // When distribution is paused, no solidarity is available regardless of grace/tier
        if (solidarity.distributionPaused) {
            return (inGrace, 0, true, 0);
        }

        if (inGrace) {
            uint128 spendUsed = org.solidarityUsedThisPeriod;
            spendRemaining = spendUsed < grace.maxSpendDuringGrace ? grace.maxSpendDuringGrace - spendUsed : 0;
            requiresDeposit = false;
            solidarityLimit = uint256(grace.maxSpendDuringGrace);
        } else {
            uint256 depositAvailable = org.deposited > org.spent ? org.deposited - org.spent : 0;
            requiresDeposit = depositAvailable < grace.minDepositRequired;
            solidarityLimit = PaymasterGraceLib.calculateMatchAllowance(depositAvailable, grace.minDepositRequired);
        }
    }

    /**
     * @notice Check if a UserOperation would be valid without state changes
     * @param orgId The org to validate against
     * @param userOp The packed user operation to check
     * @param maxCost The maximum cost to check budget against
     * @return valid Whether the operation would pass validation
     * @return reason Human-readable reason if invalid
     */
    function wouldValidate(bytes32 orgId, PackedUserOperation calldata userOp, uint256 maxCost)
        external
        view
        returns (bool valid, string memory reason)
    {
        // Decode paymasterAndData FIRST and branch on subjectType, mirroring the hub's ordering
        // (M-11/#181): the hub validates onboarding / org-deploy BEFORE any org lookup, and both
        // require the decoded orgId == bytes32(0) (org 0 is never registered). The old lens ran
        // the OrgNotRegistered / OrgIdMismatch checks first, making both sponsorship branches
        // unreachable. Decoding up front makes the predictor agree with the hub.
        (uint8 version, bytes32 decodedOrgId, uint8 subjectType, bytes32 subjectId, uint32 ruleId) =
            _decodePaymasterData(userOp.paymasterAndData);

        if (version != PAYMASTER_DATA_VERSION) return (false, "InvalidVersion");

        // Onboarding sponsorship (global-only, no org registration required).
        if (subjectType == SUBJECT_TYPE_POA_ONBOARDING) {
            if (decodedOrgId != bytes32(0) || subjectId != bytes32(0) || ruleId != RULE_ID_GENERIC) {
                return (false, "InvalidOnboardingRequest");
            }
            OnboardingConfig memory onb = hub.getOnboardingConfig();
            if (!onb.enabled) return (false, "OnboardingDisabled");
            SolidarityFund memory sol = hub.getSolidarityFund();
            if (sol.distributionPaused) return (false, "SolidarityDistributionIsPaused");
            if (maxCost > onb.maxGasPerCreation) return (false, "GasTooHigh");
            if (sol.balance < maxCost) return (false, "InsufficientFunds");
            return (true, "Onboarding");
        }

        // Org-deploy sponsorship (global-only).
        if (subjectType == SUBJECT_TYPE_ORG_DEPLOY) {
            if (decodedOrgId != bytes32(0) || subjectId != bytes32(0) || ruleId != RULE_ID_GENERIC) {
                return (false, "InvalidOrgDeployRequest");
            }
            OrgDeployConfig memory dep = hub.getOrgDeployConfig();
            if (!dep.enabled) return (false, "OrgDeployDisabled");
            SolidarityFund memory sol = hub.getSolidarityFund();
            if (sol.distributionPaused) return (false, "SolidarityDistributionIsPaused");
            if (maxCost > dep.maxGasPerDeploy) return (false, "GasTooHigh");
            if (sol.balance < maxCost) return (false, "InsufficientFunds");
            return (true, "OrgDeploy");
        }

        // Org-scoped path: now enforce org registration and the orgId match.
        if (decodedOrgId != orgId) return (false, "OrgIdMismatch");
        OrgConfig memory cfg = hub.getOrgConfig(orgId);
        if (cfg.adminHatId == 0) return (false, "OrgNotRegistered");
        if (cfg.paused) return (false, "Paused");

        // Check subject eligibility
        bytes32 subjectKey;
        if (subjectType == SUBJECT_TYPE_ACCOUNT) {
            if (address(uint160(uint256(subjectId))) != userOp.sender) return (false, "Ineligible");
            subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
        } else if (subjectType == SUBJECT_TYPE_HAT) {
            uint256 hatId = uint256(subjectId);
            IHats hatsContract = IHats(hub.HATS());
            // Use isEligible — allows vouched users who don't yet wear the hat to get sponsored gas
            if (!hatsContract.isEligible(userOp.sender, hatId)) {
                return (false, "Ineligible");
            }
            // Ensure the hat itself is still active (toggle module check)
            (,,,,,,,, bool active) = hatsContract.viewHat(hatId);
            if (!active) {
                return (false, "Ineligible");
            }
            subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
        } else if (subjectType == SUBJECT_TYPE_CLAIM) {
            // Mirrors PaymasterHub: no wearer-eligibility pre-check — the claim contract is the gate.
            // Bind the sponsorship to the claim contract: callData must be execute(subjectId, 0, ...).
            (bool validClaim,) =
                PaymasterCalldataLib.parseExecuteCall(userOp.callData, address(uint160(uint256(subjectId))));
            if (!validClaim) return (false, "Ineligible");
            subjectKey = keccak256(abi.encodePacked(subjectType, subjectId));
        } else {
            return (false, "InvalidSubjectType");
        }

        // Check fee/gas caps (L-36: the hub enforces these in validation; predict them too).
        if (!_feeCapsOk(orgId, userOp)) return (false, "FeeOrGasTooHigh");

        // Check rules. For RULE_ID_GENERIC executeBatch, validate EVERY inner call against org
        // rules (L-35) instead of one synthetic (sender, batchSelector) pair.
        if (!_rulesOk(orgId, userOp, ruleId)) return (false, "RuleDenied");

        // Check budget. Widen the epoch-end comparison to uint256 (L-37): epochStart + epochLen
        // are uint32 and can overflow in uint32 arithmetic near the year-2106 boundary, which
        // would wrongly report the epoch as still open.
        Budget memory budget = hub.getBudget(orgId, subjectKey);
        uint128 available = budget.capPerEpoch;
        if (block.timestamp < uint256(budget.epochStart) + uint256(budget.epochLen)) {
            available = budget.capPerEpoch > budget.usedInEpoch ? budget.capPerEpoch - budget.usedInEpoch : 0;
        }
        if (maxCost > available) return (false, "BudgetExceeded");

        return (true, "Valid");
    }

    /// @dev Predict the hub's fee/gas cap check (L-36).
    function _feeCapsOk(bytes32 orgId, PackedUserOperation calldata userOp) private view returns (bool) {
        FeeCaps memory caps = hub.getFeeCaps(orgId);
        (uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) = UserOpLib.unpackGasFees(userOp.gasFees);
        if (caps.maxFeePerGas > 0 && maxFeePerGas > caps.maxFeePerGas) return false;
        if (caps.maxPriorityFeePerGas > 0 && maxPriorityFeePerGas > caps.maxPriorityFeePerGas) return false;
        (uint128 verificationGasLimit, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);
        if (caps.maxCallGas > 0 && callGasLimit > caps.maxCallGas) return false;
        if (caps.maxVerificationGas > 0 && verificationGasLimit > caps.maxVerificationGas) return false;
        if (caps.maxPreVerificationGas > 0 && userOp.preVerificationGas > caps.maxPreVerificationGas) return false;
        return true;
    }

    /// @dev Predict the hub's rule check, including per-inner-call executeBatch validation (L-35).
    function _rulesOk(bytes32 orgId, PackedUserOperation calldata userOp, uint32 ruleId) private view returns (bool) {
        bytes calldata callData = userOp.callData;
        if (callData.length < 4) return false;

        if (ruleId == RULE_ID_GENERIC) {
            bytes4 outerSelector = bytes4(callData[0:4]);
            // executeBatch(address[],uint256[],bytes[]) or executeBatch(address[],bytes[])
            if (outerSelector == bytes4(0x47e1da2a) || outerSelector == bytes4(0x18dfb3c7)) {
                address[] memory targets;
                bytes[] memory datas;
                if (outerSelector == bytes4(0x47e1da2a)) {
                    (targets,, datas) = abi.decode(callData[4:], (address[], uint256[], bytes[]));
                } else {
                    (targets, datas) = abi.decode(callData[4:], (address[], bytes[]));
                }
                if (targets.length != datas.length) return false;
                for (uint256 i = 0; i < targets.length;) {
                    bytes4 innerSelector;
                    if (datas[i].length >= 4) {
                        bytes memory d = datas[i];
                        assembly {
                            innerSelector := mload(add(d, 0x20))
                        }
                    }
                    (bool innerAllowed,,) = _effectiveRule(orgId, targets[i], innerSelector);
                    if (!innerAllowed) return false;
                    unchecked {
                        ++i;
                    }
                }
                return true;
            }
        }

        (address target, bytes4 selector) = _extractTargetSelector(userOp, ruleId);
        (bool allowed, uint32 maxCallGasHint,) = _effectiveRule(orgId, target, selector);
        if (!allowed) return false;
        // Parity with PaymasterRuleLib.validateRules single-call path: a set maxCallGasHint
        // rejects ops whose callGasLimit exceeds it (GasTooHigh). The batch path above
        // intentionally skips per-call gas hints, matching the hub.
        if (maxCallGasHint > 0) {
            (, uint128 callGasLimit) = UserOpLib.unpackAccountGasLimits(userOp.accountGasLimits);
            if (callGasLimit > maxCallGasHint) return false;
        }
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IPaymaster).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ============ Helper Functions (copied from PaymasterHub) ============

    function _decodePaymasterData(bytes calldata paymasterAndData)
        private
        pure
        returns (uint8 version, bytes32 orgId, uint8 subjectType, bytes32 subjectId, uint32 ruleId)
    {
        // ERC-4337 v0.7 packed format (must match PaymasterHub._decodePaymasterData):
        // [paymaster(20) | verificationGasLimit(16) | postOpGasLimit(16) | version(1) | orgId(32) | subjectType(1) | subjectId(32) | ruleId(4)]
        // = 122 bytes total. Custom data starts at offset 52.
        if (paymasterAndData.length < 122) revert PaymasterHubErrors.InvalidPaymasterData();

        version = uint8(paymasterAndData[52]);

        // Extract orgId from bytes 53-84
        assembly {
            orgId := calldataload(add(paymasterAndData.offset, 53))
        }

        subjectType = uint8(paymasterAndData[85]);

        // Extract bytes32 subjectId from bytes 86-117
        assembly {
            subjectId := calldataload(add(paymasterAndData.offset, 86))
        }

        // Extract ruleId from bytes 118-121
        ruleId = uint32(bytes4(paymasterAndData[118:122]));
    }

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
            if (selector == 0xb61d27f6 && callData.length >= 0x64) {
                assembly {
                    // Extract target address at offset 0x04
                    target := calldataload(add(callData.offset, 0x04))

                    // Read the bytes data offset pointer at position 0x44
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
            // Check for executeBatch(address[],bytes[]) - 0x18dfb3c7 (SimpleAccount pattern)
            else if (selector == 0x18dfb3c7) {
                target = userOp.sender;
            }
            // Check for executeBatch(address[],uint256[],bytes[]) - 0x47e1da2a (PasskeyAccount pattern)
            else if (selector == 0x47e1da2a) {
                target = userOp.sender;
            } else {
                target = userOp.sender;
            }
        } else if (ruleId == RULE_ID_COARSE) {
            target = userOp.sender;
            selector = bytes4(callData[0:4]);
        } else {
            revert PaymasterHubErrors.InvalidRuleId();
        }
    }
}
