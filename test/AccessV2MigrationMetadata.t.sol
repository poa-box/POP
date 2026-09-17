// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AccessV2MigrationBase, IHatsMin} from "../script/accessv2/AccessV2MigrationBase.sol";
import {IMembershipAuthority} from "../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../src/libs/AccessV2Types.sol";
import {IExecutor} from "../src/Executor.sol";

contract AccessV2MigrationMetadataHarness is AccessV2MigrationBase {
    function buildSingleSubject(address authority, string calldata org, uint256 hatId)
        external
        returns (IExecutor.Call[] memory)
    {
        _loadSubjectMetadata(org);
        delete _batches;
        _newBatch();
        _pushAdminSubject(authority, hatId);
        return _batches[0];
    }

    function buildRepairs(address authority, string calldata org, uint256[] calldata hatIds)
        external
        returns (IExecutor.Call[] memory)
    {
        _loadSubjectMetadata(org);
        delete _subjects;
        for (uint256 i; i < hatIds.length; ++i) {
            _addSubject(hatIds[i]);
        }
        return _buildSubjectMetadataRepairs(authority);
    }

    function isOpaqueSubjectName(string calldata name) external pure returns (bool) {
        return _isOpaqueSubjectName(name);
    }
}

contract SubjectMetadataSink {
    uint256 public subjectId;
    string public seededName;
    string public subjectName;
    bytes32 public metadataCID;
    string public imageURI;
    uint32 public maxMembers;
    bool public exists;

    function prime(uint256 id, string calldata name, bytes32 cid, string calldata image, uint32 cap) external {
        subjectId = id;
        subjectName = name;
        metadataCID = cid;
        imageURI = image;
        maxMembers = cap;
        exists = true;
    }

    function seedSubjects(
        uint256[] calldata subjectIds,
        AccessV2Types.SubjectKind[] calldata,
        string[] calldata names,
        uint32[] calldata caps
    ) external {
        subjectId = subjectIds[0];
        seededName = names[0];
        subjectName = names[0];
        maxMembers = caps[0];
        exists = true;
    }

    function renameSubject(uint256 id, string calldata name, bytes32 cid, string calldata image) external {
        subjectId = id;
        subjectName = name;
        metadataCID = cid;
        imageURI = image;
    }

    function getSubject(uint256 id) external view returns (IMembershipAuthority.SubjectInfo memory info) {
        if (id != subjectId || !exists) return info;
        info = IMembershipAuthority.SubjectInfo({
            kind: AccessV2Types.SubjectKind.Role,
            name: subjectName,
            metadataCID: metadataCID,
            imageURI: imageURI,
            maxMembers: maxMembers,
            exists: true
        });
    }
}

