// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.30;

/*  OpenZeppelin v5.3 Upgradeables  */
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
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
    // M-14: mirror of HybridVotingProposals.MAX_POLL_HATS — the enforced cap lives in the lib
    // (_initProposal), this facade copy makes the bound discoverable via the public ABI. Keep
    // the two in sync.
    uint16 public constant MAX_POLL_HATS = 100;
    uint32 public constant MAX_DURATION = 43_200; /* 30 days */
    // L-04: reconciled to match the value ENFORCED in HybridVotingProposals._validateDuration
    // (the facade constant is informational only; enforcement lives in the lib). Both are now 10.
    uint32 public constant MIN_DURATION = 10; /* 10 min floor */

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
        uint256[] hatIds; // voter must wear ≥1 (union)
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
        uint256[] creatorHatIds; // enumeration array for creator hats
        uint8 thresholdPct; // 1‑100  (min % of support for winning option)
        ClassConfig[] classes; // global N-class configuration
        /* Vote Bookkeeping */
        Proposal[] _proposals;
        /* Inline State */
        bool _paused; // Inline pausable state
        uint256 _lock; // Inline reentrancy guard state
        uint32 quorum; // minimum number of voters required (0 = disabled)
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

    function initialize(
        address hats_,
        address executor_,
        uint256[] calldata initialCreatorHats,
        address[] calldata initialTargets,
        uint8 thresholdPct_,
        uint32 quorum_,
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
        emit ThresholdPctSet(thresholdPct_);

        // Deploy-time voter-count quorum (0 = disabled). Mirrors setConfig(QUORUM) — the
        // event is emitted here too so the subgraph indexes the genesis value from logs.
        l.quorum = quorum_;
        emit QuorumSet(quorum_);

        _initializeCreatorHats(initialCreatorHats);
        // initialTargets parameter kept for ABI compatibility but not used;
        // HybridVoting passes batches directly to Executor without target restrictions.

        // Use library for class initialization
        HybridVotingConfig.validateAndInitClasses(initialClasses);
    }

    function _initializeCreatorHats(uint256[] calldata creatorHats) internal {
        Layout storage l = _layout();
        uint256 len = creatorHats.length;
        for (uint256 i; i < len;) {
            HatManager.setHatInArray(l.creatorHatIds, creatorHats[i], true);
            unchecked {
                ++i;
            }
        }
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
    function setCreatorHatAllowed(uint256 h, bool ok) external onlyExecutor {
        Layout storage l = _layout();
        HatManager.setHatInArray(l.creatorHatIds, h, ok);
        emit HatSet(HatType.CREATOR, h, ok);
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
            bool canCreate = HatManager.hasAnyHat(l.hats, l.creatorHatIds, _msgSender());
            if (!canCreate) revert VotingErrors.Unauthorized();
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

    function creatorHats() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().creatorHatIds);
    }

    function pollRestricted(uint256 id) external view exists(id) returns (bool) {
        return _layout()._proposals[id].restricted;
    }

    /// @notice Unix timestamp at which voting on proposal `id` closes.
    /// @dev L-05: real end-timestamp getter that backs HybridVotingLens (previously the lens
    ///      returned 0 / a tautology because this value was not exposed).
    function proposalEndTimestamp(uint256 id) external view exists(id) returns (uint64) {
        return _layout()._proposals[id].endTimestamp;
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
