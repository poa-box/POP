// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    AccessV2MigrationBase,
    IHatsMin,
    IExecMig,
    IToggleMig,
    IDDMig,
    IEMMig,
    IPTMig,
    IPaymasterMig,
    IPoaManagerMig
} from "./AccessV2MigrationBase.sol";
import {IMembershipAuthority} from "../../src/interfaces/IMembershipAuthority.sol";
import {IAuthorityRouter} from "../../src/interfaces/IAuthorityRouter.sol";
import {AccessV2Types} from "../../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../../src/libs/AccessV2PermKeys.sol";
import {IExecutor} from "../../src/Executor.sol";

import {MembershipAuthority} from "../../src/MembershipAuthority.sol";
import {AuthorityRouter} from "../../src/AuthorityRouter.sol";
import {CutoverVerifier} from "../../src/CutoverVerifier.sol";
import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {Executor} from "../../src/Executor.sol";

/*
 * ============================================================================
 * RehearseMigration — end-to-end per-org fork rehearsal (Wave D2, SPEC §6)
 * ============================================================================
 *
 * Runs the COMPLETE ceremony against a real fork, under FOUNDRY_PROFILE=production:
 *   1. Protocol effects (D1 waves, replicated pranked-Hudson): register the
 *      MembershipAuthority + AuthorityRouter beacons, deploy the router singleton,
 *      bump PaymasterHub → v20 + setHats(router), bump the 7 dual-path module beacons.
 *   2. PREDEPLOY + SEED the org authority from live Hats/EligibilityModule/module state.
 *   3. Execute the CUTOVER BATCH FAITHFULLY — vm.prank(votingContract) → executor.execute
 *      — so Executor's own restrictions (allowedCaller gate + the W6 self-target allowlist)
 *      are exercised, not bypassed.
 *   4. Assert: (i) MEMBERSHIP PARITY, (ii) five behavioral probes, (iii) router-bind-before-
 *      toggle-off ordering, (iv) vouch-state parity, (v) ROLLBACK byte-identity.
 *
 * Run:
 *   FOUNDRY_PROFILE=production forge script script/accessv2/RehearseMigration.s.sol:RehearseTest6 \
 *     --fork-url gnosis-gateway -vvv
 *   ...:RehearseDecentralPark --fork-url gnosis-gateway
 *   ...:RehearseKubi          --fork-url gnosis-gateway
 *   ...:RehearsePoa           --fork-url arbitrum
 * ============================================================================
 */

