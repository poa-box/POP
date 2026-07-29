// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";

/// @dev Stands in for the org Executor (the module's superAdmin): exposes the hat-minter authorization
///      the module's email-verified path authenticates against, and forwards superAdmin-gated calls.
contract MockMinterAuthorityExecutor {
    mapping(address => bool) public minters;

    function setMinter(address m, bool v) external {
        minters[m] = v;
    }

    function isAuthorizedHatMinter(address m) external view returns (bool) {
        return minters[m];
    }

    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec call failed");
        return ret;
    }
}

/// @dev Minimal IHats stand-in — only isWearerOfHat/isAdminOfHat are consulted (vouch path, unused here).
contract MockHatsMinimal {
    function isWearerOfHat(address, uint256) external pure returns (bool) {
        return false;
    }

    function isAdminOfHat(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @title Email-verified eligibility (THIRD path) — unit tests
/// @notice The verified email IS the eligibility grant: an authorized claim contract (org-approved hat
///         minter) marks a wearer email-verified; explicit per-wearer rules (kicks) always win.
contract EligibilityModuleEmailVerifiedTest is Test {
    EligibilityModule internal module;
    MockMinterAuthorityExecutor internal executor;

    address internal claimContract = makeAddr("zk-email-invites");
    address internal rando = makeAddr("rando");
    address internal claimer = makeAddr("claimer");
    address internal probe = address(uint160(uint256(keccak256("poa.zkemailinvites.claim.probe"))));
    uint256 internal constant HAT = 0x0000043500010001000100000000000000000000000000000000000000000000;
    uint256 internal constant HAT2 = 0x0000043500010001000200000000000000000000000000000000000000000000;

    function setUp() public {
        executor = new MockMinterAuthorityExecutor();
        module = _deployModule(address(executor));
        executor.setMinter(claimContract, true);
    }

    /// @dev Impl has `_disableInitializers()` — deploy behind a proxy like production (BeaconProxy there).
    function _deployModule(address superAdmin) internal returns (EligibilityModule) {
        EligibilityModule impl = new EligibilityModule();
        bytes memory init =
            abi.encodeCall(EligibilityModule.initialize, (superAdmin, address(new MockHatsMinimal()), address(1)));
        return EligibilityModule(address(new ERC1967Proxy(address(impl), init)));
    }

    function _hats(uint256 h) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = h;
    }

    /* ───────── authorization ───────── */

    function testAuthorizedMinterCanSetEmailVerified() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));
        assertTrue(module.isEmailVerified(claimer, HAT));
    }

    function testSuperAdminCanSetEmailVerified() public {
        executor.call(address(module), abi.encodeCall(EligibilityModule.setEmailVerified, (claimer, _hats(HAT))));
        assertTrue(module.isEmailVerified(claimer, HAT));
    }

    function testUnauthorizedCallerReverts() public {
        vm.prank(rando);
        vm.expectRevert(EligibilityModule.NotAuthorizedEmailVerifier.selector);
        module.setEmailVerified(claimer, _hats(HAT));
    }

    function testDeauthorizedMinterReverts() public {
        executor.setMinter(claimContract, false);
        vm.prank(claimContract);
        vm.expectRevert(EligibilityModule.NotAuthorizedEmailVerifier.selector);
        module.setEmailVerified(claimer, _hats(HAT));
    }

    /// @dev superAdmin without the getter (e.g. an EOA): fail closed for non-superAdmin callers.
    function testEoaSuperAdminFailsClosedForOthers() public {
        EligibilityModule m2 = _deployModule(makeAddr("eoa-admin"));
        vm.prank(claimContract);
        vm.expectRevert(EligibilityModule.NotAuthorizedEmailVerifier.selector);
        m2.setEmailVerified(claimer, _hats(HAT));
    }

    /* ───────── eligibility semantics ───────── */

    function testEmailVerifiedGrantsEligibilityAndStanding() public {
        (bool eligibleBefore,) = module.getWearerStatus(claimer, HAT);
        assertFalse(eligibleBefore, "gated hat: not eligible before");

        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));

        (bool eligible, bool standing) = module.getWearerStatus(claimer, HAT);
        assertTrue(eligible, "email-verified => eligible");
        assertTrue(standing, "email-verified => standing (no explicit rule)");
    }

    function testGrantIsPerHat() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));
        (bool eligibleOther,) = module.getWearerStatus(claimer, HAT2);
        assertFalse(eligibleOther, "grant must not leak to other hats");
    }

    function testGrantIsPerWearer_probeStaysIneligible() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));
        (bool probeEligible,) = module.getWearerStatus(probe, HAT);
        assertFalse(probeEligible, "H-03 sentinel probe must stay ineligible");
    }

    function testMultiHatBatchGrant() public {
        uint256[] memory both = new uint256[](2);
        both[0] = HAT;
        both[1] = HAT2;
        vm.prank(claimContract);
        module.setEmailVerified(claimer, both);
        (bool e1,) = module.getWearerStatus(claimer, HAT);
        (bool e2,) = module.getWearerStatus(claimer, HAT2);
        assertTrue(e1 && e2);
    }

    /* ───────── kicks/bans always win ───────── */

    function testExplicitKickBeatsEmailVerified() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));

        // Governance kicks the wearer: explicit (false, false) per-wearer rule.
        executor.call(
            address(module), abi.encodeCall(EligibilityModule.setWearerEligibility, (claimer, HAT, false, false))
        );

        (bool eligible,) = module.getWearerStatus(claimer, HAT);
        assertFalse(eligible, "explicit kick must beat email verification");
        assertTrue(module.isEmailVerified(claimer, HAT), "flag itself remains until cleared");
    }

    function testClearEmailVerified() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));
        executor.call(address(module), abi.encodeCall(EligibilityModule.clearEmailVerified, (claimer, HAT)));
        assertFalse(module.isEmailVerified(claimer, HAT));
        (bool eligible,) = module.getWearerStatus(claimer, HAT);
        assertFalse(eligible, "cleared => back to gated");
    }

    function testClearOnlySuperAdmin() public {
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));
        vm.prank(claimContract);
        vm.expectRevert(EligibilityModule.NotSuperAdmin.selector);
        module.clearEmailVerified(claimer, HAT);
    }

    /* ───────── events ───────── */

    event EmailVerifiedSet(address indexed wearer, uint256 indexed hatId, address indexed verifier);
    event EmailVerifiedCleared(address indexed wearer, uint256 indexed hatId, address indexed admin);

    function testEventsEmitted() public {
        vm.expectEmit(true, true, true, true);
        emit EmailVerifiedSet(claimer, HAT, claimContract);
        vm.prank(claimContract);
        module.setEmailVerified(claimer, _hats(HAT));

        vm.expectEmit(true, true, true, true);
        emit EmailVerifiedCleared(claimer, HAT, address(executor));
        executor.call(address(module), abi.encodeCall(EligibilityModule.clearEmailVerified, (claimer, HAT)));
    }
}
