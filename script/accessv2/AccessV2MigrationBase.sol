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
import {ZkEmailProof} from "../../src/zkemail/IVerifier.sol";

/*
 * ============================================================================
 * AccessV2MigrationBase — reusable per-org migration engine (SPEC §6)
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
 *       toggle-off + in-batch CutoverVerifier. announceWinner needs an explicit high gas
 *       limit (CLAUDE.md gotcha) — the per-org figure from MIGRATION-RUNBOOK.md's measured gas
 *       table (KUBI 5M, others 4M) is written into every generated proposal JSON.
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
    // viewHat returns the full 9-field hat record — we adopt maxSupply (the honest live cap, R1)
    // and details (the live role name) verbatim.
    function viewHat(uint256 hatId)
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        );
}

/// @dev HybridVoting voting-class enumeration — class hatIds are consumed as authority subjects
///      (activeMemberSince) post-cutover, so they must be discovered/seeded.
///      Struct field order MUST match HybridVoting.ClassConfig exactly.
interface IHVClasses {
    struct ClassCfg {
        uint8 strategy;
        uint8 slicePct;
        bool quadratic;
        uint256 minBalance;
        address asset;
        uint256[] hatIds;
    }

    function getClasses() external view returns (ClassCfg[] memory);
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
    // A1/A3 live-state reads (BOTH present on the DEPLOYED EM impls — getWearerRuleFlags is NOT: it
    // reverts on the live older bytecode, so ban detection uses hasSpecificWearerRules + getWearerRules):
    //  - getWearerRules(fresh, hat).eligible == the subject's LIVE default verdict for a fresh address
    //    (A1 live-default adoption: DP member true; Test6/KUBI member FALSE — zk/vouch gated).
    //  - hasSpecificWearerRules(user, hat) == an EXPLICIT per-wearer rule exists; combined with
    //    getWearerRules(user, hat) NOT (eligible && standing) it identifies a legacy BAN/kick (A3).
    function getWearerRules(address wearer, uint256 hatId) external view returns (bool eligible, bool standing);
    function hasSpecificWearerRules(address wearer, uint256 hatId) external view returns (bool);
    // getWearerStatus is the EM's COMBINED verdict (rule + vouch + email + hierarchy). It is
    // TOGGLE-INDEPENDENT (the EM has no knowledge of the ToggleModule), so it is the stable
    // "is this candidate an effectively-eligible member today" test — used to exclude current members
    // from the ban set at BOTH build time and post-toggle-off assert time (isWearerOfHat is NOT stable
    // across the cutover toggle-off: it goes false for every wearer once legacy hats are toggled off).
    function getWearerStatus(address wearer, uint256 hatId) external view returns (bool eligible, bool standing);
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

/// @dev The executor-gated TaskManager admin surface used by the T5 override-row injection fallback.
interface ITMWriteMig {
    function setProjectRolePerm(bytes32 pid, uint256 hatId, uint8 mask) external;
}

interface IExecMig {
    function execute(uint256 proposalId, IExecutor.Call[] calldata batch) external;
    function mintHatsForUser(address user, uint256[] calldata hatIds) external;
    function setMembershipAuthority(address authority) external;
    function hats() external view returns (address);
    function allowedCaller() external view returns (address);
    /// @dev The gate BOTH the legacy EligibilityModule.setEmailVerified and the v2
    ///      MembershipAuthority.setEmailVerified apply to a non-executor caller (T1 zk continuity).
    function isAuthorizedHatMinter(address minter) external view returns (bool);
}

/// @dev The LIVE per-org ZkEmailInvites surface exercised by the T1 continuity probe. The deployed
///      bytecode resolves its Hats instance from `executor.hats()` (fork-traced, 2026-08-25), so the
///      cutover's `Executor.setMembershipAuthority` IS the zk repoint — there is no module-side setter
///      to call and none is needed. See _probeZkContinuity for the full traced chain.
interface IZkInvitesMig {
    function executor() external view returns (address);
    function domainVerifier() external view returns (address);
    function dkimRegistry() external view returns (address);
    function merkleRoot() external view returns (bytes32);
    function allowlistCid() external view returns (bytes32);
    function setActiveAllowlist(bytes32 root, bytes32 cid) external;
    function claimRoleByDomain(
        ZkEmailProof calldata proof,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external;
}

/// @dev The legacy EligibilityModule WRITE surface used by the pre-cutover zk baseline (T1), the
///      synthetic-ban drill (T3) and the A5 drift drill. superAdmin == the org Executor (verified live).
interface IEMWriteMig {
    function setWearerEligibility(address wearer, uint256 hatId, bool eligible, bool standing) external;
    function mintHatToAddress(uint256 hatId, address wearer) external;
    function setEmailVerified(address wearer, uint256[] calldata hatIds) external;
    // A real governance kick on the DEPLOYED pre-FIX-0 EM needs all three: the explicit deny alone is
    // ADDITIVE there (EligibilityLogic._getWearerStatus ORs hierarchy with the vouch verdict, and the
    // FIX-0 explicit-ban short-circuit is absent from the live bytecode), so a vouched wearer stays
    // eligible until their vouch count is cleared too.
    function clearWearerVouches(address wearer, uint256 hatId) external;
    function clearEmailVerified(address wearer, uint256 hatId) external;
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

/// @dev CutoverVerifier — the stateless §6 in-batch verifier (src/CutoverVerifier.sol). Wired as the
///      LAST call of the cutover batch so a failed check reverts the WHOLE batch (nothing half-lands).
interface ICutoverVerifierMig {
    function verify(
        bytes32 orgId,
        address authority,
        address router,
        uint256[] calldata subjects,
        uint32[] calldata expectedCounts,
        uint32[] calldata expectedSupplies
    ) external view;
}

interface IHatsSupplyMig {
    function hatSupply(uint256 hatId) external view returns (uint32);
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
        // T2: the RECORDED per-org member-gate expectation. The A1 seeder and the A1
        // join probe both used to consult the SAME _liveDefaultAllow oracle, so a wrong verdict flipped
        // both and every sim passed self-consistently (a gated role misread as open would be seeded
        // default-ALLOW and then "proved" open). This is a live-verified CONSTANT of the catalog
        // (2026-08-25: DecentralPark member hat raw+combined (true,true) = OPEN; Test6 (false,true) and
        // KUBI (false,true) = GATED; Poa has NO QuickJoin member hat). The seeder require()s the live
        // gate still equals it, and the probe selects its arm from THIS, never from the live probe.
        bool expectOpenMember;
        // T3: run the SYNTHETIC-BAN drill on this org — inject a real explicit-deny
        // on a current member through the live EligibilityModule admin surface BEFORE seeding, so the
        // RuleKind.Ban porting path actually executes (all four orgs' effective-ban sets were empty or
        // near-empty, making every per-ban assert vacuous). One org per chain: KUBI (Gnosis), Poa (Arb).
        bool banDrill;
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
    // The stateless CutoverVerifier singleton (src/CutoverVerifier.sol). Set by _setupProtocol (sims
    // deploy a fresh instance) or by GenerateBatches (the registered per-chain address). When nonzero,
    // _buildCutoverBatch appends its verify() as the LAST cutover call (§6 in-batch verification, C4).
    address internal _verifier;

    // A2: the LIVE TaskManager permission table, enumerated by
    // tools/enumerate-tm-perms.sh into fixtures/<org>.tmperms.json (there is NO getter for
    // rolePermGlobal/rolePermProj; the event stream is the only source of truth). Five parallel arrays:
    // global (hat→mask at ctx 0) and per-project (pid,hat→mask at ctx = pid+1). Loaded per org by
    // _loadTmPerms; consumed by _seedTmPerms (seeding) and the rehearsal shadow probe (parity).
    uint256[] internal _tmGlobalHats;
    uint256[] internal _tmGlobalMasks;
    uint256[] internal _tmProjPids;
    uint256[] internal _tmProjHats;
    uint256[] internal _tmProjMasks;
    bool internal _tmPermsLoaded;

    // T3: the (subject, user) pair the SYNTHETIC-BAN drill kicked on the live
    // EligibilityModule before seeding. Zero when the drill did not run for this org.
    uint256 internal _synthBanSubject;
    address internal _synthBanUser;

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
        // A6: the TM authority arm resolves creator (lens 5) and organizer
        // (lens 11) hats through _authorityHoldsAny (pure isMember, no perm key), and HybridVoting
        // resolves each voting-class hatId via activeMemberSince. All three are AUTHORITY SUBJECTS
        // post-cutover — omitting them disenfranchises voters / breaks TM create+organize. They are
        // pure-membership subjects, so discovery+seeding (no perm key) is the complete fix.
        _addArray(_tmLensHats(s, 5)); // creator hats
        _addArray(_tmLensHats(s, 11)); // organizer hats
        _addArray(_hvClassHats(s)); // HybridVoting voting-class hats
    }

    function _tmPermissionHats(OrgSpec memory s) internal view returns (uint256[] memory) {
        return _tmLensHats(s, 6);
    }

    function _tmLensHats(OrgSpec memory s, uint8 t) internal view returns (uint256[] memory) {
        try ITMMig(s.tm).getLensData(t, "") returns (bytes memory raw) {
            return abi.decode(raw, (uint256[]));
        } catch {
            return new uint256[](0);
        }
    }

    /// @dev Flatten every HybridVoting voting-class hatId (union across classes) — each is an
    ///      adopted-verbatim authority subject on the HV tally arm.
    function _hvClassHats(OrgSpec memory s) internal view returns (uint256[] memory out) {
        try IHVClasses(s.hv).getClasses() returns (IHVClasses.ClassCfg[] memory cs) {
            uint256 total;
            for (uint256 i; i < cs.length; ++i) {
                total += cs[i].hatIds.length;
            }
            out = new uint256[](total);
            uint256 k;
            for (uint256 i; i < cs.length; ++i) {
                for (uint256 j; j < cs[i].hatIds.length; ++j) {
                    out[k++] = cs[i].hatIds[j];
                }
            }
        } catch {
            out = new uint256[](0);
        }
    }

    /*═══════════════════════════════ Live hat record adoption (R1) ═══════════════════════════════*/

    /// @dev maxMembers adopts the legacy hat's maxSupply VERBATIM (R1) — the honest live cap, neither
    ///      tightened to the current count nor guessed-unlimited. Hats guarantees supply ≤ maxSupply, so
    ///      the seeded memberCount is always ≤ maxMembers (SEED INVARIANT holds).
    function _hatMaxSupply(uint256 id) internal view returns (uint32) {
        (, uint32 maxSupply,,,,,,,) = IHatsMin(HATS).viewHat(id);
        return maxSupply;
    }

    /// @dev Role name adopts the live hat details; falls back to "Role#N" when the
    ///      legacy hat carries an empty details string.
    function _hatName(uint256 id, string memory fallbackName) internal view returns (string memory) {
        (string memory details,,,,,,,,) = IHatsMin(HATS).viewHat(id);
        return bytes(details).length == 0 ? fallbackName : details;
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
    ///         front-run grief close). The proxy is created via
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
        // (executor/orgId/paused only — front-run grief close). So batch 1 does NOT call
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
        //     The admin grant is STICKY (delegable=false, R5): a delegated CAP_REMOVE
        //     manager must never be able to clear the Executor's admin membership (org lock-out).
        _pushAdminSubject(authority, topHat);
        _pushSeedSlice(authority, topHat, _single(s.executor), false);

        // (1) Role subjects (maxMembers=0 during seeding; tightened after memberships).
        _pushRoleSubjects(authority);

        // (2) LIVE-ADOPTED default eligibility (A1). Do NOT force the
        //     QuickJoin member role open: probe the LEGACY EligibilityModule default for a FRESH address
        //     per subject and seed default-ALLOW ONLY where the gate is genuinely open TODAY. DP's member
        //     hat is open (true); Test6's (zk-email) and KUBI's (vouch) member hats deny a fresh address
        //     (false) — force-opening them made org membership permissionlessly claimable post-cutover
        //     (a stranger could authority.claim() the member subject with sponsored gas). Adopting the
        //     live verdict keeps QuickJoin/claim succeeding exactly where it does today and failing where
        //     it fails today (the mint/claim gate then denies the ineligible fresh address, as legacy Hats
        //     + EM do). QJ_AUTOJOIN stays attached to the legacy QJ member hats (below): with the correct
        //     deny-default the post-cutover mint reverts precisely where legacy hats.mintHat reverts.
        _seedLiveDefaults(s, authority);

        // (3) SUBJECT_RENAME from live metadataAdmin wearership.
        _pushPerm(authority, _metadataAdminHat, AccessV2PermKeys.SUBJECT_RENAME, _boolWord());

        // (4) Perm table from the audited module inventory.
        _buildPerms(s, authority);

        /*── Batch 2+: memberships → tighten → BANS → vouch → email ──*/
        _newBatch();
        _buildMembershipsAndTighten(s, authority, candidates);
        _buildBans(s, authority, candidates);
        _buildVouch(s, authority, candidates);
        if (s.zkEmailInvites != address(0)) _buildEmail(s, authority, candidates);

        return _batches;
    }

    /// @dev A1 (live-default adoption): seed each subject's default-ALLOW verdict from the LIVE legacy
    ///      EligibilityModule (a FRESH address's getWearerRules().eligible == the subject default). The
    ///      admin (topHat) subject is intentionally skipped — it is deny-default with the Executor as its
    ///      sole EXPLICIT member (root-by-address). Only default-ALLOW is emitted (the authority default
    ///      is already deny), so a gated legacy role stays gated post-cutover.
    ///
    ///      T7 — TITLED-ROLE SUPPRESSION, spec §2 DEFAULT ("Open roles = default-ALLOW
    ///      + user claim (QuickJoin keeps working); TITLED roles = deny-by-default + explicit grants").
    ///      Legacy eligibility != legacy wearing: an EM-default-open verdict on a hat with NO permissionless
    ///      mint channel (anything other than the QuickJoin member role) was never self-assumable — wearing
    ///      it required an executor/EM mint, i.e. governance. MembershipAuthority.claim() has no such second
    ///      gate: default-ALLOW alone makes the subject permissionlessly claimable by any address (with
    ///      sponsored gas). Adopting the legacy default verbatim on a titled hat is therefore a WIDENING,
    ///      not parity. This is live TODAY, not hypothetical: Test6's "Treasurer" subject probes
    ///      getWearerRules == getWearerStatus == (true,true) for a fresh address on the deployed EM
    ///      (0xf01F2b…8c8B) — adopting it would have shipped a permissionless Treasurer grab.
    ///      Suppressed subjects lose NOTHING at cutover: every current wearer is ported with an explicit
    ///      seeded Grant (_pushSeedSlice) and CutoverVerifier pins hatSupply, so no wearer rides the default.
    ///      Post-cutover appointment goes through the governance path (grantRole, then mintHat) exactly as
    ///      the legacy executor-gated mint did. The suppression is LOUD (per-subject log + count) and the
    ///      matching probe (_probeOpenSubjectStrangers) proves both arms on the authority afterwards.
    function _seedLiveDefaults(OrgSpec memory s, address authority) internal {
        uint256 topHat = _topHatId(s);
        // T2: the recorded expectation is checked HERE, at seed time, against the live gate — before a
        // single default is emitted. A silent live-state change now fails loudly instead of seeding the
        // other arm and being "proved" correct by a probe reading the same oracle.
        _assertRecordedMemberGate(s);
        uint256 opened;
        uint256 suppressed;
        for (uint256 i; i < _subjects.length; ++i) {
            uint256 subject = _subjects[i];
            if (subject == topHat) continue;
            if (!_liveDefaultAllow(s, subject)) continue;
            if (subject != _memberSubject) {
                console.log("  [T7] TITLED role is EM-default-OPEN legacy-side; seeding deny (not claimable):");
                console.log("       subject:", subject);
                suppressed++;
                continue;
            }
            // _assertRecordedMemberGate already pinned this against the recorded catalog constant.
            require(s.expectOpenMember, "open member default without the recorded OPEN expectation");
            _push(authority, abi.encodeCall(IMembershipAuthority.setSubjectDefault, (subject, true, false)));
            opened++;
        }
        console.log("  [T7] default-ALLOW seeded (open member role):", opened);
        console.log("       titled roles suppressed (legacy-open, no permissionless mint channel):", suppressed);
    }

    /// @dev The LIVE default eligibility verdict for `subject`: probe the legacy EM with a FRESH,
    ///      never-seen address (deterministic per org+subject). A fresh address has no explicit rule, so
    ///      getWearerRules returns the subject's DEFAULT rule flags — .eligible is the open/gated verdict.
    function _liveDefaultAllow(OrgSpec memory s, uint256 subject) internal view returns (bool) {
        try IEMMig(s.eligibilityModule).getWearerRules(_freshProbeAddr(s, subject), subject) returns (bool e, bool) {
            return e;
        } catch {
            return false;
        }
    }

    /// @dev The deterministic never-seen address the A1 default probes use for `subject`.
    function _freshProbeAddr(OrgSpec memory s, uint256 subject) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(s.orgId, subject, "live-default-probe")))));
    }

    /// @dev T2: reconcile the CATALOG-RECORDED member-gate constant against the LIVE
    ///      EligibilityModule, in BOTH oracle shapes. (1) The recorded `expectOpenMember` must equal the
    ///      raw per-wearer default verdict the seeder acts on. (2) The raw rule verdict must agree with
    ///      the EM's COMBINED getWearerStatus for the same fresh address — the raw-vs-combined divergence
    ///      the A3 ban logic documents (and KUBI's kicks exhibit) would otherwise let a (eligible=true,
    ///      standing=false) legacy-CLOSED role be seeded default-ALLOW. Both are require()s, not probes:
    ///      a divergence must stop the ceremony, not silently pick the other arm.
    function _assertRecordedMemberGate(OrgSpec memory s) internal view {
        if (_memberSubject == 0) {
            require(!s.expectOpenMember, "catalog records OPEN member gate but org has no QuickJoin member subject");
            console.log("  [T2] recorded member gate: n/a (governance-only org, no member subject)");
            return;
        }
        address fresh = _freshProbeAddr(s, _memberSubject);
        (bool rawEligible, bool rawStanding) = IEMMig(s.eligibilityModule).getWearerRules(fresh, _memberSubject);
        (bool cEligible, bool cStanding) = IEMMig(s.eligibilityModule).getWearerStatus(fresh, _memberSubject);
        require(rawEligible == s.expectOpenMember, "LIVE member gate diverged from the RECORDED expectation (A1)");
        require(
            (rawEligible && rawStanding) == (cEligible && cStanding),
            "member-gate oracle shape: raw wearer rules disagree with the EM COMBINED verdict"
        );
        require(
            s.expectOpenMember == (cEligible && cStanding),
            "RECORDED member gate disagrees with the EM COMBINED verdict for a fresh address"
        );
        console.log("  [T2] recorded member gate matches live (raw + combined). openMember:", s.expectOpenMember);
    }

    /// @dev A3: port legacy explicit-DENY wearer rules (bans/kicks) as
    ///      governance-authored STICKY RuleKind.Ban rows. §6 step 2 lists "bans" as seed content; without
    ///      this every legacy ban evaporates and (on any default-ALLOW subject) the banned user can
    ///      sponsored-claim straight back in. Enumerated candidates × subjects on the fork: a ban is an
    ///      EXPLICIT per-wearer rule (hasSpecificWearerRules) whose verdict is NOT (eligible && standing).
    ///      Sticky (delegable=false) so a delegated CAP_REMOVE manager can never clear it. Returns the count.
    function _buildBans(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        returns (uint256 total)
    {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address[] memory tmp = new address[](candidates.length);
            uint256 n;
            for (uint256 j; j < candidates.length; ++j) {
                if (_isLegacyBanned(s, candidates[j], subject)) tmp[n++] = candidates[j];
            }
            for (uint256 off; off < n; off += SEED_CHUNK) {
                uint256 len = n - off;
                if (len > SEED_CHUNK) len = SEED_CHUNK;
                uint256[] memory subs = new uint256[](len);
                address[] memory users = new address[](len);
                AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](len);
                bool[] memory del = new bool[](len);
                for (uint256 k; k < len; ++k) {
                    subs[k] = subject;
                    users[k] = tmp[off + k];
                    kinds[k] = AccessV2Types.RuleKind.Ban;
                    del[k] = false; // sticky governance ban
                }
                _push(authority, abi.encodeCall(IMembershipAuthority.seedRules, (subs, users, kinds, del)));
                total += len;
            }
        }
    }

    /// @dev True iff `user` carries a legacy EXPLICIT deny/kick rule on `subject`. getWearerRuleFlags is
    ///      ABSENT on the deployed EM bytecode (it reverts), so provenance is read via
    ///      hasSpecificWearerRules (an explicit rule exists) + getWearerRules (its verdict). A current
    ///      member seeded with an explicit Grant returns (true,true) here → not a ban; a vouch-eligible
    ///      member has NO explicit rule → not a ban; only a genuine deny/kick is flagged.
    function _isLegacyBanned(OrgSpec memory s, address user, uint256 subject) internal view returns (bool) {
        // A ban is a legacy explicit rule that leaves the wearer EFFECTIVELY ineligible today, so it must
        // NOT overlap the seeded member set. Two facts, both live-verified:
        //  (1) getWearerRules(user, subject) exposes the RAW per-wearer rule flags, but the EM's COMBINED
        //      getWearerStatus (rule + vouch/email/hierarchy) is what decides membership. A user can carry
        //      a raw deny (eligible==false) yet remain a combined-eligible member (e.g. a standing-only
        //      rule, or a vouch override). Seeding a Ban for such a user would overwrite their seeded Grant
        //      → accepted-but-ineligible (SEED INVARIANT trip). So EXCLUDE anyone the EM deems eligible.
        //      NOTE: this MUST use getWearerStatus (toggle-INDEPENDENT), NOT hats.isWearerOfHat: the ban set
        //      is re-derived by the rehearsal AFTER the cutover toggle-off, at which point isWearerOfHat is
        //      false for every wearer and would misclassify combined-eligible members as bans. At build time
        //      (toggle active, candidates hold balance) getWearerStatus.eligible ⟺ isWearerOfHat, so the
        //      seeded ban set is unchanged; only the assert-time re-derivation is made stable.
        //  (2) A genuine kick/ban is a candidate carrying an explicit deny (hasSpecificWearerRules &&
        //      raw eligible==false) whom the EM deems combined-INELIGIBLE. getWearerRuleFlags is absent on
        //      the deployed EM (reverts), hence the hasSpecificWearerRules + getWearerRules pair.
        try IEMMig(s.eligibilityModule).getWearerStatus(user, subject) returns (bool combinedEligible, bool) {
            if (combinedEligible) return false;
        } catch {
            return false;
        }
        try IEMMig(s.eligibilityModule).hasSpecificWearerRules(user, subject) returns (bool hasRule) {
            if (!hasRule) return false;
            (bool eligible,) = IEMMig(s.eligibilityModule).getWearerRules(user, subject);
            return !eligible;
        } catch {
            return false;
        }
    }

    /*═══════════════════════════════ T3: SYNTHETIC-BAN DRILL ═══════════════════════════════*/

    /// @notice Inject a REAL legacy kick before the seed so the RuleKind.Ban porting path actually
    ///         executes against a live ban. Rationale: the behavior-preserving
    ///         EFFECTIVE-ban set is empty or near-empty on all four orgs, so `_buildBans` could
    ///         mis-encode RuleKind, drop chunks or seed nothing and every sim still PASSed — the
    ///         per-ban asserts ran ZERO times.
    /// @dev    Writes through the org's LIVE EligibilityModule admin surface (`setWearerEligibility`,
    ///         superAdmin == the org Executor — the same surface a real kick uses), pranked as the
    ///         Executor, and only ACCEPTS the pair when the module's COMBINED `getWearerStatus` actually
    ///         reports the wearer ineligible: on the deployed pre-FIX-0 EM an explicit deny is ADDITIVE
    ///         and can be vouch/hierarchy-overridden, which is precisely why the live effective-ban set
    ///         is empty. Candidates that would break the rest of the ceremony are skipped (the Executor
    ///         itself, HybridVoting creator-hat wearers — the governed sims need one to author
    ///         proposals — and any wearer who is the SOLE member of the subject).
    ///         Each attempt is snapshot-isolated so a non-effective deny leaves NO explicit rule behind.
    function _injectSyntheticBan(OrgSpec memory s, address[] memory candidates) internal {
        if (!s.banDrill) return;
        uint256 topHat = _topHatId(s);
        uint256 foundSubject;
        address foundUser;
        for (uint256 si; si < _subjects.length && foundSubject == 0; ++si) {
            uint256 subject = _subjects[si];
            if (subject == topHat) continue;
            address[] memory members = _currentMembers(s, subject, candidates);
            if (members.length < 2) continue; // never empty a subject
            for (uint256 j; j < members.length; ++j) {
                address user = members[j];
                if (user == s.executor) continue;
                uint256 snap = vm.snapshotState();
                bool wrote = _kickOnLegacyEM(s, user, subject);
                if (!wrote) {
                    vm.revertToState(snap);
                    continue;
                }
                // Accept only a kick that is EFFECTIVE (combined-ineligible, flagged by the ban scanner,
                // and no longer a Hats wearer) AND that leaves the org governable — the governed sims
                // still need a live HybridVoting creator-hat wearer among the candidates to author the
                // seed/cutover proposals (on KUBI every member wears a creator hat, so excluding all of
                // them upfront would leave no drill target at all).
                bool effective = !_emCombinedEligible(s, user, subject) && _isLegacyBanned(s, user, subject)
                    && !IHatsMin(HATS).isWearerOfHat(user, subject) && _anyHvCreatorAmong(s, candidates);
                if (effective) {
                    foundSubject = subject;
                    foundUser = user;
                    break; // keep the state: the kick stands for the rest of the ceremony
                }
                vm.revertToState(snap);
            }
        }
        require(foundSubject != 0, "T3: synthetic-ban drill could not make any explicit deny EFFECTIVE");
        _synthBanSubject = foundSubject;
        _synthBanUser = foundUser;
        console.log("  [T3] synthetic ban injected on subject:", foundSubject);
        console.log("       kicked wearer:", foundUser);
    }

    /// @dev A REAL governance kick on the org's LIVE EligibilityModule, pranked as the superAdmin
    ///      (the org Executor). All three writes are needed on the DEPLOYED pre-FIX-0 bytecode: the
    ///      explicit (false,false) rule is only the hierarchy arm there, so a wearer who meets the vouch
    ///      quorum (KUBI/Poa: every non-admin subject is vouch-configured) stays eligible until
    ///      clearWearerVouches zeroes the count. clearEmailVerified is belt-and-braces (the email path is
    ///      already skipped once an explicit rule exists). Returns false if the deny itself did not land.
    function _kickOnLegacyEM(OrgSpec memory s, address user, uint256 subject) internal returns (bool) {
        vm.prank(s.executor);
        try IEMWriteMig(s.eligibilityModule).setWearerEligibility(user, subject, false, false) {}
        catch {
            return false;
        }
        vm.prank(s.executor);
        try IEMWriteMig(s.eligibilityModule).clearWearerVouches(user, subject) {} catch {}
        vm.prank(s.executor);
        try IEMWriteMig(s.eligibilityModule).clearEmailVerified(user, subject) {} catch {}
        return true;
    }

    function _emCombinedEligible(OrgSpec memory s, address user, uint256 subject) internal view returns (bool) {
        try IEMMig(s.eligibilityModule).getWearerStatus(user, subject) returns (bool e, bool) {
            return e;
        } catch {
            return false;
        }
    }

    /// @dev At least one candidate still wears a HybridVoting creator hat (the governed sims need one to
    ///      author proposals). Evaluated AFTER the drill's kick lands, inside the snapshot.
    function _anyHvCreatorAmong(OrgSpec memory s, address[] memory candidates) internal view returns (bool) {
        uint256[] memory ch = IHVMig(s.hv).creatorHats();
        for (uint256 i; i < ch.length; ++i) {
            for (uint256 j; j < candidates.length; ++j) {
                if (IHatsMin(HATS).isWearerOfHat(candidates[j], ch[i])) return true;
            }
        }
        return false;
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
        names[0] = _hatName(topHat, "Admin"); // live details, fallback "Admin"
        maxm[0] = _hatMaxSupply(topHat); // legacy maxSupply verbatim (R1) — topHat is 1
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
            names[i - 1] = _hatName(_subjects[i], string.concat("Role#", vm.toString(i))); // live details
            maxm[i - 1] = _hatMaxSupply(_subjects[i]); // legacy maxSupply verbatim (R1)
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
        // A2: TM permission table — REAL masks, per-project rows.
        _seedTmPerms(s, authority);
    }

    /// @dev A2: seed the LIVE TaskManager permission table from fixtures/<org>.tmperms.json — NOT a
    ///      blanket 0xFF. The old builder wrote 0xFF at ctx 0 for every permission hat (org-wide TM
    ///      privilege escalation) and dropped all per-project rolePermProj overrides. This ports:
    ///        (1) each hat's REAL global mask at ctx 0 (the low-8-bit rolePermGlobal value); and
    ///        (2) every nonzero per-project override at ctx = bytes32(pid+1) with inherit=FALSE, so
    ///            the authority arm RESOLVES it exactly like the legacy `_permMask`
    ///            (`rolePermProj[pid][hat] != 0 ? rolePermProj : rolePermGlobal`, OR-folded across the
    ///            hats a user wears — TaskManager.sol:1481-1494 / freeze amendment W4 ctx = pid+1).
    ///      Zero-mask project rows are absent from the fixture (they fall through to global; §4). Only
    ///      discovered subjects (lens-6 permission hats) are seeded — a fixture hat with no live perm
    ///      would not be a subject, so isMember is false and it contributes nothing regardless.
    function _seedTmPerms(OrgSpec memory s, address authority) internal {
        _loadTmPerms(s.name);
        // (1) Global rows at ctx 0 — the REAL mask (skip zero: contributes nothing under the OR fold).
        for (uint256 i; i < _tmGlobalHats.length; ++i) {
            uint256 hat = _tmGlobalHats[i];
            uint256 mask = _tmGlobalMasks[i] & 0xFF;
            if (hat == 0 || mask == 0 || !_seen[hat]) continue;
            _pushPerm(authority, hat, AccessV2PermKeys.TM_PERMS, AccessV2PermKeys.EXISTS_BIT | mask);
        }
        // (2) Per-project override rows at ctx = pid+1, inherit=FALSE (legacy proj REPLACES global).
        //     Not via _pushPerm (its dedup is keyed (subject,key) and ctx-blind); raw _push with the ctx.
        for (uint256 i; i < _tmProjPids.length; ++i) {
            uint256 hat = _tmProjHats[i];
            uint256 mask = _tmProjMasks[i] & 0xFF;
            if (hat == 0 || mask == 0 || !_seen[hat]) continue;
            bytes32 ctx = bytes32(_tmProjPids[i] + 1); // W4: TM ids start at 0, ctx 0 is global → +1
            _push(
                authority,
                abi.encodeCall(
                    IMembershipAuthority.setPerm,
                    (hat, AccessV2PermKeys.TM_PERMS, ctx, AccessV2PermKeys.EXISTS_BIT | mask)
                )
            );
        }
    }

    /// @dev Load fixtures/<org>.tmperms.json into the parallel arrays. Idempotent within a run (guarded).
    ///      Fields are parsed as uint arrays (hat/pid values are quoted hex, masks are 0..255 numbers —
    ///      vm.parseJsonUintArray handles both). A missing fixture is fatal: the TM perm table is
    ///      mandatory §6 seed content, and silently seeding nothing would repeat the escalation the fix
    ///      exists to close.
    function _loadTmPerms(string memory org) internal {
        if (_tmPermsLoaded) return;
        delete _tmGlobalHats;
        delete _tmGlobalMasks;
        delete _tmProjPids;
        delete _tmProjHats;
        delete _tmProjMasks;
        string memory path =
            string.concat(vm.projectRoot(), "/script/accessv2/fixtures/", _lowerName(org), ".tmperms.json");
        string memory json = vm.readFile(path);
        _tmGlobalHats = vm.parseJsonUintArray(json, ".globalHats");
        _tmGlobalMasks = vm.parseJsonUintArray(json, ".globalMasks");
        _tmProjPids = vm.parseJsonUintArray(json, ".projPids");
        _tmProjHats = vm.parseJsonUintArray(json, ".projHats");
        _tmProjMasks = vm.parseJsonUintArray(json, ".projMasks");
        _tmPermsLoaded = true;
    }

    /*═══════════════ T5: INDEPENDENT legacy TaskManager oracle ═══════════════*/
    /*
     * The A2 probe compared the seeded authority state against `_legacyExpectedMask`, folded from the
     * SAME fixture that seeded it — a shared-source tautology that also omitted legacy `_permMask`'s
     * `permissionHatIds` gate, so a stale fixture row for a delisted hat would be seeded as a live TM
     * grant and "proved" correct by both sides carrying it.
     *
     * The oracle below is read from the LIVE TaskManager's OWN ERC-7201 storage (rolePermGlobal /
     * rolePermProj / permissionHatIds) plus live Hats wearership, i.e. exactly the inputs
     * TaskManager._permMask's legacy arm folds — nothing fixture-derived. Slot offsets are anchored by
     * requiring the storage-read permissionHatIds to equal getLensData(6) before any mask is trusted.
     */
    bytes32 internal constant TM_SLOT = keccak256("poa.taskmanager.storage");
    uint256 internal constant TM_F_ROLE_PERM_GLOBAL = 6; // Layout field index (append-only struct)
    uint256 internal constant TM_F_ROLE_PERM_PROJ = 7;
    uint256 internal constant TM_F_PERMISSION_HATS = 8;

    // Oracle rows captured PRE-cutover (live Hats reads go dark after the toggle-off).
    address[] internal _tmOracleUsers;
    uint256[] internal _tmOraclePids;
    uint256[] internal _tmOracleMasks;
    bool[] internal _tmOracleShadow; // true = the row carries a per-project override for this user

    function _tmPermHatsLive(OrgSpec memory s) internal view returns (uint256[] memory out) {
        bytes32 lenSlot = bytes32(uint256(TM_SLOT) + TM_F_PERMISSION_HATS);
        uint256 len = uint256(vm.load(s.tm, lenSlot));
        out = new uint256[](len);
        uint256 start = uint256(keccak256(abi.encode(lenSlot)));
        for (uint256 i; i < len; ++i) {
            out[i] = uint256(vm.load(s.tm, bytes32(start + i)));
        }
    }

    function _tmGlobalMaskLive(OrgSpec memory s, uint256 hat) internal view returns (uint256) {
        return uint256(vm.load(s.tm, keccak256(abi.encode(hat, uint256(TM_SLOT) + TM_F_ROLE_PERM_GLOBAL)))) & 0xFF;
    }

    function _tmProjMaskLive(OrgSpec memory s, uint256 pid, uint256 hat) internal view returns (uint256) {
        bytes32 inner = keccak256(abi.encode(bytes32(pid), uint256(TM_SLOT) + TM_F_ROLE_PERM_PROJ));
        return uint256(vm.load(s.tm, keccak256(abi.encode(hat, inner)))) & 0xFF;
    }

    /// @dev The LEGACY effective mask for (`user`, `pid`) computed EXACTLY as TaskManager._permMask's
    ///      legacy arm does: fold over `permissionHatIds` (the gate the fixture-derived expectation
    ///      lacked), skip hats the user does not wear, `proj != 0 ? proj : global`. Live reads — call
    ///      BEFORE the cutover toggle-off.
    function _tmLiveMask(OrgSpec memory s, address user, uint256 pid) internal view returns (uint256 m) {
        uint256[] memory hats = _tmPermHatsLive(s);
        for (uint256 i; i < hats.length; ++i) {
            if (!IHatsMin(HATS).isWearerOfHat(user, hats[i])) continue;
            uint256 proj = _tmProjMaskLive(s, pid, hats[i]);
            m |= proj != 0 ? proj : _tmGlobalMaskLive(s, hats[i]);
        }
    }

    /// @dev Anchor the slot derivation: the storage-read permission-hat array must equal the contract's
    ///      own getLensData(6). If this ever fails the Layout was reordered and every mask below is junk.
    function _assertTmSlotDerivation(OrgSpec memory s) internal view {
        uint256[] memory fromStorage = _tmPermHatsLive(s);
        uint256[] memory fromLens = _tmLensHats(s, 6);
        require(fromStorage.length == fromLens.length, "T5: TM permissionHatIds slot derivation (length)");
        for (uint256 i; i < fromLens.length; ++i) {
            require(fromStorage[i] == fromLens[i], "T5: TM permissionHatIds slot derivation (element)");
        }
    }

    /// @notice Capture the INDEPENDENT legacy TM resolution for every (candidate, project) pair that
    ///         carries a per-project override row, plus a global-only pair on an override-free project.
    ///         Call PRE-cutover. The post-cutover probe replays these verbatim against the authority.
    function _captureTmOracle(OrgSpec memory s, address[] memory candidates) internal {
        _loadTmPerms(s.name);
        _assertTmSlotDerivation(s);
        delete _tmOracleUsers;
        delete _tmOraclePids;
        delete _tmOracleMasks;
        delete _tmOracleShadow;

        uint256[] memory permHats = _tmPermHatsLive(s);
        // (1) SHADOW rows — a LIVE per-project override for a permission hat a candidate actually wears.
        for (uint256 i; i < permHats.length; ++i) {
            uint256 hat = permHats[i];
            uint256 globalMask = _tmGlobalMaskLive(s, hat);
            for (uint256 r; r < _tmProjPids.length; ++r) {
                uint256 pid = _tmProjPids[r];
                uint256 projMask = _tmProjMaskLive(s, pid, hat);
                if (projMask == 0 || projMask == globalMask) continue; // no genuine shadow for this hat
                for (uint256 j; j < candidates.length; ++j) {
                    if (!IHatsMin(HATS).isWearerOfHat(candidates[j], hat)) continue;
                    _pushTmOracle(s, candidates[j], pid, true);
                }
            }
        }
        // (2) GLOBAL-ONLY — the same fold on a project id NO override row targets.
        uint256 unusedPid = _firstUnusedPid();
        for (uint256 i; i < permHats.length; ++i) {
            if (_tmGlobalMaskLive(s, permHats[i]) == 0) continue;
            for (uint256 j; j < candidates.length; ++j) {
                if (!IHatsMin(HATS).isWearerOfHat(candidates[j], permHats[i])) continue;
                _pushTmOracle(s, candidates[j], unusedPid, false);
            }
        }
        console.log("  [T5] independent TM oracle rows captured (live TM storage):", _tmOracleUsers.length);
    }

    function _pushTmOracle(OrgSpec memory s, address user, uint256 pid, bool shadow) internal {
        for (uint256 i; i < _tmOracleUsers.length; ++i) {
            if (_tmOracleUsers[i] == user && _tmOraclePids[i] == pid) return; // dedup
        }
        _tmOracleUsers.push(user);
        _tmOraclePids.push(pid);
        _tmOracleMasks.push(_tmLiveMask(s, user, pid));
        _tmOracleShadow.push(shadow);
    }

    /// @dev A project id (uint256) that NO fixture per-project row targets — its ctx (pid+1) has no
    ///      override for any hat, so resolution there is pure global-union.
    function _firstUnusedPid() internal view returns (uint256) {
        uint256 maxPid;
        for (uint256 i; i < _tmProjPids.length; ++i) {
            if (_tmProjPids[i] > maxPid) maxPid = _tmProjPids[i];
        }
        return maxPid + 1000; // comfortably past any real project id
    }

    /// @dev T5 fallback: no LIVE per-project override row is worn by any candidate, so the per-project
    ///      resolution path would never execute on this org. Inject one through the org's own TM admin
    ///      surface (`setProjectRolePerm`, executor-gated) on a project that already exists in the
    ///      fixture, for a permission hat a candidate wears — and mirror it into the in-memory fixture
    ///      rows so the seed builder ports it (i.e. exactly what a re-enumerated fixture would carry).
    ///      Returns true when a row was injected. Call BEFORE the seed batches are built.
    function _injectTmOverrideRow(OrgSpec memory s, address[] memory candidates) internal returns (bool) {
        uint256[] memory permHats = _tmPermHatsLive(s);
        if (_tmProjPids.length == 0 || permHats.length == 0) return false;
        uint256 pid = _tmProjPids[0];
        for (uint256 i; i < permHats.length; ++i) {
            uint256 hat = permHats[i];
            uint256 globalMask = _tmGlobalMaskLive(s, hat);
            uint256 newMask = globalMask == 0 ? 0x0F : (globalMask ^ 0x0F);
            if (newMask == 0 || newMask == globalMask) continue;
            bool worn;
            for (uint256 j; j < candidates.length && !worn; ++j) {
                worn = IHatsMin(HATS).isWearerOfHat(candidates[j], hat);
            }
            if (!worn) continue;
            vm.prank(s.executor);
            try ITMWriteMig(s.tm).setProjectRolePerm(bytes32(pid), hat, uint8(newMask)) {}
            catch {
                continue;
            }
            if (_tmProjMaskLive(s, pid, hat) != newMask) continue;
            _tmProjPids.push(pid);
            _tmProjHats.push(hat);
            _tmProjMasks.push(newMask);
            console.log("  [T5] injected a per-project override row (no live shadow existed). pid/hat:", pid, hat);
            return true;
        }
        return false;
    }

    /// @notice T5 non-vacuity guarantee: make sure the per-project override resolution path WILL execute
    ///         on this org. Call PRE-SEED. If no live override row is worn by any candidate, inject one.
    function _ensureTmOverrideRow(OrgSpec memory s, address[] memory candidates) internal {
        _loadTmPerms(s.name);
        _assertTmSlotDerivation(s);
        if (_liveShadowRowExists(s, candidates)) return;
        require(
            _injectTmOverrideRow(s, candidates),
            "T5: org has NO per-project override row worn by a candidate and none could be injected"
        );
    }

    function _liveShadowRowExists(OrgSpec memory s, address[] memory candidates) internal view returns (bool) {
        uint256[] memory permHats = _tmPermHatsLive(s);
        for (uint256 i; i < permHats.length; ++i) {
            uint256 hat = permHats[i];
            uint256 globalMask = _tmGlobalMaskLive(s, hat);
            for (uint256 r; r < _tmProjPids.length; ++r) {
                uint256 projMask = _tmProjMaskLive(s, _tmProjPids[r], hat);
                if (projMask == 0 || projMask == globalMask) continue;
                for (uint256 j; j < candidates.length; ++j) {
                    if (IHatsMin(HATS).isWearerOfHat(candidates[j], hat)) return true;
                }
            }
        }
        return false;
    }

    /// @dev The fixture global mask for `hat` (0 if none). Small linear scans (a few rows per org).
    function _fixtureGlobalMask(uint256 hat) internal view returns (uint256) {
        for (uint256 i; i < _tmGlobalHats.length; ++i) {
            if (_tmGlobalHats[i] == hat) return _tmGlobalMasks[i] & 0xFF;
        }
        return 0;
    }

    /// @dev The fixture per-project override mask for (pid, hat) (0 if none).
    function _fixtureProjMask(uint256 pid, uint256 hat) internal view returns (uint256) {
        for (uint256 i; i < _tmProjPids.length; ++i) {
            if (_tmProjPids[i] == pid && _tmProjHats[i] == hat) return _tmProjMasks[i] & 0xFF;
        }
        return 0;
    }

    /// @dev The LEGACY effective TaskManager mask for `user` on project `pid`, computed INDEPENDENTLY of
    ///      the seed builder from the fixture + the pre-cutover wearer snapshot (_expectMember). Mirrors
    ///      TaskManager._permMask legacy arm EXACTLY: for each permission hat the user wore,
    ///      `proj != 0 ? proj : global`, OR-folded. The rehearsal probe compares the post-cutover
    ///      authority resolution against this — a seed-builder ctx/inherit bug diverges (non-tautological).
    function _legacyExpectedMask(uint256 pid, address user) internal view returns (uint256 m) {
        for (uint256 i; i < _tmGlobalHats.length; ++i) {
            uint256 hat = _tmGlobalHats[i];
            if (!_expectMember[hat][user]) continue;
            uint256 proj = _fixtureProjMask(pid, hat);
            m |= proj != 0 ? proj : (_tmGlobalMasks[i] & 0xFF);
        }
        // Hats that appear ONLY in per-project rows (no global row) also contribute their proj mask.
        for (uint256 i; i < _tmProjHats.length; ++i) {
            uint256 hat = _tmProjHats[i];
            if (_tmProjPids[i] != pid || !_expectMember[hat][user]) continue;
            if (_fixtureGlobalMask(hat) != 0) continue; // already folded in the global loop above
            m |= _tmProjMasks[i] & 0xFF;
        }
    }

    function _lowerName(string memory v) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
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
            // maxMembers is NOT tightened here: R1 adopts the legacy hats.viewHat(id).maxSupply
            // VERBATIM at subject-creation time (_pushRoleSubjects / _pushAdminSubject). That is the
            // honest live cap — headroom above the current count — so post-cutover grant/claim/vouch
            // on titled roles does NOT revert SubjectFull, and it never produces the linted
            // VouchWithMaxMembers anti-pattern. The open member role's maxSupply
            // is likewise adopted verbatim (QuickJoin was already bounded by it legacy-side).
        }
    }

    function _buildVouch(OrgSpec memory s, address authority, address[] memory candidates) internal {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            IEMMig.VouchCfg memory vc = IEMMig(s.eligibilityModule).getVouchConfig(subject);
            bool enabled = (vc.flags & 0x01) != 0;
            if (!enabled || vc.quorum == 0) continue;
            // A4 (C1): a legacy SELF-voucher config (voucherSubject == subject) — KUBI's
            // Executives-vouch-Executives officer gate — is a REAL live semantic the authority now
            // ACCEPTS (emits the SelfVoucher lint, no WiringIncompatible revert). It IS ported verbatim
            // (configureVouchAttestor(subject, quorum, subject) below + per-voucher records). Only a
            // genuinely EMPTY voucher subject (membershipHatId == 0) is skipped — there is nothing to
            // port, and members hold seeded explicit grants regardless.
            if (vc.membershipHatId == 0) continue;
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
        names[0] = _hatName(id, "VoucherRole"); // live details, fallback "VoucherRole"
        maxm[0] = _hatMaxSupply(id); // legacy maxSupply verbatim (R1)
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
    ///         Ordering: DELTA-SEED (A5, §6 first element) → router BIND (before toggle-off) →
    ///         setMembershipAuthority ×8 (incl. Executor self-target) → unpause → legacy toggle-off →
    ///         in-batch CutoverVerifier.verify (LAST). announceWinner needs the per-org runbook
    ///         --gas-limit (KUBI 5M, others 4M). Returns the batch and the index of the router-bind call
    ///         (bindIndex == number of delta calls; 0 when there is no drift).
    function _buildCutoverBatch(OrgSpec memory s, address authority, address router, address[] memory candidates)
        internal
        view
        returns (IExecutor.Call[] memory batch, uint256 bindIndex)
    {
        uint256 domain = _topHatDomain(s);
        uint256[] memory roleHats = _subjects; // toggle-off targets (adopted legacy ids)
        bool[] memory offs = new bool[](roleHats.length);
        // offs default false → setHatStatus(false)

        // A5 (§6 step-3): DELTA-SEED first — legacy wearers who joined
        // since the authority was seeded (isWearerOfHat but NOT yet an authority member) are granted +
        // accepted here, INSIDE the atomic cutover, so they are not silently toggled off unported. When
        // there is no drift the delta is EMPTY (bindIndex == 0, the pre-A5 shape). This is executable —
        // seedRules/seedMemberships are executor-gated and pause-exempt, and run before the unpause.
        (IExecutor.Call[] memory delta,) = _buildDeltaSeed(s, authority, candidates);

        // The batch is `delta` + 11 core calls + 1 trailing CutoverVerifier.verify. The verifier is
        // MANDATORY: an unverified cutover batch must be UNBUILDABLE —
        // the silent `withVerify` omission previously let GenerateBatches emit production JSON with
        // NO in-batch verification at all. Every caller must wire _verifier first.
        require(_verifier != address(0), "CutoverVerifier not wired (_verifier unset) - refusing to build cutover");
        batch = new IExecutor.Call[](delta.length + 12);
        require(batch.length <= MAX_CALLS, "cutover batch exceeds Executor MAX_CALLS (freeze legacy joins)");
        uint256 k;

        // 0. DELTA-SEED slices (the §6 first cutover element).
        for (uint256 i; i < delta.length; ++i) {
            batch[k++] = delta[i];
        }

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

        // 11. Legacy-hat TOGGLE-OFF (one batched call) — AFTER the bind, so no hub/admin gap.
        batch[k++] = IExecutor.Call({
            target: s.toggleModule, value: 0, data: abi.encodeCall(IToggleMig.batchSetHatStatus, (roleHats, offs))
        });

        // 12. §6 IN-BATCH VERIFICATION (C4) — the LAST call: CutoverVerifier.verify require()s, THROUGH
        //     the just-bound router, (a) every subject binds to THIS authority (no spoof), (b) authority
        //     unpaused, (c) per-subject memberCount == the generation-time count (seed→cutover DRIFT
        //     reverts the whole batch — the on-chain regenerate-before-cutover guard, A5) AND
        //     memberCount <= canonical Hats supply, (d) the admin (topHat, subjects[0]) resolves to the
        //     org Executor + is active through the router. A failed check reverts the ENTIRE batch, so
        //     the runbook's "the cutover batch itself require()s counts and router-through resolution"
        //     is now TRUE (was previously sim-only).
        {
            (uint256[] memory subjects, uint32[] memory expectedCounts, uint32[] memory expectedSupplies) =
                _cutoverExpectedState(s, authority, candidates);
            batch[k++] = IExecutor.Call({
                target: _verifier,
                value: 0,
                data: abi.encodeCall(
                    ICutoverVerifierMig.verify, (s.orgId, authority, router, subjects, expectedCounts, expectedSupplies)
                )
            });
        }

        require(k == batch.length, "batch length mismatch");
    }

    /// @dev A5: the DELTA-SEED calls — for each subject, legacy wearers (isWearerOfHat, in `candidates`)
    ///      who are NOT yet authority members get one seedRules(Grant)+seedMemberships pair (the SEED
    ///      INVARIANT unit). Returns the calls and the count of subjects carrying a delta. Empty when the
    ///      authority already covers every live wearer (no drift → bindIndex 0, the pre-A5 batch shape).
    function _buildDeltaSeed(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (IExecutor.Call[] memory delta, uint256 subjectsWithDelta)
    {
        uint256 n = _subjects.length;
        address[][] memory perNew = new address[][](n);
        for (uint256 i; i < n; ++i) {
            perNew[i] = _deltaMembers(s, authority, _subjects[i], candidates);
            if (perNew[i].length > 0) subjectsWithDelta++;
        }
        delta = new IExecutor.Call[](2 * subjectsWithDelta);
        uint256 di;
        for (uint256 i; i < n; ++i) {
            address[] memory newM = perNew[i];
            if (newM.length == 0) continue;
            uint256 subject = _subjects[i];
            bool delegable = (subject == _memberSubject); // member-class delegable, officer-class sticky
            AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](newM.length);
            bool[] memory del = new bool[](newM.length);
            uint256[] memory subs = new uint256[](newM.length);
            for (uint256 j; j < newM.length; ++j) {
                kinds[j] = AccessV2Types.RuleKind.Grant;
                del[j] = delegable;
                subs[j] = subject;
            }
            delta[di++] = IExecutor.Call({
                target: authority,
                value: 0,
                data: abi.encodeCall(IMembershipAuthority.seedRules, (subs, newM, kinds, del))
            });
            delta[di++] = IExecutor.Call({
                target: authority, value: 0, data: abi.encodeCall(IMembershipAuthority.seedMemberships, (subs, newM))
            });
        }
    }

    /// @dev Legacy wearers of `subject` among `candidates` who are NOT yet authority members (the delta).
    function _deltaMembers(OrgSpec memory s, address authority, uint256 subject, address[] memory candidates)
        internal
        view
        returns (address[] memory)
    {
        address[] memory legacyMembers = _currentMembers(s, subject, candidates);
        IMembershipAuthority a = IMembershipAuthority(authority);
        address[] memory tmp = new address[](legacyMembers.length);
        uint256 c;
        for (uint256 j; j < legacyMembers.length; ++j) {
            if (!a.isMember(subject, legacyMembers[j])) tmp[c++] = legacyMembers[j];
        }
        address[] memory out = new address[](c);
        for (uint256 j; j < c; ++j) {
            out[j] = tmp[j];
        }
        return out;
    }

    /// @dev Generation-time state baked into the cutover verifier: per-subject expectedCounts (authority
    ///      memberCount AFTER the in-batch delta applies) and expectedSupplies (live canonical Hats
    ///      supply). subjects[0] is the admin (topHat) id, as the CutoverVerifier requires. Authority-side
    ///      drift trips MemberCountDrift; a fresh LEGACY wearer (invisible to authority memberCount) trips
    ///      SupplyDrift — together the on-chain regenerate-with-delta-before-cutover guard (A5).
    function _cutoverExpectedState(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (uint256[] memory subjects, uint32[] memory expectedCounts, uint32[] memory expectedSupplies)
    {
        uint256 n = _subjects.length;
        subjects = new uint256[](n);
        expectedCounts = new uint32[](n);
        expectedSupplies = new uint32[](n);
        IMembershipAuthority a = IMembershipAuthority(authority);
        for (uint256 i; i < n; ++i) {
            uint256 subject = _subjects[i];
            subjects[i] = subject;
            uint256 deltaCount = _deltaMembers(s, authority, subject, candidates).length;
            expectedCounts[i] = uint32(a.memberCount(subject) + deltaCount);
            expectedSupplies[i] = IHatsSupplyMig(HATS).hatSupply(subject);
        }
    }

    function _setAuth(address module, address authority) internal pure returns (IExecutor.Call memory) {
        return IExecutor.Call({
            target: module, value: 0, data: abi.encodeWithSignature("setMembershipAuthority(address)", authority)
        });
    }
}
