// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

/*  OpenZeppelin v5.3 Upgradeables  */
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {IExecutor} from "./Executor.sol";
import {HatManager} from "./libs/HatManager.sol";
import {VotingMath} from "./libs/VotingMath.sol";
import {VotingErrors} from "./libs/VotingErrors.sol";
import {HybridVotingProposals} from "./libs/HybridVotingProposals.sol";
import {HybridVotingCore} from "./libs/HybridVotingCore.sol";
import {HybridVotingConfig} from "./libs/HybridVotingConfig.sol";

/* ─────────────────── HybridVoting ─────────────────── */
contract HybridVoting is Initializable {
    /* ─────── Constants ─────── */
    uint8 public constant MAX_OPTIONS = 50;
    uint8 public constant MAX_CALLS = 20;
    uint8 public constant MAX_CLASSES = 8;
    uint32 public constant MAX_DURATION = 43_200; /* 30 days */
    uint32 public constant MIN_DURATION = 1; /* 1 min for testing */

    /* ─────── Data Structures ─────── */

    enum ClassStrategy {
        DIRECT, // 1 person → 100 raw points
        ERC20_BAL // balance (or sqrt) scaled
    }

    struct ClassConfig {
        ClassStrategy strategy; // DIRECT / ERC20_BAL
        uint8 slicePct; // 1..100; all classes must sum to 100
        bool quadratic; // only for token strategies
        uint256 minBalance; // sybil floor for token strategies
        address asset; // ERC20 token (if required)
        uint256 hatId; // capability hat for this class (0 = unrestricted)
    }

    struct PollOption {
        uint128[] classRaw; // length = classesSnapshot.length
    }

    struct Proposal {
        uint64 endTimestamp;
        uint256[] classTotalsRaw; // Σ raw from each class (len = classesSnapshot.length)
        PollOption[] options; // each option has classRaw[i]
        mapping(address => bool) hasVoted;
        IExecutor.Call[][] batches;
        uint256[] pollHatIds; // array of specific hat IDs for this poll
        bool restricted; // if true only pollHatIds can vote
        mapping(uint256 => bool) pollHatAllowed; // O(1) lookup for poll hat permission
        ClassConfig[] classesSnapshot; // Snapshot the class config to freeze semantics for this proposal
        bool executed; // finalization guard
        uint32 voterCount; // number of voters who cast a vote
    }

    /* ─────── ERC-7201 Storage ─────── */
    /// @custom:storage-location erc7201:poa.hybridvoting.v2.storage
    struct Layout {
        /* Config / Storage */
        IHats hats;
        IExecutor executor;
        mapping(address => bool) allowedTarget; // deprecated: kept for storage layout compatibility
        uint256[] creatorHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        uint8 thresholdPct; // 1‑100  (min % of support for winning option)
        ClassConfig[] classes; // global N-class configuration
        /* Vote Bookkeeping */
        Proposal[] _proposals;
        /* Inline State */
        bool _paused; // Inline pausable state
        uint256 _lock; // Inline reentrancy guard state
        uint32 quorum; // minimum number of voters required (0 = disabled)
        /* Hats-native capability hat */
        uint256 proposalCreatorHat; // capability hat gating createProposal
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.hybridvoting.v2.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /* ─────────── Inline Context Implementation ─────────── */
    function _msgSender() internal view returns (address addr) {
        assembly {
            addr := caller()
        }
    }

    /* ─────────── Inline Pausable Implementation ─────────── */
    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    function _checkNotPaused() private view {
        if (_layout()._paused) revert VotingErrors.Paused();
    }

    function paused() external view returns (bool) {
        return _layout()._paused;
    }

    function _pause() internal {
        _layout()._paused = true;
    }

    function _unpause() internal {
        _layout()._paused = false;
    }

    /* ─────── Events ─────── */
    event HatSet(HatType hatType, uint256 hat, bool allowed);
    event ExecutorUpdated(address newExec);
    event ThresholdPctSet(uint8 pct);
    event QuorumSet(uint32 quorum);

    /* ─────── Initialiser ─────── */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param hats_ Hats Protocol address
    /// @param executor_ Org's Executor address
    /// @param proposalCreatorHat_ Capability hat gating createProposal
    /// @param initialTargets DEPRECATED: kept for ABI compatibility; HybridVoting passes batches
    ///        directly to Executor without target restrictions.
    /// @param thresholdPct_ Threshold percentage (1-100)
    /// @param initialClasses Initial N-class config (each class has a single capability hat)
    function initialize(
        address hats_,
        address executor_,
        uint256 proposalCreatorHat_,
        address[] calldata initialTargets,
        uint8 thresholdPct_,
        ClassConfig[] calldata initialClasses
    ) external initializer {
        if (hats_ == address(0) || executor_ == address(0)) {
            revert VotingErrors.ZeroAddress();
        }

        VotingMath.validateThreshold(thresholdPct_);

        Layout storage l = _layout();
        l.hats = IHats(hats_);
        l.executor = IExecutor(executor_);
        l._paused = false; // Initialize paused state
        l._lock = 0; // Initialize reentrancy guard state

        l.thresholdPct = thresholdPct_;
        l.proposalCreatorHat = proposalCreatorHat_;
        emit ThresholdPctSet(thresholdPct_);
        emit HatSet(HatType.CREATOR, proposalCreatorHat_, true);

        // initialTargets parameter kept for ABI compatibility but not used;
        // HybridVoting passes batches directly to Executor without target restrictions.

        // Use library for class initialization
        HybridVotingConfig.validateAndInitClasses(initialClasses);
    }

    /* ─────── Governance setters (executor‑gated) ─────── */
    modifier onlyExecutor() {
        _checkExecutor();
        _;
    }

    function _checkExecutor() private view {
        if (_msgSender() != address(_layout().executor)) revert VotingErrors.Unauthorized();
    }

    function pause() external onlyExecutor {
        _pause();
    }

    function unpause() external onlyExecutor {
        _unpause();
    }

    /* ─────── Hat Management ─────── */
    function setProposalCreatorHat(uint256 h) external onlyExecutor {
        _layout().proposalCreatorHat = h;
        emit HatSet(HatType.CREATOR, h, true);
    }

    enum HatType {
        CREATOR
    }

    /* ─────── N-Class Configuration ─────── */
    function setClasses(ClassConfig[] calldata newClasses) external onlyExecutor {
        HybridVotingConfig.setClasses(newClasses);
    }

    function getClasses() external view returns (ClassConfig[] memory) {
        return _layout().classes;
    }

    function getProposalClasses(uint256 id) external view exists(id) returns (ClassConfig[] memory) {
        return _layout()._proposals[id].classesSnapshot;
    }

    /* ─────── Configuration Setters ─────── */
    enum ConfigKey {
        THRESHOLD,
        TARGET_ALLOWED, // deprecated: kept for enum ordering compatibility
        EXECUTOR,
        QUORUM
    }

    function setConfig(ConfigKey key, bytes calldata value) external onlyExecutor {
        Layout storage l = _layout();

        if (key == ConfigKey.THRESHOLD) {
            uint8 q = abi.decode(value, (uint8));
            VotingMath.validateThreshold(q);
            l.thresholdPct = q;
            emit ThresholdPctSet(q);
        } else if (key == ConfigKey.EXECUTOR) {
            address newExecutor = abi.decode(value, (address));
            if (newExecutor == address(0)) revert VotingErrors.ZeroAddress();
            l.executor = IExecutor(newExecutor);
            emit ExecutorUpdated(newExecutor);
        } else if (key == ConfigKey.QUORUM) {
            uint32 q = abi.decode(value, (uint32));
            l.quorum = q;
            emit QuorumSet(q);
        }
    }

    /* ─────── Helpers & modifiers ─────── */
    modifier onlyCreator() {
        _checkCreator();
        _;
    }

    modifier exists(uint256 id) {
        _checkExists(id);
        _;
    }

    modifier isExpired(uint256 id) {
        _checkExpired(id);
        _;
    }

    function _checkCreator() private view {
        Layout storage l = _layout();
        if (_msgSender() != address(l.executor)) {
            if (!l.hats.isWearerOfHat(_msgSender(), l.proposalCreatorHat)) revert VotingErrors.Unauthorized();
        }
    }

    function _checkExists(uint256 id) private view {
        if (id >= _layout()._proposals.length) revert VotingErrors.InvalidProposal();
    }

    function _checkExpired(uint256 id) private view {
        if (block.timestamp <= _layout()._proposals[id].endTimestamp) revert VotingErrors.VotingOpen();
    }

    /* ─────── Proposal creation ─────── */
    function createProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds
    ) external onlyCreator whenNotPaused {
        HybridVotingProposals.createProposal(title, descriptionHash, minutesDuration, numOptions, batches, hatIds);
    }

    /* ─────── Voting ─────── */
    function vote(uint256 id, uint8[] calldata idxs, uint8[] calldata weights) external exists(id) whenNotPaused {
        HybridVotingCore.vote(id, idxs, weights);
    }

    /* ─────── Winner & execution ─────── */
    function announceWinner(uint256 id)
        external
        exists(id)
        isExpired(id)
        whenNotPaused
        returns (uint256 winner, bool valid)
    {
        return HybridVotingCore.announceWinner(id);
    }

    /* ─────── Targeted View Functions ─────── */
    function proposalsCount() external view returns (uint256) {
        return _layout()._proposals.length;
    }

    function thresholdPct() external view returns (uint8) {
        return _layout().thresholdPct;
    }

    function quorum() external view returns (uint32) {
        return _layout().quorum;
    }

    /// @notice Backwards-compat: returns single-element array with proposalCreatorHat.
    function creatorHats() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().proposalCreatorHat;
    }

    function proposalCreatorHat() external view returns (uint256) {
        return _layout().proposalCreatorHat;
    }

    function pollRestricted(uint256 id) external view exists(id) returns (bool) {
        return _layout()._proposals[id].restricted;
    }

    function pollHatAllowed(uint256 id, uint256 hat) external view exists(id) returns (bool) {
        return _layout()._proposals[id].pollHatAllowed[hat];
    }

    function executor() external view returns (address) {
        return address(_layout().executor);
    }

    function hats() external view returns (address) {
        return address(_layout().hats);
    }
}
