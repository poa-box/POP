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
    IEMWriteMig,
    IPTMig,
    IPaymasterMig,
    IPoaManagerMig,
    IZkInvitesMig
} from "./AccessV2MigrationBase.sol";
import {ZkEmailProof, IZkEmailGroth16Verifier} from "../../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../../src/zkemail/IDKIMRegistry.sol";
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
        // T3: inject a REAL legacy kick BEFORE any seed content is built, so the ban-porting path runs
        //     against a live effective ban instead of an empty set.
        _injectSyntheticBan(s, candidates);
        // T5: guarantee the per-project TM override resolution path executes on this org.
        _ensureTmOverrideRow(s, candidates);
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
        // T5: capture the INDEPENDENT legacy TM resolution from the live TM's own storage, PRE-cutover.
        _captureTmOracle(s, candidates);

        // T1: capture the LEGACY zk-claim baseline (snapshot-isolated) BEFORE the cutover, so the
        //     post-cutover continuity probe compares against an independent pre-cutover expectation.
        _zkLegacyBaseline(s);

        // (4) Ordering proof (iii) + faithful cutover execution. No drift in the rehearsal → the delta
        //     is empty and bindIdx == 0 (the pre-A5 batch shape).
        (IExecutor.Call[] memory batch, uint256 bindIdx) = _buildCutoverBatch(s, authority, router, candidates);
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
        _verifier = address(new CutoverVerifier(HATS, _orgRegistry(s), _paymaster(s)));
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
        uint256 recordsVerified;
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
            // T4 (assertTautology-4): per-wearer COUNT parity PLUS per-record IDENTITY for EVERY
            // reconstructed record — not one sampled record per subject. With KUBI's all-quorum-1 /
            // length-1 voucher lists a cross-wearer misattribution (wearer[j]'s voucher array pushed for
            // wearer[j+1]) preserved every count and was caught only by luck.
            uint256 subjectRecords;
            uint256 subjectCountTotal;
            for (uint256 j; j < candidates.length; ++j) {
                address wearer = candidates[j];
                if (!_expectMember[subject][wearer]) continue;
                address[] memory vs = _reconstructVouchers(s, subject, wearer, candidates);
                uint32 ported = a.vouchCount(subject, wearer);
                require(ported == vs.length, "VERBATIM vouch record port drift");
                uint32 legacy = IEMMig(s.eligibilityModule).currentVouchCount(subject, wearer);
                require(ported <= legacy, "ported count exceeds legacy (over-count)");
                subjectCountTotal += ported;
                for (uint256 v; v < vs.length; ++v) {
                    _assertRecordLive(authority, subject, wearer, vs[v]);
                    subjectRecords++;
                }
                // NEGATIVE arm: a candidate with NO legacy record must hold NO authority record. Together
                // with `ported == vs.length` this pins exact SET equality, not just cardinality.
                address nonVoucher = _firstNonVoucher(candidates, vs, wearer);
                if (nonVoucher != address(0)) _assertRecordAbsent(authority, subject, wearer, nonVoucher);
            }
            require(subjectRecords == subjectCountTotal, "T4: verified record total != ported vouchCount total");
            recordsVerified += subjectRecords;
            // A4 behavioral parity: exercise the FIRST ported (wearer, voucher) RECORD on this subject.
            // Records-first porting (not a bare count) must let a ported voucher REVOKE (count drops)
            // and must REJECT a re-vouch by that same voucher (AlreadyVouched) — the two behaviors the
            // VERBATIM port exists to preserve.
            recordsExercised += _exerciseVouchRecord(s, authority, subject, candidates);
        }
        console.log("  vouch-configured subjects checked:", vouchSubjects);
        console.log("  vouch RECORDS verified verbatim (per-record identity):", recordsVerified);
        console.log("  vouch RECORD behaviors exercised (revoke+re-vouch):", recordsExercised);
        // Non-vacuity guard: a VERBATIM org MUST have at least one real ported record to exercise
        // (KUBI's Executive gate). If none was found, the port silently did nothing — fail loudly.
        if (s.vouchVerbatim) {
            require(recordsVerified > 0, "VERBATIM: no ported vouch record verified");
            require(recordsExercised > 0, "VERBATIM: no ported vouch record exercised");
        }
    }

    /// @dev T4: prove ONE reconstructed record is LIVE on the authority, by identity. revokeVouch has no
    ///      membership gate — it succeeds if and only if `vouchers[subject][wearer][msg.sender]` is set at
    ///      the CURRENT epoch AND gen — so a snapshot-isolated revoke is an exact per-record oracle
    ///      (IMembershipAuthority exposes no record getter). The count must drop by exactly 1.
    function _assertRecordLive(address authority, uint256 subject, address wearer, address voucher) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint32 before = a.vouchCount(subject, wearer);
        uint256 snap = vm.snapshotState();
        vm.prank(voucher);
        IMembershipAuthority(authority).revokeVouch(subject, wearer);
        require(a.vouchCount(subject, wearer) == before - 1, "T4: ported record revoke did not drop the count");
        vm.revertToState(snap);
    }

    /// @dev T4 negative arm: an address with NO legacy record must hold NO authority record.
    function _assertRecordAbsent(address authority, uint256 subject, address wearer, address nonVoucher) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(nonVoucher);
        try IMembershipAuthority(authority).revokeVouch(subject, wearer) {
            revert("T4: a NON-voucher holds a live authority vouch record (misattributed port)");
        } catch (bytes memory e) {
            require(bytes4(e) == IMembershipAuthority.HasNotVouched.selector, "T4: non-voucher revoke wrong revert");
        }
        vm.revertToState(snap);
    }

    /// @dev The first candidate that is neither `wearer` nor a member of `vs` (0 if none).
    function _firstNonVoucher(address[] memory candidates, address[] memory vs, address wearer)
        internal
        pure
        returns (address)
    {
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i] == wearer || _isIn(vs, candidates[i])) continue;
            return candidates[i];
        }
        return address(0);
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

        // Probe C1b — T7: EVERY subject's stranger semantics, both arms explicit.
        _probeOpenSubjectStrangers(s, authority);

        // Probe C2 — legacy bans ported (A3): banned wearers stay ineligible/non-claimable post-cutover.
        _assertBansPorted(s, authority, candidates);

        // Probe C3 — zk-email continuity (T1): Test6/KUBI's ONLY post-cutover invite channel, driven
        //             end-to-end through the LIVE ZkEmailInvites bytecode.
        _probeZkContinuity(s, authority);

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

    /// @dev A2 + T5 (specOrder-9 / seedCompleteness-0 / assertTautology-5): TaskManager
    ///      permission-resolution parity against an INDEPENDENT oracle. The `want` side is no longer
    ///      folded from the same fixture that seeded the authority — it is `_captureTmOracle`'s
    ///      PRE-cutover replay of TaskManager._permMask's LEGACY arm, computed from the live TM's own
    ///      ERC-7201 storage (rolePermGlobal / rolePermProj / permissionHatIds — including the
    ///      permissionHatIds gate the fixture fold omitted) plus live Hats wearership.
    ///      Two arms, both now HARD requires instead of vacuous "skipped" logs:
    ///        (1) SHADOW: every captured (user, project-with-override) pair must resolve through the
    ///            authority (ctx = pid+1) to exactly the legacy value, and the per-project result must
    ///            genuinely differ from the ctx-0 global-only result (the shadow is materialized).
    ///        (2) GLOBAL-ONLY: every captured global holder on an override-free project resolves to the
    ///            legacy global fold, non-empty.
    ///      The FIXTURE-derived expectation is additionally cross-checked against the live oracle, so a
    ///      stale fixture row for a hat that is no longer in `permissionHatIds` (the TM privilege-
    ///      escalation class the finding names) surfaces as a loud mismatch instead of cancelling out on
    ///      both sides of a shared-source comparison.
    function _probeTM(OrgSpec memory s, address authority, address[] memory candidates) internal view {
        s;
        candidates; // the oracle rows were captured pre-cutover; these are only used there
        IMembershipAuthority a = IMembershipAuthority(authority);
        require(_tmOracleUsers.length > 0, "T5: no independent TM oracle rows captured");
        uint256 shadowChecked;
        uint256 globalChecked;
        for (uint256 i; i < _tmOracleUsers.length; ++i) {
            address user = _tmOracleUsers[i];
            uint256 pid = _tmOraclePids[i];
            uint256 want = _tmOracleMasks[i];
            uint256 got = a.hasPerm(user, AccessV2PermKeys.TM_PERMS, bytes32(pid + 1));
            require(got == want, "T5: authority TM resolution != INDEPENDENT legacy oracle");
            require(
                want == _legacyExpectedMask(pid, user),
                "T5: fixture-derived TM expectation diverges from the LIVE TM storage oracle (stale fixture)"
            );
            if (_tmOracleShadow[i]) {
                uint256 globalOnly = a.hasPerm(user, AccessV2PermKeys.TM_PERMS, bytes32(0));
                require(want != globalOnly, "TM shadow: per-project mask did not shadow global (no effect)");
                shadowChecked++;
            } else {
                require(got != 0, "TM global-only: resolved empty for a global-mask holder");
                globalChecked++;
            }
        }
        require(shadowChecked > 0, "T5: no per-project override row was exercised (path never executed)");
        require(globalChecked > 0, "T5: no global-only row was exercised");
        console.log("  probe TaskManager SHADOW rows verified vs INDEPENDENT live-storage oracle:", shadowChecked);
        console.log("  probe TaskManager GLOBAL-ONLY rows verified vs INDEPENDENT oracle:", globalChecked);
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
        // T2 (assertTautology-1): the arm is selected from the CATALOG-RECORDED constant, never from the
        // live oracle that seeded the default (_assertRecordedMemberGate already require()d they agree at
        // seed time, so a live change fails loudly there rather than silently flipping this arm too).
        bool openMember = s.expectOpenMember;
        address fresh = address(uint160(uint256(keccak256(abi.encode(s.orgId, "qj-join")))));
        require(!a.isMember(_memberSubject, fresh), "fresh user already a member");

        if (openMember) {
            // OPEN member role (DP): the fresh user joins via QJ->Executor.mintHatsForUser->authority.mintHat.
            // T2: the executor-gated terminal mint is a fallback ONLY where QuickJoin is genuinely not an
            // authorized minter on this Executor — NOT a blanket catch. A blanket catch converted a broken
            // QJ->Executor->authority chain (every real join dead) into a PASS.
            uint256[] memory hatIds = new uint256[](1);
            hatIds[0] = _memberSubject;
            if (IExecMig(s.executor).isAuthorizedHatMinter(s.qj)) {
                vm.prank(s.qj);
                IExecMig(s.executor).mintHatsForUser(fresh, hatIds);
                require(a.isMember(_memberSubject, fresh), "open QuickJoin mint did not create member");
                console.log("  probe QuickJoin join path: OK (OPEN member; QJ->Executor->authority.mintHat)");
            } else {
                vm.prank(s.executor);
                IMembershipAuthority(authority).mintHat(_memberSubject, fresh);
                require(a.isMember(_memberSubject, fresh), "open authority.mintHat did not create member");
                console.log(
                    "  probe QuickJoin join path: OK (OPEN member; terminal executor-gated mint - QJ is NOT"
                    " an authorized minter on this Executor)"
                );
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

    /// @dev T7 (assertTautology-7): stranger semantics for EVERY subject, both arms explicit per org.
    ///      MembershipAuthority.claim() flips membership for ANY caller on a default-ALLOW subject, but
    ///      legacy openness ALSO required a permissionless mint channel (QuickJoin): a default-open EM
    ///      verdict on a non-QuickJoin hat (an officer/voting hat whose real gate was the executor-gated
    ///      mint) becomes a sponsored permissionless role grab post-cutover. Only the member subject's
    ///      join semantics were ever probed. This probe is the enforcement half of the `_seedLiveDefaults`
    ///      titled-role suppression: it re-derives the verdict from the authority and fails the ceremony
    ///      if ANY subject other than the recorded open member role is claimable.
    ///      The open/gated verdict here is read from the AUTHORITY itself (a fresh stranger's
    ///      isEligible — with no rule, vouch or email that is exactly the subject's default), not from
    ///      the legacy oracle that seeded it, so this is not a second self-referential check.
    ///        POSITIVE arm: the ONE subject allowed to be open is the org's QuickJoin member role, and
    ///                      only where the catalog records it open — a fresh address must actually be
    ///                      able to claim() it (open semantics preserved end-to-end).
    ///        NEGATIVE arm: every other subject must reject a stranger's claim() with NotClaimable.
    function _probeOpenSubjectStrangers(OrgSpec memory s, address authority) internal {
        IMembershipAuthority a = IMembershipAuthority(authority);
        uint256 openSubjects;
        uint256 gatedSubjects;
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            address stranger = address(uint160(uint256(keccak256(abi.encode(s.orgId, subject, "t7-stranger")))));
            require(!a.isMember(subject, stranger), "T7: fresh stranger is already a member");
            bool openOnAuthority = a.isEligible(stranger, subject);
            bool mayBeOpen = (subject == _memberSubject && s.expectOpenMember);
            if (openOnAuthority != mayBeOpen) {
                console.log("  [T7] UNEXPECTED default verdict on subject:", subject);
                console.log("       authority-open / catalog-allows-open:", openOnAuthority, mayBeOpen);
                console.log(string.concat("       role name: ", a.getSubject(subject).name));
            }
            require(
                openOnAuthority == mayBeOpen,
                "T7: default-ALLOW verdict on a subject the catalog does not record as the open member role"
            );
            if (openOnAuthority) {
                vm.prank(stranger);
                IMembershipAuthority(authority).claim(subject);
                require(a.isMember(subject, stranger), "T7: OPEN subject claim did not create a member");
                openSubjects++;
            } else {
                vm.prank(stranger);
                try IMembershipAuthority(authority).claim(subject) {
                    revert("T7: stranger CLAIMED a gated subject (security regression)");
                } catch (bytes memory e) {
                    require(bytes4(e) == IMembershipAuthority.NotClaimable.selector, "T7: gated claim wrong revert");
                }
                gatedSubjects++;
            }
        }
        console.log("  [T7] stranger arms - OPEN subjects claimable:", openSubjects);
        console.log("       GATED subjects that rejected a stranger claim:", gatedSubjects);
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
        // T3 (assertTautology-3): on a drill org the ban path is NON-VACUOUS by construction — assert the
        // exact injected pair specifically (not just "some ban existed"), including that the wearer's
        // PRIOR membership was never seeded and that they cannot claim their way back in.
        if (s.banDrill) {
            require(_synthBanSubject != 0, "T3: ban drill org but no synthetic ban was injected");
            require(total >= 1, "T3: synthetic ban did not reach the ported ban set");
            (, bool sbEligible,, AccessV2Types.RuleKind sbKind) = a.getStatus(_synthBanSubject, _synthBanUser);
            require(sbKind == AccessV2Types.RuleKind.Ban, "T3: synthetic ban not ported as RuleKind.Ban");
            require(!sbEligible, "T3: synthetically-banned wearer is eligible post-cutover");
            require(!a.isMember(_synthBanSubject, _synthBanUser), "T3: synthetically-banned wearer is a member");
            require(
                !_expectMember[_synthBanSubject][_synthBanUser],
                "T3: synthetically-banned wearer's PRIOR membership was seeded (ban lost the race)"
            );
            vm.prank(_synthBanUser);
            try IMembershipAuthority(authority).claim(_synthBanSubject) {
                revert("T3: synthetically-banned wearer could still claim");
            } catch (bytes memory e) {
                require(bytes4(e) == IMembershipAuthority.NotClaimable.selector, "T3: banned-claim wrong revert");
            }
            console.log("  [T3] synthetic-ban drill: ported as Ban, ineligible, non-member, claim rejected");
        }
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
        (uint256 rawDenies, uint256 denySubjects) = _rawExplicitDenyCensus(s, candidates);
        console.log("  raw explicit-deny rules found (recon enumeration):", rawDenies);
        console.log("  distinct subjects carrying a raw deny:", denySubjects);
        require(rawDenies >= total, "raw-deny enumeration must be a superset of effective bans");
        // NOTE: `_lower`/`_lowerName` cast `string memory -> bytes memory` and lowercase IN PLACE, so
        // s.name is already lowercased by the first _loadCandidates/_loadTmPerms call. Compare through
        // _lower() so the branch is case-robust either way.
        if (keccak256(bytes(_lower(s.name))) == keccak256("kubi")) {
            // The recon flagged KUBI's FOUR raw deny rules — 0x439831a0/0xb1392efc on the Executive hat
            // and 0x12e32ea6/0x3daa26ce on the member hat — all re-verified live. T3 pins the census
            // instead of the old `>= 2` floor (which passed even if subject discovery dropped the
            // Executive hat entirely, or the candidate fixture lost both Executive-banned addresses —
            // exactly the halved-scanner failure the assert exists to catch): the scanner must find
            // EXACTLY the 4 recon kicks plus the 1 synthetic-ban-drill kick, spread over EXACTLY the 2
            // subjects that carry them.
            require(rawDenies == 5, "KUBI: raw-deny census != 4 recon kicks + 1 drill kick (scanner halved?)");
            require(denySubjects == 2, "KUBI: raw denies must span EXACTLY 2 subjects (member + Executive)");
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
    ///      Returns both the total pair count and the number of DISTINCT subjects carrying at least one
    ///      raw deny — the second figure is what pins the census against a halved scanner (T3).
    function _rawExplicitDenyCensus(OrgSpec memory s, address[] memory candidates)
        internal
        view
        returns (uint256 n, uint256 subjectsWithDenies)
    {
        for (uint256 si; si < _subjects.length; ++si) {
            uint256 subject = _subjects[si];
            uint256 perSubject;
            for (uint256 j; j < candidates.length; ++j) {
                try IEMMig(s.eligibilityModule).hasSpecificWearerRules(candidates[j], subject) returns (bool hasRule) {
                    if (!hasRule) continue;
                    (bool eligible,) = IEMMig(s.eligibilityModule).getWearerRules(candidates[j], subject);
                    if (!eligible) perSubject++;
                } catch {}
            }
            n += perSubject;
            if (perSubject > 0) subjectsWithDenies++;
        }
    }

    /*═══════════════════ T1: zk-email continuity (spec "Test6 zkEmail continuity", assertTautology-0) ═══════════════════*/

    /// @dev The live module's domain-leaf kind (ZkEmailInvites.LEAF_DOMAIN).
    uint8 internal constant ZK_LEAF_DOMAIN = 0;
    /// @dev Captured PRE-cutover by {_zkLegacyBaseline}: did the org's REAL zk claim path work on the
    ///      legacy stack? The post-cutover probe asserts PARITY against this, so a dead-before /
    ///      dead-after channel cannot masquerade as a regression and (more importantly) a live-before /
    ///      dead-after channel cannot pass.
    bool internal _zkBaselineRan;
    bool internal _zkBaselineOk;

    /// @dev Drive the LIVE ZkEmailInvites module's REAL claim entrypoint for `claimer` on `subject`.
    ///      The ONLY things faked are the two pure crypto oracles the cutover does not touch: the
    ///      Groth16 verifier and the DKIM registry (vm.mockCall true). Governance activates a
    ///      single-leaf allowlist whose only entry is (domain, [subject]) — the same
    ///      `setActiveAllowlist` call an org makes for real — and the org's live root is restored
    ///      afterwards. Every link the cutover DOES move runs against the deployed module bytecode
    ///      untouched: executor.hats() -> H-03 open-hat probe -> viewHat[eligibility] ->
    ///      setEmailVerified -> isEligible -> executor.mintHatsForUser -> mintHat.
    function _zkClaim(OrgSpec memory s, address claimer, uint256 subject, bytes32 salt)
        internal
        returns (bool ok, bytes memory err)
    {
        IZkInvitesMig zk = IZkInvitesMig(s.zkEmailInvites);
        bytes32 prevRoot = zk.merkleRoot();
        bytes32 prevCid = zk.allowlistCid();

        uint256[] memory hatIds = new uint256[](1);
        hatIds[0] = subject;
        bytes32 dh = keccak256(abi.encode(s.orgId, salt, "zk-domain"));
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(ZK_LEAF_DOMAIN, dh, hatIds))));

        vm.prank(s.executor);
        zk.setActiveAllowlist(leaf, bytes32(uint256(1)));
        vm.mockCall(
            zk.domainVerifier(), abi.encodeWithSelector(IZkEmailGroth16Verifier.verifyProof.selector), abi.encode(true)
        );
        vm.mockCall(zk.dkimRegistry(), abi.encodeWithSelector(IDKIMRegistry.isKeyHashValid.selector), abi.encode(true));

        ZkEmailProof memory p;
        p.pubkeyHash = keccak256(abi.encode(salt, "pk"));
        p.emailNullifier = keccak256(abi.encode(s.orgId, salt, "nullifier"));
        p.fromDomainHash = dh;

        try zk.claimRoleByDomain(p, claimer, hatIds, new bytes32[](0)) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }

        vm.clearMockedCalls();
        vm.prank(s.executor);
        zk.setActiveAllowlist(prevRoot, prevCid);
    }

    /// @dev PRE-CUTOVER baseline (run inside a snapshot by the orchestrators): does the org's REAL zk
    ///      claim path mint a fresh invitee on the LEGACY stack today? Establishes the independent
    ///      expectation the post-cutover probe must reproduce (no self-referential oracle).
    function _zkLegacyBaseline(OrgSpec memory s) internal {
        if (s.zkEmailInvites == address(0) || _memberSubject == 0) return;
        uint256 snap = vm.snapshotState();
        address invitee = address(uint160(uint256(keccak256(abi.encode(s.orgId, "zk-legacy-baseline")))));
        (bool ok, bytes memory err) = _zkClaim(s, invitee, _memberSubject, "legacy");
        bool wears = IHatsMin(HATS).isWearerOfHat(invitee, _memberSubject);
        // Locals live in memory and survive the state revert; the flags MUST be written after it
        // (vm.revertToState rolls back this script contract's own storage too).
        vm.revertToState(snap);
        _zkBaselineRan = true;
        _zkBaselineOk = ok && wears;
        if (_zkBaselineOk) {
            console.log("  [T1] zk LEGACY baseline: real claim path MINTED a fresh invitee (channel live pre-cutover)");
        } else {
            console.log("  [T1] zk LEGACY baseline: real claim path did NOT mint (channel already dead pre-cutover)");
            console.logBytes(err);
        }
    }

    /// @dev POST-CUTOVER zk continuity. Traces + exercises the FULL chain the spec mandates, against the
    ///      DEPLOYED module bytecode (the sims never upgrade the ZkEmailInvites beacon):
    ///        (a) WIRING TRACE — executor.hats() == authority (this is the ONLY repoint the module needs:
    ///            it resolves Hats from the Executor, so cutover call #8 Executor.setMembershipAuthority
    ///            IS the zk repoint — fork-traced, no module-side setter exists or is required);
    ///            Executor.isAuthorizedHatMinter(zk) (the gate MembershipAuthority.setEmailVerified
    ///            applies to a non-executor caller); authority.viewHat(subject)[eligibility] == authority
    ///            (the address the module will call setEmailVerified ON); and the H-03 open-hat probe
    ///            answering NOT-open for the gated subject through the authority.
    ///        (b) EXACT CALL — prank the zk module address calling authority.setEmailVerified: the flag
    ///            must land ON THE AUTHORITY and flip the invitee from ineligible to eligible.
    ///        (c) FULL CHAIN — a DIFFERENT fresh invitee with NO pre-grant runs the module's real claim
    ///            entrypoint and ends up an authority member (the module itself performs (b) internally).
    ///        (d) PARITY — the outcome matches the pre-cutover legacy baseline.
    function _probeZkContinuity(OrgSpec memory s, address authority) internal {
        if (s.zkEmailInvites == address(0)) {
            console.log("  probe zk-email continuity: org has no ZkEmailInvites (n/a)");
            return;
        }
        require(_memberSubject != 0, "zk continuity: org has a zk module but no member subject");
        IMembershipAuthority a = IMembershipAuthority(authority);
        address zk = s.zkEmailInvites;
        uint256 subject = _memberSubject;

        // (a) wiring trace
        require(IExecMig(s.executor).hats() == authority, "zk chain: executor.hats() is not the authority");
        require(IExecMig(s.executor).isAuthorizedHatMinter(zk), "zk chain: module is not an authorized hat minter");
        (,,, address eligSlot,,,,,) = IMembershipAuthority(authority).viewHat(subject);
        require(eligSlot == authority, "zk chain: authority.viewHat eligibility slot is not the authority");
        address claimProbe = address(uint160(uint256(keccak256("poa.zkemailinvites.claim.probe"))));
        require(!a.isEligible(claimProbe, subject), "zk chain: H-03 open-hat probe reads OPEN through the authority");

        // (b) the module's exact setEmailVerified call, pranked as the module
        address invitee = address(uint160(uint256(keccak256(abi.encode(s.orgId, "zk-flag-invitee")))));
        require(!a.isEligible(invitee, subject), "zk probe: fresh invitee already eligible");
        uint256[] memory one = new uint256[](1);
        one[0] = subject;
        vm.prank(zk);
        IMembershipAuthority(authority).setEmailVerified(invitee, one);
        require(
            a.isEligible(invitee, subject), "zk chain: emailVerified flag did NOT flip eligibility on the authority"
        );
        console.log("  [T1] zk setEmailVerified: flag landed on the AUTHORITY and flipped eligibility");

        // (c) the full live-module claim, no pre-grant
        address invitee2 = address(uint160(uint256(keccak256(abi.encode(s.orgId, "zk-claim-invitee")))));
        require(!a.isMember(subject, invitee2), "zk probe: fresh invitee2 already a member");
        (bool ok, bytes memory err) = _zkClaim(s, invitee2, subject, "postcutover");
        if (!ok) {
            console.logBytes(err);
        }
        // (d) parity with the legacy baseline
        require(_zkBaselineRan, "zk continuity: legacy baseline was never captured");
        require(
            ok == _zkBaselineOk,
            "zk continuity REGRESSION: post-cutover claim outcome differs from the pre-cutover legacy baseline"
        );
        if (ok) {
            require(a.isMember(subject, invitee2), "zk chain: claim succeeded but no authority membership");
            console.log("  probe zk-email continuity: OK (real claim -> authority membership, legacy parity)");
        } else {
            console.log("  probe zk-email continuity: channel dead BOTH sides (parity held) - see bytes above");
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
            vouchVerbatim: false, // Test6 uses zk-email continuity; vouch AMNESTY (recorded)
            expectOpenMember: false, // GATED (zk-email): live raw+combined (false,true) for a fresh address
            banDrill: false
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
            vouchVerbatim: false, // AMNESTY (recorded)
            expectOpenMember: true, // OPEN: live raw+combined (true,true) for a fresh address (QuickJoin auto-join)
            banDrill: false
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
            vouchVerbatim: true, // KUBI Executive: VERBATIM port (counts + epochs), recon-mandated
            expectOpenMember: false, // GATED (vouch): live raw+combined (false,true) for a fresh address
            banDrill: true // T3 synthetic-ban drill — the Gnosis leg
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
            vouchVerbatim: false, // AMNESTY (recorded)
            expectOpenMember: false, // governance-only: QuickJoin.memberHatIds() is EMPTY (no member subject)
            banDrill: true // T3 synthetic-ban drill — the Arbitrum leg
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

