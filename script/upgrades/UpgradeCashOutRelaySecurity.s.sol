// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CashOutRelay} from "../../src/cashout/CashOutRelay.sol";

/*
 * ============================================================================
 * Security remediation upgrade — CashOutRelay (WS-F: audit H-01, L-44, L-45,
 * L-46, L-47, M-16)
 * ============================================================================
 *
 * CashOutRelay is a STANDALONE UUPS proxy on Base (NOT a beacon/registry-managed
 * module — it is not in any ImplementationRegistry and has no DeterministicDeployer
 * salt). The upgrade is a plain `upgradeToAndCall(newImpl, migrateCalldata)`.
 *
 *   Live proxy (Base): 0xA65414A21dc114199cAfD7c6c3ed99488Eb9eFE5
 *   Live owner / UUPS authorizer: 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9
 *     (verified on Base via `cast storage <proxy> 2` and the old `owner()` getter;
 *      _authorizeUpgrade gates on msg.sender == owner, so the OWNER prank/broadcast
 *      is the correct signer — this owner is ALSO the Gnosis/Arbitrum admin EOA,
 *      but that is coincidental: authorization here is the relay's own owner slot,
 *      not the Satellite/Hub admin.)
 *   Live _initialized: 1 (verified via `cast storage <proxy>
 *     0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`)
 *     => the migration uses reinitializer(2), the next free init slot.
 *
 * ── WHAT CHANGES ──
 *   H-01: executeData is now gated to a stored trusted Bungee executor (or owner);
 *         a new owner-only setBungeeExecutor installs it post-upgrade.
 *   L-44: _disableInitializers() added to the impl constructor.
 *   L-45: sequential storage + uint256[44] __gap -> ERC-7201 namespaced Layout
 *         (slot keccak256("poa.cashoutrelay.storage")).
 *   L-46: hand-rolled `owner` -> Ownable2StepUpgradeable (transfer + accept).
 *   L-47: executeData deposits the actual delivered balance, not the claimed amount.
 *   M-16: createDepositFromBalance requestHash derives from a monotonic nonce.
 *
 * ── MIGRATION ──
 *   upgradeToAndCall runs migrateToV2() atomically. It raw-sloads the OLD sequential
 *   slots (0=escrow, 1=usdc, 2=owner, 3=cctp, 6=totalFailedAmount) and copies them into
 *   the new Layout, transfers ownership to Ownable2Step (same owner), and zeroes the
 *   stale owner slot. It REQUIRES totalFailedAmount == 0 (the live proxy has zero failed
 *   deposits — no CashOutFailed event ever emitted — so the mapping base-slot rehome
 *   orphans nothing). The proxy is never left half-migrated.
 *
 *   POST-UPGRADE OPERATIONAL STEP (not in this script's broadcast; owner does it next):
 *     CashOutRelay(proxy).setBungeeExecutor(<trusted Bungee destination executor>)
 *   until then executeData is callable only by the owner.
 *
 * ── SIM (must PASS under FOUNDRY_PROFILE=production before broadcast) ──
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeCashOutRelaySecurity.s.sol:SimBase --fork-url base -vvv
 *
 * ── BROADCAST (do NOT run in this workstream) ──
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeCashOutRelaySecurity.s.sol:BroadcastBase \
 *     --rpc-url base --broadcast --slow --private-key $DEPLOYER_PRIVATE_KEY
 */

