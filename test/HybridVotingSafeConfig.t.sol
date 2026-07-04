// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {HybridVoting} from "../src/HybridVoting.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {IExecutor} from "../src/Executor.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";
import {MockHats} from "./mocks/MockHats.sol";

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Minimal executor stub — proposals in these tests never need to execute a batch.
contract NoopExecutor is IExecutor {
    function execute(uint256, Call[] calldata) external {}
}

/**
 * @title HybridVotingSafeConfig
 * @notice H2: the audit flagged that HybridVoting's ERC20_BAL class reads a *live* `balanceOf` with no
 *         per-proposal snapshot (transfer-and-revote / mint-mid-proposal inflation). This is acceptable —
 *         and is left unchanged on-chain — *provided the org is configured safely*: the voting asset is the
 *         soulbound ParticipationToken and mint authority (TaskManager self-review / approvers) is not handed
 *         out broadly. These tests PROVE the safety boundary of a properly-configured org and document, with an
 *         executable example, the exact lever an unsafe config would expose.
 */
contract HybridVotingSafeConfigTest is Test {
    address owner = vm.addr(1);
    address alice = vm.addr(2); // member, 200 PT
    address bob = vm.addr(3); // member, 100 PT
    address sock = vm.addr(4); // member, 0 PT, NO mint authority (the would-be attacker)
    address approver = vm.addr(5); // wears APPROVER hat
    address taskManager = vm.addr(6); // the gated mint authority (stands in for TaskManager)

    uint256 constant MEMBER_HAT = 1;
    uint256 constant APPROVER_HAT = 2;
    uint256 constant CREATOR_HAT = 3;

    ParticipationToken public pt;
    HybridVoting public hv;
    MockHats hats;
    NoopExecutor exec;

    function setUp() public {
        hats = new MockHats();
        exec = new NoopExecutor();

        hats.mintHat(MEMBER_HAT, alice);
        hats.mintHat(MEMBER_HAT, bob);
        hats.mintHat(MEMBER_HAT, sock);
        hats.mintHat(MEMBER_HAT, approver);
        hats.mintHat(APPROVER_HAT, approver);
        hats.mintHat(CREATOR_HAT, alice);

        // Deploy the real (soulbound) ParticipationToken; narrow mint authority to `taskManager`.
        // C-01 fix: setTaskManager is executor-only — the token's executor is `exec`.
        pt = _deployPT();
        vm.prank(address(exec));
        pt.setTaskManager(taskManager);
        vm.startPrank(taskManager);
        pt.mint(alice, 200 ether);
        pt.mint(bob, 100 ether);
        vm.stopPrank();

        // Deploy HybridVoting with a single ERC20_BAL class (100%) over the soulbound PT.
        hv = _deployHV(address(pt));
    }

    /* ─────────────────────────── helpers ─────────────────────────── */

    /// @dev Split out of setUp() to keep each function's stack frame small (production via-IR profile).
    function _deployPT() internal returns (ParticipationToken) {
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = MEMBER_HAT;
        uint256[] memory approverHats = new uint256[](1);
        approverHats[0] = APPROVER_HAT;
        UpgradeableBeacon ptBeacon = new UpgradeableBeacon(address(new ParticipationToken()), owner);
        bytes memory ptInit = abi.encodeCall(
            ParticipationToken.initialize,
            (address(exec), "Participation", "PT", address(hats), memberHats, approverHats)
        );
        return ParticipationToken(address(new BeaconProxy(address(ptBeacon), ptInit)));
    }

    /// @dev Split out of setUp() to keep each function's stack frame small (production via-IR profile).
    function _deployHV(address asset) internal returns (HybridVoting) {
        uint256[] memory votingHats = new uint256[](1);
        votingHats[0] = MEMBER_HAT;
        uint256[] memory creatorHats = new uint256[](1);
        creatorHats[0] = CREATOR_HAT;
        address[] memory targets = new address[](1);
        targets[0] = address(0xCA11);
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.ERC20_BAL,
            slicePct: 100,
            quadratic: false,
            minBalance: 1 ether,
            asset: asset,
            hatIds: votingHats
        });
        bytes memory initData = abi.encodeCall(
            HybridVoting.initialize, (address(hats), address(exec), creatorHats, targets, uint8(50), classes)
        );
        UpgradeableBeacon hvBeacon = new UpgradeableBeacon(address(new HybridVoting()), owner);
        return HybridVoting(payable(address(new BeaconProxy(address(hvBeacon), initData))));
    }

    function _createPoll() internal returns (uint256 id) {
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](1);
        batches[1] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
        batches[1][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
        uint256[] memory pollHats = new uint256[](0); // open to all MEMBER_HAT wearers
        vm.prank(alice);
        hv.createProposal(bytes("Treasury Spend"), bytes32(0), 30, 2, batches, pollHats);
        id = hv.proposalsCount() - 1;
    }

    function _vote(address who, uint256 id, uint8 option) internal {
        uint8[] memory idx = new uint8[](1);
        idx[0] = option; // 0 = YES, 1 = NO
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(who);
        hv.vote(id, idx, w);
    }

    /* ───────────────────── Property 1: soulbound token blocks transfer-revote ───────────────────── */

    /// @notice The transferable-asset inflation vector (transfer tokens between addresses to double-count)
    ///         is structurally impossible for the default config because PT is soulbound.
    function test_PT_IsSoulbound_TransferRevoteImpossible() public {
        vm.prank(alice);
        vm.expectRevert(ParticipationToken.TransfersDisabled.selector);
        pt.transfer(sock, 50 ether);

        vm.prank(alice);
        vm.expectRevert(ParticipationToken.TransfersDisabled.selector);
        pt.transferFrom(alice, sock, 50 ether);

        // delegation is also locked, so weight cannot be re-pointed to another voter
        vm.prank(alice);
        vm.expectRevert(ParticipationToken.TransfersDisabled.selector);
        pt.delegate(sock);
    }

    /* ───────────────────── Property 2: unprivileged actor cannot mint to inflate ───────────────────── */

    /// @notice An ordinary member (no TaskManager / approver authority) cannot mint PT, and an approver cannot
    ///         self-approve their own request — so a voter's balance (hence ERC20_BAL weight) is fixed by what
    ///         they legitimately earned.
    function test_UnprivilegedActor_CannotSelfMint() public {
        // direct mint is gated to TaskManager / EducationHub / executor
        vm.prank(sock);
        vm.expectRevert(ParticipationToken.NotTaskOrEdu.selector);
        pt.mint(sock, 1_000_000 ether);

        // the request flow does not let an approver mint to themselves
        vm.prank(approver);
        pt.requestTokens(uint96(1_000_000 ether), "ipfs://self");
        uint256 selfReqId = 1;
        vm.prank(approver);
        vm.expectRevert(ParticipationToken.NotRequester.selector);
        pt.approveRequest(selfReqId);

        // a non-member cannot even open a request
        vm.prank(address(0xDEAD));
        vm.expectRevert(ParticipationToken.NotMember.selector);
        pt.requestTokens(uint96(1 ether), "ipfs://x");
    }

    /* ───────────────────── Scenario: unprivileged actor cannot flip a decided outcome ───────────────────── */

    /// @notice With a safe config, a decided proposal cannot be flipped by an actor who lacks legitimate weight.
    function test_SafeConfig_DecidedOutcomeCannotBeFlipped() public {
        uint256 id = _createPoll();

        _vote(alice, id, 0); // YES, 200 PT
        _vote(bob, id, 1); // NO, 100 PT

        // `sock` is a member but holds 0 PT and has no way to acquire any (mint gated, transfers blocked).
        // The contract's own Sybil guard rejects a zero-power voter outright — sock cannot even cast a ballot,
        // so it can neither shift weight nor inflate the voter/quorum count.
        uint8[] memory idx = new uint8[](1);
        idx[0] = 1;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(sock);
        vm.expectRevert(VotingErrors.Unauthorized.selector);
        hv.vote(id, idx, w);

        vm.warp(block.timestamp + 31 minutes);
        (uint256 winner, bool valid) = hv.announceWinner(id);
        assertTrue(valid, "proposal should be valid");
        assertEq(winner, 0, "YES (200 PT) must win over NO (100 PT) despite sock's weightless vote");
    }

    /* ───────────────────── Boundary: the lever an UNSAFE config would expose ───────────────────── */

    /// @notice Documents (executably) WHY the configuration matters: because weight is read live, an actor who
    ///         *does* hold mint authority can raise their own balance mid-proposal and thereby their vote weight.
    ///         A properly-configured org keeps this authority narrow (no broad self-review); this test shows the
    ///         lever exists so the safe-config requirement is concrete rather than assumed.
    function test_Boundary_MintAuthorityIsTheLever() public {
        uint256 id = _createPoll();

        // Suppose `sock` were (mis)granted mint authority — stand in for a broadly-granted TaskManager self-review.
        // We simulate by minting to sock through the authority, then sock votes with the inflated balance.
        uint256 sockBefore = pt.balanceOf(sock);
        vm.prank(taskManager);
        pt.mint(sock, 1000 ether); // the inflation a safe config must prevent by restricting this authority
        assertGt(pt.balanceOf(sock), sockBefore, "mint authority can raise balance mid-proposal (live weight)");

        _vote(alice, id, 0); // YES, 200 PT
        _vote(sock, id, 1); // NO, 1000 PT (only possible because of the unsafe mint authority)

        vm.warp(block.timestamp + 31 minutes);
        (uint256 winner,) = hv.announceWinner(id);
        assertEq(winner, 1, "with mint authority, NO flips the outcome - exactly what safe config must prevent");
    }
}

