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
    // and details (the live role name, specOrder-10) verbatim.
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
///      (activeMemberSince) post-cutover, so they must be discovered/seeded (finding
///      seedCompleteness-6). Struct field order MUST match HybridVoting.ClassConfig exactly.
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

    // A2 (specOrder-9 / seedCompleteness-0): the LIVE TaskManager permission table, enumerated by
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
        // A6 (seedCompleteness-6): the TM authority arm resolves creator (lens 5) and organizer
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

    /*═══════════════════════════════ Live hat record adoption (R1, specOrder-10) ═══════════════════════════════*/

    /// @dev maxMembers adopts the legacy hat's maxSupply VERBATIM (R1) — the honest live cap, neither
    ///      tightened to the current count nor guessed-unlimited. Hats guarantees supply ≤ maxSupply, so
    ///      the seeded memberCount is always ≤ maxMembers (SEED INVARIANT holds).
    function _hatMaxSupply(uint256 id) internal view returns (uint32) {
        (, uint32 maxSupply,,,,,,,) = IHatsMin(HATS).viewHat(id);
        return maxSupply;
    }

    /// @dev Role name adopts the live hat details (specOrder-10); falls back to "Role#N" when the
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
        //     The admin grant is STICKY (delegable=false, R5 / specOrder-8): a delegated CAP_REMOVE
        //     manager must never be able to clear the Executor's admin membership (org lock-out).
        _pushAdminSubject(authority, topHat);
        _pushSeedSlice(authority, topHat, _single(s.executor), false);

        // (1) Role subjects (maxMembers=0 during seeding; tightened after memberships).
        _pushRoleSubjects(authority);

        // (2) LIVE-ADOPTED default eligibility (A1 / specOrder-0 / seedCompleteness-1). Do NOT force the
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
    function _seedLiveDefaults(OrgSpec memory s, address authority) internal {
        uint256 topHat = _topHatId(s);
        for (uint256 i; i < _subjects.length; ++i) {
            uint256 subject = _subjects[i];
            if (subject == topHat) continue;
            if (_liveDefaultAllow(s, subject)) {
                _push(authority, abi.encodeCall(IMembershipAuthority.setSubjectDefault, (subject, true, false)));
            }
        }
    }

    /// @dev The LIVE default eligibility verdict for `subject`: probe the legacy EM with a FRESH,
    ///      never-seen address (deterministic per org+subject). A fresh address has no explicit rule, so
    ///      getWearerRules returns the subject's DEFAULT rule flags — .eligible is the open/gated verdict.
    function _liveDefaultAllow(OrgSpec memory s, uint256 subject) internal view returns (bool) {
        address fresh = address(uint160(uint256(keccak256(abi.encode(s.orgId, subject, "live-default-probe")))));
        try IEMMig(s.eligibilityModule).getWearerRules(fresh, subject) returns (bool eligible, bool) {
            return eligible;
        } catch {
            return false;
        }
    }

    /// @dev A3 (specOrder-1 / seedCompleteness-1): port legacy explicit-DENY wearer rules (bans/kicks) as
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
        names[0] = _hatName(topHat, "Admin"); // live details, fallback "Admin" (specOrder-10)
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
            names[i - 1] = _hatName(_subjects[i], string.concat("Role#", vm.toString(i))); // specOrder-10
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
        // A2 (specOrder-9 / seedCompleteness-0): TM permission table — REAL masks, per-project rows.
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
            // VouchWithMaxMembers anti-pattern (seedCompleteness-3). The open member role's maxSupply
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
        names[0] = _hatName(id, "VoucherRole"); // live details, fallback "VoucherRole" (specOrder-10)
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

        // A5 (§6 step-3, specOrder-4 / seedCompleteness-2): DELTA-SEED first — legacy wearers who joined
        // since the authority was seeded (isWearerOfHat but NOT yet an authority member) are granted +
        // accepted here, INSIDE the atomic cutover, so they are not silently toggled off unported. When
        // there is no drift the delta is EMPTY (bindIndex == 0, the pre-A5 shape). This is executable —
        // seedRules/seedMemberships are executor-gated and pause-exempt, and run before the unpause.
        (IExecutor.Call[] memory delta,) = _buildDeltaSeed(s, authority, candidates);

        // The batch is `delta` + 11 core calls + 1 trailing CutoverVerifier.verify (when wired).
        bool withVerify = _verifier != address(0);
        batch = new IExecutor.Call[](delta.length + (withVerify ? 12 : 11));
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
        //     is now TRUE (was previously sim-only — specOrder-2 / simVsBroadcast-1 / seedCompleteness-2).
        if (withVerify) {
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
