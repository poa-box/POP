// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/*──────── OpenZeppelin v5.3 Upgradeables ────────*/
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*──────── External interfaces ────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";
import {IMembershipAuthority} from "./interfaces/IMembershipAuthority.sol";
import {AccessV2PermKeys} from "./libs/AccessV2PermKeys.sol";

interface IParticipationToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function setEducationHub(address eh) external;
    function educationHub() external view returns (address);
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
    error TokenNotWired();

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
        uint256[] creatorHatIds; // enumeration array for creator hats
        uint256[] memberHatIds; // enumeration array for member hats
        // ─── Role customization (configAdmin) ───
        // Reserved historical config-admin slot; no longer grants any permission.
        address configAdmin;
        // Required MembershipAuthority; zero means an inactive, unmigrated module.
        address membershipAuthority;
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
    /// @notice The secondary config admin (may set creator/member hat allowlists) changed.
    event ConfigAdminSet(address indexed admin);
    /// @notice The org's nonzero MembershipAuthority pointer changed.
    event MembershipAuthoritySet(address indexed authority);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*────────── Initialiser ────────*/

    /// @notice Initialize the education module. Authority wiring is atomic in OrgDeployer.
    function initialize(address tokenAddr, address executorAddr) external initializer {
        if (tokenAddr == address(0) || executorAddr == address(0)) revert ZeroAddress();
        __Context_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        Layout storage l = _layout();
        l.token = IParticipationToken(tokenAddr);
        l.executor = executorAddr;
        emit TokenSet(tokenAddr);
        emit ExecutorSet(executorAddr);
    }

    /*────────── Hat Management ─────*/

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

    /// @notice Point the hub at a new ParticipationToken. Executor-only.
    /// @dev L-16: completeModule mints via `token.mint`, which the token gates on its
    ///      `educationHub` being this hub. If setToken were allowed to point at a token that
    ///      does not authorize this hub as its minter, every completeModule would revert and
    ///      the module rewards would be silently bricked. Require the reverse wiring to already
    ///      be in place so the mis-wire is caught here, not at claim time.
    function setToken(address newToken) external onlyExecutor {
        if (newToken == address(0)) revert ZeroAddress();
        if (IParticipationToken(newToken).educationHub() != address(this)) revert TokenNotWired();
        _layout().token = IParticipationToken(newToken);
        emit TokenSet(newToken);
    }

    function setHats(address newHats) external onlyExecutor {
        if (newHats == address(0)) revert ZeroAddress();
        _layout().hats = IHats(newHats);
        emit HatsSet(newHats);
    }

    /// @notice Set the org's nonzero MembershipAuthority. Governance-only; no legacy rollback.
    function setMembershipAuthority(address authority) external onlyExecutor {
        if (authority == address(0)) revert ZeroAddress();
        _layout().membershipAuthority = authority;
        emit MembershipAuthoritySet(authority);
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
    /// @dev Check EDU_CREATE on the org authority.
    function _hasCreatorHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        address a = l.membershipAuthority;
        return IMembershipAuthority(a).hasPerm(user, AccessV2PermKeys.EDU_CREATE, bytes32(0)) != 0;
    }

    /// @dev Check EDU_MEMBER on the org authority.
    function _hasMemberHat(address user) internal view returns (bool) {
        Layout storage l = _layout();
        address a = l.membershipAuthority;
        return IMembershipAuthority(a).hasPerm(user, AccessV2PermKeys.EDU_MEMBER, bytes32(0)) != 0;
    }

    /*────────── Public getters for storage variables ─────────*/
    function nextModuleId() external view returns (uint256) {
        return _layout().nextModuleId;
    }

    function creatorHatIds() external view returns (uint256[] memory) {
        return _layout().creatorHatIds;
    }

    function memberHatIds() external view returns (uint256[] memory) {
        return _layout().memberHatIds;
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

    /// @notice The org's authority, or zero for an inactive, unmigrated module.
    function membershipAuthority() external view returns (address) {
        return _layout().membershipAuthority;
    }

    /*────────── Hat Management View Functions ─────────── */
    function creatorHatCount() external view returns (uint256) {
        return _layout().creatorHatIds.length;
    }

    function memberHatCount() external view returns (uint256) {
        return _layout().memberHatIds.length;
    }
}