contract AccessV2MigrationMetadataTest is Test {
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    uint256 internal constant KUBI_TOP_HAT = 0x43700000000000000000000000000000000000000000000000000000000;
    uint256 internal constant NEW_MEMBER_HAT = 0x43700010001000100010000000000000000000000000000000000000000;
    bytes32 internal constant NEW_MEMBER_CID = 0xc9f573a180f5c200d297e8c451effc4ffb8ae867ec72add82f282daf310443fc;

    AccessV2MigrationMetadataHarness internal harness;

    function setUp() public {
        harness = new AccessV2MigrationMetadataHarness();
    }

    function testMetadataBearingRoleKeepsCanonicalNameCIDAndImage() public {
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(
            NEW_MEMBER_HAT,
            "0xc9f573a180f5c200d297e8c451effc4ffb8ae867ec72add82f282daf310443fc",
            "ipfs://new-member-image"
        );

        IExecutor.Call[] memory calls = harness.buildSingleSubject(address(sink), "KUBI", NEW_MEMBER_HAT);

        assertEq(calls.length, 2, "seed + metadata write");
        assertEq(_selector(calls[0].data), IMembershipAuthority.seedSubjects.selector, "subject seeded first");
        assertEq(_selector(calls[1].data), IMembershipAuthority.renameSubject.selector, "metadata follows seed");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok, "generated metadata call failed");
        }

        assertEq(sink.subjectId(), NEW_MEMBER_HAT);
        assertEq(sink.seededName(), "New Member", "CID hex must never be emitted as SubjectCreated.name");
        assertEq(sink.subjectName(), "New Member");
        assertEq(sink.metadataCID(), NEW_MEMBER_CID);
        assertEq(sink.imageURI(), "ipfs://new-member-image");
        assertEq(sink.maxMembers(), 100);
    }

    function testCIDShapedDetailsWithoutCanonicalEventFixtureFailsClosed() public {
        uint256 unknownHat = NEW_MEMBER_HAT + 1;
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(unknownHat, "0xc9f573a180f5c200d297e8c451effc4ffb8ae867ec72add82f282daf310443fc", "");

        vm.expectRevert(
            abi.encodeWithSelector(AccessV2MigrationBase.SubjectMetadataRequired.selector, unknownHat, NEW_MEMBER_CID)
        );
        harness.buildSingleSubject(address(sink), "KUBI", unknownHat);
    }

    function testStaleMetadataFixtureFailsClosed() public {
        bytes32 changedCID = bytes32(uint256(0x1234));
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(NEW_MEMBER_HAT, "0x0000000000000000000000000000000000000000000000000000000000001234", "");

        vm.expectRevert(
            abi.encodeWithSelector(
                AccessV2MigrationBase.SubjectMetadataDrift.selector, NEW_MEMBER_HAT, changedCID, NEW_MEMBER_CID
            )
        );
        harness.buildSingleSubject(address(sink), "KUBI", NEW_MEMBER_HAT);
    }

    function testTopHatIPFSPointerUsesAdminFallback() public {
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(KUBI_TOP_HAT, "ipfs://KUBI", "");

        IExecutor.Call[] memory calls = harness.buildSingleSubject(address(sink), "KUBI", KUBI_TOP_HAT);
        assertEq(calls.length, 1, "pointer is not persisted as subject metadata");
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertTrue(ok);
        assertEq(sink.seededName(), "Admin");
    }

    function testLegacyImageSentinelIsNormalizedToEmpty() public {
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(KUBI_TOP_HAT, "ipfs://KUBI", "ELIGIBILITY_ADMIN");

        IExecutor.Call[] memory calls = harness.buildSingleSubject(address(sink), "KUBI", KUBI_TOP_HAT);
        assertEq(calls.length, 1, "a non-URI image sentinel must not add a metadata write");
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertTrue(ok);
        assertEq(sink.seededName(), "Admin");
        assertEq(sink.imageURI(), "");
    }

    function testFixtureNameCannotBeOpaqueMetadataPointer() public view {
        assertTrue(harness.isOpaqueSubjectName("ipfs://role-metadata"));
        assertTrue(harness.isOpaqueSubjectName("https://example.com/role.json"));
        assertTrue(harness.isOpaqueSubjectName("Qm11111111111111111111111111111111111111111111"));
        assertTrue(harness.isOpaqueSubjectName("0xc9f573a180f5c200d297e8c451effc4ffb8ae867ec72add82f282daf310443fc"));
        assertFalse(harness.isOpaqueSubjectName("New Member"));
    }

    function testBareCIDPointerUsesAdminFallback() public {
        SubjectMetadataSink sink = new SubjectMetadataSink();
        _mockHat(KUBI_TOP_HAT, "Qm11111111111111111111111111111111111111111111", "");

        IExecutor.Call[] memory calls = harness.buildSingleSubject(address(sink), "KUBI", KUBI_TOP_HAT);
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertTrue(ok);
        assertEq(sink.seededName(), "Admin");
    }

    function testCutoverRepairsAlreadySeededOpaqueAdminNameIdempotently() public {
        SubjectMetadataSink sink = new SubjectMetadataSink();
        sink.prime(KUBI_TOP_HAT, "ipfs://KUBI", bytes32(0), "", 1);
        _mockHat(KUBI_TOP_HAT, "ipfs://KUBI", "ELIGIBILITY_ADMIN");
        uint256[] memory ids = new uint256[](1);
        ids[0] = KUBI_TOP_HAT;

        IExecutor.Call[] memory repairs = harness.buildRepairs(address(sink), "KUBI", ids);
        assertEq(repairs.length, 1);
        assertEq(_selector(repairs[0].data), IMembershipAuthority.renameSubject.selector);
        (bool ok,) = repairs[0].target.call(repairs[0].data);
        assertTrue(ok);
        assertEq(sink.subjectName(), "Admin");
        assertEq(sink.imageURI(), "", "legacy image sentinel must not be copied during repair");

        repairs = harness.buildRepairs(address(sink), "KUBI", ids);
        assertEq(repairs.length, 0, "a repaired subject must not add another cutover call");
    }

    function _mockHat(uint256 hatId, string memory details, string memory imageURI) internal {
        vm.mockCall(
            HATS,
            abi.encodeCall(IHatsMin.viewHat, (hatId)),
            abi.encode(details, uint32(100), uint32(0), address(0xE11), address(0x706), imageURI, uint16(0), true, true)
        );
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }
}
