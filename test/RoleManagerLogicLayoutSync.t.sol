// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {MockHatsRM} from "./mocks/MockHatsRM.sol";
import {MockEligibilityModuleRM} from "./mocks/MockEligibilityModuleRM.sol";
import {
    MockDDVotingRM,
    MockHVVotingRM,
    MockTaskManagerRM,
    MockPTRM,
    MockEduRM,
    MockQuickJoinRM,
    MockPaymasterHubRM
} from "./mocks/MockSiblingsRM.sol";

/**
 * @title RoleManagerLogicLayoutSyncTest — functional ERC-7201 layout-divergence guard
 * @notice {RoleManager} offloads its permission fan-out body (`applyWiring`) to {RoleManagerLogic}, a
 *         DELEGATECALL library that RE-DECLARES the module's ERC-7201 `Layout` struct at the SAME slot
 *         (`keccak256("poa.rolemanager.storage")`). Because the library executes in the module's
 *         storage context, the two `Layout` definitions MUST stay byte-identical — field order, types
 *         and count. There is NO compiler check for this: if a field is appended/reordered in one
 *         struct and not the other, every field AFTER the divergence point silently reads the WRONG
 *         slot while the module keeps compiling.
 *
 *         This suite is that missing check, expressed FUNCTIONALLY. `applyWiring` runs entirely in the
 *         library and READS every module-wiring slot (`eligibilityModule`, `ddVoting`, `hybridVoting`,
 *         `taskManager`, `participationToken`, `educationHub`, `quickJoin`, `paymasterHub`, `orgId`)
 *         to decide where to fan out. Those slots are written MODULE-side by `initialize`. So a single
 *         `createRole`/`setRoleWiring` with comprehensive wiring proves the library reads the exact
 *         slots the module wrote: a shift anywhere at or before those fields (e.g. dropping `executor`
 *         or `hats` from the library mirror) misdirects a fan-out to `address(0)` and fails an
 *         assertion here instead of shipping silent storage corruption. The appended delegation-config
 *         fields (`roleManagerConfigs`/`groupManagerConfigs`) are round-tripped module-side with a
 *         subsequent lib fan-out to prove the earlier slots still align once the tail is populated.
 */
