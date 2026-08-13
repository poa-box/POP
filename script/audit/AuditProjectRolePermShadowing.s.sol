// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";

/*
 * ============================================================================
 * Audit: per-project ROLE_PERM overrides that SHADOW a global mask
 * ============================================================================
 *
 * TaskManager merges a hat's global and per-project permission masks with
 * REPLACE (not union) semantics: `_permMask` does
 *
 *     m |= (projectMask == 0 ? rolePermGlobal[hat] : projectMask);
 *
 * so ANY non-zero per-project override for a hat FULLY REPLACES that hat's
 * global mask on that project — the global bits are silently dropped there.
 * (This is the `taskmanager-project-override-shadows-global` footgun that has
 * already bitten Test6 and Decentral Park v5.)
 *
 * This script is READ-ONLY (no broadcast). It enumerates, for a set of live
 * TaskManager proxies, every (project, role-hat) pair where a project override
 * exists while the hat also carries a global mask, and prints whether the
 * override is a strict SHADOW (drops global bits the override does not carry).
 * It informs migration to RoleManager-driven role wiring; it mutates nothing.
 *
 * Inputs (env vars):
 *   TASKMANAGER   comma-separated TaskManager proxy addresses (required)
 *   ROLE_HATS     comma-separated role hat IDs (uint256) to inspect. Optional —
 *                 if omitted, the script falls back to the proxy's on-chain
 *                 `permissionHatIds` enumeration (lens key 6).
 *   PROJECT_IDS   comma-separated project ids (bytes32) to inspect (required)
 *
 * The same ROLE_HATS / PROJECT_IDS lists are applied to every TASKMANAGER in
 * the list, so pass one org's TaskManager per run when the hat/project sets
 * differ across orgs.
 *
 * Usage:
 *   TASKMANAGER=0xabc... \
 *   ROLE_HATS=123,456 \
 *   PROJECT_IDS=0x11..,0x22.. \
 *   forge script script/audit/AuditProjectRolePermShadowing.s.sol:Audit --rpc-url gnosis
 * ============================================================================
 */
contract Audit is Script {
    /// @dev ERC-7201 base slot for TaskManager.Layout.
    bytes32 constant TM_STORAGE_SLOT = keccak256("poa.taskmanager.storage");
    /// @dev Field offset of `rolePermGlobal` within Layout (mapping(uint256 => uint8)).
    ///      Verified against src/TaskManager.sol Layout ordering (slots 0-5 precede it).
    uint256 constant ROLE_PERM_GLOBAL_OFFSET = 6;
    /// @dev Field offset of `rolePermProj` (mapping(bytes32 => mapping(uint256 => uint8))).
    uint256 constant ROLE_PERM_PROJ_OFFSET = 7;

    function run() public {
        address[] memory tms = vm.envAddress("TASKMANAGER", ",");
        bytes32[] memory projectIds = vm.envBytes32("PROJECT_IDS", ",");

        // ROLE_HATS is optional; empty array signals "use on-chain permissionHatIds".
        uint256[] memory roleHats;
        try vm.envUint("ROLE_HATS", ",") returns (uint256[] memory hats) {
            roleHats = hats;
        } catch {
            roleHats = new uint256[](0);
        }

        console.log("=== Project ROLE_PERM shadowing audit ===");
        console.log("TaskManagers:", tms.length);
        console.log("Projects    :", projectIds.length);

        uint256 grandTotalShadows;
        for (uint256 t; t < tms.length; ++t) {
            grandTotalShadows += _auditTaskManager(tms[t], roleHats, projectIds);
        }

        console.log("\n=== Summary ===");
        console.log("Total shadowing overrides found:", grandTotalShadows);
        if (grandTotalShadows == 0) {
            console.log("CLEAN: no per-project override shadows a global mask for the given hats/projects.");
        } else {
            console.log("REVIEW: each SHADOW line lists a project override that drops global permission bits.");
            console.log("Migration note: re-issue the intended union as an explicit per-project mask.");
        }
    }

    function _auditTaskManager(address proxy, uint256[] memory roleHats, bytes32[] memory projectIds)
        internal
        returns (uint256 shadowsForTm)
    {
        console.log("\n--- TaskManager", proxy, "---");
        if (proxy.code.length == 0) {
            console.log("  no code at proxy, skipping");
            return 0;
        }

        uint256[] memory hats = roleHats;
        if (hats.length == 0) {
            hats = _permissionHatIds(proxy);
            console.log("  ROLE_HATS not provided; using on-chain permissionHatIds:", hats.length);
        }

        bytes32 globalBase = bytes32(uint256(TM_STORAGE_SLOT) + ROLE_PERM_GLOBAL_OFFSET);
        bytes32 projBase = bytes32(uint256(TM_STORAGE_SLOT) + ROLE_PERM_PROJ_OFFSET);

        for (uint256 p; p < projectIds.length; ++p) {
            bytes32 pid = projectIds[p];
            // Inner mapping slot: rolePermProj[pid] => keccak(pid, projBase).
            bytes32 innerBase = keccak256(abi.encode(pid, projBase));

            for (uint256 h; h < hats.length; ++h) {
                uint256 hatId = hats[h];
                uint8 globalMask = uint8(uint256(vm.load(proxy, keccak256(abi.encode(hatId, globalBase)))));
                uint8 projMask = uint8(uint256(vm.load(proxy, keccak256(abi.encode(hatId, innerBase)))));

                // A shadow only occurs when a project override exists (non-zero) AND the hat
                // has a global mask: the override REPLACES the global, so any global bit not
                // also present in the override is silently dropped on this project.
                if (projMask != 0 && globalMask != 0) {
                    uint8 dropped = globalMask & ~projMask;
                    if (dropped != 0) {
                        shadowsForTm++;
                        console.log("  SHADOW project", vm.toString(pid));
                        console.log("    hatId        =", hatId);
                        console.log("    globalMask   =", globalMask);
                        console.log("    projectMask  =", projMask);
                        console.log("    droppedBits  =", dropped);
                    } else {
                        console.log("  ok project", vm.toString(pid));
                        console.log("    hatId (override superset of global) =", hatId);
                    }
                }
            }
        }

        if (shadowsForTm == 0) {
            console.log("  no shadows for this TaskManager");
        }
    }

    /// @dev Reads the proxy's `permissionHatIds` enumeration via lens key 6 (getLensData).
    function _permissionHatIds(address proxy) internal view returns (uint256[] memory hatIds) {
        try TaskManager(proxy).getLensData(6, "") returns (bytes memory raw) {
            hatIds = abi.decode(raw, (uint256[]));
        } catch {
            hatIds = new uint256[](0);
        }
    }
}