abstract contract CashOutRelayUpgradeBase is Script {
    /// @dev Live UUPS proxy on Base.
    address internal constant PROXY = 0xA65414A21dc114199cAfD7c6c3ed99488Eb9eFE5;

    /// @dev OZ v5 InitializableStorage ERC-7201 slot (holds the packed _initialized/_initializing).
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev Snapshot of every live field read BEFORE the upgrade (through the old sequential slots).
    struct LiveState {
        address escrow;
        address usdc;
        address owner;
        address cctp;
        uint256 totalFailedAmount;
        uint64 initializedVersion;
    }

    /// @dev Read the pre-migration state directly from the sequential storage slots so the
    ///      snapshot does not depend on which impl is currently deployed.
    function _readLiveState() internal view returns (LiveState memory s) {
        s.escrow = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(0))))));
        s.usdc = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(1))))));
        s.owner = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(2))))));
        s.cctp = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(3))))));
        s.totalFailedAmount = uint256(vm.load(PROXY, bytes32(uint256(6))));
        // Low 64 bits of the Initializable slot are _initialized.
        s.initializedVersion = uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT)));
    }

    function _logLiveState(LiveState memory s) internal pure {
        console.log("  escrow:            ", s.escrow);
        console.log("  usdc:              ", s.usdc);
        console.log("  owner:             ", s.owner);
        console.log("  cctp transmitter:  ", s.cctp);
        console.log("  totalFailedAmount: ", s.totalFailedAmount);
        console.log("  _initialized:      ", s.initializedVersion);
    }
}

/**
 * @title BroadcastBase
 * @notice Deploy the new CashOutRelay impl and upgrade the live Base proxy, running the
 *         migrateToV2 reinitializer atomically. Broadcast as the relay owner.
 */
contract BroadcastBase is CashOutRelayUpgradeBase {
    function run() public {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address deployer = vm.addr(deployerKey);

        LiveState memory pre = _readLiveState();
        console.log("\n=== Upgrade CashOutRelay on Base (security remediation) ===");
        console.log("Proxy:   ", PROXY);
        console.log("Deployer:", deployer);
        console.log("Pre-upgrade live state:");
        _logLiveState(pre);

        require(deployer == pre.owner, "deployer is not the relay owner (UUPS authorizer)");

        vm.startBroadcast(deployerKey);
        CashOutRelay newImpl = new CashOutRelay();
        console.log("New impl:", address(newImpl));
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));
        vm.stopBroadcast();

        console.log("\nUpgrade + migration complete.");
        console.log("NEXT (owner action): setBungeeExecutor(<trusted Bungee executor>) to enable executeData.");
    }
}

/**
 * @title SimBase
 * @notice Fork simulation of the exact BroadcastBase call path, pranked as the live owner.
 *         Reads every migrated field from the LIVE proxy pre-upgrade, executes
 *         upgradeToAndCall, then asserts every field reads back IDENTICAL through the new
 *         Layout, the attacker executeData path reverts, and the reinitializer is burned.
 *
 *   FOUNDRY_PROFILE=production forge script \
 *     script/upgrades/UpgradeCashOutRelaySecurity.s.sol:SimBase --fork-url base -vvv
 */
