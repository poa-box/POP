// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IExecMig, IPoaManagerMig, IHatsMin, IEMWriteMig} from "./AccessV2MigrationBase.sol";
import {OrgCatalog} from "./RehearseMigration.s.sol";
import {CutoverVerifier} from "../../src/CutoverVerifier.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IMembershipAuthority} from "../../src/interfaces/IMembershipAuthority.sol";
import {IAuthorityRouter} from "../../src/interfaces/IAuthorityRouter.sol";
import {IExecutor} from "../../src/Executor.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * MigrateOrgToAuthority — the PRODUCTION per-org ceremony (SPEC §6)
 * ============================================================================
 *
 * Three surfaces, all env-driven by ORG = TEST6 | DP | KUBI | POA:
 *
 *  1. PredeployAuthority (BROADCAST, any EOA): CREATE2-deploy the org's
 *     MembershipAuthority BeaconProxy via the DeterministicDeployer, ATOMICALLY
 *     INITIALIZED with an empty-genesis config (executor/orgId/paused) in the deploy
 *     tx (C5 — front-run grief close) — salt ("MembershipAuthorityProxy:<Org>", "v1")
 *     — so the address is knowable BEFORE the governance proposals reference it, and
 *     no attacker can initialize the slot first during the seed-proposal vote window.
 *       ORG=TEST6 forge script .../MigrateOrgToAuthority.s.sol:PredeployAuthority \
 *         --rpc-url gnosis --broadcast --slow    (FOUNDRY_PROFILE=production)
 *
 *  2. GenerateBatches (FORK, no broadcast): build the §6 seed + cutover batches from
 *     LIVE state and write proposal-ready JSON to script/accessv2/out/<org>.*.json.
 *     The org crafts each batch as a 1-option executable HybridVoting proposal (the
 *     frontend flow), IN ORDER, finalizing each with an EXPLICIT gas limit:
 *       cast send <HV> 'announceWinner(uint256)' <id> --gas-limit <per-JSON figure>
 *     REGENERATE immediately before the cutover proposal is created (delta-seed:
 *     the batches are state-derived; §6 freezes legacy joins between snapshot and
 *     cutover for KUBI-sized orgs).
 *       ORG=TEST6 forge script .../MigrateOrgToAuthority.s.sol:GenerateBatches \
 *         --fork-url gnosis-gateway   (FOUNDRY_PROFILE=production)
 *
 *  3. SimMigrate<Org> (FORK, no broadcast): the FULL governance loop — predeploy via
 *     DD exactly as broadcast will, then every seed batch and the cutover batch each
 *     as a REAL HybridVoting proposal: createProposal (a live creator-hat wearer) →
 *     vote (live member wearers) → warp → announceWinner with measured gas — then the
 *     §6 assertion set (seed invariant, membership/vouch parity, behavioral probes,
 *     rollback). This closes the loop RehearseMigration leaves open (it pranks
 *     executor.execute directly): here the exact JSON that ships is executed through
 *     the exact proposal machinery that will execute it in production.
 * ============================================================================
 */

interface IHVGov {
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
}