contract RoleManagerLogicLayoutSyncTest is Test {
    uint256 constant ADMIN_HAT = 1;
    uint256 constant MEMBER_HAT = 2;
    bytes32 constant ORG_ID = keccak256("layout-sync-org");
    uint8 constant SUBJECT_TYPE_HAT = 0x01;

    RoleManager rm;
    MockHatsRM hats;
    MockEligibilityModuleRM em;
    MockDDVotingRM dd;
    MockHVVotingRM hv;
    MockTaskManagerRM tm;
    MockPTRM pt;
    MockEduRM edu;
    MockQuickJoinRM qj;
    MockPaymasterHubRM paymaster;

    function setUp() public {
        hats = new MockHatsRM();
        em = new MockEligibilityModuleRM(hats, ADMIN_HAT);
        hats.setEligibility(address(em));
        dd = new MockDDVotingRM();
        hv = new MockHVVotingRM();
        tm = new MockTaskManagerRM();
        pt = new MockPTRM();
        edu = new MockEduRM();
        qj = new MockQuickJoinRM();
        paymaster = new MockPaymasterHubRM();

        RoleManager impl = new RoleManager();
        uint256[] memory seed = new uint256[](1);
        seed[0] = MEMBER_HAT;
        string[] memory names = new string[](1);
        names[0] = "Member";
        IRoleManager.InitConfig memory cfg = IRoleManager.InitConfig({
            executor: address(this),
            eligibilityModule: address(em),
            hats: address(hats),
            ddVoting: address(dd),
            hybridVoting: address(hv),
            taskManager: address(tm),
            participationToken: address(pt),
            educationHub: address(edu),
            quickJoin: address(qj),
            paymasterHub: address(paymaster),
            orgId: ORG_ID,
            existingOrgHats: seed,
            existingOrgHatNames: names
        });
        rm = RoleManager(address(new ERC1967Proxy(address(impl), abi.encodeCall(RoleManager.initialize, (cfg)))));
    }

    /*═══════════ every lib-read wiring slot at once (MODULE-write initialize -> LIB-read applyWiring) ═══════════*/

    /// A createRole with comprehensive wiring exercises the library's read of EVERY module-wiring slot.
    /// Each mock recording the expected call proves the library and module agree on that slot.
    function testAllWiringSlots_ModuleWriteLibRead() public {
        IRoleManager.RoleWiring memory w;
        w.setTaskPerm = true;
        w.taskPermMask = 7;
        w.ddVoter = true;
        w.ddCreator = true;
        w.hvCreator = true;
        w.hvClassIndexes = new uint8[](1);
        w.hvClassIndexes[0] = 2;
        w.ptMember = true;
        w.ptApprover = true;
        w.eduCreator = true;
        w.eduMember = true;
        w.quickJoinAutoMint = false; // identity hats are default-closed; auto-mint would revert
        w.vouchingEnabled = true; // proves eligibilityModule slot (configureVouching runs in the lib)
        w.vouchQuorum = 3;
        w.vouchMembershipHatId = MEMBER_HAT;
        w.vouchCombine = true;
        w.budgetCapPerEpoch = 1_000; // proves paymasterHub + orgId slots
        w.budgetEpochLen = 86_400;

        IRoleManager.RoleParams memory p;
        p.name = "President";
        p.imageURI = "img";
        p.maxSupply = type(uint32).max;
        p.mutableHat = true;
        p.groupIds = new uint256[](0);
        p.wiring = w;
        p.initialGrants = new address[](0);

        (, uint256 hatId) = rm.createRole(p);

        // TaskManager slot.
        assertEq(tm.callCount(), 1, "lib read taskManager slot -> ROLE_PERM fan-out");
        // DirectDemocracy slot (VOTING + CREATOR).
        assertEq(dd.callCount(), 2, "lib read ddVoting slot -> 2 HAT_ALLOWED fan-outs");
        // HybridVoting slot (creator right + one class edit).
        assertEq(hv.creatorCallCount(), 1, "lib read hybridVoting slot -> setCreatorHatAllowed");
        assertEq(hv.classEditCount(), 1, "lib read hybridVoting slot -> addHatToClass");
        // ParticipationToken slot.
        assertEq(pt.memberCallCount(), 1, "lib read participationToken slot -> setMemberHatAllowed");
        assertEq(pt.approverCallCount(), 1, "lib read participationToken slot -> setApproverHatAllowed");
        // EducationHub slot.
        assertEq(edu.creatorCallCount(), 1, "lib read educationHub slot -> setCreatorHatAllowed");
        assertEq(edu.memberCallCount(), 1, "lib read educationHub slot -> setMemberHatAllowed");
        // EligibilityModule slot (configureVouching runs in the lib).
        assertTrue(em.vouchConfigured(hatId), "lib read eligibilityModule slot -> configureVouching");
        assertEq(em.lastVouchQuorum(hatId), 3, "lib read eligibilityModule slot -> quorum value");
        // PaymasterHub + orgId slots.
        assertEq(paymaster.callCount(), 1, "lib read paymasterHub slot -> setBudget");
        (bytes32 gotOrg, bytes32 gotSubject, uint128 gotCap,) = paymaster.calls(0);
        assertEq(gotOrg, ORG_ID, "lib read orgId slot -> setBudget orgId");
        assertEq(gotSubject, keccak256(abi.encodePacked(SUBJECT_TYPE_HAT, bytes32(hatId))), "subjectKey from hatId");
        assertEq(gotCap, uint128(1_000), "budget cap forwarded");
    }

    /*═══════════ quickJoin slot (LIB read-modify-write of the member-hat list) ═══════════*/

    function testQuickJoinSlot_LibReadModifyWrite() public {
        (, uint256 hatId) = rm.createRole(_bareRole("Ops"));

        // Seed the QJ list with the identity hat, then re-wire with quickJoinAutoMint=false: the lib
        // reads the quickJoin slot, sees the hat present, and writes the shortened list back.
        uint256[] memory seed = new uint256[](1);
        seed[0] = hatId;
        qj.seed(seed);
        assertEq(qj.memberHatIds().length, 1, "seeded");

        IRoleManager.RoleWiring memory w;
        w.hvClassIndexes = new uint8[](0);
        w.quickJoinAutoMint = false;
        rm.setRoleWiring(_roleIdOf(hatId), w);

        assertEq(qj.memberHatIds().length, 0, "lib read+wrote quickJoin slot -> hat removed");
    }

    /*═══════════ appended delegation-config tail (MODULE round-trip, then LIB fan-out still aligns) ═══════════*/

    function testManagerConfigTail_ModuleRoundTripThenLibReadStillAligns() public {
        (uint256 roleId, uint256 hatId) = rm.createRole(_bareRole("Treasurer"));
        (uint256 groupId,) = rm.createGroup("Council", bytes32(0), "img", _one(roleId), _emptyWiring());

        // MODULE-write the appended config fields; MODULE-read them back.
        rm.setRoleManagerConfig(roleId, 42, rm.CAP_GRANT());
        rm.setGroupManagerConfig(groupId, 43, rm.CAP_REVOKE());
        assertEq(rm.getRoleManagerConfig(roleId).managerHatId, 42, "role config tail written+read");
        assertEq(rm.getRoleManagerConfig(roleId).caps, rm.CAP_GRANT(), "role config caps");
        assertEq(rm.getGroupManagerConfig(groupId).managerHatId, 43, "group config tail written+read");
        assertEq(rm.getGroupManagerConfig(groupId).caps, rm.CAP_REVOKE(), "group config caps");

        // With the tail populated, a LIB fan-out must still read the EARLY wiring slots correctly.
        IRoleManager.RoleWiring memory w;
        w.hvClassIndexes = new uint8[](0);
        w.ddVoter = true;
        uint256 ddBefore = dd.callCount();
        rm.setRoleWiring(roleId, w);
        assertEq(dd.callCount(), ddBefore + 2, "lib still reads ddVoting slot after config tail populated");
        // silence unused warning
        hatId;
    }

    /*═══════════ helpers ═══════════*/

    function _emptyWiring() internal pure returns (IRoleManager.RoleWiring memory w) {
        w.hvClassIndexes = new uint8[](0);
    }

    function _bareRole(string memory name) internal pure returns (IRoleManager.RoleParams memory p) {
        p.name = name;
        p.imageURI = "img";
        p.maxSupply = type(uint32).max;
        p.mutableHat = true;
        p.groupIds = new uint256[](0);
        p.wiring = _emptyWiring();
        p.initialGrants = new address[](0);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _roleIdOf(uint256 hatId) internal view returns (uint256) {
        return rm.roleIdOfHat(hatId);
    }
}
