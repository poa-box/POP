// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {MigrateOrgBase, IHVGov, HVAnnounce} from "./MigrateOrgToAuthority.s.sol";
import {IMembershipAuthority} from "../../src/interfaces/IMembershipAuthority.sol";
import {AccessV2Types} from "../../src/libs/AccessV2Types.sol";
import {AccessV2PermKeys} from "../../src/libs/AccessV2PermKeys.sol";
import {IExecutor} from "../../src/Executor.sol";

/*
 * ============================================================================
 * KubiRoles — KUBI (Kansas Blockchain) board-roles setup, one governance batch
 * ============================================================================
 *
 * Creates the 10 board title ROLES + the "Executives" GROUP composed over them,
 * and seats the 11 board members. NO perm rows are attached (the board's ask:
 * "no extra permissions for now") — every seat-holder is already a KUBI Member,
 * which carries the org's day-to-day perms; a future vote can attach perms to
 * the GROUP once and reach every title-holder through composition.
 *
 * ORDERING (load-bearing): this proposal is created alongside the cutover in
 * migrate-kubi.sh round 2 but must be ANNOUNCED strictly AFTER the cutover
 * executes. All four call families are pause-exempt, so a premature execution
 * would not revert — it would backdate seats (paused ⇒ acceptedAt=1) and drift
 * the subject counts the CutoverVerifier baked, burning the cutover proposal.
 * migrate-kubi.sh enforces cutover-then-roles announce order.
 *
 * ID PREDICTION: createRole/createGroup auto-allocate (authority << 64) | ++localSeq.
 * Migration seeds adopt literal legacy hat ids and never bump localSeq, so the
 * first runtime allocation is seq 1 → roles land at seq 1..10, group at 11.
 * SimKubiRoles replays the FULL migration then this batch on a live fork and
 * hard-asserts every predicted id, so any localSeq drift fails the sim loudly.
 *
 *   Generate the production JSON (out/kubi.roles.1.json):
 *     ORG=KUBI forge script script/accessv2/KubiRoles.s.sol:GenerateKubiRoles \
 *       --fork-url gnosis   (FOUNDRY_PROFILE=production)
 *   Fork-sim end to end (migration + roles, ~minutes):
 *     forge script script/accessv2/KubiRoles.s.sol:SimKubiRoles \
 *       --fork-url gnosis-gateway   (FOUNDRY_PROFILE=production)
 * ============================================================================
 */
