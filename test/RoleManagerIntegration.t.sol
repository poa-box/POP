// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {Executor, IExecutor} from "../src/Executor.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";
import {VotingErrors} from "../src/libs/VotingErrors.sol";

/**
 * @title RoleManagerIntegrationTest
 * @notice End-to-end W6 integration suite wiring the REAL contracts together (NO mocks): real Hats
 *         Protocol, real EligibilityModule (+EligibilityLogic delegatecall lib), real ToggleModule,
 *         real Executor, real RoleManager, real DirectDemocracyVoting + HybridVoting, real
 *         TaskManager + ParticipationToken. It exercises the full "KUBI story": role/group creation
 *         with typed permission fan-out, the consent-safe grant/offer/claim flow, group-restricted
 *         polls (quorum override + equalWeight), dynamic derived-eligibility revocation, the
 *         bidirectional derived<->vouch guard, legacy-hat adoption, an election batch through the
 *         real Executor, and superAdmin kick precedence.
 *
 *         The Hats tree is built manually in setUp, mirroring HatsTreeSetup's ordering: mint a top hat
 *         to the deployer, create an ELIGIBILITY_ADMIN hat worn by the EM proxy (so EM is admin of every
 *         role/marker hat it mints), then hand superAdmin to the Executor. Because Hats is real, the
 *         C-1 invariant (eligibility != wearing) and mechanistic getWearerStatus staticcall path are
 *         genuinely exercised — derived markers auto-zero with no burn call when a member loses their
 *         last identity hat.
 *
 *         Real Hats is obtained by forking a live chain and using the canonical deployment through the
 *         {IHats} interface — the same approach as DeployerTest. Hats.sol itself is deliberately never
 *         compiled locally (its `batchCreateHats` assembly stack-overflows under the mandated
 *         optimizer-off default profile), so a fork is the only faithful, non-mock source of real Hats.
 *         Fork-RPC noise (`-32029 Rate limited`) is environmental, per the repo's memory notes.
 */
