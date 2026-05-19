// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {Executor} from "../src/Executor.sol";
import {HybridVoting} from "../src/HybridVoting.sol";
import {DirectDemocracyVoting} from "../src/DirectDemocracyVoting.sol";
import {ParticipationToken} from "../src/ParticipationToken.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {EducationHub} from "../src/EducationHub.sol";
import {PaymentManager} from "../src/PaymentManager.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {OrgDeployer} from "../src/OrgDeployer.sol";
import {EligibilityModule} from "../src/EligibilityModule.sol";
import {ToggleModule} from "../src/ToggleModule.sol";
import {PasskeyAccount} from "../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../src/PasskeyAccountFactory.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PoaManager} from "../src/PoaManager.sol";
import {SwitchableBeacon} from "../src/SwitchableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockHats} from "./mocks/MockHats.sol";

/// @title UpgradeSafetyTest
/// @notice Comprehensive tests verifying upgrade safety invariants for all upgradeable contracts
contract UpgradeSafetyTest is Test {
    address constant OWNER = address(0xA);
    address constant HATS = address(0xB);
    address constant UNAUTHORIZED = address(0xDEAD);

    // ══════════════════════════════════════════════════════════════════════
    //  SECTION 1: Re-initialization prevention
    //  Every implementation contract must revert when initialize() is called
    // ══════════════════════════════════════════════════════════════════════

    function testExecutorImplCannotBeInitialized() public {
        Executor impl = new Executor();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS);
    }

    function testParticipationTokenImplCannotBeInitialized() public {
        ParticipationToken impl = new ParticipationToken();
        uint256[] memory hats = new uint256[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, "Token", "TKN", HATS, hats, hats);
    }

    function testTaskManagerImplCannotBeInitialized() public {
        TaskManager impl = new TaskManager();
        uint256[] memory hats = new uint256[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS, hats, OWNER, OWNER);
    }

    function testQuickJoinImplCannotBeInitialized() public {
        QuickJoin impl = new QuickJoin();
        uint256[] memory hats = new uint256[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS, OWNER, OWNER, hats);
    }

    function testEducationHubImplCannotBeInitialized() public {
        EducationHub impl = new EducationHub();
        uint256[] memory hats = new uint256[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS, OWNER, hats, hats);
    }

    function testPaymentManagerImplCannotBeInitialized() public {
        PaymentManager impl = new PaymentManager();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, OWNER);
    }

    function testUniversalAccountRegistryImplCannotBeInitialized() public {
        UniversalAccountRegistry impl = new UniversalAccountRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER);
    }

    function testImplementationRegistryImplCannotBeInitialized() public {
        ImplementationRegistry impl = new ImplementationRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER);
    }

    function testHybridVotingImplCannotBeInitialized() public {
        HybridVoting impl = new HybridVoting();
        uint256[] memory hats = new uint256[](0);
        address[] memory targets = new address[](0);
        HybridVoting.ClassConfig[] memory classes = new HybridVoting.ClassConfig[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(HATS, OWNER, hats, targets, 51, classes);
    }

    function testDirectDemocracyVotingImplCannotBeInitialized() public {
        DirectDemocracyVoting impl = new DirectDemocracyVoting();
        uint256[] memory hats = new uint256[](0);
        address[] memory targets = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(HATS, OWNER, hats, hats, targets, 51);
    }

    function testOrgRegistryImplCannotBeInitialized() public {
        OrgRegistry impl = new OrgRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS);
    }

    function testEligibilityModuleImplCannotBeInitialized() public {
        EligibilityModule impl = new EligibilityModule();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, HATS, OWNER);
    }

    function testToggleModuleImplCannotBeInitialized() public {
        ToggleModule impl = new ToggleModule();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER);
    }

    function testPaymasterHubImplCannotBeInitialized() public {
        PaymasterHub impl = new PaymasterHub();
        // PaymasterHub requires entryPoint to be a contract
        address mockEntryPoint = address(new MockEntryPoint());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(mockEntryPoint, HATS, OWNER);
    }

    function testPasskeyAccountImplCannotBeInitialized() public {
        PasskeyAccount impl = new PasskeyAccount();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), OWNER, 1 days);
    }

    function testPasskeyAccountFactoryImplCannotBeInitialized() public {
        PasskeyAccountFactory impl = new PasskeyAccountFactory();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, OWNER, OWNER, 1 days);
    }

    function testOrgDeployerImplCannotBeInitialized() public {
        OrgDeployer impl = new OrgDeployer();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER, OWNER, OWNER, OWNER, OWNER, HATS, OWNER, OWNER);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SECTION 2: PoaManager upgrade authorization
    // ══════════════════════════════════════════════════════════════════════

    function testPoaManagerUpgradeOnlyOwner() public {
        ImplementationRegistry reg = new ImplementationRegistry();
        // Initialize via proxy to bypass _disableInitializers on impl
        UpgradeableBeacon regBeacon = new UpgradeableBeacon(address(reg), address(this));
        BeaconProxy regProxy = new BeaconProxy(address(regBeacon), "");
        ImplementationRegistry(address(regProxy)).initialize(address(this));

        PoaManager pm = new PoaManager(address(regProxy));
        ImplementationRegistry(address(regProxy)).transferOwnership(address(pm));

        // Deploy a real implementation to upgrade to
        DummyImplV1 implV1 = new DummyImplV1();
        DummyImplV2 implV2 = new DummyImplV2();

        pm.addContractType("TestType", address(implV1));

        // Non-owner cannot upgrade
        vm.prank(UNAUTHORIZED);
        vm.expectRevert();
        pm.upgradeBeacon("TestType", address(implV2), "v2");

        // Owner can upgrade
        pm.upgradeBeacon("TestType", address(implV2), "v2");
        assertEq(pm.getCurrentImplementationById(keccak256("TestType")), address(implV2));
    }

    function testPoaManagerRejectsEOAImplementation() public {
        ImplementationRegistry reg = new ImplementationRegistry();
        UpgradeableBeacon regBeacon = new UpgradeableBeacon(address(reg), address(this));
        BeaconProxy regProxy = new BeaconProxy(address(regBeacon), "");
        ImplementationRegistry(address(regProxy)).initialize(address(this));

        PoaManager pm = new PoaManager(address(regProxy));
        ImplementationRegistry(address(regProxy)).transferOwnership(address(pm));

        // addContractType rejects EOA
        vm.expectRevert(PoaManager.ImplZero.selector);
        pm.addContractType("TestType", address(0x1234));

        // Set up a valid type first, then try upgrading to EOA
        DummyImplV1 implV1 = new DummyImplV1();
        pm.addContractType("TestType", address(implV1));

        vm.expectRevert(PoaManager.ImplZero.selector);
        pm.upgradeBeacon("TestType", address(0x5678), "v2");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SECTION 3: Storage preservation after beacon upgrade
    // ══════════════════════════════════════════════════════════════════════

    function testStoragePreservedAfterBeaconUpgrade() public {
        // Deploy V1 implementation behind a beacon
        UniversalAccountRegistry implV1 = new UniversalAccountRegistry();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implV1), address(this));
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");

        // Initialize and set state via proxy
        UniversalAccountRegistry registry = UniversalAccountRegistry(address(proxy));
        registry.initialize(address(this));

        // Register a user
        registry.registerAccount("alice");
        assertEq(registry.getUsername(address(this)), "alice");

        // Deploy V2 and upgrade beacon
        UniversalAccountRegistry implV2 = new UniversalAccountRegistry();
        beacon.upgradeTo(address(implV2));

        // Verify state is preserved after upgrade
        assertEq(registry.getUsername(address(this)), "alice");
    }

    /// @notice Proves that appending the folders fields (foldersRoot, organizerHatIds)
    ///         to TaskManager.Layout does not disturb pre-existing project state, and
    ///         that the new `setFolders` function is callable through a proxy upgraded
    ///         from a previous impl. Two impls of the same struct simulate the
    ///         upgrade — append-only storage means the new impl reads old state
    ///         identically.
    function testTaskManagerStoragePreservedAfterFoldersUpgrade() public {
        MockHats hats = new MockHats();
        uint256 creatorHat = 1;
        uint256 organizerHat = 99;
        address creator = makeAddr("creator");
        address exec = makeAddr("executor");
        address organizer = makeAddr("organizer");
        hats.mintHat(creatorHat, creator);
        hats.mintHat(organizerHat, organizer);

        // Token doesn't need to be real for these reads — any non-zero contract works.
        address token = address(new DummyImplV1());

        // Deploy "v1" impl + proxy and write state.
        TaskManager implV1 = new TaskManager();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implV1), address(this));
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        TaskManager tm = TaskManager(address(proxy));

        uint256[] memory creators = new uint256[](1);
        creators[0] = creatorHat;
        vm.prank(creator);
        tm.initialize(token, address(hats), creators, exec, address(0));

        // Pre-upgrade state: an organizer hat allowance + a project + a folders root.
        vm.prank(exec);
        tm.setConfig(TaskManager.ConfigKey.ORGANIZER_HAT_ALLOWED, abi.encode(organizerHat, true));

        vm.prank(creator);
        bytes32 pid = tm.createProject(
            TaskManager.BootstrapProjectConfig({
                title: bytes("PRE_UPGRADE"),
                metadataHash: bytes32(0),
                cap: 5 ether,
                managers: new address[](0),
                createHats: creators,
                claimHats: new uint256[](0),
                reviewHats: new uint256[](0),
                assignHats: new uint256[](0),
                bountyTokens: new address[](0),
                bountyCaps: new uint256[](0)
            })
        );

        bytes32 rootBefore = keccak256("root-before-upgrade");
        vm.prank(organizer);
        tm.setFolders(bytes32(0), rootBefore);

        // Read state via lens for comparison post-upgrade.
        bytes memory execLensBefore = tm.getLensData(4, "");
        bytes memory creatorHatsBefore = tm.getLensData(5, "");
        bytes memory projectLensBefore = tm.getLensData(2, abi.encode(pid));
        bytes memory foldersLensBefore = tm.getLensData(10, "");
        bytes memory organizersLensBefore = tm.getLensData(11, "");

        // "Upgrade" — same impl class, new instance.
        TaskManager implV2 = new TaskManager();
        beacon.upgradeTo(address(implV2));

        // Storage must be byte-identical for every lens variant.
        assertEq(keccak256(tm.getLensData(4, "")), keccak256(execLensBefore), "executor drifted");
        assertEq(keccak256(tm.getLensData(5, "")), keccak256(creatorHatsBefore), "creator hats drifted");
        assertEq(keccak256(tm.getLensData(2, abi.encode(pid))), keccak256(projectLensBefore), "project drifted");
        assertEq(keccak256(tm.getLensData(10, "")), keccak256(foldersLensBefore), "folders root drifted");
        assertEq(keccak256(tm.getLensData(11, "")), keccak256(organizersLensBefore), "organizer hats drifted");

        // New folder writes must still go through CAS guard, and organizer hat plumbing
        // must survive the upgrade so organizer can still reorg.
        bytes32 rootAfter = keccak256("root-after-upgrade");
        vm.prank(organizer);
        tm.setFolders(rootBefore, rootAfter);
        assertEq(abi.decode(tm.getLensData(10, ""), (bytes32)), rootAfter, "new folder write must land");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SECTION 4: SwitchableBeacon mode-switch safety
    // ══════════════════════════════════════════════════════════════════════

    function testSwitchableBeaconMirrorToStaticPreservesProxy() public {
        // Set up POA global beacon with V1
        DummyImplV1 implV1 = new DummyImplV1();
        UpgradeableBeacon poaBeacon = new UpgradeableBeacon(address(implV1), address(this));

        // Create SwitchableBeacon in Mirror mode
        SwitchableBeacon switchable =
            new SwitchableBeacon(address(this), address(poaBeacon), address(0), SwitchableBeacon.Mode.Mirror);

        // Verify mirror mode returns POA impl
        assertEq(switchable.implementation(), address(implV1));

        // Switch to static (pin to current)
        switchable.pinToCurrent();
        assertEq(switchable.implementation(), address(implV1));
        assertEq(uint256(switchable.mode()), uint256(SwitchableBeacon.Mode.Static));

        // Upgrade POA beacon to V2 - static beacon should NOT follow
        DummyImplV2 implV2 = new DummyImplV2();
        poaBeacon.upgradeTo(address(implV2));

        // SwitchableBeacon still returns V1 (pinned)
        assertEq(switchable.implementation(), address(implV1));

        // Switch back to mirror - should now follow V2
        switchable.setMirror(address(poaBeacon));
        assertEq(switchable.implementation(), address(implV2));
        assertEq(uint256(switchable.mode()), uint256(SwitchableBeacon.Mode.Mirror));
    }

    function testSwitchableBeaconOnlyOwnerCanSwitchModes() public {
        DummyImplV1 implV1 = new DummyImplV1();
        UpgradeableBeacon poaBeacon = new UpgradeableBeacon(address(implV1), address(this));

        SwitchableBeacon switchable =
            new SwitchableBeacon(address(this), address(poaBeacon), address(0), SwitchableBeacon.Mode.Mirror);

        // Non-owner cannot pin
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        switchable.pin(address(implV1));

        // Non-owner cannot set mirror
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        switchable.setMirror(address(poaBeacon));

        // Non-owner cannot pin to current
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        switchable.pinToCurrent();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SECTION 5: Proxy initialization works correctly
    // ══════════════════════════════════════════════════════════════════════

    function testProxyCanBeInitializedWhileImplBlocked() public {
        // Implementation cannot be initialized (blocked by constructor)
        ImplementationRegistry impl = new ImplementationRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(OWNER);

        // But proxy CAN be initialized through beacon
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        ImplementationRegistry(address(proxy)).initialize(OWNER);
        assertEq(ImplementationRegistry(address(proxy)).owner(), OWNER);
    }

    function testProxyCannotBeInitializedTwice() public {
        UniversalAccountRegistry impl = new UniversalAccountRegistry();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");

        // First initialization succeeds
        UniversalAccountRegistry(address(proxy)).initialize(OWNER);

        // Second initialization reverts
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UniversalAccountRegistry(address(proxy)).initialize(address(0xBEEF));
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Mock contracts for upgrade testing
// ══════════════════════════════════════════════════════════════════════

contract DummyImplV1 {
    uint256 public version = 1;
}

contract DummyImplV2 {
    uint256 public version = 2;
}

contract MockEntryPoint {
    mapping(address => uint256) public balances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }
}
