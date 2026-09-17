// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockEntryPoint, MockHats} from "./PaymasterHubSolidarity.t.sol";

/// @title PaymasterHubAccessV2Test
/// @notice Coverage for the §4.8 one-function change: protocolAdmin-gated setHats(address) + HatsSet
///         event (the §6 step-0.3 router repoint). Validation semantics are otherwise untouched.
contract PaymasterHubAccessV2Test is Test {
    PaymasterHub hub;
    MockEntryPoint ep;
    MockHats hats;

    address poaManager = address(0xA0A);
    address protocolAdmin = address(0xADA);
    address router = address(0x9007E5);
    address stranger = address(0xBAD);

    event HatsSet(address indexed hats);

    function setUp() public {
        ep = new MockEntryPoint();
        hats = new MockHats();

        PaymasterHub impl = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(ep), address(hats), poaManager);
        hub = PaymasterHub(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.prank(poaManager);
        hub.setProtocolAdmin(protocolAdmin);
    }

    /*───────────────────── Auth matrix ─────────────────────*/
    function testPoaManagerCanSetHats() public {
        vm.expectEmit(true, false, false, false, address(hub));
        emit HatsSet(router);
        vm.prank(poaManager);
        hub.setHats(router);
        assertEq(hub.HATS(), router);
    }

    function testProtocolAdminCanSetHats() public {
        vm.prank(protocolAdmin);
        hub.setHats(router);
        assertEq(hub.HATS(), router);
    }

    function testStrangerCannotSetHats() public {
        vm.prank(stranger);
        vm.expectRevert(PaymasterHubErrors.NotOperator.selector);
        hub.setHats(router);
    }

    function testSetHatsZeroReverts() public {
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.ZeroAddress.selector);
        hub.setHats(address(0));
    }

    /*───────────────────── Rollback (repoint back to a legacy Hats) ─────────────────────*/
    function testSetHatsRollback() public {
        vm.startPrank(poaManager);
        hub.setHats(router);
        assertEq(hub.HATS(), router);
        MockHats legacy = new MockHats();
        hub.setHats(address(legacy));
        assertEq(hub.HATS(), address(legacy));
        vm.stopPrank();
    }

    /*───────────────────── Impl deploys (size gate is the production --sizes run) ─────────────────────*/
    /// @dev The EIP-170 runtime-size gate is enforced by `FOUNDRY_PROFILE=production forge build
    ///      --sizes` (measured: 22,602 B runtime / 1,974 B margin). Under the default test profile the
    ///      optimizer is OFF (~2× size), so an in-test byte bound would be meaningless; this only
    ///      confirms the one-function bump still yields deployable bytecode.
    function testHubImplDeploys() public {
        PaymasterHub impl = new PaymasterHub();
        assertGt(address(impl).code.length, 0);
    }
}
