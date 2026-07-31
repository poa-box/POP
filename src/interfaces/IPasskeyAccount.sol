// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/**
 * @title IPasskeyAccount
 * @notice Interface for PasskeyAccount smart contract wallet
 * @dev Defines credential management and recovery functions for passkey-based accounts
 */
interface IPasskeyAccount {
    /*──────────────────────────── Structs ──────────────────────────────*/

    /**
     * @notice Passkey credential information
     * @param publicKeyX P256 public key X coordinate
     * @param publicKeyY P256 public key Y coordinate
     * @param createdAt Timestamp when credential was registered
     * @param signCount Last known signature count (anti-replay)
     * @param active Whether this credential is currently active
     */
    struct PasskeyCredential {
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        uint64 createdAt;
        uint32 signCount;
        bool active;
    }

    /**
     * @notice Recovery request information
     * @param credentialId ID of the new credential to add
     * @param pubKeyX New credential public key X
     * @param pubKeyY New credential public key Y
     * @param executeAfter Timestamp when recovery can be completed
     * @param cancelled Whether the request was cancelled
     */
    struct RecoveryRequest {
        bytes32 credentialId;
        bytes32 pubKeyX;
        bytes32 pubKeyY;
        uint48 executeAfter;
        bool cancelled;
    }

    /*──────────────────────────── Events ───────────────────────────────*/

    /// @notice Emitted when a new credential is added
    event CredentialAdded(bytes32 indexed credentialId, uint64 createdAt);

    /// @notice Emitted when a credential is removed
    event CredentialRemoved(bytes32 indexed credentialId);

    /// @notice Emitted when a credential is activated/deactivated
    event CredentialStatusChanged(bytes32 indexed credentialId, bool active);

    /// @notice Emitted when guardian is updated
    /// @dev Retained for the legacy single-guardian field (now inert). New multi-guardian
    ///      changes emit GuardianAdded / GuardianRemoved instead.
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Emitted when a guardian is added to the M-of-N guardian set
    event GuardianAdded(address indexed guardian);

    /// @notice Emitted when a guardian is removed from the M-of-N guardian set
    event GuardianRemoved(address indexed guardian);

    /// @notice Emitted when the recovery threshold (M in M-of-N) is updated
    event RecoveryThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when a guardian approves a pending recovery proposal
    event RecoveryApproved(bytes32 indexed proposalId, address indexed guardian, uint256 approvals);

    /// @notice Emitted when recovery delay is updated
    event RecoveryDelayUpdated(uint48 oldDelay, uint48 newDelay);

    /// @notice Emitted when recovery is initiated (quorum reached, request staged)
    event RecoveryInitiated(
        bytes32 indexed recoveryId, bytes32 credentialId, address indexed initiator, uint48 executeAfter
    );

    /// @notice Emitted when recovery is completed
    event RecoveryCompleted(bytes32 indexed recoveryId, bytes32 indexed credentialId);

    /// @notice Emitted when recovery is cancelled
    event RecoveryCancelled(bytes32 indexed recoveryId);

