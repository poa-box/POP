// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {MockModuleAuthority} from "./mocks/MockModuleAuthority.sol";
import {AccessV2PermKeys} from "../src/libs/AccessV2PermKeys.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/QuickJoin.sol";
import "./mocks/MockHats.sol";

contract MockExecutorHatMinter {
    MockHats public hats;

    constructor() {
        hats = new MockHats();
    }

    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        for (uint256 i = 0; i < hatIds.length; i++) {
            hats.mintHat(hatIds[i], user);
        }
    }
}

contract MockRegistry is IUniversalAccountRegistry {
    mapping(address => string) public usernames;
    mapping(address => uint256) private _nonces;

    function getUsername(address account) external view returns (string memory) {
        return usernames[account];
    }

    function setUsername(address user, string memory name) external {
        usernames[user] = name;
    }

    function registerAccountBySig(
        address user,
        string calldata username,
        uint256 deadline,
        uint256 nonce,
        bytes calldata /* signature */
    ) external {
        require(block.timestamp <= deadline, "expired");
        require(nonce == _nonces[user], "bad nonce");
        _nonces[user]++;
        usernames[user] = username;
    }

    function registerAccountByPasskeySig(
        bytes32, /* credentialId */
        bytes32, /* pubKeyX */
        bytes32, /* pubKeyY */
        uint256, /* salt */
        string calldata username,
        uint256 deadline,
        uint256, /* nonce */
        WebAuthnLib.WebAuthnAuth calldata /* auth */
    ) external {
        // In mock: skip sig verification, just register.
        require(block.timestamp <= deadline, "expired");
        usernames[address(0)] = username; // placeholder, tests override via setUsername
    }

    function nonces(address user) external view returns (uint256) {
        return _nonces[user];
    }
}

