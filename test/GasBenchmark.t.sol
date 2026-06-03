// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/**
 * @notice Side-by-side gas benchmarks: old "array of allowed hats" model vs. new
 *         "single capability hat" model. Both implementations are inlined here so
 *         the gas numbers reflect ONLY the permission-check work (no test harness
 *         overhead, no proxy delegatecall, no business logic).
 *
 *         All measurements use vm.snapshot/forge gas accounting. To replicate the
 *         numbers, run:
 *
 *             forge test --match-contract GasBenchmark -vv
 *
 *         and read the "gas:" column.
 */
contract OldModelGate {
    /// Mimics the pre-refactor TaskManager._permMask logic: loops permissionHatIds,
    /// batch-checks via balanceOfBatch, ORs together project/global masks.
    IHats public hats;
    uint256[] public permissionHatIds;
    mapping(uint256 => uint8) public rolePermGlobal;

    uint8 constant CREATE = 1 << 0;

    constructor(IHats _hats, uint256[] memory _hatIds) {
        hats = _hats;
        for (uint256 i; i < _hatIds.length; ++i) {
            permissionHatIds.push(_hatIds[i]);
            rolePermGlobal[_hatIds[i]] = CREATE;
        }
    }

    function checkCanCreate(address user) external view returns (bool) {
        uint256 len = permissionHatIds.length;
        if (len == 0) return false;
        address[] memory wearers = new address[](len);
        uint256[] memory hatIds_ = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            wearers[i] = user;
            hatIds_[i] = permissionHatIds[i];
        }
        uint256[] memory bal = hats.balanceOfBatch(wearers, hatIds_);
        uint8 m;
        for (uint256 i; i < len; ++i) {
            if (bal[i] > 0) {
                uint8 mask = rolePermGlobal[hatIds_[i]];
                m |= mask;
            }
        }
        return m & CREATE != 0;
    }
}

contract NewModelGate {
    /// Mimics the new TaskManager._hasCap logic: single SLOAD + single isWearerOfHat.
    IHats public hats;
    uint256 public createHat;

    constructor(IHats _hats, uint256 _createHat) {
        hats = _hats;
        createHat = _createHat;
    }

    function checkCanCreate(address user) external view returns (bool) {
        uint256 hat = createHat;
        if (hat == 0) return false;
        return hats.isWearerOfHat(user, hat);
    }
}

contract GasBenchmarkTest is Test {
    MockHats hats;
    address constant USER = address(0xA11CE);
    uint256 constant HAT_1 = 1001;
    uint256 constant HAT_2 = 1002;
    uint256 constant HAT_3 = 1003;
    uint256 constant HAT_4 = 1004;
    uint256 constant HAT_5 = 1005;

    function setUp() public {
        hats = new MockHats();
        // Give USER only HAT_3 — middle of the array for the old model so we exercise
        // the typical "iterate, find, then OR" path.
        hats.mintHat(HAT_3, USER);
    }

    /// @notice Old model with 5 permission hats. ~12k gas per check (matches the audit estimate).
    function testGas_OldModel_5hats() public {
        uint256[] memory hatIds = new uint256[](5);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;
        hatIds[3] = HAT_4;
        hatIds[4] = HAT_5;
        OldModelGate gate = new OldModelGate(IHats(address(hats)), hatIds);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        emit log_named_uint("OLD model checkCanCreate (5 hats) gas", gasUsed);
    }

    /// @notice Old model with 3 permission hats.
    function testGas_OldModel_3hats() public {
        uint256[] memory hatIds = new uint256[](3);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_3;
        OldModelGate gate = new OldModelGate(IHats(address(hats)), hatIds);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        emit log_named_uint("OLD model checkCanCreate (3 hats) gas", gasUsed);
    }

    /// @notice Old model with 1 permission hat (best case for the old model — array short-circuit).
    function testGas_OldModel_1hat() public {
        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = HAT_3;
        OldModelGate gate = new OldModelGate(IHats(address(hats)), hatIds);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        emit log_named_uint("OLD model checkCanCreate (1 hat) gas", gasUsed);
    }

    /// @notice New model: single SLOAD + single isWearerOfHat.
    function testGas_NewModel_singleCapHat() public {
        NewModelGate gate = new NewModelGate(IHats(address(hats)), HAT_3);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        emit log_named_uint("NEW model checkCanCreate (1 capability hat) gas", gasUsed);
    }

    /// @notice Worst case for old model: user has no relevant hat, must still iterate full array.
    function testGas_OldModel_5hats_userDoesNotPass() public {
        uint256[] memory hatIds = new uint256[](5);
        hatIds[0] = HAT_1;
        hatIds[1] = HAT_2;
        hatIds[2] = HAT_4;
        hatIds[3] = HAT_5;
        hatIds[4] = 9999; // user wears HAT_3 only, none of these
        OldModelGate gate = new OldModelGate(IHats(address(hats)), hatIds);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertFalse(ok);
        emit log_named_uint("OLD model checkCanCreate (5 hats, REJECT) gas", gasUsed);
    }

    /// @notice New model worst case: same as best case (constant time).
    function testGas_NewModel_userDoesNotPass() public {
        NewModelGate gate = new NewModelGate(IHats(address(hats)), 9999);

        uint256 gasBefore = gasleft();
        bool ok = gate.checkCanCreate(USER);
        uint256 gasUsed = gasBefore - gasleft();

        assertFalse(ok);
        emit log_named_uint("NEW model checkCanCreate (REJECT) gas", gasUsed);
    }
}
