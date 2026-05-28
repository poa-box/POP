// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {TaskPerm} from "../../src/libs/TaskPerm.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Decentral Park (Gnosis) - Create "Agent" role via governance
 * ============================================================================
 *
 * Single governance proposal with 5 calls executed by Decentral Park's Executor.
 * Creates a new "Agent" role for AI brains that help generate tasks:
 *
 *   1. EligibilityModule.createHatWithEligibility(parent=topHat, ...)
 *      → Creates the Agent hat under the org's topHat. Unlimited supply,
 *        mutable, no initial mint (wearers join via vouching).
 *
 *   2. EligibilityModule.configureVouching(agentHat, quorum=1, membershipHat=Delegate, combine=false)
 *      → A single Delegate-hat wearer can vouch a candidate EOA into eligibility.
 *        Once vouched, the candidate (or anyone) can call Hats.mintHat to grant
 *        them the Agent hat.
 *
 *   3. TaskManager.setConfig(ROLE_PERM, abi.encode(agentHat, CREATE | ASSIGN | EDIT_META))
 *      → Org-wide TaskPerm grant. Agent can create tasks, assign them to humans
 *        (also covers approveApplication - same perm bit gates both), and edit
 *        task metadata post-claim (title + IPFS hash, not payout / bounty).
 *
 *   4. HybridVoting.setCreatorHatAllowed(agentHat, true)
 *      → Agent wearers can submit binding governance proposals.
 *
 *   5. PaymasterHub.setBudget(orgId, agentSubjectKey, 5 xDAI, 7 days)
 *      → Gas sponsorship for Agent wearers. On Gnosis, 5 xDAI/week sponsors
 *        thousands of typical txs.
 *
 * Explicit non-grants (this proposal deliberately does NOT add Agent to):
 *   - HV / DD voting class hats          → Agent cannot vote
 *   - DirectDemocracyVoting creator hats → no DD polls (only HV proposals)
 *   - ParticipationToken member hats     → Agent cannot hold shares
 *   - ParticipationToken approver hats   → Agent cannot approve token mints
 *   - QuickJoin memberHatIds             → Agent isn't quick-joinable; vouching only
 *   - TaskManager creatorHatIds          → Agent can create tasks but not new projects
 *   - TaskPerm.EDIT_FULL                 → Agent can NOT change payout / bounty after claim
 *   - TaskPerm.REVIEW / BUDGET           → Reserved for humans
 *
 * Auth: all 5 calls are executor-gated (TaskManager / HV / PaymasterHub auth
 * paths) or topHat-admin-gated (EligibilityModule via superAdmin == Executor).
 * The Executor wears Decentral Park's topHat, so all checks resolve cleanly.
 *
 * Hat-ID prediction caveat: Hats Protocol assigns sequential child IDs under a
 * given admin. We predict the Agent hat's ID via `Hats.getNextId(topHat)` at
 * proposal-build time and bake it into calls 2-5. If another hat is created
 * under Decentral Park's topHat between this proposal's broadcast and execute,
 * the prediction skews and the downstream calls would target a stale ID. The
 * sim re-checks `getNextId` immediately before building the batch; the
 * broadcast contract re-checks again at broadcast time and reverts if drift is
 * detected so a stale proposal can't ship.
 *
 * Sim-first per CLAUDE.md: stages the full proposal-pass-execute path on a
 * Gnosis fork using REAL Hats Protocol state (no etch). Pranks Hudson
 * (verified Delegate-hat wearer) for createProposal + vote; the Executor (real
 * topHat wearer) fires the 5-call batch atomically and the sim asserts all
 * five post-conditions.
 *
 * Usage:
 *   # Sim
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/CreateAgentRoleDecentralPark.s.sol:SimCreateAgentRoleDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/CreateAgentRoleDecentralPark.s.sol:BroadcastCreateAgentRoleDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env overrides:
 *   AGENT_GAS_BUDGET_WEI   - Default 5 xDAI = 5e18.
 *   AGENT_EPOCH_LEN_SEC    - Default 604800 (7 days).
 *   PROPOSAL_DURATION_MIN  - Default 30 minutes.
 *   AGENT_DETAILS          - Hat details field (ipfs:// or short string). Default "Agent".
 *   AGENT_IMAGE_URI        - Hat image URI. Default "".
 *
 * Next steps after the proposal executes:
 *   1. A Delegate calls `EligibilityModule.vouchFor(agentEOA, AGENT_HAT_ID)`
 *   2. Anyone calls `Hats.mintHat(AGENT_HAT_ID, agentEOA)` - agent is live
 * ============================================================================
 */

// On-chain addresses
address constant GNOSIS_HATS_PROTOCOL = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
address constant GNOSIS_PAYMASTER_HUB = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;

// Decentral Park (Gnosis) - verified 2026-05-28
bytes32 constant DECENTRAL_PARK_ORG_ID = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
address constant DECENTRAL_PARK_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DECENTRAL_PARK_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;
address constant DECENTRAL_PARK_EM = 0xe4A02F20B8282A272879e31479Ee070dab07B015;
uint256 constant DECENTRAL_PARK_TOP_HAT = 36180248427316158604443134246780344364021047815049448269641044954447872;
// EligibilityModule wears the ELIGIBILITY_ADMIN hat (set up by HatsTreeSetup at deploy).
// That gives EM admin rights to create children of ELIGIBILITY_ADMIN — which is where all
// role hats in Decentral Park live (Delegate / Neighbor are level-2 hats under ELIG_ADMIN,
// confirmed via `Hats.getAdminAtLevel(delegateHat, 1) == ELIG_ADMIN`). New role hats created
// post-deploy must use ELIGIBILITY_ADMIN as parent or `createHat` reverts NotAdmin (EM is
// NOT admin of topHat — only the Executor is, and EM is the contract relaying the call).
uint256 constant DECENTRAL_PARK_ELIG_ADMIN_HAT =
    36180248838692297934744644785522640003358674060733414678036010791600128;
uint256 constant DECENTRAL_PARK_DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024;

// Hudson - verified Delegate-hat wearer; the sim pranks this address.
address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;

// Agent role config defaults (overridable via env at sim / broadcast time).
uint128 constant DEFAULT_AGENT_GAS_BUDGET_WEI = 5 ether; // 5 xDAI / week
uint32 constant DEFAULT_AGENT_EPOCH_LEN_SEC = 7 days;
uint32 constant DEFAULT_PROPOSAL_DURATION_MIN = 30;
uint32 constant AGENT_MAX_SUPPLY = type(uint32).max; // unlimited per user direction
uint8 constant AGENT_TASK_PERM_MASK = TaskPerm.CREATE | TaskPerm.ASSIGN | TaskPerm.EDIT_META;
uint32 constant VOUCH_QUORUM = 1; // a single Delegate vouch suffices

/// @dev EligibilityModule.createHatWithEligibility takes this struct (mirrored exactly here
/// to avoid pulling in the full EligibilityModule.sol compile graph).
struct CreateHatParams {
    uint256 parentHatId;
    string details;
    uint32 maxSupply;
    bool _mutable;
    string imageURI;
    bool defaultEligible;
    bool defaultStanding;
    address[] mintToAddresses;
    bool[] wearerEligibleFlags;
    bool[] wearerStandingFlags;
}

interface IEligibilityModuleMinimal {
    function createHatWithEligibility(CreateHatParams calldata params) external returns (uint256 newHatId);
    function configureVouching(uint256 hatId, uint32 quorum, uint256 membershipHatId, bool combineWithHierarchy)
        external;
    function vouchConfigs(uint256 hatId) external view returns (uint32 quorum, uint256 membershipHatId, uint8 flags);
}

interface IHatsMinimal {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
    function getNextId(uint256 admin) external view returns (uint256);
    function isWearerOfHat(address user, uint256 hatId) external view returns (bool);
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
            uint16 numChildren,
            bool mutable_
        );
}