abstract contract MigrateOrgBase is OrgCatalog {
    address internal constant DD_DEPLOYER = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    // JSON output subdirectory. GOVERNED SIMS set "sim/": their batches
    // embed sim-ephemeral protocol addresses (freshly-deployed router/verifier on the fork) and must
    // NEVER clobber the production artifacts GenerateBatches writes to out/ directly.
    string internal _outSubdir = "";
    uint32 internal constant VOTE_MINUTES = 10; // sim cadence; real proposals use org-chosen durations

    /*──────────────────── DD CREATE2 predeploy (shared by broadcast + sim) ────────────────────*/

    function _proxySalt(OrgSpec memory s) internal view returns (bytes32) {
        return DeterministicDeployer(DD_DEPLOYER).computeSalt(string.concat("MembershipAuthorityProxy:", s.name), "v1");
    }

    function _proxyInitCode(OrgSpec memory s) internal view returns (bytes memory) {
        address beacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
        require(beacon != address(0), "MA beacon not registered (run protocol wave first)");
        // C5 (front-run grief close): deploy the proxy WITH init data so it lands
        // ATOMICALLY initialized (empty-genesis: executor/orgId/paused). An attacker can no longer
        // initialize the predicted CREATE2 slot first during the seed-proposal voting window.
        bytes memory initData = abi.encodeCall(IMembershipAuthority.initialize, (_minimalInit(s)));
        return abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, initData));
    }

    function _predictedAuthority(OrgSpec memory s) internal view returns (address) {
        return DeterministicDeployer(DD_DEPLOYER).computeAddress(_proxySalt(s));
    }

    function _ddDeployAuthority(OrgSpec memory s) internal returns (address authority) {
        authority = _predictedAuthority(s);
        if (authority.code.length == 0) {
            address deployed = DeterministicDeployer(DD_DEPLOYER).deploy(_proxySalt(s), _proxyInitCode(s));
            require(deployed == authority, "DD address mismatch");
        } else {
            // A7 (CLAUDE.md point 6): the CREATE2 slot is already occupied. Adopting it
            // blindly would let the ceremony bind FOREIGN bytecode (a colliding salt, or stale code
            // registered under a different version) as the org's authority. Two layered guards:
            //  (1) CODEHASH: the occupant runtime MUST be a BeaconProxy pointing at THIS org's MA beacon —
            //      reject any non-proxy / wrong-beacon bytecode at the colliding slot. Compared against a
            //      throwaway reference proxy on the same beacon (BeaconProxy runtimeCode is unavailable —
            //      it carries an immutable — so a fresh reference deploy is the robust codehash source).
            //  (2) SEMANTIC: the proxy is THIS org's atomically-initialized authority (executor + paused
            //      match the empty-genesis init) — catches a legit-but-foreign BeaconProxy for another org.
            address maBeacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
            bytes32 refCodehash = address(new BeaconProxy(maBeacon, "")).codehash;
            require(
                authority.codehash == refCodehash,
                "CREATE2 slot occupant is not a MembershipAuthority BeaconProxy (foreign bytecode)"
            );
            try IMembershipAuthority(authority).executor() returns (address ex) {
                require(ex == s.executor, "CREATE2 slot occupied by a DIFFERENT org's authority (wrong executor)");
                require(
                    IMembershipAuthority(authority).paused(),
                    "CREATE2 slot occupant not born-paused (not our empty-genesis predeploy)"
                );
            } catch {
                revert("CREATE2 slot occupied by FOREIGN bytecode (executor() reverted)");
            }
        }
    }

    /*──────────────────── Real governance loop (create → vote → warp → announce) ────────────────────*/

    /// @dev Drive one batch through the org's REAL HybridVoting: a live creator-hat wearer creates a
    ///      1-option executable proposal, live member wearers vote it, warp past close, announceWinner
    ///      with an explicit stipend (measured — the ops gas-limit figure). Reverts if invalid.
    function _govern(OrgSpec memory s, IExecutor.Call[] memory batch, string memory title, address[] memory candidates)
        internal
        returns (uint256 id, uint256 gasUsed, uint256 createGas)
    {
        address creator = _findLegacyCreator(s, candidates);
        require(creator != address(0), "no live creator-hat wearer among candidates");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;
        id = IHVGov(s.hv).proposalsCount();
        // A7: HybridVotingProposals._initProposal SSTOREs the ENTIRE batches calldata,
        // so createProposal — not announceWinner — is often the most expensive tx in the ceremony and is
        // the one orgs pay for via a sponsored passkey userOp. Measure it so ops can size the userOp gas
        // and confirm the HV createProposal rulebook hint (0 == uncapped) cannot hint-reject it.
        uint256 c0 = gasleft();
        vm.prank(creator);
        IHVGov(s.hv).createProposal(bytes(title), bytes32(0), VOTE_MINUTES, 1, batches, new uint256[](0));
        createGas = c0 - gasleft();

        // Vote with every candidate who can (quorum is participation-based; cast the widest net).
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory wts = new uint8[](1);
        idxs[0] = 0;
        wts[0] = 100;
        uint256 voted;
        for (uint256 i; i < candidates.length; ++i) {
            vm.prank(candidates[i]);
            try IHVGov(s.hv).vote(id, idxs, wts) {
                voted++;
            } catch {}
        }
        require(voted > 0, "no candidate could vote the proposal");

        vm.warp(vm.getBlockTimestamp() + uint256(VOTE_MINUTES) * 60 + 60);

        // Explicit stipend mirrors the broadcast --gas-limit; measured so ops can size the live call
        // (CLAUDE.md: announceWinner's try/catch makes eth_estimateGas under-fund the tx).
        uint256 g0 = gasleft();
        (, bool valid) = HVAnnounce(s.hv).announceWinner{gas: 12_000_000}(id);
        gasUsed = g0 - gasleft();
        require(valid, "proposal did not reach a valid outcome (quorum?)");
        console.log(string.concat("  [gov] ", title, " proposal #"), id);
        console.log("        voters:", voted, "announceWinner gas:", gasUsed);
        console.log("        createProposal gas:", createGas);
    }

    function _findLegacyCreator(OrgSpec memory s, address[] memory candidates) internal view returns (address) {
        uint256[] memory ch = IHVGov(s.hv).creatorHats();
        for (uint256 i; i < ch.length; ++i) {
            for (uint256 j; j < candidates.length; ++j) {
                if (IHatsLocal(HATS).isWearerOfHat(candidates[j], ch[i])) return candidates[j];
            }
        }
        return address(0);
    }

    /*──────────────────── Governed end-to-end sim (per org) ────────────────────*/

    function _governedMigrate(OrgSpec memory s) internal {
        _outSubdir = "sim/"; // sim-ephemeral addresses -> out/sim/, never the production out/ files
        address[] memory candidates = _loadCandidates(s.name);
        console.log(string.concat("\n=== GOVERNED MIGRATE (sim): ", s.name, " ==="));
        require(_topHatDomain(s) != 0, "recorded topHat domain is zero");
        _ddLegacyPre = _ddLegacySnapshot(s.dd);

        // Protocol wave effects (pranked-Hudson replica of the D1 scripts).
        address router = _setupProtocol(s);

        // Predeploy EXACTLY as broadcast will: DD CREATE2 at the predicted address.
        // DeterministicDeployer.deploy is onlyOwner (Hudson) — same signer as the broadcast step.
        _discoverSubjects(s);
        // T3: real legacy kick injected BEFORE the seed proposals are built (ban path non-vacuity).
        _injectSyntheticBan(s, candidates);
        // T5: guarantee the per-project TM override resolution path executes on this org.
        _ensureTmOverrideRow(s, candidates);
        vm.startPrank(HUDSON);
        address authority = _ddDeployAuthority(s);
        vm.stopPrank();
        console.log("  authority (DD-predicted):", authority);

        // Seed batches — each one a REAL governance proposal (and emitted as proposal JSON, so the
        // sim-verified batches double as the reviewable out/ artifacts).
        IExecutor.Call[][] memory seedBatches = _buildSeedBatches(s, authority, candidates);
        // A7: track the LARGEST createProposal cost across the seed batches — the
        // proposal orgs author via a sponsored passkey userOp — and report it against the HV createProposal
        // rulebook hint (0 == uncapped) so ops can confirm no hint-rejection and size the userOp.
        uint256 maxCreateGas;
        uint256 maxCreateBatch;
        for (uint256 b; b < seedBatches.length; ++b) {
            _writeBatchJson(s, "seed", b + 1, seedBatches[b], authority);
            (,, uint256 createGas) =
                _govern(s, seedBatches[b], string.concat("access-v2 seed ", vm.toString(b + 1)), candidates);
            if (createGas > maxCreateGas) {
                maxCreateGas = createGas;
                maxCreateBatch = b + 1;
            }
        }
        console.log("  [A7] LARGEST seed createProposal gas:", maxCreateGas);
        console.log("       (seed batch #):", maxCreateBatch);
        console.log("       HV createProposal rulebook hint is 0 (UNCAPPED) -> no hint under-fund possible");
        require(IMembershipAuthority(authority).paused(), "authority must be paused after seeding");
        uint256 seeded = _assertSeedInvariant(s, authority, candidates);
        console.log("  SEED INVARIANT ok; seeded memberships:", seeded);
        _captureExpectations(s, candidates);
        // T5: INDEPENDENT legacy TM oracle, read from the live TM's own storage PRE-cutover.
        _captureTmOracle(s, candidates);

        // T1: LEGACY zk-claim baseline (snapshot-isolated) — the independent pre-cutover expectation
        //     the post-cutover continuity probe must reproduce.
        _zkLegacyBaseline(s);

        // A5 DRIFT DRILL (isolated snapshot): a fresh legacy wearer joins after the seed proposals
        // executed; prove the STALE cutover reverts on-chain and a regenerated DELTA cutover ports them.
        _driftDrill(s, authority, router, candidates);

        // Cutover — one atomic governance proposal (§6 order; no drift here → delta empty, bindIdx 0).
        (IExecutor.Call[] memory cutover, uint256 bindIdx) = _buildCutoverBatch(s, authority, router, candidates);
        require(bindIdx == 0, "router bind must lead the cutover batch (no drift expected here)");
        _writeBatchJson(s, "cutover", 1, cutover, authority);
        _govern(s, cutover, "access-v2 cutover", candidates);
        _assertCutoverLanded(s, authority, router);

        (uint256 checked, uint256 matched) = _assertMembershipParity(s, authority, candidates);
        console.log("  MEMBERSHIP PARITY:", matched, "/", checked);
        require(checked == matched, "membership parity mismatch");
        _assertVouchParity(s, authority, candidates);
        _probeBehaviors(s, authority, router, candidates);
        _assertRollback(s, authority);

        console.log(string.concat("PASS: ", s.name, " governed migration sim complete."));
    }

    /*──────────────────── A5 drift drill (delta-seed vs stale-batch revert) ────────────────────*/

    /// @dev A5: the drift drill. After the seeds executed, a NEW legacy
    ///      member joins (force-eligible + mint via the EligibilityModule superAdmin = Executor). Then:
    ///        (i)  the STALE cutover (built pre-drift, expectedSupplies baked before the join) REVERTS
    ///             on-chain — the CutoverVerifier SupplyDrift guard catches the fresh wearer that the
    ///             authority memberCount is blind to (proves drift protection is real, not sim-only);
    ///        (ii) a REGENERATED cutover (candidate set now including the newcomer) carries a delta-seed
    ///             at its head, ports the newcomer, and the in-batch verifier PASSES.
    ///      Runs inside a snapshot so it does not perturb the clean cutover that follows.
    function _driftDrill(OrgSpec memory s, address authority, address router, address[] memory candidates) internal {
        uint256 snap = vm.snapshotState();

        // Build the STALE cutover at the current (no-drift) state — expectedSupplies baked pre-join.
        (IExecutor.Call[] memory stale, uint256 staleBind) = _buildCutoverBatch(s, authority, router, candidates);
        require(staleBind == 0, "A5: pre-drift cutover unexpectedly carries a delta");

        // A fresh legacy wearer joins — through the org's REAL join channel wherever one exists (T6).
        (uint256 subj, address newcomer, string memory channel, bool indexed_) = _joinLegacyNewcomer(s);
        require(newcomer != address(0), "A5 drill: could not join a legacy newcomer on any subject");
        console.log(string.concat("  [A5] fresh legacy wearer joined via ", channel, " on subject:"), subj);
        // T6: the production recovery loop is "re-enumerate (tools/enumerate-wearers.sh) -> regenerate ->
        //     cutover passes". That enumerator's ONLY sources are Executor.HatsMinted and
        //     QuickJoin.QuickJoined, so a joiner invisible to both can never be picked up and ops would
        //     sit in an unresolvable SupplyDrift loop. Assert the drill's joiner IS visible to it (or say
        //     loudly, per org, that no indexed channel exists — Poa has no permissionless join at all).
        if (indexed_) {
            console.log("  [T6] joiner emitted an enumerator-visible event -> re-enumeration WOULD find them");
        } else {
            console.log(
                "  [T6] NOTE: this org has NO permissionless join channel (governance/EM direct-mint only),"
                " so the drill's joiner emits neither HatsMinted nor QuickJoined and the candidate refresh"
                " cannot see them. Recovery there is a governance mint, not a re-enumeration."
            );
        }

        // (i) the STALE cutover must REVERT atomically at the verifier — and specifically with
        //     CutoverVerifier.SupplyDrift (T6: the old blanket `catch {}` passed on ANY revert, so a
        //     future reordering of verifier checks or an unrelated side effect of the drill's own state
        //     changes would keep the drill green while the specific guard degraded). Executed directly
        //     through the Executor so the revert BUBBLES (announceWinner's try/catch would swallow it —
        //     that swallowing is the silent-no-op hazard; the drill asserts the batch itself reverts).
        vm.prank(s.votingContract);
        try IExecMig(s.executor).execute(90901, stale) {
            revert("A5 DRIFT: stale cutover did NOT revert despite a fresh legacy wearer (guard dead)");
        } catch (bytes memory err) {
            (bytes memory inner, uint256 failedIdx, bool wrapped) = _unwrapCallFailed(err);
            require(wrapped, "A5 DRIFT: stale cutover revert is not Executor.CallFailed (unexpected shape)");
            require(inner.length >= 4, "A5 DRIFT: verifier reverted with EMPTY data (not SupplyDrift)");
            require(
                bytes4(inner) == CutoverVerifier.SupplyDrift.selector,
                "A5 DRIFT: stale cutover reverted for the WRONG reason (expected CutoverVerifier.SupplyDrift)"
            );
            require(failedIdx == stale.length - 1, "A5 DRIFT: the failing call was not the trailing verify()");
        }
        console.log("  [A5] stale cutover REVERTED with CutoverVerifier.SupplyDrift (selector-decoded)");

        // (ii) regenerate WITH the newcomer in the candidate set → delta-seed leads the cutover, ports it.
        address[] memory augmented = _appendAddr(candidates, newcomer);
        (IExecutor.Call[] memory deltaCut, uint256 deltaBind) = _buildCutoverBatch(s, authority, router, augmented);
        require(deltaBind > 0, "A5: regenerated cutover has no delta-seed despite drift");
        require(deltaCut[deltaBind].target == router, "A5: router bind not at bindIndex after delta");
        vm.prank(s.votingContract);
        IExecMig(s.executor).execute(90902, deltaCut);
        require(IMembershipAuthority(authority).isMember(subj, newcomer), "A5: delta cutover did not port the newcomer");
        _assertCutoverLanded(s, authority, router);
        console.log("  [A5] delta cutover ported the newcomer; in-batch verifier PASSED. bindIndex:", deltaBind);

        vm.revertToState(snap);
    }

    /// @dev T6: a fresh legacy wearer joins through the org's REAL join channel,
    ///      preferred in this order — the executor-superAdmin direct-mint is a LAST resort, not the
    ///      default, precisely because it emits neither Executor.HatsMinted nor QuickJoin.QuickJoined and
    ///      is therefore invisible to tools/enumerate-wearers.sh (so the "re-enumerate -> regenerate ->
    ///      cutover passes" recovery loop the drill claims to prove would never see the joiner):
    ///        (1) OPEN member role (DecentralPark)  -> UniversalAccountRegistry.registerAccount then
    ///            QuickJoin.quickJoinWithUser()      — the real permissionless POP join.
    ///        (2) zk-email org (Test6, KUBI)        -> the LIVE ZkEmailInvites claim entrypoint
    ///                                                (their ONLY permissionless join channel).
    ///        (3) governance-only org (Poa)         -> EligibilityModule superAdmin direct-mint; there
    ///                                                IS no permissionless channel, reported as such.
    ///      Returns the subject, the joiner, a human-readable channel label, and whether the join
    ///      emitted an event the production candidate enumerator can actually see.
    function _joinLegacyNewcomer(OrgSpec memory s)
        internal
        returns (uint256 subject, address newcomer, string memory channel, bool enumeratorVisible)
    {
        newcomer = address(uint160(uint256(keccak256(abi.encode(s.orgId, "a5-drift-newcomer")))));

        // (1) the REAL QuickJoin chain, where the org's member role is genuinely open.
        if (s.expectOpenMember && _memberSubject != 0) {
            vm.recordLogs();
            address reg = address(IQJJoin(s.qj).accountRegistry());
            vm.prank(newcomer);
            try IUARJoin(reg).registerAccount("a5-drift-newcomer") {} catch {}
            vm.prank(newcomer);
            try IQJJoin(s.qj).quickJoinWithUser() {} catch {}
            if (IHatsMin(HATS).isWearerOfHat(newcomer, _memberSubject)) {
                return (_memberSubject, newcomer, "QuickJoin.quickJoinWithUser (real join)", _sawJoinEvent());
            }
        }

        // (2) the REAL zk-email claim chain (Test6/KUBI's only permissionless join channel).
        if (s.zkEmailInvites != address(0) && _memberSubject != 0) {
            vm.recordLogs();
            (bool ok,) = _zkClaim(s, newcomer, _memberSubject, "a5-drift");
            if (ok && IHatsMin(HATS).isWearerOfHat(newcomer, _memberSubject)) {
                return (_memberSubject, newcomer, "ZkEmailInvites.claimRoleByDomain (real join)", _sawJoinEvent());
            }
        }

        // (3) fallback: EligibilityModule superAdmin (== the org Executor) direct-mint.
        for (uint256 i; i < _subjects.length; ++i) {
            uint256 cand = _subjects[i];
            if (cand == _topHatId(s)) continue; // topHat maxSupply 1 (no headroom)
            (, uint32 maxSupply, uint32 supply,,,,,,) = IHatsMin(HATS).viewHat(cand);
            if (maxSupply <= supply) continue; // no headroom (AllHatsWorn would revert)
            vm.recordLogs();
            vm.startPrank(s.executor);
            try IEMWriteMig(s.eligibilityModule).setWearerEligibility(newcomer, cand, true, true) {} catch {}
            try IEMWriteMig(s.eligibilityModule).mintHatToAddress(cand, newcomer) {
                vm.stopPrank();
                if (IHatsMin(HATS).isWearerOfHat(newcomer, cand)) {
                    return
                        (cand, newcomer, "EligibilityModule superAdmin direct-mint (no open channel)", _sawJoinEvent());
                }
            } catch {
                vm.stopPrank();
            }
        }
        return (0, address(0), "none", false);
    }

    /// @dev Did the recorded logs carry an event tools/enumerate-wearers.sh indexes? Its only two
    ///      sources are Executor.HatsMinted(address,uint256[]) and QuickJoin.QuickJoined(address,uint256[]).
    function _sawJoinEvent() internal returns (bool) {
        bytes32 hatsMinted = keccak256("HatsMinted(address,uint256[])");
        bytes32 quickJoined = keccak256("QuickJoined(address,uint256[])");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == hatsMinted || logs[i].topics[0] == quickJoined) return true;
        }
        return false;
    }

    /// @dev Unwrap Executor.execute's `CallFailed(uint256 index, bytes lowLevelData)` so the drill can
    ///      assert the INNER revert selector rather than accepting any revert (T6).
    function _unwrapCallFailed(bytes memory err)
        internal
        pure
        returns (bytes memory inner, uint256 index, bool wrapped)
    {
        if (err.length < 4 || bytes4(err) != bytes4(keccak256("CallFailed(uint256,bytes)"))) {
            return (inner, 0, false);
        }
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        (index, inner) = abi.decode(body, (uint256, bytes));
        wrapped = true;
    }

    function _appendAddr(address[] memory arr, address x) internal pure returns (address[] memory out) {
        out = new address[](arr.length + 1);
        for (uint256 i; i < arr.length; ++i) {
            out[i] = arr[i];
        }
        out[arr.length] = x;
    }

    /*──────────────────── Proposal JSON emission ────────────────────*/

    /// @dev The per-org announceWinner --gas-limit, unified with MIGRATION-RUNBOOK.md's measured gas
    ///      table (the ONLY gas figure the JSON carries). KUBI's seed.3 measured 3.13M (above the old
    ///      3M guidance that reproduced the Test6-#23 silent no-op) → 5M; the other three → 4M. This
    ///      replaces the stale blanket 12M (near Gnosis's ~17M block limit if a frontend forwards it).
    function _announceGasLimit(OrgSpec memory s) internal pure returns (uint256) {
        return keccak256(bytes(s.name)) == keccak256("KUBI") ? 5_000_000 : 4_000_000;
    }

    function _writeBatchJson(
        OrgSpec memory s,
        string memory kind,
        uint256 idx,
        IExecutor.Call[] memory batch,
        address authority
    ) internal {
        string memory json = string.concat(
            "{\n",
            "  \"org\": \"",
            s.name,
            "\",\n  \"kind\": \"",
            kind,
            "\",\n  \"index\": ",
            vm.toString(idx),
            ",\n  \"authority\": \"",
            vm.toString(authority),
            "\",\n  \"hybridVoting\": \"",
            vm.toString(s.hv),
            "\",\n  \"announceWinnerGasLimit\": ",
            vm.toString(_announceGasLimit(s)),
            ",\n  \"note\": \"1-option executable proposal; finalize with an explicit --gas-limit (announceWinner try/catch defeats eth_estimateGas). This is the per-org runbook figure; see MIGRATION-RUNBOOK.md gas table.\",\n  \"calls\": ["
        );
        for (uint256 i; i < batch.length; ++i) {
            json = string.concat(
                json,
                i == 0 ? "\n" : ",\n",
                "    {\"target\": \"",
                vm.toString(batch[i].target),
                "\", \"value\": 0, \"data\": \"",
                vm.toString(batch[i].data),
                "\"}"
            );
        }
        json = string.concat(json, "\n  ]\n}\n");
        // out/ is gitignored + regenerated — create it on demand so a fresh checkout can
        // generate without a committed artifact directory.
        string memory dir = string.concat(vm.projectRoot(), "/script/accessv2/out/", _outSubdir);
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", _lower(s.name), ".", kind, ".", vm.toString(idx), ".json");
        vm.writeFile(path, json);
        console.log("  wrote", path);
    }
}

