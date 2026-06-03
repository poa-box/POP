// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/QuickJoin.sol";
import "./mocks/MockHats.sol";

/// @notice Minimal RoleBundleHatter mock for QuickJoin unit tests.
///         Just mints the requested role hat — bundle expansion is exercised in the
///         RoleBundleHatter tests directly.
contract MockRoleBundleHatter {
    MockHats public hats;
    address public lastUser;
    uint256 public lastRoleHat;
    uint256 public mintRoleCalls;

    constructor(MockHats _hats) {
        hats = _hats;
    }

    function mintRole(uint256 roleHat, address user) external {
        lastUser = user;
        lastRoleHat = roleHat;
        unchecked {
            ++mintRoleCalls;
        }
        hats.mintHat(roleHat, user);
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
    MockRoleBundleHatter bundleHatter;

    event QuickJoined(address indexed user, uint256 memberHat);
    event QuickJoinedByMaster(address indexed master, address indexed user, uint256 memberHat);
    event RegisterAndQuickJoined(address indexed user, string username, uint256 memberHat);

    address executor = address(0x1);
    address master = address(0x2);
    address user1 = address(0x100);
    address user2 = address(0x200);

    uint256 constant DEFAULT_HAT_ID = 1;

    function setUp() public {
        hats = new MockHats();
        registry = new MockRegistry();
        bundleHatter = new MockRoleBundleHatter(hats);
        QuickJoin _qjImpl = new QuickJoin();
        UpgradeableBeacon _qjBeacon = new UpgradeableBeacon(address(_qjImpl), address(this));
        qj = QuickJoin(address(new BeaconProxy(address(_qjBeacon), "")));

        qj.initialize(executor, address(hats), address(registry), master, DEFAULT_HAT_ID, address(bundleHatter));
    }

    /* ═══════════════════ Initialization ═══════════════════ */

    function testInitializeStoresArgs() public {
        assertEq(address(qj.hats()), address(hats));
        assertEq(address(qj.accountRegistry()), address(registry));
        assertEq(qj.masterDeployAddress(), master);
        assertEq(qj.executor(), executor);
        assertEq(qj.memberHat(), DEFAULT_HAT_ID);
        assertEq(qj.roleBundleHatter(), address(bundleHatter));
    }

    function testInitializeZeroExecutorReverts() public {
        QuickJoin _tmpImpl = new QuickJoin();
        UpgradeableBeacon _tmpBeacon = new UpgradeableBeacon(address(_tmpImpl), address(this));
        QuickJoin tmp = QuickJoin(address(new BeaconProxy(address(_tmpBeacon), "")));
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        tmp.initialize(address(0), address(hats), address(registry), master, DEFAULT_HAT_ID, address(bundleHatter));
    }

    function testInitializeAllowsZeroRoleBundleHatter() public {
        // RoleBundleHatter may be unset during bootstrap; setRoleBundleHatter wires it later.
        QuickJoin _tmpImpl = new QuickJoin();
        UpgradeableBeacon _tmpBeacon = new UpgradeableBeacon(address(_tmpImpl), address(this));
        QuickJoin tmp = QuickJoin(address(new BeaconProxy(address(_tmpBeacon), "")));
        tmp.initialize(executor, address(hats), address(registry), master, DEFAULT_HAT_ID, address(0));
        assertEq(tmp.roleBundleHatter(), address(0));
    }

    function testInitializeCannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        qj.initialize(executor, address(hats), address(registry), master, DEFAULT_HAT_ID, address(bundleHatter));
    }

    /* ═══════════════════ Setters ═══════════════════ */

    function testUpdateAddresses() public {
        MockHats h2 = new MockHats();
        MockRegistry r2 = new MockRegistry();
        address master2 = address(0x3);

        vm.prank(executor);
        qj.updateAddresses(address(h2), address(r2), master2);

        assertEq(address(qj.hats()), address(h2));
        assertEq(address(qj.accountRegistry()), address(r2));
        assertEq(qj.masterDeployAddress(), master2);
    }

    function testUpdateAddressesUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.updateAddresses(address(hats), address(registry), master);
    }

    function testSetMemberHat() public {
        uint256 newHat = 99;
        vm.prank(executor);
        qj.setMemberHat(newHat);
        assertEq(qj.memberHat(), newHat);
    }

    function testSetMemberHatUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.setMemberHat(99);
    }

    function testSetRoleBundleHatter() public {
        MockRoleBundleHatter newHatter = new MockRoleBundleHatter(hats);
        vm.prank(executor);
        qj.setRoleBundleHatter(address(newHatter));
        assertEq(qj.roleBundleHatter(), address(newHatter));
    }

    function testSetRoleBundleHatterZeroReverts() public {
        vm.prank(executor);
        vm.expectRevert(QuickJoin.InvalidAddress.selector);
        qj.setRoleBundleHatter(address(0));
    }

    function testSetRoleBundleHatterUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.setRoleBundleHatter(address(0x9));
    }

    function testSetExecutor() public {
        address newExec = address(0x9);
        vm.prank(executor);
        qj.setExecutor(newExec);
        assertEq(qj.executor(), newExec);
    }

    function testSetExecutorUnauthorized() public {
        vm.expectRevert(QuickJoin.Unauthorized.selector);
        qj.setExecutor(address(0x9));
    }

    /* ═══════════════════ Join flows route through RoleBundleHatter ═══════════════════ */

    function testQuickJoinWithUserRoutesThroughBundleHatter() public {
        registry.setUsername(user1, "bob");
        vm.prank(user1);
        qj.quickJoinWithUser();

        assertEq(bundleHatter.mintRoleCalls(), 1);
        assertEq(bundleHatter.lastUser(), user1);
        assertEq(bundleHatter.lastRoleHat(), DEFAULT_HAT_ID);
        assertTrue(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testQuickJoinWithUserEmitsSingleHatEvent() public {
        registry.setUsername(user1, "bob");
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit QuickJoined(user1, DEFAULT_HAT_ID);
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
        assertEq(bundleHatter.mintRoleCalls(), 1);
        assertTrue(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testQuickJoinNoUserMasterDeployByExecutor() public {
        vm.prank(executor);
        qj.quickJoinNoUserMasterDeploy(user1);
        assertTrue(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
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
        assertTrue(hats.isWearerOfHat(user2, DEFAULT_HAT_ID));
    }

    function testQuickJoinWithUserMasterDeployUnauthorized() public {
        registry.setUsername(user1, "bob");
        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.quickJoinWithUserMasterDeploy(user1);
    }

    /* ═══════════════════ Bootstrap mode: no-op when memberHat or bundleHatter is zero ═══════════════════ */

    function testJoinWithZeroMemberHatIsNoOp() public {
        // Configure: memberHat=0 (no member role to grant)
        vm.prank(executor);
        qj.setMemberHat(0);

        registry.setUsername(user1, "bob");
        vm.prank(user1);
        qj.quickJoinWithUser();

        // No mint call; user wears nothing
        assertEq(bundleHatter.mintRoleCalls(), 0);
        assertFalse(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testJoinWithZeroBundleHatterIsNoOp() public {
        // Spin up a fresh proxy with bundleHatter unset (bootstrap state)
        QuickJoin _tmpImpl = new QuickJoin();
        UpgradeableBeacon _tmpBeacon = new UpgradeableBeacon(address(_tmpImpl), address(this));
        QuickJoin tmp = QuickJoin(address(new BeaconProxy(address(_tmpBeacon), "")));
        tmp.initialize(executor, address(hats), address(registry), master, DEFAULT_HAT_ID, address(0));

        registry.setUsername(user1, "bob");
        vm.prank(user1);
        tmp.quickJoinWithUser();

        // No mint; bundleHatter not wired
        assertFalse(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    /* ═══════════════════ registerAndQuickJoin (EOA) ═══════════════════ */

    function testRegisterAndQuickJoin() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 0;
        bytes memory sig = hex"00";

        address sponsor = address(0xBEEF);
        vm.prank(sponsor);
        qj.registerAndQuickJoin(user1, "alice", deadline, nonce, sig);

        assertEq(registry.usernames(user1), "alice");
        assertTrue(hats.isWearerOfHat(user1, DEFAULT_HAT_ID));
    }

    function testRegisterAndQuickJoinEmitsEvent() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"00";

        vm.expectEmit(true, false, false, true);
        emit RegisterAndQuickJoined(user1, "alice", DEFAULT_HAT_ID);
        qj.registerAndQuickJoin(user1, "alice", deadline, 0, sig);
    }

    function testRegisterAndQuickJoinZeroUser() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"00";

        vm.expectRevert(QuickJoin.ZeroUser.selector);
        qj.registerAndQuickJoin(address(0), "alice", deadline, 0, sig);
    }

    /* ═══════════════════ registerAndQuickJoinWithPasskey (no factory) ═══════════════════ */

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

        vm.prank(address(0x999));
        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.registerAndQuickJoinWithPasskeyMasterDeploy(passkey, "alice", deadline, 0, auth);
    }
}