    /// @notice Emitted when a transaction is executed
    event Executed(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Emitted when batch transactions are executed
    event BatchExecuted(uint256 count);

    /*──────────────────────────── Errors ───────────────────────────────*/

    /// @notice Thrown when caller is not the EntryPoint
    error OnlyEntryPoint();

    /// @notice Thrown when caller is not the account itself
    error OnlySelf();

    /// @notice Thrown when caller is not the guardian
    error OnlyGuardian();

    /// @notice Thrown when caller is not the guardian or account
    error OnlyGuardianOrSelf();

    /// @notice Thrown when the caller is not a registered recovery guardian
    error NotAGuardian();

    /// @notice Thrown when the guardian address is already registered
    error GuardianAlreadyExists();

    /// @notice Thrown when the guardian address is not registered
    error GuardianDoesNotExist();

    /// @notice Thrown when a guardian tries to approve the same recovery twice
    error AlreadyApproved();

    /// @notice Thrown when the requested recovery threshold exceeds the guardian count
    error ThresholdExceedsGuardianCount();

    /// @notice Thrown when recovery is attempted while it is disabled (no guardians / threshold 0)
    error RecoveryDisabled();

    /// @notice Thrown when the recovery public key is not a valid on-curve P-256 point
    error InvalidPublicKey();

    /// @notice Thrown when credential already exists
    error CredentialExists();

    /// @notice Thrown when credential does not exist
    error CredentialNotFound();

    /// @notice Thrown when credential is not active
    error CredentialNotActive();

    /// @notice Thrown when max credentials is reached
    error MaxCredentialsReached();

    /// @notice Thrown when trying to remove the last credential
    error CannotRemoveLastCredential();

    /// @notice Thrown when recovery is already pending
    error RecoveryAlreadyPending();

    /// @notice Thrown when recovery is not pending
    error RecoveryNotPending();

    /// @notice Thrown when recovery delay hasn't passed
    error RecoveryDelayNotPassed();

    /// @notice Thrown when call execution fails
    error ExecutionFailed();

    /// @notice Thrown when array lengths mismatch
    error ArrayLengthMismatch();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when signature is invalid
    error InvalidSignature();

    /*──────────────────────────── View Functions ──────────────────────*/

    /**
     * @notice Get credential information
     * @param credentialId The credential ID to query
     * @return credential The credential information
     */
    function getCredential(bytes32 credentialId) external view returns (PasskeyCredential memory credential);

    /**
     * @notice Get all credential IDs for this account
     * @return credentialIds Array of credential IDs
     */
    function getCredentialIds() external view returns (bytes32[] memory credentialIds);

    /**
     * @notice Get the legacy single-guardian address (inert; retained for storage compatibility)
     * @return guardian The legacy guardian address
     * @dev This address no longer grants any recovery power. Use the M-of-N guardian set instead.
     */
    function guardian() external view returns (address guardian);

    /**
     * @notice Get the M-of-N recovery guardian set
     * @return guardians The list of registered recovery guardians
     */
    function getGuardians() external view returns (address[] memory guardians);

    /**
     * @notice Check whether an address is a registered recovery guardian
     * @param account The address to check
     * @return True if the address is a guardian
     */
    function isGuardian(address account) external view returns (bool);

    /**
     * @notice Get the current recovery threshold (M in M-of-N)
     * @return threshold Number of distinct guardian approvals required to stage a recovery
     */
    function recoveryThreshold() external view returns (uint256 threshold);

    /**
     * @notice Get the number of approvals a recovery proposal currently has
     * @param proposalId keccak256(credentialId, pubKeyX, pubKeyY)
     * @return count Number of distinct guardian approvals collected so far
     */
    function recoveryApprovalCount(bytes32 proposalId) external view returns (uint256 count);

    /**
     * @notice Check whether a specific guardian has approved a recovery proposal
     * @param proposalId keccak256(credentialId, pubKeyX, pubKeyY)
     * @param guardianAddr The guardian address
     * @return True if that guardian has already approved the proposal
     */
    function hasApprovedRecovery(bytes32 proposalId, address guardianAddr) external view returns (bool);

    /**
     * @notice Get the recovery delay
     * @return delay Recovery delay in seconds
     */
    function recoveryDelay() external view returns (uint48 delay);

    /**
     * @notice Get a pending recovery request
     * @param recoveryId The recovery request ID
     * @return request The recovery request
     */
    function getRecoveryRequest(bytes32 recoveryId) external view returns (RecoveryRequest memory request);

    /**
     * @notice Get the factory that created this account
     * @return factory The factory address
     */
    function factory() external view returns (address factory);

    /*──────────────────────────── Credential Management ───────────────*/

    /**
     * @notice Add a new passkey credential
     * @param credentialId Unique identifier for the credential (hash of WebAuthn credentialId)
     * @param pubKeyX P256 public key X coordinate
     * @param pubKeyY P256 public key Y coordinate
     * @dev Only callable via UserOp (self-call through EntryPoint)
     */
    function addCredential(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY) external;

    /**
     * @notice Remove a passkey credential
     * @param credentialId The credential to remove
     * @dev Only callable via UserOp, cannot remove last credential
     */
    function removeCredential(bytes32 credentialId) external;

    /**
     * @notice Set credential active status
     * @param credentialId The credential to update
     * @param active Whether the credential should be active
     */
    function setCredentialActive(bytes32 credentialId, bool active) external;

    /*──────────────────────────── Guardian Management ─────────────────*/

    /**
     * @notice Add a recovery guardian to the M-of-N guardian set
     * @param newGuardian The guardian address to add
     * @dev Only callable via UserOp (owner self-call). Reverts on zero/duplicate.
     */
    function addGuardian(address newGuardian) external;

    /**
     * @notice Remove a recovery guardian from the M-of-N guardian set
     * @param oldGuardian The guardian address to remove
     * @dev Only callable via UserOp. If the removal drops the guardian count below the
     *      current threshold, the threshold is lowered to the new guardian count.
     */
    function removeGuardian(address oldGuardian) external;

    /**
     * @notice Set the recovery threshold (M in M-of-N)
     * @param newThreshold Number of distinct guardian approvals required to stage a recovery
     * @dev Only callable via UserOp. Must satisfy newThreshold <= guardian count.
     *      A threshold of 0 disables recovery entirely.
     */
    function setRecoveryThreshold(uint256 newThreshold) external;

    /**
     * @notice Update the recovery delay
     * @param newDelay The new recovery delay in seconds
     * @dev Only callable via UserOp
     */
    function setRecoveryDelay(uint48 newDelay) external;

    /*──────────────────────────── Recovery Functions ──────────────────*/

    /**
     * @notice Approve (and, on reaching quorum, stage) an account recovery with a new credential
     * @param credentialId ID for the new credential
     * @param pubKeyX New credential public key X
     * @param pubKeyY New credential public key Y
     * @dev Only callable by a registered guardian. Each distinct guardian approval counts once.
     *      The recovery is only staged (delay timer started) once `recoveryThreshold` distinct
     *      guardians have approved the same (credentialId, pubKeyX, pubKeyY) proposal. The new
     *      public key must be a valid on-curve P-256 point.
     */
    function approveRecovery(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY) external;

    /**
     * @notice Compute the proposal id used to accumulate guardian approvals
     * @param credentialId ID for the new credential
     * @param pubKeyX New credential public key X
     * @param pubKeyY New credential public key Y
     * @return proposalId keccak256(credentialId, pubKeyX, pubKeyY)
     */
    function computeRecoveryProposalId(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY)
        external
        pure
        returns (bytes32 proposalId);

    /**
     * @notice Complete a pending recovery
     * @param recoveryId The recovery request ID to complete
     * @dev Anyone can call after delay passes.
     */
    function completeRecovery(bytes32 recoveryId) external;

    /**
     * @notice Cancel a pending recovery
     * @param recoveryId The recovery request ID to cancel
     * @dev Callable by guardian or account owner
     */
    function cancelRecovery(bytes32 recoveryId) external;

    /*──────────────────────────── Execution Functions ─────────────────*/

    /**
     * @notice Execute a single transaction
     * @param target Target address
     * @param value ETH value to send
     * @param data Calldata
     * @return result Return data from the call
     */
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result);

    /**
     * @notice Execute multiple transactions
     * @param targets Target addresses
     * @param values ETH values to send
     * @param datas Calldatas
     */
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external;
}
