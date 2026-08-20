// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {Executor} from "../src/Executor.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {TaskPerm} from "../src/libs/TaskPerm.sol";

import {MembershipAuthorityProto} from "./mocks/MembershipAuthorityProto.sol";
import {CurrentPathHarness} from "./mocks/CurrentPathHarness.sol";

/**
 * @title AccessV2GasBenchProd
 * @notice ROUND-2 production-weight gas benchmark (pre-build gate for ACCESS-V2-SPEC.md v1.3, §3
 *         re-bench requirement). Round 1 ({AccessV2GasBench}) priced the collapsed-authority FLOOR
 *         with {NativeLedgerPrototype}. This measures the SAME current-path fixtures against
 *         {MembershipAuthorityProto} — which adds back the spec's production weight (ERC-1155
 *         events, pause+reentrancy guards, scoped access matrix, memberCount/maxMembers, caps, the
 *         §3 inverted-fold hasPerm with the ctx∪global union, the §4 pending-action delegation
 *         model, and the IHats read-subset). It then measures the genuinely-new spec operations the
 *         round-1 table did not cover.
 *
 *         Current side = REAL forked Gnosis Hats + real EligibilityModule/EligibilityLogic + real
 *         RoleManager, wired exactly as {RoleManagerIntegration.t.sol}. Numbers are default-profile
 *         (optimizer OFF, repo test convention) — production optimizer shrinks both sides; direction
 *         holds. Warm = repeat call (warmed slots); cold = first slot touch.
 */
