// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IEntryPoint} from "../interfaces/IEntryPoint.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {PaymasterHubErrors} from "./PaymasterHubErrors.sol";

/// @title PaymasterAdminLib
/// @author POA Engineering
/// @notice Delegatecall library holding PaymasterHub's withdraw paths (M-04), the
///         solidarity reservation reconciliation helper (M-05), and the protocolAdmin
///         setter (M-10). These live in a separately-deployed library and are invoked
///         via `delegatecall` from PaymasterHub so they do NOT inflate the hub's runtime
///         bytecode — PaymasterHub is at the EIP-170 edge (24,464 B at optimizer_runs=1).
/// @dev External functions in a Solidity `library` are delegatecalled by the caller, so
///      `msg.sender` / `msg.value` are preserved and all storage reads/writes hit the
///      HUB's ERC-7201 namespaced slots. The slot constants and struct layouts below MUST
///      stay byte-for-byte in sync with PaymasterHub.
library PaymasterAdminLib {
    // ── ERC-7201 storage locations (must match PaymasterHub exactly) ──
    bytes32 private constant MAIN_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.main")) - 1));
    bytes32 private constant ORGS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.orgs")) - 1));
    bytes32 private constant FINANCIALS_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.financials")) - 1));
    bytes32 private constant SOLIDARITY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("poa.paymasterhub.solidarity")) - 1));

    // ── Storage structs (must match PaymasterHub exactly) ──
    struct MainStorage {
        address entryPoint;
        address hats;
        address poaManager;
        address orgRegistrar;
        address protocolAdmin;
    }

    struct OrgConfig {
        uint256 adminHatId;
        uint256 operatorHatId;
        bool paused;
        uint40 registeredAt;
        bool bannedFromSolidarity;
    }

    struct OrgFinancials {
        uint128 deposited;
        uint128 spent;
        uint128 solidarityUsedThisPeriod;
        uint32 periodStart;
    }

    struct SolidarityFund {
        uint128 balance;
        uint32 numActiveOrgs;
        uint16 feePercentageBps;
        bool distributionPaused;
    }

    // ── Events (re-declared so they emit from the hub's context) ──
    event OrgDepositWithdrawn(bytes32 indexed orgId, address indexed to, uint256 amount);
    event SolidarityWithdrawn(address indexed to, uint256 amount);
    event ProtocolAdminSet(address indexed previousAdmin, address indexed newAdmin);

    // ─────────────────────────────────────────────────────────────────────────
    // M-04 — Withdraw paths
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Withdraw an org's unspent deposit back out of the EntryPoint (M-04).
    /// @dev Org-admin gated. Bounded by `deposited - spent`. Reduces `deposited` and
    ///      `deposited`-tracked solidarity accounting stays consistent because withdrawing
    ///      only touches the org's own funds. Callers wrap this in `nonReentrant`; state is
    ///      updated before the EntryPoint call (checks-effects-interactions).
    /// @param orgId The organization whose deposit is being withdrawn.
    /// @param to Recipient of the withdrawn ETH (must be non-zero).
    /// @param amount Amount to withdraw; must be <= (deposited - spent).
    function withdrawOrgDeposit(bytes32 orgId, address payable to, uint256 amount) external {
        if (to == address(0)) revert PaymasterHubErrors.ZeroAddress();
        if (amount == 0) revert PaymasterHubErrors.ZeroAmount();

        OrgConfig storage org = _orgs()[orgId];
        if (org.adminHatId == 0) revert PaymasterHubErrors.OrgNotRegistered();
        if (!IHats(_main().hats).isWearerOfHat(msg.sender, org.adminHatId)) {
            revert PaymasterHubErrors.NotAdmin();
        }

        OrgFinancials storage fin = _financials()[orgId];
        uint256 available =
            uint256(fin.deposited) > uint256(fin.spent) ? uint256(fin.deposited) - uint256(fin.spent) : 0;
        if (amount > available) revert PaymasterHubErrors.InsufficientOrgBalance();

        // Effect: reduce the org's tracked deposit before the external call.
        fin.deposited -= uint128(amount);

        // Interaction: pull the ETH out of the EntryPoint to the recipient.
        IEntryPoint(_main().entryPoint).withdrawTo(to, amount);

        emit OrgDepositWithdrawn(orgId, to, amount);
    }

    /// @notice Emergency/solidarity withdraw from the EntryPoint deposit (M-04).
    /// @dev PoaManager-gated. Bounded by the solidarity fund balance so it can never pull
    ///      out ETH that belongs to an org's tracked deposit. Intended for fund migration
    ///      or emergency rescue; a future governance upgrade can re-gate this.
    /// @param to Recipient of the withdrawn ETH (must be non-zero).
    /// @param amount Amount to withdraw; must be <= solidarity.balance.
    function withdrawSolidarity(address payable to, uint256 amount) external {
        if (to == address(0)) revert PaymasterHubErrors.ZeroAddress();
        if (amount == 0) revert PaymasterHubErrors.ZeroAmount();
        if (msg.sender != _main().poaManager) revert PaymasterHubErrors.NotPoaManager();

        SolidarityFund storage sol = _solidarity();
        if (amount > uint256(sol.balance)) revert PaymasterHubErrors.InsufficientFunds();

        // Effect before interaction.
        sol.balance -= uint128(amount);

        IEntryPoint(_main().entryPoint).withdrawTo(to, amount);

        emit SolidarityWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // M-10 — protocolAdmin setter (replaces unauthenticated reinitializeProtocolAdmin)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the protocol-level admin, gated to the PoaManager (M-10).
    /// @dev Replaces the unauthenticated `reinitializeProtocolAdmin(address)` reinitializer,
    ///      which any address could front-run once a new impl was live but unconsumed. This
    ///      is an ordinary poaManager-gated setter with no reinitializer, so it can be
    ///      re-run and cannot be seized.
    /// @param newAdmin The new protocolAdmin (may be zero to disable the protocol-admin path).
    function setProtocolAdmin(address newAdmin) external {
        MainStorage storage m = _main();
        if (msg.sender != m.poaManager) revert PaymasterHubErrors.NotPoaManager();
        address prev = m.protocolAdmin;
        m.protocolAdmin = newAdmin;
        emit ProtocolAdminSet(prev, newAdmin);
    }

    // ── Storage accessors (mirror PaymasterHub's private getters) ──
    function _main() private pure returns (MainStorage storage $) {
        bytes32 slot = MAIN_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _orgs() private pure returns (mapping(bytes32 => OrgConfig) storage $) {
        bytes32 slot = ORGS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _financials() private pure returns (mapping(bytes32 => OrgFinancials) storage $) {
        bytes32 slot = FINANCIALS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function _solidarity() private pure returns (SolidarityFund storage $) {
        bytes32 slot = SOLIDARITY_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }
}
