// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";

import {RoleBundleHatter} from "../src/RoleBundleHatter.sol";
import {IRoleBundleHatter} from "../src/interfaces/IRoleBundleHatter.sol";

import {MockHats} from "./mocks/MockHats.sol";

/**
 * @notice Mocks the Executor.mintHatsForUser entrypoint.
 *         RoleBundleHatter forwards mints through this contract, which in turn calls
 *         hats.mintHat for each ID — mirroring the real Executor pattern.
 */
contract MockExecutorMint {
    IHats public hats;
    bool public shouldRevert;
    address public lastUser;
    uint256[] public lastHatIds;

    constructor(IHats _hats) {
        hats = _hats;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        require(!shouldRevert, "MockExecutor revert");
        lastUser = user;
        delete lastHatIds;
        for (uint256 i = 0; i < hatIds.length; i++) {
            lastHatIds.push(hatIds[i]);
            hats.mintHat(hatIds[i], user);
        }
    }

    function lastHatIdsLength() external view returns (uint256) {
        return lastHatIds.length;
    }
}

/**
 * @notice Minimal mock of EligibilityModule's `setWearerEligibility`. Records every revoke
 *         call (for assertion) and writes false eligibility into MockHats via setHatWearerStatus
 *         so the cascade's `isWearerOfHat` re-queries see the user lose the hat.
 */
