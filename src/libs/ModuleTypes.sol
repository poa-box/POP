// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/**
 * @title ModuleTypes
 * @author POA Team
 * @notice Central registry of module type identifiers (keccak256 hashes computed at compile time)
 * @dev These constants represent keccak256(moduleName) computed inline by the compiler.
 *
 *      Design rationale:
 *      - PoaManager internally uses bytes32 typeIds (keccak256 of module names)
 *      - OrgRegistry requires bytes32 typeIds for contract registration
 *      - Inline keccak256 ensures correctness verified by the compiler
 *
 *      Migration notes:
 *      - Legacy code using string-based lookups remains compatible via PoaManager.getBeacon(string)
 *      - New code should use typeId-based lookups via PoaManager.getBeaconById(bytes32)
 */
library ModuleTypes {
    bytes32 constant EXECUTOR_ID = keccak256("Executor");
    bytes32 constant QUICK_JOIN_ID = keccak256("QuickJoin");
    bytes32 constant PARTICIPATION_TOKEN_ID = keccak256("ParticipationToken");
    bytes32 constant TASK_MANAGER_ID = keccak256("TaskManager");
    bytes32 constant EDUCATION_HUB_ID = keccak256("EducationHub");
    bytes32 constant HYBRID_VOTING_ID = keccak256("HybridVoting");
    bytes32 constant ELIGIBILITY_MODULE_ID = keccak256("EligibilityModule");
    bytes32 constant TOGGLE_MODULE_ID = keccak256("ToggleModule");
    bytes32 constant PAYMENT_MANAGER_ID = keccak256("PaymentManager");
    bytes32 constant PAYMASTER_HUB_ID = keccak256("PaymasterHub");
    bytes32 constant DIRECT_DEMOCRACY_VOTING_ID = keccak256("DirectDemocracyVoting");
    bytes32 constant PASSKEY_ACCOUNT_ID = keccak256("PasskeyAccount");
    bytes32 constant PASSKEY_ACCOUNT_FACTORY_ID = keccak256("PasskeyAccountFactory");
    bytes32 constant ROLE_BUNDLE_HATTER_ID = keccak256("RoleBundleHatter");
}
