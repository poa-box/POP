// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @title AccessV2Types — shared enums/structs referenced by IMembershipAuthority + IAuthorityRouter.
/// @notice A standalone types unit keeps the router, the authority, and the modules on ONE declaration
///         of each type (the v1 lesson: RoleManagerLogic shared IEligibilityModuleRM so the lib and the
///         contract never diverged).
library AccessV2Types {
    /// @notice Subject taxonomy (§1). ROLE has acceptance + maxMembers + memberCount; GROUP is a
    ///         pure derivation over member-roles (no acceptance, no maxMembers, supply=0).
    enum SubjectKind {
        Role, // 0
        Group // 1
    }

    /// @notice Explicit-rule verb (§2). Exactly ONE rule slot per (subject,user); the slot IS the
    ///         rule — no ALLOW/DENY coexistence, no partial (false,true) shapes.
    enum RuleKind {
        None, // 0 — no explicit rule present (ABSTAIN at the explicit tier)
        Grant, // 1 — explicit ALLOW
        Ban // 2 — explicit DENY (supremacy over attestor-ALLOW)
    }

    /// @notice Rule provenance (§2). Governance writes overwrite ANY rule; delegated writes are
    ///         provenance-guarded (may only clear delegate-authored rules or delegable governance ones).
    enum RuleAuthor {
        Governance, // 0 — executor/vote authored
        Delegated // 1 — authored by a manager-subject delegate
    }

    /// @notice Delegated lifecycle action (§4). ONE pending-action model over all three.
    enum PendingKind {
        Grant, // 0 — delegated grant to an in-org member (finalize())
        Offer, // 1 — delegated offer to an out-of-org user (claim() is the finalize)
        Remove // 2 — delegated soft/hard removal (finalize())
    }

    /// @notice Eligibility fold verdict per source (§2 tri-state resolver).
    enum Verdict {
        Abstain, // 0
        Allow, // 1
        Deny // 2
    }

    /// @notice Surviving eligibility source(s) reported by RemovalIneffective / canRemove (§4).
    ///         Returned as an enum-SET packed into a bitmask (`1 << uint8(source)`), so a member held
    ///         by multiple sources reports all of them.
    enum EligSource {
        DefaultAllow, // bit 0 — subject default is ALLOW ("open role — removing means banning")
        VouchQuorum, // bit 1 — vouch quorum still met
        EmailVerified, // bit 2 — live email verification
        StickyGovernanceGrant // bit 3 — delegable=false governance grant (only governance can clear)
    }

    /// @notice Preflight reason codes for canGrant / canRemove / canClaim (§4 error-channel views).
    ///         `Ok` (0) means the action would succeed.
    enum ActionReason {
        Ok, // 0 — action would succeed
        UnknownSubject, // 1
        NotInOrg, // 2 — grant target is out-of-org (would become an offer, not a grant)
        AlreadyMember, // 3
        NotMember, // 4
        SubjectFull, // 5 — role at maxMembers; preflights mirror the lapsedCandidate hint (ruling 6)
        BlockedByGovernanceBan, // 6 — delegated grant over a governance ban
        RemovalIneffective, // 7 — canRemove: target stays eligible (see EligSource set)
        NotYetActive, // 8 — canClaim before pending.activatesAt
        NoRuleToClaim, // 9 — canClaim with no explicit-ALLOW / offer present
        RenouncedClaimable, // 10 — canClaim on a sticky-grant seat held in reserve after renounce
        Paused // 11
    }

    /// @notice Config-time LINT codes (§2 lint set — orchestrator ruling 4). Lints are
    ///         NON-REVERTING: config writers emit `ConfigLint(subject, uint8(code))` and proceed.
    ///         Only WiringIncompatible-class conflicts hard-revert (see the error).
    enum LintCode {
        None, // 0 — never emitted
        QuorumNoOp, // 1 — default-ALLOW + vouch-attestor on the same subject (M-03 heir)
        VouchWithMaxMembers, // 2 — vouch-attestor + nonzero maxMembers (quorum-lapse ghosts vs cap)
        DefaultAllowStrongPerms, // 3 — default-ALLOW on a subject with voting/TM-mask/budget power (H-03 heir)
        GroupFanout, // 4 — perm key attached to many GROUP subjects (§3 composed cost)
        SelfVoucher // 5 — vouch config whose voucherSubject IS the subject (e.g. KUBI Execs-vouch-Execs);
        // LEGAL (a real live semantic), only the EMPTY-subject bootstrap deadlocks — recoverable
        // via a governance grant/seed exactly like legacy (C1 / ruling: relax the old revert to a lint)
    }

    /// @notice Genesis seed payload — ONE declaration shared by IMembershipAuthority.InitConfig and
    ///         the OrgDeployer/GovernanceFactory Q7 delta (§4.9): DeploymentParams appends exactly
    ///         this struct as ONE field (arrays-in-a-struct per the production stack-too-deep
    ///         history), and GovernanceFactory maps it 1:1 into InitConfig.
    /// @dev SUBJECT-REF CONVENTION (normative): everywhere this struct references a subject
    ///      (`groupMemberRoles`, `vouchSubjects`, `vouchVoucherSubjects`, `permSubjects`), a value
    ///      `< 2^64` is an INDEX into `subjectIds` (a subject created in the SAME call — its final
    ///      id is unknown pre-allocation for new orgs), and a value `>= 2^64` is a literal subject
    ///      id. Structurally unambiguous: every v2 id embeds a nonzero address in bits 64–223 and
    ///      every legacy id is >= 2^224, so no real id is < 2^64.
    struct OrgAccessSeed {
        // subjects (index-aligned; admin/operator subjects MUST come first — lock-out guard, §6)
        uint256[] subjectIds; // adopted legacy ids OR 0 (0 => allocate a new v2 id)
        SubjectKind[] subjectKinds;
        string[] subjectNames;
        uint32[] subjectMaxMembers; // ROLE only; 0 = unlimited
        bool[] subjectDefaults; // per-subject default verdict (§2). QJ auto-claim roles =
        // default-ALLOW here + a QJ_AUTOJOIN perm row below (Q7 1:1 map)
        uint256[][] groupMemberRoles; // per subject: member-role refs (Group subjects only; else empty)
        // vouch-attestor rows (sparse; index-aligned among THEMSELVES)
        uint256[] vouchSubjects; // subject-ref
        uint32[] vouchQuorums;
        uint256[] vouchVoucherSubjects; // subject-ref (the config's membership subject)
        // perm-table rows (index-aligned among THEMSELVES)
        uint256[] permSubjects; // subject-ref
        bytes32[] permKeys;
        bytes32[] permCtxs;
        uint256[] permWords;
    }
}
