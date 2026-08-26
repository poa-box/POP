// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {RoleResolver} from "../src/libs/RoleResolver.sol";

/// @dev The library is `internal pure`; a harness gives the revert cases a call boundary.
contract RoleResolverHarness {
    function resolveRoleBitmap(uint256[] memory roleSubjectIds, uint256 rolesBitmap)
        external
        pure
        returns (uint256[] memory)
    {
        return RoleResolver.resolveRoleBitmap(roleSubjectIds, rolesBitmap);
    }
}

contract RoleResolverTest is Test {
    RoleResolverHarness resolver;
    uint256[] subjects;

    uint256 constant DEFAULT_SUBJECT = 1001;
    uint256 constant EXECUTIVE_SUBJECT = 1002;
    uint256 constant ADMIN_SUBJECT = 1003;

    function setUp() public {
        resolver = new RoleResolverHarness();
        subjects = new uint256[](3);
        subjects[0] = DEFAULT_SUBJECT;
        subjects[1] = EXECUTIVE_SUBJECT;
        subjects[2] = ADMIN_SUBJECT;
    }

    function testEmptyBitmapResolvesToNothing() public view {
        assertEq(resolver.resolveRoleBitmap(subjects, 0).length, 0);
    }

    function testSingleBit() public view {
        uint256[] memory result = resolver.resolveRoleBitmap(subjects, 1 << 1);
        assertEq(result.length, 1);
        assertEq(result[0], EXECUTIVE_SUBJECT);
    }

    /// @notice Results follow ascending role index regardless of which bits are set.
    function testMultipleBitsKeepRoleIndexOrder() public view {
        uint256[] memory result = resolver.resolveRoleBitmap(subjects, (1 << 2) | (1 << 0));
        assertEq(result.length, 2);
        assertEq(result[0], DEFAULT_SUBJECT);
        assertEq(result[1], ADMIN_SUBJECT);
    }

    function testAllBits() public view {
        uint256[] memory result = resolver.resolveRoleBitmap(subjects, (1 << 0) | (1 << 1) | (1 << 2));
        assertEq(result.length, 3);
        assertEq(result[0], DEFAULT_SUBJECT);
        assertEq(result[1], EXECUTIVE_SUBJECT);
        assertEq(result[2], ADMIN_SUBJECT);
    }

    /// @notice A bit past the role count is rejected — storing subject 0 as "authorized" would
    ///         silently grant nobody.
    function testBitPastTheRoleCountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RoleResolver.UnregisteredRole.selector, uint256(4)));
        resolver.resolveRoleBitmap(subjects, (1 << 0) | (1 << 4));
    }

    /// @notice Same rejection for an in-range hole (a subject id that was never allocated).
    function testUnallocatedSubjectReverts() public {
        uint256[] memory withHole = new uint256[](3);
        withHole[0] = DEFAULT_SUBJECT;
        withHole[2] = ADMIN_SUBJECT;

        vm.expectRevert(abi.encodeWithSelector(RoleResolver.UnregisteredRole.selector, uint256(1)));
        resolver.resolveRoleBitmap(withHole, 1 << 1);
    }

    function testEmptySubjectListRejectsAnySetBit() public {
        vm.expectRevert(abi.encodeWithSelector(RoleResolver.UnregisteredRole.selector, uint256(0)));
        resolver.resolveRoleBitmap(new uint256[](0), 1);
    }

    /// @notice The authority caps an org at 16 roles; the resolver must handle a full bitmap.
    function testFullRoleCap() public {
        uint256[] memory many = new uint256[](16);
        uint256 bitmap;
        for (uint256 i; i < 16; ++i) {
            many[i] = 2000 + i;
            bitmap |= 1 << i;
        }

        uint256[] memory result = resolver.resolveRoleBitmap(many, bitmap);
        assertEq(result.length, 16);
        for (uint256 i; i < 16; ++i) {
            assertEq(result[i], 2000 + i);
        }
    }
}
