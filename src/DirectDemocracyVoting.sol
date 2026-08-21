// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/* ──────────────────  OpenZeppelin v5.3 Upgradeables  ────────────────── */
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {IExecutor} from "./Executor.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {VotingMath} from "./libs/VotingMath.sol";
import {VotingErrors} from "./libs/VotingErrors.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";
import {IMembershipAuthority} from "./interfaces/IMembershipAuthority.sol";
import {AccessV2PermKeys} from "./libs/AccessV2PermKeys.sol";

/* ──────────────────  Direct‑democracy governor  ─────────────────────── */
contract DirectDemocracyVoting is Initializable {
    /* ─────────── Constants ─────────── */
    bytes4 public constant MODULE_ID = 0x6464766f; /* "ddvo"  */
    uint8 public constant MAX_OPTIONS = 50;
    uint8 public constant MAX_CALLS = 20;
    // M-14: cap the number of poll-specific hats a proposal can carry. The vote() path scans
    // p.pollHatIds linearly (and _initProposal writes them), so an unbounded array is a
    // gas-griefing vector — a proposal could be created with thousands of hats, making every
    // restricted vote() call unaffordable. Bounds the existing scan; vote() ABI is unchanged.
    uint16 public constant MAX_POLL_HATS = 100;
    uint32 public constant MAX_DURATION_MIN = 43_200; /* 30 days */
    uint32 public constant MIN_DURATION_MIN = 1; /* 1 min for testing */

    enum HatType {
        VOTING,
        CREATOR
    }

    enum ConfigKey {
        THRESHOLD,
        EXECUTOR,
        TARGET_ALLOWED,
        HAT_ALLOWED,
        QUORUM
    }

    /* ─────────── Data Structures ─────────── */
    struct PollOption {
        uint96 votes;
    }

    struct Proposal {
        uint128 totalWeight; // voters × 100
        uint64 endTimestamp;
        PollOption[] options;
        mapping(address => bool) hasVoted;
        IExecutor.Call[][] batches; // per‑option execution
        uint256[] pollHatIds; // array of specific hat IDs for this poll
        bool restricted; // if true only allowedHats can vote
        mapping(uint256 => bool) pollHatAllowed; // O(1) lookup for poll hat permission
        bool executed; // finalization guard
    }

    /* ─────────── ERC-7201 Storage ─────────── */
    /// @custom:storage-location erc7201:poa.directdemocracy.storage
    struct Layout {
        IHats hats;
        IExecutor executor;
        mapping(address => bool) allowedTarget; // execution allow‑list
        uint256[] votingHatIds; // Array of voting hat IDs
        uint256[] creatorHatIds; // Array of creator hat IDs
        uint8 thresholdPct; // 1‑100  (min % of support for winning option)
        Proposal[] _proposals;
        bool _paused; // Inline pausable state
        uint256 _lock; // Inline reentrancy guard state
        uint32 quorum; // minimum number of voters required (0 = disabled)
        // ─── RoleManager Phase 2 (V2) append-only tail ───
        // Per-proposal quorum override lives in a SIDE mapping keyed by proposalId — NEVER a field
        // on the Proposal struct (it lives in a storage array; widening its stride corrupts every
        // existing proposal). 0 = no override (V1 proposals + V2 proposals that pass 0).
        mapping(uint256 => uint32) proposalQuorumOverride;
        // Scoped secondary admin (RoleManager) allowed to toggle voting/creator hats via
        // setConfig(HAT_ALLOWED) — every other ConfigKey stays executor-only. 0 = none.
        address configAdmin;
        // ─── Access v2 (MembershipAuthority) DUAL-PATH append-only tail ───
        // When 0, every permission read uses the LEGACY Hats path byte-identically (unmigrated org /
        // rollback target). When set, creator/voter checks route to the authority per the frozen key
        // shapes (DD_CREATE / DD_VOTE) and the electorate ACTIVATION GATE (activeMemberSince) engages.
        address membershipAuthority;
        // Per-proposal creation timestamp — the anti-packing anchor for the authority-path activation
        // gate. Stored in a SIDE mapping keyed by proposalId (NEVER a field on the Proposal struct,
        // which lives in a storage array; widening its stride corrupts every existing proposal).
        // Legacy reads never consult it, so the legacy path stays byte-identical.
        mapping(uint256 => uint64) proposalCreatedAt;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.directdemocracy.storage");

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
        require(!_layout()._paused, "Pausable: paused");
        _;
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

    /* ─────────── Inline ReentrancyGuard Implementation ─────────── */
    modifier nonReentrant() {
        require(_layout()._lock == 0, "ReentrancyGuard: reentrant call");
        _layout()._lock = 1;
        _;
        _layout()._lock = 0;
    }

    /* ─────────── Events ─────────── */
    event HatSet(HatType hatType, uint256 hat, bool allowed);
    event CreatorHatSet(uint256 hat, bool allowed);
    event NewProposal(uint256 id, bytes title, bytes32 descriptionHash, uint8 numOptions, uint64 endTs, uint64 created);
    event NewHatProposal(
        uint256 id,
        bytes title,
        bytes32 descriptionHash,
        uint8 numOptions,
        uint64 endTs,
        uint64 created,
        uint256[] hatIds
    );
    event VoteCast(uint256 id, address voter, uint8[] idxs, uint8[] weights);
    event Winner(uint256 id, uint256 winningIdx, bool valid);
    event ProposalExecutionFailed(uint256 indexed id, uint256 indexed winningIdx, bytes reason);
    event ExecutorUpdated(address newExecutor);
    event TargetAllowed(address target, bool allowed);
    event ProposalCleaned(uint256 id, uint256 cleaned);
    event ThresholdPctSet(uint8 pct);
    event QuorumSet(uint32 quorum);
    // V2 (RoleManager Phase 2): additive event carrying per-proposal config that is NOT present on
    // the legacy NewProposal/NewHatProposal ABIs. `equalWeight` is always false on DD (HV-only knob);
    // the field is kept for a uniform cross-module event shape the subgraph can index.
    event ProposalConfigV2(uint256 indexed id, uint32 quorumOverride, bool equalWeight);
    event ConfigAdminSet(address indexed admin);
    // Access v2: dual-path repoint. `address(0)` restores the legacy Hats path (rollback, §6).
    event MembershipAuthoritySet(address indexed authority);

    /* ─────────── Initialiser ─────────── */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address hats_,
        address executor_,
        uint256[] calldata initialHats,
        uint256[] calldata initialCreatorHats,
        address[] calldata initialTargets,
        uint8 thresholdPct_,
        uint32 quorum_
    ) external initializer {
        if (hats_ == address(0) || executor_ == address(0)) {
            revert VotingErrors.ZeroAddress();
        }
        VotingMath.validateThreshold(thresholdPct_);

        Layout storage l = _layout();
        l.hats = IHats(hats_);
        l.executor = IExecutor(executor_);
        l.thresholdPct = thresholdPct_;
        l._paused = false; // Initialize paused state
        l._lock = 0; // Initialize reentrancy guard state
        emit ThresholdPctSet(thresholdPct_);

        // Deploy-time voter-count quorum (0 = disabled). Mirrors setConfig(QUORUM) — the
        // event is emitted here too so the subgraph indexes the genesis value from logs.
        l.quorum = quorum_;
        emit QuorumSet(quorum_);

        uint256 len = initialHats.length;
        for (uint256 i; i < len;) {
            HatManager.setHatInArray(l.votingHatIds, initialHats[i], true);
            unchecked {
                ++i;
            }
        }
        len = initialCreatorHats.length;
        for (uint256 i; i < len;) {
            HatManager.setHatInArray(l.creatorHatIds, initialCreatorHats[i], true);
            unchecked {
                ++i;
            }
        }
        len = initialTargets.length;
        for (uint256 i; i < len;) {
            l.allowedTarget[initialTargets[i]] = true;
            emit TargetAllowed(initialTargets[i], true);
            unchecked {
                ++i;
            }
        }
    }

    /* ─────────── Admin (executor‑gated) ─────────── */
    modifier onlyExecutor() {
        if (_msgSender() != address(_layout().executor)) revert VotingErrors.Unauthorized();
        _;
    }

    function pause() external onlyExecutor {
        _pause();
    }

    function unpause() external onlyExecutor {
        _unpause();
    }

    /// @notice Set the scoped config admin (RoleManager) permitted to toggle voting/creator hats.
    /// @dev Executor-only. Every ConfigKey other than HAT_ALLOWED stays executor-only regardless.
    function setConfigAdmin(address admin) external onlyExecutor {
        _layout().configAdmin = admin;
        emit ConfigAdminSet(admin);
    }

    /// @notice Repoint this module to the org's MembershipAuthority (Access v2). `address(0)` restores
    ///         the legacy Hats path (rollback, §6). AUTH: onlyExecutor. Emits MembershipAuthoritySet.
    /// @dev DUAL-PATH INVARIANT: while `membershipAuthority == address(0)` every creator/voter check
    ///      reads the legacy `votingHatIds`/`creatorHatIds` arrays byte-identically; once set, the
    ///      checks route to `hasPerm(DD_CREATE)` / the `activeMemberSince(DD_VOTE)` electorate gate.
    function setMembershipAuthority(address authority) external onlyExecutor {
        _layout().membershipAuthority = authority;
        emit MembershipAuthoritySet(authority);
    }

    function setConfig(ConfigKey key, bytes calldata value) external {
        Layout storage l = _layout();
        // HAT_ALLOWED (voting/creator hat wiring) accepts executor OR configAdmin (RoleManager);
        // every other key is executor-only — matches the frozen auth surface (auth-surfaces §1).
        if (key == ConfigKey.HAT_ALLOWED) {
            if (_msgSender() != address(l.executor) && _msgSender() != l.configAdmin) {
                revert VotingErrors.Unauthorized();
            }
        } else if (_msgSender() != address(l.executor)) {
            revert VotingErrors.Unauthorized();
        }
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
        } else if (key == ConfigKey.TARGET_ALLOWED) {
            (address target, bool allowed) = abi.decode(value, (address, bool));
            l.allowedTarget[target] = allowed;
            emit TargetAllowed(target, allowed);
        } else if (key == ConfigKey.HAT_ALLOWED) {
            (HatType hatType, uint256 hat, bool allowed) = abi.decode(value, (HatType, uint256, bool));
            if (hatType == HatType.VOTING) {
                HatManager.setHatInArray(l.votingHatIds, hat, allowed);
            } else if (hatType == HatType.CREATOR) {
                HatManager.setHatInArray(l.creatorHatIds, hat, allowed);
            }
            emit HatSet(hatType, hat, allowed);
        } else if (key == ConfigKey.QUORUM) {
            uint32 q = abi.decode(value, (uint32));
            l.quorum = q;
            emit QuorumSet(q);
        }
    }

    /* ─────────── Modifiers ─────────── */
    modifier onlyCreator() {
        Layout storage l = _layout();
        if (_msgSender() != address(l.executor)) {
            address a = l.membershipAuthority;
            bool canCreate = a == address(0)
                ? HatManager.hasAnyHat(l.hats, l.creatorHatIds, _msgSender())
                : IMembershipAuthority(a).hasPerm(_msgSender(), AccessV2PermKeys.DD_CREATE, bytes32(0)) != 0;
            if (!canCreate) revert VotingErrors.Unauthorized();
        }
        _;
    }

    modifier exists(uint256 id) {
        if (id >= _layout()._proposals.length) revert VotingErrors.InvalidProposal();
        _;
    }

    modifier notExpired(uint256 id) {
        if (block.timestamp > _layout()._proposals[id].endTimestamp) revert VotingErrors.VotingExpired();
        _;
    }

    modifier isExpired(uint256 id) {
        if (block.timestamp <= _layout()._proposals[id].endTimestamp) revert VotingErrors.VotingOpen();
        _;
    }

    /* ─────── Internal Helper Functions ─────── */
    function _validateDuration(uint32 minutesDuration) internal pure {
        if (minutesDuration < MIN_DURATION_MIN || minutesDuration > MAX_DURATION_MIN) {
            revert VotingErrors.DurationOutOfRange();
        }
    }

    function _validateTargets(IExecutor.Call[] calldata batch, Layout storage l) internal view {
        uint256 batchLen = batch.length;
        if (batchLen > MAX_CALLS) revert VotingErrors.TooManyCalls();
        for (uint256 j; j < batchLen;) {
            // No self-target guard: changing DDV's own onlyExecutor config via a proposal is the
            // intended governance path. Self-targeting still requires the org to explicitly
            // allow-list address(this) below, so it stays an opt-in, deliberate action.
            if (!l.allowedTarget[batch[j].target]) revert VotingErrors.TargetNotAllowed();
            unchecked {
                ++j;
            }
        }
    }

    function _initProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds
    ) internal returns (uint256) {
        ValidationLib.requireValidTitle(title);
        if (numOptions == 0) revert VotingErrors.LengthMismatch();
        if (numOptions > MAX_OPTIONS) revert VotingErrors.TooManyOptions();
        _validateDuration(minutesDuration);

        Layout storage l = _layout();

        bool isExecuting = false;
        if (batches.length > 0) {
            if (numOptions != batches.length) revert VotingErrors.LengthMismatch();
            for (uint256 i; i < numOptions;) {
                if (batches[i].length > 0) {
                    isExecuting = true;
                    _validateTargets(batches[i], l);
                }
                unchecked {
                    ++i;
                }
            }
        }

        uint64 endTs = uint64(block.timestamp + minutesDuration * 60);
        Proposal storage p = l._proposals.push();
        p.endTimestamp = endTs;
        p.restricted = hatIds.length > 0;

        uint256 id = l._proposals.length - 1;
        // Anchor the authority-path activation gate to creation time (§4 anti-packing). Behaviour-
        // neutral for the legacy path, which never reads it; the Proposal struct is left untouched.
        l.proposalCreatedAt[id] = uint64(block.timestamp);

        for (uint256 i; i < numOptions;) {
            p.options.push(PollOption(0));
            unchecked {
                ++i;
            }
        }

        if (isExecuting) {
            for (uint256 i; i < numOptions;) {
                p.batches.push(batches[i]);
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < numOptions;) {
                p.batches.push();
                unchecked {
                    ++i;
                }
            }
        }

        if (hatIds.length > 0) {
            uint256 hatLen = hatIds.length;
            if (hatLen > MAX_POLL_HATS) revert VotingErrors.TooManyPollHats(); // M-14
            for (uint256 i; i < hatLen;) {
                p.pollHatIds.push(hatIds[i]);
                p.pollHatAllowed[hatIds[i]] = true;
                unchecked {
                    ++i;
                }
            }
        }

        return id;
    }

    /* ────────── Proposal Creation ────────── */
    function createProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds
    ) external onlyCreator whenNotPaused {
        uint256 id = _initProposal(title, descriptionHash, minutesDuration, numOptions, batches, hatIds);

        uint64 endTs = _layout()._proposals[id].endTimestamp;

        if (hatIds.length > 0) {
            emit NewHatProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp), hatIds);
        } else {
            emit NewProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp));
        }
    }

    /// @notice Create a proposal with a per-proposal quorum override (additive to createProposal).
    /// @dev The legacy createProposal selector/behaviour is untouched. Rules (PLAN §1.5, H-2):
    ///      - `quorumOverride` is only allowed on RESTRICTED polls (`hatIds.length > 0`); an
    ///        unrestricted proposal MUST pass 0 or it reverts (InvalidQuorum).
    ///      - Executable proposals (any non-empty batch) can only RAISE quorum: the effective
    ///        quorum is `max(globalQuorum, override)` — a captured micro-electorate cannot lower
    ///        the bar and push through an arbitrary Executor batch.
    ///      - Non-executable signal polls may LOWER quorum: effective quorum = override.
    ///      The override is stored in a side mapping keyed by proposalId and read at winner calc.
    function createProposalV2(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds,
        uint32 quorumOverride
    ) external onlyCreator whenNotPaused {
        if (hatIds.length == 0 && quorumOverride != 0) revert VotingErrors.InvalidQuorum();

        uint256 id = _initProposal(title, descriptionHash, minutesDuration, numOptions, batches, hatIds);

        Layout storage l = _layout();
        if (quorumOverride != 0) {
            l.proposalQuorumOverride[id] = quorumOverride;
        }

        uint64 endTs = l._proposals[id].endTimestamp;
        if (hatIds.length > 0) {
            emit NewHatProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp), hatIds);
        } else {
            emit NewProposal(id, title, descriptionHash, numOptions, endTs, uint64(block.timestamp));
        }
        emit ProposalConfigV2(id, quorumOverride, false);
    }

    /* ─────────── Voting ─────────── */
    function vote(uint256 id, uint8[] calldata idxs, uint8[] calldata weights)
        external
        exists(id)
        notExpired(id)
        whenNotPaused
    {
        if (idxs.length != weights.length) revert VotingErrors.LengthMismatch();
        Layout storage l = _layout();
        address a = l.membershipAuthority;
        // Authority-path activation anchor: a voter is only eligible if they were an active member
        // AT OR BEFORE proposal creation (closes every instant-add / mid-proposal-packing channel at
        // the READ side, §4 electorate gate). Unused on the legacy path.
        uint64 createdAt = l.proposalCreatedAt[id];
        if (_msgSender() != address(l.executor)) {
            bool canVote = a == address(0)
                ? HatManager.hasAnyHat(l.hats, l.votingHatIds, _msgSender())
                : IMembershipAuthority(a).activeMemberSince(_msgSender(), AccessV2PermKeys.DD_VOTE, bytes32(0))
                    <= createdAt;
            if (!canVote) revert VotingErrors.Unauthorized();
        }
        Proposal storage p = l._proposals[id];
        if (p.restricted) {
            bool hasAllowedHat = false;
            // Per-poll subject list: `pollHatIds` are opaque uint256 ids — Hats ids on the legacy path,
            // adopted-verbatim subject ids on the authority path. The existing pollHatIds machinery is
            // id-agnostic (stores/scans raw uint256), so the same array carries subject ids unchanged;
            // "Only Executives" is simply `[executivesGroupId]`. The authority arm additionally gates
            // each subject on the activation anchor (activeMemberSince <= createdAt).
            uint256 pollHatLen = p.pollHatIds.length;
            for (uint256 i = 0; i < pollHatLen;) {
                bool ok = a == address(0)
                    ? l.hats.isWearerOfHat(_msgSender(), p.pollHatIds[i])
                    : IMembershipAuthority(a).activeMemberSince(p.pollHatIds[i], _msgSender()) <= createdAt;
                if (ok) {
                    hasAllowedHat = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }
            if (!hasAllowedHat) revert VotingErrors.RoleNotAllowed();
        }
        if (p.hasVoted[_msgSender()]) revert VotingErrors.AlreadyVoted();

        // Use VotingMath for weight validation
        VotingMath.validateWeights(VotingMath.Weights({idxs: idxs, weights: weights, optionsLen: p.options.length}));

        p.hasVoted[_msgSender()] = true;
        unchecked {
            p.totalWeight += 100;
        }

        uint256 len = idxs.length;
        for (uint256 i; i < len;) {
            unchecked {
                p.options[idxs[i]].votes += uint96(weights[i]);
                ++i;
            }
        }
        emit VoteCast(id, _msgSender(), idxs, weights);
    }

    /* ─────────── Finalise & Execute ─────────── */
    function announceWinner(uint256 id)
        external
        nonReentrant
        exists(id)
        isExpired(id)
        whenNotPaused
        returns (uint256 winner, bool valid)
    {
        Layout storage l = _layout();
        Proposal storage prop = l._proposals[id];
        if (prop.executed) revert VotingErrors.AlreadyExecuted();

        (winner, valid) = _calcWinner(id);
        IExecutor.Call[] storage batch = prop.batches[winner];

        // H-05 (issue #140): only mark the proposal executed once there is nothing left to run
        // OR the winning batch has actually executed. Setting `executed` up-front (the old
        // behaviour) meant a transiently-reverting batch permanently bricked the proposal — the
        // AlreadyExecuted guard blocked every retry even though nothing ran. Now a reverting
        // execution leaves `executed == false` so the finalize can be re-attempted once the
        // revert cause is fixed. The `nonReentrant` modifier (not `executed`) guards reentrancy.
        if (valid && batch.length > 0) {
            uint256 len = batch.length;
            for (uint256 i; i < len;) {
                // No self-target guard (see _validateTargets) — self-amendment is intended and
                // still gated by the allowedTarget allow-list below.
                if (!l.allowedTarget[batch[i].target]) revert VotingErrors.TargetNotAllowed();
                unchecked {
                    ++i;
                }
            }
            try l.executor.execute(id, batch) {
                prop.executed = true;
            } catch (bytes memory reason) {
                // Leave prop.executed == false so the finalize stays retryable (H-05).
                emit ProposalExecutionFailed(id, winner, reason);
            }
        } else {
            // Nothing to execute (informational poll, no winner, or empty batch): finalization
            // is terminal, so mark executed to prevent duplicate Winner emissions.
            prop.executed = true;
        }
        emit Winner(id, winner, valid);
    }

    /* ─────────── View helpers ─────────── */
    /// @dev Effective voter-count quorum for a proposal, honouring any V2 override (H-2):
    ///      - no override (0) → global quorum (V1 path, byte-identical).
    ///      - override set + executable (any non-empty batch) → max(global, override) (raise-only).
    ///      - override set + non-executable poll → override (may lower for small-group signals).
    function _effectiveQuorum(Layout storage l, Proposal storage p, uint256 id) internal view returns (uint32) {
        uint32 ov = l.proposalQuorumOverride[id];
        if (ov == 0) return l.quorum;
        uint256 n = p.batches.length;
        for (uint256 i; i < n;) {
            if (p.batches[i].length > 0) {
                // executable: override can only raise the bar
                return ov > l.quorum ? ov : l.quorum;
            }
            unchecked {
                ++i;
            }
        }
        // non-executable signal poll: override replaces the global quorum
        return ov;
    }

    function _calcWinner(uint256 id) internal view returns (uint256 win, bool ok) {
        Layout storage l = _layout();
        Proposal storage p = l._proposals[id];

        // Check quorum: minimum number of voters required (V2 override honoured, raise-only for
        // executable proposals — see _effectiveQuorum).
        uint32 eq = _effectiveQuorum(l, p, id);
        if (eq > 0 && p.totalWeight / 100 < eq) {
            return (0, false);
        }

        // Build option scores array for VoteCalc
        uint256 len = p.options.length;
        uint256[] memory optionScores = new uint256[](len);
        for (uint256 i; i < len;) {
            optionScores[i] = p.options[i].votes;
            unchecked {
                ++i;
            }
        }

        // Use VotingMath to pick winner with strict majority requirement
        (win, ok,,) = VotingMath.pickWinnerMajority(
            optionScores,
            p.totalWeight,
            l.thresholdPct,
            true // requireStrictMajority
        );
    }

    /* ─────────── Targeted View Functions ─────────── */
    function proposalsCount() external view returns (uint256) {
        return _layout()._proposals.length;
    }

    function thresholdPct() external view returns (uint8) {
        return _layout().thresholdPct;
    }

    function quorum() external view returns (uint32) {
        return _layout().quorum;
    }

    function isTargetAllowed(address target) external view returns (bool) {
        return _layout().allowedTarget[target];
    }

    function executor() external view returns (address) {
        return address(_layout().executor);
    }

    function hats() external view returns (address) {
        return address(_layout().hats);
    }

    function votingHats() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().votingHatIds);
    }

    function creatorHats() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().creatorHatIds);
    }

    function votingHatCount() external view returns (uint256) {
        return HatManager.getHatCount(_layout().votingHatIds);
    }

    function creatorHatCount() external view returns (uint256) {
        return HatManager.getHatCount(_layout().creatorHatIds);
    }

    function pollRestricted(uint256 id) external view exists(id) returns (bool) {
        return _layout()._proposals[id].restricted;
    }

    /// @notice Unix timestamp at which voting on proposal `id` closes.
    /// @dev L-05 parity with HybridVoting: exposes the proposal end timestamp so the lens can
    ///      implement a real `isProposalActive` instead of a tautology.
    function proposalEndTimestamp(uint256 id) external view exists(id) returns (uint64) {
        return _layout()._proposals[id].endTimestamp;
    }

    function pollHatAllowed(uint256 id, uint256 hat) external view exists(id) returns (bool) {
        return _layout()._proposals[id].pollHatAllowed[hat];
    }

    /// @notice Per-proposal quorum override (0 = none / legacy proposal). See createProposalV2.
    function proposalQuorumOverride(uint256 id) external view exists(id) returns (uint32) {
        return _layout().proposalQuorumOverride[id];
    }

    /// @notice The scoped config admin (RoleManager) allowed to toggle voting/creator hats.
    function configAdmin() external view returns (address) {
        return _layout().configAdmin;
    }

    /// @notice The org's MembershipAuthority (Access v2). `address(0)` = legacy Hats path active.
    function membershipAuthority() external view returns (address) {
        return _layout().membershipAuthority;
    }

    /// @notice Proposal `id`'s creation timestamp — the authority-path activation-gate anchor.
    function proposalCreatedAt(uint256 id) external view exists(id) returns (uint64) {
        return _layout().proposalCreatedAt[id];
    }
}
