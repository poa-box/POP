// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IMembershipAuthority} from "../../src/interfaces/IMembershipAuthority.sol";
import {IAuthorityRouter} from "../../src/interfaces/IAuthorityRouter.sol";
import {AccessV2Types} from "../../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../../src/libs/AccessV2PermKeys.sol";
import {IExecutor} from "../../src/Executor.sol";

/*
 * ============================================================================
 * AccessV2MigrationBase — reusable per-org migration engine (Wave D2, SPEC §6)
 * ============================================================================
 *
 * The shared machinery behind MigrateOrgToAuthority (proposal-calldata generation)
 * and RehearseMigration (end-to-end fork rehearsal). Implements the §6 per-org
 * ceremony EXACTLY:
 *
 *   (a) PREDEPLOY (§6 step 1-2): deploy the org's MembershipAuthority BeaconProxy
 *       UNINITIALIZED, register it in OrgRegistry (register-before-initialize so the
 *       subgraph template precedes the init events), initialize it PAUSED, then SEED
 *       roles / defaults / perms / rules / memberships / vouch-state / email flags
 *       from the org's LIVE Hats + EligibilityModule + module perm-list state (adopting
 *       legacy hatIds VERBATIM as subject ids). The SEED INVARIANT (every seeded
 *       membership carries an eligibility source in the same batch) is hard-require()'d.
 *
 *   (b) CUTOVER BATCH (§6 step 3): the exact Executor.Call[] — router legacy-id BIND
 *       ordered BEFORE the eligibility toggle-off; setMembershipAuthority on all 8
 *       modules incl. Executor itself (the W6 self-target allowlist); unpause; legacy
 *       toggle-off + unported burns. announceWinner needs an explicit 3,000,000 gas
 *       limit (CLAUDE.md gotcha) — noted in every generated proposal JSON.
 *
 * SEED DATA SOURCING (§6 "enumerate wearers via event logs + fork reads"): the CANDIDATE
 * address set comes from tools/enumerate-wearers.sh (Executor.HatsMinted + QuickJoin
 * events, the real POP join path); this engine reads the FORK for each candidate's
 * authoritative current wearership / vouch / email state. ON-CHAIN fork state is the
 * source of truth — script/config/infrastructure.json is stale and never read.
 * ============================================================================
 */

/*──────────────────────── Minimal live-state read interfaces ────────────────────────*/

interface IHatsMin {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
    function isInGoodStanding(address wearer, uint256 hatId) external view returns (bool);
}

interface IEMMig {
    // getVouchConfig returns VouchConfig{uint32 quorum; uint256 membershipHatId; uint8 flags} — flags bit0=enabled.
    struct VouchCfg {
        uint32 quorum;
        uint256 membershipHatId;
        uint8 flags;
    }

    function getVouchConfig(uint256 hatId) external view returns (VouchCfg memory);
    function currentVouchCount(uint256 hatId, address wearer) external view returns (uint32);
    function isEmailVerified(address wearer, uint256 hatId) external view returns (bool);
    function getMaxDailyVouches() external view returns (uint32);
}

interface IDDMig {
    function votingHats() external view returns (uint256[] memory);
    function creatorHats() external view returns (uint256[] memory);
    function membershipAuthority() external view returns (address);
    function hats() external view returns (address);
    function executor() external view returns (address);
}

interface IHVMig {
    function creatorHats() external view returns (uint256[] memory);
}

interface IPTMig {
    function memberHatIds() external view returns (uint256[] memory);
    function approverHatIds() external view returns (uint256[] memory);
}

interface IEDUMig {
    function creatorHatIds() external view returns (uint256[] memory);
    function memberHatIds() external view returns (uint256[] memory);
}

interface IQJMig {
    function memberHatIds() external view returns (uint256[] memory);
}

interface ITMMig {
    // getLensData(6,"") → permissionHats; (12,"") → membershipAuthority.
    function getLensData(uint8 t, bytes calldata d) external view returns (bytes memory);
}

interface IExecMig {
    function execute(uint256 proposalId, IExecutor.Call[] calldata batch) external;
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
    function setMembershipAuthority(address authority) external;
    function hats() external view returns (address);
    function allowedCaller() external view returns (address);
}

