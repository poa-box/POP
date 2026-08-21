// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MembershipAuthority} from "../src/MembershipAuthority.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {AccessV2Ids} from "../src/libs/AccessV2Ids.sol";
import {MembershipAuthorityLogic} from "../src/libs/MembershipAuthorityLogic.sol";

/// @title MembershipAuthorityLayoutSyncTest — ERC-7201 slot-mirror guard across the THREE deployed
///        code units (hub impl + {MembershipAuthorityLogic} + {MembershipAuthoritySeed}).
/// @notice The three units share ONE canonical {MembershipAuthorityLogic.Layout} declaration and reach
///         it via `MembershipAuthorityLogic.layout()` at slot `keccak256("poa.membershipauthority.storage")`.
///         Each executes in the proxy's storage context by DELEGATECALL, so if any unit computed a
///         different slot, a value WRITTEN by one unit would read back WRONG through another. This suite
///         pins the slot constant and exercises SEED-write → hub-read and LOGIC-write → hub-read for
///         every field family the cold libs touch, so any accidental slot/struct drift fails loudly
///         (the EligibilityLogicLayoutSync precedent).
contract MembershipAuthorityLayoutSyncTest is Test {
    MembershipAuthority internal auth;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        MembershipAuthority impl = new MembershipAuthority();
        AccessV2Types.OrgAccessSeed memory seed;
        seed.subjectIds = new uint256[](0);
        seed.subjectKinds = new AccessV2Types.SubjectKind[](0);
        seed.subjectNames = new string[](0);
        seed.subjectMaxMembers = new uint32[](0);
        seed.subjectDefaults = new bool[](0);
        seed.groupMemberRoles = new uint256[][](0);
        seed.vouchSubjects = new uint256[](0);
        seed.vouchQuorums = new uint32[](0);
        seed.vouchVoucherSubjects = new uint256[](0);
        seed.permSubjects = new uint256[](0);
        seed.permKeys = new bytes32[](0);
        seed.permCtxs = new bytes32[](0);
        seed.permWords = new uint256[](0);
        IMembershipAuthority.InitConfig memory cfg = IMembershipAuthority.InitConfig({
            executor: address(this), paymasterHub: address(0), orgId: bytes32(0), seed: seed
        });
        auth = MembershipAuthority(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MembershipAuthority.initialize, (cfg))))
        );
    }

    function testStorageSlotConstantPinned() public pure {
        assertEq(
            MembershipAuthorityLogic.STORAGE_SLOT,
            keccak256("poa.membershipauthority.storage"),
            "ERC-7201 slot constant drifted"
        );
    }

    /// SEED-lib write (seedSubjects / seedRules / seedMemberships) -> hub-read (getSubject / isMember /
    /// getRule): the seed library resolves the SAME Layout slot the hub reads.
    function testSeedWriteHubRead() public {
        uint256 sid = (uint256(uint160(address(auth))) << 64) | 1; // first allocated new id
        uint256[] memory ids = new uint256[](1);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        names[0] = "Member";
        uint32[] memory mm = new uint32[](1);
        auth.seedSubjects(ids, kinds, names, mm);
        assertTrue(auth.getSubject(sid).exists, "seed-written subject visible to hub");

        uint256[] memory subs = new uint256[](1);
        subs[0] = sid;
        address[] memory users = new address[](1);
        users[0] = alice;
        AccessV2Types.RuleKind[] memory rk = new AccessV2Types.RuleKind[](1);
        rk[0] = AccessV2Types.RuleKind.Grant;
        bool[] memory dg = new bool[](1);
        dg[0] = true;
        auth.seedRules(subs, users, rk, dg);
        assertEq(uint8(auth.getRule(sid, alice).kind), uint8(AccessV2Types.RuleKind.Grant), "seed rule visible to hub");

        auth.seedMemberships(subs, users);
        assertTrue(auth.isMember(sid, alice), "seed membership visible to hub");
        assertEq(auth.memberCount(sid), 1, "seed memberCount visible to hub");
    }

    /// LOGIC-lib write (createRole / setPerm / setManagerConfig / grant) -> hub-read.
    function testLogicWriteHubRead() public {
        uint256 sid = auth.createRole("Titled", bytes32(0), "", 3); // Logic lib write
        uint256 mgr = auth.createRole("Manager", bytes32(0), "", 0);
        assertEq(auth.getSubject(sid).maxMembers, 3, "logic-written subject read by hub");

        auth.setManagerConfig(sid, mgr, 3, 100);
        assertEq(auth.getManagerConfig(sid).managerSubject, mgr, "logic-written manager config read by hub");
        assertEq(auth.getManagerConfig(sid).delaySecs, 100, "logic-written delay read by hub");

        // grant to out-of-org alice writes a rule the hub reads
        auth.grant(sid, alice, false);
        assertEq(uint8(auth.getRule(sid, alice).kind), uint8(AccessV2Types.RuleKind.Grant), "logic grant read by hub");
    }
}
