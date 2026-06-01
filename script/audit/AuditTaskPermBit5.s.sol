// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";

/*
 * ============================================================================
 * Audit: TaskPerm bit 5 collisions before v4 broadcast
 * ============================================================================
 *
 * TaskManager v4 introduces `TaskPerm.BUDGET = 1 << 5` (bit 5). Pre-v4, bit 5
 * was unused, but `setConfig(ROLE_PERM, abi.encode(hatId, mask))` accepts
 * `uint8` verbatim. If any existing hat in any live org was historically
 * granted a mask with bit 5 set (e.g. someone passed `0xFF` thinking only
 * bits 0–4 mattered), that hat silently gains BUDGET permission post-upgrade.
 *
 * Scope:
 *   - This script audits the GLOBAL `rolePermGlobal` mapping per org. There
 *     is no public getter for that mapping (it's nested in the ERC-7201
 *     Layout), so we read it via `vm.load` on the ERC-7201 storage slot.
 *   - Per-project `rolePermProj` audits are NOT in this script — the
 *     subgraph already indexes `ProjectRolePermSet` and exposes
 *     `ProjectRolePermission.mask` on every chain. Run this GraphQL query
 *     against the live subgraph:
 *
 *       { projectRolePermissions(first: 1000, where: { mask_gte: 32 }) {
 *           id hatId mask
 *           project { id taskManager { id organization { id name } } }
 *       } }
 *
 *     mask >= 32 means bit 5+ is set somewhere. Pre-v4, valid masks were in
 *     [0, 31], so any hit is an unintentional pre-existing bit-5 grant.
 *
 * Usage (read-only — no broadcast):
 *   forge script script/audit/AuditTaskPermBit5.s.sol:AuditGnosis --rpc-url gnosis
 *   forge script script/audit/AuditTaskPermBit5.s.sol:AuditArbitrum --rpc-url arbitrum
 *
 * Output: per-org line for every (hatId, mask) where mask & 0x20 != 0.
 *   "COLLISION" prefix => bit 5 is set; this hat unexpectedly gets BUDGET.
 *   "CLEAN" prefix     => no global collisions on that org.
 * ============================================================================
 */

interface IOrgRegistry {
    function orgIds(uint256 index) external view returns (bytes32);
    function proxyOf(bytes32 orgId, bytes32 typeId) external view returns (address);
}

abstract contract AuditBase is Script {
    bytes32 constant TM_STORAGE_SLOT = keccak256("poa.taskmanager.storage");
    /// @dev Index of `rolePermGlobal` in TaskManager.Layout. Verified by inspecting
    ///      Layout in src/TaskManager.sol (slot 0–5 are _projects, _tasks, hats,
    ///      token, creatorHatIds, packed[nextTaskId|nextProjectId|executor]).
    uint256 constant ROLE_PERM_GLOBAL_OFFSET = 6;

    address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

    function _auditOrg(string memory chainName, bytes32 orgId, address proxy) internal returns (uint256 hitsForOrg) {
        if (proxy.code.length == 0) {
            console.log("[%s] orgId=%s: no TaskManager proxy, skipping", chainName, vm.toString(orgId));
            return 0;
        }
        TaskManager tm = TaskManager(proxy);

        // Lens key 6 = permissionHatIds — every hat that's been granted ANY perm bit.
        uint256[] memory hatIds;
        try tm.getLensData(6, "") returns (bytes memory raw) {
            hatIds = abi.decode(raw, (uint256[]));
        } catch {
            console.log(
                "[%s] orgId=%s: lens key 6 unavailable on proxy %s - skipping", chainName, vm.toString(orgId), proxy
            );
            return 0;
        }

        bytes32 rolePermGlobalBase = bytes32(uint256(TM_STORAGE_SLOT) + ROLE_PERM_GLOBAL_OFFSET);
        for (uint256 i; i < hatIds.length; ++i) {
            uint256 hatId = hatIds[i];
            bytes32 slot = keccak256(abi.encode(hatId, rolePermGlobalBase));
            uint8 mask = uint8(uint256(vm.load(proxy, slot)));
            if (mask & 0x20 != 0) {
                hitsForOrg++;
                console.log("COLLISION", chainName, vm.toString(orgId));
                console.log("  proxy   =", proxy);
                console.log("  hatId   =", hatId);
                console.log("  mask    =", mask);
            }
        }

        if (hitsForOrg == 0) {
            console.log("CLEAN [%s] orgId=%s (%d hats checked)", chainName, vm.toString(orgId), hatIds.length);
        }
    }

    function _runAudit(string memory chainName) internal {
        console.log("\n=== TaskPerm bit-5 audit on %s ===\n", chainName);
        IOrgRegistry reg = IOrgRegistry(ORG_REGISTRY);

        uint256 totalHits;
        uint256 orgsChecked;
        for (uint256 i; i < 64; ++i) {
            bytes32 orgId;
            try reg.orgIds(i) returns (bytes32 id) {
                orgId = id;
            } catch {
                break;
            }
            if (orgId == bytes32(0)) break;
            address proxy = reg.proxyOf(orgId, keccak256("TaskManager"));
            totalHits += _auditOrg(chainName, orgId, proxy);
            orgsChecked++;
        }

        console.log("\n--- %s summary ---", chainName);
        console.log("Orgs checked:", orgsChecked);
        console.log("Global rolePermGlobal collisions:", totalHits);
        if (totalHits == 0) {
            console.log("PASS: no pre-existing global bit-5 grants. Safe to broadcast v4.");
        } else {
            console.log("REVIEW: each COLLISION line shows a hat that gains BUDGET post-v4.");
            console.log("Decide per case: revoke pre-broadcast, or accept the new permission.");
        }
        console.log("\nReminder: for PER-PROJECT collisions, query the subgraph. See script header.");
    }
}

contract AuditGnosis is AuditBase {
    function run() public {
        _runAudit("gnosis");
    }
}

contract AuditArbitrum is AuditBase {
    function run() public {
        _runAudit("arbitrum");
    }
}

/// @dev Direct-proxy fallback for chains where OrgRegistry enumeration isn't
/// available via `orgIds(uint256)` (Arbitrum's registry uses a different
/// interface). Audits Poa's TaskManager directly. Add other proxies to the
/// `proxies` array as new orgs deploy.
contract AuditArbitrumDirect is AuditBase {
    function run() public {
        console.log("\n=== TaskPerm bit-5 audit on arbitrum (direct proxies) ===\n");

        address[1] memory proxies = [
            // Poa governance org
            0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0
        ];
        bytes32[1] memory orgIds = [bytes32(0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069)];

        uint256 totalHits;
        for (uint256 i; i < proxies.length; ++i) {
            totalHits += _auditOrg("arbitrum", orgIds[i], proxies[i]);
        }

        console.log("\n--- arbitrum summary ---");
        console.log("Orgs checked:", proxies.length);
        console.log("Global rolePermGlobal collisions:", totalHits);
        if (totalHits == 0) {
            console.log("PASS: no pre-existing global bit-5 grants. Safe to broadcast v4.");
        } else {
            console.log("REVIEW: each COLLISION line shows a hat that gains BUDGET post-v4.");
        }
        console.log("\nReminder: for PER-PROJECT collisions, query the subgraph. See script header.");
    }
}
