// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {PoaDKIMRegistry} from "../src/zkemail/PoaDKIMRegistry.sol";

contract PoaDKIMRegistryTest is Test {
    PoaDKIMRegistry reg;
    address owner = address(0xA11CE);
    address stranger = address(0xBEEF);

    bytes32 constant DOMAIN_HASH = keccak256("anthropic.com");
    bytes32 constant KEY_HASH = bytes32(uint256(0x1234));

    function setUp() public {
        reg = new PoaDKIMRegistry(owner);
    }

    function testConstructorSetsOwner() public view {
        assertEq(reg.owner(), owner);
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(PoaDKIMRegistry.ZeroAddress.selector);
        new PoaDKIMRegistry(address(0));
    }

    function testDefaultsToInvalid() public view {
        assertFalse(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));
    }

    function testSetKeyHashOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(PoaDKIMRegistry.NotOwner.selector);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
    }

    function testSetKeyHashSetsAndClears() public {
        vm.prank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));

        vm.prank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, false);
        assertFalse(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));
    }

    function testSetKeyHashIsKeySpecific() public {
        vm.prank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
        // A different key hash for the same domain stays invalid.
        assertFalse(reg.isKeyHashValid(DOMAIN_HASH, bytes32(uint256(0x9999))));
        // Same key hash for a different domain stays invalid.
        assertFalse(reg.isKeyHashValid(keccak256("other.com"), KEY_HASH));
    }

    /// @dev domainHashOf must match ZkEmailInvites' keccak256(lower(domain)) exactly, including
    ///      lowercasing uppercase ASCII — otherwise seeded keys would address the wrong domain slot.
    function testDomainHashOfLowercases() public view {
        assertEq(reg.domainHashOf("Anthropic.COM"), keccak256("anthropic.com"));
        assertEq(reg.domainHashOf("anthropic.com"), keccak256("anthropic.com"));
        assertEq(reg.domainHashOf("OPACITYLABS.COM"), keccak256("opacitylabs.com"));
    }

    function testSetKeyForDomainMatchesModuleHashing() public {
        vm.prank(owner);
        reg.setKeyForDomain("Anthropic.com", KEY_HASH, true);
        // Validity must be visible under the module's hash of the lowercased domain.
        assertTrue(reg.isKeyHashValid(keccak256("anthropic.com"), KEY_HASH));
    }

    function testSetKeyHashesBatch() public {
        bytes32[] memory domains = new bytes32[](2);
        bytes32[] memory keys = new bytes32[](2);
        domains[0] = keccak256("a.com");
        domains[1] = keccak256("b.com");
        keys[0] = bytes32(uint256(1));
        keys[1] = bytes32(uint256(2));

        vm.prank(owner);
        reg.setKeyHashes(domains, keys, true);
        assertTrue(reg.isKeyHashValid(domains[0], keys[0]));
        assertTrue(reg.isKeyHashValid(domains[1], keys[1]));
    }

    function testSetKeyHashesLengthMismatchReverts() public {
        bytes32[] memory domains = new bytes32[](2);
        bytes32[] memory keys = new bytes32[](1);
        vm.prank(owner);
        vm.expectRevert(PoaDKIMRegistry.LengthMismatch.selector);
        reg.setKeyHashes(domains, keys, true);
    }

    function testTransferOwnership() public {
        vm.prank(owner);
        reg.transferOwnership(stranger);
        assertEq(reg.owner(), stranger);

        // Old owner can no longer write.
        vm.prank(owner);
        vm.expectRevert(PoaDKIMRegistry.NotOwner.selector);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
    }

    function testTransferOwnershipRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(PoaDKIMRegistry.ZeroAddress.selector);
        reg.transferOwnership(address(0));
    }

    /*────────── Rotation / staleness (Advisory 5) ──────────*/

    function testBooleanSetIsPermanent() public {
        vm.prank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
        assertEq(reg.keyValidUntil(DOMAIN_HASH, KEY_HASH), reg.NO_EXPIRY(), "true => NO_EXPIRY");
        // Still valid far in the future (no time cut-off).
        vm.warp(block.timestamp + 3650 days);
        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));
    }

    function testKeyExpiresAfterValidUntil() public {
        uint256 cutoff = block.timestamp + 30 days;
        vm.prank(owner);
        reg.setKeyHashWithExpiry(DOMAIN_HASH, KEY_HASH, cutoff);

        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH), "valid before cutoff");
        vm.warp(cutoff); // inclusive boundary — still valid AT the cutoff
        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH), "valid at cutoff");
        vm.warp(cutoff + 1);
        assertFalse(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH), "invalid after cutoff");
        // A leaked, rotated-out key is now dead even though it was never explicitly revoked.
    }

    function testSetKeyHashWithExpiryRejectsPastTimestamp() public {
        vm.warp(1000);
        vm.prank(owner);
        vm.expectRevert(PoaDKIMRegistry.ExpiryInPast.selector);
        reg.setKeyHashWithExpiry(DOMAIN_HASH, KEY_HASH, 999);
    }

    function testSetKeyHashWithExpiryAcceptsNoExpirySentinel() public {
        uint256 noExpiry = reg.NO_EXPIRY(); // read before prank — a view call would consume vm.prank
        vm.prank(owner);
        reg.setKeyHashWithExpiry(DOMAIN_HASH, KEY_HASH, noExpiry);
        vm.warp(block.timestamp + 100000 days);
        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH), "NO_EXPIRY sentinel never expires");
    }

    function testSetKeyForDomainWithExpiry() public {
        uint256 cutoff = block.timestamp + 10 days;
        vm.prank(owner);
        reg.setKeyForDomainWithExpiry("Anthropic.com", KEY_HASH, cutoff);
        assertTrue(reg.isKeyHashValid(keccak256("anthropic.com"), KEY_HASH));
        vm.warp(cutoff + 1);
        assertFalse(reg.isKeyHashValid(keccak256("anthropic.com"), KEY_HASH));
    }

    function testRevokeKeyHash() public {
        vm.startPrank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
        assertTrue(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));
        reg.revokeKeyHash(DOMAIN_HASH, KEY_HASH);
        vm.stopPrank();
        assertFalse(reg.isKeyHashValid(DOMAIN_HASH, KEY_HASH));
        assertEq(reg.keyValidUntil(DOMAIN_HASH, KEY_HASH), 0, "revoked => 0");
    }

    function testRevokeKeyHashEmitsRevokedEvent() public {
        vm.prank(owner);
        reg.setKeyHash(DOMAIN_HASH, KEY_HASH, true);
        vm.expectEmit(true, true, false, false);
        emit PoaDKIMRegistry.KeyHashRevoked(DOMAIN_HASH, KEY_HASH);
        vm.prank(owner);
        reg.revokeKeyHash(DOMAIN_HASH, KEY_HASH);
    }

    function testBulkRevoke() public {
        bytes32[] memory domains = new bytes32[](2);
        bytes32[] memory keys = new bytes32[](2);
        domains[0] = keccak256("a.com");
        domains[1] = keccak256("b.com");
        keys[0] = bytes32(uint256(1));
        keys[1] = bytes32(uint256(2));

        vm.startPrank(owner);
        reg.setKeyHashes(domains, keys, true);
        assertTrue(reg.isKeyHashValid(domains[0], keys[0]));
        assertTrue(reg.isKeyHashValid(domains[1], keys[1]));

        reg.revokeKeyHashes(domains, keys);
        vm.stopPrank();
        assertFalse(reg.isKeyHashValid(domains[0], keys[0]));
        assertFalse(reg.isKeyHashValid(domains[1], keys[1]));
    }

    function testBulkRevokeLengthMismatchReverts() public {
        bytes32[] memory domains = new bytes32[](2);
        bytes32[] memory keys = new bytes32[](1);
        vm.prank(owner);
        vm.expectRevert(PoaDKIMRegistry.LengthMismatch.selector);
        reg.revokeKeyHashes(domains, keys);
    }

    function testExpiryAndRevocationOnlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(PoaDKIMRegistry.NotOwner.selector);
        reg.setKeyHashWithExpiry(DOMAIN_HASH, KEY_HASH, block.timestamp + 1 days);
        vm.expectRevert(PoaDKIMRegistry.NotOwner.selector);
        reg.revokeKeyHash(DOMAIN_HASH, KEY_HASH);
        vm.stopPrank();
    }
}
