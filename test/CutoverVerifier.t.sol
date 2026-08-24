// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CutoverVerifier} from "../src/CutoverVerifier.sol";

/*═══════════════════════════════ Minimal mocks (only the consumed selectors) ═══════════════════════════════*/

contract MockRouter {
    mapping(uint256 => address) public authorityOf;
    mapping(bytes32 => bool) internal _wears; // keccak(user,id) => bool
    mapping(uint256 => bool) internal _active;

    function setAuthorityOf(uint256 id, address a) external {
        authorityOf[id] = a;
    }

    function setWears(address user, uint256 id, bool v) external {
        _wears[keccak256(abi.encode(user, id))] = v;
    }

    function setActive(uint256 id, bool v) external {
        _active[id] = v;
    }

    function isWearerOfHat(address user, uint256 id) external view returns (bool) {
        return _wears[keccak256(abi.encode(user, id))];
    }

    function viewHat(uint256 id)
        external
        view
        returns (string memory, uint32, uint32, address, address, string memory, uint16, bool, bool)
    {
        return ("", 0, 0, address(0), address(0), "", 0, true, _active[id]);
    }
}

contract MockAuthority {
    bool public paused;
    mapping(uint256 => uint256) public memberCount;

    function setPaused(bool p) external {
        paused = p;
    }

    function setMemberCount(uint256 subject, uint256 c) external {
        memberCount[subject] = c;
    }
}

contract MockHats {
    mapping(uint256 => uint32) internal _supply;

    function setSupply(uint256 id, uint32 s) external {
        _supply[id] = s;
    }

    function hatSupply(uint256 id) external view returns (uint32) {
        return _supply[id];
    }
}

contract MockOrgRegistry {
    mapping(bytes32 => address) internal _exec;
    mapping(bytes32 => bool) internal _exists;

    function setOrg(bytes32 orgId, address executor, bool exists) external {
        _exec[orgId] = executor;
        _exists[orgId] = exists;
    }

    function orgOf(bytes32 orgId) external view returns (address, uint32, bool, bool) {
        return (_exec[orgId], 0, false, _exists[orgId]);
    }
}

/*═══════════════════════════════ Tests ═══════════════════════════════*/

contract CutoverVerifierTest is Test {
    CutoverVerifier internal verifier;
    MockRouter internal router;
    MockAuthority internal authority;
    MockHats internal hats;
    MockOrgRegistry internal orgRegistry;

    bytes32 internal constant ORG_ID = keccak256("org.cutover.test");
    address internal executor = address(0xE9EC);

    // Adopted legacy ids: admin (topHat) at [0], one role at [1].
    uint256 internal constant ADMIN = uint256(1077) << 224;
    uint256 internal constant ROLE = (uint256(1077) << 224) | (uint256(1) << 16) | 1;

    function setUp() public {
        router = new MockRouter();
        authority = new MockAuthority();
        hats = new MockHats();
        orgRegistry = new MockOrgRegistry();
        verifier = new CutoverVerifier(address(hats), address(orgRegistry));
        _happyState();
    }

    /// @dev Wire a fully-passing post-cutover state.
    function _happyState() internal {
        authority.setPaused(false);
        router.setAuthorityOf(ADMIN, address(authority));
        router.setAuthorityOf(ROLE, address(authority));
        authority.setMemberCount(ADMIN, 1);
        authority.setMemberCount(ROLE, 5);
        hats.setSupply(ADMIN, 1);
        hats.setSupply(ROLE, 8);
        orgRegistry.setOrg(ORG_ID, executor, true);
        router.setWears(executor, ADMIN, true);
        router.setActive(ADMIN, true);
    }

    function _subjects() internal pure returns (uint256[] memory s) {
        s = new uint256[](2);
        s[0] = ADMIN;
        s[1] = ROLE;
    }

    function _counts() internal pure returns (uint32[] memory c) {
        c = new uint32[](2);
        c[0] = 1;
        c[1] = 5;
    }

    function _verify() internal view {
        verifier.verify(ORG_ID, address(authority), address(router), _subjects(), _counts());
    }

    function testImmutablesPinned() public view {
        assertEq(verifier.hats(), address(hats));
        assertEq(verifier.orgRegistry(), address(orgRegistry));
    }

    function testVerifyPassesOnHealthyCutover() public view {
        _verify(); // reverts on any failure
    }

    function testRevertsOnNoSubjects() public {
        vm.expectRevert(CutoverVerifier.NoSubjects.selector);
        verifier.verify(ORG_ID, address(authority), address(router), new uint256[](0), new uint32[](0));
    }

    function testRevertsOnLengthMismatch() public {
        uint32[] memory c = new uint32[](1);
        c[0] = 1;
        vm.expectRevert(CutoverVerifier.ArrayLengthMismatch.selector);
        verifier.verify(ORG_ID, address(authority), address(router), _subjects(), c);
    }

    function testRevertsWhenAuthorityStillPaused() public {
        authority.setPaused(true);
        vm.expectRevert(CutoverVerifier.AuthorityPaused.selector);
        _verify();
    }

    function testRevertsWhenBindMissingOrSpoofed() public {
        // Spoof: ROLE routes to a different authority (a missing/hijacked bind).
        router.setAuthorityOf(ROLE, address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(CutoverVerifier.AuthorityNotBound.selector, ROLE, address(authority), address(0xBAD))
        );
        _verify();
    }

    function testRevertsOnMemberCountDrift() public {
        // A member joined between generation and announceWinner: live count 6 != expected 5.
        authority.setMemberCount(ROLE, 6);
        vm.expectRevert(abi.encodeWithSelector(CutoverVerifier.MemberCountDrift.selector, ROLE, uint256(5), uint256(6)));
        verifier.verify(ORG_ID, address(authority), address(router), _subjects(), _counts());
    }

    function testRevertsWhenMemberCountExceedsHatSupply() public {
        // memberCount 5 (== expected) but hats supply only 4 → self-referential-parity guard trips.
        authority.setMemberCount(ROLE, 5);
        hats.setSupply(ROLE, 4);
        vm.expectRevert(
            abi.encodeWithSelector(CutoverVerifier.MemberCountExceedsSupply.selector, ROLE, uint256(5), uint32(4))
        );
        _verify();
    }

    function testRevertsWhenOrgNotRegistered() public {
        orgRegistry.setOrg(ORG_ID, executor, false);
        vm.expectRevert(abi.encodeWithSelector(CutoverVerifier.OrgNotRegistered.selector, ORG_ID));
        _verify();
    }

    function testRevertsWhenAdminNotResolvedThroughRouter() public {
        router.setWears(executor, ADMIN, false);
        vm.expectRevert(abi.encodeWithSelector(CutoverVerifier.AdminNotResolved.selector, ADMIN, executor));
        _verify();
    }

    function testRevertsWhenAdminHatInactive() public {
        router.setActive(ADMIN, false);
        vm.expectRevert(abi.encodeWithSelector(CutoverVerifier.AdminHatInactive.selector, ADMIN));
        _verify();
    }

    function testMemberCountEqualToSupplyPasses() public {
        // Boundary: memberCount == hatSupply is allowed (<=), not a revert.
        authority.setMemberCount(ROLE, 8);
        hats.setSupply(ROLE, 8);
        uint32[] memory c = _counts();
        c[1] = 8;
        verifier.verify(ORG_ID, address(authority), address(router), _subjects(), c);
    }
}
