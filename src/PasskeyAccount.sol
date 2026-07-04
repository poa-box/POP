// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/*──────────────────── OpenZeppelin Upgradeables ────────────────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

/*──────────────────── Interfaces ────────────────────────────────────*/
import {IAccount} from "./interfaces/IAccount.sol";
import {IPasskeyAccount} from "./interfaces/IPasskeyAccount.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

/// @notice Interface for reading factory config
interface IPasskeyAccountFactoryConfig {
    struct GlobalConfig {
        address poaGuardian;
        uint48 recoveryDelay;
        uint8 maxCredentialsPerAccount;
        bool paused;
    }

    function getGlobalConfig() external view returns (GlobalConfig memory);
}

/*──────────────────── Libraries ────────────────────────────────────*/
import {WebAuthnLib} from "./libs/WebAuthnLib.sol";
import {P256Verifier} from "./libs/P256Verifier.sol";

/**
 * @title PasskeyAccount
 * @author POA Team
 * @notice ERC-4337 smart contract wallet with WebAuthn/Passkey authentication
 * @dev Features:
 *      - Multi-passkey support (up to maxCredentials per org)
 *      - M-of-N threshold multi-guardian recovery with time delay (H-04). Recovery is DISABLED by
 *        default (no guardians, threshold 0) until the owner configures a guardian set. A single
 *        guardian can never stage a recovery; `recoveryThreshold` distinct guardians must approve.
 *      - Per-org credential tracking to prevent account selling
 *      - EIP-7951 native P256 signature verification
 *
 *      Architecture:
 *      - Uses ERC-7201 namespaced storage for upgrade safety
 *      - Deployed via BeaconProxy for upgradeability
 *      - Integrates with ERC-4337 EntryPoint v0.7
 */