interface IHatsLocal {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
}

/// @dev The REAL permissionless join surfaces the T6 drift drill prefers over an EM direct-mint.
interface IQJJoin {
    function accountRegistry() external view returns (address);
    function quickJoinWithUser() external;
}

interface IUARJoin {
    function registerAccount(string calldata username) external;
}

interface HVAnnounce {
    function announceWinner(uint256 id) external returns (uint256 winner, bool valid);
}

/* ════════════════════════════ 1. Predeploy (broadcast) ════════════════════════════ */

/// @notice BROADCAST: CREATE2-deploy the ORG's authority proxy (atomically initialized) at its predicted
///         address. Env: ORG=TEST6|DP|KUBI|POA. Signer MUST be the DeterministicDeployer owner
///         (Hudson — deploy is onlyOwner). Safe to re-run (no-op once deployed).
contract PredeployAuthority is MigrateOrgBase {
    function run() public {
        OrgSpec memory s = _specByKey(vm.envString("ORG"));
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address predicted = _predictedAuthority(s);
        console.log(string.concat("\n=== PREDEPLOY authority proxy: ", s.name, " ==="));
        console.log("  predicted:", predicted);
        vm.startBroadcast(key);
        address authority = _ddDeployAuthority(s);
        vm.stopBroadcast();
        require(authority == predicted && authority.code.length > 0, "predeploy failed");
        require(IMembershipAuthority(authority).executor() == s.executor, "predeploy not atomically initialized");
        require(IMembershipAuthority(authority).paused(), "predeploy authority must be born paused");
        console.log("  deployed (atomically initialized, PAUSED; awaiting seed proposal #1):", authority);
    }
}