interface ISatelliteAdmin {
    function owner() external view returns (address);
    function addContractType(string calldata typeName, address impl) external;
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

interface IHubAdmin {
    function owner() external view returns (address);
    function addContractType(string calldata typeName, address impl) external;
    function upgradeBeaconLocal(string calldata typeName, address newImpl, string calldata version) external;
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
}

interface IDDProbe {
    function createProposal(
        bytes calldata title,
        bytes32 descriptionHash,
        uint32 minutesDuration,
        uint8 numOptions,
        IExecutor.Call[][] calldata batches,
        uint256[] calldata hatIds
    ) external;
    function vote(uint256 id, uint8[] calldata idxs, uint8[] calldata weights) external;
    function proposalsCount() external view returns (uint256);
    function creatorHats() external view returns (uint256[] memory);
    function votingHats() external view returns (uint256[] memory);
}

abstract contract RehearseMigrationBase is AccessV2MigrationBase {
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant ARB_HUB = 0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71;
    string internal constant SIM_VERSION = "d2rehearsal";

    // Rollback pre-image (captured before any migration write).
    bytes32 internal _ddLegacyPre;

    /*═══════════════════════════════ Orchestration ═══════════════════════════════*/

    function _rehearse(OrgSpec memory s) internal {
        address[] memory candidates = _loadCandidates(s.name);
        console.log(string.concat("\n=== REHEARSE: ", s.name, " ==="));
        console.log("  candidates loaded:", candidates.length);

        require(_topHatDomain(s) != 0, "recorded topHat domain is zero (bind would revert)");

        // Rollback pre-image: the DD legacy read surface BEFORE any migration write.
        _ddLegacyPre = _ddLegacySnapshot(s.dd);

        // (1) Protocol effects.
        address router = _setupProtocol(s);

        // (2) PREDEPLOY (permissionless proxy) + SEED as governance batches through Executor.execute —
        //     the SAME Call[] content the real proposals will carry (one source of truth).
        _discoverSubjects(s);
        console.log("  subjects discovered:", _subjects.length);
        address authority = _predeployAuthority(s);
        IExecutor.Call[][] memory seedBatches = _buildSeedBatches(s, authority, candidates);
        console.log("  seed batches (proposals):", seedBatches.length);
        for (uint256 b; b < seedBatches.length; ++b) {
            vm.prank(s.votingContract);
            IExecMig(s.executor).execute(100 + b, seedBatches[b]);
        }
        require(IMembershipAuthority(authority).paused(), "authority must be paused after seed batches");

        // (3) SEED INVARIANT.
        uint256 seeded = _assertSeedInvariant(s, authority, candidates);
        console.log("  SEED INVARIANT ok; seeded memberships:", seeded);

        // Capture the membership EXPECTATION from live Hats BEFORE cutover (toggle-off makes legacy
        // reads go dark; parity must compare the authority against this pre-cutover snapshot).
        _captureExpectations(s, candidates);

        // (4) Ordering proof (iii) + faithful cutover execution.
        (IExecutor.Call[] memory batch, uint256 bindIdx) = _buildCutoverBatch(s, authority, router);
        _assertBindBeforeToggle(s, authority, router, batch, bindIdx);

        // Execute the FULL batch faithfully through governance.
        vm.prank(s.votingContract);
        IExecMig(s.executor).execute(1, batch);
        _assertCutoverLanded(s, authority, router);

        // (i) MEMBERSHIP PARITY.
        (uint256 checked, uint256 matched) = _assertMembershipParity(s, authority, candidates);
        console.log("  MEMBERSHIP PARITY:", matched, "/", checked);
        require(checked == matched, "membership parity mismatch");

        // (iv) VOUCH-STATE PARITY.
        _assertVouchParity(s, authority, candidates);

        // (ii) BEHAVIORAL PROBES.
        _probeBehaviors(s, authority, router, candidates);

        // (v) ROLLBACK byte-identity.
        _assertRollback(s, authority);

        console.log(string.concat("PASS: ", s.name, " rehearsal complete."));
    }

    /*═══════════════════════════════ (1) Protocol setup ═══════════════════════════════*/

    function _setupProtocol(OrgSpec memory s) internal returns (address routerProxy) {
        vm.startPrank(HUDSON);
        address maImpl = address(new MembershipAuthority());
        address routerImpl = address(new AuthorityRouter());
        address pmImpl = address(new PaymasterHub());

        // A7 (simVsBroadcast-2): IDEMPOTENT protocol setup so the sim also runs on a POST-Phase-0 fork
        // (the runbook mandates re-running the governed sim right before each org's proposals). Guards:
        //  - addContractType reverts TypeExists once a type is registered → only add when its beacon is
        //    absent (getBeaconById == 0);
        //  - if the router singleton is already live (hub.HATS() resolves as a router), REUSE it and skip
        //    both the second ERC1967Proxy deploy and the setHats admin call.
        // Pre-Phase-0 (today's live fork: MA type count == 0 both chains) every guard is false → the
        // original fresh path runs byte-for-byte unchanged.
        bool routerLive = _looksLikeRouter(IPaymasterMig(_paymaster(s)).HATS());
        if (routerLive) {
            routerProxy = IPaymasterMig(_paymaster(s)).HATS();
        } else {
            bytes memory routerInit =
                abi.encodeCall(AuthorityRouter.initialize, (HATS, _orgRegistry(s), _paymaster(s), HUDSON));
            routerProxy = address(new ERC1967Proxy(routerImpl, routerInit));
        }

        // Fresh dual-path module impls (the D1 module wave).
        address ddI = address(new DirectDemocracyVoting());
        address hvI = address(new HybridVoting());
        address tmI = address(new TaskManager());
        address ptI = address(new ParticipationToken());
        address eduI = address(new EducationHub());
        address qjI = address(new QuickJoin());
        address exI = address(new Executor());

        if (s.gnosis) {
            ISatelliteAdmin sat = ISatelliteAdmin(GNOSIS_SATELLITE);
            if (!_typeRegistered(s, "MembershipAuthority")) sat.addContractType("MembershipAuthority", maImpl);
            if (!_typeRegistered(s, "AuthorityRouter")) sat.addContractType("AuthorityRouter", routerImpl);
            sat.upgradeBeaconDirect("PaymasterHub", pmImpl, SIM_VERSION);
            sat.upgradeBeaconDirect("DirectDemocracyVoting", ddI, SIM_VERSION);
            sat.upgradeBeaconDirect("HybridVoting", hvI, SIM_VERSION);
            sat.upgradeBeaconDirect("TaskManager", tmI, SIM_VERSION);
            sat.upgradeBeaconDirect("ParticipationToken", ptI, SIM_VERSION);
            sat.upgradeBeaconDirect("EducationHub", eduI, SIM_VERSION);
            sat.upgradeBeaconDirect("QuickJoin", qjI, SIM_VERSION);
            sat.upgradeBeaconDirect("Executor", exI, SIM_VERSION);
            if (!routerLive) sat.adminCall(_paymaster(s), abi.encodeWithSignature("setHats(address)", routerProxy));
        } else {
            IHubAdmin hub = IHubAdmin(ARB_HUB);
            if (!_typeRegistered(s, "MembershipAuthority")) hub.addContractType("MembershipAuthority", maImpl);
            if (!_typeRegistered(s, "AuthorityRouter")) hub.addContractType("AuthorityRouter", routerImpl);
            hub.upgradeBeaconLocal("PaymasterHub", pmImpl, SIM_VERSION);
            hub.upgradeBeaconLocal("DirectDemocracyVoting", ddI, SIM_VERSION);
            hub.upgradeBeaconLocal("HybridVoting", hvI, SIM_VERSION);
            hub.upgradeBeaconLocal("TaskManager", tmI, SIM_VERSION);
            hub.upgradeBeaconLocal("ParticipationToken", ptI, SIM_VERSION);
            hub.upgradeBeaconLocal("EducationHub", eduI, SIM_VERSION);
            hub.upgradeBeaconLocal("QuickJoin", qjI, SIM_VERSION);
            hub.upgradeBeaconLocal("Executor", exI, SIM_VERSION);
            if (!routerLive) hub.adminCall(_paymaster(s), abi.encodeWithSignature("setHats(address)", routerProxy));
        }
        vm.stopPrank();

        require(IPaymasterMig(_paymaster(s)).HATS() == routerProxy, "hub setHats(router) did not land");
        // The org being migrated must not already be bound (un-migrated org → authorityOf(topHat) == 0),
        // whether the router is fresh or a reused post-Phase-0 singleton carrying OTHER orgs' binds.
        require(
            IAuthorityRouter(routerProxy).authorityOf(_topHatId(s)) == address(0),
            "org already bound on the router (already migrated?)"
        );

        // Deploy the stateless CutoverVerifier (immutable hats + orgRegistry, ZERO storage) so the
        // cutover batch carries its in-batch verify() as the LAST call (§6, C4). Fresh instance per sim
        // mirrors the Phase-0 protocol singleton; production resolves the registered per-chain address.
        _verifier = address(new CutoverVerifier(HATS, _orgRegistry(s)));
    }

    /// @dev A7 idempotency helper: has PoaManager registered a beacon for this contract type yet?
    ///      getBeaconById REVERTS TypeUnknown() for an unregistered type (it does not return zero), so the
    ///      revert IS the "not registered" signal.
    function _typeRegistered(OrgSpec memory s, string memory name) internal view returns (bool) {
        try IPoaManagerMig(_poaManager(s)).getBeaconById(keccak256(bytes(name))) returns (address beacon) {
            return beacon != address(0);
        } catch {
            return false;
        }
    }

    /// @dev A7 idempotency helper: does `r` resolve as an AuthorityRouter (Phase-0 already landed)?
    function _looksLikeRouter(address r) internal view returns (bool) {
        if (r == address(0) || r == HATS) return false;
        try IAuthorityRouter(r).authorityOf(0) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /*═══════════════════════════════ (iii) bind-before-toggle ═══════════════════════════════*/

    function _assertBindBeforeToggle(
        OrgSpec memory s,
        address authority,
        address router,
        IExecutor.Call[] memory batch,
        uint256 bindIdx
    ) internal {
        require(bindIdx == 0, "router bind must be the FIRST cutover call (before toggle-off)");
        // Toggle state BEFORE any cutover call — the bind step must not disturb it (toggle-off is a
        // separate, later call in the batch, so adopted ids flip passthrough->authority WHILE the
        // legacy toggle state is still untouched).
        bool toggleBefore = IToggleMig(s.toggleModule).hatActive(_memberSubject);

        uint256 snap = vm.snapshotState();
        IExecutor.Call[] memory bindOnly = new IExecutor.Call[](1);
        bindOnly[0] = batch[0];
        vm.prank(s.votingContract);
        IExecMig(s.executor).execute(1, bindOnly);
        // After the bind-only sub-batch: adopted ids route to the authority AND the legacy toggle state
        // is UNCHANGED — the bind is independently live before any toggle-off runs (ordering proof).
        require(IAuthorityRouter(router).authorityOf(_topHatId(s)) == authority, "router NOT bound after bind step");
        require(
            IToggleMig(s.toggleModule).hatActive(_memberSubject) == toggleBefore,
            "bind step disturbed legacy toggle state - ordering wrong"
        );
        vm.revertToState(snap);
        require(IAuthorityRouter(router).authorityOf(_topHatId(s)) == address(0), "snapshot revert failed");
    }

    function _assertCutoverLanded(OrgSpec memory s, address authority, address router) internal view {
        require(IAuthorityRouter(router).authorityOf(_topHatId(s)) == authority, "authority not bound post-cutover");
        require(!IMembershipAuthority(authority).paused(), "authority still paused post-cutover");
        require(IExecMig(s.executor).hats() == authority, "Executor.hats() not repointed to authority");
        require(IDDMig(s.dd).membershipAuthority() == authority, "DD not repointed");
        require(!IToggleMig(s.toggleModule).hatActive(_memberSubject), "legacy hat not toggled off");
        // Router-THROUGH verification (§6 step-3 require reads): topHat + one role id resolve via authority.
        require(IAuthorityRouter(router).isWearerOfHat(s.executor, _topHatId(s)), "admin id fails through router");
        (,,,,,,,, bool active) = IAuthorityRouter(router).viewHat(_topHatId(s));
        require(active, "adopted topHat inactive through router");
    }

    /*═══════════════════════════════ (i) membership parity ═══════════════════════════════*/

    function _assertMembershipParity(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (uint256 checked, uint256 matched)
    {
        IMembershipAuthority a = IMembershipAuthority(authority);
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            // Executor is the pre-captured admin member of the topHat subject.
            if (subject == _topHatId(s)) {
                checked++;
                if (a.isMember(subject, s.executor) == _expectMember[subject][s.executor]) matched++;
            }
            // Every candidate: authority.isMember MUST equal the pre-cutover legacy-wearer expectation
            // (positive for pre-captured wearers, negative for the rest).
            for (uint256 j; j < candidates.length; ++j) {
                checked++;
                if (a.isMember(subject, candidates[j]) == _expectMember[subject][candidates[j]]) matched++;
            }
            // Negative: a fresh stranger is a member of nothing.
            address stranger = address(uint160(uint256(keccak256(abi.encode(s.orgId, subject, "stranger")))));
            checked++;
            if (!a.isMember(subject, stranger)) matched++;
        }
    }

    /*═══════════════════════════════ (iv) vouch parity ═══════════════════════════════*/

    function _assertVouchParity(OrgSpec memory s, address authority, address[] memory candidates) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256 vouchSubjects;
        uint256 recordsExercised;
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            IEMMig.VouchCfg memory vc = IEMMig(s.eligibilityModule).getVouchConfig(subject);
            if ((vc.flags & 0x01) == 0 || vc.quorum == 0) continue;
            // A4: self-voucher configs (membershipHatId == subject) ARE ported (C1) — check them too.
            // Only a genuinely empty voucher subject (== 0) has nothing to port.
            if (vc.membershipHatId == 0) continue;
            vouchSubjects++;
            (uint32 quorum, uint256 voucherSubject,) = a.vouchConfig(subject);
            require(quorum == vc.quorum, "vouch quorum not ported");
            require(voucherSubject == vc.membershipHatId, "voucher subject not ported");
            if (!s.vouchVerbatim) continue;
            // VERBATIM: the ported per-wearer count must equal the number of voucher RECORDS the seed
            // could actually reconstruct from the candidate set (records-first port — seedCompleteness-5).
            // NOTE (candidate-completeness limitation, seedCompleteness-7 / A5): legacy
            // EligibilityModule.currentVouchCount may exceed this when a wearer was vouched by an address
            // OUTSIDE the candidate fixture (EM direct-mint / vouched-but-unclaimed channels the current
            // enumerate-wearers.sh misses). Those records are provably unportable with the current
            // candidate source, so byte-exact legacy-count parity is NOT asserted here; closing it
            // requires the A5 candidate-enumeration rewrite (event-log union of every join/vouch channel).
            // What IS asserted: the authority faithfully ported EVERY record the seed saw (round-trip).
            for (uint256 j; j < candidates.length; ++j) {
                if (!_expectMember[subject][candidates[j]]) continue;
                uint256 portable = _reconstructVouchers(s, subject, candidates[j], candidates).length;
                require(a.vouchCount(subject, candidates[j]) == portable, "VERBATIM vouch record port drift");
                uint32 legacy = IEMMig(s.eligibilityModule).currentVouchCount(subject, candidates[j]);
                require(a.vouchCount(subject, candidates[j]) <= legacy, "ported count exceeds legacy (over-count)");
            }
            // A4 behavioral parity: exercise the FIRST ported (wearer, voucher) RECORD on this subject.
            // Records-first porting (not a bare count) must let a ported voucher REVOKE (count drops)
            // and must REJECT a re-vouch by that same voucher (AlreadyVouched) — the two behaviors the
            // VERBATIM port exists to preserve.
            recordsExercised += _exerciseVouchRecord(s, authority, subject, candidates);
        }
        console.log("  vouch-configured subjects checked:", vouchSubjects);
        console.log("  vouch RECORD behaviors exercised (revoke+re-vouch):", recordsExercised);
        // Non-vacuity guard: a VERBATIM org MUST have at least one real ported record to exercise
        // (KUBI's Executive gate). If none was found, the port silently did nothing — fail loudly.
        if (s.vouchVerbatim) require(recordsExercised > 0, "VERBATIM: no ported vouch record exercised");
    }

