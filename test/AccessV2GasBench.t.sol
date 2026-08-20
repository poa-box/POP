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

import {NativeLedgerPrototype} from "./mocks/NativeLedgerPrototype.sol";
import {CurrentPathHarness} from "./mocks/CurrentPathHarness.sol";

/**
 * @title AccessV2GasBench
 * @notice Head-to-head gas benchmark for the "remove Hats + unified authority" decision
 *         (.context/rolemanager/blank-slate-review.md, PLAN.md). Measures five hot paths against the
 *         REAL contracts wired as today (real forked Hats + real EligibilityModule/EligibilityLogic +
 *         real RoleManager) and the same five against {NativeLedgerPrototype}, a single collapsed
 *         authority. All numbers are printed as a markdown table (see test log) and land in the report.
 *
 *         Real Hats: forked from Gnosis via the canonical deployment (same approach as
 *         RoleManagerIntegration.t.sol; Hats.sol is never compiled locally — its batchCreateHats
 *         assembly stack-overflows under the optimizer-off default profile).
 */
contract AccessV2GasBench is Test {
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
    NativeLedgerPrototype internal proto;
    CurrentPathHarness internal harness;

    /*──────── hats ────────*/
    uint256 internal topHat;
    uint256 internal adminHat;
    uint256 internal memberHat;
    uint256 internal explicitRoleHat; // #1: explicit-rule wearer
    uint256[5] internal groupMembers; // gm[0..4], alice wears only gm[4]
    uint256 internal marker1; // derived list len 1
    uint256 internal marker3; // derived list len 3 (worst case: last)
    uint256 internal marker5; // derived list len 5 (worst case: last)
    uint256[10] internal voteHats; // alice wears only voteHats[last-in-array]
    uint256 internal permHatA;
    uint256 internal permHatB;
    uint256 internal presRole;
    uint256 internal presHat;
    uint256 internal groupId;
    uint256 internal marker;

    /*──────── prototype subjects ────────*/
    uint256 internal pRoleExplicit; // #6
    uint256[5] internal pGroupMembers;
    uint256 internal pMarker1;
    uint256 internal pMarker3;
    uint256 internal pMarker5;
    uint256[10] internal pVoteSubjects;
    uint256 internal pPermRole; // #9
    uint256 internal pPresRole; // #10 lifecycle

    /*──────── actors ────────*/
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob"); // fresh in-org member for grant/revoke
    address internal carol = makeAddr("carol");

    uint8 internal constant THRESHOLD = 50;
    bytes32 internal constant ORG_ID = keccak256("BENCH");
    bytes32 internal constant PERM_KEY = keccak256("TASK");
    bytes32 internal constant PID = bytes32("proj");

    /*──────── blackholes (keep measured returns live) ────────*/
    bool internal bSink;
    uint256 internal uSink;

    function setUp() public {
        vm.createSelectFork("gnosis", FORK_BLOCK);
        hats = IHats(CANONICAL_HATS);

        // EM + Toggle
        toggle = ToggleModule(_proxy(address(new ToggleModule()), abi.encodeCall(ToggleModule.initialize, (deployer))));
        em = EligibilityModule(
            _proxy(
                address(new EligibilityModule()),
                abi.encodeCall(EligibilityModule.initialize, (deployer, address(hats), address(toggle)))
            )
        );
        toggle.setEligibilityModule(address(em));

        // Hat tree
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

        // PT + TM (needed for RoleManager wiring fan-out on grant)
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

        // Hand off admin authority to governance (Executor).
        hats.transferHat(topHat, deployer, address(executor));
        em.transferSuperAdmin(address(executor));
        toggle.transferAdmin(address(executor));

        _setupCurrentFixtures();

        // ── Prototype ──
        proto = new NativeLedgerPrototype();
        // authorityAdmin = this test (acts as governance), roleManager = this test too so provenance
        // path is exercised on grant; a real deploy would separate them.
        proto.initialize(deployer, deployer);
        _setupPrototypeFixtures();
    }

    /*═════════════════════════════════ current-path fixtures ═════════════════════════════════*/

    function _setupCurrentFixtures() internal {
        vm.startPrank(address(executor));

        // #1 explicit-rule wearer: default-INELIGIBLE hat, explicit (true,true) rule for alice, minted.
        explicitRoleHat = _execHat("President-Explicit", 100, false, false);
        em.setWearerEligibility(alice, explicitRoleHat, true, true);
        em.mintHatToAddress(explicitRoleHat, alice);

        // #2 derived markers. 5 member hats (default-eligible); alice wears ONLY groupMembers[4].
        for (uint256 i; i < 5; ++i) {
            groupMembers[i] = _execHat(string.concat("GM", vm.toString(i)), type(uint32).max, true, true);
        }
        em.mintHatToAddress(groupMembers[4], alice);

        // marker hats are default-INELIGIBLE; eligibility comes ONLY from the derived list.
        marker1 = _execHat("Marker1", type(uint32).max, false, false);
        marker3 = _execHat("Marker3", type(uint32).max, false, false);
        marker5 = _execHat("Marker5", type(uint32).max, false, false);

        // Worst case: matching member is LAST in the list.
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
        // alice is derived-eligible for all three markers (wears gm[4]) → mint so she actually wears them.
        em.mintHatToAddress(marker1, alice);
        em.mintHatToAddress(marker3, alice);
        em.mintHatToAddress(marker5, alice);

        // #3 DD vote hot path arrays: 10 distinct default-eligible hats; alice wears ONLY the last.
        for (uint256 i; i < 10; ++i) {
            voteHats[i] = _execHat(string.concat("Vote", vm.toString(i)), type(uint32).max, true, true);
        }
        em.mintHatToAddress(voteHats[9], alice); // last of the 10-array; arrays below reuse the tail

        // #4 perm hats: 2 permission hats, alice wears BOTH (worst case, both masks OR'd).
        permHatA = _execHat("PermA", type(uint32).max, true, true);
        permHatB = _execHat("PermB", type(uint32).max, true, true);
        em.mintHatToAddress(permHatA, alice);
        em.mintHatToAddress(permHatB, alice);

        vm.stopPrank();

        // #5 lifecycle: an Executives group + President role, granted/revoked to bob (in-org member).
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

        // harness (real HatManager + verbatim _permMask over real Hats)
        harness = new CurrentPathHarness(hats);
        harness.setPermissionHat(permHatA, uint8(TaskPerm.CREATE));
        harness.setPermissionHat(permHatB, uint8(TaskPerm.BUDGET));
    }

    /*═════════════════════════════════ prototype fixtures ═════════════════════════════════*/

    function _setupPrototypeFixtures() internal {
        // #6 explicit-rule member.
        pRoleExplicit = proto.registerSubject(1, "President-Explicit");
        proto.setDefaultEligibility(pRoleExplicit, false, false);
        proto.grantRole(pRoleExplicit, alice); // accepted + explicit (true,true)

        // #7 derived groups. 5 member subjects; alice member of ONLY pGroupMembers[4].
        for (uint256 i; i < 5; ++i) {
            pGroupMembers[i] = proto.registerSubject(1, string.concat("PGM", vm.toString(i)));
            proto.setDefaultEligibility(pGroupMembers[i], false, false);
        }
        proto.grantRole(pGroupMembers[4], alice);

        pMarker1 = proto.registerSubject(2, "PMarker1");
        pMarker3 = proto.registerSubject(2, "PMarker3");
        pMarker5 = proto.registerSubject(2, "PMarker5");
        proto.setDefaultEligibility(pMarker1, false, false);
        proto.setDefaultEligibility(pMarker3, false, false);
        proto.setDefaultEligibility(pMarker5, false, false);

        uint256[] memory l1 = new uint256[](1);
        l1[0] = pGroupMembers[4];
        uint256[] memory l3 = new uint256[](3);
        l3[0] = pGroupMembers[0];
        l3[1] = pGroupMembers[1];
        l3[2] = pGroupMembers[4];
        uint256[] memory l5 = new uint256[](5);
        for (uint256 i; i < 4; ++i) {
            l5[i] = pGroupMembers[i];
        }
        l5[4] = pGroupMembers[4];
        proto.setGroupEligibility(pMarker1, l1);
        proto.setGroupEligibility(pMarker3, l3);
        proto.setGroupEligibility(pMarker5, l5);
        // accepted (mint-at-grant) for the markers themselves — group members drawing the group.
        proto.grantRole(pMarker1, alice);
        proto.grantRole(pMarker3, alice);
        proto.grantRole(pMarker5, alice);
        // grantRole wrote an explicit rule on the marker, which would short-circuit the derived path.
        // Clear it so the marker resolves via the DERIVED list (apples-to-apples with #2's mint+derive),
        // keeping only the accepted consent bit — re-set it via a fresh accept path:
        proto.clearWearerEligibility(alice, pMarker1);
        proto.clearWearerEligibility(alice, pMarker3);
        proto.clearWearerEligibility(alice, pMarker5);
        _reaccept(pMarker1, alice);
        _reaccept(pMarker3, alice);
        _reaccept(pMarker5, alice);

        // #8 vote subjects: 10; alice member of ONLY the last.
        for (uint256 i; i < 10; ++i) {
            pVoteSubjects[i] = proto.registerSubject(1, string.concat("PVote", vm.toString(i)));
            proto.setDefaultEligibility(pVoteSubjects[i], false, false);
        }
        proto.grantRole(pVoteSubjects[9], alice);

        // #9 perm role: alice member + perm mask.
        pPermRole = proto.registerSubject(1, "PPerm");
        proto.setDefaultEligibility(pPermRole, false, false);
        proto.grantRole(pPermRole, alice);
        proto.setPerm(pPermRole, PERM_KEY, TaskPerm.CREATE | TaskPerm.BUDGET);

        // #10 lifecycle subject.
        pPresRole = proto.registerSubject(1, "PPresident");
        proto.setDefaultEligibility(pPresRole, false, false);
    }

    /// @dev Re-establish the accepted consent bit WITHOUT an explicit rule, so marker membership
    ///      resolves through the derived list (mirrors the current mint+derive marker state).
    function _reaccept(uint256 subjectId, address user) internal {
        // proto has no bare "accept" setter (consent is via grantRole). Emulate the same on-chain state
        // — accepted=true, no explicit rule — by a direct storage write in the test (cheatcode), which
        // does not affect the MEASURED gas of the read path.
        // slot: keccak256("poa.nativeledger.storage"); accepted is the 5th declared mapping field.
        // Simpler + robust: grant then clear leaves accepted=true already (clear only wipes wearerRules
        // + hasSpecificWearerRules). So nothing more is needed — assert it.
        assertTrue(proto.isMember(subjectId, user), "marker derived membership after clear");
    }

    /*═════════════════════════════════════ THE BENCHMARK ═════════════════════════════════════*/

    function testAccessV2GasBench() public {
        console2.log("");
        console2.log("=== ACCESS V2 GAS BENCH (gas per call; cold = first slot touch, warm = repeat) ===");
        console2.log("op | current_cold | current_warm | proto_cold | proto_warm");

        // 1/6 single permission check
        (uint256 c1c, uint256 c1w) = _measureIsWearer(alice, explicitRoleHat);
        (uint256 p1c, uint256 p1w) = _measureIsMember(pRoleExplicit, alice);
        _row("1|6 single-check (explicit)", c1c, c1w, p1c, p1w);

        // 2/7 marker/group derived — len 1
        (uint256 c2c, uint256 c2w) = _measureIsWearer(alice, marker1);
        (uint256 p2c, uint256 p2w) = _measureIsMember(pMarker1, alice);
        _row("2|7 group derived n=1", c2c, c2w, p2c, p2w);

        // 2/7 len 3
        (uint256 c3c, uint256 c3w) = _measureIsWearer(alice, marker3);
        (uint256 p3c, uint256 p3w) = _measureIsMember(pMarker3, alice);
        _row("2|7 group derived n=3", c3c, c3w, p3c, p3w);

        // 2/7 len 5
        (uint256 c4c, uint256 c4w) = _measureIsWearer(alice, marker5);
        (uint256 p4c, uint256 p4w) = _measureIsMember(pMarker5, alice);
        _row("2|7 group derived n=5", c4c, c4w, p4c, p4w);

        // 3/8 DD hot path hasAnyHat / hasAnyMember — len 2, 5, 10
        _benchVote(2);
        _benchVote(5);
        _benchVote(10);

        // 4/9 permMask (2 hats) vs hasPerm (1 call)
        (uint256 c5c, uint256 c5w) = _measurePermMask(alice, PID);
        (uint256 p5c, uint256 p5w) = _measureHasPerm(pPermRole, PERM_KEY, alice);
        _row("4|9 permMask(2) / hasPerm", c5c, c5w, p5c, p5w);

        // 5/10 lifecycle grant + revoke
        uint256 cGrant = _measureRmGrant(presRole, bob);
        uint256 cRevoke = _measureRmRevoke(presRole, bob);
        uint256 pGrant = _measureProtoGrant(pPresRole, carol);
        uint256 pRevoke = _measureProtoRevoke(pPresRole, carol);
        console2.log("5|10 grantRole            | current:", cGrant, "| proto:", pGrant);
        console2.log("5|10 revokeRole           | current:", cRevoke, "| proto:", pRevoke);

        console2.log("=== END ===");

        // Correctness (run AFTER measurement so it does not pre-warm the priced slots): both sides
        // agree on the membership truth we are pricing.
        assertTrue(hats.isWearerOfHat(alice, explicitRoleHat), "current #1 truth");
        assertTrue(proto.isMember(pRoleExplicit, alice), "proto #6 truth");
        assertTrue(hats.isWearerOfHat(alice, marker5), "current #2 truth");
        assertTrue(proto.isMember(pMarker5, alice), "proto #7 truth");
        assertEq(uint256(harness.permMask(alice, PID)), uint256(TaskPerm.CREATE | TaskPerm.BUDGET), "permMask");
        assertEq(proto.hasPerm(pPermRole, PERM_KEY, alice), TaskPerm.CREATE | TaskPerm.BUDGET, "hasPerm");
    }

    /*──────── vote-path bench (uses tail of the 10-array so alice wears the LAST entry) ────────*/
    function _benchVote(uint256 n) internal {
        uint256[] memory cur = new uint256[](n);
        uint256[] memory pro = new uint256[](n);
        // fill with hats/subjects alice does NOT wear, LAST = the one she wears.
        for (uint256 i; i < n - 1; ++i) {
            cur[i] = voteHats[i];
            pro[i] = pVoteSubjects[i];
        }
        cur[n - 1] = voteHats[9];
        pro[n - 1] = pVoteSubjects[9];

        harness.setVotingHats(cur);
        (uint256 cc, uint256 cw) = _measureHasAnyHat(alice);
        (uint256 pc, uint256 pw) = _measureHasAnyMember(pro, alice);
        if (n == 2) _row("3|8 hasAnyHat/Member n=2", cc, cw, pc, pw);
        else if (n == 5) _row("3|8 hasAnyHat/Member n=5", cc, cw, pc, pw);
        else _row("3|8 hasAnyHat/Member n=10", cc, cw, pc, pw);
    }

    /*═════════════════════════════════════ measurement helpers ═════════════════════════════════════*/

    function _measureIsWearer(address u, uint256 h) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = hats.isWearerOfHat(u, h);
        cold = g - gasleft();
        g = gasleft();
        r = hats.isWearerOfHat(u, h);
        warm = g - gasleft();
        bSink = r;
    }

    function _measureIsMember(uint256 s, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = proto.isMember(s, u);
        cold = g - gasleft();
        g = gasleft();
        r = proto.isMember(s, u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measureHasAnyHat(address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = harness.hasAnyHat(u);
        cold = g - gasleft();
        g = gasleft();
        r = harness.hasAnyHat(u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measureHasAnyMember(uint256[] memory s, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        bool r = proto.hasAnyMember(s, u);
        cold = g - gasleft();
        g = gasleft();
        r = proto.hasAnyMember(s, u);
        warm = g - gasleft();
        bSink = r;
    }

    function _measurePermMask(address u, bytes32 pid) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint8 r = harness.permMask(u, pid);
        cold = g - gasleft();
        g = gasleft();
        r = harness.permMask(u, pid);
        warm = g - gasleft();
        uSink = r;
    }

    function _measureHasPerm(uint256 s, bytes32 k, address u) internal returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        uint256 r = proto.hasPerm(s, k, u);
        cold = g - gasleft();
        g = gasleft();
        r = proto.hasPerm(s, k, u);
        warm = g - gasleft();
        uSink = r;
    }

    function _measureRmGrant(uint256 role, address u) internal returns (uint256 used) {
        vm.prank(address(executor));
        uint256 g = gasleft();
        rm.grantRole(role, u);
        used = g - gasleft();
    }

    function _measureRmRevoke(uint256 role, address u) internal returns (uint256 used) {
        vm.prank(address(executor));
        uint256 g = gasleft();
        rm.revokeRole(role, u);
        used = g - gasleft();
    }

    function _measureProtoGrant(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        proto.grantRole(s, u);
        used = g - gasleft();
    }

    function _measureProtoRevoke(uint256 s, address u) internal returns (uint256 used) {
        uint256 g = gasleft();
        proto.revokeRole(s, u);
        used = g - gasleft();
    }

    function _row(string memory op, uint256 cc, uint256 cw, uint256 pc, uint256 pw) internal pure {
        console2.log(op);
        console2.log("   current cold/warm:", cc, cw);
        console2.log("   proto   cold/warm:", pc, pw);
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

    /// @dev create a hat under an active executor prank (post-handoff superAdmin)
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
