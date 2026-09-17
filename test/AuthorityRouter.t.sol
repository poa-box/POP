// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AuthorityRouter} from "../src/AuthorityRouter.sol";
import {IAuthorityRouter} from "../src/interfaces/IAuthorityRouter.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {MockHats} from "./mocks/MockHats.sol";
import {MockAuthority, MalformedAuthority, WritingHats} from "./mocks/MockAuthority.sol";

contract AuthorityRouterTest is Test {
    AuthorityRouter router;
    OrgRegistry reg;
    MockHats hats;
    MockAuthority authA;
    MockAuthority authB;

    address admin = address(0xADACAD);
    address hub = address(0x4111B); // stand-in PaymasterHub
    address executorA = address(0xE0A);
    address executorB = address(0xE0B);
    address userAlice = address(0xA11CE);
    address userBob = address(0xB0B);

    bytes32 constant ORG_A = keccak256("ORG_A");
    bytes32 constant ORG_B = keccak256("ORG_B");
    uint256 constant DOMAIN_A = 1;
    uint256 constant DOMAIN_B = 2;

    uint256 constant FLOOR = 1 << 224;

    /*───────────────────── setup ─────────────────────*/

    function setUp() public {
        hats = new MockHats();

        OrgRegistry regImpl = new OrgRegistry();
        reg = OrgRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl), abi.encodeCall(OrgRegistry.initialize, (address(this), address(hats)))
                )
            )
        );

        AuthorityRouter routerImpl = new AuthorityRouter();
        router = AuthorityRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeCall(AuthorityRouter.initialize, (address(hats), address(reg), hub, admin))
                )
            )
        );

        authA = new MockAuthority();
        authB = new MockAuthority();

        // Register two orgs + their hats trees (topHatId = domain << 224).
        reg.registerOrg(ORG_A, executorA, bytes("Org Alpha"), bytes32(0));
        reg.registerOrg(ORG_B, executorB, bytes("Org Beta"), bytes32(0));
        uint256[] memory none = new uint256[](0);
        reg.registerHatsTree(ORG_A, _topHat(DOMAIN_A), none);
        reg.registerHatsTree(ORG_B, _topHat(DOMAIN_B), none);
    }

    /*───────────────────── helpers ─────────────────────*/

    function _topHat(uint256 domain) internal pure returns (uint256) {
        return domain << 224;
    }

    function _legacyId(uint256 domain, uint256 local) internal pure returns (uint256) {
        return (domain << 224) | local;
    }

    function _v2Id(address authority, uint64 seq) internal pure returns (uint256) {
        return (uint256(uint160(authority)) << 64) | seq;
    }

    function _bindA() internal {
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authA));
    }

    function _bindB() internal {
        vm.prank(executorB);
        router.bindAuthority(ORG_B, DOMAIN_B, address(authB));
    }

    /*═══════════════════════ initialize ═══════════════════════*/

    function testInitializeSetsState() public {
        assertEq(router.hats(), address(hats));
        assertEq(router.orgRegistry(), address(reg));
        assertEq(router.paymasterHub(), hub);
        assertEq(router.admin(), admin);
    }

    function testInitializeEmitsEvents() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectEmit(true, true, true, true);
        emit IAuthorityRouter.RouterInitialized(address(hats), address(reg), admin);
        vm.expectEmit(true, true, true, true);
        emit IAuthorityRouter.PaymasterHubSet(hub);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (address(hats), address(reg), hub, admin))
        );
    }

    function testInitializeRevertsOnZeroHats() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (address(0), address(reg), hub, admin))
        );
    }

    function testInitializeRevertsOnZeroRegistry() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (address(hats), address(0), hub, admin))
        );
    }

    function testInitializeRevertsOnZeroHub() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (address(hats), address(reg), address(0), admin))
        );
    }

    function testInitializeRevertsOnZeroAdmin() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AuthorityRouter.initialize, (address(hats), address(reg), hub, address(0)))
        );
    }

    function testInitializeIsOneShot() public {
        vm.expectRevert();
        router.initialize(address(hats), address(reg), hub, admin);
    }

    function testImplementationInitializersDisabled() public {
        AuthorityRouter impl = new AuthorityRouter();
        vm.expectRevert();
        impl.initialize(address(hats), address(reg), hub, admin);
    }

    /*═══════════════════════ setPaymasterHub ═══════════════════════*/

    function testSetPaymasterHubByAdmin() public {
        address newHub = address(0xBEEF);
        vm.expectEmit(true, true, true, true);
        emit IAuthorityRouter.PaymasterHubSet(newHub);
        vm.prank(admin);
        router.setPaymasterHub(newHub);
        assertEq(router.paymasterHub(), newHub);
    }

    function testSetPaymasterHubRevertsForNonAdmin() public {
        vm.expectRevert(IAuthorityRouter.NotAdmin.selector);
        vm.prank(userAlice);
        router.setPaymasterHub(address(0xBEEF));
    }

    function testSetPaymasterHubRevertsOnZero() public {
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        vm.prank(admin);
        router.setPaymasterHub(address(0));
    }

    /*═══════════════════════ bindAuthority ═══════════════════════*/

    function testBindAuthoritySuccess() public {
        vm.expectEmit(true, true, true, true);
        emit IAuthorityRouter.AuthorityBound(ORG_A, DOMAIN_A, address(authA));
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authA));

        assertEq(router.authorityOf(_legacyId(DOMAIN_A, 7)), address(authA));
    }

    function testBindRevertsOnZeroAuthority() public {
        vm.expectRevert(IAuthorityRouter.ZeroAddress.selector);
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_A, address(0));
    }

    function testBindRevertsForNonExecutor() public {
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        vm.prank(userAlice);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authA));
    }

    function testBindRevertsForUnknownOrg() public {
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        vm.prank(executorA);
        router.bindAuthority(keccak256("GHOST"), DOMAIN_A, address(authA));
    }

    function testBindRevertsOnDomainMismatch() public {
        // executorA is the real executor, but claims org B's domain — must fail on domain, not auth.
        vm.expectRevert(IAuthorityRouter.TopHatDomainMismatch.selector);
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_B, address(authA));
    }

    function testBindSpoofForeignOrgRejected() public {
        // A malicious authority's controller tries to bind a victim org's domain as themselves.
        // They are not the victim's executor → NotOrgExecutor (cannot even reach the domain check).
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        vm.prank(executorB);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authB));
    }

    function testBindRevertsWhenAlreadyBound() public {
        _bindA();
        vm.expectRevert(IAuthorityRouter.AlreadyBound.selector);
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authB));
    }

    function testBindRevertsWhenNoTreeRegistered() public {
        // Org with an executor but no registered topHat → recordedDomain == 0 → mismatch.
        bytes32 orgC = keccak256("ORG_C");
        address executorC = address(0xE0C);
        reg.registerOrg(orgC, executorC, bytes("Org Gamma"), bytes32(0));
        vm.expectRevert(IAuthorityRouter.TopHatDomainMismatch.selector);
        vm.prank(executorC);
        router.bindAuthority(orgC, 0, address(authA));
    }

    /*═══════════════════════ unbindAuthority ═══════════════════════*/

    function testUnbindAuthoritySuccess() public {
        _bindA();
        vm.expectEmit(true, true, true, true);
        emit IAuthorityRouter.AuthorityUnbound(ORG_A, DOMAIN_A, address(authA));
        vm.prank(executorA);
        router.unbindAuthority(ORG_A, DOMAIN_A);

        assertEq(router.authorityOf(_legacyId(DOMAIN_A, 7)), address(0));
    }

    function testUnbindRevertsWhenNotBound() public {
        vm.expectRevert(IAuthorityRouter.NotBound.selector);
        vm.prank(executorA);
        router.unbindAuthority(ORG_A, DOMAIN_A);
    }

    function testUnbindRevertsForNonExecutor() public {
        _bindA();
        vm.expectRevert(IAuthorityRouter.NotOrgExecutor.selector);
        vm.prank(userAlice);
        router.unbindAuthority(ORG_A, DOMAIN_A);
    }

    function testUnbindRevertsOnDomainMismatch() public {
        _bindA();
        vm.expectRevert(IAuthorityRouter.TopHatDomainMismatch.selector);
        vm.prank(executorA);
        router.unbindAuthority(ORG_A, DOMAIN_B);
    }

    function testRebindAfterUnbindRollback() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 3);
        authA.setWearer(userAlice, id, true);
        assertTrue(router.isWearerOfHat(userAlice, id));

        vm.prank(executorA);
        router.unbindAuthority(ORG_A, DOMAIN_A);
        // Now unbound → passthrough to Hats (holds nothing for this id) → false.
        assertFalse(router.isWearerOfHat(userAlice, id));

        // Rebind to a different authority (rollback/replace path).
        vm.prank(executorA);
        router.bindAuthority(ORG_A, DOMAIN_A, address(authB));
        authB.setWearer(userAlice, id, true);
        assertTrue(router.isWearerOfHat(userAlice, id));
        assertEq(router.authorityOf(id), address(authB));
    }

    /*═══════════════════════ authorityOf ═══════════════════════*/

    function testAuthorityOfLegacyUnbound() public view {
        assertEq(router.authorityOf(_legacyId(DOMAIN_A, 1)), address(0));
    }

    function testAuthorityOfV2IdIsZero() public {
        _bindA();
        // v2 embedded ids self-route; they are never in the legacy binding table.
        assertEq(router.authorityOf(_v2Id(address(authA), 5)), address(0));
    }

    /*═══════════════════════ classification: legacy bound (native) ═══════════════════════*/

    function testLegacyBoundRoutesToAuthority() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 42);
        authA.setWearer(userAlice, id, true);
        authA.setEligible(userAlice, id, true);
        authA.setStanding(userAlice, id, true);

        assertTrue(router.isWearerOfHat(userAlice, id));
        assertTrue(router.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), 1);
        (bool e, bool s) = router.getWearerStatus(userAlice, id);
        assertTrue(e);
        assertTrue(s);
    }

    /*═══════════════════════ classification: legacy unbound (passthrough) ═══════════════════════*/

    function testLegacyUnboundPassesThroughToHats() public {
        uint256 id = _legacyId(99, 5); // unbound domain
        hats.mintHat(id, userAlice); // sets wearer + active
        hats.setEligible(userAlice, id, true);

        assertEq(router.isWearerOfHat(userAlice, id), hats.isWearerOfHat(userAlice, id));
        assertEq(router.isEligible(userAlice, id), hats.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), hats.balanceOf(userAlice, id));
        assertTrue(router.isWearerOfHat(userAlice, id));
    }

    function testLegacyNeverMintedSafeZeros() public view {
        uint256 id = _legacyId(123, 456);
        assertFalse(router.isWearerOfHat(userBob, id));
        assertFalse(router.isEligible(userBob, id));
        assertEq(router.balanceOf(userBob, id), 0);
    }

    /*═══════════════════════ classification: garbage sub-2^64 (passthrough safe zeros) ═══════════════════════*/

    function testGarbageLowIdSafeZeros() public view {
        uint256 id = 42; // < 2^64, no embedded address
        assertFalse(router.isWearerOfHat(userAlice, id));
        assertFalse(router.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), 0);
        (bool e, bool s) = router.getWearerStatus(userAlice, id);
        assertFalse(e);
        assertFalse(s);
    }

    function testZeroIdSafeZeros() public view {
        assertFalse(router.isWearerOfHat(userAlice, 0));
        assertEq(router.balanceOf(userAlice, 0), 0);
    }

    /*═══════════════════════ classification: v2 embedded, code present (self-route) ═══════════════════════*/

    function testV2EmbeddedSelfRoutes() public {
        uint256 id = _v2Id(address(authA), 9);
        authA.setWearer(userAlice, id, true);
        authA.setEligible(userAlice, id, true);

        assertTrue(router.isWearerOfHat(userAlice, id));
        assertTrue(router.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), 1);
        // No bind was needed.
        assertEq(router.authorityOf(id), address(0));
    }

    /*═══════════════════════ classification: v2 embedded, no code (EMPTY) ═══════════════════════*/

    function testV2EmbeddedCodelessResolvesEmpty() public {
        address ghost = makeAddr("ghost-codeless-authority");
        assertEq(ghost.code.length, 0);
        uint256 id = _v2Id(ghost, 1);

        assertFalse(router.isWearerOfHat(userAlice, id));
        assertFalse(router.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), 0);
        (bool e, bool s) = router.getWearerStatus(userAlice, id);
        assertFalse(e);
        assertFalse(s);
        assertFalse(router.checkHatWearerStatus(id, userAlice));

        (,,,,,,,, bool active) = router.viewHat(id);
        assertFalse(active);
    }

    /*═══════════════════════ classification: v2 embedded, malformed returndata (EMPTY) ═══════════════════════*/

    function testV2EmbeddedMalformedResolvesEmpty() public {
        MalformedAuthority mal = new MalformedAuthority();
        uint256 id = _v2Id(address(mal), 1);

        // All hub-consumed selectors must resolve EMPTY, never revert, despite garbage returndata.
        assertFalse(router.isWearerOfHat(userAlice, id));
        assertFalse(router.isEligible(userAlice, id));
        assertEq(router.balanceOf(userAlice, id), 0);
        (bool e,) = router.getWearerStatus(userAlice, id);
        assertFalse(e);
        (,,,,,,,, bool active) = router.viewHat(id);
        assertFalse(active);
    }

    /*═══════════════════════ passthrough viewHat 9-field parity ═══════════════════════*/

    struct Hat9 {
        string details;
        uint32 maxSupply;
        uint32 supply;
        address eligibility;
        address toggle;
        string imageURI;
        uint16 lastHatId;
        bool mutable_;
        bool active;
    }

    function _routerHat(uint256 id) internal view returns (Hat9 memory h) {
        (h.details, h.maxSupply, h.supply, h.eligibility, h.toggle, h.imageURI, h.lastHatId, h.mutable_, h.active) =
            router.viewHat(id);
    }

    function _hatsHat(uint256 id) internal view returns (Hat9 memory h) {
        (h.details, h.maxSupply, h.supply, h.eligibility, h.toggle, h.imageURI, h.lastHatId, h.mutable_, h.active) =
            hats.viewHat(id);
    }

    function testViewHatPassthroughParity() public {
        uint256 id = _legacyId(77, 1);
        hats.setEligible(userAlice, id, true); // flips activeHats[id] = true

        // Byte-parity of the full nine-field record through the passthrough arm.
        assertEq(abi.encode(_routerHat(id)), abi.encode(_hatsHat(id)));
        assertTrue(_routerHat(id).active);
    }

    function testViewHatNativeAuthority() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 8);
        authA.setHatView(
            id,
            MockAuthority.HatView({
                details: "ADMIN",
                maxSupply: 5,
                supply: 2,
                eligibility: address(authA),
                toggle: address(authA),
                imageURI: "ipfs://x",
                lastHatId: 0,
                mutable_: true,
                active: true
            })
        );

        (string memory d, uint32 mx, uint32 sp, address el, address tg, string memory iu, uint16 lh, bool mu, bool ac) =
            router.viewHat(id);
        assertEq(d, "ADMIN");
        assertEq(mx, 5);
        assertEq(sp, 2);
        assertEq(el, address(authA));
        assertEq(tg, address(authA));
        assertEq(iu, "ipfs://x");
        assertEq(lh, 0);
        assertTrue(mu);
        assertTrue(ac);
    }

    /*═══════════════════════ checkHatWearerStatus uses CALL (R5) ═══════════════════════*/

    function testCheckHatWearerStatusNativeUsesCall() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 11);
        authA.setWearer(userAlice, id, true);

        assertEq(authA.checkCallCount(), 0);
        bool r = router.checkHatWearerStatus(id, userAlice);
        assertTrue(r);
        // The SSTORE inside the mock proves a STATICCALL was NOT used.
        assertEq(authA.checkCallCount(), 1);
    }

    function testCheckHatWearerStatusPassthroughUsesCall() public {
        // Fresh router pointed at a Hats stand-in that SSTOREs in checkHatWearerStatus.
        WritingHats whats = new WritingHats();
        AuthorityRouter impl = new AuthorityRouter();
        AuthorityRouter r2 = AuthorityRouter(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(AuthorityRouter.initialize, (address(whats), address(reg), hub, admin))
                )
            )
        );

        uint256 id = _legacyId(555, 1); // unbound → passthrough to whats
        assertEq(whats.writes(), 0);
        bool ok = r2.checkHatWearerStatus(id, userAlice);
        assertTrue(ok);
        assertEq(whats.writes(), 1); // STATICCALL would have reverted
    }

    /*═══════════════════════ hub revert-wrapping differential ═══════════════════════*/

    function testBoundAuthorityRevertPropagatesForNonHub() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 21);
        authA.setRevertAll(true);

        // Legacy-bound authority reverting: a normal caller gets honest propagation.
        vm.expectRevert(bytes("MockAuthority: revert"));
        router.isEligible(userAlice, id);
    }

    function testBoundAuthorityRevertWrappedForHub() public {
        _bindA();
        uint256 id = _legacyId(DOMAIN_A, 21);
        authA.setRevertAll(true);

        // Same reverting authority, but the hub gets a clean false (cannot brick validateUserOp).
        vm.prank(hub);
        assertFalse(router.isEligible(userAlice, id));
        vm.prank(hub);
        assertFalse(router.isWearerOfHat(userAlice, id));
        vm.prank(hub);
        assertEq(router.balanceOf(userAlice, id), 0);
    }

    function testV2AuthorityRevertResolvesEmptyForAllCallers() public {
        uint256 id = _v2Id(address(authA), 3);
        authA.setRevertAll(true);

        // Self-routing v2 authority: a revert resolves EMPTY structurally — even for a non-hub caller.
        vm.prank(userAlice);
        assertFalse(router.isEligible(userAlice, id));
        // And for the hub too.
        vm.prank(hub);
        assertFalse(router.isEligible(userAlice, id));
    }

    function testPassthroughRevertPropagatesForNonHubButWrapsForHub() public {
        uint256 id = _legacyId(88, 1); // unbound → passthrough
        hats.setRevertOnEligible(true);

        // Non-hub caller: honest propagation of the Hats revert.
        vm.expectRevert(bytes("MockHats: eligibility probe reverted"));
        router.isEligible(userAlice, id);

        // Hub caller: wrapped to false.
        vm.prank(hub);
        assertFalse(router.isEligible(userAlice, id));
    }

    /*═══════════════════════ balanceOfBatch ═══════════════════════*/

    function testBalanceOfBatchMixedIds() public {
        _bindA();
        uint256 boundId = _legacyId(DOMAIN_A, 30);
        uint256 v2Id = _v2Id(address(authB), 4);
        uint256 passId = _legacyId(200, 1);
        uint256 emptyId = _v2Id(makeAddr("codeless-batch-target"), 1);

        authA.setWearer(userAlice, boundId, true);
        authB.setWearer(userAlice, v2Id, true);
        hats.mintHat(passId, userAlice);

        address[] memory users = new address[](4);
        uint256[] memory ids = new uint256[](4);
        users[0] = userAlice;
        users[1] = userAlice;
        users[2] = userAlice;
        users[3] = userAlice;
        ids[0] = boundId;
        ids[1] = v2Id;
        ids[2] = passId;
        ids[3] = emptyId;

        uint256[] memory bals = router.balanceOfBatch(users, ids);
        assertEq(bals[0], 1); // bound authority
        assertEq(bals[1], 1); // v2 self-route
        assertEq(bals[2], 1); // passthrough
        assertEq(bals[3], 0); // codeless empty
    }

    function testBalanceOfBatchLengthMismatchReverts() public {
        address[] memory users = new address[](1);
        uint256[] memory ids = new uint256[](2);
        vm.expectRevert(AuthorityRouter.ArrayLengthMismatchRouter.selector);
        router.balanceOfBatch(users, ids);
    }

    /*═══════════════════════ two-org routing isolation ═══════════════════════*/

    function testTwoOrgRoutingIsolation() public {
        _bindA();
        _bindB();

        uint256 idA = _legacyId(DOMAIN_A, 1);
        uint256 idB = _legacyId(DOMAIN_B, 1);

        // Alice is a wearer in A only; Bob in B only.
        authA.setWearer(userAlice, idA, true);
        authB.setWearer(userBob, idB, true);

        assertTrue(router.isWearerOfHat(userAlice, idA));
        assertFalse(router.isWearerOfHat(userAlice, idB)); // no leak into B
        assertTrue(router.isWearerOfHat(userBob, idB));
        assertFalse(router.isWearerOfHat(userBob, idA)); // no leak into A

        assertEq(router.authorityOf(idA), address(authA));
        assertEq(router.authorityOf(idB), address(authB));
    }

    function testUnbindMidBatchLeavesOtherOrgIntact() public {
        _bindA();
        _bindB();
        uint256 idA = _legacyId(DOMAIN_A, 2);
        uint256 idB = _legacyId(DOMAIN_B, 2);
        authA.setWearer(userAlice, idA, true);
        authB.setWearer(userBob, idB, true);

        // Simulate an unbind occurring mid-cutover-batch for org A only.
        vm.prank(executorA);
        router.unbindAuthority(ORG_A, DOMAIN_A);

        assertFalse(router.isWearerOfHat(userAlice, idA)); // A now passthrough → false
        assertTrue(router.isWearerOfHat(userBob, idB)); // B untouched
        assertEq(router.authorityOf(idA), address(0));
        assertEq(router.authorityOf(idB), address(authB));
    }
}