interface IPaymasterHubMinimal {
    function getBudget(bytes32 orgId, bytes32 subjectKey)
        external
        view
        returns (uint128 capPerEpoch, uint128 usedInEpoch, uint32 epochLen, uint32 epochStart);
    function setBudget(bytes32 orgId, bytes32 subjectKey, uint128 capPerEpoch, uint32 epochLen) external;
}

abstract contract CreateAgentBase is Script {
    /// @dev Subject-key for a hat budget on PaymasterHub. Matches
    /// `keccak256(abi.encodePacked(uint8(1), bytes32(hatId)))` (subjectType=1 → hat).
    function _hatSubjectKey(uint256 hatId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(1), bytes32(hatId)));
    }

    function _resolveGasBudget() internal view returns (uint128) {
        return uint128(vm.envOr("AGENT_GAS_BUDGET_WEI", uint256(DEFAULT_AGENT_GAS_BUDGET_WEI)));
    }

    function _resolveEpochLen() internal view returns (uint32) {
        return uint32(vm.envOr("AGENT_EPOCH_LEN_SEC", uint256(DEFAULT_AGENT_EPOCH_LEN_SEC)));
    }

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("PROPOSAL_DURATION_MIN", uint256(DEFAULT_PROPOSAL_DURATION_MIN)));
    }

    function _resolveDetails() internal view returns (string memory) {
        return vm.envOr("AGENT_DETAILS", string("Agent"));
    }

    function _resolveImageURI() internal view returns (string memory) {
        return vm.envOr("AGENT_IMAGE_URI", string(""));
    }

    /// @dev Predict the Agent hat ID - the next child slot under Decentral Park's topHat.
    /// Race risk: if another hat is created under the topHat between now and proposal
    /// execution, this ID will be stale. The broadcast variant re-checks before sending.
    function _predictAgentHatId() internal view returns (uint256) {
        return IHatsMinimal(GNOSIS_HATS_PROTOCOL).getNextId(DECENTRAL_PARK_ELIG_ADMIN_HAT);
    }

    /// @dev Build the 5-call batch the proposal executes.
    function _buildBatch(uint256 predictedAgentHatId, uint128 gasBudget, uint32 epochLen)
        internal
        view
        returns (IExecutor.Call[] memory batch)
    {
        batch = new IExecutor.Call[](5);

        // 1. Create the Agent hat (Executor satisfies onlyHatAdmin(topHat) since it wears topHat).
        CreateHatParams memory createParams = CreateHatParams({
            parentHatId: DECENTRAL_PARK_ELIG_ADMIN_HAT,
            details: _resolveDetails(),
            maxSupply: AGENT_MAX_SUPPLY,
            _mutable: true,
            imageURI: _resolveImageURI(),
            defaultEligible: false, // default deny - wearers become eligible only via vouching
            defaultStanding: true,
            mintToAddresses: new address[](0), // no initial mint; minting via vouch + Hats.mintHat
            wearerEligibleFlags: new bool[](0),
            wearerStandingFlags: new bool[](0)
        });
        batch[0] = IExecutor.Call({
            target: DECENTRAL_PARK_EM,
            value: 0,
            data: abi.encodeCall(IEligibilityModuleMinimal.createHatWithEligibility, (createParams))
        });

        // 2. Configure vouching: 1 Delegate vouch makes a candidate eligible.
        batch[1] = IExecutor.Call({
            target: DECENTRAL_PARK_EM,
            value: 0,
            data: abi.encodeCall(
                IEligibilityModuleMinimal.configureVouching,
                (predictedAgentHatId, VOUCH_QUORUM, DECENTRAL_PARK_DELEGATE_HAT, false)
            )
        });

        // 3. Grant TaskPerm bits globally (CREATE | ASSIGN | EDIT_META = 1 | 8 | 64 = 73).
        batch[2] = IExecutor.Call({
            target: DECENTRAL_PARK_TM,
            value: 0,
            data: abi.encodeCall(
                TaskManager.setConfig,
                (TaskManager.ConfigKey.ROLE_PERM, abi.encode(predictedAgentHatId, AGENT_TASK_PERM_MASK))
            )
        });

        // 4. Allow Agent to create HybridVoting proposals.
        batch[3] = IExecutor.Call({
            target: DECENTRAL_PARK_HV,
            value: 0,
            data: abi.encodeWithSignature("setCreatorHatAllowed(uint256,bool)", predictedAgentHatId, true)
        });

        // 5. Set gas sponsorship budget on PaymasterHub.
        batch[4] = IExecutor.Call({
            target: GNOSIS_PAYMASTER_HUB,
            value: 0,
            data: abi.encodeCall(
                IPaymasterHubMinimal.setBudget,
                (DECENTRAL_PARK_ORG_ID, _hatSubjectKey(predictedAgentHatId), gasBudget, epochLen)
            )
        });
    }

    function _printPreview(uint256 predictedAgentHatId, uint128 gasBudget, uint32 epochLen) internal view {
        console.log("\n=== Agent role preview ===");
        console.log("  Predicted hatId:        ", predictedAgentHatId);
        console.log("  Parent (ELIG_ADMIN):    ", DECENTRAL_PARK_ELIG_ADMIN_HAT);
        console.log("  Max supply:             ", uint256(AGENT_MAX_SUPPLY));
        console.log("  Vouching quorum:        ", uint256(VOUCH_QUORUM));
        console.log("  Voucher hat (Delegate): ", DECENTRAL_PARK_DELEGATE_HAT);
        console.log("  TaskPerm mask:          ", uint256(AGENT_TASK_PERM_MASK), "(CREATE | ASSIGN | EDIT_META)");
        console.log("  HV creator hat:         ", uint256(1), "(true)");
        console.log("  PaymasterHub cap (wei): ", uint256(gasBudget));
        console.log("  PaymasterHub epoch (s): ", uint256(epochLen));
    }

    /// @dev Full sim using REAL Hats Protocol state - no etch.
    function _simFullFlow(uint128 gasBudget, uint32 epochLen) internal {
        console.log("\n=== Decentral Park Agent role creation sim (real Hats, prank Hudson) ===");

        uint256 predictedAgentHatId = _predictAgentHatId();
        _printPreview(predictedAgentHatId, gasBudget, epochLen);

        // Pre-state: predicted hat must NOT yet exist (supply == 0 and details empty).
        IHatsMinimal hats = IHatsMinimal(GNOSIS_HATS_PROTOCOL);
        (, uint32 maxSupplyBefore,,,,,,,) = hats.viewHat(predictedAgentHatId);
        require(maxSupplyBefore == 0, "Sim: predicted hat already exists - race or stale prediction");

        IExecutor.Call[] memory batch = _buildBatch(predictedAgentHatId, gasBudget, epochLen);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        // Create + vote as Hudson (real Delegate hat wearer).
        uint32 minutesDuration = 10;
        uint256[] memory pollHats = new uint256[](0);
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: create Agent role (sim)"), bytes32(0), minutesDuration, 1, batches, pollHats
            );
        uint256 proposalId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        console.log("\n  Proposal id:", proposalId);

        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(HUDSON);
        HybridVoting(DECENTRAL_PARK_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);

        (uint256 winner, bool valid) = HybridVoting(DECENTRAL_PARK_HV).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass (likely quorum)");
        console.log("  Winner option:", winner, " valid:", valid);

        // Post-state assertions.
        // (a) Agent hat exists with the predicted ID and configured supply.
        (string memory details, uint32 maxSupplyAfter,, address eligibility,, string memory imageURIAfter,,,) =
            hats.viewHat(predictedAgentHatId);
        require(maxSupplyAfter == AGENT_MAX_SUPPLY, "Sim: hat maxSupply mismatch");
        require(eligibility == DECENTRAL_PARK_EM, "Sim: hat eligibility module mismatch");
        require(keccak256(bytes(details)) == keccak256(bytes(_resolveDetails())), "Sim: hat details mismatch");
        // imageURI not asserted: Hats Protocol inherits the parent's URI when the input is
        // empty, so the stored value may differ from what we passed. Acceptable — image is
        // cosmetic. To set a custom image, pass AGENT_IMAGE_URI env var.
        imageURIAfter; // silence unused-local warning

        // (b) Vouching configured: quorum=1, membershipHat=Delegate.
        (uint32 quorumAfter, uint256 membershipHatAfter,) =
            IEligibilityModuleMinimal(DECENTRAL_PARK_EM).vouchConfigs(predictedAgentHatId);
        require(quorumAfter == VOUCH_QUORUM, "Sim: vouch quorum mismatch");
        require(membershipHatAfter == DECENTRAL_PARK_DELEGATE_HAT, "Sim: vouch membership hat mismatch");

        // (c) TaskManager role perm matches AGENT_TASK_PERM_MASK.
        uint8 maskAfter = _readTaskManagerRolePerm(predictedAgentHatId);
        require(maskAfter == AGENT_TASK_PERM_MASK, "Sim: TaskManager rolePermGlobal mismatch");

        // (d) HybridVoting creator hats includes the new Agent hat.
        uint256[] memory creatorHats = HybridVoting(DECENTRAL_PARK_HV).creatorHats();
        bool foundCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (creatorHats[i] == predictedAgentHatId) {
                foundCreator = true;
                break;
            }
        }
        require(foundCreator, "Sim: Agent hat missing from HV creatorHats");

        // (e) PaymasterHub budget set correctly.
        (uint128 capAfter,, uint32 epochAfter,) = IPaymasterHubMinimal(GNOSIS_PAYMASTER_HUB)
            .getBudget(DECENTRAL_PARK_ORG_ID, _hatSubjectKey(predictedAgentHatId));
        require(capAfter == gasBudget, "Sim: paymaster cap mismatch");
        require(epochAfter == epochLen, "Sim: paymaster epoch mismatch");

        console.log("\n  Post-state:");
        console.log("    Hat exists, maxSupply:", uint256(maxSupplyAfter));
        console.log("    Eligibility module:   ", eligibility);
        console.log("    Vouch quorum:         ", uint256(quorumAfter));
        console.log("    Voucher hat:          ", membershipHatAfter);
        console.log("    TaskPerm mask:        ", uint256(maskAfter));
        console.log("    HV creator hats len:  ", creatorHats.length);
        console.log("    Paymaster cap (wei):  ", uint256(capAfter));
        console.log("    Paymaster epoch (s):  ", uint256(epochAfter));
        console.log("\nPASS: Decentral Park Agent role creation governance proposal landed end-to-end.");
    }

    /// @dev TaskManager has no public getter for rolePermGlobal - read directly from storage.
    function _readTaskManagerRolePerm(uint256 hatId) internal view returns (uint8) {
        // Same slot computation used by GrantV5EditFullViaGovernance / AuditTaskPermBit5.
        bytes32 base = bytes32(uint256(keccak256("poa.taskmanager.storage")) + 6);
        bytes32 slot = keccak256(abi.encode(hatId, base));
        return uint8(uint256(vm.load(DECENTRAL_PARK_TM, slot)));
    }

    function _broadcast(uint128 gasBudget, uint32 epochLen) internal {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Broadcasting Agent role creation proposal ===");
        console.log("  Sender:        ", sender);
        console.log("  Duration (min):", uint256(minutesDuration));

        // Drift guard: predicted hatId must still be Hats' next slot at broadcast time.
        uint256 predictedAgentHatId = _predictAgentHatId();
        console.log("  Predicted hatId:", predictedAgentHatId);

        IHatsMinimal hats = IHatsMinimal(GNOSIS_HATS_PROTOCOL);
        (, uint32 maxSupplyBefore,,,,,,,) = hats.viewHat(predictedAgentHatId);
        require(maxSupplyBefore == 0, "Broadcast: predicted hat already exists - race; re-run script");

        // Sanity: sender must wear a creator hat or createProposal reverts.
        IHatsMinimal hatsForCheck = IHatsMinimal(GNOSIS_HATS_PROTOCOL);
        uint256[] memory creatorHats = HybridVoting(DECENTRAL_PARK_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (hatsForCheck.balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on Decentral Park HybridVoting");

        _printPreview(predictedAgentHatId, gasBudget, epochLen);

        IExecutor.Call[] memory batch = _buildBatch(predictedAgentHatId, gasBudget, epochLen);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(DECENTRAL_PARK_HV).proposalsCount();

        vm.startBroadcast(key);
        HybridVoting(DECENTRAL_PARK_HV)
            .createProposal(
                bytes("Decentral Park: create Agent role (vouching-only mint, no shares, no voting)"),
                bytes32(0),
                minutesDuration,
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        uint256 newId = HybridVoting(DECENTRAL_PARK_HV).proposalsCount() - 1;
        require(newId == idBefore, "Proposal not created");
        console.log("\n  Proposal ID:", newId);
        console.log("  IMPORTANT: between now and announceWinner, do NOT let another hat be created under DP's topHat,");
        console.log("  or this proposal's downstream calls will target a stale hatId.");
    }
}

contract SimCreateAgentRoleDecentralPark is CreateAgentBase {
    function run() public {
        _simFullFlow(_resolveGasBudget(), _resolveEpochLen());
    }
}

contract BroadcastCreateAgentRoleDecentralPark is CreateAgentBase {
    function run() public {
        _broadcast(_resolveGasBudget(), _resolveEpochLen());
    }
}