contract RoleManagerIntegrationTest is Test {
    /// @dev Canonical Hats Protocol deployment (same address on every chain).
    address internal constant CANONICAL_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    /// @dev Pinned Gnosis block for fork-cache stability across reruns.
    uint256 internal constant FORK_BLOCK = 47_700_000;

    /*───────────────────────── Real contracts ─────────────────────────*/
    IHats internal hats;
    EligibilityModule internal em;
    ToggleModule internal toggle;
    Executor internal executor;
    RoleManager internal rm;
    DirectDemocracyVoting internal dd;
    HybridVoting internal hv;
    TaskManager internal tm;
    ParticipationToken internal pt;

    /*───────────────────────── Hat ids ─────────────────────────*/
    uint256 internal topHat;
    uint256 internal adminHat;
    uint256 internal memberHat; // base org-membership hat (seeds RoleManager.orgHats)

    /*───────────────────────── Actors ─────────────────────────*/
    address internal deployer = address(this);
    address internal alice = makeAddr("alice"); // in-org member
    address internal bob = makeAddr("bob"); // in-org member
    address internal carol = makeAddr("carol"); // in-org member
    address internal ianthe = makeAddr("ianthe"); // in-org member (election winner)
    address internal dave = makeAddr("dave"); // NOT in org (offer/claim)
    address internal frank = makeAddr("frank"); // legacy Executive wearer (adoption)
    address internal grace = makeAddr("grace"); // legacy Executive wearer (adoption)
    address internal rando = makeAddr("rando");

    /*───────────────────────── Config ─────────────────────────*/
    uint8 internal constant THRESHOLD = 50;
    uint32 internal constant DD_GLOBAL_QUORUM = 2;
    bytes32 internal constant ORG_ID = keccak256("KUBI");

    function setUp() public {
        // 1. Real Hats: fork Gnosis and bind the canonical deployment via the IHats interface.
        vm.createSelectFork("gnosis", FORK_BLOCK);
        hats = IHats(CANONICAL_HATS);

        // 2. EM + Toggle proxies (superAdmin/admin = deployer during bootstrap).
        toggle = ToggleModule(_proxy(address(new ToggleModule()), abi.encodeCall(ToggleModule.initialize, (deployer))));
        em = EligibilityModule(
            _proxy(
                address(new EligibilityModule()),
                abi.encodeCall(EligibilityModule.initialize, (deployer, address(hats), address(toggle)))
            )
        );
        toggle.setEligibilityModule(address(em));

        // 3. Top hat -> deployer, then ELIGIBILITY_ADMIN worn by the EM proxy.
        topHat = hats.mintTopHat(deployer, "ipfs://KUBI", "");
        adminHat = hats.createHat(topHat, "ELIGIBILITY_ADMIN", 1, address(em), address(toggle), true, "");
        em.setWearerEligibility(address(em), adminHat, true, true);
        toggle.setHatStatus(adminHat, true);
        hats.mintHat(adminHat, address(em));
        em.setEligibilityModuleAdminHat(adminHat);

        // 4. Executor (owner = deployer during bootstrap).
        executor = Executor(
            payable(_proxy(address(new Executor()), abi.encodeCall(Executor.initialize, (deployer, address(hats)))))
        );

        // 5. Base membership hat (default-eligible so members are freely mintable) + seed members.
        memberHat = _createHat("MEMBER", type(uint32).max, true, true);
        _mint(memberHat, alice);
        _mint(memberHat, bob);
        _mint(memberHat, carol);
        _mint(memberHat, ianthe);

        // 6. Sibling modules.
        pt = ParticipationToken(
            _proxy(
                address(new ParticipationToken()),
                abi.encodeCall(
                    ParticipationToken.initialize,
                    (address(executor), "Participation", "PT", address(hats), _arr(memberHat), _arr())
                )
            )
        );
        tm = TaskManager(
            _proxy(
                address(new TaskManager()),
                abi.encodeCall(
                    TaskManager.initialize, (address(pt), address(hats), _arr(), address(executor), address(0))
                )
            )
        );
        dd = DirectDemocracyVoting(
            _proxy(
                address(new DirectDemocracyVoting()),
                abi.encodeCall(
                    DirectDemocracyVoting.initialize,
                    (address(hats), address(executor), _arr(memberHat), _arr(), _addrArr(), THRESHOLD, DD_GLOBAL_QUORUM)
                )
            )
        );

        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](1);
        classes[0] = HybridVoting.ClassConfig({
            strategy: HybridVoting.ClassStrategy.ERC20_BAL,
            slicePct: 100,
            quadratic: false,
            minBalance: 0,
            asset: address(pt),
            hatIds: _arr()
        });
        hv = HybridVoting(
            _proxy(
                address(new HybridVoting()),
                abi.encodeCall(
                    HybridVoting.initialize,
                    (address(hats), address(executor), _arr(), _addrArr(), THRESHOLD, 0, classes)
                )
            )
        );

        // 7. RoleManager (seeds the base MEMBER hat as an existing role).
        rm = RoleManager(
            _proxy(
                address(new RoleManager()),
                abi.encodeCall(
                    RoleManager.initialize,
                    (IRoleManager.InitConfig({
                            executor: address(executor),
                            eligibilityModule: address(em),
                            hats: address(hats),
                            ddVoting: address(dd),
                            hybridVoting: address(hv),
                            taskManager: address(tm),
                            participationToken: address(pt),
                            educationHub: address(0),
                            quickJoin: address(0),
                            paymasterHub: address(0),
                            orgId: ORG_ID,
                            existingOrgHats: _arr(memberHat),
                            existingOrgHatNames: _strArr("Member")
                        }))
                )
            )
        );

        // 8. Scoped authority: EM.roleManager = RM (while deployer is still superAdmin).
        em.setRoleManager(address(rm));

        // 9. Wire configAdmins + PT minter + a DD-allowed target (as the Executor).
        vm.startPrank(address(executor));
        dd.setConfigAdmin(address(rm));
        hv.setConfigAdmin(address(rm));
        tm.setConfigAdmin(address(rm));
        pt.setConfigAdmin(address(rm));
        pt.setTaskManager(address(tm));
        dd.setConfig(DirectDemocracyVoting.ConfigKey.TARGET_ALLOWED, abi.encode(address(tm), true));
        vm.stopPrank();

        // 10. Hand off admin authority to governance (Executor), matching HatsTreeSetup.
        hats.transferHat(topHat, deployer, address(executor));
        em.transferSuperAdmin(address(executor));
        toggle.transferAdmin(address(executor));

        // 11. Executor's sole governor for the real-execute election test.
        executor.setCaller(deployer);
    }

    /*═══════════════════════════════ Scenario 1 ═══════════════════════════════*/
    /// createGroup + roles with shared wiring, grant to an in-org member, assert every wired surface.
    function testScenario1_CreateGroupRoleGrantAndPermissions() public {
        (uint256 groupId, uint256 marker, uint256 presRole, uint256 presHat,,) = _setupExecutives();

        // Grant President to alice (in-org): mints identity + marker directly.
        vm.prank(address(executor));
        rm.grantRole(presRole, alice);

        // Wears both identity + marker.
        assertTrue(hats.isWearerOfHat(alice, presHat), "alice wears President identity");
        assertTrue(hats.isWearerOfHat(alice, marker), "alice wears Executives marker");

        // TaskManager: _permMask honours the marker's CREATE mask. Executor creates a project with no
        // per-project role overrides, then alice (marker wearer, no creator hat, no PM) creates a task.
        bytes32 pid = _createProject();
        vm.prank(alice);
        tm.createTask(1e18, bytes("task"), bytes32("m"), pid, address(0), 0, false, 0, 0);

        // A non-marker in-org member cannot create (mask not honoured for them).
        vm.prank(bob);
        vm.expectRevert(TaskManager.Unauthorized.selector);
        tm.createTask(1e18, bytes("nope"), bytes32("m"), pid, address(0), 0, false, 0, 0);

        // HybridVoting: alice is a creator via the marker, so proposal creation is allowed.
        vm.prank(alice);
        hv.createProposal(bytes("hv"), bytes32("d"), 60, 2, _noBatch(), _arr());
        assertEq(hv.proposalsCount(), 1, "HV proposal created by marker-wearing creator");

        // Marker perms are visible on every module (subgraph-observable state).
        assertTrue(_hatIn(tm.getLensData(6, ""), marker), "marker in TM permission hats");
        assertTrue(_hatIn(abi.encode(dd.votingHats()), marker), "marker in DD voting hats");
        assertTrue(_hatIn(abi.encode(dd.creatorHats()), marker), "marker in DD creator hats");
        assertTrue(_hatIn(abi.encode(hv.creatorHats()), marker), "marker in HV creator hats");
        assertEq(pt.balanceOf(alice), 0, "sanity: no PT minted yet");
        assertGt(groupId, 0);
    }

    /*═══════════════════════════════ Scenario 2 ═══════════════════════════════*/
    /// Out-of-org grant => offer (zero balances) => claimHats([identity, marker]) in ONE tx.
    function testScenario2_OfferThenClaimHatsInOneCall() public {
        (, uint256 marker, uint256 presRole, uint256 presHat,,) = _setupExecutives();

        assertFalse(rm.isInOrg(dave), "dave starts out-of-org");

        vm.prank(address(executor));
        rm.grantRole(presRole, dave);

        // Offer only: nothing minted.
        assertEq(hats.balanceOf(dave, presHat), 0, "no identity minted on offer");
        assertEq(hats.balanceOf(dave, marker), 0, "no marker minted on offer");

        // PAYMASTER INVARIANT (PLAN 1.4c): isEligible is true pre-claim while balance stays 0 — the
        // onboarding-sponsorship semantic that lets dave's claim tx be gas-sponsored.
        assertTrue(hats.isEligible(dave, presHat), "isEligible true pre-claim for sponsorship");
        assertEq(hats.balanceOf(dave, presHat), 0, "still no balance pre-claim");

        // Accept: identity minted first in the array makes dave derived-eligible for the marker in the
        // SAME call — both minted in one tx.
        vm.prank(dave);
        em.claimHats(_arr2(presHat, marker));

        assertTrue(hats.isWearerOfHat(dave, presHat), "dave now wears identity");
        assertTrue(hats.isWearerOfHat(dave, marker), "dave now wears marker");
        assertTrue(rm.isInOrg(dave), "dave is now in-org");
    }

    /*═══════════════════════════════ Scenario 3 ═══════════════════════════════*/
    /// DD signal poll lowers quorum for execs-only; DD executable proposal floors quorum at max().
    function testScenario3a_DDSignalPollLowersQuorum() public {
        (, uint256 marker, uint256 presRole,,,) = _setupExecutives();
        vm.prank(address(executor));
        rm.grantRole(presRole, alice);

        // Non-executable restricted poll (empty batches), override 1 < global 2 -> effective = 1.
        uint256[] memory pollHats = _arr(marker);
        vm.prank(alice);
        dd.createProposalV2(bytes("execs-poll"), bytes32("d"), 60, 2, _noBatch(), pollHats, 1);
        uint256 id = dd.proposalsCount() - 1;
        assertEq(dd.proposalQuorumOverride(id), 1, "override recorded");

        // Only marker wearers may vote; a plain member is rejected.
        vm.prank(bob);
        vm.expectRevert(VotingErrors.RoleNotAllowed.selector);
        dd.vote(id, _u8(0), _u8(100));

        // The single exec voter meets the lowered quorum.
        vm.prank(alice);
        dd.vote(id, _u8(0), _u8(100));

        vm.warp(block.timestamp + 61 minutes);
        (uint256 winner, bool valid) = dd.announceWinner(id);
        assertTrue(valid, "lowered quorum honoured: poll valid with 1 exec");
        assertEq(winner, 0, "option 0 wins");
    }

    function testScenario3b_DDExecutableQuorumFloorsAtMax() public {
        (, uint256 marker, uint256 presRole,,,) = _setupExecutives();
        vm.prank(address(executor));
        rm.grantRole(presRole, alice);

        // Executable restricted proposal: option0 batch targets the allowed TaskManager; option1 empty.
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](2);
        batches[0] = new IExecutor.Call[](1);
        batches[0][0] = IExecutor.Call({target: address(tm), value: 0, data: abi.encodeWithSignature("nextTaskId()")});
        batches[1] = new IExecutor.Call[](0);

        vm.prank(alice);
        dd.createProposalV2(bytes("execs-exec"), bytes32("d"), 60, 2, batches, _arr(marker), 1);
        uint256 id = dd.proposalsCount() - 1;

        // Only alice votes: effective quorum = max(global=2, override=1) = 2 > 1 voter -> invalid (H-2).
        vm.prank(alice);
        dd.vote(id, _u8(0), _u8(100));
        vm.warp(block.timestamp + 61 minutes);
        (, bool valid) = dd.announceWinner(id);
        assertFalse(valid, "executable proposal cannot lower quorum below global (raise-only)");
    }

    function testScenario3c_HVEqualWeightNeutralisesTokenBalance() public {
        (, uint256 marker, uint256 presRole, uint256 presHat, uint256 vpRole, uint256 vpHat) = _setupExecutives();
        vm.startPrank(address(executor));
        rm.grantRole(presRole, alice);
        rm.grantRole(vpRole, bob);
        // Wildly different soulbound PT balances.
        pt.mint(alice, 1_000_000e18);
        pt.mint(bob, 1e18);
        vm.stopPrank();

        // equalWeight restricted poll: synthetic DIRECT class => one-person-one-vote (100 each). Two
        // execs vote OPPOSITE options with EQUAL power -> tie -> no strict-majority winner.
        vm.prank(alice);
        hv.createProposalV2(bytes("equal"), bytes32("d"), 60, 2, _noBatch(), _arr(marker), 0, true);
        uint256 id = hv.proposalsCount() - 1;
        vm.prank(alice);
        hv.vote(id, _u8(0), _u8(100));
        vm.prank(bob);
        hv.vote(id, _u8(1), _u8(100));
        vm.warp(block.timestamp + 61 minutes);
        (, bool validEqual) = hv.announceWinner(id);
        assertFalse(validEqual, "equalWeight: opposite votes tie despite the whale's balance");

        // Control: the SAME opposite votes on a NON-equalWeight proposal let the whale (alice) win,
        // proving equalWeight is what neutralised the balance.
        vm.prank(alice);
        hv.createProposalV2(bytes("weighted"), bytes32("d"), 60, 2, _noBatch(), _arr(marker), 0, false);
        uint256 id2 = hv.proposalsCount() - 1;
        vm.prank(alice);
        hv.vote(id2, _u8(0), _u8(100));
        vm.prank(bob);
        hv.vote(id2, _u8(1), _u8(100));
        vm.warp(block.timestamp + 61 minutes);
        (uint256 winner2, bool valid2) = hv.announceWinner(id2);
        assertTrue(valid2, "token-weighted proposal has a winner");
        assertEq(winner2, 0, "whale's option wins under token weighting");
        assertTrue(hats.isWearerOfHat(bob, vpHat) && hats.isWearerOfHat(bob, marker), "bob wears VP + marker");
        assertGt(presHat, 0);
    }

    /*═══════════════════════════════ Scenario 4 ═══════════════════════════════*/
    /// revokeRole zeroes the identity dynamically AND auto-zeroes the marker (last member role) — no
    /// burn call — while an exec who retains another member role keeps the marker.
    function testScenario4_RevokeDynamicRevocationAndRetention() public {
        (, uint256 marker, uint256 presRole, uint256 presHat, uint256 vpRole, uint256 vpHat) = _setupExecutives();
        vm.startPrank(address(executor));
        rm.grantRole(presRole, alice); // alice: President only
        rm.grantRole(presRole, bob); // bob: President ...
        rm.grantRole(vpRole, bob); // ... and VP
        vm.stopPrank();

        assertTrue(hats.isWearerOfHat(alice, marker), "alice wears marker pre-revoke");
        assertTrue(hats.isWearerOfHat(bob, marker), "bob wears marker pre-revoke");

        // Revoke alice's only member role: identity zeroes, and the marker auto-zeroes (derived) with
        // NO burn call on the marker.
        vm.prank(address(executor));
        rm.revokeRole(presRole, alice);
        assertEq(hats.balanceOf(alice, presHat), 0, "alice identity zeroed dynamically");
        assertEq(hats.balanceOf(alice, marker), 0, "alice marker auto-zeroed (no burn)");

        // Revoke bob's President: he still wears VP, so the marker is retained.
        vm.prank(address(executor));
        rm.revokeRole(presRole, bob);
        assertEq(hats.balanceOf(bob, presHat), 0, "bob President identity zeroed");
        assertTrue(hats.isWearerOfHat(bob, vpHat), "bob still wears VP");
        assertTrue(hats.isWearerOfHat(bob, marker), "bob retains marker via the VP member role");
    }

    /*═══════════════════════════════ Scenario 5 ═══════════════════════════════*/
    /// Bidirectional derived<->vouch guard, via both RoleManager wiring AND a direct EM call.
    function testScenario5a_GroupWiringVouchOnMarkerReverts() public {
        (uint256 groupId,,,,,) = _setupExecutives();
        // Turn on vouching in the group's shared wiring -> _applyWiring calls EM.configureVouching on
        // the marker, which already carries derived config -> revert.
        IRoleManager.RoleWiring memory w = _zeroWiring();
        w.vouchingEnabled = true;
        w.vouchQuorum = 2;
        w.vouchMembershipHatId = memberHat;
        vm.prank(address(executor));
        vm.expectRevert(EligibilityModule.DerivedConflictsWithVouch.selector);
        rm.setGroupWiring(groupId, w);
    }

    function testScenario5b_DirectEMDerivedOnVouchHatReverts() public {
        // Vouching enabled on the base member hat, then try to give it derived config directly -> revert.
        vm.startPrank(address(executor));
        em.configureVouching(memberHat, 2, memberHat, false);
        vm.expectRevert(EligibilityModule.DerivedConflictsWithVouch.selector);
        em.setGroupEligibility(memberHat, _arr(memberHat));
        vm.stopPrank();
    }

    /*═══════════════════════════════ Scenario 6 ═══════════════════════════════*/
    /// Adoption: register a legacy Executive hat (with wearers) as a marker, add a NEW President role,
    /// assert legacy wearers keep everything and the derived path only ADDS eligibility.
    function testScenario6_AdoptLegacyGroupAndRole() public {
        // Pre-create a legacy "Executive" hat (default-eligible, KUBI shape) with two wearers.
        // Created via EM as superAdmin (Executor) — flat child of the admin hat.
        uint256 legacyExec = _execCreateHat("Executive", 10, true, true);
        vm.startPrank(address(executor));
        em.mintHatToAddress(legacyExec, frank);
        em.mintHatToAddress(legacyExec, grace);
        vm.stopPrank();
        assertTrue(hats.isWearerOfHat(frank, legacyExec) && hats.isWearerOfHat(grace, legacyExec), "legacy wearers set");

        // Adopt: register a President identity role, then register the legacy hat as the group marker
        // listing President as a member role.
        vm.startPrank(address(executor));
        (uint256 presRole, uint256 presHat) = rm.createRole(
            IRoleManager.RoleParams({
                name: "President",
                metadataCID: bytes32(0),
                imageURI: "",
                maxSupply: 5,
                mutableHat: true,
                groupIds: _arr(),
                wiring: _zeroWiring(),
                initialGrants: _addrArr()
            })
        );
        uint256[] memory members = new uint256[](1);
        members[0] = presRole;
        (uint256 groupId) = rm.registerExistingGroup(legacyExec, "Executive", members);
        vm.stopPrank();
        assertGt(groupId, 0);

        // Legacy wearers keep the hat: adding derived config is additive, never subtractive.
        assertTrue(hats.isWearerOfHat(frank, legacyExec), "frank keeps legacy Executive");
        assertTrue(hats.isWearerOfHat(grace, legacyExec), "grace keeps legacy Executive");

        // The NEW derived path only ADDS: granting President to an in-org member mints the marker too.
        vm.prank(address(executor));
        rm.grantRole(presRole, alice);
        assertTrue(hats.isWearerOfHat(alice, presHat), "alice wears new President identity");
        assertTrue(hats.isWearerOfHat(alice, legacyExec), "alice gains the adopted marker via derived path");

        // Legacy wearer who does NOT hold President still wears the marker (default eligibility intact).
        assertFalse(hats.isWearerOfHat(frank, presHat), "frank never got the new role");
        assertTrue(hats.isWearerOfHat(frank, legacyExec), "legacy eligibility untouched by the derived add");
    }

    /*═══════════════════════════════ Scenario 7 ═══════════════════════════════*/
    /// Election as a single composed batch through the REAL Executor.execute.
    function testScenario7_ElectionBatchThroughRealExecutor() public {
        (, uint256 marker, uint256 presRole, uint256 presHat,,) = _setupExecutives();
        vm.prank(address(executor));
        rm.grantRole(presRole, alice); // incumbent

        // One atomic batch: revoke the loser, grant the winner.
        IExecutor.Call[] memory batch = new IExecutor.Call[](2);
        batch[0] = IExecutor.Call({
            target: address(rm), value: 0, data: abi.encodeCall(RoleManager.revokeRole, (presRole, alice))
        });
        batch[1] = IExecutor.Call({
            target: address(rm), value: 0, data: abi.encodeCall(RoleManager.grantRole, (presRole, ianthe))
        });
        assertLt(batch.length, executor.MAX_CALLS_PER_BATCH(), "batch fits comfortably under the cap");

        // Executed BY the real Executor (deployer is the sole allowedCaller / governor).
        vm.prank(deployer);
        executor.execute(uint256(1), batch);

        // Winner ends up wearing identity + marker; loser fully revoked.
        assertTrue(hats.isWearerOfHat(ianthe, presHat), "winner wears President identity");
        assertTrue(hats.isWearerOfHat(ianthe, marker), "winner wears the Executives marker");
        assertEq(hats.balanceOf(alice, presHat), 0, "loser identity revoked");
        assertEq(hats.balanceOf(alice, marker), 0, "loser marker auto-zeroed");
    }

    /*═══════════════════════════════ Scenario 8 ═══════════════════════════════*/
    /// Kick precedence: an explicit superAdmin ban on the marker beats derived membership even while
    /// the user still wears an identity hat.
    function testScenario8_SuperAdminKickBeatsDerived() public {
        (, uint256 marker, uint256 presRole, uint256 presHat,,) = _setupExecutives();
        vm.prank(address(executor));
        rm.grantRole(presRole, alice);
        assertTrue(hats.isWearerOfHat(alice, marker), "alice wears marker pre-kick");

        // superAdmin (Executor/governance) explicitly bans alice on the marker.
        vm.prank(address(executor));
        em.setWearerEligibility(alice, marker, false, false);

        assertTrue(hats.isWearerOfHat(alice, presHat), "alice still wears the identity hat");
        (bool eligible,) = em.getWearerStatus(alice, marker);
        assertFalse(eligible, "explicit kick overrides derived membership");
        assertEq(hats.balanceOf(alice, marker), 0, "marker balance forced to zero by the kick");
    }

    /*═════════════════════════════ Helpers ═════════════════════════════*/

    /// @dev Creates the "Executives" group (shared wiring on the marker: TM CREATE|BUDGET, DD
    ///      voter+creator, HV creator, PT member) plus President + VP identity roles inside it.
    function _setupExecutives()
        internal
        returns (uint256 groupId, uint256 marker, uint256 presRole, uint256 presHat, uint256 vpRole, uint256 vpHat)
    {
        IRoleManager.RoleWiring memory shared = _zeroWiring();
        shared.setTaskPerm = true;
        shared.taskPermMask = TaskPerm.CREATE | TaskPerm.BUDGET;
        shared.ddVoter = true;
        shared.ddCreator = true;
        shared.hvCreator = true;
        shared.ptMember = true;

        vm.startPrank(address(executor));
        (groupId, marker) = rm.createGroup("Executives", bytes32("cid"), "", _arr(), shared);
        (presRole, presHat) = rm.createRole(
            IRoleManager.RoleParams({
                name: "President",
                metadataCID: bytes32(0),
                imageURI: "",
                maxSupply: 5,
                mutableHat: true,
                groupIds: _arr(groupId),
                wiring: _zeroWiring(),
                initialGrants: _addrArr()
            })
        );
        (vpRole, vpHat) = rm.createRole(
            IRoleManager.RoleParams({
                name: "VP",
                metadataCID: bytes32(0),
                imageURI: "",
                maxSupply: 5,
                mutableHat: true,
                groupIds: _arr(groupId),
                wiring: _zeroWiring(),
                initialGrants: _addrArr()
            })
        );
        vm.stopPrank();
    }

    /// @dev Executor creates a project with NO per-project role overrides (so the global marker mask
    ///      governs), unlimited PT cap.
    function _createProject() internal returns (bytes32 pid) {
        TaskManager.BootstrapProjectConfig memory cfg = TaskManager.BootstrapProjectConfig({
            title: bytes("Project X"),
            metadataHash: bytes32("p"),
            cap: 0,
            managers: _addrArr(),
            createHats: _arr(),
            claimHats: _arr(),
            reviewHats: _arr(),
            assignHats: _arr(),
            bountyTokens: _addrArr(),
            bountyCaps: _arr()
        });
        vm.prank(address(executor));
        pid = tm.createProject(cfg);
    }

    /// @dev Create a hat as the (bootstrap) superAdmin = deployer, flat child of the admin hat.
    function _createHat(string memory name, uint32 maxSupply, bool defaultEligible, bool defaultStanding)
        internal
        returns (uint256 hatId)
    {
        hatId = em.createHatWithEligibility(
            EligibilityModule.CreateHatParams({
                parentHatId: adminHat,
                details: name,
                maxSupply: maxSupply,
                _mutable: true,
                imageURI: "",
                defaultEligible: defaultEligible,
                defaultStanding: defaultStanding,
                mintToAddresses: _addrArr(),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
        );
    }

    /// @dev Same as {_createHat} but under an active prank (superAdmin = Executor post-bootstrap).
    function _execCreateHat(string memory name, uint32 maxSupply, bool defaultEligible, bool defaultStanding)
        internal
        returns (uint256 hatId)
    {
        vm.prank(address(executor));
        hatId = em.createHatWithEligibility(
            EligibilityModule.CreateHatParams({
                parentHatId: adminHat,
                details: name,
                maxSupply: maxSupply,
                _mutable: true,
                imageURI: "",
                defaultEligible: defaultEligible,
                defaultStanding: defaultStanding,
                mintToAddresses: _addrArr(),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
        );
    }

    function _mint(uint256 hatId, address to) internal {
        em.mintHatToAddress(hatId, to);
    }

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function _zeroWiring() internal pure returns (IRoleManager.RoleWiring memory w) {
        w.hvClassIndexes = new uint8[](0);
    }

    /*──────── tiny array builders ────────*/
    function _arr() internal pure returns (uint256[] memory a) {
        a = new uint256[](0);
    }

    function _arr(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _arr2(uint256 x, uint256 y) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = x;
        a[1] = y;
    }

    function _addrArr() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _strArr(string memory s) internal pure returns (string[] memory a) {
        a = new string[](1);
        a[0] = s;
    }

    function _u8(uint8 x) internal pure returns (uint8[] memory a) {
        a = new uint8[](1);
        a[0] = x;
    }

    function _noBatch() internal pure returns (IExecutor.Call[][] memory b) {
        b = new IExecutor.Call[][](0);
    }

    /// @dev True if `hat` appears in an abi.encode(uint256[]) blob.
    function _hatIn(bytes memory encoded, uint256 hat) internal pure returns (bool) {
        uint256[] memory arr = abi.decode(encoded, (uint256[]));
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == hat) return true;
        }
        return false;
    }
}