    /// @dev Find the first (wearer, voucher) ported record on `subject` and assert: (1) re-vouch by the
    ///      ported voucher reverts AlreadyVouched (record present), then (2) the ported voucher can
    ///      revoke and the authority's vouchCount drops by exactly 1. Returns 1 if a record was
    ///      exercised, 0 otherwise. Mutates the (ephemeral) fork — run AFTER count parity above.
    function _exerciseVouchRecord(OrgSpec memory s, address authority, uint256 subject, address[] memory candidates)
        internal
        returns (uint256)
    {
        IMembershipAuthority a = IMembershipAuthority(authority);
        for (uint256 j; j < candidates.length; ++j) {
            address wearer = candidates[j];
            if (a.vouchCount(subject, wearer) == 0) continue;
            for (uint256 v; v < candidates.length; ++v) {
                address voucher = candidates[v];
                // A ported record exists legacy-side AND the voucher is an authority member of the
                // voucher subject (so vouch/revokeVouch pass the caller gate).
                if (!IEMMig(s.eligibilityModule).vouchers(subject, wearer, voucher)) continue;
                (, uint256 voucherSubject,) = a.vouchConfig(subject);
                if (!a.isMember(voucherSubject, voucher)) continue;

                // (1) re-vouch by the ported voucher must revert AlreadyVouched.
                vm.prank(voucher);
                try IMembershipAuthority(authority).vouch(subject, wearer) {
                    revert("ported voucher re-vouch did NOT revert (double-count risk)");
                } catch (bytes memory err) {
                    require(bytes4(err) == IMembershipAuthority.AlreadyVouched.selector, "re-vouch wrong revert");
                }

                // (2) the ported voucher can revoke → count drops by exactly 1.
                uint32 before = a.vouchCount(subject, wearer);
                vm.prank(voucher);
                IMembershipAuthority(authority).revokeVouch(subject, wearer);
                require(a.vouchCount(subject, wearer) == before - 1, "ported voucher revoke did not drop count");
                return 1;
            }
        }
        return 0;
    }