/* ════════════════════════════ 2. Generate proposal JSON (fork) ════════════════════════════ */

/// @notice FORK (no broadcast): build the seed + cutover batches from LIVE state and write
///         proposal-ready JSON to script/accessv2/out/. Env: ORG=TEST6|DP|KUBI|POA.
///         REGENERATE right before the cutover proposal is created (delta-seed discipline, §6).
contract GenerateBatches is MigrateOrgBase {
    error InvalidCutoverPrefixOrder();

    function run() public {
        OrgSpec memory s = _specByKey(vm.envString("ORG"));
        address[] memory candidates = _loadCandidates(s.name);
        console.log(string.concat("\n=== GENERATE proposal batches: ", s.name, " ==="));

        address authority = _predictedAuthority(s);
        require(authority.code.length > 0, "run PredeployAuthority first");
        _discoverSubjects(s);

        IExecutor.Call[][] memory seedBatches = _buildSeedBatches(s, authority, candidates);
        for (uint256 b; b < seedBatches.length; ++b) {
            _writeBatchJson(s, "seed", b + 1, seedBatches[b], authority);
        }

        // Cutover references the router singleton — resolve it from the hub's live pointer (the
        // protocol wave repointed hub.HATS() to the router; before that wave this correctly reverts).
        address router = _hubHats(s);
        require(_isRouter(router), "hub HATS() is not the AuthorityRouter yet (run protocol wave first)");
        // Wire the CANONICAL CutoverVerifier (this was previously never
        // set, so the PRODUCTION cutover JSON carried NO in-batch verification). CREATE3 address is
        // deterministic (salt-only — same type/version strings as RegisterAccessV2Protocol); require
        // deployed code so a pre-protocol-wave generation fails loudly instead of emitting a batch
        // that targets an empty address.
        {
            DeterministicDeployer dd = DeterministicDeployer(DD_DEPLOYER);
            address verifier = dd.computeAddress(dd.computeSalt("CutoverVerifier", "v1"));
            require(verifier.code.length > 0, "CutoverVerifier not deployed (run protocol wave first)");
            _verifier = verifier;
        }
        // A5 delta mode: candidates should be RE-ENUMERATED (tools/enumerate-wearers.sh) immediately
        // before this call so any legacy joiner since the seed is picked up as a delta-seed slice in the
        // cutover prefix. The prefix can also contain idempotent repairs for already-seeded metadata.
        (IExecutor.Call[] memory cutover, uint256 bindIdx) = _buildCutoverBatch(s, authority, router, candidates);
        if (cutover[bindIdx].target != router) revert InvalidCutoverPrefixOrder();
        _writeBatchJson(s, "cutover", 1, cutover, authority);

        console.log("  DONE. Craft proposals from out/*.json IN ORDER (seed.1..n, then cutover.1).");
    }

    function _hubHats(OrgSpec memory s) internal view returns (address) {
        return IPaymasterHats(_paymaster(s)).HATS();
    }

    function _isRouter(address r) internal view returns (bool) {
        if (r == address(0) || r == HATS) return false;
        try IAuthorityRouter(r).authorityOf(0) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}

interface IPaymasterHats {
    function HATS() external view returns (address);
}

/* ════════════════════════════ 3. Governed sims (fork, per org) ════════════════════════════ */

contract SimMigrateTest6 is MigrateOrgBase {
    function run() public {
        _governedMigrate(_test6Spec());
    }
}

contract SimMigrateDecentralPark is MigrateOrgBase {
    function run() public {
        _governedMigrate(_decentralParkSpec());
    }
}

contract SimMigrateKubi is MigrateOrgBase {
    function run() public {
        _governedMigrate(_kubiSpec());
    }
}

contract SimMigratePoa is MigrateOrgBase {
    function run() public {
        _governedMigrate(_poaSpec());
    }
}

/* ════════════════════════════ 4. CLI proposal helpers (broadcast) ════════════════════════════ */

/// @notice BROADCAST: create ONE migration proposal from a generated JSON, as a creator-hat wearer.
///         Env: ORG=TEST6|DP|KUBI|POA, KIND=seed|cutover, INDEX=N, MINUTES (vote window, default 15).
///         Prints the proposal id plus the exact vote/announce commands for it.
contract CreateMigrationProposal is MigrateOrgBase {
    function run() public {
        OrgSpec memory s = _specByKey(vm.envString("ORG"));
        string memory kind = vm.envString("KIND");
        uint256 idx = vm.envUint("INDEX");
        uint32 mins = uint32(vm.envOr("MINUTES", uint256(15)));
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));

        string memory path = string.concat(
            vm.projectRoot(), "/script/accessv2/out/", _lower(s.name), ".", kind, ".", vm.toString(idx), ".json"
        );
        string memory json = vm.readFile(path);

        // Count calls, then load each {target, data} pair.
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".calls[", vm.toString(n), "].target"))) {
            n++;
        }
        require(n > 0, "JSON has no calls (regenerate via GenerateBatches)");
        IExecutor.Call[] memory batch = new IExecutor.Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".calls[", vm.toString(i), "]");
            batch[i] = IExecutor.Call({
                target: vm.parseJsonAddress(json, string.concat(k, ".target")),
                value: 0,
                data: vm.parseJsonBytes(json, string.concat(k, ".data"))
            });
        }
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 id = IHVGov(s.hv).proposalsCount();
        string memory title = string.concat("Access v2 migration - ", s.name, " ", kind, " ", vm.toString(idx));
        vm.startBroadcast(key);
        IHVGov(s.hv).createProposal(bytes(title), bytes32(0), mins, 1, batches, new uint256[](0));
        vm.stopBroadcast();

        uint256 gasLimit = vm.parseJsonUint(json, ".announceWinnerGasLimit");
        console.log(
            string.concat("CREATED proposal #", vm.toString(id), " on ", s.name, " (", vm.toString(n), " calls)")
        );
        console.log(
            string.concat(
                "  vote:     ORG=",
                vm.envString("ORG"),
                " ID=",
                vm.toString(id),
                " forge script ...:VoteMigrationProposal --rpc-url <chain> --broadcast --slow --sender <you>"
            )
        );
        console.log(
            string.concat(
                "  announce (after the window): cast send ",
                vm.toString(s.hv),
                " 'announceWinner(uint256)' ",
                vm.toString(id),
                " --gas-limit ",
                vm.toString(gasLimit),
                " --rpc-url <chain> --private-key $DEPLOYER_PRIVATE_KEY"
            )
        );
    }
}

/// @notice BROADCAST: vote option 0 / weight 100 on a proposal. Env: ORG, ID.
contract VoteMigrationProposal is MigrateOrgBase {
    function run() public {
        OrgSpec memory s = _specByKey(vm.envString("ORG"));
        uint256 id = vm.envUint("ID");
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory wts = new uint8[](1);
        wts[0] = 100;
        vm.startBroadcast(key);
        IHVGov(s.hv).vote(id, idxs, wts);
        vm.stopBroadcast();
        console.log(string.concat("VOTED on #", vm.toString(id), " (option 0, weight 100)"));
    }
}