contract AccessV2GasBenchProd is Test {
    address internal constant CANONICAL_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    uint256 internal constant FORK_BLOCK = 47_700_000;

    /*──────── real contracts ────────*/
    IHats internal hats;
    EligibilityModule internal em;
    ToggleModule internal toggle;
    Executor internal executor;
    RoleManager internal rm;
    ParticipationToken internal pt;
    TaskManager internal tm;

    /*──────── prototype + harness ────────*/
    MembershipAuthorityProto internal auth;
    CurrentPathHarness internal harness;

    /*──────── hats (current side) ────────*/
    uint256 internal topHat;
    uint256 internal adminHat;
    uint256 internal memberHat;
    uint256 internal explicitRoleHat;
    uint256[5] internal groupMembers;
    uint256 internal marker1;
    uint256 internal marker3;
    uint256 internal marker5;
    uint256[10] internal voteHats;
    uint256 internal permHatA;
    uint256 internal permHatB;
    uint256 internal presRole;
    uint256 internal presHat;
    uint256 internal groupId;
    uint256 internal marker;

    /*──────── authority subjects ────────*/
    uint256 internal aRoleExplicit;
    uint256[5] internal aGroupMembers;
    uint256 internal aMarker1;
    uint256 internal aMarker3;
    uint256 internal aMarker5;
    uint256[10] internal aVoteSubjects;
    uint256 internal aPermRole;
    uint256 internal aPresRole; // lifecycle grant/remove
    uint256 internal aOfferRole; // claim (offer-accept)
    uint256 internal aDelegRole; // delegated grant via pending
    uint256 internal aManagerRole; // manager subject for delegation
    uint256 internal aReconRole; // reconcile

    // fan-out fixtures (§3): 16 frank-roles + 16 groups(GroupSizeLimit=16, distinct fillers per group).
    uint256[16] internal fanRoles;
    uint256[16] internal fanGroups;
    bytes32 internal constant PK_F2 = bytes32(uint256(0x01) << 248 | 0xF2); // OR-tag
    bytes32 internal constant PK_F8 = bytes32(uint256(0x01) << 248 | 0xF8);
    bytes32 internal constant PK_F32 = bytes32(uint256(0x01) << 248 | 0x32);
    bytes32 internal constant FAN_CTX = bytes32("project-7");

    /*──────── actors ────────*/
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave"); // manager member (delegation actor)
    address internal erin = makeAddr("erin"); // offer/claim target
    address internal frank = makeAddr("frank"); // fan-out subject (holds exactly the 16 fan-roles = cap)

    bytes32 internal constant ORG_ID = keccak256("BENCH2");
    bytes32 internal constant PERM_KEY = bytes32(uint256(0x01) << 248 | 0x7A); // OR-tag TASK key
    bytes32 internal constant PID = bytes32("proj");

    bool internal bSink;
    uint256 internal uSink;
    uint64 internal tSink;

    function setUp() public {
        vm.createSelectFork("gnosis", FORK_BLOCK);
        hats = IHats(CANONICAL_HATS);

        toggle = ToggleModule(_proxy(address(new ToggleModule()), abi.encodeCall(ToggleModule.initialize, (deployer))));
        em = EligibilityModule(
            _proxy(
                address(new EligibilityModule()),
                abi.encodeCall(EligibilityModule.initialize, (deployer, address(hats), address(toggle)))
            )
        );
        toggle.setEligibilityModule(address(em));

        topHat = hats.mintTopHat(deployer, "ipfs://bench", "");
        adminHat = hats.createHat(topHat, "ELIGIBILITY_ADMIN", 1, address(em), address(toggle), true, "");
        em.setWearerEligibility(address(em), adminHat, true, true);
        toggle.setHatStatus(adminHat, true);
        hats.mintHat(adminHat, address(em));
        em.setEligibilityModuleAdminHat(adminHat);

        executor = Executor(
            payable(_proxy(address(new Executor()), abi.encodeCall(Executor.initialize, (deployer, address(hats)))))
        );

        memberHat = _createHat("MEMBER", type(uint32).max, true, true);
        _mint(memberHat, alice);
        _mint(memberHat, bob);
        _mint(memberHat, carol);

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
        rm = RoleManager(
            _proxy(
                address(new RoleManager()),
                abi.encodeCall(
                    RoleManager.initialize,
                    (IRoleManager.InitConfig({
                            executor: address(executor),
                            eligibilityModule: address(em),
                            hats: address(hats),
                            ddVoting: address(0),
                            hybridVoting: address(0),
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
        em.setRoleManager(address(rm));

        vm.startPrank(address(executor));
        tm.setConfigAdmin(address(rm));
        pt.setConfigAdmin(address(rm));
        pt.setTaskManager(address(tm));
        vm.stopPrank();

        hats.transferHat(topHat, deployer, address(executor));
        em.transferSuperAdmin(address(executor));
        toggle.transferAdmin(address(executor));

        _setupCurrentFixtures();

        auth = new MembershipAuthorityProto();
        auth.initialize(deployer); // deployer acts as the org Executor (root by address)
        _setupAuthorityFixtures();
    }

    /*═════════════════════════════════ current-path fixtures (verbatim round-1) ═════════════════════════════════*/

    function _setupCurrentFixtures() internal {
        vm.startPrank(address(executor));
        explicitRoleHat = _execHat("President-Explicit", 100, false, false);
        em.setWearerEligibility(alice, explicitRoleHat, true, true);
        em.mintHatToAddress(explicitRoleHat, alice);

        for (uint256 i; i < 5; ++i) {
            groupMembers[i] = _execHat(string.concat("GM", vm.toString(i)), type(uint32).max, true, true);
        }
        em.mintHatToAddress(groupMembers[4], alice);

        marker1 = _execHat("Marker1", type(uint32).max, false, false);
        marker3 = _execHat("Marker3", type(uint32).max, false, false);
        marker5 = _execHat("Marker5", type(uint32).max, false, false);

        uint256[] memory l1 = new uint256[](1);
        l1[0] = groupMembers[4];
        uint256[] memory l3 = new uint256[](3);
        l3[0] = groupMembers[0];
        l3[1] = groupMembers[1];
        l3[2] = groupMembers[4];
        uint256[] memory l5 = new uint256[](5);
        for (uint256 i; i < 4; ++i) {
            l5[i] = groupMembers[i];
        }
        l5[4] = groupMembers[4];
        em.setGroupEligibility(marker1, l1);
        em.setGroupEligibility(marker3, l3);
        em.setGroupEligibility(marker5, l5);
        em.mintHatToAddress(marker1, alice);
        em.mintHatToAddress(marker3, alice);
        em.mintHatToAddress(marker5, alice);

        for (uint256 i; i < 10; ++i) {
            voteHats[i] = _execHat(string.concat("Vote", vm.toString(i)), type(uint32).max, true, true);
        }
        em.mintHatToAddress(voteHats[9], alice);

        permHatA = _execHat("PermA", type(uint32).max, true, true);
        permHatB = _execHat("PermB", type(uint32).max, true, true);
        em.mintHatToAddress(permHatA, alice);
        em.mintHatToAddress(permHatB, alice);
        vm.stopPrank();

        vm.startPrank(address(executor));
        IRoleManager.RoleWiring memory shared = _zeroWiring();
        shared.setTaskPerm = true;
        shared.taskPermMask = TaskPerm.CREATE | TaskPerm.BUDGET;
        (groupId, marker) = rm.createGroup("Executives", bytes32("cid"), "", _arr(), shared);
        (presRole, presHat) = rm.createRole(
            IRoleManager.RoleParams({
                name: "President",
                metadataCID: bytes32(0),
                imageURI: "",
                maxSupply: 50,
                mutableHat: true,
                groupIds: _arr(groupId),
                wiring: _zeroWiring(),
                initialGrants: _addrArr()
            })
        );
        vm.stopPrank();

        harness = new CurrentPathHarness(hats);
        harness.setPermissionHat(permHatA, uint8(TaskPerm.CREATE));
        harness.setPermissionHat(permHatB, uint8(TaskPerm.BUDGET));
    }

    /*═════════════════════════════════ authority fixtures ═════════════════════════════════*/

    function _setupAuthorityFixtures() internal {
        // #1 explicit-rule member (deny-default role + governance grant).
        aRoleExplicit = auth.registerSubject(1, "President-Explicit", bytes32(0), "", 100);
        auth.grant(aRoleExplicit, alice);

        // #2 derived groups. 5 member roles; alice member of ONLY aGroupMembers[4]. Markers are GROUP subjects.
        for (uint256 i; i < 5; ++i) {
            aGroupMembers[i] = auth.registerSubject(1, string.concat("AGM", vm.toString(i)), bytes32(0), "", 0);
        }
        auth.grant(aGroupMembers[4], alice);

        aMarker1 = auth.registerSubject(2, "AMarker1", bytes32(0), "", 0);
        aMarker3 = auth.registerSubject(2, "AMarker3", bytes32(0), "", 0);
        aMarker5 = auth.registerSubject(2, "AMarker5", bytes32(0), "", 0);
        // worst case: alice's member role (aGroupMembers[4]) is LAST in each list.
        uint256[] memory m1 = new uint256[](1);
        m1[0] = aGroupMembers[4];
        uint256[] memory m3 = new uint256[](3);
        m3[0] = aGroupMembers[0];
        m3[1] = aGroupMembers[1];
        m3[2] = aGroupMembers[4];
        uint256[] memory m5 = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            m5[i] = aGroupMembers[i];
        }
        auth.setGroupComposition(aMarker1, m1);
        auth.setGroupComposition(aMarker3, m3);
        auth.setGroupComposition(aMarker5, m5);

        // #3 vote subjects: 10; alice member of ONLY the last.
        for (uint256 i; i < 10; ++i) {
            aVoteSubjects[i] = auth.registerSubject(1, string.concat("AVote", vm.toString(i)), bytes32(0), "", 0);
        }
        auth.grant(aVoteSubjects[9], alice);

        // #4 perm role: alice member + global perm word.
        aPermRole = auth.registerSubject(1, "APerm", bytes32(0), "", 0);
        auth.grant(aPermRole, alice);
        auth.setPerm(aPermRole, PERM_KEY, bytes32(0), TaskPerm.CREATE | TaskPerm.BUDGET, false);

        // #5 lifecycle grant/remove subject (carol).
        aPresRole = auth.registerSubject(1, "APresident", bytes32(0), "", 50);

        // new: offer/claim (erin), delegated grant (dave→erin), reconcile.
        aOfferRole = auth.registerSubject(1, "AOffer", bytes32(0), "", 50);
        aManagerRole = auth.registerSubject(1, "AManager", bytes32(0), "", 50);
        auth.grant(aManagerRole, dave); // dave is a manager-subject member
        aDelegRole = auth.registerSubject(1, "ADeleg", bytes32(0), "", 50);
        auth.setManagerConfig(aDelegRole, aManagerRole, type(uint256).max, 1 days);
        aReconRole = auth.registerSubject(1, "ARecon", bytes32(0), "", 50);
        auth.setDefault(aReconRole, true); // default-ALLOW: bob self-claims (no explicit rule) so a
        vm.prank(bob); //                    later default ALLOW→DENY flip actually lapses him.
        auth.claimOpen(aReconRole);

        _setupFanout();
    }

    /// @dev §3 fan-out: 16 frank-roles + 16 groups (each GroupSizeLimit=16: 15 distinct filler roles
    ///      frank is NOT in + one frank-role LAST = worst-case 16-probe derivation). Distinct fillers
    ///      per group respect the 8-groups-per-role cap. Three perm keys select union sub-slices of
    ///      2 / 8 / 32 at the FAN_CTX project ctx (ctx-list ∪ global-list, deduped).
    function _setupFanout() internal {
        for (uint256 i; i < 16; ++i) {
            fanRoles[i] = auth.registerSubject(1, string.concat("FanR", vm.toString(i)), bytes32(0), "", 0);
            auth.grant(fanRoles[i], frank); // 16 roles → frank at the RoleLimit cap exactly
        }
        for (uint256 i; i < 16; ++i) {
            fanGroups[i] = auth.registerSubject(2, string.concat("FanG", vm.toString(i)), bytes32(0), "", 0);
            uint256[] memory mem = new uint256[](16);
            for (uint256 j; j < 15; ++j) {
                mem[j] = auth.registerSubject(
                    1, string.concat("Fill", vm.toString(i), "_", vm.toString(j)), bytes32(0), "", 0
                ); // distinct filler frank is NOT a member of
            }
            mem[15] = fanRoles[i]; // frank's role LAST → full 16-probe worst-case derivation
            auth.setGroupComposition(fanGroups[i], mem);
        }
        // perm entries: ROLE subjects → GLOBAL (ctx 0); GROUP subjects → FAN_CTX (inherit=true, combine).
        // PK_F2: 1 role global + 1 group ctx = union 2.
        auth.setPerm(fanRoles[0], PK_F2, bytes32(0), TaskPerm.CREATE, false);
        auth.setPerm(fanGroups[0], PK_F2, FAN_CTX, TaskPerm.BUDGET, true);
        // PK_F8: 4 roles global + 4 groups ctx = union 8.
        for (uint256 i; i < 4; ++i) {
            auth.setPerm(fanRoles[i], PK_F8, bytes32(0), TaskPerm.CREATE, false);
            auth.setPerm(fanGroups[i], PK_F8, FAN_CTX, TaskPerm.BUDGET, true);
        }
        // PK_F32: 16 roles global + 16 groups ctx = union 32 (both at the PermFanoutLimit cap).
        for (uint256 i; i < 16; ++i) {
            auth.setPerm(fanRoles[i], PK_F32, bytes32(0), TaskPerm.CREATE, false);
            auth.setPerm(fanGroups[i], PK_F32, FAN_CTX, TaskPerm.BUDGET, true);
        }
    }

    /*═════════════════════════════════════ THE BENCHMARK ═════════════════════════════════════*/

    function testAccessV2GasBenchProd() public {
        console2.log("");
        console2.log("=== ACCESS V2 PROD-WEIGHT GAS BENCH (cold = first slot touch, warm = repeat) ===");

        // round-1-comparable rows: current vs production-weight authority.
        (uint256 c1c, uint256 c1w) = _measIsWearer(alice, explicitRoleHat);
        (uint256 p1c, uint256 p1w) = _measIsMember(aRoleExplicit, alice);
        _row("1 single-check (explicit)", c1c, c1w, p1c, p1w);

        (uint256 c2c, uint256 c2w) = _measIsWearer(alice, marker1);
        (uint256 p2c, uint256 p2w) = _measIsMember(aMarker1, alice);
        _row("2 group derived n=1", c2c, c2w, p2c, p2w);

        (uint256 c3c, uint256 c3w) = _measIsWearer(alice, marker3);
        (uint256 p3c, uint256 p3w) = _measIsMember(aMarker3, alice);
        _row("2 group derived n=3", c3c, c3w, p3c, p3w);

        (uint256 c4c, uint256 c4w) = _measIsWearer(alice, marker5);
        (uint256 p4c, uint256 p4w) = _measIsMember(aMarker5, alice);
        _row("2 group derived n=5", c4c, c4w, p4c, p4w);

        _benchVote(2);
        _benchVote(5);
        _benchVote(10);

        (uint256 c5c, uint256 c5w) = _measPermMask(alice, PID);
        (uint256 p5c, uint256 p5w) = _measHasPermGlobal(aPermRole, PERM_KEY, alice);
        _row("4 permMask(2) / hasPerm(1 subj)", c5c, c5w, p5c, p5w);

        // lifecycle grant + remove(soft) vs current grant/revoke.
        uint256 cGrant = _measRmGrant(presRole, bob);
        uint256 cRevoke = _measRmRevoke(presRole, bob);
        uint256 aGrant = _measAuthGrant(aPresRole, carol);
        uint256 aRemove = _measAuthRemoveSoft(aPresRole, carol);
        console2.log("5 grantRole   | current:", cGrant, "| authority:", aGrant);
        console2.log("5 revoke/remove| current:", cRevoke, "| authority:", aRemove);

        console2.log("--- NEW spec ops (authority only; no current-path equivalent) ---");

        // §3 hasPerm at the three fan-outs (ctx∪global union; mix role+group; groups at GroupSizeLimit).
        // frank is a member of every fan-out subject (16 roles = RoleLimit cap; groups derive via them).
        (uint256 f2c, uint256 f2w) = _measHasPermCtx(frank, PK_F2, FAN_CTX);
        (uint256 f8c, uint256 f8w) = _measHasPermCtx(frank, PK_F8, FAN_CTX);
        (uint256 f32c, uint256 f32w) = _measHasPermCtx(frank, PK_F32, FAN_CTX);
        _protoRow("hasPerm fan-out 2  (1 role +1 grp)", f2c, f2w);
        _protoRow("hasPerm fan-out 8  (4 role +4 grp)", f8c, f8w);
        _protoRow("hasPerm fan-out 32 (16role+16grp)", f32c, f32w);

        // §3 activeMemberSince (DD-style gate read): subject variant + key-folded variant.
        (uint256 s1c, uint256 s1w) = _measAmsSubject(aVoteSubjects[9], alice);
        (uint256 s2c, uint256 s2w) = _measAmsKey(frank, PK_F32, FAN_CTX);
        _protoRow("activeMemberSince(subject)", s1c, s1w);
        _protoRow("activeMemberSince(user,key,ctx) f32", s2c, s2w);

        // §4 delegated grant via pending create + finalize.
        uint256 gCreate = _measDelegCreate(ACT_GRANT(), aDelegRole, erin);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 gFinal = _measFinalize(_lastPending());
        console2.log("delegated grant createPending :", gCreate);
        console2.log("delegated grant finalize       :", gFinal);

        // §4 claim (offer-accept): governance offer creates a pending (delay 0), claim finalizes it.
        uint256 oCreate = _measOffer(aOfferRole, erin);
        uint256 pidClaim = _lastPending();
        uint256 cl = _measClaim(pidClaim, erin);
        console2.log("offer (create pending)         :", oCreate);
        console2.log("claim (offer-accept finalize)  :", cl);

        // §2 reconcile: flip default ALLOW→DENY for aReconRole so bob lapses, then reconcile.
        vm.prank(deployer);
        auth.setDefault(aReconRole, false);
        uint256 rc = _measReconcile(aReconRole, bob);
        console2.log("reconcile (lapsed member)      :", rc);

        console2.log("=== END ===");

        // Correctness (post-measurement so it does not pre-warm priced slots).
        assertTrue(auth.isMember(aRoleExplicit, alice), "auth #1");
        assertTrue(auth.isMember(aMarker5, alice), "auth marker5 derived");
        assertEq(auth.hasPerm(alice, PERM_KEY, bytes32(0)), TaskPerm.CREATE | TaskPerm.BUDGET, "hasPerm global");
        // fan-out fold: roles contribute CREATE, groups contribute BUDGET → OR = CREATE|BUDGET.
        assertEq(auth.hasPerm(frank, PK_F32, FAN_CTX), TaskPerm.CREATE | TaskPerm.BUDGET, "hasPerm f32 fold");
        assertEq(auth.hasPerm(frank, PK_F2, FAN_CTX), TaskPerm.CREATE | TaskPerm.BUDGET, "hasPerm f2 fold");
        // §3 unit case: a GLOBAL-only subject contributes at a project ctx (fanRoles[i] are global-only).
        assertTrue(auth.hasPerm(frank, PK_F32, FAN_CTX) & TaskPerm.CREATE != 0, "global-only contributes at ctx");
        // §3 fan-out cap sanity: 16 subjects per (key,ctx) on both arms → union 32.
        assertEq(auth.subjectsWithKeyLen(PK_F32, bytes32(0)), 16, "global list at cap");
        assertEq(auth.subjectsWithKeyLen(PK_F32, FAN_CTX), 16, "ctx list at cap");
        // activation gate.
        assertTrue(auth.activeMemberSince(aVoteSubjects[9], alice) != type(uint64).max, "ams member");
        assertEq(auth.activeMemberSince(aVoteSubjects[0], alice), type(uint64).max, "ams non-member sentinel");
        // delegated grant landed; offer-accept landed.
        assertTrue(auth.isMember(aDelegRole, erin), "delegated grant finalized");
        assertTrue(auth.isMember(aOfferRole, erin), "offer-accept claimed");
        // reconcile evicted the lapsed member.
        assertFalse(auth.isMember(aReconRole, bob), "reconciled out");
    }

    /*──────── vote-path bench ────────*/
    function _benchVote(uint256 n) internal {
        uint256[] memory cur = new uint256[](n);
        uint256[] memory pro = new uint256[](n);
        for (uint256 i; i < n - 1; ++i) {
            cur[i] = voteHats[i];
            pro[i] = aVoteSubjects[i];
        }
        cur[n - 1] = voteHats[9];
        pro[n - 1] = aVoteSubjects[9];

        harness.setVotingHats(cur);
        (uint256 cc, uint256 cw) = _measHasAnyHat(alice);
        (uint256 pc, uint256 pw) = _measHasAnyMember(pro, alice);
        if (n == 2) _row("3 hasAnyHat/Member n=2", cc, cw, pc, pw);
        else if (n == 5) _row("3 hasAnyHat/Member n=5", cc, cw, pc, pw);
        else _row("3 hasAnyHat/Member n=10", cc, cw, pc, pw);
    }

    /*═════════════════════════════════════ measurement helpers ═════════════════════════════════════*/

    function _measIsWearer(address u, uint256 h) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = hats.isWearerOfHat(u, h);
        cold = g - gasleft();
        g = gasleft();
        r = hats.isWearerOfHat(u, h);
        warm = g - gasleft();
        bSink = r;
    }

    function _measIsMember(uint256 s, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = auth.isMember(s, u);
        cold = g - gasleft();
        g = gasleft();
        r = auth.isMember(s, u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measHasAnyHat(address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = harness.hasAnyHat(u);
        cold = g - gasleft();
        g = gasleft();
        r = harness.hasAnyHat(u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measHasAnyMember(uint256[] memory s, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = auth.hasAnyMember(s, u);
        cold = g - gasleft();
        g = gasleft();
        r = auth.hasAnyMember(s, u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measPermMask(address u, bytes32 pid) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint8 r = harness.permMask(u, pid);
        cold = g - gasleft();
        g = gasleft();
        r = harness.permMask(u, pid);
        warm = g - gasleft();
        uSink = r;
    }

    function _measHasPermGlobal(uint256, bytes32 k, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint256 r = auth.hasPerm(u, k, bytes32(0));
        cold = g - gasleft();
        g = gasleft();
        r = auth.hasPerm(u, k, bytes32(0));
        warm = g - gasleft();
        uSink = r;
    }

    function _measHasPermCtx(address u, bytes32 k, bytes32 ctx) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint256 r = auth.hasPerm(u, k, ctx);
        cold = g - gasleft();
        g = gasleft();
        r = auth.hasPerm(u, k, ctx);
        warm = g - gasleft();
        uSink = r;
    }

    function _measAmsSubject(uint256 s, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint64 r = auth.activeMemberSince(s, u);
        cold = g - gasleft();
        g = gasleft();
        r = auth.activeMemberSince(s, u);
        warm = g - gasleft();
        tSink = r;
    }

    function _measAmsKey(address u, bytes32 k, bytes32 ctx) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint64 r = auth.activeMemberSince(u, k, ctx);
        cold = g - gasleft();
        g = gasleft();
        r = auth.activeMemberSince(u, k, ctx);
        warm = g - gasleft();
        tSink = r;
    }

    function _measRmGrant(uint256 role, address u) internal returns (uint256 used) {
        vm.prank(address(executor));
        uint256 g = gasleft();
        rm.grantRole(role, u);
        used = g - gasleft();
    }

    function _measRmRevoke(uint256 role, address u) internal returns (uint256 used) {
        vm.prank(address(executor));
        uint256 g = gasleft();
        rm.revokeRole(role, u);
        used = g - gasleft();
    }

    function _measAuthGrant(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        auth.grant(s, u);
        used = g - gasleft();
    }

    function _measAuthRemoveSoft(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        auth.remove(s, u, false);
        used = g - gasleft();
    }

    function _measDelegCreate(uint8 action, uint256 s, address u) internal returns (uint256 used) {
        vm.prank(dave);
        uint256 g = gasleft();
        auth.createPending(action, s, u);
        used = g - gasleft();
    }

    function _measFinalize(uint256 pid) internal returns (uint256 used) {
        uint256 g = gasleft();
        auth.finalize(pid);
        used = g - gasleft();
    }

    function _measOffer(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        auth.offer(s, u);
        used = g - gasleft();
    }

    function _measClaim(uint256 pid, address u) internal returns (uint256 used) {
        vm.prank(u);
        uint256 g = gasleft();
        auth.claim(pid);
        used = g - gasleft();
    }

    function _measReconcile(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        auth.reconcile(s, u);
        used = g - gasleft();
    }

    /*═════════════════════════════════════ printing ═════════════════════════════════════*/

    function _row(string memory op, uint256 cc, uint256 cw, uint256 pc, uint256 pw) internal pure {
        console2.log(op);
        console2.log("   current   cold/warm:", cc, cw);
        console2.log("   authority cold/warm:", pc, pw);
    }

    function _protoRow(string memory op, uint256 pc, uint256 pw) internal pure {
        console2.log(op);
        console2.log("   authority cold/warm:", pc, pw);
    }

    /*═════════════════════════════════════ small helpers ═════════════════════════════════════*/

    function ACT_GRANT() internal pure returns (uint8) {
        return 1;
    }

    function _lastPending() internal view returns (uint256) {
        return auth.pendingSeqView();
    }

    /*═════════════════════════════════════ setup helpers ═════════════════════════════════════*/

    function _createHat(string memory name, uint32 maxSupply, bool defElig, bool defStand)
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
                defaultEligible: defElig,
                defaultStanding: defStand,
                mintToAddresses: _addrArr(),
                wearerEligibleFlags: new bool[](0),
                wearerStandingFlags: new bool[](0)
            })
        );
    }

    function _execHat(string memory name, uint32 maxSupply, bool defElig, bool defStand)
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
                defaultEligible: defElig,
                defaultStanding: defStand,
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

    function _arr() internal pure returns (uint256[] memory a) {
        a = new uint256[](0);
    }

    function _arr(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _addrArr() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _strArr(string memory s) internal pure returns (string[] memory a) {
        a = new string[](1);
        a[0] = s;
    }
}