/* ════════════════════════════════ Invariant: no unprivileged inflation ════════════════════════════════ */

/// @dev Handler exercising ONLY unprivileged actions (voting, and reverting transfer/mint attempts).
contract UnprivilegedActorHandler is Test {
    ParticipationToken public pt;
    HybridVoting public hv;
    uint256 public proposalId;
    address[] public actors;

    constructor(ParticipationToken _pt, HybridVoting _hv, uint256 _proposalId, address[] memory _actors) {
        pt = _pt;
        hv = _hv;
        proposalId = _proposalId;
        actors = _actors;
    }

    function vote(uint256 actorSeed, uint8 option) external {
        address a = actors[actorSeed % actors.length];
        uint8[] memory idx = new uint8[](1);
        idx[0] = option % 2;
        uint8[] memory w = new uint8[](1);
        w[0] = 100;
        vm.prank(a);
        try hv.vote(proposalId, idx, w) {} catch {}
    }

    function attemptTransfer(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        address to = actors[(actorSeed + 1) % actors.length];
        vm.prank(a);
        try pt.transfer(to, amount) {} catch {}
    }

    function attemptSelfMint(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        try pt.mint(a, amount) {} catch {}
    }
}

contract HybridVotingSafeConfigInvariant is StdInvariant, Test {
    HybridVotingSafeConfigTest internal env;
    ParticipationToken internal pt;
    HybridVoting internal hv;
    UnprivilegedActorHandler internal handler;
    uint256 internal initialSupply;

    function setUp() public {
        // Reuse the safe-config deployment from the scenario test.
        env = new HybridVotingSafeConfigTest();
        env.setUp();
        pt = env.pt();
        hv = env.hv();
        initialSupply = pt.totalSupply();

        // Open a proposal as the creator (alice = vm.addr(2)) so the handler can fuzz votes against it.
        address creator = vm.addr(2);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](1);
        batches[1] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
        batches[1][0] = IExecutor.Call({target: address(0xCA11), value: 0, data: ""});
        uint256[] memory pollHats = new uint256[](0);
        vm.prank(creator);
        hv.createProposal(bytes("Invariant Poll"), bytes32(0), 60, 2, batches, pollHats);
        uint256 pid = hv.proposalsCount() - 1;

        address[] memory actors = new address[](3);
        actors[0] = vm.addr(2); // alice
        actors[1] = vm.addr(3); // bob
        actors[2] = vm.addr(4); // sock
        handler = new UnprivilegedActorHandler(pt, hv, pid, actors);
        targetContract(address(handler));
    }

    /// @notice No sequence of unprivileged voting / transfer / mint attempts can inflate the PT supply.
    ///         Because PT is soulbound and mint is gated, the legitimate weight distribution is immutable,
    ///         so the live-`balanceOf` tally cannot be gamed under a safe config.
    function invariant_supplyConstantUnderUnprivilegedActivity() public view {
        assertEq(pt.totalSupply(), initialSupply, "unprivileged activity must never change PT supply");
    }

    /// @notice Individual voter balances are likewise immutable under unprivileged activity.
    function invariant_voterBalancesImmutable() public view {
        assertEq(pt.balanceOf(vm.addr(2)), 200 ether, "alice balance must be fixed");
        assertEq(pt.balanceOf(vm.addr(3)), 100 ether, "bob balance must be fixed");
        assertEq(pt.balanceOf(vm.addr(4)), 0, "sock must never acquire weight");
    }
}
