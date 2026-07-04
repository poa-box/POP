// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {CashOutRelay} from "../src/cashout/CashOutRelay.sol";

/// @dev Byte-for-byte replica of the PRE-migration (sequential + __gap) CashOutRelay storage
///      layout, matching the live Base proxy 0xA65414A21dc114199cAfD7c6c3ed99488Eb9eFE5. Used only
///      to reproduce the exact old storage image so the real migrateToV2 reinitializer can be
///      exercised against it. Storage order MUST match the pre-migration contract exactly.
contract LegacyCashOutRelay is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // slot 0
    address public escrow;
    // slot 1
    address public usdc;
    // slot 2
    address public owner;
    // slot 3
    address public cctpMessageTransmitter;
    // slot 4 / 5
    mapping(bytes32 => address) public failedDepositor;
    mapping(bytes32 => uint256) public failedAmount;
    // slot 6
    uint256 public totalFailedAmount;
    // slot 7
    uint256[44] private __gap;

    error NotOwner();

    function initialize(address _escrow, address _usdc, address _cctpMessageTransmitter, address _owner)
        external
        initializer
    {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        escrow = _escrow;
        usdc = _usdc;
        cctpMessageTransmitter = _cctpMessageTransmitter;
        owner = _owner;
    }

    /// @dev Test-only helper to seed a failed-deposit record (drives totalFailedAmount != 0).
    function seedFailed(bytes32 requestHash, address depositor, uint256 amount) external {
        failedDepositor[requestHash] = depositor;
        failedAmount[requestHash] = amount;
        totalFailedAmount += amount;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != owner) revert NotOwner();
    }
}

/// @notice Exercises the real CashOutRelay.migrateToV2 reinitializer against the exact legacy
///         storage image, mirroring the live Base upgradeToAndCall path.
contract CashOutRelayMigrationTest is Test {
    address constant ESCROW = 0x777777779d229cdF3110e9de47943791c26300Ef;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CCTP = 0x1682Ae6375C4E4A97e4B583BC394c861A46D8962;
    address constant OWNER = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    LegacyCashOutRelay legacy;
    address proxy;

    function setUp() public {
        LegacyCashOutRelay impl = new LegacyCashOutRelay();
        bytes memory initData =
            abi.encodeWithSelector(LegacyCashOutRelay.initialize.selector, ESCROW, BASE_USDC, CCTP, OWNER);
        proxy = address(new ERC1967Proxy(address(impl), initData));
        legacy = LegacyCashOutRelay(payable(proxy));
    }

    /// @notice Migration copies every live scalar field from its OLD sequential slot into the
    ///         new ERC-7201 Layout and hands ownership to Ownable2Step, preserving the same owner.
    function testMigration_CopiesAllFieldsAndOwner() public {
        // Sanity: legacy proxy has the pre-migration image.
        assertEq(legacy.escrow(), ESCROW);
        assertEq(legacy.usdc(), BASE_USDC);
        assertEq(legacy.owner(), OWNER);
        assertEq(legacy.cctpMessageTransmitter(), CCTP);
        assertEq(legacy.totalFailedAmount(), 0);

        // Perform the exact live upgrade path: upgradeToAndCall(newImpl, migrateToV2()).
        CashOutRelay newImpl = new CashOutRelay();
        vm.prank(OWNER);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));

        CashOutRelay relay = CashOutRelay(payable(proxy));

        // Every migrated field reads back identical through the new Layout getters.
        assertEq(relay.escrow(), ESCROW, "escrow migrated");
        assertEq(relay.usdc(), BASE_USDC, "usdc migrated");
        assertEq(relay.cctpMessageTransmitter(), CCTP, "cctp migrated");
        assertEq(relay.totalFailedAmount(), 0, "totalFailedAmount migrated");
        assertEq(relay.owner(), OWNER, "ownership handed to Ownable2Step, same owner");

        // New fields start at defaults.
        assertEq(relay.bungeeExecutor(), address(0), "bungeeExecutor starts empty");
        assertEq(relay.depositNonce(), 0, "depositNonce starts at 0");

        // The stale hand-rolled owner slot (slot 2) is zeroed.
        bytes32 slot2 = vm.load(proxy, bytes32(uint256(2)));
        assertEq(address(uint160(uint256(slot2))), address(0), "old owner slot zeroed");
    }

    /// @notice The migration reinitializer is burned — a second migrateToV2 reverts.
    function testMigration_ReinitializerBurned() public {
        CashOutRelay newImpl = new CashOutRelay();
        vm.prank(OWNER);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));

        // A second call to migrateToV2 (directly) reverts — reinitializer(2) already consumed.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        CashOutRelay(payable(proxy)).migrateToV2();

        // And a fresh upgrade that re-runs the migration calldata also reverts atomically.
        CashOutRelay newImpl2 = new CashOutRelay();
        vm.prank(OWNER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl2), abi.encodeCall(CashOutRelay.migrateToV2, ()));
    }

    /// @notice Post-migration the contract is fully operational: owner can set the Bungee
    ///         executor and the H-01 gate is live.
    function testMigration_OperationalAfterMigrate() public {
        CashOutRelay newImpl = new CashOutRelay();
        vm.prank(OWNER);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));

        CashOutRelay relay = CashOutRelay(payable(proxy));

        // Owner sets the Bungee executor (was empty after migration).
        address bungee = address(0xB009EE);
        vm.prank(OWNER);
        relay.setBungeeExecutor(bungee);
        assertEq(relay.bungeeExecutor(), bungee);

        // executeData is gated — an attacker is rejected.
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        address[] memory tokens = new address[](1);
        tokens[0] = BASE_USDC;
        vm.prank(address(0xBAD));
        vm.expectRevert(CashOutRelay.NotAuthorizedExecutor.selector);
        relay.executeData(bytes32(0), amounts, tokens, "");
    }

    /// @notice Migration refuses to run if the legacy proxy has outstanding failed-deposit funds,
    ///         because the mapping base-slot rehome would orphan them. Guards against a future
    ///         careless re-use of this migration when totalFailedAmount != 0.
    function testMigration_RevertsIfHeldRecoveryFundsExist() public {
        // Seed a failed-deposit record so totalFailedAmount != 0.
        legacy.seedFailed(keccak256("held"), address(0xBEEF), 100e6);
        assertEq(legacy.totalFailedAmount(), 100e6);

        CashOutRelay newImpl = new CashOutRelay();
        vm.prank(OWNER);
        vm.expectRevert(CashOutRelay.WouldDrainRecoveryFunds.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));
    }
}
