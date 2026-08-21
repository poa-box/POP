// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.20;

/*──────────────────── OpenZeppelin v5.3 Upgradeables ─────────────*/
import "@openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/*────────────── External Hats interface ─────────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";
import {IMembershipAuthority} from "./interfaces/IMembershipAuthority.sol";
import {AccessV2PermKeys} from "./libs/AccessV2PermKeys.sol";

/*──────────────────  Participation Token  ──────────────────*/
contract ParticipationToken is Initializable, ERC20VotesUpgradeable, ReentrancyGuardUpgradeable {
    /*──────────── Errors ───────────*/
    error NotTaskOrEdu();
    error NotApprover();
    error NotMember();
    error NotRequester();
    error RequestUnknown();
    error AlreadyApproved();
    error AlreadySet();
    error InvalidAddress();
    error ZeroAmount();
    error TransfersDisabled();
    error Unauthorized();
    error EmptyString();
    error StringTooLong();

    /*──────────── Constants ───────────*/
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;

    /// @dev ERC-7201 storage slot for OZ ERC20Upgradeable. Hardcoded against OZ
    ///      v5.3 layout (`erc7201:openzeppelin.storage.ERC20`). The
    ///      testStorageSlotMatchesOZ test asserts this matches what OZ derives
    ///      so accidental dependency upgrades don't silently break renames.
    bytes32 private constant ERC20_STORAGE_SLOT = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    /// @dev Field offsets within ERC20Storage struct
    /// (see OZ ERC20Upgradeable.sol: _balances, _allowances, _totalSupply, _name, _symbol).
    uint256 private constant ERC20_NAME_OFFSET = 3;
    uint256 private constant ERC20_SYMBOL_OFFSET = 4;

    /*──────────── Types ───────────*/
    struct Request {
        address requester;
        uint96 amount;
        bool approved;
        string ipfsHash;
    }

    /*──────────── Hat Type Enum ───────────*/
    enum HatType {
        MEMBER,
        APPROVER
    }

    /*──────────── ERC-7201 Storage ───────────*/
    /// @custom:storage-location erc7201:poa.participationtoken.storage
    struct Layout {
        address taskManager;
        address educationHub;
        IHats hats;
        address executor;
        uint256 requestCounter;
        mapping(uint256 => Request) requests;
        uint256[] memberHatIds; // enumeration array for member hats
        uint256[] approverHatIds; // enumeration array for approver hats
        // ─── Role customization (configAdmin) ───
        // Optional secondary admin (e.g. RoleManager) permitted to set member/approver hat
        // allowlists alongside the executor. address(0) = none.
        address configAdmin;
        // ─── Access v2 dual-path (append-only tail) ───
        // When non-zero, member/approver reads route through the org's MembershipAuthority instead
        // of the legacy Hats path. address(0) = legacy path (byte-identical; also the rollback state).
        address membershipAuthority;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.participationtoken.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*──────────── Events ──────────*/
    event TaskManagerSet(address indexed taskManager);
    event EducationHubSet(address indexed educationHub);
    event Requested(uint256 indexed id, address indexed requester, uint96 amount, string ipfsHash);
    event RequestApproved(uint256 indexed id, address indexed approver);
    event RequestCancelled(uint256 indexed id, address indexed caller);
    event MemberHatSet(uint256 hat, bool allowed);
    event ApproverHatSet(uint256 hat, bool allowed);
    event NameSet(string newName);
    event SymbolSet(string newSymbol);
    /// @notice The secondary config admin (may set member/approver hat allowlists) changed.
    event ConfigAdminSet(address indexed admin);
    /// @notice The org's MembershipAuthority pointer changed. `authority == address(0)` restores the
    ///         legacy Hats member/approver path (rollback).
    event MembershipAuthoritySet(address indexed authority);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*─────────── Initialiser ──────*/
    function initialize(
        address executor_,
        string calldata name_,
        string calldata symbol_,
        address hatsAddr,
        uint256[] calldata initialMemberHats,
        uint256[] calldata initialApproverHats
    ) external initializer {
        if (hatsAddr == address(0) || executor_ == address(0)) {
            revert InvalidAddress();
        }

        __ERC20_init(name_, symbol_);
        __ERC20Votes_init();
        __ReentrancyGuard_init();

        Layout storage l = _layout();
        l.hats = IHats(hatsAddr);
        l.executor = executor_;

        // Set initial member hats using HatManager
        for (uint256 i; i < initialMemberHats.length;) {
            HatManager.setHatInArray(l.memberHatIds, initialMemberHats[i], true);
            emit MemberHatSet(initialMemberHats[i], true);
            unchecked {
                ++i;
            }
        }

        // Set initial approver hats using HatManager
        for (uint256 i; i < initialApproverHats.length;) {
            HatManager.setHatInArray(l.approverHatIds, initialApproverHats[i], true);
            emit ApproverHatSet(initialApproverHats[i], true);
            unchecked {
                ++i;
            }
        }
    }

    /*────────── Modifiers ─────────*/
    modifier onlyTaskOrEdu() {
        _checkTaskOrEdu();
        _;
    }

    modifier onlyApprover() {
        _checkApprover();
        _;
    }

    modifier isMember() {
        _checkMember();
        _;
    }

    modifier onlyExecutor() {
        _checkExecutor();
        _;
    }

    function _checkTaskOrEdu() private view {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && _msgSender() != l.taskManager && _msgSender() != l.educationHub) {
            revert NotTaskOrEdu();
        }
    }

    function _checkApprover() private view {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && !_hasHat(_msgSender(), HatType.APPROVER)) {
            revert NotApprover();
        }
    }

    function _checkMember() private view {
        Layout storage l = _layout();
        if (_msgSender() != l.executor && !_hasHat(_msgSender(), HatType.MEMBER)) {
            revert NotMember();
        }
    }

    function _checkExecutor() private view {
        if (_msgSender() != _layout().executor) {
            revert Unauthorized();
        }
    }

    /// @dev Caller must be the executor or the configured configAdmin; reverts Unauthorized otherwise.
    ///      Used only by the member/approver hat setters so a RoleManager can fan out role wiring.
    function _checkExecutorOrConfigAdmin() private view {
        Layout storage l = _layout();
        address s = _msgSender();
        if (s == l.executor) return;
        if (s != address(0) && s == l.configAdmin) return;
        revert Unauthorized();
    }

    /*──────── Admin setters ───────*/
    /// @notice Set the TaskManager authorized to mint tokens. Executor-only.
    /// @dev C-01 fix: previously the first set (while `taskManager == 0`) was open
    ///      to any caller, letting an attacker install a malicious minter. Now every
    ///      set — first and subsequent — must come from the executor. During atomic
    ///      deploy the wiring flows through `Executor.configureParticipationToken`,
    ///      so `_msgSender()` is the executor and the gate passes.
    function setTaskManager(address tm) external onlyExecutor {
        if (tm == address(0)) revert InvalidAddress();
        Layout storage l = _layout();
        l.taskManager = tm;
        emit TaskManagerSet(tm);
    }

    /// @notice Set (or clear) the EducationHub authorized to mint tokens. Executor-only.
    /// @dev C-01 fix: the first set was previously open to any caller. Because an
    ///      unset `educationHub` authorizes its owner as an unbounded minter via
    ///      `_checkTaskOrEdu`, an attacker could seize minting on any org deployed
    ///      without an EducationHub. Now every set is executor-only. `address(0)` is
    ///      still accepted so the executor can clear a previously-set hub.
    function setEducationHub(address eh) external onlyExecutor {
        Layout storage l = _layout();
        l.educationHub = eh;
        emit EducationHubSet(eh);
    }

    /// @notice Set the secondary config admin permitted to set member/approver hat allowlists.
    /// @dev Executor-only. `admin` may be address(0) to clear.
    function setConfigAdmin(address admin) external onlyExecutor {
        _layout().configAdmin = admin;
        emit ConfigAdminSet(admin);
    }

    /// @notice Repoint this module to the org's MembershipAuthority (Access v2).
    /// @dev Executor-only. When `authority != address(0)` member/approver reads route through the
    ///      authority; `address(0)` restores the legacy Hats path (rollback). Dual-path §4.5/§4.1.
    function setMembershipAuthority(address authority) external onlyExecutor {
        _layout().membershipAuthority = authority;
        emit MembershipAuthoritySet(authority);
    }

    /// @notice Add or remove a member hat. Executor or configAdmin.
    function setMemberHatAllowed(uint256 h, bool ok) external {
        _checkExecutorOrConfigAdmin();
        Layout storage l = _layout();
        HatManager.setHatInArray(l.memberHatIds, h, ok);
        emit MemberHatSet(h, ok);
    }

    /// @notice Add or remove an approver hat. Executor or configAdmin.
    function setApproverHatAllowed(uint256 h, bool ok) external {
        _checkExecutorOrConfigAdmin();
        Layout storage l = _layout();
        HatManager.setHatInArray(l.approverHatIds, h, ok);
        emit ApproverHatSet(h, ok);
    }

    /// @notice Update the ERC20 token name. Executor-only — typically called via
    ///         a passed governance proposal that targets this function.
    /// @dev OZ ERC20Upgradeable's `_name` is private and unset post-init, so we
    ///      write directly to its ERC-7201 storage slot. Length-bounded to 64.
    function setName(string calldata newName) external onlyExecutor {
        uint256 len = bytes(newName).length;
        if (len == 0) revert EmptyString();
        if (len > MAX_NAME_LENGTH) revert StringTooLong();
        _writeERC20String(ERC20_NAME_OFFSET, newName);
        emit NameSet(newName);
    }

    /// @notice Update the ERC20 token symbol. Executor-only.
    /// @dev See `setName`. Length-bounded to 16 to match common wallet UIs.
    function setSymbol(string calldata newSymbol) external onlyExecutor {
        uint256 len = bytes(newSymbol).length;
        if (len == 0) revert EmptyString();
        if (len > MAX_SYMBOL_LENGTH) revert StringTooLong();
        _writeERC20String(ERC20_SYMBOL_OFFSET, newSymbol);
        emit SymbolSet(newSymbol);
    }

    /// @dev Writes a Solidity string to the OZ ERC20 storage struct at `offset`.
    ///      Replicates Solidity's string storage encoding:
    ///        - len < 32:  single slot, packed = (data << (32-len)*8) | (len*2)
    ///        - len >= 32: slot stores (len*2 + 1); data lives at keccak256(slot),
    ///                     with the last chunk zero-padded beyond `len`.
    ///      Inputs are length-bounded by callers so the long-string branch is
    ///      bounded and predictable.
    function _writeERC20String(uint256 offset, string calldata s) private {
        bytes32 baseSlot = bytes32(uint256(ERC20_STORAGE_SLOT) + offset);
        bytes calldata b = bytes(s);
        uint256 len = b.length;

        if (len < 32) {
            assembly {
                // Load up to 32 bytes from calldata starting at b.offset.
                // calldatacopy guarantees zero-fill beyond actual length, but
                // Solidity calldata bytes are followed by their next ABI item,
                // so we mask explicitly to be safe.
                calldatacopy(0x00, b.offset, len)
                let raw := mload(0x00)
                // Mask: keep top `len` bytes, zero the rest.
                let mask := not(shr(mul(len, 8), not(0)))
                let packed := or(and(raw, mask), mul(len, 2))
                sstore(baseSlot, packed)
            }
        } else {
            assembly {
                // Header slot: len*2 + 1 (long-string flag).
                sstore(baseSlot, add(mul(len, 2), 1))
                // Data starts at keccak256(baseSlot).
                mstore(0x00, baseSlot)
                let dataSlot := keccak256(0x00, 0x20)

                // Copy in 32-byte chunks; zero-pad the final chunk past `len`.
                for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                    calldatacopy(0x00, add(b.offset, i), 32)
                    let chunk := mload(0x00)
                    let remaining := sub(len, i)
                    if lt(remaining, 32) {
                        let bits := mul(sub(32, remaining), 8)
                        chunk := and(chunk, shl(bits, not(0)))
                    }
                    sstore(add(dataSlot, div(i, 32)), chunk)
                }
            }
        }
    }

    /*────── Mint by authorised modules ─────*/
    function mint(address to, uint256 amount) external nonReentrant onlyTaskOrEdu {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /*────────── Request flow ─────────*/
    function requestTokens(uint96 amount, string calldata ipfsHash) external isMember {
        if (amount == 0) revert ZeroAmount();
        if (bytes(ipfsHash).length == 0) revert ZeroAmount();

        Layout storage l = _layout();
        uint256 requestId = ++l.requestCounter;
        l.requests[requestId] = Request({requester: _msgSender(), amount: amount, approved: false, ipfsHash: ipfsHash});

        emit Requested(requestId, _msgSender(), amount, ipfsHash);
    }

    /// Approvers approve – state change *after* successful mint
    function approveRequest(uint256 id) external nonReentrant onlyApprover {
        Layout storage l = _layout();
        Request storage r = l.requests[id];
        if (r.requester == address(0)) revert RequestUnknown();
        if (r.approved) revert AlreadyApproved();
        if (r.requester == _msgSender()) revert NotRequester();

        r.approved = true;
        _mint(r.requester, r.amount);

        emit RequestApproved(id, _msgSender());
    }

    /// Cancel unapproved request – requester **or** approver
    function cancelRequest(uint256 id) external nonReentrant {
        Layout storage l = _layout();
        Request storage r = l.requests[id];
        if (r.requester == address(0)) revert RequestUnknown();
        if (r.approved) revert AlreadyApproved();

        bool isApprover = (_msgSender() == l.executor) || _hasHat(_msgSender(), HatType.APPROVER);
        if (_msgSender() != r.requester && !isApprover) revert NotApprover();

        delete l.requests[id];
        emit RequestCancelled(id, _msgSender());
    }

    /*────── Complete transfer lockdown ─────*/
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    /// still allow mint / burn internally
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
        super._update(from, to, value);

        // Auto-delegate to self on first mint to ensure votes are counted
        if (from == address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /*───────── Delegation Control (Disabled) ─────────*/
    /// @notice Delegation is disabled - votes automatically count for token holder
    /// @dev Reverts to prevent delegation to other addresses
    function delegate(address) public pure override {
        revert TransfersDisabled(); // Reusing existing error for consistency
    }

    /// @notice Delegation by signature is disabled
    /// @dev Reverts to prevent delegation to other addresses
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) public pure override {
        revert TransfersDisabled(); // Reusing existing error for consistency
    }

    /*───────── ERC20Votes Clock Configuration ─────────*/
    /// @dev Use block numbers for checkpointing (simpler and more predictable)
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    /*───────── Internal Helper Functions ─────────*/
    /// @dev Returns true if `user` wears *any* hat of the requested type. Access v2: when an authority
    ///      is set, the check routes through `hasPerm(user, PT_MEMBER|PT_APPROVE, GLOBAL) != 0` (§4.5);
    ///      legacy Hats otherwise (byte-identical / rollback path).
    function _hasHat(address user, HatType hatType) internal view returns (bool) {
        Layout storage l = _layout();
        address a = l.membershipAuthority;
        if (a != address(0)) {
            bytes32 key = hatType == HatType.MEMBER ? AccessV2PermKeys.PT_MEMBER : AccessV2PermKeys.PT_APPROVE;
            return IMembershipAuthority(a).hasPerm(user, key, bytes32(0)) != 0;
        }
        uint256[] storage ids = hatType == HatType.MEMBER ? l.memberHatIds : l.approverHatIds;
        return HatManager.hasAnyHat(l.hats, ids, user);
    }

    /*───────── View helpers ─────────*/
    function requests(uint256 id)
        external
        view
        returns (address requester, uint96 amount, bool approved, string memory ipfsHash)
    {
        Layout storage l = _layout();
        Request storage r = l.requests[id];
        return (r.requester, r.amount, r.approved, r.ipfsHash);
    }

    function taskManager() external view returns (address) {
        return _layout().taskManager;
    }

    function educationHub() external view returns (address) {
        return _layout().educationHub;
    }

    function hats() external view returns (IHats) {
        return _layout().hats;
    }

    function executor() external view returns (address) {
        return _layout().executor;
    }

    /// @notice The org's MembershipAuthority pointer (Access v2). address(0) = legacy Hats path.
    function membershipAuthority() external view returns (address) {
        return _layout().membershipAuthority;
    }

    function requestCounter() external view returns (uint256) {
        return _layout().requestCounter;
    }

    function memberHatIds() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().memberHatIds);
    }

    function approverHatIds() external view returns (uint256[] memory) {
        return HatManager.getHatArray(_layout().approverHatIds);
    }

    /*───────── Hat Management View Functions ─────────*/
    function memberHatCount() external view returns (uint256) {
        return HatManager.getHatCount(_layout().memberHatIds);
    }

    function approverHatCount() external view returns (uint256) {
        return HatManager.getHatCount(_layout().approverHatIds);
    }

    function isMemberHat(uint256 hatId) external view returns (bool) {
        return HatManager.isHatInArray(_layout().memberHatIds, hatId);
    }

    function isApproverHat(uint256 hatId) external view returns (bool) {
        return HatManager.isHatInArray(_layout().approverHatIds, hatId);
    }
}
