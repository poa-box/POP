// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../src/ImplementationRegistry.sol";

contract ImplementationRegistryTest is Test {
    ImplementationRegistry reg;

    function setUp() public {
        ImplementationRegistry _regImpl = new ImplementationRegistry();
        UpgradeableBeacon _regBeacon = new UpgradeableBeacon(address(_regImpl), address(this));
        reg = ImplementationRegistry(address(new BeaconProxy(address(_regBeacon), "")));
        reg.initialize(address(this));
    }

    function testRegisterAndLatest() public {
        reg.registerImplementation("TypeA", "v1", address(0x1), true);
        assertEq(reg.getLatestImplementation("TypeA"), address(0x1));
        reg.registerImplementation("TypeA", "v2", address(0x2), true);
        assertEq(reg.getLatestImplementation("TypeA"), address(0x2));
        assertEq(reg.getImplementation("TypeA", "v1"), address(0x1));
        assertEq(reg.getVersionCount("TypeA"), 2);
    }

    /*////////////////////////////////////////////////////////////
        L-58: first registration must set `latest` even if setLatest=false
    ////////////////////////////////////////////////////////////*/
    function testFirstRegisterSetsLatestEvenWhenSetLatestFalse() public {
        // Register the FIRST version of a type with setLatest=false.
        // Pre-fix: getLatestImplementation would revert TypeUnknown despite a valid impl.
        reg.registerImplementation("TypeB", "v1", address(0xB1), false);
        assertEq(reg.getLatestImplementation("TypeB"), address(0xB1), "first register must become latest");
        assertEq(reg.getImplementation("TypeB", "v1"), address(0xB1));
        assertEq(reg.getVersionCount("TypeB"), 1);
    }

    function testFirstRegisterEmitsLatestTrue() public {
        // The event must reflect that the first version became latest, even with setLatest=false.
        vm.expectEmit(true, true, false, true);
        emit ImplementationRegistered(
            keccak256(bytes("TypeC")), "TypeC", keccak256(bytes("v1")), "v1", address(0xC1), true
        );
        reg.registerImplementation("TypeC", "v1", address(0xC1), false);
    }

    function testSecondRegisterDoesNotForceLatest() public {
        // First version becomes latest automatically...
        reg.registerImplementation("TypeD", "v1", address(0xD1), false);
        assertEq(reg.getLatestImplementation("TypeD"), address(0xD1));
        // ...but a subsequent register with setLatest=false must NOT move latest.
        reg.registerImplementation("TypeD", "v2", address(0xD2), false);
        assertEq(reg.getLatestImplementation("TypeD"), address(0xD1), "latest must stay pinned to v1");
        // Explicit promotion still works.
        reg.setLatestVersion("TypeD", "v2");
        assertEq(reg.getLatestImplementation("TypeD"), address(0xD2));
    }

    // Mirror of the contract event so vm.expectEmit can match on it.
    event ImplementationRegistered(
        bytes32 indexed typeId,
        string typeName,
        bytes32 indexed versionId,
        string version,
        address implementation,
        bool latest
    );
}