    /*═══════════════════════════════ (ii) behavioral probes ═══════════════════════════════*/

    function _probeBehaviors(OrgSpec memory s, address authority, address router, address[] memory candidates)
        internal
    {
        IMembershipAuthority a = IMembershipAuthority(authority);

        // Find a real member who can both CREATE and VOTE on DD (a DD creator-hat member).
        address creator = _findCreator(s, authority, candidates);

        // Probe A — DD create + vote by a real member (the full module path post-cutover).
        if (creator != address(0)) {
            uint256 before = IDDProbe(s.dd).proposalsCount();
            IExecutor.Call[][] memory noBatches = new IExecutor.Call[][](0);
            uint256[] memory noHats = new uint256[](0);
            vm.prank(creator);
            IDDProbe(s.dd).createProposal(bytes("D2 rehearsal probe"), keccak256("d2"), 60, 2, noBatches, noHats);
            uint256 pid = IDDProbe(s.dd).proposalsCount() - 1;
            require(pid == before, "DD proposal not created");
            uint8[] memory idxs = new uint8[](1);
            uint8[] memory wts = new uint8[](1);
            idxs[0] = 0;
            wts[0] = 100;
            vm.prank(creator);
            IDDProbe(s.dd).vote(pid, idxs, wts);
            console.log("  probe DD create+vote: OK (creator voted on new proposal)");
        } else {
            console.log("  probe DD create+vote: no creator-hat member among candidates (read-probe only)");
        }

        // Probe B — TaskManager permission resolution for a real permission-holder (the exact TM read).
        _probeTM(s, authority, candidates);

        // Probe C — per-org QuickJoin/join semantics (A1): open-join (DP), gated stranger-claim rejection
        //           (Test6/KUBI), vouch->claim continuity (KUBI), governance-only (Poa).
        _probeQuickJoin(s, authority, candidates);

        // Probe C2 — legacy bans ported (A3): banned wearers stay ineligible/non-claimable post-cutover.
        _assertBansPorted(s, authority, candidates);

        // Probe D — ParticipationToken transfer/membership gate (the exact PT hasPerm read).
        _probePT(s, authority, candidates);

        // Probe E — hub sponsorship resolution: a sponsored selector's isEligible resolves THROUGH the
        //           router → authority for a real member (== the hub's HATS() read path). Use any
        //           member of any subject (governance-only orgs like Poa have no open member role).
        (uint256 subj, address anyMember) = _findAnyMember(s, authority, candidates);
        if (anyMember != address(0)) {
            require(IAuthorityRouter(router).isEligible(anyMember, subj), "hub-lens isEligible false for member");
            require(
                a.isMember(subj, anyMember) == IAuthorityRouter(router).isWearerOfHat(anyMember, subj),
                "router/authority disagree"
            );
            console.log("  probe hub sponsorship resolution: OK (router->authority eligible)");
        } else {
            console.log("  probe hub sponsorship resolution: no seeded member found (skipped)");
        }
    }

