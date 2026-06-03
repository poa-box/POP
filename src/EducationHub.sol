// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────── OpenZeppelin v5.3 Upgradeables ────────*/
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*──────── External interfaces ────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";

interface IParticipationToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function setEducationHub(address eh) external;
}

/*────────────────── EducationHub ─────────────────*/
/// @title EducationHub – on‑chain learning modules that reward participation tokens
/// @notice Metadata is emitted in events as compressed bytes rather than stored on‑chain
contract EducationHub is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    /*────────── Constants ─────────*/
    bytes4 public constant MODULE_ID = 0x45445548; /* "EDUH" */

    /*────────── Errors ─────────*/
    error ZeroAddress();
    error InvalidPayout();
    error InvalidAnswer();
    error NotMember();
    error NotCreator();
    error NotExecutor();
    error ModuleExists();
    error ModuleUnknown();
    error AlreadyCompleted();

    /*────────── Types ─────────*/
    struct Module {
        bytes32 answerHash;
        uint128 payout;
        bool exists;
    }

    /*────────── ERC-7201 Storage ─────────*/
    /// @custom:storage-location erc7201:poa.educationhub.storage
    struct Layout {
        mapping(uint256 => Module) _modules;
        mapping(address => mapping(uint256 => uint256)) _progress;
        uint48 nextModuleId; // packed with executor address
        address executor; // 20 bytes + 6 bytes = 26 bytes (fits in one slot)
        IHats hats;
        IParticipationToken token;
        uint256[] creatorHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        uint256[] memberHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        // ─── Hats-native capability hats (one per gate) ───
        uint256 creatorHat; // capability hat for createModule/updateModule/removeModule
        uint256 memberHat; // capability hat for completeModule
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.educationhub.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*────────── Events ─────────*/
    event ModuleCreated(uint256 indexed id, bytes title, bytes32 contentHash, uint256 payout);
    event ModuleUpdated(uint256 indexed id, bytes title, bytes32 contentHash, uint256 payout);
    event ModuleRemoved(uint256 indexed id);
    event ModuleCompleted(uint256 indexed id, address indexed learner);
    event CreatorHatSet(uint256 indexed hatId, bool enabled);
    event MemberHatSet(uint256 indexed hatId, bool enabled);

    event ExecutorSet(address indexed newExecutor);
    event TokenSet(address indexed newToken);
    event HatsSet(address indexed newHats);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*────────── Initialiser ────────*/
    /// @param tokenAddr ParticipationToken address
    /// @param hatsAddr Hats Protocol address
    /// @param executorAddr Executor (governance) address
    /// @param creatorHat_ Capability hat ID gating createModule/updateModule/removeModule
    /// @param memberHat_ Capability hat ID gating completeModule
    function initialize(
        address tokenAddr,
        address hatsAddr,
        address executorAddr,
        uint256 creatorHat_,
        uint256 memberHat_
    ) external initializer {
        if (tokenAddr == address(0) || hatsAddr == address(0) || executorAddr == address(0)) {
            revert ZeroAddress();
        }

        __Context_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        Layout storage l = _layout();
        l.token = IParticipationToken(tokenAddr);
        l.hats = IHats(hatsAddr);
        l.executor = executorAddr;
        l.creatorHat = creatorHat_;
        l.memberHat = memberHat_;

        emit TokenSet(tokenAddr);
        emit HatsSet(hatsAddr);
        emit ExecutorSet(executorAddr);
        emit CreatorHatSet(creatorHat_, true);
        emit MemberHatSet(memberHat_, true);
    }

    /*────────── Hat Management ─────*/
    function setCreatorHat(uint256 h) external onlyExecutor {
        _layout().creatorHat = h;
        emit CreatorHatSet(h, true);
    }

    function setMemberHat(uint256 h) external onlyExecutor {
        _layout().memberHat = h;
        emit MemberHatSet(h, true);
    }

    /*────────── Modifiers ─────────*/
    modifier onlyMember() {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && !_hasMemberHat(_msgSender())) revert NotMember();
        _;
    }

    modifier onlyCreator() {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && !_hasCreatorHat(_msgSender())) revert NotCreator();
        _;
    }

    modifier onlyExecutor() {
        if (_msgSender() != _layout().executor) revert NotExecutor();
        _;
    }

    /*────────── DAO / Admin Setters ───────*/
    function setExecutor(address newExec) external {
        Layout storage l = _layout();
        if (newExec == address(0)) revert ZeroAddress();
        if (_msgSender() != l.executor) revert NotExecutor();
        l.executor = newExec;
        emit ExecutorSet(newExec);
    }

    function setToken(address newToken) external onlyExecutor {
        if (newToken == address(0)) revert ZeroAddress();
        _layout().token = IParticipationToken(newToken);
        emit TokenSet(newToken);
    }

    function setHats(address newHats) external onlyExecutor {
        if (newHats == address(0)) revert ZeroAddress();
        _layout().hats = IHats(newHats);
        emit HatsSet(newHats);
    }

    /*────────── Pause Control (executor) ───────*/
    function pause() external {
        if (_msgSender() != _layout().executor) revert NotExecutor();
        _pause();
    }

    function unpause() external {
        if (_msgSender() != _layout().executor) revert NotExecutor();
        _unpause();
    }

    /*────────── Module CRUD ────────*/
    function createModule(bytes calldata title, bytes32 contentHash, uint256 payout, uint8 correctAnswer)
        external
        onlyCreator
        whenNotPaused
    {
        ValidationLib.requireValidTitle(title);
        if (payout == 0 || payout > type(uint128).max) revert InvalidPayout();

        Layout storage l = _layout();
        uint48 id = l.nextModuleId;
        unchecked {
            ++l.nextModuleId;
        }

        l._modules[id] =
            Module({answerHash: keccak256(abi.encodePacked(id, correctAnswer)), payout: uint128(payout), exists: true});

        emit ModuleCreated(id, title, contentHash, payout);
    }

    function updateModule(uint256 id, bytes calldata newTitle, bytes32 newContentHash, uint256 newPayout)
        external
        onlyCreator
        whenNotPaused
    {
        Layout storage l = _layout();
        Module storage m = _module(l, id);
        ValidationLib.requireValidTitle(newTitle);
        if (newPayout == 0 || newPayout > type(uint128).max) revert InvalidPayout();

        m.payout = uint128(newPayout);
        emit ModuleUpdated(id, newTitle, newContentHash, newPayout);
    }

    function removeModule(uint256 id) external onlyCreator whenNotPaused {
        Layout storage l = _layout();
        _module(l, id); // existence check
        delete l._modules[id];
        emit ModuleRemoved(id);
    }

    /*────────── Learner path ───────*/
    function completeModule(uint256 id, uint8 answer) external nonReentrant onlyMember whenNotPaused {
        Layout storage l = _layout();
        Module storage m = _module(l, id);
        if (_isCompleted(l, _msgSender(), id)) revert AlreadyCompleted();
        if (keccak256(abi.encodePacked(uint48(id), answer)) != m.answerHash) revert InvalidAnswer();

        l.token.mint(_msgSender(), m.payout);
        _setCompleted(l, _msgSender(), id);

        emit ModuleCompleted(id, _msgSender());
    }

    /*────────── View helpers ───────*/
    function getModule(uint256 id) external view returns (uint256 payout, bool exists) {
        Layout storage l = _layout();
        Module storage m = _module(l, id);
        return (m.payout, m.exists);
    }

    function hasCompleted(address learner, uint256 id) external view returns (bool) {
        Layout storage l = _layout();
        return _isCompleted(l, learner, id);
    }

    /*────────── Internal utils ───────*/
    function _module(Layout storage l, uint256 id) internal view returns (Module storage m) {
        m = l._modules[id];
        if (!m.exists) revert ModuleUnknown();
    }

    function _isCompleted(Layout storage l, address user, uint256 id) internal view returns (bool) {
        uint256 word = id >> 8;
        uint256 bit = 1 << (id & 0xff);
        return l._progress[user][word] & bit != 0;
    }

    function _setCompleted(Layout storage l, address user, uint256 id) internal {
        uint256 word = id >> 8;
        uint256 bit = 1 << (id & 0xff);
        unchecked {
            l._progress[user][word] |= bit;
        }
    }

    /*────────── Internal Helper Functions ─────────── */
    /// @dev Returns true if `user` wears the creator capability hat.
    function _hasCreatorHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        return l.hats.isWearerOfHat(user, l.creatorHat);
    }

    /// @dev Returns true if `user` wears the member capability hat.
    function _hasMemberHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        return l.hats.isWearerOfHat(user, l.memberHat);
    }

    /*────────── Public getters for storage variables ─────────*/
    function nextModuleId() external view returns (uint256) {
        return _layout().nextModuleId;
    }

    /// @notice Capability hat IDs gating module creation. Returns a single-element array
    ///         for backwards compatibility with lens contracts and subgraph integrations.
    function creatorHatIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().creatorHat;
    }

    /// @notice Capability hat IDs gating module completion. Returns a single-element array
    ///         for backwards compatibility with lens contracts and subgraph integrations.
    function memberHatIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().memberHat;
    }

    function creatorHat() external view returns (uint256) {
        return _layout().creatorHat;
    }

    function memberHat() external view returns (uint256) {
        return _layout().memberHat;
    }

    function token() external view returns (IParticipationToken) {
        return _layout().token;
    }

    function hats() external view returns (IHats) {
        return _layout().hats;
    }

    function executor() external view returns (address) {
        return _layout().executor;
    }

    /*────────── Hat Management View Functions ─────────── */
    function creatorHatCount() external view returns (uint256) {
        return 1;
    }

    function memberHatCount() external view returns (uint256) {
        return 1;
    }

    function isCreatorHat(uint256 hatId) external view returns (bool) {
        return hatId != 0 && hatId == _layout().creatorHat;
    }

    function isMemberHat(uint256 hatId) external view returns (bool) {
        return hatId != 0 && hatId == _layout().memberHat;
    }
}