abstract contract KubiRolesBase is MigrateOrgBase {
    uint256 internal constant N_ROLES = 10;
    uint256 internal constant N_SEATS = 11;

    function _titles() internal pure returns (string[N_ROLES] memory t) {
        t = [
            "Co-President",
            "VP of Business",
            "VP of Engineering",
            "VP of Education",
            "Director of Finance",
            "Director of Engineering",
            "Director of Education",
            "Director of Research and Development",
            "Director of Product and Innovation",
            "Director of Public Relations"
        ];
    }

    /// @dev maxMembers per title (seat counts; 2 Co-Presidents). Changeable later via setMaxMembers vote.
    function _caps() internal pure returns (uint32[N_ROLES] memory c) {
        c = [uint32(2), 1, 1, 1, 1, 1, 1, 1, 1, 1];
    }

    /// @dev (roleIdx, holder) seat assignments. Usernames resolved 2026-09-02 via UniversalAccountRegistry.
    function _seats() internal pure returns (uint256[N_SEATS] memory roleIdx, address[N_SEATS] memory who) {
        roleIdx = [uint256(0), 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
        who = [
            0x27677cD05185395be6DCe86b1c251410EC3c6239, // cdoherty       Co-President
            0x439831a0C10F834D6Bc6f62917834DdCaa203dCf, // caleb          Co-President
            0x69dd72d16c549699B599f23b43eC5A1E02fe392a, // alex           VP of Business
            0xb1D73DA3fD6891d9D7225413A02f005E3A4b511f, // nischay        VP of Engineering
            0x8D8612fABF6E94591e29796Ed0Fb2e18D6DcFBcd, // wolfiesell     VP of Education
            0x287a2eeD60cE19a621e3B0E3f3E322c3998B561d, // anthony        Director of Finance
            0xDa13dF65951D18E27a62695466Ce390E94C43a8c, // shivakabalee   Director of Engineering
            0xB1392EFc004ad50292C809f28DAFC746c404aed0, // wcalhoun04     Director of Education
            0x3698191f7fAbdD89DF5F1206141F9ad1f400E904, // sigmaheet      Director of R&D
            0xDdBEfE3B77902b9E31962e038Ad809d07C815796, // jag            Director of Product and Innovation
            0x94ae540518F0FC6eDA37cB7D76cf9da660345B83 // sharivapradhan  Director of Public Relations
        ];
    }

    function _roleId(address authority, uint256 seq) internal pure returns (uint256) {
        return (uint256(uint160(authority)) << 64) | seq;
    }

    /// @dev Post-cutover twin of `_govern`: identical create→vote→warp→announce loop, but the
    ///      creator is found through the AUTHORITY (hasPerm HV_CREATE) — the legacy creator-hat
    ///      scan `_govern` uses returns nobody once the cutover toggles the hat tree off.
    function _governPostCutover(
        OrgSpec memory s,
        address authority,
        IExecutor.Call[] memory batch,
        string memory title,
        address[] memory candidates
    ) internal returns (uint256 id, uint256 gasUsed) {
        IMembershipAuthority a = IMembershipAuthority(authority);
        address creator;
        for (uint256 i; i < candidates.length; ++i) {
            if (a.hasPerm(candidates[i], AccessV2PermKeys.HV_CREATE, bytes32(0)) != 0) {
                creator = candidates[i];
                break;
            }
        }
        require(creator != address(0), "no authority-side HV_CREATE holder among candidates");

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;
        id = IHVGov(s.hv).proposalsCount();
        vm.prank(creator);
        IHVGov(s.hv).createProposal(bytes(title), bytes32(0), VOTE_MINUTES, 1, batches, new uint256[](0));

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
        require(voted >= 2, "post-cutover quorum not reachable (fewer than 2 candidates could vote)");

        vm.warp(vm.getBlockTimestamp() + uint256(VOTE_MINUTES) * 60 + 60);
        uint256 g0 = gasleft();
        (, bool valid) = HVAnnounce(s.hv).announceWinner{gas: 12_000_000}(id);
        gasUsed = g0 - gasleft();
        require(valid, "roles proposal did not reach a valid outcome (quorum?)");
        console.log(string.concat("  [gov] ", title, " proposal #"), id);
        console.log("        voters:", voted, "announceWinner gas:", gasUsed);
    }

    /// @dev 13 calls (≤ Executor.MAX_CALLS_PER_BATCH 20): 10 createRole, 1 createGroup
    ///      (composes all 10 in one call), then the canonical seedRules+seedMemberships
    ///      pair for the 11 seats (11 ≤ SEED_CHUNK 20; rules land before memberships).
    function _buildRolesBatch(address authority) internal pure returns (IExecutor.Call[] memory batch) {
        string[N_ROLES] memory titles = _titles();
        uint32[N_ROLES] memory caps = _caps();
        (uint256[N_SEATS] memory roleIdx, address[N_SEATS] memory who) = _seats();

        batch = new IExecutor.Call[](N_ROLES + 3);
        for (uint256 i; i < N_ROLES; ++i) {
            batch[i] = IExecutor.Call({
                target: authority,
                value: 0,
                data: abi.encodeCall(IMembershipAuthority.createRole, (titles[i], bytes32(0), "", caps[i]))
            });
        }

        uint256[] memory memberRoleIds = new uint256[](N_ROLES);
        for (uint256 i; i < N_ROLES; ++i) {
            memberRoleIds[i] = _roleId(authority, i + 1);
        }
        batch[N_ROLES] = IExecutor.Call({
            target: authority,
            value: 0,
            data: abi.encodeCall(IMembershipAuthority.createGroup, ("Executives", bytes32(0), "", memberRoleIds))
        });

        uint256[] memory subs = new uint256[](N_SEATS);
        address[] memory users = new address[](N_SEATS);
        AccessV2Types.RuleKind[] memory kinds = new AccessV2Types.RuleKind[](N_SEATS);
        bool[] memory delegable = new bool[](N_SEATS);
        for (uint256 i; i < N_SEATS; ++i) {
            subs[i] = _roleId(authority, roleIdx[i] + 1);
            users[i] = who[i];
            kinds[i] = AccessV2Types.RuleKind.Grant;
            delegable[i] = true; // delegate-manageable; renounce fully unwinds (not sticky founder-style seats)
        }
        batch[N_ROLES + 1] = IExecutor.Call({
            target: authority,
            value: 0,
            data: abi.encodeCall(IMembershipAuthority.seedRules, (subs, users, kinds, delegable))
        });
        batch[N_ROLES + 2] = IExecutor.Call({
            target: authority, value: 0, data: abi.encodeCall(IMembershipAuthority.seedMemberships, (subs, users))
        });
    }
}

/// @notice Writes the proposal-ready out/kubi.roles.1.json against the CREATE3-predicted authority.
contract GenerateKubiRoles is KubiRolesBase {
    function run() external {
        OrgSpec memory s = _kubiSpec();
        address authority = _predictedAuthority(s);
        IExecutor.Call[] memory batch = _buildRolesBatch(authority);
        _writeBatchJson(s, "roles", 1, batch, authority);
        console.log("kubi.roles.1.json written; calls:", batch.length);
        console.log("authority:", authority);
    }
}

/// @notice FULL fork sim: governed migration (seeds + cutover + parity + probes), then the roles
///         batch through the same real HybridVoting machinery, then the assertion set.
contract SimKubiRoles is KubiRolesBase {
    function run() external {
        OrgSpec memory s = _kubiSpec();
        address authority = _predictedAuthority(s);

        _governedMigrate(s);

        IMembershipAuthority auth = IMembershipAuthority(authority);
        // localSeq must be untouched by the entire migration (adopted legacy ids only).
        require(!auth.getSubject(_roleId(authority, 1)).exists, "localSeq drifted: seq 1 already allocated");

        IExecutor.Call[] memory batch = _buildRolesBatch(authority);
        (uint256 id, uint256 gasUsed) =
            _governPostCutover(s, authority, batch, "KUBI board roles setup", _loadCandidates(s.name));
        console.log("roles proposal executed, id:", id, "announceWinner gas:", gasUsed);

        // 1. Every title role at its predicted id, right kind/name/cap.
        string[N_ROLES] memory titles = _titles();
        uint32[N_ROLES] memory caps = _caps();
        for (uint256 i; i < N_ROLES; ++i) {
            IMembershipAuthority.SubjectInfo memory si = auth.getSubject(_roleId(authority, i + 1));
            require(si.exists, "role subject missing");
            require(si.kind == AccessV2Types.SubjectKind.Role, "role kind wrong");
            require(keccak256(bytes(si.name)) == keccak256(bytes(titles[i])), "role name wrong");
            require(si.maxMembers == caps[i], "role cap wrong");
        }

        // 2. The group at seq 11, kind Group.
        uint256 groupId = _roleId(authority, N_ROLES + 1);
        IMembershipAuthority.SubjectInfo memory gi = auth.getSubject(groupId);
        require(gi.exists && gi.kind == AccessV2Types.SubjectKind.Group, "Executives group wrong");
        require(keccak256(bytes(gi.name)) == keccak256("Executives"), "group name wrong");

        // 3. Every seat: accepted member of the title role AND (derived) of the group,
        //    stamped post-cutover (block.timestamp, not the paused-era backdate).
        (uint256[N_SEATS] memory roleIdx, address[N_SEATS] memory who) = _seats();
        for (uint256 i; i < N_SEATS; ++i) {
            uint256 rid = _roleId(authority, roleIdx[i] + 1);
            require(auth.isMember(rid, who[i]), "seat not seated");
            require(auth.isMember(groupId, who[i]), "group membership not derived");
            require(auth.activeMemberSince(rid, who[i]) > 1, "seat backdated (executed while paused?)");
        }

        // 4. Negative: a plain member (the operator EOA is a KUBI candidate, not a board seat)
        //    is NOT in the group.
        require(!auth.isMember(groupId, 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9), "non-seat leaked into group");

        console.log("PASS: KUBI board roles sim complete (10 roles + Executives group + 11 seats)");
    }
}