    function _probeTM(OrgSpec memory s, address authority, address[] memory candidates) internal view {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256[] memory permHats = _tmPermissionHats(s);
        for (uint256 i; i < permHats.length; ++i) {
            address holder = _findMemberOf(s, permHats[i], authority, candidates);
            if (holder == address(0)) continue;
            uint256 mask = a.hasPerm(holder, AccessV2PermKeys.TM_PERMS, bytes32(0));
            require(mask != 0, "TM_PERMS resolves empty for a permission-holder");
            console.log("  probe TaskManager permission: OK (mask nonzero for holder)");
            return;
        }
        console.log("  probe TaskManager permission: no TM permission-holder among candidates (skipped)");
    }

    /// @dev A1 (specOrder-0 / seedCompleteness-1): PER-ORG join semantics. The member role's LIVE default
    ///      verdict drives the assertion — OPEN (DP): a fresh user joins through the exact QJ chain; GATED
    ///      (Test6 zk / KUBI vouch): a stranger CANNOT claim or be minted the role (the security
    ///      regression the audit caught — prove it closed), and for a VERBATIM vouch org the vouch->claim
    ///      continuity path works. Governance-only (Poa): no member subject, nothing claimable.
    function _probeQuickJoin(OrgSpec memory s, address authority, address[] memory candidates) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        if (_memberSubject == 0) {
            console.log("  probe QuickJoin join path: OK (governance-only org; no open member subject)");
            return;
        }
        bool openMember = _liveDefaultAllow(s, _memberSubject);
        address fresh = address(uint160(uint256(keccak256(abi.encode(s.orgId, "qj-join")))));
        require(!a.isMember(_memberSubject, fresh), "fresh user already a member");

        if (openMember) {
            // OPEN member role (DP): the fresh user joins via QJ->Executor.mintHatsForUser->authority.mintHat
            // (or the terminal executor-gated mint if QJ is not an authorized minter on this Executor).
            uint256[] memory hatIds = new uint256[](1);
            hatIds[0] = _memberSubject;
            vm.prank(s.qj);
            try IExecMig(s.executor).mintHatsForUser(fresh, hatIds) {
                require(a.isMember(_memberSubject, fresh), "open QuickJoin mint did not create member");
                console.log("  probe QuickJoin join path: OK (OPEN member; QJ->Executor->authority.mintHat)");
            } catch {
                vm.prank(s.executor);
                IMembershipAuthority(authority).mintHat(_memberSubject, fresh);
                require(a.isMember(_memberSubject, fresh), "open authority.mintHat did not create member");
                console.log("  probe QuickJoin join path: OK (OPEN member; terminal executor-gated mint)");
            }
            return;
        }

        // GATED member role (Test6 zk / KUBI vouch): a stranger MUST NOT be able to claim or be minted in.
        vm.prank(fresh);
        try IMembershipAuthority(authority).claim(_memberSubject) {
            revert("SECURITY REGRESSION: stranger claimed a GATED member role");
        } catch (bytes memory err) {
            require(bytes4(err) == IMembershipAuthority.NotClaimable.selector, "gated stranger-claim wrong revert");
        }
        address fresh2 = address(uint160(uint256(keccak256(abi.encode(s.orgId, "qj-join-gated")))));
        vm.prank(s.executor);
        try IMembershipAuthority(authority).mintHat(_memberSubject, fresh2) returns (bool) {
            revert("SECURITY REGRESSION: executor minted a GATED member role to an ineligible fresh user");
        } catch {}
        require(!a.isMember(_memberSubject, fresh2), "gated mint created a member for an ineligible fresh user");
        console.log("  probe QuickJoin join path: OK (GATED member; stranger claim+mint both reverted)");

