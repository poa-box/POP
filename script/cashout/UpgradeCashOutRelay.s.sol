// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * @title UpgradeCashOutRelay (RETIRED — do not run)
 * @notice This script predates the WS-F security migration. CashOutRelay moved
 *         from sequential + __gap storage to an ERC-7201 namespaced Layout, so a
 *         bare `upgradeToAndCall(newImpl, "")` from this script would switch the
 *         live Base proxy to the new implementation WITHOUT running the storage
 *         migration — owner()/escrow()/usdc() would all read zero until
 *         migrateToV2 is called.
 *
 *         Use script/upgrades/UpgradeCashOutRelaySecurity.s.sol instead: it
 *         performs the atomic `upgradeToAndCall(newImpl, migrateToV2 calldata)`
 *         and has a SimBase sibling that must PASS before any broadcast.
 */
contract UpgradeCashOutRelay is Script {
    error RetiredUseUpgradeCashOutRelaySecurity();

    function run() public pure {
        revert RetiredUseUpgradeCashOutRelaySecurity();
    }
}
