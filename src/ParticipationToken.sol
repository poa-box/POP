// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.20;

/*──────────────────── OpenZeppelin v5.3 Upgradeables ─────────────*/
import "@openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/*────────────── External Hats interface ─────────────*/
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {HatManager} from "./libs/HatManager.sol";

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
        uint256[] memberHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        uint256[] approverHatIds; // DEPRECATED: dead state, kept for ERC-7201 append-only rules
        // ─── Hats-native capability hats (one per gate) ───
        uint256 memberHat; // capability hat for requestTokens (member-only)
        uint256 approverHat; // capability hat for approveRequest (approver-only)
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*─────────── Initialiser ──────*/
    /// @param executor_ Org's Executor (governance)
    /// @param name_ ERC20 token name
    /// @param symbol_ ERC20 token symbol
    /// @param hatsAddr Hats Protocol address
    /// @param memberHat_ Capability hat gating `requestTokens` (member-only)
    /// @param approverHat_ Capability hat gating `approveRequest` (approver-only)
    function initialize(
        address executor_,
        string calldata name_,
        string calldata symbol_,
        address hatsAddr,
        uint256 memberHat_,
        uint256 approverHat_
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
        l.memberHat = memberHat_;
        l.approverHat = approverHat_;

        emit MemberHatSet(memberHat_, true);
        emit ApproverHatSet(approverHat_, true);
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

    /*──────── Admin setters ───────*/
    function setTaskManager(address tm) external {
        if (tm == address(0)) revert InvalidAddress();
        Layout storage l = _layout();
        if (l.taskManager == address(0)) {
            l.taskManager = tm;
            emit TaskManagerSet(tm);
        } else {
            if (_msgSender() != l.executor) revert Unauthorized();
            l.taskManager = tm;
            emit TaskManagerSet(tm);
        }
    }

    function setEducationHub(address eh) external {
        // Allow address(0) to support optional EducationHub deployment
        // and allow executor to clear it later
        Layout storage l = _layout();
        if (l.educationHub == address(0)) {
            l.educationHub = eh;
            emit EducationHubSet(eh);
        } else {
            if (_msgSender() != l.executor) revert Unauthorized();
            l.educationHub = eh;
            emit EducationHubSet(eh);
        }
    }

    function setMemberHat(uint256 h) external onlyExecutor {
        _layout().memberHat = h;
        emit MemberHatSet(h, true);
    }

    function setApproverHat(uint256 h) external onlyExecutor {
        _layout().approverHat = h;
        emit ApproverHatSet(h, true);
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
    /// @dev Returns true if `user` wears the capability hat for the given type.
    function _hasHat(address user, HatType hatType) internal view returns (bool) {
        Layout storage l = _layout();
        uint256 hatId = hatType == HatType.MEMBER ? l.memberHat : l.approverHat;
        return l.hats.isWearerOfHat(user, hatId);
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

    function requestCounter() external view returns (uint256) {
        return _layout().requestCounter;
    }

    /// @notice Backwards-compat array getter; returns single-element array with the
    ///         current capability hat.
    function memberHatIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().memberHat;
    }

    /// @notice Backwards-compat array getter; returns single-element array with the
    ///         current capability hat.
    function approverHatIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _layout().approverHat;
    }

    function memberHat() external view returns (uint256) {
        return _layout().memberHat;
    }

    function approverHat() external view returns (uint256) {
        return _layout().approverHat;
    }

    /*───────── Hat Management View Functions ─────────*/
    function memberHatCount() external view returns (uint256) {
        return 1;
    }

    function approverHatCount() external view returns (uint256) {
        return 1;
    }

    function isMemberHat(uint256 hatId) external view returns (bool) {
        return hatId != 0 && hatId == _layout().memberHat;
    }

    function isApproverHat(uint256 hatId) external view returns (bool) {
        return hatId != 0 && hatId == _layout().approverHat;
    }
}
