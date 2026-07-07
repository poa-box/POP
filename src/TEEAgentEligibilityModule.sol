// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IHatsEligibility} from "@hats-protocol/src/Interfaces/IHatsEligibility.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ITEEAttestationVerifier} from "./interfaces/ITEEAttestationVerifier.sol";

/**
 * @title TEEAgentEligibilityModule
 * @notice A Hats Protocol eligibility module that pins a hat to a TEE-attested
 *         enclave measurement. A wallet may wear the agent hat only while it
 *         holds a fresh attestation binding it to an enclave *image* that
 *         governance has explicitly allowed for that hat.
 *
 * @dev This makes "the org hires attested software" concrete, and — crucially —
 *      makes upgrading the agent's code a governance event: a new enclave image
 *      produces a new `measurement`, which governance must register before the
 *      new build can wear the hat. Rotating or revoking a measurement instantly
 *      de-eligibilizes every wallet running that image (Hats calls
 *      {getWearerStatus} live), so a compromised or retired build loses its hat
 *      with no per-wallet bookkeeping.
 *
 *      Trust in the *attestation itself* is delegated to a pluggable
 *      {ITEEAttestationVerifier}, so the module is agnostic to how a quote is
 *      checked (trusted notary today, on-chain DCAP later).
 *
 *      Storage uses ERC-7201-style namespaced storage; no `__gap`. Access is
 *      gated by a `governor` address (the org's Executor), matching the
 *      project convention of governance-controlled admin rather than OZ
 *      AccessControl.
 */
