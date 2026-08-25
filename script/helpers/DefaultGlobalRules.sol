// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";

/**
 * @title DefaultGlobalRules
 * @notice Canonical seed set for the PaymasterHub GLOBAL RULEBOOK — every sponsored
 *         (module typeId, selector) pair, with gas hints where relevant.
 * @dev This is the single source of truth that replaced OrgDeployer._buildDefaultPaymasterRules
 *      (which hardcoded per-org addresses and required an OrgDeployer redeploy per new function).
 *      Used by the rulebook seeding scripts and by tests. INTERNAL library: it compiles into
 *      scripts/tests only and is never deployed on-chain, so growing this list has no runtime
 *      bytecode cost anywhere.
 *
 *      NOTE: the four ZkEmailInvites signatures fix a LATENT BUG inherited from the old
 *      OrgDeployer list — its strings used `string` where the real proof tuple has `bytes32`
 *      (domain hash), so the deploy-time zkemail rules matched no real function. Entries here
 *      are cross-checked against compiler-derived contract selectors by
 *      testDefaultGlobalRules_MatchRealContractSelectors.
 *
 *      To sponsor a new/changed function protocol-wide: add the entry here, then broadcast
 *      `PaymasterHub.setGlobalRulesBatch` with the delta (or the full set — upserts are
 *      idempotent). Every Mirror-mode org picks it up instantly; Static-mode orgs vote via
 *      `adoptGlobalRules` / `snapshotGlobalRules` / `setRule`.
 */
