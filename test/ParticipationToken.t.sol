// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ParticipationToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

contract ParticipationTokenTest is Test {
    ParticipationToken token;
    MockHats hats;
    address executor = address(0x1);
    address taskManager = address(0x2);
    address educationHub = address(0x3);
    address member = address(0x4);
    address approver = address(0x5);

    uint256 constant MEMBER_HAT_ID = 1;
    uint256 constant APPROVER_HAT_ID = 2;

    function setUp() public {
        hats = new MockHats();

        // Mint member hat to member
        hats.mintHat(MEMBER_HAT_ID, member);

        // Mint approver hat to approver
        hats.mintHat(APPROVER_HAT_ID, approver);

        ParticipationToken impl = new ParticipationToken();
        bytes memory data = abi.encodeCall(
            ParticipationToken.initialize, (executor, "PToken", "PTK", address(hats), MEMBER_HAT_ID, APPROVER_HAT_ID)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        token = ParticipationToken(address(proxy));
    }

    function testInitializeStores() public {
        assertEq(token.executor(), executor);
        assertEq(address(token.hats()), address(hats));
        assertEq(token.memberHat(), MEMBER_HAT_ID);
        assertEq(token.approverHat(), APPROVER_HAT_ID);
        // Backwards-compat array getters return single-element arrays
        assertEq(token.memberHatIds()[0], MEMBER_HAT_ID);
        assertEq(token.approverHatIds()[0], APPROVER_HAT_ID);
    }

    function testSetTaskManagerOnceAndByExecutor() public {
        token.setTaskManager(taskManager);
        assertEq(token.taskManager(), taskManager);
        vm.prank(executor);
        token.setTaskManager(address(0x5));
        assertEq(token.taskManager(), address(0x5));
    }

    function testSetEducationHubOnceAndByExecutor() public {
        token.setEducationHub(educationHub);
        assertEq(token.educationHub(), educationHub);
        vm.prank(executor);
        token.setEducationHub(address(0x6));
        assertEq(token.educationHub(), address(0x6));
    }

    function testMintOnlyAuthorized() public {
        token.setTaskManager(taskManager);
        vm.prank(taskManager);
        token.mint(member, 1 ether);
        assertEq(token.balanceOf(member), 1 ether);
        vm.prank(executor);
        token.mint(member, 1 ether);
        assertEq(token.balanceOf(member), 2 ether);
        vm.expectRevert(ParticipationToken.NotTaskOrEdu.selector);
        token.mint(member, 1 ether);
    }

    function testRequestApproveAndCancel() public {
        // Member requests tokens
        vm.prank(member);
        token.requestTokens(1 ether, "ipfs://req");
        (address req,, bool approved,) = token.requests(1);
        assertEq(req, member);
        assertFalse(approved);

        // Approver approves request
        vm.prank(approver);
        token.approveRequest(1);
        assertEq(token.balanceOf(member), 1 ether);

        // Cannot cancel approved request
        vm.prank(member);
        vm.expectRevert(ParticipationToken.AlreadyApproved.selector);
        token.cancelRequest(1);
    }

    function testRequestRequiresMemberHat() public {
        address nonMember = address(0x6);
        vm.prank(nonMember);
        vm.expectRevert(ParticipationToken.NotMember.selector);
        token.requestTokens(1 ether, "ipfs://req");
    }

    function testApproveRequiresApproverHat() public {
        vm.prank(member);
        token.requestTokens(1 ether, "ipfs://req");

        address nonApprover = address(0x6);
        vm.prank(nonApprover);
        vm.expectRevert(ParticipationToken.NotApprover.selector);
        token.approveRequest(1);
    }

    function testSetMemberHat() public {
        uint256 newHatId = 123;
        address newMember = address(0xbeef);

        // Create and assign new hat
        hats.createHat(newHatId, "New Member Hat", 1, address(0), address(0), true, "");
        hats.mintHat(newHatId, newMember);

        // Should fail without hat permission
        vm.prank(newMember);
        vm.expectRevert(ParticipationToken.NotMember.selector);
        token.requestTokens(1 ether, "ipfs://req");

        // Swap to new member capability hat
        vm.prank(executor);
        token.setMemberHat(newHatId);

        // newMember now passes the member gate
        vm.prank(newMember);
        token.requestTokens(1 ether, "ipfs://req");

        // Old member (only wears MEMBER_HAT_ID) no longer passes
        vm.prank(member);
        vm.expectRevert(ParticipationToken.NotMember.selector);
        token.requestTokens(1 ether, "ipfs://req2");
    }

    function testSetApproverHat() public {
        uint256 newHatId = 456;
        address newApprover = address(0xcafe);

        // Create and assign new hat
        hats.createHat(newHatId, "New Approver Hat", 1, address(0), address(0), true, "");
        hats.mintHat(newHatId, newApprover);

        // Create a request first
        vm.prank(member);
        token.requestTokens(1 ether, "ipfs://req");

        // Should fail without hat permission
        vm.prank(newApprover);
        vm.expectRevert(ParticipationToken.NotApprover.selector);
        token.approveRequest(1);

        // Swap to new approver capability hat
        vm.prank(executor);
        token.setApproverHat(newHatId);

        // Should now succeed
        vm.prank(newApprover);
        token.approveRequest(1);
        assertEq(token.balanceOf(member), 1 ether);
    }

    function testExecutorBypassesHatChecks() public {
        // Test 1: Executor can request tokens without member hat
        vm.prank(executor);
        token.requestTokens(1 ether, "ipfs://exec-req");

        // Test 2: Executor can approve someone else's request without approver hat
        // First, have the member make a request
        vm.prank(member);
        token.requestTokens(2 ether, "ipfs://member-req");

        // Now executor can approve the member's request (ID 2)
        vm.prank(executor);
        token.approveRequest(2);
        assertEq(token.balanceOf(member), 2 ether);

        // Test 3: Someone with approver hat can approve the executor's request
        vm.prank(approver);
        token.approveRequest(1);
        assertEq(token.balanceOf(executor), 1 ether);
    }

    function testTransfersDisabled() public {
        vm.expectRevert(ParticipationToken.TransfersDisabled.selector);
        token.transfer(address(1), 1);
    }

    /*══════════════════════════════════════════════════════
     * setName / setSymbol — metadata setters via governance
     *══════════════════════════════════════════════════════*/

    // Re-declare events for vm.expectEmit (Foundry needs them in test scope)
    event NameSet(string newName);
    event SymbolSet(string newSymbol);

    // ---------- setName ----------

    function testSetName_AsExecutor_Short() public {
        vm.prank(executor);
        token.setName("Reputation Points");
        assertEq(token.name(), "Reputation Points");
    }

    function testSetName_AsExecutor_LongString() public {
        // 40-char string forces the long-string storage branch (>= 32 bytes)
        string memory longName = "Argus Reputation Reward Token Long Name!";
        assertEq(bytes(longName).length, 40, "test setup: expected 40 bytes");

        vm.prank(executor);
        token.setName(longName);
        assertEq(token.name(), longName);
    }

    function testSetName_AsExecutor_ExactlyMaxLength() public {
        // 64 chars (MAX_NAME_LENGTH) should pass
        string memory s64 = "0123456789012345678901234567890123456789012345678901234567890123";
        assertEq(bytes(s64).length, 64);
        vm.prank(executor);
        token.setName(s64);
        assertEq(token.name(), s64);
    }

    function testSetName_RevertsWhenNotExecutor() public {
        vm.prank(member);
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        token.setName("Hijacked");

        vm.prank(taskManager);
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        token.setName("Hijacked");

        vm.prank(approver);
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        token.setName("Hijacked");

        // Default sender (not pranked) — also not executor
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        token.setName("Hijacked");
    }

    function testSetName_RevertsOnEmpty() public {
        vm.prank(executor);
        vm.expectRevert(ParticipationToken.EmptyString.selector);
        token.setName("");
    }

    function testSetName_RevertsOnTooLong() public {
        // 65 chars — one over MAX_NAME_LENGTH
        string memory tooLong = "01234567890123456789012345678901234567890123456789012345678901234";
        assertEq(bytes(tooLong).length, 65);
        vm.prank(executor);
        vm.expectRevert(ParticipationToken.StringTooLong.selector);
        token.setName(tooLong);
    }

    function testSetName_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit NameSet("FOO");
        vm.prank(executor);
        token.setName("FOO");
    }

    // ---------- setSymbol ----------

    function testSetSymbol_AsExecutor() public {
        vm.prank(executor);
        token.setSymbol("REP");
        assertEq(token.symbol(), "REP");
    }

    function testSetSymbol_AsExecutor_ExactlyMaxLength() public {
        // 16 chars (MAX_SYMBOL_LENGTH)
        string memory s16 = "ABCDEFGHIJKLMNOP";
        assertEq(bytes(s16).length, 16);
        vm.prank(executor);
        token.setSymbol(s16);
        assertEq(token.symbol(), s16);
    }

    function testSetSymbol_RevertsWhenNotExecutor() public {
        vm.prank(member);
        vm.expectRevert(ParticipationToken.Unauthorized.selector);
        token.setSymbol("HIJ");
    }

    function testSetSymbol_RevertsOnEmpty() public {
        vm.prank(executor);
        vm.expectRevert(ParticipationToken.EmptyString.selector);
        token.setSymbol("");
    }

    function testSetSymbol_RevertsOnTooLong() public {
        // 17 chars — one over MAX_SYMBOL_LENGTH
        string memory tooLong = "ABCDEFGHIJKLMNOPQ";
        assertEq(bytes(tooLong).length, 17);
        vm.prank(executor);
        vm.expectRevert(ParticipationToken.StringTooLong.selector);
        token.setSymbol(tooLong);
    }

    function testSetSymbol_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit SymbolSet("ARG");
        vm.prank(executor);
        token.setSymbol("ARG");
    }

    // ---------- Storage layout invariants ----------

    /// @notice Belt-and-suspenders: confirm the hardcoded ERC20 storage slot
    ///         in ParticipationToken matches what OZ derives from
    ///         `erc7201:openzeppelin.storage.ERC20`. If OZ ever changes the
    ///         namespace path, this catches it before the assembly write
    ///         silently corrupts unrelated storage.
    function testStorageSlot_MatchesOZNamespace() public {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff));

        // _name lives at expected + 3. After init, it should hold "PToken"
        // (length 6, encoding = "PToken" + (6*2) = 0x50546f6b656e0c in upper bytes)
        bytes32 nameSlot = bytes32(uint256(expected) + 3);
        bytes32 raw = vm.load(address(token), nameSlot);

        // Lowest byte = length × 2 for short strings
        assertEq(uint8(uint256(raw) & 0xff), 12, "expected len*2 = 12 for 'PToken'");
    }

    /// @notice Critical: the assembly write hits ONLY _name / _symbol slots,
    ///         not the adjacent _balances / _allowances / _totalSupply.
    function testSetName_DoesNotCorruptBalances() public {
        // Set up taskManager + mint to member
        token.setTaskManager(taskManager);
        vm.prank(taskManager);
        token.mint(member, 100 ether);
        uint256 balBefore = token.balanceOf(member);
        uint256 supplyBefore = token.totalSupply();
        assertEq(balBefore, 100 ether);
        assertEq(supplyBefore, 100 ether);

        vm.prank(executor);
        token.setName("Different");

        assertEq(token.balanceOf(member), balBefore, "balance changed after setName");
        assertEq(token.totalSupply(), supplyBefore, "supply changed after setName");
        assertEq(token.name(), "Different");
        // Symbol should still be the original
        assertEq(token.symbol(), "PTK");
    }

    function testSetSymbol_DoesNotCorruptName() public {
        vm.prank(executor);
        token.setSymbol("NEW");
        assertEq(token.symbol(), "NEW");
        assertEq(token.name(), "PToken", "name was modified by setSymbol");
    }

    /// @notice Both setters in sequence work (covers slot offset correctness).
    function testSetNameAndSymbol_Sequential() public {
        vm.startPrank(executor);
        token.setName("First Name");
        token.setSymbol("FST");
        token.setName("Second Name");
        token.setSymbol("SND");
        vm.stopPrank();

        assertEq(token.name(), "Second Name");
        assertEq(token.symbol(), "SND");
    }

    /// @notice Long-string write followed by short-string write — verifies
    ///         the length prefix is updated correctly when shrinking.
    function testSetName_LongThenShort() public {
        string memory long = "Argus Reputation Reward Token Long Name!"; // 40 bytes
        vm.prank(executor);
        token.setName(long);
        assertEq(token.name(), long);

        // Now write a shorter name — should overwrite cleanly
        vm.prank(executor);
        token.setName("Short");
        assertEq(token.name(), "Short");
    }
}