contract MockEligibilityModule {
    IHats public hats;

    struct RevokeRecord {
        address user;
        uint256 hatId;
        bool eligible;
        bool standing;
    }

    RevokeRecord[] public records;
    // Count of calls that revoke eligibility (`!eligible || !standing`). Tracked separately
    // so cascade-revoke tests can assert on the revoke count without picking up the
    // pre-mint eligibility-reset writes that `RoleBundleHatter.mintRole` performs.
    uint256 public revokeCount;
    // Mirror count for the pre-mint eligibility-reset path — useful for asserting that
    // mintRole correctly re-enables eligibility before invoking the mint.
    uint256 public resetCount;
    bool public shouldRevert;
    // Mirror EligibilityModule's `hasSpecificWearerRules`: once an explicit (user, hat) rule has
    // been written, this is true. RoleBundleHatter.mintRole gates its pre-mint eligibility reset
    // on this, so the mock must track it for the re-mint-after-revoke path to behave like prod.
    mapping(address => mapping(uint256 => bool)) internal _hasRule;

    constructor(IHats _hats) {
        hats = _hats;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setWearerEligibility(address user, uint256 hatId, bool eligible, bool standing) external {
        require(!shouldRevert, "MockEligibility: revert");
        records.push(RevokeRecord(user, hatId, eligible, standing));
        if (!eligible || !standing) {
            revokeCount++;
        } else {
            resetCount++;
        }
        _hasRule[user][hatId] = true;
        // Mirror the live behavior: write eligibility through to Hats so isWearerOfHat queries
        // see the post-revoke state.
        hats.setHatWearerStatus(hatId, user, eligible, standing);
    }

    function hasSpecificWearerRules(address user, uint256 hatId) external view returns (bool) {
        return _hasRule[user][hatId];
    }

    function recordCount() external view returns (uint256) {
        return records.length;
    }

    function lastRecord() external view returns (RevokeRecord memory) {
        require(records.length > 0, "no records");
        return records[records.length - 1];
    }

    function getRecord(uint256 i) external view returns (RevokeRecord memory) {
        return records[i];
    }

    function clearRecords() external {
        delete records;
        revokeCount = 0;
        resetCount = 0;
    }
}

contract RoleBundleHatterTest is Test {
    RoleBundleHatter hatter;
    MockHats hats;
    MockExecutorMint executor;

    address constant DEPLOYER = address(0xDEAD);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant MINTER = address(0xBEEF);

    uint256 constant VP_HAT = 1001;
    uint256 constant EXEC_HAT = 1002;
    uint256 constant CAP_TASK_CREATE = 2001;
    uint256 constant CAP_TASK_REVIEW = 2002;
    uint256 constant CAP_VOTE = 2003;
    uint256 constant CAP_PROPOSE = 2004;

    event RoleBundleHatterInitialized(address indexed hats, address indexed executor, address indexed deployer);
    event DeployerCleared(address indexed clearedBy);
    event BundleSet(uint256 indexed roleHat, uint256[] capabilityHats);
    event BundleUpdated(uint256 indexed roleHat, uint256 indexed capabilityHat, bool added);
    event RoleMinted(uint256 indexed roleHat, address indexed user, uint256 hatsMinted);
    event AuthorizedMinterSet(address indexed minter, bool authorized);

    function setUp() public {
        hats = new MockHats();
        executor = new MockExecutorMint(IHats(address(hats)));

        RoleBundleHatter impl = new RoleBundleHatter();
        bytes memory data = abi.encodeCall(RoleBundleHatter.initialize, (address(hats), address(executor), DEPLOYER));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        hatter = RoleBundleHatter(address(proxy));
    }

    /* ─────────── Initialization ─────────── */

    function testInitializeSetsFields() public {
        assertEq(hatter.hats(), address(hats));
        assertEq(hatter.executor(), address(executor));
        assertEq(hatter.deployer(), DEPLOYER);
    }

    function testInitializeZeroHatsReverts() public {
        RoleBundleHatter impl = new RoleBundleHatter();
        bytes memory data = abi.encodeCall(RoleBundleHatter.initialize, (address(0), address(executor), DEPLOYER));
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeZeroExecutorReverts() public {
        RoleBundleHatter impl = new RoleBundleHatter();
        bytes memory data = abi.encodeCall(RoleBundleHatter.initialize, (address(hats), address(0), DEPLOYER));
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeZeroDeployerReverts() public {
        RoleBundleHatter impl = new RoleBundleHatter();
        bytes memory data = abi.encodeCall(RoleBundleHatter.initialize, (address(hats), address(executor), address(0)));
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testCannotReinitialize() public {
        vm.expectRevert();
        hatter.initialize(address(hats), address(executor), DEPLOYER);
    }

    /* ─────────── Deployer / Executor auth ─────────── */

    function testDeployerCanCallAdmin() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        assertEq(hatter.bundleSize(VP_HAT), 1);
    }

    function testExecutorCanCallAdmin() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.prank(address(executor));
        hatter.setBundle(VP_HAT, caps);
        assertEq(hatter.bundleSize(VP_HAT), 1);
    }

    function testUnauthorizedAdminCallReverts() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.prank(ALICE);
        vm.expectRevert(RoleBundleHatter.NotAdmin.selector);
        hatter.setBundle(VP_HAT, caps);
    }

    function testClearDeployerRemovesDeployerAccess() public {
        vm.prank(DEPLOYER);
        hatter.clearDeployer();
        assertEq(hatter.deployer(), address(0));

        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.NotAdmin.selector);
        hatter.setBundle(VP_HAT, caps);
    }

    function testClearDeployerByExecutorWorks() public {
        vm.prank(address(executor));
        hatter.clearDeployer();
        assertEq(hatter.deployer(), address(0));
    }

    function testExecutorStillWorksAfterDeployerCleared() public {
        vm.prank(DEPLOYER);
        hatter.clearDeployer();

        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.prank(address(executor));
        hatter.setBundle(VP_HAT, caps);
        assertEq(hatter.bundleSize(VP_HAT), 1);
    }

    /* ─────────── setBundle ─────────── */

    function testSetBundleStoresEntries() public {
        uint256[] memory caps = new uint256[](3);
        caps[0] = CAP_TASK_CREATE;
        caps[1] = CAP_TASK_REVIEW;
        caps[2] = CAP_VOTE;

        vm.prank(DEPLOYER);
        vm.expectEmit(true, false, false, true);
        emit BundleSet(VP_HAT, caps);
        hatter.setBundle(VP_HAT, caps);

        assertEq(hatter.bundleSize(VP_HAT), 3);
        assertTrue(hatter.isInBundle(VP_HAT, CAP_TASK_CREATE));
        assertTrue(hatter.isInBundle(VP_HAT, CAP_TASK_REVIEW));
        assertTrue(hatter.isInBundle(VP_HAT, CAP_VOTE));
        assertFalse(hatter.isInBundle(VP_HAT, CAP_PROPOSE));

        uint256[] memory stored = hatter.getBundle(VP_HAT);
        assertEq(stored.length, 3);
    }

    function testSetBundleDedupsDuplicates() public {
        uint256[] memory caps = new uint256[](3);
        caps[0] = CAP_TASK_CREATE;
        caps[1] = CAP_TASK_CREATE; // duplicate
        caps[2] = CAP_VOTE;

        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);

        assertEq(hatter.bundleSize(VP_HAT), 2);
    }

    function testSetBundleReplacesPrevious() public {
        uint256[] memory first = new uint256[](2);
        first[0] = CAP_TASK_CREATE;
        first[1] = CAP_TASK_REVIEW;
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, first);

        uint256[] memory second = new uint256[](1);
        second[0] = CAP_VOTE;
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, second);

        assertEq(hatter.bundleSize(VP_HAT), 1);
        assertFalse(hatter.isInBundle(VP_HAT, CAP_TASK_CREATE));
        assertFalse(hatter.isInBundle(VP_HAT, CAP_TASK_REVIEW));
        assertTrue(hatter.isInBundle(VP_HAT, CAP_VOTE));
    }

    function testSetBundleTooLargeReverts() public {
        uint256 maxSize = hatter.MAX_BUNDLE_SIZE();
        uint256[] memory caps = new uint256[](maxSize + 1);
        for (uint256 i; i < caps.length; ++i) {
            caps[i] = 1000 + i;
        }
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.BundleTooLarge.selector);
        hatter.setBundle(VP_HAT, caps);
    }

    function testSetBundleEmptyArrayClears() public {
        uint256[] memory first = new uint256[](1);
        first[0] = CAP_TASK_CREATE;
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, first);
        assertEq(hatter.bundleSize(VP_HAT), 1);

        uint256[] memory empty = new uint256[](0);
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, empty);
        assertEq(hatter.bundleSize(VP_HAT), 0);
        assertFalse(hatter.isInBundle(VP_HAT, CAP_TASK_CREATE));
    }

    /* ─────────── addToBundle / removeFromBundle ─────────── */

    function testAddToBundleAppends() public {
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, false, true);
        emit BundleUpdated(VP_HAT, CAP_VOTE, true);
        hatter.addToBundle(VP_HAT, CAP_VOTE);
        assertEq(hatter.bundleSize(VP_HAT), 1);
        assertTrue(hatter.isInBundle(VP_HAT, CAP_VOTE));
    }

    function testAddToBundleDuplicateReverts() public {
        vm.startPrank(DEPLOYER);
        hatter.addToBundle(VP_HAT, CAP_VOTE);
        vm.expectRevert(RoleBundleHatter.AlreadyInBundle.selector);
        hatter.addToBundle(VP_HAT, CAP_VOTE);
        vm.stopPrank();
    }

    function testAddToBundleZeroHatReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.ZeroHat.selector);
        hatter.addToBundle(VP_HAT, 0);
    }

    function testAddToBundleSelfBundleReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.SelfBundle.selector);
        hatter.addToBundle(VP_HAT, VP_HAT);
    }

    function testSetBundleZeroHatInArrayReverts() public {
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP_VOTE;
        caps[1] = 0; // zero
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.ZeroHat.selector);
        hatter.setBundle(VP_HAT, caps);
    }

    function testSetBundleSelfInArrayReverts() public {
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP_VOTE;
        caps[1] = VP_HAT; // self
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.SelfBundle.selector);
        hatter.setBundle(VP_HAT, caps);
    }

    function testAddToBundleTooLargeReverts() public {
        uint256 maxSize = hatter.MAX_BUNDLE_SIZE();
        vm.startPrank(DEPLOYER);
        // Use IDs that don't collide with VP_HAT (1001) — skip the self-bundle check
        for (uint256 i; i < maxSize; ++i) {
            hatter.addToBundle(VP_HAT, 50_000 + i);
        }
        vm.expectRevert(RoleBundleHatter.BundleTooLarge.selector);
        hatter.addToBundle(VP_HAT, 99_999);
        vm.stopPrank();
    }

    function testRemoveFromBundleSwapAndPop() public {
        vm.startPrank(DEPLOYER);
        hatter.addToBundle(VP_HAT, CAP_TASK_CREATE);
        hatter.addToBundle(VP_HAT, CAP_TASK_REVIEW);
        hatter.addToBundle(VP_HAT, CAP_VOTE);

        vm.expectEmit(true, true, false, true);
        emit BundleUpdated(VP_HAT, CAP_TASK_REVIEW, false);
        hatter.removeFromBundle(VP_HAT, CAP_TASK_REVIEW);
        vm.stopPrank();

        assertEq(hatter.bundleSize(VP_HAT), 2);
        assertFalse(hatter.isInBundle(VP_HAT, CAP_TASK_REVIEW));
        assertTrue(hatter.isInBundle(VP_HAT, CAP_TASK_CREATE));
        assertTrue(hatter.isInBundle(VP_HAT, CAP_VOTE));
    }

    function testRemoveFromBundleNotPresentReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.NotInBundle.selector);
        hatter.removeFromBundle(VP_HAT, CAP_VOTE);
    }

    /* ─────────── setAuthorizedMinter ─────────── */

    function testSetAuthorizedMinter() public {
        assertFalse(hatter.isAuthorizedMinter(MINTER));
        vm.prank(DEPLOYER);
        vm.expectEmit(true, false, false, true);
        emit AuthorizedMinterSet(MINTER, true);
        hatter.setAuthorizedMinter(MINTER, true);
        assertTrue(hatter.isAuthorizedMinter(MINTER));

        vm.prank(DEPLOYER);
        hatter.setAuthorizedMinter(MINTER, false);
        assertFalse(hatter.isAuthorizedMinter(MINTER));
    }

    function testSetAuthorizedMinterZeroReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        hatter.setAuthorizedMinter(address(0), true);
    }

    function testSetAuthorizedMinterUnauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(RoleBundleHatter.NotAdmin.selector);
        hatter.setAuthorizedMinter(MINTER, true);
    }

    /* ─────────── mintRole — happy paths ─────────── */

    function testMintRoleMintsRoleAndBundle() public {
        // Configure bundle: VP role → [task.create, task.review, vote]
        uint256[] memory caps = new uint256[](3);
        caps[0] = CAP_TASK_CREATE;
        caps[1] = CAP_TASK_REVIEW;
        caps[2] = CAP_VOTE;
        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setAuthorizedMinter(MINTER, true);
        vm.stopPrank();

        // Sanity: Alice wears nothing
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));

        vm.prank(MINTER);
        vm.expectEmit(true, true, false, true);
        emit RoleMinted(VP_HAT, ALICE, 4); // 1 role + 3 capabilities
        hatter.mintRole(VP_HAT, ALICE);

        // Alice should now wear role hat + all 3 capability hats
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_REVIEW));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_VOTE));

        // Executor saw the full hat list pass through
        assertEq(executor.lastUser(), ALICE);
        assertEq(executor.lastHatIdsLength(), 4);
    }

    function testMintRoleEmptyBundleStillMintsRoleHat() public {
        vm.prank(DEPLOYER);
        hatter.setAuthorizedMinter(MINTER, true);

        // No bundle set for VP_HAT

        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);

        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertEq(executor.lastHatIdsLength(), 1);
    }

    function testMintRoleIdempotentSkipsAlreadyWornHats() public {
        // Configure bundle
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP_TASK_CREATE;
        caps[1] = CAP_VOTE;
        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setAuthorizedMinter(MINTER, true);
        vm.stopPrank();

        // Pre-mint role hat + one capability so they're already worn
        hats.mintHat(VP_HAT, ALICE);
        hats.mintHat(CAP_TASK_CREATE, ALICE);

        // mintRole should only mint the remaining capability hat
        vm.prank(MINTER);
        vm.expectEmit(true, true, false, true);
        emit RoleMinted(VP_HAT, ALICE, 1);
        hatter.mintRole(VP_HAT, ALICE);

        assertEq(executor.lastHatIdsLength(), 1);
        assertTrue(hats.isWearerOfHat(ALICE, CAP_VOTE));
    }

    function testMintRoleFullyAlreadyWornNoOp() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setAuthorizedMinter(MINTER, true);
        vm.stopPrank();

        hats.mintHat(VP_HAT, ALICE);
        hats.mintHat(CAP_TASK_CREATE, ALICE);

        // Reset executor tracking
        executor.setShouldRevert(false);

        vm.prank(MINTER);
        vm.expectEmit(true, true, false, true);
        emit RoleMinted(VP_HAT, ALICE, 0);
        hatter.mintRole(VP_HAT, ALICE);

        // No mint call was made — lastUser stays from prior state (default address(0))
        assertEq(executor.lastUser(), address(0));
    }

    /* ─────────── mintRole — auth + validation ─────────── */

    function testMintRoleUnauthorizedCallerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(RoleBundleHatter.NotAuthorizedMinter.selector);
        hatter.mintRole(VP_HAT, BOB);
    }

    function testMintRoleZeroUserReverts() public {
        vm.prank(DEPLOYER);
        hatter.setAuthorizedMinter(MINTER, true);

        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        hatter.mintRole(VP_HAT, address(0));
    }

    function testMintRoleAfterMinterRevokedReverts() public {
        vm.startPrank(DEPLOYER);
        hatter.setAuthorizedMinter(MINTER, true);
        hatter.setAuthorizedMinter(MINTER, false);
        vm.stopPrank();

        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.NotAuthorizedMinter.selector);
        hatter.mintRole(VP_HAT, ALICE);
    }

    /* ─────────── Composition: two roles with overlapping capabilities ─────────── */

    function testTwoRolesOverlappingCapabilitiesIdempotent() public {
        // VP bundle = [task.create, task.review, vote, propose]
        uint256[] memory vpCaps = new uint256[](4);
        vpCaps[0] = CAP_TASK_CREATE;
        vpCaps[1] = CAP_TASK_REVIEW;
        vpCaps[2] = CAP_VOTE;
        vpCaps[3] = CAP_PROPOSE;

        // Exec bundle = [task.create, task.review] (subset of VP)
        uint256[] memory execCaps = new uint256[](2);
        execCaps[0] = CAP_TASK_CREATE;
        execCaps[1] = CAP_TASK_REVIEW;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, vpCaps);
        hatter.setBundle(EXEC_HAT, execCaps);
        hatter.setAuthorizedMinter(MINTER, true);
        vm.stopPrank();

        // Mint VP first
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        // 4 caps + role = 5
        assertEq(executor.lastHatIdsLength(), 5);

        // Then mint Exec — should be a no-op for the overlapping capabilities,
        // only the Exec role hat itself needs to be minted
        vm.prank(MINTER);
        hatter.mintRole(EXEC_HAT, ALICE);
        assertEq(executor.lastHatIdsLength(), 1); // just EXEC_HAT
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));
        // Capability hats stay
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_REVIEW));
    }

    /* ─────────── revokeRole (diff-based cascade) ─────────── */

    function _setupRevokeFixture() internal returns (MockEligibilityModule em) {
        em = new MockEligibilityModule(IHats(address(hats)));

        // VP bundle = [CAP_TASK_CREATE, CAP_TASK_REVIEW, CAP_VOTE, CAP_PROPOSE]
        uint256[] memory vpCaps = new uint256[](4);
        vpCaps[0] = CAP_TASK_CREATE;
        vpCaps[1] = CAP_TASK_REVIEW;
        vpCaps[2] = CAP_VOTE;
        vpCaps[3] = CAP_PROPOSE;

        // Member bundle (modeled by EXEC_HAT in this fixture) = [CAP_VOTE]
        // — overlaps with VP on CAP_VOTE so the election scenario can verify it's preserved
        uint256[] memory memberCaps = new uint256[](1);
        memberCaps[0] = CAP_VOTE;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, vpCaps);
        hatter.setBundle(EXEC_HAT, memberCaps);
        hatter.setAuthorizedMinter(MINTER, true);
        hatter.setEligibilityModule(address(em));
        vm.stopPrank();
    }

    function testRevokeRoleSingleRoleRemovesAllCaps() public {
        MockEligibilityModule em = _setupRevokeFixture();

        // ALICE has only VP — losing VP should remove every cap in VP's bundle.
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_VOTE));

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // VP hat + all 4 caps = 5 revocations on EligibilityModule
        assertEq(em.revokeCount(), 5, "should revoke role + 4 caps");
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_REVIEW));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_VOTE));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_PROPOSE));
    }

    /// @notice The election-with-fallback scenario: Alice loses VP role but keeps Member
    ///         role, so any cap granted by BOTH VP and Member should be retained.
    function testRevokeRolePreservesOverlappingCapsFromOtherRole() public {
        MockEligibilityModule em = _setupRevokeFixture();

        // Mint VP first
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        // Then mint Member (EXEC_HAT) — overlapping cap is CAP_VOTE
        vm.prank(MINTER);
        hatter.mintRole(EXEC_HAT, ALICE);

        // Sanity: she wears both roles + every cap
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_VOTE));

        // Revoke VP — she still wears Member, which also grants CAP_VOTE
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // VP + 3 unique-to-VP caps = 4 revocations. CAP_VOTE is retained.
        assertEq(em.revokeCount(), 4, "should revoke VP hat + 3 VP-only caps, preserve CAP_VOTE");
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE), "VP-only cap should be revoked");
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_REVIEW));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_PROPOSE));
        // The overlapping cap stays because Member still grants it
        assertTrue(hats.isWearerOfHat(ALICE, CAP_VOTE), "overlapping cap must be preserved");
        // Member role itself untouched
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));
    }

    function testRevokeRoleSkipsCapsUserDoesNotWear() public {
        MockEligibilityModule em = _setupRevokeFixture();

        // Manually set ALICE to wear VP hat but NOT all caps
        hats.mintHat(VP_HAT, ALICE);
        hats.mintHat(CAP_TASK_CREATE, ALICE);
        // Intentionally NOT minting CAP_TASK_REVIEW / CAP_VOTE / CAP_PROPOSE

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // Only the role hat + CAP_TASK_CREATE actually need revoking
        assertEq(em.revokeCount(), 2);
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
    }

    function testRevokeRoleUnauthorizedReverts() public {
        _setupRevokeFixture();
        hats.mintHat(VP_HAT, ALICE);

        vm.prank(BOB);
        vm.expectRevert(RoleBundleHatter.NotAuthorizedMinter.selector);
        hatter.revokeRole(VP_HAT, ALICE);
    }

    function testRevokeRoleZeroAddressReverts() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        hatter.revokeRole(VP_HAT, address(0));
    }

    function testRevokeRoleZeroHatReverts() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.ZeroHat.selector);
        hatter.revokeRole(0, ALICE);
    }

    function testMintRoleZeroHatReverts() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.ZeroHat.selector);
        hatter.mintRole(0, ALICE);
    }

    function testMintRoleZeroAddressReverts() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        hatter.mintRole(VP_HAT, address(0));
    }

    function testRevokeRoleEligibilityModuleNotSetReverts() public {
        // Note: do NOT call _setupRevokeFixture, which would set the EligibilityModule.
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_TASK_CREATE;
        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setAuthorizedMinter(MINTER, true);
        vm.stopPrank();

        vm.prank(MINTER);
        vm.expectRevert(RoleBundleHatter.EligibilityModuleNotSet.selector);
        hatter.revokeRole(VP_HAT, ALICE);
    }

    /// @notice Re-calling revokeRole on a user who has already lost everything is a no-op
    ///         at the Hats layer (isWearerOfHat already false → no setWearerEligibility calls
    ///         for caps), but the role hat itself is still touched for symmetry.
    function testRevokeRoleIdempotent() public {
        MockEligibilityModule em = _setupRevokeFixture();
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        uint256 firstRevokes = em.revokeCount();
        assertEq(firstRevokes, 5);

        // Second revoke: only the role hat is touched (caps already gone — isWearerOfHat false)
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        assertEq(em.revokeCount(), firstRevokes + 1, "only role hat should be re-revoked");
    }

    function testRevokeRoleEmitsEventWithCorrectCount() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);

        vm.expectEmit(true, true, false, true);
        emit RoleRevoked(VP_HAT, ALICE, 4); // 4 caps revoked
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
    }

    /// @notice Three-role overlap: VP grants {A,B,C}, Director grants {B,D}, Member grants {C}.
    ///         Revoking VP from a user who also wears Director and Member should keep B (Director)
    ///         and C (Member) but remove A.
    function testRevokeRoleThreeRoleOverlap() public {
        MockEligibilityModule em = new MockEligibilityModule(IHats(address(hats)));

        uint256 DIRECTOR_HAT = 1003;
        uint256 CAP_A = 3001;
        uint256 CAP_B = 3002;
        uint256 CAP_C = 3003;
        uint256 CAP_D = 3004;

        // VP = {A, B, C}
        uint256[] memory vp = new uint256[](3);
        vp[0] = CAP_A;
        vp[1] = CAP_B;
        vp[2] = CAP_C;
        // Director = {B, D}
        uint256[] memory dir = new uint256[](2);
        dir[0] = CAP_B;
        dir[1] = CAP_D;
        // Member = {C}
        uint256[] memory mem = new uint256[](1);
        mem[0] = CAP_C;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, vp);
        hatter.setBundle(DIRECTOR_HAT, dir);
        hatter.setBundle(EXEC_HAT, mem);
        hatter.setAuthorizedMinter(MINTER, true);
        hatter.setEligibilityModule(address(em));
        vm.stopPrank();

        vm.startPrank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        hatter.mintRole(DIRECTOR_HAT, ALICE);
        hatter.mintRole(EXEC_HAT, ALICE);
        vm.stopPrank();

        // Sanity
        assertTrue(hats.isWearerOfHat(ALICE, CAP_A));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_B));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_C));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_D));

        // Revoke VP — only CAP_A is VP-exclusive
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // VP hat + CAP_A = 2 revocations
        assertEq(em.revokeCount(), 2);
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, CAP_A), "VP-exclusive cap removed");
        assertTrue(hats.isWearerOfHat(ALICE, CAP_B), "Director still grants B");
        assertTrue(hats.isWearerOfHat(ALICE, CAP_C), "Member still grants C");
        assertTrue(hats.isWearerOfHat(ALICE, CAP_D), "Director's exclusive cap untouched");
        assertTrue(hats.isWearerOfHat(ALICE, DIRECTOR_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));
    }

    /// @notice If another role grants the cap but the user does NOT wear that role,
    ///         the cap should still be revoked.
    function testRevokeRoleOtherRoleNotWornDoesNotPreserveCap() public {
        MockEligibilityModule em = _setupRevokeFixture();
        // VP and Member both grant CAP_VOTE.
        // Alice wears VP only — she does NOT wear EXEC_HAT (Member).
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_HAT));

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // CAP_VOTE should be revoked since Alice doesn't wear Member
        assertEq(em.revokeCount(), 5, "all VP caps revoked");
        assertFalse(hats.isWearerOfHat(ALICE, CAP_VOTE));
    }

    function testSetEligibilityModuleZeroReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(RoleBundleHatter.ZeroAddress.selector);
        hatter.setEligibilityModule(address(0));
    }

    function testSetEligibilityModuleEmitsEvent() public {
        MockEligibilityModule em = new MockEligibilityModule(IHats(address(hats)));
        vm.expectEmit(true, false, false, true);
        emit EligibilityModuleSet(address(em));
        vm.prank(DEPLOYER);
        hatter.setEligibilityModule(address(em));
        assertEq(hatter.eligibilityModule(), address(em));
    }

    function testSetEligibilityModuleOnlyAdmin() public {
        MockEligibilityModule em = new MockEligibilityModule(IHats(address(hats)));
        vm.prank(BOB);
        vm.expectRevert(RoleBundleHatter.NotAdmin.selector);
        hatter.setEligibilityModule(address(em));
    }

    function testTrackedRolesAfterSetBundle() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_VOTE;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setBundle(EXEC_HAT, caps);
        // Setting VP_HAT again does NOT re-track
        hatter.setBundle(VP_HAT, caps);
        vm.stopPrank();

        assertEq(hatter.trackedRoleCount(), 2);
        assertEq(hatter.trackedRoleAt(0), VP_HAT);
        assertEq(hatter.trackedRoleAt(1), EXEC_HAT);
    }

    function testTrackedRolesAfterAddToBundle() public {
        vm.startPrank(DEPLOYER);
        hatter.addToBundle(VP_HAT, CAP_VOTE);
        // Same role, second add — no re-track
        hatter.addToBundle(VP_HAT, CAP_PROPOSE);
        // Different role
        hatter.addToBundle(EXEC_HAT, CAP_TASK_CREATE);
        vm.stopPrank();

        assertEq(hatter.trackedRoleCount(), 2);
    }

    function testTrackedRolesUntracksOnEmptySetBundle() public {
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP_VOTE;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setBundle(EXEC_HAT, caps);
        vm.stopPrank();
        assertEq(hatter.trackedRoleCount(), 2);

        // Clear VP's bundle — it should be untracked
        uint256[] memory empty = new uint256[](0);
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, empty);
        assertEq(hatter.trackedRoleCount(), 1);
        assertEq(hatter.trackedRoleAt(0), EXEC_HAT);

        // Re-setting a non-empty bundle re-tracks
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        assertEq(hatter.trackedRoleCount(), 2);
    }

    function testTrackedRolesUntracksOnRemoveDrainingLastCap() public {
        vm.startPrank(DEPLOYER);
        hatter.addToBundle(VP_HAT, CAP_VOTE);
        vm.stopPrank();
        assertEq(hatter.trackedRoleCount(), 1);

        // Removing the last cap should untrack the role
        vm.prank(DEPLOYER);
        hatter.removeFromBundle(VP_HAT, CAP_VOTE);
        assertEq(hatter.trackedRoleCount(), 0);
    }

    function testTrackedRolesNoCascadeForUntrackedRole() public {
        // Set up two roles with overlapping caps, then untrack one.
        // The cascade should treat the untracked role as if it doesn't grant anything.
        MockEligibilityModule em = _setupRevokeFixture();
        // _setupRevokeFixture tracked VP and EXEC. Empty EXEC's bundle to untrack.
        uint256[] memory empty = new uint256[](0);
        vm.prank(DEPLOYER);
        hatter.setBundle(EXEC_HAT, empty);

        // Mint VP only (EXEC has no bundle to mint anymore — but still grant role hat)
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        // Grant EXEC role hat manually (still wearing it)
        hats.mintHat(EXEC_HAT, ALICE);
        // Eligibility check: alice has EXEC role hat now
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));

        em.clearRecords();

        // Revoke VP — even though Alice wears EXEC, EXEC is untracked, so the cascade
        // shouldn't preserve CAP_VOTE through EXEC's (now-empty) bundle
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        // All 5 hats revoked (role + 4 caps) since EXEC is untracked
        assertEq(em.revokeCount(), 5);
    }

    /// @notice Bubble up the underlying revert if EligibilityModule rejects the call.
    function testRevokeRoleBubblesUpEligibilityRevert() public {
        MockEligibilityModule em = _setupRevokeFixture();
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);

        em.setShouldRevert(true);
        vm.prank(MINTER);
        // The mock reverts with "MockEligibility: revert" — we don't pin to the exact bytes
        // here, just that the call fails.
        vm.expectRevert();
        hatter.revokeRole(VP_HAT, ALICE);
    }

    /* ─────────── Election scenarios (frontend-driven) ─────────── */
    //
    // These tests model the full election flow as the frontend would compose it:
    //   1. Vote concludes → governance produces a batch of (revokeRole, mintRole) calls
    //   2. Executor.execute([...]) runs the batch atomically
    //
    // In tests we don't go through Executor — we prank as MINTER (an authorized minter
    // representing what the Executor would do) and call revokeRole/mintRole directly.
    // The state transitions are what matter, not the dispatch mechanism.
    //
    // Election fixture layout (3-role hierarchy modeling a real org):
    //   - PRESIDENT (1101): bundle = {EXEC_TASK, EXEC_REVIEW, EXEC_VOTE, EXEC_PROPOSE, EXEC_TREASURY}
    //   - VP        (1102): bundle = {EXEC_TASK, EXEC_REVIEW, EXEC_VOTE, EXEC_PROPOSE}
    //   - MEMBER    (1103): bundle = {EXEC_VOTE}
    //
    // Overlaps:
    //   - EXEC_VOTE is in all three bundles
    //   - EXEC_TASK/EXEC_REVIEW/EXEC_PROPOSE are in President AND VP (not Member)
    //   - EXEC_TREASURY is President-only
    //
    // This shape lets us write tests that exercise every kind of cascade outcome
    // ("lose President, keep VP" preserves all VP caps; "lose VP, keep Member"
    // preserves only EXEC_VOTE; "lose President but had no fallback" wipes everything).

    uint256 constant PRESIDENT_HAT = 1101;
    uint256 constant VP_ELECT_HAT = 1102;
    uint256 constant MEMBER_HAT = 1103;
    uint256 constant EXEC_TASK = 2101;
    uint256 constant EXEC_REVIEW = 2102;
    uint256 constant EXEC_VOTE = 2103;
    uint256 constant EXEC_PROPOSE = 2104;
    uint256 constant EXEC_TREASURY = 2105;

    address constant CAROL = address(0xCA101);
    address constant DAVE = address(0xDA7E);

    function _setupElectionFixture() internal returns (MockEligibilityModule em) {
        em = new MockEligibilityModule(IHats(address(hats)));

        // President = {TASK, REVIEW, VOTE, PROPOSE, TREASURY}
        uint256[] memory pres = new uint256[](5);
        pres[0] = EXEC_TASK;
        pres[1] = EXEC_REVIEW;
        pres[2] = EXEC_VOTE;
        pres[3] = EXEC_PROPOSE;
        pres[4] = EXEC_TREASURY;

        // VP = {TASK, REVIEW, VOTE, PROPOSE}
        uint256[] memory vp = new uint256[](4);
        vp[0] = EXEC_TASK;
        vp[1] = EXEC_REVIEW;
        vp[2] = EXEC_VOTE;
        vp[3] = EXEC_PROPOSE;

        // Member = {VOTE}
        uint256[] memory mem = new uint256[](1);
        mem[0] = EXEC_VOTE;

        vm.startPrank(DEPLOYER);
        hatter.setBundle(PRESIDENT_HAT, pres);
        hatter.setBundle(VP_ELECT_HAT, vp);
        hatter.setBundle(MEMBER_HAT, mem);
        hatter.setAuthorizedMinter(MINTER, true);
        hatter.setEligibilityModule(address(em));
        vm.stopPrank();
    }

    /// @notice Simple succession: Alice (current VP) loses, Bob (new VP) wins.
    ///         Neither holds any other role. After election: Alice has nothing,
    ///         Bob wears VP + full VP bundle.
    function testElection_SimpleSuccession() public {
        _setupElectionFixture();

        // Pre-election state: Alice is the incumbent VP
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));

        // Election TX (the executor would batch these together)
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Alice loses everything (no fallback role)
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));

        // Bob gains the full VP bundle
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_REVIEW));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_PROPOSE));
    }

    /// @notice Election with Member fallback — Alice has VP + Member, loses VP election.
    ///         She should keep Member role + Member's caps (EXEC_VOTE) but lose all
    ///         VP-exclusive caps. This is the canonical "permission set fallback" case.
    function testElection_LoserKeepsMemberFallback() public {
        _setupElectionFixture();

        // Alice is VP and also a regular Member
        vm.startPrank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        vm.stopPrank();

        // Sanity: she wears both roles + every cap
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));

        // Election TX: Alice loses VP, Bob wins
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Alice's VP-exclusive caps are revoked
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT), "VP role lost");
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK), "VP-only cap lost");
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_REVIEW), "VP-only cap lost");
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_PROPOSE), "VP-only cap lost");

        // Alice keeps Member role and the overlapping cap (EXEC_VOTE)
        assertTrue(hats.isWearerOfHat(ALICE, MEMBER_HAT), "Member role retained");
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE), "Member-granted cap preserved");

        // Bob gets the full VP bundle
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));
    }

    /// @notice 3-role overlap: Alice is President + VP + Member. Loses President.
    ///         All of VP's caps overlap with President so they're all preserved.
    ///         EXEC_TREASURY (President-only) is the only thing she loses.
    function testElection_PresidentLossKeepsVPFallback() public {
        _setupElectionFixture();

        vm.startPrank(MINTER);
        hatter.mintRole(PRESIDENT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        vm.stopPrank();

        // Bob wins the presidency
        vm.startPrank(MINTER);
        hatter.revokeRole(PRESIDENT_HAT, ALICE);
        hatter.mintRole(PRESIDENT_HAT, BOB);
        vm.stopPrank();

        // President role lost, but VP still grants TASK/REVIEW/VOTE/PROPOSE
        assertFalse(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TREASURY), "President-only cap lost");

        // VP-overlapping caps preserved
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK), "VP still grants it");
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_REVIEW), "VP still grants it");
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));
        assertTrue(hats.isWearerOfHat(ALICE, MEMBER_HAT));
    }

    /// @notice Winner already wore a fallback role — mint should be idempotent on overlap.
    ///         Bob is a Member when he wins VP. After mint, he wears VP + Member,
    ///         no double-mint attempt on EXEC_VOTE.
    function testElection_WinnerHadFallback_NoOpOnOverlap() public {
        MockEligibilityModule em = _setupElectionFixture();
        // Bob was already a Member
        vm.prank(MINTER);
        hatter.mintRole(MEMBER_HAT, BOB);
        em.clearRecords();

        // Alice was VP, loses
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);

        // Election
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Bob keeps Member, gains VP and the new VP-only caps
        assertTrue(hats.isWearerOfHat(BOB, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_REVIEW));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_PROPOSE));

        // Verify mintRole's "skip already-worn" logic: Bob ended up minting only
        // 4 hats (VP role + 3 new caps). EXEC_VOTE was already on him from Member.
        // The most recent mint call would have been mintRole(VP_ELECT_HAT, BOB).
        assertEq(executor.lastUser(), BOB);
        assertEq(executor.lastHatIdsLength(), 4);
    }

    /// @notice Recall: governance removes Alice from ALL her roles, one by one.
    ///         She wears President + VP + Member. After the recall batch she should
    ///         lose every hat she had.
    function testElection_FullRecall_LosesEverything() public {
        _setupElectionFixture();

        vm.startPrank(MINTER);
        hatter.mintRole(PRESIDENT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        vm.stopPrank();

        // Sanity: she's wearing everything
        assertTrue(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TREASURY));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));

        // Recall batch: revoke each role in order
        vm.startPrank(MINTER);
        hatter.revokeRole(PRESIDENT_HAT, ALICE);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.revokeRole(MEMBER_HAT, ALICE);
        vm.stopPrank();

        // Alice loses all roles and all caps
        assertFalse(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, MEMBER_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TREASURY));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));
    }

    /// @notice Order-independence: revoking roles in a different order should produce
    ///         the same final state.
    function testElection_RecallOrderIndependent() public {
        _setupElectionFixture();
        vm.startPrank(MINTER);
        hatter.mintRole(PRESIDENT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        vm.stopPrank();

        // Revoke in reverse order
        vm.startPrank(MINTER);
        hatter.revokeRole(MEMBER_HAT, ALICE);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.revokeRole(PRESIDENT_HAT, ALICE);
        vm.stopPrank();

        assertFalse(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, MEMBER_HAT));
        // The middle step (revoke VP while President still held) should have preserved
        // EXEC_TASK because President granted it. Then revoke President wiped EXEC_TASK.
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_VOTE));
    }

    /// @notice Rotation: Alice and Bob swap roles. Alice was VP, Bob was Member.
    ///         After election, Alice is Member, Bob is VP. The frontend would
    ///         compose this as 4 calls (revoke VP from Alice, mint Member to Alice,
    ///         revoke Member from Bob, mint VP to Bob) but the cascade is the same.
    function testElection_AliceAndBobSwapRoles() public {
        _setupElectionFixture();

        // Initial: Alice = VP, Bob = Member
        vm.startPrank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, BOB);
        vm.stopPrank();

        // Election swap
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        hatter.revokeRole(MEMBER_HAT, BOB);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Alice is now Member only
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK), "VP-only cap removed");
        assertTrue(hats.isWearerOfHat(ALICE, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE), "Member grants this");

        // Bob is now VP only (no longer Member)
        assertFalse(hats.isWearerOfHat(BOB, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));
    }

    /// @notice Multi-candidate election: 3 candidates run for VP, 2 lose.
    ///         The losers must each be revoked. The winner is minted.
    function testElection_ThreeCandidatesOneWins() public {
        _setupElectionFixture();

        // Alice is incumbent VP; Bob and Carol are challengers (both Members)
        vm.startPrank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, BOB);
        hatter.mintRole(MEMBER_HAT, CAROL);
        vm.stopPrank();

        // Carol wins
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, CAROL);
        vm.stopPrank();

        // Alice: no fallback → loses everything
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_VOTE));

        // Bob: was a challenger but didn't win; he should still wear Member
        //      (he was never VP, so revokeRole wasn't called on him)
        assertTrue(hats.isWearerOfHat(BOB, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));

        // Carol: won, has Member + VP
        assertTrue(hats.isWearerOfHat(CAROL, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(CAROL, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(CAROL, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(CAROL, EXEC_VOTE));
    }

    /// @notice Concurrent revocations: revoking VP from Alice must NOT affect Bob,
    ///         who also wears VP. (Each user's cascade is independent.)
    function testElection_RevokeFromOneUserDoesNotAffectAnother() public {
        _setupElectionFixture();

        vm.startPrank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Sanity
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));

        // Revoke from Alice only
        vm.prank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);

        // Alice loses everything
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));

        // Bob is untouched
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_VOTE));
    }

    /// @notice Cap on revoke event count for a complex election batch — used to
    ///         confirm gas/event scaling under realistic election sizes.
    function testElection_BatchCountsAreCorrect() public {
        MockEligibilityModule em = _setupElectionFixture();

        // Alice = VP+Member. Bob = no roles. President un-held.
        vm.startPrank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(MEMBER_HAT, ALICE);
        vm.stopPrank();
        uint256 beforeRevokes = em.revokeCount();

        // Election: Alice loses VP (keeps Member), Bob wins
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Revocations during this batch:
        //   - VP role hat itself
        //   - EXEC_TASK / EXEC_REVIEW / EXEC_PROPOSE (Member doesn't grant these)
        //   - EXEC_VOTE NOT revoked (Member grants it)
        // = 4 setWearerEligibility(false,false) calls
        assertEq(em.revokeCount() - beforeRevokes, 4);
    }

    /// @notice Bundle was edited mid-term. Alice wore the OLD bundle; revokeRole
    ///         iterates the CURRENT bundle, so caps that were removed from the
    ///         bundle definition before the revoke are NOT auto-revoked.
    ///         This documents the intended behavior: bundle = source of truth for
    ///         "what does this role grant right now". Caps a wearer accumulated
    ///         under old bundle configs need explicit cleanup by governance.
    function testElection_BundleChangedMidTerm_OnlyCurrentCapsRevoked() public {
        MockEligibilityModule em = _setupElectionFixture();

        // Mint Alice as VP under the original 4-cap VP bundle
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        // She wears all 4 caps
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));

        // Governance changes VP's bundle — now only includes EXEC_TASK + EXEC_REVIEW
        uint256[] memory newVpBundle = new uint256[](2);
        newVpBundle[0] = EXEC_TASK;
        newVpBundle[1] = EXEC_REVIEW;
        vm.prank(DEPLOYER);
        hatter.setBundle(VP_ELECT_HAT, newVpBundle);

        // Alice still wears all 4 original caps — no auto-revoke on bundle change
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE), "stale cap still worn");
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE), "stale cap still worn");

        uint256 beforeRevokes = em.revokeCount();

        // Election: Alice loses VP, Bob wins
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        vm.stopPrank();

        // Cascade only iterates the CURRENT bundle (2 caps + role hat = 3 revocations)
        assertEq(em.revokeCount() - beforeRevokes, 3);
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        // Stale caps from the old bundle remain — governance must clean these up explicitly
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE), "not in current bundle -- not auto-revoked");
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE), "not in current bundle -- not auto-revoked");

        // Bob (newly minted) gets ONLY the current bundle's caps
        assertTrue(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_REVIEW));
        assertFalse(hats.isWearerOfHat(BOB, EXEC_VOTE), "not in current bundle");
        assertFalse(hats.isWearerOfHat(BOB, EXEC_PROPOSE), "not in current bundle");
    }

    /// @notice Promotion: VP wins President election. The frontend would emit both
    ///         a revokeRole(VP, Alice) AND a mintRole(President, Alice). After:
    ///         Alice wears President + President bundle, VP role gone.
    ///         (Note: Alice keeps VP-overlapping caps because President grants them.)
    function testElection_VPPromotedToPresident() public {
        _setupElectionFixture();
        // Alice starts as VP
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);

        // Election: Alice wins presidency. The election logic would do BOTH
        // revoke(VP) and mint(President) for her.
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(PRESIDENT_HAT, ALICE);
        vm.stopPrank();

        // Alice wears President now, not VP
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));

        // All previous VP caps re-granted via President bundle, plus EXEC_TREASURY
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TREASURY));
    }

    /// @notice Adversarial ordering: what if the frontend orders mint BEFORE revoke?
    ///         (Bad batch ordering.) The cascade should still produce a sensible result:
    ///         Alice ends up with the union of both bundles. This shouldn't happen in
    ///         practice (frontend always revokes loser first), but the contract should
    ///         not corrupt state.
    function testElection_MintBeforeRevokeYieldsUnionState() public {
        _setupElectionFixture();
        // Alice has VP. Promotion election to President with wrong-order calls:
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);

        vm.startPrank(MINTER);
        hatter.mintRole(PRESIDENT_HAT, ALICE); // mint first
        hatter.revokeRole(VP_ELECT_HAT, ALICE); // then revoke
        vm.stopPrank();

        // President role retained, VP role lost
        assertTrue(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));

        // VP caps preserved (because President grants them too)
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_REVIEW));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_PROPOSE));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TREASURY));
    }

    /// @notice Stress: full org election with 4 candidates and a complex starting state.
    ///         Verifies the cascade is correct across many revoke+mint operations in one batch.
    function testElection_FullOrgElection_StressBatch() public {
        _setupElectionFixture();

        // Starting state:
        //   ALICE  = President  (5 caps)
        //   BOB    = VP         (4 caps)
        //   CAROL  = Member     (1 cap: EXEC_VOTE)
        //   DAVE   = Member     (1 cap)
        vm.startPrank(MINTER);
        hatter.mintRole(PRESIDENT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, BOB);
        hatter.mintRole(MEMBER_HAT, CAROL);
        hatter.mintRole(MEMBER_HAT, DAVE);
        vm.stopPrank();

        // Election outcome:
        //   - Bob is promoted to President
        //   - Carol is promoted to VP
        //   - Alice loses President (no fallback)
        //   - Dave stays Member (unchanged)
        vm.startPrank(MINTER);
        hatter.revokeRole(PRESIDENT_HAT, ALICE);
        hatter.revokeRole(VP_ELECT_HAT, BOB);
        hatter.mintRole(PRESIDENT_HAT, BOB);
        hatter.mintRole(VP_ELECT_HAT, CAROL);
        vm.stopPrank();

        // Alice: lost everything
        assertFalse(hats.isWearerOfHat(ALICE, PRESIDENT_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_TREASURY));
        assertFalse(hats.isWearerOfHat(ALICE, EXEC_VOTE));

        // Bob: was VP, now President. Wears President + all 5 caps.
        assertFalse(hats.isWearerOfHat(BOB, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, PRESIDENT_HAT));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(BOB, EXEC_TREASURY));

        // Carol: was Member, now VP+Member. Wears VP role + all 4 VP caps.
        assertTrue(hats.isWearerOfHat(CAROL, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(CAROL, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(CAROL, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(CAROL, EXEC_VOTE));

        // Dave: untouched
        assertTrue(hats.isWearerOfHat(DAVE, MEMBER_HAT));
        assertTrue(hats.isWearerOfHat(DAVE, EXEC_VOTE));
        assertFalse(hats.isWearerOfHat(DAVE, VP_ELECT_HAT));
    }

    /// @notice Edge case: re-elected incumbent. Naive batch is revoke + mint to the same
    ///         person. After revoke, eligibility is false → production `Hats.mintHat`
    ///         would revert with `NotEligible`. `mintRole` resets eligibility to (true,
    ///         true) for each hat about to be minted, so the re-mint succeeds.
    function testElection_IncumbentReElected_RoundTripsThroughZero() public {
        _setupElectionFixture();
        vm.prank(MINTER);
        hatter.mintRole(VP_ELECT_HAT, ALICE);

        // Election: Alice re-elected (loser-side wash). The naive batch would be
        // revoke(VP, Alice) then mint(VP, Alice).
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_ELECT_HAT, ALICE);
        hatter.mintRole(VP_ELECT_HAT, ALICE);
        vm.stopPrank();

        // End state: Alice wears VP + bundle, same as before
        assertTrue(hats.isWearerOfHat(ALICE, VP_ELECT_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_TASK));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_VOTE));
    }

    /* ─────────── Re-mint after revoke (production NotEligible path) ─────────── */
    //
    // Background:
    //   - Production Hats Protocol reverts `mintHat` with NotEligible when the
    //     EligibilityModule reports the wearer as ineligible.
    //   - `revokeRole` sets eligibility false. Without `mintRole`'s pre-mint
    //     eligibility reset, any subsequent `mintRole` for that user+hat would
    //     revert in production.
    //   - MockHats now mirrors that behavior (revert on mint when ineligible).
    //
    // These tests prove the reset path works end-to-end against the production-faithful mock.

    function testRemint_AfterFullRevokeWorks() public {
        MockEligibilityModule em = _setupRevokeFixture();

        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));
        // Eligibility is now false on VP_HAT — without the reset, mintHat would revert
        assertFalse(hats.isEligible(ALICE, VP_HAT));

        // Re-mint must succeed and restore eligibility
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
        assertTrue(hats.isEligible(ALICE, VP_HAT));

        // The pre-mint eligibility reset is gated on hasSpecificWearerRules:
        // 1st mint = 0 resets (fresh user has no specific rule yet — gate skips the write)
        // revoke   = 5 revokes (writes specific (false,false) rules)
        // 2nd mint = 5 resets (those 5 hats now have rules, so the reset re-enables them)
        assertEq(em.resetCount(), 5);
        assertEq(em.revokeCount(), 5);
    }

    function testRemint_AfterPartialRevokeOnlyResetsMintedHats() public {
        MockEligibilityModule em = _setupRevokeFixture();

        // Alice = VP + Member. Lose VP — caps overlapping with Member (CAP_VOTE) stay.
        vm.startPrank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        hatter.mintRole(EXEC_HAT, ALICE);
        vm.stopPrank();
        em.clearRecords();

        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        // 4 revocations (role + 3 VP-only caps); CAP_VOTE retained via Member
        assertEq(em.revokeCount(), 4);

        // Re-mint VP — should reset eligibility ONLY for hats actually about to be minted
        // (role hat + 3 VP-only caps = 4 hats; CAP_VOTE is skipped, already worn via Member)
        em.clearRecords();
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        assertEq(em.resetCount(), 4, "reset only the 4 hats being minted");
        assertEq(em.revokeCount(), 0);
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, EXEC_HAT));
    }

    function testRemint_NoEligibilityModuleSkipsReset() public {
        // Legacy/test path: if no EligibilityModule wired, mintRole should not call
        // setWearerEligibility at all. This is the path bootstrap orgs may use before
        // the cascade is wired.
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP_TASK_CREATE;
        caps[1] = CAP_VOTE;
        vm.startPrank(DEPLOYER);
        hatter.setBundle(VP_HAT, caps);
        hatter.setAuthorizedMinter(MINTER, true);
        // Intentionally NOT calling setEligibilityModule
        vm.stopPrank();

        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        // Mint succeeded without touching any EligibilityModule (because none is set).
        // We're asserting the absence of a revert; if mintRole tried to call into the
        // zero address it would have failed.
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
    }

    function testRemint_BubblesUpEligibilityResetRevert() public {
        MockEligibilityModule em = _setupRevokeFixture();

        // Establish specific wearer rules via a grant + revoke cycle so the re-mint's eligibility
        // reset path is actually exercised (the reset is gated on hasSpecificWearerRules — a fresh
        // user has no rule and would skip it).
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);
        vm.prank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);

        // Now make the eligibility reset revert; the re-mint must bubble it up.
        em.setShouldRevert(true);
        vm.prank(MINTER);
        vm.expectRevert(); // mock-level "MockEligibility: revert"
        hatter.mintRole(VP_HAT, ALICE);
    }

    /// @notice Election + re-election: Alice loses, Bob wins. Two elections later Alice
    ///         wins back her old role. Both transitions must work.
    function testRemint_ElectionThenReElectionRoundTrip() public {
        _setupRevokeFixture();
        vm.prank(MINTER);
        hatter.mintRole(VP_HAT, ALICE);

        // Election 1: Bob wins
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_HAT, ALICE);
        hatter.mintRole(VP_HAT, BOB);
        vm.stopPrank();
        assertTrue(hats.isWearerOfHat(BOB, VP_HAT));
        assertFalse(hats.isWearerOfHat(ALICE, VP_HAT));

        // Election 2: Alice wins back
        vm.startPrank(MINTER);
        hatter.revokeRole(VP_HAT, BOB);
        hatter.mintRole(VP_HAT, ALICE);
        vm.stopPrank();
        assertFalse(hats.isWearerOfHat(BOB, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, VP_HAT));
        assertTrue(hats.isWearerOfHat(ALICE, CAP_TASK_CREATE));
    }

    /// @notice MockHats sanity: confirm the mock actually reverts on ineligible mint.
    ///         If this test fails, the production-fidelity guarantee is broken.
    function testMockHatsRevertsOnIneligibleMint() public {
        hats.setHatWearerStatus(VP_HAT, ALICE, false, false);
        assertFalse(hats.isEligible(ALICE, VP_HAT));
        vm.expectRevert(); // NotEligible from Hats interface
        hats.mintHat(VP_HAT, ALICE);
    }

    /* ─────────── Event signatures used in tests ─────────── */

    event RoleRevoked(uint256 indexed roleHat, address indexed user, uint256 capabilitiesRevoked);
    event EligibilityModuleSet(address indexed eligibilityModule);
}