contract TEEAgentEligibilityModule is Initializable, IHatsEligibility {
    /*═══════════════════════════════ ERRORS ═══════════════════════════════*/

    /// @notice Caller is not the configured governor.
    error NotGovernor();
    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice The attested measurement is not allowed for this hat.
    error MeasurementNotAllowed();
    /// @notice The attestation names a different subject than expected.
    error SubjectMismatch();
    /// @notice The attestation is already expired at submission time.
    error AttestationExpired();
    /// @notice No binding exists for the (wearer, hat) pair.
    error NoBinding();

    /*═══════════════════════════════ EVENTS ═══════════════════════════════*/

    event Initialized(address indexed governor, address indexed verifier);
    event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event MeasurementAllowed(uint256 indexed hatId, bytes32 indexed measurement, bool allowed);
    event AttestationAccepted(
        uint256 indexed hatId, address indexed subject, bytes32 indexed measurement, uint64 expiry
    );
    event BindingRevoked(uint256 indexed hatId, address indexed subject);

    /*══════════════════════════════ STRUCTS ═══════════════════════════════*/

    /// @notice A wallet's attestation binding for one hat.
    struct Binding {
        bytes32 measurement; // enclave image the wallet attested to
        uint64 expiry; // attestation freshness cutoff (unix)
        bool active; // false once revoked
    }

    /*══════════════════════════════ STORAGE ═══════════════════════════════*/

    /// @custom:storage-location erc7201:poa.teeagenteligibility.storage
    struct Layout {
        /// @notice Governance address (the org Executor) that manages measurements.
        address governor;
        /// @notice The attestation verifier (swappable for a stronger one).
        ITEEAttestationVerifier verifier;
        /// @notice hatId => measurement => allowed.
        mapping(uint256 => mapping(bytes32 => bool)) allowedMeasurement;
        /// @notice wearer => hatId => binding.
        mapping(address => mapping(uint256 => Binding)) bindings;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.teeagenteligibility.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*═════════════════════════════ MODIFIERS ══════════════════════════════*/

    modifier onlyGovernor() {
        if (msg.sender != _layout().governor) revert NotGovernor();
        _;
    }

    /*═══════════════════════════════ INIT ═════════════════════════════════*/

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the module.
     * @param governor_ Governance address (typically the org Executor).
     * @param verifier_ Attestation verifier implementation.
     */
    function initialize(address governor_, address verifier_) external initializer {
        if (governor_ == address(0) || verifier_ == address(0)) revert ZeroAddress();
        Layout storage l = _layout();
        l.governor = governor_;
        l.verifier = ITEEAttestationVerifier(verifier_);
        emit Initialized(governor_, verifier_);
    }

    /*═══════════════════════════ GOVERNANCE ═══════════════════════════════*/

    /// @notice Transfer governance to a new address.
    function transferGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        address old = _layout().governor;
        _layout().governor = newGovernor;
        emit GovernorTransferred(old, newGovernor);
    }

    /// @notice Swap the attestation verifier (e.g. notary → on-chain DCAP).
    function setVerifier(address newVerifier) external onlyGovernor {
        if (newVerifier == address(0)) revert ZeroAddress();
        address old = address(_layout().verifier);
        _layout().verifier = ITEEAttestationVerifier(newVerifier);
        emit VerifierUpdated(old, newVerifier);
    }

    /**
     * @notice Allow or disallow an enclave `measurement` to wear `hatId`.
     * @dev This is the governance lever that makes an agent-code upgrade a
     *      governance action. Disallowing a measurement instantly removes
     *      eligibility from every wallet attested to it.
     */
    function setMeasurementAllowed(uint256 hatId, bytes32 measurement, bool allowed) external onlyGovernor {
        _layout().allowedMeasurement[hatId][measurement] = allowed;
        emit MeasurementAllowed(hatId, measurement, allowed);
    }

    /**
     * @notice Emergency: revoke a specific wallet's binding for a hat, without
     *         disallowing the whole measurement.
     */
    function revokeBinding(address wearer, uint256 hatId) external onlyGovernor {
        Binding storage b = _layout().bindings[wearer][hatId];
        if (!b.active) revert NoBinding();
        b.active = false;
        emit BindingRevoked(hatId, wearer);
    }

    /*═══════════════════════════ ATTESTATION ══════════════════════════════*/

    /**
     * @notice Submit an attestation binding a wallet to `hatId`. Permissionless:
     *         the verifier authenticates the attestation, so anyone (typically
     *         the agent itself) may relay it.
     * @param hatId       The hat the subject wants to become eligible for.
     * @param attestation Opaque attestation blob understood by the verifier.
     * @return subject     The bound wallet.
     * @return measurement The attested enclave measurement.
     */
    function submitAttestation(uint256 hatId, bytes calldata attestation)
        external
        returns (address subject, bytes32 measurement)
    {
        Layout storage l = _layout();
        uint64 expiry;
        (subject, measurement, expiry) = l.verifier.verifyAttestation(attestation);

        if (subject == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert AttestationExpired();
        if (!l.allowedMeasurement[hatId][measurement]) revert MeasurementNotAllowed();

        l.bindings[subject][hatId] = Binding({measurement: measurement, expiry: expiry, active: true});
        emit AttestationAccepted(hatId, subject, measurement, expiry);
    }

    /*═══════════════════════ ELIGIBILITY INTERFACE ════════════════════════*/

    /**
     * @inheritdoc IHatsEligibility
     * @dev Eligible iff the wearer has an active, unexpired binding whose
     *      measurement is *still* allowed for the hat. All three conditions are
     *      checked live, so revoking the measurement, expiry lapsing, or an
     *      explicit revocation each drop eligibility immediately.
     */
    function getWearerStatus(address _wearer, uint256 _hatId)
        external
        view
        override
        returns (bool eligible, bool standing)
    {
        Layout storage l = _layout();
        Binding storage b = l.bindings[_wearer][_hatId];
        eligible = b.active && b.expiry > block.timestamp && l.allowedMeasurement[_hatId][b.measurement];
        // Standing tracks eligibility here; a bad-standing wearer is simply not eligible.
        standing = eligible;
    }

    /*════════════════════════════ VIEWS ═══════════════════════════════════*/

    /// @notice Current governor.
    function governor() external view returns (address) {
        return _layout().governor;
    }

    /// @notice Current verifier.
    function verifier() external view returns (address) {
        return address(_layout().verifier);
    }

    /// @notice Whether `measurement` may wear `hatId`.
    function isMeasurementAllowed(uint256 hatId, bytes32 measurement) external view returns (bool) {
        return _layout().allowedMeasurement[hatId][measurement];
    }

    /// @notice The binding recorded for `wearer` on `hatId`.
    function bindingOf(address wearer, uint256 hatId)
        external
        view
        returns (bytes32 measurement, uint64 expiry, bool active)
    {
        Binding storage b = _layout().bindings[wearer][hatId];
        return (b.measurement, b.expiry, b.active);
    }
}
