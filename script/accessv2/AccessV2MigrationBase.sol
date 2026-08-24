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
 *   (a) PREDEPLOY (§6 step 1-2, C5): deploy the org's MembershipAuthority BeaconProxy
 *       ATOMICALLY INITIALIZED with an EMPTY genesis (executor/orgId/paused only) in the
 *       deploy tx (front-run grief close), register it in OrgRegistry (register-before-
 *       SUBJECT so the subgraph template precedes every subject event), then SEED the
 *       admin subject + roles / defaults / perms / rules / memberships / vouch-state / email flags
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
    function vouchers(uint256 hatId, address wearer, address voucher) external view returns (bool);
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

    /// @notice Deploy the authority BeaconProxy WITH init data in the SAME transaction (C5 —
    ///         front-run grief close, finding specOrder-5). The proxy is created via
    ///         `BeaconProxy(beacon, abi.encodeCall(initialize, EMPTY-GENESIS cfg))` so it lands
    ///         ATOMICALLY initialized (executor/orgId/paused) — an attacker can no longer initialize
    ///         the predicted CREATE2 address first (poisoning the slot) during the seed-proposal
    ///         voting window. The EMPTY genesis creates NO subjects, so ALL subject events index
    ///         AFTER registerOrgContract (which leads seed batch 1); only initialize's config events
    ///         predate registration and are subgraph-derivable from the Organization entity (runbook
    ///         SPEC ERRATA). Register + seed still live in the SEED BATCH (built by _buildSeedBatches).
    function _predeployAuthority(OrgSpec memory s) internal returns (address authority) {
        address beacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
        require(beacon != address(0), "MA beacon not registered (run protocol wave first)");
        authority = address(new BeaconProxy(beacon, abi.encodeCall(IMembershipAuthority.initialize, (_minimalInit(s)))));
    }

    /// @dev Minimal EMPTY-GENESIS InitConfig (C5): sets ONLY executor/paymasterHub/orgId — NO subjects.
    ///      The admin (topHat) subject, the full role set, memberships, rules, vouch and email are all
    ///      applied by the seed batches below (executor writes, pause-exempt) so every subject event is
    ///      emitted AFTER the org registers the proxy in OrgRegistry (register-before-SUBJECT discipline).
    function _minimalInit(OrgSpec memory s) internal view returns (IMembershipAuthority.InitConfig memory cfg) {
        cfg.executor = s.executor;
        cfg.paymasterHub = _paymaster(s);
        cfg.orgId = s.orgId;

        cfg.seed.subjectIds = new uint256[](0);
        cfg.seed.subjectKinds = new AccessV2Types.SubjectKind[](0);
        cfg.seed.subjectNames = new string[](0);
        cfg.seed.subjectMaxMembers = new uint32[](0);
        cfg.seed.subjectDefaults = new bool[](0);
        cfg.seed.groupMemberRoles = new uint256[][](0);
        cfg.seed.vouchSubjects = new uint256[](0);
        cfg.seed.vouchQuorums = new uint32[](0);
        cfg.seed.vouchVoucherSubjects = new uint256[](0);
        cfg.seed.permSubjects = new uint256[](0);
        cfg.seed.permKeys = new bytes32[](0);
        cfg.seed.permCtxs = new bytes32[](0);
        cfg.seed.permWords = new uint256[](0);
    }

    /*═══════════════════════════════ SEED BATCH (§6 step 2) ═══════════════════════════════*/
    /*
     * ONE SOURCE OF TRUTH for the ceremony content: the seed is BUILT as Executor.Call[] batches and
     * EXECUTED through Executor.execute — by the rehearsal (pranked voting contract) and by the real
     * governance proposals (HybridVoting create→vote→announceWinner) ALIKE. What is rehearsed is
     * byte-identical to what ships.
     *
     * Batch 1: registerOrgContract → initialize(PAUSED) → admin seed → role subjects → defaults →
     *          SUBJECT_RENAME → module perms.   (register-before-initialize INSIDE one tx: same-block
     *          init events are safe for the subgraph template — graph-node note.)
     * Batch 2+: per-subject membership chunks — each chunk carries seedRules AND seedMemberships for
     *          the SAME member slice (the §6 SEED INVARIANT holds per-chunk, even across KUBI's split
     *          batches) — then tighten, vouch, email.
     */

    uint256 internal constant SEED_CHUNK = 20; // members per membership chunk (announceWinner gas bound)
    // Executor.MAX_CALLS_PER_BATCH is 20; _push auto-splits at this bound. A seedRules/seedMemberships
    // pair straddling a split is SAFE for the §6 invariant: rules are always pushed BEFORE their
    // memberships, so across any split the eligibility source lands first — a member can be briefly
    // eligible-but-not-accepted (harmless), never accepted-but-ineligible.
    uint256 internal constant MAX_CALLS = 20;

    IExecutor.Call[][] internal _batches;

    function _push(address target, bytes memory data) internal {
        if (_batches[_batches.length - 1].length >= MAX_CALLS) _newBatch();
        _batches[_batches.length - 1].push(IExecutor.Call({target: target, value: 0, data: data}));
    }

    function _newBatch() internal {
        _batches.push();
    }

    /// @notice Build the full §6 seed choreography as governance batches for `authority`.
    function _buildSeedBatches(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        returns (IExecutor.Call[][] memory)
    {
        delete _batches;
        address beacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
        uint256 topHat = _topHatId(s);

        /*── Batch 1: register → admin subject → admin membership → subjects → defaults → rename → perms ──*/
        // NOTE (C5): the proxy was ALREADY initialized ATOMICALLY at deploy with an EMPTY genesis
        // (executor/orgId/paused only — front-run grief close, specOrder-5). So batch 1 does NOT call
        // initialize; the admin SUBJECT is created here (seedSubjects), AFTER registerOrgContract, so
        // its SubjectCreated event indexes post-registration.
        _newBatch();
        _push(
            _orgRegistry(s),
            abi.encodeCall(
                IOrgRegistryMig.registerOrgContract,
                (s.orgId, MEMBERSHIP_AUTHORITY_TYPEID, authority, beacon, true, s.executor, false)
            )
        );

        // (0) ADMIN subject + membership LEAD the batch (lock-out guard): create the topHat subject,
        //     then grant + accept the Executor as its sole member, before any other subject/rule.
        _pushAdminSubject(authority, topHat);
        _pushSeedSlice(authority, topHat, _single(s.executor), true);

        // (1) Role subjects (maxMembers=0 during seeding; tightened after memberships).
        _pushRoleSubjects(authority);

        // (2) Default-ALLOW on the open member role (QuickJoin keeps working).
        if (_memberSubject != 0) {
            _push(authority, abi.encodeCall(IMembershipAuthority.setSubjectDefault, (_memberSubject, true, false)));
        }

        // (3) SUBJECT_RENAME from live metadataAdmin wearership.
        _pushPerm(authority, _metadataAdminHat, AccessV2PermKeys.SUBJECT_RENAME, _boolWord());

        // (4) Perm table from the audited module inventory.
        _buildPerms(s, authority);

        /*── Batch 2+: memberships (chunked; rule+membership same chunk) → tighten → vouch → email ──*/
        _newBatch();
        _buildMembershipsAndTighten(s, authority, candidates);
        _buildVouch(s, authority, candidates);
        if (s.zkEmailInvites != address(0)) _buildEmail(s, authority, candidates);

        return _batches;
    }

    /// @dev Push seedRules+seedMemberships for one (subject, member-slice) — the invariant unit.
    function _pushSeedSlice(address authority, uint256 subject, address[] memory members, bool delegable) internal {
        AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](members.length);
        bool[] memory del = new bool[](members.length);
        uint256[] memory subs = new uint256[](members.length);
        for (uint256 j; j < members.length; ++j) {
            kinds[j] = AccessV2Types.RuleKind.Grant;
            del[j] = delegable;
            subs[j] = subject;
        }
        _push(authority, abi.encodeCall(IMembershipAuthority.seedRules, (subs, members, kinds, del)));
        _push(authority, abi.encodeCall(IMembershipAuthority.seedMemberships, (subs, members)));
    }

    function _single(address x) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = x;
    }

    /// @dev Create the ADMIN (topHat) subject as the first authority write of seed batch 1 (C5).
    ///      Empty-genesis initialize created NO subjects, so the admin subject is materialized here —
    ///      AFTER registerOrgContract — as a deny-default, unlimited ROLE named "Admin".
    function _pushAdminSubject(address authority, uint256 topHat) internal {
        uint256[] memory ids = new uint256[](1);
        AccessV2Types.SubjectKind[] memory kinds = new AccessV2Types.SubjectKind[](1);
        string[] memory names = new string[](1);
        uint32[] memory maxm = new uint32[](1);
        ids[0] = topHat;
        kinds[0] = AccessV2Types.SubjectKind.Role;
        names[0] = "Admin";
        maxm[0] = 0;
        _push(authority, abi.encodeCall(IMembershipAuthority.seedSubjects, (ids, kinds, names, maxm)));
    }

    function _pushRoleSubjects(address authority) internal {
        // skip index 0 (admin subject — created by _pushAdminSubject at the head of seed batch 1)
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
        _push(authority, abi.encodeCall(IMembershipAuthority.seedSubjects, (ids, kinds, names, maxm)));
    }

    /// @dev Perm rows: for each role subject a module gates on, attach the module's perm key.
    mapping(uint256 => mapping(bytes32 => bool)) internal _permPushed; // build-time dedup (union across modules)

    function _buildPerms(OrgSpec memory s, address authority) internal {
        _attachBool(authority, IDDMig(s.dd).votingHats(), AccessV2PermKeys.DD_VOTE);
        _attachBool(authority, IDDMig(s.dd).creatorHats(), AccessV2PermKeys.DD_CREATE);
        _attachBool(authority, IHVMig(s.hv).creatorHats(), AccessV2PermKeys.HV_CREATE);
        _attachBool(authority, IPTMig(s.pt).memberHatIds(), AccessV2PermKeys.PT_MEMBER);
        _attachBool(authority, IPTMig(s.pt).approverHatIds(), AccessV2PermKeys.PT_APPROVE);
        _attachBool(authority, IEDUMig(s.edu).creatorHatIds(), AccessV2PermKeys.EDU_CREATE);
        _attachBool(authority, IEDUMig(s.edu).memberHatIds(), AccessV2PermKeys.EDU_MEMBER);
        _attachBool(authority, IQJMig(s.qj).memberHatIds(), AccessV2PermKeys.QJ_AUTOJOIN);
        // TM: permission hats → TM_PERMS global mask (ctx=0). Low 8 bits carry the mask; seed all-perms
        //     (0xFF) for holders — behavior-preserving for the global fold (per-project inherit=true).
        _attachMask(authority, _tmPermissionHats(s), AccessV2PermKeys.TM_PERMS, 0xFF);
    }

    function _attachBool(address authority, uint256[] memory ids, bytes32 key) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == 0 || _permPushed[ids[i]][key]) continue;
            _pushPerm(authority, ids[i], key, _boolWord());
        }
    }

    function _attachMask(address authority, uint256[] memory ids, bytes32 key, uint256 mask) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == 0 || _permPushed[ids[i]][key]) continue;
            _pushPerm(authority, ids[i], key, AccessV2PermKeys.EXISTS_BIT | (mask & AccessV2PermKeys.VALUE_MASK));
        }
    }

    function _pushPerm(address authority, uint256 subject, bytes32 key, uint256 word) internal {
        if (_permPushed[subject][key]) return;
        _permPushed[subject][key] = true;
        _push(authority, abi.encodeCall(IMembershipAuthority.setPerm, (subject, key, bytes32(0), word)));
    }

    function _boolWord() internal pure returns (uint256) {
        // exists + value 1 (bool-any true). inheritGlobal irrelevant at ctx 0.
        return AccessV2PermKeys.EXISTS_BIT | uint256(1);
    }

    /// @dev Per role subject: rules+memberships for every current wearer (SEED_CHUNK members per slice,
    ///      opening a fresh batch when a chunk boundary is crossed), then tighten maxMembers (§6).
    function _buildMembershipsAndTighten(OrgSpec memory s, address authority, address[] memory candidates) internal {
        uint256 inBatch;
        for (uint256 si = 1; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory members = _currentMembers(s, subject, candidates);
            if (members.length == 0) continue;
            bool delegable = (subject == _memberSubject); // member-class delegable, officer-class sticky
            for (uint256 off; off < members.length; off += SEED_CHUNK) {
                uint256 len = members.length - off;
                if (len > SEED_CHUNK) len = SEED_CHUNK;
                if (inBatch + len > SEED_CHUNK) {
                    _newBatch(); // split proposal: invariant holds per-chunk (rules+memberships together)
                    inBatch = 0;
                }
                address[] memory slice = new address[](len);
                for (uint256 j; j < len; ++j) {
                    slice[j] = members[off + j];
                }
                _pushSeedSlice(authority, subject, slice, delegable);
                inBatch += len;
            }
            // Tighten maxMembers to the live active count (§6 "max(active count, cap)") for TITLED roles
            // only. The OPEN member role (default-ALLOW, QuickJoin) stays UNLIMITED so new joins keep
            // working post-cutover — capping it at the current count would brick QuickJoin.
            if (subject != _memberSubject) {
                _push(authority, abi.encodeCall(IMembershipAuthority.setMaxMembers, (subject, uint32(members.length))));
            }
        }
    }

    function _buildVouch(OrgSpec memory s, address authority, address[] memory candidates) internal {
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
            _ensureSubjectPushed(authority, vc.membershipHatId);
            _push(
                authority,
                abi.encodeCall(IMembershipAuthority.configureVouchAttestor, (subject, vc.quorum, vc.membershipHatId))
            );
            if (!s.vouchVerbatim) continue; // AMNESTY: members already hold explicit grants; re-vouch later
            // VERBATIM (C2 — records-first): reconstruct each current member's ACTUAL per-voucher
            // records from the legacy EligibilityModule (which exposes vouchers(subject, wearer,
            // voucher) but no enumeration) by probing every candidate as a potential voucher, then
            // seed those records via seedVouchers. Porting real records — not a bare count — is what
            // lets a ported voucher revoke and blocks re-vouch double-counting post-cutover.
            address[] memory members = _currentMembers(s, subject, candidates);
            for (uint256 j; j < members.length; ++j) {
                address[] memory vs = _reconstructVouchers(s, subject, members[j], candidates);
                if (vs.length > 0) {
                    _push(authority, abi.encodeCall(IMembershipAuthority.seedVouchers, (subject, members[j], vs)));
                }
            }
        }
    }

    /// @dev Reconstruct the actual voucher set for `wearer` on `subject` by probing the legacy EM's
    ///      `vouchers(subject, wearer, candidate)` record for every candidate (the EM stores records
    ///      but exposes no per-wearer enumeration). Returns the tightly-sized voucher list.
    function _reconstructVouchers(OrgSpec memory s, uint256 subject, address wearer, address[] memory candidates)
        internal
        view
        returns (address[] memory)
    {
        address[] memory tmp = new address[](candidates.length);
        uint256 n;
        for (uint256 i; i < candidates.length; ++i) {
            if (IEMMig(s.eligibilityModule).vouchers(subject, wearer, candidates[i])) {
                tmp[n++] = candidates[i];
            }
        }
        address[] memory out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }

    function _ensureSubjectPushed(address authority, uint256 id) internal {
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
        _push(authority, abi.encodeCall(IMembershipAuthority.seedSubjects, (ids, kinds, names, maxm)));
    }

    function _buildEmail(OrgSpec memory s, address authority, address[] memory candidates) internal {
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
            _push(authority, abi.encodeCall(IMembershipAuthority.seedEmailVerified, (subject, users)));
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
            target: router, value: 0, data: abi.encodeCall(IAuthorityRouter.bindAuthority, (s.orgId, domain, authority))
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
            target: s.executor, value: 0, data: abi.encodeCall(IExecMig.setMembershipAuthority, (authority))
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
            target: authority, value: 0, data: abi.encodeCall(IMembershipAuthority.setPaused, (false))
        });

        // 10. Legacy-hat TOGGLE-OFF (one batched call) — AFTER the bind, so no hub/admin gap.
        batch[k++] = IExecutor.Call({
            target: s.toggleModule, value: 0, data: abi.encodeCall(IToggleMig.batchSetHatStatus, (roleHats, offs))
        });

        require(k == batch.length, "batch length mismatch");
    }

    function _setAuth(address module, address authority) internal pure returns (IExecutor.Call memory) {
        return IExecutor.Call({
            target: module, value: 0, data: abi.encodeWithSignature("setMembershipAuthority(address)", authority)
        });
    }
}