contract PasskeyAccount is Initializable, IAccount, IPasskeyAccount {
    /*──────────────────────────── Constants ────────────────────────────*/

    /// @notice ERC-4337 EntryPoint v0.7 address (same on all chains)
    address public constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice Signature validation failed return value
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @notice Maximum number of credentials per account (global limit)
    uint8 internal constant MAX_CREDENTIALS = 10;

    /// @notice Minimum recovery delay (1 day)
    uint48 internal constant MIN_RECOVERY_DELAY = 1 days;

    /// @notice Module identifier
    bytes4 public constant MODULE_ID = bytes4(keccak256("PasskeyAccount"));

    /*──────────────────────── ERC-7201 Storage ──────────────────────────*/

    /// @custom:storage-location erc7201:poa.passkeyaccount.storage
    /// @dev APPEND-ONLY. New H-04 (M-of-N recovery) fields are appended at the END of the struct.
    ///      Existing deployed accounts read those appended slots as zero: guardians == [] and
    ///      recoveryThreshold == 0, which by design means recovery is DISABLED until the owner
    ///      configures a guardian set. The legacy single `guardian` field is now INERT (it grants
    ///      no recovery power); it is retained only to preserve the storage layout.
    struct Layout {
        // Factory that created this account
        address factory;
        // Passkey credentials
        mapping(bytes32 => PasskeyCredential) credentials;
        bytes32[] credentialIds;
        // Legacy single-guardian recovery fields (INERT — kept for storage-layout compatibility)
        address guardian;
        uint48 recoveryDelay;
        mapping(bytes32 => RecoveryRequest) recoveryRequests;
        bytes32[] pendingRecoveryIds;
        // ── H-04: M-of-N multi-guardian recovery (APPENDED — reads as empty on legacy accounts) ──
        address[] guardians;
        mapping(address => bool) isGuardianMap;
        uint256 recoveryThreshold;
        // Per-proposal guardian approval accounting.
        // proposalId = keccak256(credentialId, pubKeyX, pubKeyY)
        mapping(bytes32 => uint256) recoveryApprovals;
        mapping(bytes32 => mapping(address => bool)) recoveryApprovedBy;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.passkeyaccount.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*──────────────────────────── Modifiers ────────────────────────────*/

    /// @notice Restrict to EntryPoint only
    modifier onlyEntryPoint() {
        if (msg.sender != ENTRY_POINT) revert OnlyEntryPoint();
        _;
    }

    /// @notice Restrict to self-calls (via EntryPoint execution)
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @notice Restrict to a registered M-of-N recovery guardian
    modifier onlyGuardian() {
        if (!_layout().isGuardianMap[msg.sender]) revert NotAGuardian();
        _;
    }

    /// @notice Restrict to a registered recovery guardian or the account itself
    modifier onlyGuardianOrSelf() {
        Layout storage l = _layout();
        if (!l.isGuardianMap[msg.sender] && msg.sender != address(this)) {
            revert OnlyGuardianOrSelf();
        }
        _;
    }

    /*──────────────────────────── Constructor ──────────────────────────*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*──────────────────────────── Initializer ──────────────────────────*/

    /**
     * @notice Initialize the passkey account
     * @param factory_ The factory that created this account
     * @param credentialId Initial credential ID
     * @param pubKeyX Initial credential public key X
     * @param pubKeyY Initial credential public key Y
     * @dev M-06: no guardian/recovery-delay config is baked in here, so the counterfactual
     *      account address is a pure function of (factory, credentialId, pubKeyX, pubKeyY, salt)
     *      and never depends on mutable factory config. The account starts with NO guardians and
     *      threshold 0 (recovery DISABLED). The owner configures the M-of-N guardian set lazily
     *      via addGuardian / setRecoveryThreshold (owner self-calls through the EntryPoint).
     *      The recovery delay defaults to MIN_RECOVERY_DELAY and can be raised via setRecoveryDelay.
     */
    function initialize(address factory_, bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY) external initializer {
        if (factory_ == address(0)) revert ZeroAddress();
        if (pubKeyX == bytes32(0) || pubKeyY == bytes32(0)) revert InvalidSignature();

        Layout storage l = _layout();

        l.factory = factory_;
        // Recovery starts DISABLED: no guardians, threshold 0. Delay defaults to the minimum.
        l.recoveryDelay = MIN_RECOVERY_DELAY;

        // Register initial credential
        l.credentials[credentialId] = PasskeyCredential({
            publicKeyX: pubKeyX, publicKeyY: pubKeyY, createdAt: uint64(block.timestamp), signCount: 0, active: true
        });
        l.credentialIds.push(credentialId);

        emit CredentialAdded(credentialId, uint64(block.timestamp));
    }

    /*──────────────────────────── ERC-4337 IAccount ────────────────────*/

    /**
     * @notice Validate a UserOperation signature
     * @param userOp The UserOperation to validate
     * @param userOpHash Hash of the UserOperation
     * @param missingAccountFunds Amount to pay to EntryPoint
     * @return validationData 0 for success, 1 for failure
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        onlyEntryPoint
        returns (uint256 validationData)
    {
        // Verify the WebAuthn signature
        validationData = _validateSignature(userOp.signature, userOpHash);

        // Pay prefund to EntryPoint
        if (missingAccountFunds > 0) {
            // solhint-disable-next-line no-unused-vars
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds}("");
            // Return value intentionally ignored - EntryPoint validates the deposit
        }
    }

    /**
     * @notice Validate the WebAuthn signature
     * @param signature Encoded WebAuthn signature
     * @param userOpHash The challenge (userOpHash)
     * @return validationData 0 for success, 1 for failure
     */
    function _validateSignature(bytes calldata signature, bytes32 userOpHash)
        internal
        returns (uint256 validationData)
    {
        // Decode the signature
        // Format: credentialId(32) || WebAuthnAuth
        if (signature.length < 32) {
            return SIG_VALIDATION_FAILED;
        }

        bytes32 credentialId = bytes32(signature[0:32]);
        Layout storage l = _layout();

        // Get the credential
        PasskeyCredential storage cred = l.credentials[credentialId];
        if (!cred.active) {
            return SIG_VALIDATION_FAILED;
        }

        // Decode WebAuthn auth data
        WebAuthnLib.WebAuthnAuth memory auth = abi.decode(signature[32:], (WebAuthnLib.WebAuthnAuth));

        // Verify with signCount check
        (bool valid, uint32 newSignCount) = WebAuthnLib.verifyWithSignCount(
            auth,
            userOpHash,
            cred.publicKeyX,
            cred.publicKeyY,
            false, // Don't require user verification (UP is enough)
            cred.signCount
        );

        if (!valid) {
            return SIG_VALIDATION_FAILED;
        }

        // Update signCount
        cred.signCount = newSignCount;

        return 0;
    }

    /*──────────────────────────── Credential Management ───────────────*/

    /// @inheritdoc IPasskeyAccount
    function addCredential(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY) external override onlySelf {
        if (pubKeyX == bytes32(0) || pubKeyY == bytes32(0)) revert InvalidSignature();
        Layout storage l = _layout();

        // Check if credential already exists
        if (l.credentials[credentialId].createdAt != 0) {
            revert CredentialExists();
        }

        // Check global limit from factory config
        uint8 maxCreds = _getMaxCredentials();
        if (l.credentialIds.length >= maxCreds) {
            revert MaxCredentialsReached();
        }

        // Add credential
        l.credentials[credentialId] = PasskeyCredential({
            publicKeyX: pubKeyX, publicKeyY: pubKeyY, createdAt: uint64(block.timestamp), signCount: 0, active: true
        });
        l.credentialIds.push(credentialId);

        emit CredentialAdded(credentialId, uint64(block.timestamp));
    }

    /// @inheritdoc IPasskeyAccount
    function removeCredential(bytes32 credentialId) external override onlySelf {
        Layout storage l = _layout();

        // Cannot remove last credential
        if (l.credentialIds.length <= 1) {
            revert CannotRemoveLastCredential();
        }

        PasskeyCredential storage cred = l.credentials[credentialId];
        if (cred.createdAt == 0) {
            revert CredentialNotFound();
        }

        // Remove from array
        _removeCredentialFromArray(credentialId);

        // Delete credential
        delete l.credentials[credentialId];

        emit CredentialRemoved(credentialId);
    }

    /// @inheritdoc IPasskeyAccount
    function setCredentialActive(bytes32 credentialId, bool active) external override onlySelf {
        Layout storage l = _layout();
        PasskeyCredential storage cred = l.credentials[credentialId];

        if (cred.createdAt == 0) {
            revert CredentialNotFound();
        }

        cred.active = active;
        emit CredentialStatusChanged(credentialId, active);
    }

    /*──────────────────────────── Guardian Management (M-of-N) ────────*/

    /// @inheritdoc IPasskeyAccount
    function addGuardian(address newGuardian) external override onlySelf {
        if (newGuardian == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        if (l.isGuardianMap[newGuardian]) revert GuardianAlreadyExists();

        l.isGuardianMap[newGuardian] = true;
        l.guardians.push(newGuardian);

        emit GuardianAdded(newGuardian);
    }

    /// @inheritdoc IPasskeyAccount
    function removeGuardian(address oldGuardian) external override onlySelf {
        Layout storage l = _layout();
        if (!l.isGuardianMap[oldGuardian]) revert GuardianDoesNotExist();

        l.isGuardianMap[oldGuardian] = false;
        _removeGuardianFromArray(oldGuardian);

        emit GuardianRemoved(oldGuardian);

        // Keep the invariant threshold <= guardian count: if removing a guardian drops the
        // count below the current threshold, lower the threshold to the new count (which may
        // be 0, disabling recovery). This prevents an unreachable-quorum lockout state.
        uint256 count = l.guardians.length;
        if (l.recoveryThreshold > count) {
            uint256 oldThreshold = l.recoveryThreshold;
            l.recoveryThreshold = count;
            emit RecoveryThresholdUpdated(oldThreshold, count);
        }
    }

    /// @inheritdoc IPasskeyAccount
    function setRecoveryThreshold(uint256 newThreshold) external override onlySelf {
        Layout storage l = _layout();
        if (newThreshold > l.guardians.length) revert ThresholdExceedsGuardianCount();

        uint256 oldThreshold = l.recoveryThreshold;
        l.recoveryThreshold = newThreshold;

        emit RecoveryThresholdUpdated(oldThreshold, newThreshold);
    }

    /// @inheritdoc IPasskeyAccount
    function setRecoveryDelay(uint48 newDelay) external override onlySelf {
        Layout storage l = _layout();
        uint48 oldDelay = l.recoveryDelay;

        // Enforce minimum delay
        l.recoveryDelay = newDelay < MIN_RECOVERY_DELAY ? MIN_RECOVERY_DELAY : newDelay;

        emit RecoveryDelayUpdated(oldDelay, l.recoveryDelay);
    }

    /*──────────────────────────── Recovery Functions ──────────────────*/

    /// @inheritdoc IPasskeyAccount
    function computeRecoveryProposalId(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY)
        public
        pure
        override
        returns (bytes32 proposalId)
    {
        return keccak256(abi.encodePacked(credentialId, pubKeyX, pubKeyY));
    }

    /// @inheritdoc IPasskeyAccount
    /// @dev H-04: a single guardian can no longer stage a recovery. Each distinct guardian records
    ///      one approval against the (credentialId, pubKeyX, pubKeyY) proposal; only once
    ///      `recoveryThreshold` distinct guardians have approved is the recovery staged (delay timer
    ///      started). With no guardians / threshold 0, recovery is DISABLED and this reverts.
    function approveRecovery(bytes32 credentialId, bytes32 pubKeyX, bytes32 pubKeyY) external override onlyGuardian {
        if (pubKeyX == bytes32(0) || pubKeyY == bytes32(0)) revert InvalidSignature();
        Layout storage l = _layout();

        // Recovery must be enabled: a non-zero threshold and at least that many guardians.
        uint256 threshold = l.recoveryThreshold;
        if (threshold == 0) revert RecoveryDisabled();

        // H-04 hardening: staged recovery key must be a valid on-curve P-256 point.
        if (!P256Verifier.isValidPublicKey(pubKeyX, pubKeyY)) revert InvalidPublicKey();

        // New credential must not already exist.
        if (l.credentials[credentialId].createdAt != 0) revert CredentialExists();

        bytes32 proposalId = keccak256(abi.encodePacked(credentialId, pubKeyX, pubKeyY));

        // A guardian cannot approve the same proposal twice to fake quorum.
        if (l.recoveryApprovedBy[proposalId][msg.sender]) revert AlreadyApproved();
        l.recoveryApprovedBy[proposalId][msg.sender] = true;

        uint256 approvals = l.recoveryApprovals[proposalId] + 1;
        l.recoveryApprovals[proposalId] = approvals;

        emit RecoveryApproved(proposalId, msg.sender, approvals);

        // Not yet at quorum — wait for more distinct guardian approvals.
        if (approvals < threshold) return;

        // Quorum reached: stage the recovery request with the delay timer.
        bytes32 recoveryId = keccak256(abi.encodePacked(proposalId, block.timestamp));

        // Defensive: an identical proposal already staged in the same block is a no-op re-stage.
        if (l.recoveryRequests[recoveryId].executeAfter != 0) revert RecoveryAlreadyPending();

        uint48 executeAfter = uint48(block.timestamp) + l.recoveryDelay;

        l.recoveryRequests[recoveryId] = RecoveryRequest({
            credentialId: credentialId, pubKeyX: pubKeyX, pubKeyY: pubKeyY, executeAfter: executeAfter, cancelled: false
        });
        l.pendingRecoveryIds.push(recoveryId);

        // Clear the approval accounting for this proposal so a future recovery for the same
        // (credentialId, pubKeyX, pubKeyY) starts fresh.
        _clearRecoveryApprovals(proposalId);

        emit RecoveryInitiated(recoveryId, credentialId, msg.sender, executeAfter);
    }

    /// @inheritdoc IPasskeyAccount
    function completeRecovery(bytes32 recoveryId) external override {
        Layout storage l = _layout();
        RecoveryRequest storage request = l.recoveryRequests[recoveryId];

        if (request.executeAfter == 0) {
            revert RecoveryNotPending();
        }

        if (request.cancelled) {
            revert RecoveryNotPending();
        }

        if (block.timestamp < request.executeAfter) {
            revert RecoveryDelayNotPassed();
        }

        // Delete all existing credentials from mapping and clear the array.
        // This prevents unbounded array growth from repeated recoveries.
        uint256 credCount = l.credentialIds.length;
        for (uint256 i = 0; i < credCount; i++) {
            bytes32 existingCredId = l.credentialIds[i];
            if (l.credentials[existingCredId].active) {
                emit CredentialStatusChanged(existingCredId, false);
            }
            delete l.credentials[existingCredId];
        }
        // Clear the credentialIds array
        while (l.credentialIds.length > 0) {
            l.credentialIds.pop();
        }

        // Add only the new recovery credential
        bytes32 credentialId = request.credentialId;

        l.credentials[credentialId] = PasskeyCredential({
            publicKeyX: request.pubKeyX,
            publicKeyY: request.pubKeyY,
            createdAt: uint64(block.timestamp),
            signCount: 0,
            active: true
        });
        l.credentialIds.push(credentialId);

        // Mark recovery as completed by setting executeAfter to 0
        request.executeAfter = 0;

        // Cancel all other pending recovery requests to prevent race conditions
        // where a second recovery could wipe the credential just added by this one.
        uint256 pendingLen = l.pendingRecoveryIds.length;
        for (uint256 i = 0; i < pendingLen; i++) {
            bytes32 otherId = l.pendingRecoveryIds[i];
            if (otherId != recoveryId && !l.recoveryRequests[otherId].cancelled) {
                l.recoveryRequests[otherId].cancelled = true;
                emit RecoveryCancelled(otherId);
            }
        }
        // Clear the entire pending array since all are now resolved
        while (l.pendingRecoveryIds.length > 0) {
            l.pendingRecoveryIds.pop();
        }

        emit RecoveryCompleted(recoveryId, credentialId);
        emit CredentialAdded(credentialId, uint64(block.timestamp));
    }

    /// @inheritdoc IPasskeyAccount
    function cancelRecovery(bytes32 recoveryId) external override onlyGuardianOrSelf {
        Layout storage l = _layout();
        RecoveryRequest storage request = l.recoveryRequests[recoveryId];

        if (request.executeAfter == 0 || request.cancelled) {
            revert RecoveryNotPending();
        }

        request.cancelled = true;
        emit RecoveryCancelled(recoveryId);

        _removePendingRecovery(recoveryId);
    }

    /*──────────────────────────── Execution Functions ─────────────────*/

    /// @inheritdoc IPasskeyAccount
    function execute(address target, uint256 value, bytes calldata data)
        external
        override
        returns (bytes memory result)
    {
        // Can be called by EntryPoint or self
        if (msg.sender != ENTRY_POINT && msg.sender != address(this)) {
            revert OnlySelf();
        }

        bool success;
        (success, result) = target.call{value: value}(data);

        if (!success) {
            // Bubble up revert reason
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        emit Executed(target, value, data, result);
    }

    /// @inheritdoc IPasskeyAccount
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas)
        external
        override
    {
        // Can be called by EntryPoint or self
        if (msg.sender != ENTRY_POINT && msg.sender != address(this)) {
            revert OnlySelf();
        }

        if (targets.length != values.length || targets.length != datas.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);

            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }

        emit BatchExecuted(targets.length);
    }

    /*──────────────────────────── View Functions ──────────────────────*/

    /// @inheritdoc IPasskeyAccount
    function getCredential(bytes32 credentialId) external view override returns (PasskeyCredential memory credential) {
        return _layout().credentials[credentialId];
    }

    /// @inheritdoc IPasskeyAccount
    function getCredentialIds() external view override returns (bytes32[] memory) {
        return _layout().credentialIds;
    }

    /// @inheritdoc IPasskeyAccount
    function guardian() external view override returns (address) {
        return _layout().guardian;
    }

    /// @inheritdoc IPasskeyAccount
    function getGuardians() external view override returns (address[] memory) {
        return _layout().guardians;
    }

    /// @inheritdoc IPasskeyAccount
    function isGuardian(address account) external view override returns (bool) {
        return _layout().isGuardianMap[account];
    }

    /// @inheritdoc IPasskeyAccount
    function recoveryThreshold() external view override returns (uint256) {
        return _layout().recoveryThreshold;
    }

    /// @inheritdoc IPasskeyAccount
    function recoveryApprovalCount(bytes32 proposalId) external view override returns (uint256) {
        return _layout().recoveryApprovals[proposalId];
    }

    /// @inheritdoc IPasskeyAccount
    function hasApprovedRecovery(bytes32 proposalId, address guardianAddr) external view override returns (bool) {
        return _layout().recoveryApprovedBy[proposalId][guardianAddr];
    }

    /// @inheritdoc IPasskeyAccount
    function recoveryDelay() external view override returns (uint48) {
        return _layout().recoveryDelay;
    }

    /// @inheritdoc IPasskeyAccount
    function getRecoveryRequest(bytes32 recoveryId) external view override returns (RecoveryRequest memory) {
        return _layout().recoveryRequests[recoveryId];
    }

    /// @inheritdoc IPasskeyAccount
    function factory() external view override returns (address) {
        return _layout().factory;
    }

    /*──────────────────────────── Internal Helpers ────────────────────*/

    /**
     * @notice Remove a credential ID from the array
     * @param credentialId The credential ID to remove
     */
    function _removeCredentialFromArray(bytes32 credentialId) internal {
        Layout storage l = _layout();
        uint256 length = l.credentialIds.length;

        for (uint256 i = 0; i < length; i++) {
            if (l.credentialIds[i] == credentialId) {
                // Swap with last element and pop
                l.credentialIds[i] = l.credentialIds[length - 1];
                l.credentialIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Remove a guardian from the guardian array (swap-and-pop)
     * @param guardianAddr The guardian address to remove
     */
    function _removeGuardianFromArray(address guardianAddr) private {
        Layout storage l = _layout();
        uint256 len = l.guardians.length;
        for (uint256 i = 0; i < len; i++) {
            if (l.guardians[i] == guardianAddr) {
                l.guardians[i] = l.guardians[len - 1];
                l.guardians.pop();
                break;
            }
        }
    }

    /**
     * @notice Reset the per-guardian approval flags and the count for a recovery proposal.
     * @param proposalId keccak256(credentialId, pubKeyX, pubKeyY)
     * @dev Iterates the bounded guardian set. Called after quorum is reached and the request is
     *      staged, so a subsequent recovery for the same key starts from a clean slate.
     */
    function _clearRecoveryApprovals(bytes32 proposalId) private {
        Layout storage l = _layout();
        uint256 len = l.guardians.length;
        for (uint256 i = 0; i < len; i++) {
            address g = l.guardians[i];
            if (l.recoveryApprovedBy[proposalId][g]) {
                l.recoveryApprovedBy[proposalId][g] = false;
            }
        }
        l.recoveryApprovals[proposalId] = 0;
    }

    /**
     * @notice Remove a recovery ID from the pending array
     * @param recoveryId The recovery ID to remove
     */
    function _removePendingRecovery(bytes32 recoveryId) private {
        Layout storage l = _layout();
        uint256 len = l.pendingRecoveryIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (l.pendingRecoveryIds[i] == recoveryId) {
                l.pendingRecoveryIds[i] = l.pendingRecoveryIds[len - 1];
                l.pendingRecoveryIds.pop();
                break;
            }
        }
    }

    /// @notice Get max credentials from factory's global config
    /// @dev Falls back to hardcoded MAX_CREDENTIALS if factory call fails
    function _getMaxCredentials() internal view returns (uint8) {
        Layout storage l = _layout();
        if (l.factory == address(0)) {
            return MAX_CREDENTIALS;
        }

        try IPasskeyAccountFactoryConfig(l.factory).getGlobalConfig() returns (
            IPasskeyAccountFactoryConfig.GlobalConfig memory config
        ) {
            return config.maxCredentialsPerAccount > 0 ? config.maxCredentialsPerAccount : MAX_CREDENTIALS;
        } catch {
            return MAX_CREDENTIALS;
        }
    }

    /*──────────────────────────── Receive ETH ─────────────────────────*/

    receive() external payable {}
}