library DefaultGlobalRules {
    struct Entry {
        bytes32 typeId;
        bytes4 selector;
        uint32 maxCallGasHint;
    }

    /// @notice The full default rulebook as parallel arrays, ready for setGlobalRulesBatch.
    function defaults()
        internal
        pure
        returns (bytes32[] memory typeIds, bytes4[] memory selectors, bool[] memory allowed, uint32[] memory hints)
    {
        Entry[] memory e = entries();
        uint256 n = e.length;
        typeIds = new bytes32[](n);
        selectors = new bytes4[](n);
        allowed = new bool[](n);
        hints = new uint32[](n);
        for (uint256 i = 0; i < n; i++) {
            typeIds[i] = e[i].typeId;
            selectors[i] = e[i].selector;
            allowed[i] = true;
            hints[i] = e[i].maxCallGasHint;
        }
    }

    /// @notice All default rulebook entries (selector strings match the deployed module ABIs).
    function entries() internal pure returns (Entry[] memory e) {
        e = new Entry[](67);
        uint256 i;

        // ── QuickJoin (6) ──
        bytes32 t = ModuleTypes.QUICK_JOIN_ID;
        e[i++] = Entry(t, bytes4(keccak256("quickJoinWithUser()")), 0);
        e[i++] = Entry(t, bytes4(keccak256("registerAndQuickJoin(address,string,uint256,uint256,bytes)")), 0);
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "registerAndQuickJoinWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32))"
                )
            ),
            0
        );
        e[i++] = Entry(t, bytes4(keccak256("claimHatsWithUser(uint256[])")), 0);
        e[i++] = Entry(t, bytes4(keccak256("registerAndClaimHats(address,string,uint256,uint256,bytes,uint256[])")), 0);
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "registerAndClaimHatsWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),uint256[])"
                )
            ),
            0
        );

        // ── TaskManager (17) — v6 create/update carry deadline params; v7 adds unclaimTask ──
        t = ModuleTypes.TASK_MANAGER_ID;
        e[i++] = Entry(
            t, bytes4(keccak256("createTask(uint256,bytes,bytes32,bytes32,address,uint256,bool,uint48,uint32)")), 0
        );
        e[i++] = Entry(
            t,
            bytes4(keccak256("createTasksBatch(bytes32,(uint256,bytes,bytes32,address,uint256,bool,uint48,uint32)[])")),
            0
        );
        e[i++] = Entry(t, bytes4(keccak256("claimTask(uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("unclaimTask(uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("submitTask(uint256,bytes32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("completeTask(uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("applyForTask(uint256,bytes32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("approveApplication(uint256,address)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("assignTask(uint256,address)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("rejectTask(uint256,bytes32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("cancelTask(uint256)")), 0);
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "createAndAssignTask(uint256,bytes,bytes32,bytes32,address,address,uint256,bool,uint48,uint32)"
                )
            ),
            0
        );
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "createProject((bytes,bytes32,uint256,address[],uint256[],uint256[],uint256[],uint256[],address[],uint256[]))"
                )
            ),
            0
        );
        e[i++] = Entry(t, bytes4(keccak256("deleteProject(bytes32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("setFolders(bytes32,bytes32)")), 0);
        e[i++] =
            Entry(t, bytes4(keccak256("updateTask(uint256,uint256,bytes,bytes32,address,uint256,uint48,uint32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("updateTaskMetadata(uint256,bytes,bytes32)")), 0);

        // ── HybridVoting (4) + DirectDemocracyVoting (4) ──
        bytes4 voteSel = bytes4(keccak256("vote(uint256,uint8[],uint8[])"));
        bytes4 announceSel = bytes4(keccak256("announceWinner(uint256)"));
        bytes4 proposalSel =
            bytes4(keccak256("createProposal(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[])"));
        // V2 signatures differ per contract: DD carries quorumOverride, HV adds equalWeight — both
        // must be sponsored or passkey users lose gasless restricted-poll creation.
        bytes4 proposalV2DDSel = bytes4(
            keccak256("createProposalV2(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[],uint32)")
        );
        bytes4 proposalV2HVSel = bytes4(
            keccak256("createProposalV2(bytes,bytes32,uint32,uint8,(address,uint256,bytes)[][],uint256[],uint32,bool)")
        );
        e[i++] = Entry(ModuleTypes.HYBRID_VOTING_ID, voteSel, 0);
        e[i++] = Entry(ModuleTypes.HYBRID_VOTING_ID, announceSel, 0);
        e[i++] = Entry(ModuleTypes.HYBRID_VOTING_ID, proposalSel, 0);
        e[i++] = Entry(ModuleTypes.HYBRID_VOTING_ID, proposalV2HVSel, 0);
        e[i++] = Entry(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, voteSel, 0);
        e[i++] = Entry(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, announceSel, 0);
        e[i++] = Entry(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, proposalSel, 0);
        e[i++] = Entry(ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, proposalV2DDSel, 0);

        // ── PaymentManager (5) ──
        t = ModuleTypes.PAYMENT_MANAGER_ID;
        e[i++] = Entry(t, bytes4(keccak256("claimDistribution(uint256,uint256,bytes32[])")), 0);
        e[i++] = Entry(t, bytes4(keccak256("claimMultiple(uint256[],uint256[],bytes32[][])")), 0);
        e[i++] = Entry(t, bytes4(keccak256("optOut(bool)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("createDistribution(address,uint256,bytes32,uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("finalizeDistribution(uint256,uint256)")), 0);

        // ── EligibilityModule (8) — vouch + role-application + kick paths ──
        // Retained for the orgs still on the legacy access rails; new orgs deploy no EligibilityModule.
        // `claimHat` / `claimHats` are NOT here: no chain ever had a targetTypes row mapping them, so
        // they were never reachable through the rulebook, and Access v2 replaces them with
        // MembershipAuthority.claim below.
        t = ModuleTypes.ELIGIBILITY_MODULE_ID;
        e[i++] = Entry(t, bytes4(keccak256("claimVouchedHat(uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("vouchFor(address,uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("revokeVouch(address,uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("applyForRole(uint256,bytes32)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("withdrawApplication(uint256)")), 0);
        // Delegated-kick lifecycle (kicker-hat wearers). kickWearer covers rule write + provenance +
        // burn; finalizeKick applies a delayed kick; unkickWearer is a rule restore only.
        e[i++] = Entry(t, bytes4(keccak256("kickWearer(address,uint256)")), 400_000);
        e[i++] = Entry(t, bytes4(keccak256("finalizeKick(address,uint256)")), 400_000);
        e[i++] = Entry(t, bytes4(keccak256("unkickWearer(address,uint256)")), 200_000);

        // ── ParticipationToken (3) ──
        t = ModuleTypes.PARTICIPATION_TOKEN_ID;
        e[i++] = Entry(t, bytes4(keccak256("requestTokens(uint96,string)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("approveRequest(uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("cancelRequest(uint256)")), 0);

        // ── Shared registries (2) — setProfileMetadata on UniversalAccountRegistry,
        //    updateOrgMetaAsAdmin on OrgRegistry (two distinct contracts, L-53) ──
        e[i++] = Entry(ModuleTypes.UNIVERSAL_ACCOUNT_REGISTRY_ID, bytes4(keccak256("setProfileMetadata(bytes32)")), 0);
        e[i++] = Entry(ModuleTypes.ORG_REGISTRY_ID, bytes4(keccak256("updateOrgMetaAsAdmin(bytes32,bytes,bytes32)")), 0);

        // ── EducationHub (4) ──
        t = ModuleTypes.EDUCATION_HUB_ID;
        e[i++] = Entry(t, bytes4(keccak256("completeModule(uint256,uint8)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("createModule(bytes,bytes32,uint256,uint8)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("updateModule(uint256,bytes,bytes32,uint256)")), 0);
        e[i++] = Entry(t, bytes4(keccak256("removeModule(uint256)")), 0);

        // ── ZkEmailInvites (4) — Groth16 verify + DKIM + merkle + hat mint gas hints ──
        t = ModuleTypes.ZKEMAIL_INVITES_ID;
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "claimRoleByDomain((uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,bytes32),address,uint256[],bytes32[])"
                )
            ),
            800_000
        );
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "claimRoleByEmail((uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,bytes32,bytes32),address,uint256[],bytes32[])"
                )
            ),
            800_000
        );
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "registerAndClaimByDomainWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,bytes32),uint256[],bytes32[])"
                )
            ),
            1_200_000
        );
        e[i++] = Entry(
            t,
            bytes4(
                keccak256(
                    "registerAndClaimByEmailWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,bytes32,bytes32),uint256[],bytes32[])"
                )
            ),
            1_200_000
        );

        // ── MembershipAuthority (10) — Access-v2 user-facing + delegated lifecycle selectors ──
        // Keyed under MEMBERSHIP_AUTHORITY_ID so every org's authority resolves the same type-keyed
        // whitelist (Mirror mode). The EXECUTOR path is never sponsored (governance batches carry
        // their own gas), so only USER-initiated and MANAGER-DELEGATE-initiated calls appear here.
        // INCLUSIONS / EXCLUSIONS (documented per §6):
        //   INCLUDED — user self-service: claim (self-claim / offer-accept — a single role-token mint
        //     + eligibility fold, ~claimHat), renounce (clear accepted + burn); vouch / revokeVouch
        //     (attestor runtime, member-initiated — mirrors EM vouchFor/revokeVouch, hint 0 like v1).
        //   INCLUDED — manager-delegate lifecycle: delegatedGrant / delegatedOffer / delegatedRemove
        //     (create a pending action, manager-hat wearers), delegatedUnremove (rule-restore only,
        //     ~unkickWearer), finalize (applies the delayed grant/remove — the heavy verb: rule write
        //     + membership flip + mint/burn), cancel (delete a pending action).
        //   EXCLUDED — every onlyExecutor write (grant/offer/remove/setRule/config/seed/setPaused/…):
        //     governance-only, never passkey-sponsored (executor batches fund their own gas).
        //   EXCLUDED — reconcile (permissionless keeper repair): DELIBERATE spec §6 step-0 item-4
        //     DEVIATION (orchestrator ruling R3). §6 lists reconcile among the sponsored selectors, but
        //     a permissionless, gas-free reconcile is a grief-spam vector (any address can burn org
        //     solidarity-fund gas repeatedly). Rationale: not a member-facing gasless flow; left
        //     unsponsored like v1's absence of a sponsored reconcile path. Recorded here + in
        //     MIGRATION-RUNBOOK.md (Orchestrator rulings) as the accepted deviation from the binding
        //     spec text; §8's permissionless-reconcile repair still works, just self-funded.
        // Gas hints mirror the legacy delegation-selector calibration (single-subject, bounded writes):
        t = ModuleTypes.MEMBERSHIP_AUTHORITY_ID;
        e[i++] = Entry(t, bytes4(keccak256("claim(uint256)")), 300_000); // single mint + fold (~claimHat)
        e[i++] = Entry(t, bytes4(keccak256("renounce(uint256)")), 200_000); // clear accepted + burn + rule clear
        e[i++] = Entry(t, bytes4(keccak256("vouch(uint256,address)")), 0); // attestor write (mirrors EM vouchFor)
        e[i++] = Entry(t, bytes4(keccak256("revokeVouch(uint256,address)")), 200_000); // may drop <quorum → reconcile burn
        e[i++] = Entry(t, bytes4(keccak256("delegatedGrant(uint256,address)")), 250_000); // create pending grant
        e[i++] = Entry(t, bytes4(keccak256("delegatedOffer(uint256,address)")), 300_000); // pending + immediate rule + RoleOffered
        e[i++] = Entry(t, bytes4(keccak256("delegatedRemove(uint256,address,bool)")), 250_000); // create pending remove
        e[i++] = Entry(t, bytes4(keccak256("delegatedUnremove(uint256,address)")), 200_000); // rule-restore only (~unkickWearer)
        e[i++] = Entry(t, bytes4(keccak256("finalize(uint256)")), 600_000); // applies delayed grant/remove (heavy verb)
        e[i++] = Entry(t, bytes4(keccak256("cancel(uint256)")), 200_000); // delete a pending action

        assert(i == e.length);
    }
}