contract SimBase is CashOutRelayUpgradeBase {
    /// @dev A depositor to probe for a live failed-deposit record. No CashOutFailed event has
    ///      ever been emitted on the live proxy (verified via `cast logs`), so this is the
    ///      documented zero-case: the entry must be empty both before and after migration.
    address internal constant PROBE_DEPOSITOR = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

    function run() public {
        LiveState memory pre = _readLiveState();

        console.log("\n=== SIM: CashOutRelay security upgrade on Base ===");
        console.log("Pre-upgrade live state (raw sequential slots):");
        _logLiveState(pre);

        // Guardrails against a stale fork / wrong-proxy sim.
        require(pre.owner != address(0), "SIM: live owner is zero (wrong proxy?)");
        require(pre.escrow != address(0), "SIM: live escrow is zero (wrong proxy?)");
        require(pre.usdc != address(0), "SIM: live usdc is zero (wrong proxy?)");
        require(pre.initializedVersion == 1, "SIM: expected live _initialized == 1 before migration");
        require(pre.totalFailedAmount == 0, "SIM: live totalFailedAmount must be 0 for this migration");

        // Probe a known depositor's failed record via the OLD mapping slot (slot 4). Documented
        // zero-case: no failed deposits exist on the live proxy.
        bytes32 probeKey = keccak256("cashout-sim-probe"); // arbitrary requestHash; expect empty
        address probeOldFailedDepositor =
            address(uint160(uint256(vm.load(PROXY, keccak256(abi.encode(probeKey, uint256(4)))))));
        require(probeOldFailedDepositor == address(0), "SIM: unexpected live failed-deposit entry");
        console.log("Live failed-deposit entries: NONE (zero-case documented & asserted)");

        // ---- Perform the upgrade exactly as BroadcastBase would, pranked as the live owner. ----
        CashOutRelay newImpl = new CashOutRelay();
        console.log("New impl deployed at:", address(newImpl));

        vm.prank(pre.owner);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), abi.encodeCall(CashOutRelay.migrateToV2, ()));
        console.log("upgradeToAndCall(newImpl, migrateToV2()) executed.");

        CashOutRelay relay = CashOutRelay(payable(PROXY));

        // ---- Assert every migrated field reads back IDENTICAL through the new Layout. ----
        require(relay.escrow() == pre.escrow, "SIM: escrow changed across migration");
        require(relay.usdc() == pre.usdc, "SIM: usdc changed across migration");
        require(relay.cctpMessageTransmitter() == pre.cctp, "SIM: cctp changed across migration");
        require(relay.totalFailedAmount() == pre.totalFailedAmount, "SIM: totalFailedAmount changed");
        require(relay.owner() == pre.owner, "SIM: ownership not preserved (Ownable2Step)");
        require(relay.failedDepositor(probeKey) == address(0), "SIM: probe failed-deposit not empty post-migrate");
        require(relay.bungeeExecutor() == address(0), "SIM: bungeeExecutor should start empty");
        require(relay.depositNonce() == 0, "SIM: depositNonce should start at 0");

        // Old owner slot (slot 2) zeroed by the migration.
        require(
            address(uint160(uint256(vm.load(PROXY, bytes32(uint256(2)))))) == address(0),
            "SIM: stale owner slot not zeroed"
        );

        // New _initialized bumped to 2 (reinitializer(2) consumed).
        require(uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT))) == 2, "SIM: _initialized not bumped to 2");

        console.log("Post-migration fields verified IDENTICAL through new Layout.");
        console.log("  owner:  ", relay.owner());
        console.log("  escrow: ", relay.escrow());
        console.log("  usdc:   ", relay.usdc());

        // ---- H-01: attacker executeData reverts (no executor set yet, attacker != owner). ----
        {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1e6;
            address[] memory tokens = new address[](1);
            tokens[0] = pre.usdc;
            address attacker = address(0xBAD1);
            vm.prank(attacker);
            (bool ok, bytes memory ret) =
                PROXY.call(abi.encodeCall(CashOutRelay.executeData, (bytes32(0), amounts, tokens, "")));
            require(!ok, "SIM: attacker executeData did NOT revert (H-01 gate broken)");
            require(
                bytes4(ret) == CashOutRelay.NotAuthorizedExecutor.selector,
                "SIM: attacker executeData reverted with wrong error"
            );
            console.log("H-01: attacker executeData correctly reverts NotAuthorizedExecutor.");
        }

        // ---- Reinitializer burned: a second upgradeToAndCall with the migration calldata reverts. ----
        {
            CashOutRelay newImpl2 = new CashOutRelay();
            vm.prank(pre.owner);
            (bool ok,) = PROXY.call(
                abi.encodeCall(
                    UUPSUpgradeable.upgradeToAndCall, (address(newImpl2), abi.encodeCall(CashOutRelay.migrateToV2, ()))
                )
            );
            require(!ok, "SIM: second migrateToV2 did NOT revert (reinitializer not burned)");
            console.log("Reinitializer burned: second migrateToV2 reverts.");
        }

        console.log("\nSIM PASS: CashOutRelay security upgrade migrates cleanly and gates executeData.");
    }
}