interface IToggleMig {
    function setHatStatus(uint256 hatId, bool active) external;
    function batchSetHatStatus(uint256[] calldata hatIds, bool[] calldata actives) external;
    function hatActive(uint256 hatId) external view returns (bool);
}

interface IOrgRegistryMig {
    function getTopHat(bytes32 orgId) external view returns (uint256);
    function getOrgMetadataAdminHat(bytes32 orgId) external view returns (uint256);
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external;
}

interface IPoaManagerMig {
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IPaymasterMig {
    function setTargetTypesBatch(bytes32 orgId, address[] calldata targets, bytes32[] calldata typeIds) external;
    function HATS() external view returns (address);
}

abstract contract AccessV2MigrationBase is Script {
    /*──────────────────────── Protocol constants ────────────────────────*/
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    // Gnosis protocol
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant GNOSIS_ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    address internal constant GNOSIS_PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

    // Arbitrum protocol
    address internal constant ARB_POA_MANAGER = 0xFF585Fae4A944cD173B19158C6FC5E08980b0815;
    address internal constant ARB_ORG_REGISTRY = 0x7B023B9566b96616D54935AE8De80579c93f62aC;
    address internal constant ARB_PAYMASTER = 0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11;

    bytes32 internal constant MEMBERSHIP_AUTHORITY_TYPEID = keccak256("MembershipAuthority");

    // §1 sticky/delegable classification (delegable IS a per-subject column, §6):
    // member-class role → delegable=true (keeps "Execs manage Members" alive);
    // officer/election-class → sticky (delegable=false).
    /*──────────────────────── Per-org spec ────────────────────────*/
    struct OrgSpec {
        string name;
        bytes32 orgId;
        bool gnosis;
        address executor;
        address votingContract; // allowedCaller == HybridVoting
        address dd;
        address hv;
        address tm;
        address pt;
        address edu;
        address qj;
        address eligibilityModule;
        address toggleModule;
        address paymentManager;
        address zkEmailInvites; // 0 if none
        bool vouchVerbatim; // true = VERBATIM port (counts+epochs); false = AMNESTY
    }

    /*──────────────────────── Build state (storage; fresh per sim run) ────────────────────────*/
    uint256[] internal _subjects; // discovered subject (adopted hat) ids; [0] = topHat (admin)
    mapping(uint256 => bool) internal _seen;
    uint256 internal _memberSubject; // the default-ALLOW QuickJoin member role
    uint256 internal _metadataAdminHat; // SUBJECT_RENAME source
    // Membership expectation captured from LIVE Hats BEFORE cutover (toggle-off makes legacy reads
    // go dark, so parity must compare the authority against a pre-cutover snapshot, not a live read).
    mapping(uint256 => mapping(address => bool)) internal _expectMember;
    uint256 internal _expectTotal;

    /*═══════════════════════════════ Chain helpers ═══════════════════════════════*/
    function _poaManager(OrgSpec memory s) internal pure returns (address) {
        return s.gnosis ? GNOSIS_POA_MANAGER : ARB_POA_MANAGER;
    }

    function _orgRegistry(OrgSpec memory s) internal pure returns (address) {
        return s.gnosis ? GNOSIS_ORG_REGISTRY : ARB_ORG_REGISTRY;
    }

    function _paymaster(OrgSpec memory s) internal pure returns (address) {
        return s.gnosis ? GNOSIS_PAYMASTER : ARB_PAYMASTER;
    }

    function _topHatDomain(OrgSpec memory s) internal view returns (uint256) {
        return IOrgRegistryMig(_orgRegistry(s)).getTopHat(s.orgId) >> 224;
    }

    function _topHatId(OrgSpec memory s) internal view returns (uint256) {
        return IOrgRegistryMig(_orgRegistry(s)).getTopHat(s.orgId);
    }

    /*═══════════════════════════════ Subject discovery ═══════════════════════════════*/

    function _addSubject(uint256 id) internal {
        if (id == 0 || _seen[id]) return;
        _seen[id] = true;
        _subjects.push(id);
    }

    function _addArray(uint256[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            _addSubject(ids[i]);
        }
    }

    /// @notice Enumerate the org's ROLE subjects (adopted verbatim) from live module state.
    ///         [0] is always the topHat (the ADMIN subject seeded FIRST — the §6 lock-out guard).
    function _discoverSubjects(OrgSpec memory s) internal {
        delete _subjects;
        _memberSubject = 0;

        // ADMIN subject first (Executor is its sole member; §1 root-by-address model).
        _addSubject(_topHatId(s));

        _metadataAdminHat = IOrgRegistryMig(_orgRegistry(s)).getOrgMetadataAdminHat(s.orgId);
        if (_metadataAdminHat == 0) _metadataAdminHat = _topHatId(s);

        // The default-ALLOW member role (QuickJoin auto-join) — first entry, if present.
        uint256[] memory qjm = IQJMig(s.qj).memberHatIds();
        if (qjm.length > 0) _memberSubject = qjm[0];
        _addArray(qjm);

        _addArray(IDDMig(s.dd).votingHats());
        _addArray(IDDMig(s.dd).creatorHats());
        _addArray(IHVMig(s.hv).creatorHats());
        _addArray(IPTMig(s.pt).memberHatIds());
        _addArray(IPTMig(s.pt).approverHatIds());
        _addArray(IEDUMig(s.edu).creatorHatIds());
        _addArray(IEDUMig(s.edu).memberHatIds());
        _addArray(_tmPermissionHats(s));
    }

    function _tmPermissionHats(OrgSpec memory s) internal view returns (uint256[] memory) {
        try ITMMig(s.tm).getLensData(6, "") returns (bytes memory raw) {
            return abi.decode(raw, (uint256[]));
        } catch {
            return new uint256[](0);
        }
    }

    /*═══════════════════════════════ Wearer resolution (fork read) ═══════════════════════════════*/

    /// @notice Current members of `subject` among `candidates` — the AUTHORITATIVE fork read.
    ///         The topHat's sole member is the Executor (root-by-address model).
    function _currentMembers(OrgSpec memory s, uint256 subject, address[] memory candidates)
        internal
        view
        returns (address[] memory members)
    {
        uint256 n;
        address[] memory tmp = new address[](candidates.length + 1);
        if (subject == _topHatId(s)) {
            // Admin subject: seed the Executor (its sole legacy wearer).
            if (IHatsMin(HATS).isWearerOfHat(s.executor, subject)) tmp[n++] = s.executor;
        }
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i] == s.executor && subject == _topHatId(s)) continue; // avoid dup
            if (IHatsMin(HATS).isWearerOfHat(candidates[i], subject)) tmp[n++] = candidates[i];
        }
        members = new address[](n);
        for (uint256 i; i < n; ++i) {
            members[i] = tmp[i];
        }
    }

    /*═══════════════════════════════ PREDEPLOY (§6 step 1) ═══════════════════════════════*/

    /// @notice Deploy the authority BeaconProxy UNINITIALIZED, register it (register-before-init),
    ///         then initialize it PAUSED with a minimal seed (the admin subject only — lock-out guard).
    ///         AUTH: executor (pranked in sims / a governance call in production). Returns the proxy.
    function _predeployAuthority(OrgSpec memory s) internal returns (address authority) {
        address beacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
        require(beacon != address(0), "MA beacon not registered (run protocol wave first)");

        // 1. Permissionless proxy deploy — UNINITIALIZED (empty init data) so registration precedes init.
        authority = address(new BeaconProxy(beacon, ""));

        // 2. Register in OrgRegistry BEFORE initialize (subgraph template ordering, §6 / graph-node note).
        IOrgRegistryMig(_orgRegistry(s)).registerOrgContract(
            s.orgId, MEMBERSHIP_AUTHORITY_TYPEID, authority, beacon, true, s.executor, false
        );

        // 3. Initialize PAUSED with the ADMIN subject as the sole genesis subject (seeded first).
        IMembershipAuthority(authority).initialize(_minimalInit(s));
        require(IMembershipAuthority(authority).paused(), "authority must be born paused");
    }

    /// @dev Minimal InitConfig: exactly the admin (topHat) subject — deny-default, unlimited. The
    ///      full role set + memberships + rules + vouch/email are applied by the seed batches below
    ///      (all executor writes, pause-exempt), matching the multi-batch §6 seed choreography.
    function _minimalInit(OrgSpec memory s) internal view returns (IMembershipAuthority.InitConfig memory cfg) {
        cfg.executor = s.executor;
        cfg.paymasterHub = _paymaster(s);
        cfg.orgId = s.orgId;

        uint256[] memory ids = new uint256[](1);
        ids[0] = _topHatId(s);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        kinds[0] = AccessV2Types.SubjectKind.Role;
        string[] memory names = new string[](1);
        names[0] = "Admin";
        uint32[] memory maxm = new uint32[](1);
        maxm[0] = 0;
        bool[] memory defs = new bool[](1);
        defs[0] = false;
        uint256[][] memory grp = new uint256[][](1);
        grp[0] = new uint256[](0);

        cfg.seed.subjectIds = ids;
        cfg.seed.subjectKinds = kinds;
        cfg.seed.subjectNames = names;
        cfg.seed.subjectMaxMembers = maxm;
        cfg.seed.subjectDefaults = defs;
        cfg.seed.groupMemberRoles = grp;
        // vouch / perm arrays left empty (applied via seed batches).
    }

    /*═══════════════════════════════ SEED (§6 step 2) ═══════════════════════════════*/

    /// @notice Full seed choreography. AUTH: executor (pranked). Ordering per §6:
    ///         admin membership → role subjects → defaults → SUBJECT_RENAME → perms →
    ///         memberships(+rule source) → vouch → email. Every write is pause-exempt.
    function _seedAuthority(OrgSpec memory s, address authority, address[] memory candidates) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256 topHat = _topHatId(s);

        // (0) ADMIN membership: grant + accept the Executor on the admin subject FIRST (lock-out guard).
        _seedOne(a, topHat, s.executor, true);

        // (1) Role subjects: create each with maxMembers=0 (unlimited) to avoid any SubjectFull during
        //     seeding; tightened to the live active count afterward (§6 "max(active count, cap)").
        _seedRoleSubjects(a);

        // (2) Defaults: the QuickJoin member role is default-ALLOW (open, QuickJoin keeps working);
        //     every titled role stays deny-by-default (explicit grants below carry members). (§2)
        if (_memberSubject != 0) a.setSubjectDefault(_memberSubject, true, false);

        // (3) SUBJECT_RENAME from live metadataAdmin wearership (§1/§6) — so no live metadata-holder
        //     silently loses the rename power. Attach the perm to the metadataAdmin subject.
        a.setPerm(_metadataAdminHat, AccessV2PermKeys.SUBJECT_RENAME, bytes32(0), _boolWord());

        // (4) Perm table from the audited module inventory (§3/§4).
        _seedPerms(s, a);

        // (5) Memberships (+ per-wearer explicit-ALLOW as the SAME-batch eligibility source, §6 invariant).
        _seedMembershipsAndTighten(s, a, candidates);

        // (6) Vouch attestor state (per-org choice: VERBATIM counts+epochs vs AMNESTY). (§6)
        _seedVouch(s, a, candidates);

        // (7) Email-verified flags (Test6 zk continuity, §6).
        if (s.zkEmailInvites != address(0)) _seedEmail(s, a, candidates);
    }

    /// @dev Seed a single (subject,user): governance explicit-ALLOW then accepted membership.
    function _seedOne(IMembershipAuthority a, uint256 subject, address user, bool delegable) internal {
        uint256[] memory subs = new uint256[](1);
        address[] memory usr = new address[](1);
        AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](1);
        bool[] memory del = new bool[](1);
        subs[0] = subject;
        usr[0] = user;
        kinds[0] = AccessV2Types.RuleKind.Grant;
        del[0] = delegable;
        a.seedRules(subs, usr, kinds, del);
        a.seedMemberships(subs, usr);
    }

    function _seedRoleSubjects(IMembershipAuthority a) internal {
        // skip index 0 (admin subject already exists from initialize)
        uint256 count = _subjects.length - 1;
        if (count == 0) return;
        uint256[] memory ids = new uint256[](count);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](count);
        string[] memory names = new string[](count);
        uint32[] memory maxm = new uint32[](count);
        for (uint256 i = 1; i < _subjects.length; ++i) {
            ids[i - 1] = _subjects[i];
            kinds[i - 1] = AccessV2Types.SubjectKind.Role;
            names[i - 1] = string.concat("Role#", vm.toString(i));
            maxm[i - 1] = 0; // unlimited during seeding; tightened post-membership
        }
        a.seedSubjects(ids, kinds, names, maxm);
    }

    /// @dev Perm rows: for each role subject that a module gates on, attach the module's perm key.
    ///      member-class → delegable in memberships; here we attach the boolean/mask perm words.
    function _seedPerms(OrgSpec memory s, IMembershipAuthority a) internal {
        // DD: voting hats → DD_VOTE, creator hats → DD_CREATE
        _attachBool(a, IDDMig(s.dd).votingHats(), AccessV2PermKeys.DD_VOTE);
        _attachBool(a, IDDMig(s.dd).creatorHats(), AccessV2PermKeys.DD_CREATE);
        // HV: creator hats → HV_CREATE
        _attachBool(a, IHVMig(s.hv).creatorHats(), AccessV2PermKeys.HV_CREATE);
        // PT: member/approver
        _attachBool(a, IPTMig(s.pt).memberHatIds(), AccessV2PermKeys.PT_MEMBER);
        _attachBool(a, IPTMig(s.pt).approverHatIds(), AccessV2PermKeys.PT_APPROVE);
        // EDU: creator/member
        _attachBool(a, IEDUMig(s.edu).creatorHatIds(), AccessV2PermKeys.EDU_CREATE);
        _attachBool(a, IEDUMig(s.edu).memberHatIds(), AccessV2PermKeys.EDU_MEMBER);
        // QJ: member role → auto-join key
        _attachBool(a, IQJMig(s.qj).memberHatIds(), AccessV2PermKeys.QJ_AUTOJOIN);
        // TM: permission hats → TM_PERMS global mask (ctx=0). Low 8 bits carry the mask; seed all-perms
        //     (0xFF) for holders — behavior-preserving for the global fold (per-project inherit=true).
        _attachMask(a, _tmPermissionHats(s), AccessV2PermKeys.TM_PERMS, 0xFF);
    }

    function _attachBool(IMembershipAuthority a, uint256[] memory ids, bytes32 key) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == 0) continue;
            // idempotent: skip if already attached (union across modules)
            if (a.getPerm(ids[i], key, bytes32(0)) != 0) continue;
            a.setPerm(ids[i], key, bytes32(0), _boolWord());
        }
    }

    function _attachMask(IMembershipAuthority a, uint256[] memory ids, bytes32 key, uint256 mask) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == 0) continue;
            if (a.getPerm(ids[i], key, bytes32(0)) != 0) continue;
            a.setPerm(ids[i], key, bytes32(0), AccessV2PermKeys.EXISTS_BIT | (mask & AccessV2PermKeys.VALUE_MASK));
        }
    }

    function _boolWord() internal pure returns (uint256) {
        // exists + value 1 (bool-any true). inheritGlobal irrelevant at ctx 0.
        return AccessV2PermKeys.EXISTS_BIT | uint256(1);
    }

    /// @dev Per role subject: seed grant(delegable)+membership for every current wearer, then tighten
    ///      maxMembers to the live active count (§6). member-class role → delegable=true; else sticky.
    function _seedMembershipsAndTighten(OrgSpec memory s, IMembershipAuthority a, address[] memory candidates)
        internal
    {
        for (uint256 si = 1; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory members = _currentMembers(s, subject, candidates);
            if (members.length == 0) continue;
            bool delegable = (subject == _memberSubject); // member-class delegable, officer-class sticky
            AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](members.length);
            bool[] memory del = new bool[](members.length);
            uint256[] memory subs = new uint256[](members.length);
            for (uint256 j; j < members.length; ++j) {
                kinds[j] = AccessV2Types.RuleKind.Grant;
                del[j] = delegable;
                subs[j] = subject;
            }
            a.seedRules(subs, members, kinds, del);
            a.seedMemberships(subs, members);
            // Tighten maxMembers to the live active count (§6 "max(active count, cap)") for TITLED roles
            // only. The OPEN member role (default-ALLOW, QuickJoin) stays UNLIMITED so new joins keep
            // working post-cutover — capping it at the current count would brick QuickJoin.
            if (subject != _memberSubject) a.setMaxMembers(subject, uint32(members.length));
        }
    }

    function _seedVouch(OrgSpec memory s, IMembershipAuthority a, address[] memory candidates) internal {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            IEMMig.VouchCfg memory vc = IEMMig(s.eligibilityModule).getVouchConfig(subject);
            bool enabled = (vc.flags & 0x01) != 0;
            if (!enabled || vc.quorum == 0) continue;
            // A legacy self-voucher config (voucherSubject == subject) is a v2 bootstrap deadlock the
            // authority rejects ({WiringIncompatible}). It is NOT ported verbatim: members hold seeded
            // explicit grants and stay eligible; governance re-configures a valid voucher subject
            // post-cutover if vouch-lapse semantics are wanted (recorded in the migration notes).
            if (vc.membershipHatId == subject || vc.membershipHatId == 0) continue;
            // Ensure the voucher (membership) subject exists as a subject.
            _ensureSubjectSeeded(a, vc.membershipHatId);
            a.configureVouchAttestor(subject, vc.quorum, vc.membershipHatId);
            if (!s.vouchVerbatim) continue; // AMNESTY: members already hold explicit grants; re-vouch later
            // VERBATIM: port each current member's received-vouch COUNT into the current epoch.
            address[] memory members = _currentMembers(s, subject, candidates);
            uint32[] memory counts = new uint32[](members.length);
            uint256 nonzero;
            for (uint256 j; j < members.length; ++j) {
                counts[j] = IEMMig(s.eligibilityModule).currentVouchCount(subject, members[j]);
                if (counts[j] > 0) nonzero++;
            }
            if (nonzero > 0) a.seedVouches(subject, members, counts);
        }
    }

    function _ensureSubjectSeeded(IMembershipAuthority a, uint256 id) internal {
        if (id == 0 || _seen[id]) return;
        _addSubject(id);
        uint256[] memory ids = new uint256[](1);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        uint32[] memory maxm = new uint32[](1);
        ids[0] = id;
        kinds[0] = AccessV2Types.SubjectKind.Role;
        names[0] = "VoucherRole";
        maxm[0] = 0;
        a.seedSubjects(ids, kinds, names, maxm);
    }

    function _seedEmail(OrgSpec memory s, IMembershipAuthority a, address[] memory candidates) internal {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory tmp = new address[](candidates.length);
            uint256 n;
            for (uint256 j; j < candidates.length; ++j) {
                if (IEMMig(s.eligibilityModule).isEmailVerified(candidates[j], subject)) tmp[n++] = candidates[j];
            }
            if (n == 0) continue;
            address[] memory users = new address[](n);
            for (uint256 j; j < n; ++j) {
                users[j] = tmp[j];
            }
            a.seedEmailVerified(subject, users);
        }
    }

    /*═══════════════════════════════ SEED INVARIANT (§6 hard assert) ═══════════════════════════════*/

    /// @notice Every seeded membership carries an eligibility source in the SAME ceremony — no seeded
    ///         member is ever accepted-but-ineligible, even mid-ceremony. Returns the total member count.
    function _assertSeedInvariant(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (uint256 totalMembers)
    {
        IMembershipAuthority a = IMembershipAuthority(authority);
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory members = _currentMembers(s, subject, candidates);
            for (uint256 j; j < members.length; ++j) {
                (bool accepted, bool eligible,,) = a.getStatus(subject, members[j]);
                require(accepted, "SEED INVARIANT: seeded member not accepted");
                require(eligible, "SEED INVARIANT: accepted-but-ineligible member seeded");
                require(a.isMember(subject, members[j]), "SEED INVARIANT: isMember false for seeded member");
                totalMembers++;
            }
            require(a.memberCount(subject) <= _maxOrUnlimited(a, subject), "memberCount exceeds maxMembers");
        }
    }

    function _maxOrUnlimited(IMembershipAuthority a, uint256 subject) internal view returns (uint256) {
        uint32 mm = a.getSubject(subject).maxMembers;
        return mm == 0 ? type(uint256).max : mm;
    }

    /// @notice Record, from LIVE Hats (call BEFORE the cutover toggle-off), which candidate is a wearer
    ///         of each subject — the parity EXPECTATION the post-cutover authority must reproduce.
    function _captureExpectations(OrgSpec memory s, address[] memory candidates) internal {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory members = _currentMembers(s, subject, candidates);
            for (uint256 j; j < members.length; ++j) {
                if (!_expectMember[subject][members[j]]) {
                    _expectMember[subject][members[j]] = true;
                    _expectTotal++;
                }
            }
        }
    }

    /*═══════════════════════════════ CUTOVER BATCH (§6 step 3) ═══════════════════════════════*/

    /// @notice Build the exact atomic cutover Executor.Call[] in §6 order. `router` is the singleton.
    ///         Ordering: router BIND (before toggle-off) → setMembershipAuthority ×8 (incl. Executor
    ///         self-target) → unpause → legacy toggle-off. announceWinner needs a 3,000,000 gas limit.
    ///         Returns the batch and the index of the router-bind call (for the ordering assertion).
    function _buildCutoverBatch(OrgSpec memory s, address authority, address router)
        internal
        view
        returns (IExecutor.Call[] memory batch, uint256 bindIndex)
    {
        uint256 domain = _topHatDomain(s);
        uint256[] memory roleHats = _subjects; // toggle-off targets (adopted legacy ids)
        bool[] memory offs = new bool[](roleHats.length);
        // offs default false → setHatStatus(false)

        batch = new IExecutor.Call[](11);
        uint256 k;

        // 1. Router legacy-id BIND — BEFORE toggle-off (adopted ids flip passthrough→authority-native).
        bindIndex = k;
        batch[k++] = IExecutor.Call({
            target: router,
            value: 0,
            data: abi.encodeCall(IAuthorityRouter.bindAuthority, (s.orgId, domain, authority))
        });

        // 2-8. setMembershipAuthority on the 7 non-Executor modules...
        batch[k++] = _setAuth(s.dd, authority);
        batch[k++] = _setAuth(s.hv, authority);
        batch[k++] = _setAuth(s.tm, authority);
        batch[k++] = _setAuth(s.pt, authority);
        batch[k++] = _setAuth(s.edu, authority);
        batch[k++] = _setAuth(s.qj, authority);
        // ...and the Executor itself (repoints l.hats — the W6 self-target allowlist).
        batch[k++] = IExecutor.Call({
            target: s.executor,
            value: 0,
            data: abi.encodeCall(IExecMig.setMembershipAuthority, (authority))
        });

        // 9. targetTypes: map the authority target → MembershipAuthority typeId so the hub resolves its
        //    sponsored selectors via the global rulebook (§6 step-3; org-admin-gated on the hub — the
        //    Executor is the org admin resolved THROUGH the router after the bind above).
        address[] memory tt = new address[](1);
        bytes32[] memory tids = new bytes32[](1);
        tt[0] = authority;
        tids[0] = MEMBERSHIP_AUTHORITY_TYPEID;
        batch[k++] = IExecutor.Call({
            target: _paymaster(s),
            value: 0,
            data: abi.encodeCall(IPaymasterMig.setTargetTypesBatch, (s.orgId, tt, tids))
        });

        // 10. UNPAUSE the authority (reads were live; now open non-executor writes).
        batch[k++] = IExecutor.Call({
            target: authority,
            value: 0,
            data: abi.encodeCall(IMembershipAuthority.setPaused, (false))
        });

        // 10. Legacy-hat TOGGLE-OFF (one batched call) — AFTER the bind, so no hub/admin gap.
        batch[k++] = IExecutor.Call({
            target: s.toggleModule,
            value: 0,
            data: abi.encodeCall(IToggleMig.batchSetHatStatus, (roleHats, offs))
        });

        require(k == batch.length, "batch length mismatch");
    }

    function _setAuth(address module, address authority) internal pure returns (IExecutor.Call memory) {
        return IExecutor.Call({target: module, value: 0, data: abi.encodeWithSignature("setMembershipAuthority(address)", authority)});
    }
}