contract QuickJoinTest is Test {
    QuickJoin qj;
    MockHats hats;
    MockRegistry registry;
    MockExecutorHatMinter mockExecutor;

    event QuickJoined(address indexed user, uint256[] hatIds);
    event QuickJoinedByMaster(address indexed master, address indexed user, uint256[] hatIds);

    address executor = address(0x1);
    address master = address(0x2);
    address user1 = address(0x100);
    address user2 = address(0x200);

    uint256 constant DEFAULT_HAT_ID = 1;
    bytes32 constant SLOT = 0x566f0545117c69d7a3001f74fa210927792975a5c779e9cbf2876fbc68ef7fa2;

    function setUp() public {
        hats = new MockHats();
        registry = new MockRegistry();
        mockExecutor = new MockExecutorHatMinter();
        QuickJoin _qjImpl = new QuickJoin();
        UpgradeableBeacon _qjBeacon = new UpgradeableBeacon(address(_qjImpl), address(this));
        qj = QuickJoin(address(new BeaconProxy(address(_qjBeacon), "")));

        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = DEFAULT_HAT_ID;

        qj.initialize(address(mockExecutor), address(registry), master);
        MockModuleAuthority moduleAuthority = new MockModuleAuthority(address(hats), address(mockExecutor));
        moduleAuthority.setSubjects(AccessV2PermKeys.QJ_AUTOJOIN, memberHats);
        vm.prank(address(mockExecutor));
        qj.setMembershipAuthority(address(moduleAuthority));
    }

    function _storedAddr(uint256 index) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(qj), bytes32(uint256(SLOT) + index)))));
    }

    function testInitializeStoresAddresses() public {
        assertEq(_storedAddr(0), address(0));
        assertEq(_storedAddr(1), address(registry));
        assertEq(_storedAddr(2), master);
        assertEq(_storedAddr(3), address(mockExecutor));
    }

    function testInitializeZeroAddressReverts() public {
        QuickJoin _tmpImpl = new QuickJoin();
        UpgradeableBeacon _tmpBeacon = new UpgradeableBeacon(address(_tmpImpl), address(this));
        QuickJoin tmp = QuickJoin(address(new BeaconProxy(address(_tmpBeacon), "")));
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = DEFAULT_HAT_ID;
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        tmp.initialize(address(0), address(registry), master);
    }

    function testInitializeCannotRunTwice() public {
        uint256[] memory memberHats = new uint256[](1);
        memberHats[0] = DEFAULT_HAT_ID;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        qj.initialize(address(mockExecutor), address(registry), master);
    }

    function testUpdateAddresses() public {
        MockHats h2 = new MockHats();
        MockRegistry r2 = new MockRegistry();
        address master2 = address(0x3);

        vm.prank(address(mockExecutor));
        qj.updateAddresses(address(r2), master2);

        assertEq(_storedAddr(0), address(0));
        assertEq(_storedAddr(1), address(r2));
        assertEq(_storedAddr(2), master2);
    }

    function testUpdateAddressesUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.updateAddresses(address(registry), master);
    }

    function testUpdateAddressesZeroReverts() public {
        vm.prank(address(mockExecutor));
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        qj.updateAddresses(address(0), master);
    }

    function testSetExecutor() public {
        address newExec = address(0x9);
        vm.prank(address(mockExecutor));
        qj.setExecutor(newExec);
        assertEq(_storedAddr(3), newExec);
    }

    function testSetExecutorUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.setExecutor(address(0x9));
    }

    function testSetExecutorZeroReverts() public {
        vm.prank(address(mockExecutor));
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        qj.setExecutor(address(0));
    }

    function testQuickJoinWithUser() public {
        registry.setUsername(user1, "bob");
        vm.prank(user1);
        qj.quickJoinWithUser();
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testQuickJoinWithUserEmitsEvent() public {
        registry.setUsername(user1, "bob");
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        uint256[] memory expectedHats = new uint256[](1);
        expectedHats[0] = DEFAULT_HAT_ID;
        emit QuickJoined(user1, expectedHats);
        qj.quickJoinWithUser();
    }

    function testQuickJoinWithUserNoNameReverts() public {
        vm.prank(user1);
        vm.expectRevert(QuickJoin.NoUsername.selector);
        qj.quickJoinWithUser();
    }

    function testQuickJoinNoUserMasterDeployByMaster() public {
        vm.prank(master);
        qj.quickJoinNoUserMasterDeploy(user1);
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testQuickJoinNoUserMasterDeployEmitsEvent() public {
        vm.prank(master);
        vm.expectEmit(true, true, true, true);
        uint256[] memory expectedHats = new uint256[](1);
        expectedHats[0] = DEFAULT_HAT_ID;
        emit QuickJoinedByMaster(master, user1, expectedHats);
        qj.quickJoinNoUserMasterDeploy(user1);
    }

    function testQuickJoinNoUserMasterDeployByExecutor() public {
        vm.prank(address(mockExecutor));
        qj.quickJoinNoUserMasterDeploy(user1);
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testQuickJoinNoUserMasterDeployUnauthorized() public {
        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.quickJoinNoUserMasterDeploy(user1);
    }

    function testQuickJoinNoUserMasterDeployZeroUser() public {
        vm.prank(master);
        vm.expectRevert(QuickJoin.ZeroUser.selector);
        qj.quickJoinNoUserMasterDeploy(address(0));
    }

    function testQuickJoinWithUserMasterDeploy() public {
        registry.setUsername(user2, "bob");
        vm.prank(master);
        qj.quickJoinWithUserMasterDeploy(user2);
        assertTrue(mockExecutor.hats().isWearerOfHat(user2, DEFAULT_HAT_ID));
    }

    function testQuickJoinWithUserMasterDeployEmitsEvent() public {
        registry.setUsername(user2, "bob");
        vm.prank(address(mockExecutor));
        vm.expectEmit(true, true, true, true);
        uint256[] memory expectedHats = new uint256[](1);
        expectedHats[0] = DEFAULT_HAT_ID;
        emit QuickJoinedByMaster(address(mockExecutor), user2, expectedHats);
        qj.quickJoinWithUserMasterDeploy(user2);
    }

    function testQuickJoinWithUserMasterDeployNoUsername() public {
        vm.prank(master);
        vm.expectRevert(QuickJoin.NoUsername.selector);
        qj.quickJoinWithUserMasterDeploy(user2);
    }

    function testQuickJoinWithUserMasterDeployZeroUser() public {
        vm.prank(master);
        vm.expectRevert(QuickJoin.ZeroUser.selector);
        qj.quickJoinWithUserMasterDeploy(address(0));
    }

    function testQuickJoinWithUserMasterDeployUnauthorized() public {
        registry.setUsername(user1, "bob");
        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.quickJoinWithUserMasterDeploy(user1);
    }

    /* ═══════════════════ registerAndQuickJoin (EOA) tests ═══════════════════ */

    function testRegisterAndQuickJoin() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 0;
        bytes memory sig = hex"00"; // Mock registry doesn't verify sig

        address sponsor = address(0xBEEF);
        vm.prank(sponsor);
        qj.registerAndQuickJoin(user1, "alice", deadline, nonce, sig);

        // Verify username was set on mock registry
        assertEq(registry.usernames(user1), "alice");
        // Verify hats were minted
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testRegisterAndQuickJoinEmitsEvent() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"00";

        vm.expectEmit(true, true, true, true);
        uint256[] memory expectedHats = new uint256[](1);
        expectedHats[0] = DEFAULT_HAT_ID;
        emit RegisterAndQuickJoined(user1, "alice", expectedHats);
        qj.registerAndQuickJoin(user1, "alice", deadline, 0, sig);
    }

    function testRegisterAndQuickJoinZeroUser() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"00";

        vm.expectRevert(QuickJoin.ZeroUser.selector);
        qj.registerAndQuickJoin(address(0), "alice", deadline, 0, sig);
    }

    /* ═══════════════════ registerAndQuickJoinWithPasskey tests ═══════════════════ */

    function testRegisterAndQuickJoinWithPasskeyNoFactory() public {
        QuickJoin.PasskeyEnrollment memory passkey = QuickJoin.PasskeyEnrollment({
            credentialId: bytes32(uint256(1)), publicKeyX: bytes32(uint256(2)), publicKeyY: bytes32(uint256(3)), salt: 0
        });

        WebAuthnLib.WebAuthnAuth memory auth;
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(QuickJoin.PasskeyFactoryNotSet.selector);
        qj.registerAndQuickJoinWithPasskey(passkey, "alice", deadline, 0, auth);
    }

    function testRegisterAndQuickJoinWithPasskeyMasterDeployUnauthorized() public {
        QuickJoin.PasskeyEnrollment memory passkey = QuickJoin.PasskeyEnrollment({
            credentialId: bytes32(uint256(1)), publicKeyX: bytes32(uint256(2)), publicKeyY: bytes32(uint256(3)), salt: 0
        });

        WebAuthnLib.WebAuthnAuth memory auth;
        uint256 deadline = block.timestamp + 1 hours;

        // Random caller, not master or executor
        vm.prank(address(0x999));
        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.registerAndQuickJoinWithPasskeyMasterDeploy(passkey, "alice", deadline, 0, auth);
    }

    event RegisterAndQuickJoined(address indexed user, string username, uint256[] hatIds);

    /* ═══════════════════ H-03: open-hat eligibility gate tests ═══════════════════ */
    //
    // New H-03 model (no allowlist): the caller-specified claim paths REJECT any hat that is
    // OPEN-TO-EVERYONE (default-eligible for an arbitrary address — the self-mint escalation, e.g. the
    // org's ELIGIBILITY_ADMIN hat) and rely on Hats.mintHat's per-user NotEligible for GATED role hats.
    //
    // Openness is detected by probing `hats.isEligible(SENTINEL, hatId)`. In this suite the outer
    // `hats` mock (QuickJoin's l.hats) is driven via `setEligible(SENTINEL, hatId, true)` to mark a hat
    // OPEN; a hat left unmarked probes as NOT eligible for the sentinel == GATED. Note the claim paths
    // mint through `mockExecutor`, whose OWN internal MockHats records wearers (mockExecutor.hats()).

    event HatsClaimed(address indexed user, uint256[] claimHatIds);
    event RegisterAndClaimedHats(address indexed user, string username, uint256[] claimHatIds);

    uint256 constant OPEN_HAT = 999; // default-eligible for everyone (e.g. ELIGIBILITY_ADMIN) → blocked
    uint256 constant GATED_HAT = 7; // vouch-gated role hat → passes the open-hat gate

    // keccak256("poa.quickjoin.claim.probe") truncated to an address — the QuickJoin claim probe sentinel.
    address constant CLAIM_PROBE = 0x9E9AFD795ed800a00608Cba049D1239d17Acc215;

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    /// @dev Mark a hat OPEN-TO-EVERYONE by making the probe sentinel eligible for it on QuickJoin's Hats.
    function _markOpen(uint256 hatId) internal {
        hats.setEligible(CLAIM_PROBE, hatId, true);
    }

    /*──────── claimHatsWithUser: open hats blocked, gated hats pass the gate ────────*/

    /*──────── registerAndClaimHats: open hats blocked, gated hats pass ────────*/

    /*──────── memberHat auto-mint paths are UNAFFECTED by the open-hat gate ────────*/

    function testQuickJoinWithUserUnaffectedByOpenHatGate() public {
        // The auto-mint join path mints memberHatIds directly from storage — never through the gate.
        registry.setUsername(user1, "bob");
        vm.prank(user1);
        qj.quickJoinWithUser();
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID), "member auto-mint unaffected");
    }

    function testRegisterAndQuickJoinUnaffectedByOpenHatGate() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"00";
        qj.registerAndQuickJoin(user1, "alice", deadline, 0, sig);
        assertTrue(mockExecutor.hats().isWearerOfHat(user1, DEFAULT_HAT_ID), "member auto-mint unaffected");
    }
}
