// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IExecMig, IPoaManagerMig} from "./AccessV2MigrationBase.sol";
import {OrgCatalog} from "./RehearseMigration.s.sol";
import {IMembershipAuthority} from "../../src/interfaces/IMembershipAuthority.sol";
import {IAuthorityRouter} from "../../src/interfaces/IAuthorityRouter.sol";
import {IExecutor} from "../../src/Executor.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";

/*
 * ============================================================================
 * MigrateOrgToAuthority — the PRODUCTION per-org ceremony (Wave D2, SPEC §6)
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
    uint32 internal constant VOTE_MINUTES = 10; // sim cadence; real proposals use org-chosen durations

    /*──────────────────── DD CREATE2 predeploy (shared by broadcast + sim) ────────────────────*/

    function _proxySalt(OrgSpec memory s) internal view returns (bytes32) {
        return DeterministicDeployer(DD_DEPLOYER).computeSalt(string.concat("MembershipAuthorityProxy:", s.name), "v1");
    }

    function _proxyInitCode(OrgSpec memory s) internal view returns (bytes memory) {
        address beacon = IPoaManagerMig(_poaManager(s)).getBeaconById(MEMBERSHIP_AUTHORITY_TYPEID);
        require(beacon != address(0), "MA beacon not registered (run protocol wave first)");
        // C5 (specOrder-5 front-run grief close): deploy the proxy WITH init data so it lands
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
        }
    }

    /*──────────────────── Real governance loop (create → vote → warp → announce) ────────────────────*/

    /// @dev Drive one batch through the org's REAL HybridVoting: a live creator-hat wearer creates a
    ///      1-option executable proposal, live member wearers vote it, warp past close, announceWinner
    ///      with an explicit stipend (measured — the ops gas-limit figure). Reverts if invalid.
    function _govern(OrgSpec memory s, IExecutor.Call[] memory batch, string memory title, address[] memory candidates)
        internal
        returns (uint256 id, uint256 gasUsed)
    {
        address creator = _findLegacyCreator(s, candidates);
        require(creator != address(0), "no live creator-hat wearer among candidates");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;
        id = IHVGov(s.hv).proposalsCount();
        vm.prank(creator);
        IHVGov(s.hv).createProposal(bytes(title), bytes32(0), VOTE_MINUTES, 1, batches, new uint256[](0));

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
        address[] memory candidates = _loadCandidates(s.name);
        console.log(string.concat("\n=== GOVERNED MIGRATE (sim): ", s.name, " ==="));
        require(_topHatDomain(s) != 0, "recorded topHat domain is zero");
        _ddLegacyPre = _ddLegacySnapshot(s.dd);

        // Protocol wave effects (pranked-Hudson replica of the D1 scripts).
        address router = _setupProtocol(s);

        // Predeploy EXACTLY as broadcast will: DD CREATE2 at the predicted address.
        // DeterministicDeployer.deploy is onlyOwner (Hudson) — same signer as the broadcast step.
        _discoverSubjects(s);
        vm.startPrank(HUDSON);
        address authority = _ddDeployAuthority(s);
        vm.stopPrank();
        console.log("  authority (DD-predicted):", authority);

        // Seed batches — each one a REAL governance proposal (and emitted as proposal JSON, so the
        // sim-verified batches double as the reviewable out/ artifacts).
        IExecutor.Call[][] memory seedBatches = _buildSeedBatches(s, authority, candidates);
        for (uint256 b; b < seedBatches.length; ++b) {
            _writeBatchJson(s, "seed", b + 1, seedBatches[b], authority);
            _govern(s, seedBatches[b], string.concat("access-v2 seed ", vm.toString(b + 1)), candidates);
        }
        require(IMembershipAuthority(authority).paused(), "authority must be paused after seeding");
        uint256 seeded = _assertSeedInvariant(s, authority, candidates);
        console.log("  SEED INVARIANT ok; seeded memberships:", seeded);
        _captureExpectations(s, candidates);

        // Cutover — one atomic governance proposal (§6 order asserted structurally).
        (IExecutor.Call[] memory cutover, uint256 bindIdx) = _buildCutoverBatch(s, authority, router);
        require(bindIdx == 0, "router bind must lead the cutover batch");
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

    /*──────────────────── Proposal JSON emission ────────────────────*/

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
            "\",\n  \"announceWinnerGasLimit\": 12000000,\n  \"note\": \"1-option executable proposal; finalize with an explicit --gas-limit (announceWinner try/catch defeats eth_estimateGas)\",\n  \"calls\": ["
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
        string memory path = string.concat(
            vm.projectRoot(), "/script/accessv2/out/", _lower(s.name), ".", kind, ".", vm.toString(idx), ".json"
        );
        vm.writeFile(path, json);
        console.log("  wrote", path);
    }
}

interface IHatsLocal {
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
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
        (IExecutor.Call[] memory cutover, uint256 bindIdx) = _buildCutoverBatch(s, authority, router);
        require(bindIdx == 0, "router bind must lead the cutover batch");
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