        // VERBATIM vouch org (KUBI): vouch->claim continuity — a fresh user vouched to quorum CAN claim.
        if (s.vouchVerbatim) _probeVouchClaim(s, authority, candidates);
    }

    /// @dev A1 KUBI arm: a fresh user vouched to quorum by members of the member role's voucher subject
    ///      becomes eligible for (and can claim) the otherwise-gated member role — proving the gate is a
    ///      real vouch gate, not a dead deny. Only a maxMembers capacity cap may block the actual flip.
    function _probeVouchClaim(OrgSpec memory s, address authority, address[] memory candidates) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        (uint32 quorum, uint256 voucherSubject,) = a.vouchConfig(_memberSubject);
        require(quorum > 0 && voucherSubject != 0, "VERBATIM: member role has no vouch config to exercise");
        address[] memory vouchers = new address[](quorum);
        uint256 found;
        for (uint256 j; j < candidates.length && found < quorum; ++j) {
            if (a.isMember(voucherSubject, candidates[j])) vouchers[found++] = candidates[j];
        }
        require(found == quorum, "VERBATIM: could not assemble a voucher quorum from candidates");
        address freshVouched = address(uint160(uint256(keccak256(abi.encode(s.orgId, "vouch-claim-fresh")))));
        require(!a.isMember(_memberSubject, freshVouched), "vouched-fresh already a member");
        for (uint256 v; v < quorum; ++v) {
            vm.prank(vouchers[v]);
            a.vouch(_memberSubject, freshVouched);
        }
        vm.prank(freshVouched);
        try IMembershipAuthority(authority).claim(_memberSubject) {
            require(a.isMember(_memberSubject, freshVouched), "vouched claim did not create member");
            console.log("  probe vouch->claim: OK (vouched-to-quorum fresh user CLAIMED gated member role)");
        } catch {
            (, bool eligible,,) = a.getStatus(_memberSubject, freshVouched);
            require(eligible, "vouched-to-quorum fresh user is NOT eligible (vouch gate is dead)");
            console.log("  probe vouch->claim: OK (vouch made fresh user ELIGIBLE; flip capped by maxMembers)");
        }
    }

    /// @dev A3 (specOrder-1 / seedCompleteness-1): every legacy EFFECTIVE deny/kick must be ported as a
    ///      RuleKind.Ban that keeps the wearer ineligible and non-claimable post-cutover. "Effective" is
    ///      load-bearing and LIVE-VERIFIED: a legacy explicit-deny rule bans a wearer only when the EM's
    ///      COMBINED getWearerStatus is ineligible. The DEPLOYED EM bytecode on Gnosis PREDATES the
    ///      explicit-ban-supremacy short-circuit (EligibilityLogic "FIX 0"): on it, a raw (false,false)
    ///      rule is ADDITIVE and is OVERRIDDEN by vouch/hierarchy, so every KUBI/Test6 raw deny sits on a
    ///      user the live chain still deems ELIGIBLE. Porting those as hard v2 Bans (which HAVE supremacy)
    ///      would flip currently-eligible members to ineligible — a behavior REGRESSION and a SEED INVARIANT
    ///      trip (accepted-but-ineligible). So the behavior-preserving effective-ban set is derived from
    ///      getWearerStatus and, for these four orgs at today's state, is empty. This probe both (a) verifies
    ///      any ported ban is truly denied, and (b) LOUDLY reconciles the effective count against the raw
    ///      explicit-deny count the recon enumerated, so the divergence is recorded, not silently absorbed.
    function _assertBansPorted(OrgSpec memory s, address authority, address[] memory candidates) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256 total;
        address firstBanned;
        uint256 firstBanSubject;
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            for (uint256 j; j < candidates.length; ++j) {
                if (!_isLegacyBanned(s, candidates[j], subject)) continue;
                total++;
                (, bool eligible,, AccessV2Types.RuleKind kind) = a.getStatus(subject, candidates[j]);
                require(kind == AccessV2Types.RuleKind.Ban, "legacy ban not ported as RuleKind.Ban");
                require(!eligible, "ported ban: wearer still eligible post-cutover");
                require(!a.isMember(subject, candidates[j]), "ported ban: wearer is a member");
                if (firstBanned == address(0)) {
                    firstBanned = candidates[j];
                    firstBanSubject = subject;
                }
            }
        }
        console.log("  BANS ported+verified:", total);
        // Defense-in-depth: a ported-banned wearer's claim reverts even where the subject is default-ALLOW.
        if (firstBanned != address(0)) {
            vm.prank(firstBanned);
            try IMembershipAuthority(authority).claim(firstBanSubject) {
                revert("ported ban: banned wearer could still claim");
            } catch (bytes memory err) {
                require(bytes4(err) == IMembershipAuthority.NotClaimable.selector, "banned-claim wrong revert");
            }
        }
        // Reconcile the EFFECTIVE ban count against the RAW explicit-deny count (the recon enumeration).
        uint256 rawDenies = _rawExplicitDenyCount(s, candidates);
        console.log("  raw explicit-deny rules found (recon enumeration):", rawDenies);
        require(rawDenies >= total, "raw-deny enumeration must be a superset of effective bans");
        if (keccak256(bytes(s.name)) == keccak256(bytes("kubi"))) {
            // The recon flagged KUBI's raw deny rules (0x439831a0/0xb1392efc on Executive B,
            // 0x12e32ea6/0x3daa26ce on member A). The enumeration MACHINERY must still surface them
            // (>=2), proving the ban scanner works — but on the LIVE pre-FIX-0 EM every one is
            // vouch/hierarchy-OVERRIDDEN (getWearerStatus == eligible), so the behavior-preserving
            // effective-ban set is 0. Porting them anyway would regress live-eligible members.
            require(rawDenies >= 2, "KUBI: raw-deny enumeration must find >=2 kicks (scanner sanity)");
            if (total == 0) {
                console.log(
                    "  [A3 FINDING] KUBI raw deny rules are all vouch/hierarchy-OVERRIDDEN on the live"
                    " pre-FIX-0 EM (getWearerStatus==eligible) -> 0 EFFECTIVE bans; porting them as hard v2"
                    " Bans would REGRESS live-eligible members and trip the SEED INVARIANT. Not ported."
                );
            }
        }
    }

    /// @dev Count RAW explicit-deny rules across candidates × subjects (hasSpecificWearerRules && the raw
    ///      per-wearer rule is NOT eligible), independent of the combined verdict. This is the recon's
    ///      enumeration surface — used only to prove the ban scanner sees the live deny rules and to
    ///      reconcile them against the (behavior-preserving) effective-ban set.
    function _rawExplicitDenyCount(OrgSpec memory s, address[] memory candidates) internal view returns (uint256 n) {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            for (uint256 j; j < candidates.length; ++j) {
                try IEMMig(s.eligibilityModule).hasSpecificWearerRules(candidates[j], subject) returns (bool hasRule) {
                    if (!hasRule) continue;
                    (bool eligible,) = IEMMig(s.eligibilityModule).getWearerRules(candidates[j], subject);
                    if (!eligible) n++;
                } catch {}
            }
        }
    }

    function _probePT(OrgSpec memory s, address authority, address[] memory candidates) internal view {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256[] memory memberHats = IPTMig(s.pt).memberHatIds();
        for (uint256 i; i < memberHats.length; ++i) {
            address holder = _findMemberOf(s, memberHats[i], authority, candidates);
            if (holder == address(0)) continue;
            require(a.hasPerm(holder, AccessV2PermKeys.PT_MEMBER, bytes32(0)) != 0, "PT_MEMBER empty for a PT member");
            address stranger = address(uint160(uint256(keccak256(abi.encode(s.orgId, "pt-stranger")))));
            require(
                a.hasPerm(stranger, AccessV2PermKeys.PT_MEMBER, bytes32(0)) == 0, "PT_MEMBER nonzero for a stranger"
            );
            console.log("  probe ParticipationToken gate: OK (member allowed, stranger denied)");
            return;
        }
        console.log("  probe ParticipationToken gate: no PT member among candidates (skipped)");
    }

    /*═══════════════════════════════ (v) rollback ═══════════════════════════════*/

    function _assertRollback(OrgSpec memory s, address authority) internal {
        // Snapshot post-cutover state, then repoint ONE module (DD) back to legacy via governance.
        uint256 snap = vm.snapshotState();

        IExecutor.Call[] memory rb = new IExecutor.Call[](1);
        rb[0] = IExecutor.Call({
            target: s.dd, value: 0, data: abi.encodeWithSignature("setMembershipAuthority(address)", address(0))
        });
        vm.prank(s.votingContract);
        IExecMig(s.executor).execute(2, rb);

        require(IDDMig(s.dd).membershipAuthority() == address(0), "DD not repointed to legacy");
        // The DD legacy read surface is byte-identical to the pre-migration pre-image.
        require(_ddLegacySnapshot(s.dd) == _ddLegacyPre, "DD legacy path NOT byte-identical after rollback");
        console.log("  ROLLBACK: DD legacy path byte-identical to pre-migration.");

        vm.revertToState(snap);
        require(IDDMig(s.dd).membershipAuthority() == authority, "rollback snapshot revert failed");
    }

    function _ddLegacySnapshot(address dd) internal view returns (bytes32) {
        return keccak256(
            abi.encode(IDDMig(dd).hats(), IDDMig(dd).executor(), IDDProbe(dd).votingHats(), IDDProbe(dd).creatorHats())
        );
    }

    /*═══════════════════════════════ Helpers ═══════════════════════════════*/

    function _findCreator(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (address)
    {
        uint256[] memory creatorHats = IDDProbe(s.dd).creatorHats();
        for (uint256 i; i < creatorHats.length; ++i) {
            address m = _findMemberOf(s, creatorHats[i], authority, candidates);
            if (m != address(0)) return m;
        }
        return address(0);
    }

    function _findAnyMember(OrgSpec memory s, address authority, address[] memory candidates)
        internal
        view
        returns (uint256 subject, address member)
    {
        for (uint256 si; si < _subjects.length; ++si) {
            if (_subjects[si] == _topHatId(s)) continue; // skip admin subject
            address m = _findMemberOf(s, _subjects[si], authority, candidates);
            if (m != address(0)) return (_subjects[si], m);
        }
        return (0, address(0));
    }

    function _findMemberOf(OrgSpec memory s, uint256 subject, address authority, address[] memory candidates)
        internal
        view
        returns (address)
    {
        if (subject == 0) return address(0);
        IMembershipAuthority a = IMembershipAuthority(authority);
        for (uint256 j; j < candidates.length; ++j) {
            if (a.isMember(subject, candidates[j])) return candidates[j];
        }
        return address(0);
    }

    function _isIn(address[] memory arr, address x) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == x) return true;
        }
        return false;
    }

    function _loadCandidates(string memory org) internal view returns (address[] memory) {
        string memory path =
            string.concat(vm.projectRoot(), "/script/accessv2/fixtures/", _lower(org), ".candidates.json");
        string memory json = vm.readFile(path);
        return vm.parseJsonAddressArray(json, "$");
    }

    function _lower(string memory v) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}

/* ════════════════════════════ Org catalog (org atlas, waveD-recon.md) ════════════════════════════ */

abstract contract OrgCatalog is RehearseMigrationBase {
    function _specByKey(string memory key) internal pure returns (OrgSpec memory) {
        bytes32 h = keccak256(bytes(key));
        if (h == keccak256("TEST6")) return _test6Spec();
        if (h == keccak256("DP")) return _decentralParkSpec();
        if (h == keccak256("KUBI")) return _kubiSpec();
        if (h == keccak256("POA")) return _poaSpec();
        revert("unknown ORG key (TEST6|DP|KUBI|POA)");
    }

    function _test6Spec() internal pure returns (OrgSpec memory) {
        return OrgSpec({
            name: "Test6",
            orgId: 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b,
            gnosis: true,
            executor: 0xA09F1035Ff97d17ccA40048F027c654b66B83183,
            votingContract: 0xF642DdE77848dC195c8089F4042A311Ed650d7a6,
            dd: 0xd2667117ED47aD259fEf73F54f31a3eF9A5D889F,
            hv: 0xF642DdE77848dC195c8089F4042A311Ed650d7a6,
            tm: 0x3d93f0D090356D25E7a1614F0F8764b103ca99bc,
            pt: 0x6083c52b2F5861F327526bD646EaA754edDD5cCf,
            edu: 0x6a29222E29FDc0000AbA55329DfF0a50D9a8e8F9,
            qj: 0x09d7006724C2Ba9bf9084ad9db6DbB09B990843d,
            eligibilityModule: 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B,
            toggleModule: 0x7653674711Bf5d53FC10F17fE9aA66431c586512,
            paymentManager: 0x10E96701746B567882b74E39a24AEe7267c22Bb5,
            zkEmailInvites: 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2,
            vouchVerbatim: false // Test6 uses zk-email continuity; vouch AMNESTY (recorded)
        });
    }

    function _decentralParkSpec() internal pure returns (OrgSpec memory) {
        return OrgSpec({
            name: "DecentralPark",
            orgId: 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78,
            gnosis: true,
            executor: 0x2A01133997abE2a001862cf0B03B22fe958FA4bC,
            votingContract: 0x1B80CA1EF7F274E141658A666fc12277957bF7A1,
            dd: 0xF3e3EB13214D9F98e6115e3C2602aE66340CD575,
            hv: 0x1B80CA1EF7F274E141658A666fc12277957bF7A1,
            tm: 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7,
            pt: 0x1A8b31903C98e514332991a70C00566ec2DeE14e,
            edu: 0x80a78A0b7E0d491B7cc4cF0bAFe8bce3be9e1454,
            qj: 0xBEba9EF99aa6E0693c22b60d4Ea5ed7C395F26f1,
            eligibilityModule: 0xe4A02F20B8282A272879e31479Ee070dab07B015,
            toggleModule: 0xe4e6A68c43d9d5d4731A44C20f639C76F1913F17,
            paymentManager: 0xebC2224Dc7Ee7DdcE889e49685dB095780Be17a1,
            zkEmailInvites: address(0),
            vouchVerbatim: false // AMNESTY (recorded)
        });
    }

    function _kubiSpec() internal pure returns (OrgSpec memory) {
        return OrgSpec({
            name: "KUBI",
            orgId: 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e,
            gnosis: true,
            executor: 0x23f90B3859818A843C3a848627A304Bc53947342,
            votingContract: 0x13CBd5eD47bF177968B24D84516a75879c23971E,
            dd: 0xe24Cb844C73095569FA146D673D45c252894200f,
            hv: 0x13CBd5eD47bF177968B24D84516a75879c23971E,
            tm: 0xF57024fC77915Fce8f2608afdd027941bCEE3336,
            pt: 0x23641B4b54E1bf63FD519b242407b9314093B33C,
            edu: 0x83C7Aa49C0C5a55E22640AC164abA838E6f1f7ae,
            qj: 0x5dBda3649B7044C8fDd0E540e86E536dDA7926Cf,
            eligibilityModule: 0x27114Cb757BeDF77E30EeB0Ca635e3368d8C2914,
            toggleModule: 0xB4da98791573ddf15Bb811D497A4212904eBA3ED,
            paymentManager: 0x4009c825b38Fb0ebB6391d5FABe4FAf90e178dF1,
            zkEmailInvites: 0x32cc2D8563e691A3Ca43723A9F558f7AD8dbA9ec,
            vouchVerbatim: true // KUBI Executive: VERBATIM port (counts + epochs), recon-mandated
        });
    }

    function _poaSpec() internal pure returns (OrgSpec memory) {
        return OrgSpec({
            name: "Poa",
            orgId: 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069,
            gnosis: false,
            executor: 0xB1ff2Bd0231770ccc91801aa1fae4b3226E1fE41,
            votingContract: 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5,
            dd: 0xC82b179f5b4e325aC1B77A423FDb266AeBfCA5E8,
            hv: 0x34aa1bD79a3A5eb5d2B208eb4f091ccF6B1081d5,
            tm: 0x681f29751724D2bED331d3EB35e0C9B1C57aF9F0,
            pt: 0x33CD0B9ae54c43C11Fd05fE00afd3DBC71D9603E,
            edu: 0xe37Db8cCD295C9E4fEbb19a91efe13aCe24ca596,
            qj: 0x366c605A3064a680fb5c05Bf9EeDa512fdDBF03a,
            eligibilityModule: 0xE4F9CB9C843D0A5bd5D52e3266138B13A635743b,
            toggleModule: 0x14Aced4F1B6fB1EF4030E7E7E19A3e6aB0B931a1,
            paymentManager: 0xAe470B8366AF331F52D9eA26efD7Cb2d276878B3,
            zkEmailInvites: address(0),
            vouchVerbatim: false // AMNESTY (recorded)
        });
    }
}

/* ════════════════════════════ Per-org rehearsals ════════════════════════════ */

contract RehearseTest6 is OrgCatalog {
    function run() public {
        _rehearse(_test6Spec());
    }
}

contract RehearseDecentralPark is OrgCatalog {
    function run() public {
        _rehearse(_decentralParkSpec());
    }
}

contract RehearseKubi is OrgCatalog {
    function run() public {
        _rehearse(_kubiSpec());
    }
}

contract RehearsePoa is OrgCatalog {
    function run() public {
        _rehearse(_poaSpec());
    }
}

