// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Add an EducationHub module to the Decentral Park org (Gnosis)
 * ============================================================================
 *
 * Decentral Park was deployed WITHOUT an EducationHub (its registry entry is
 * 0x0). Adding one is NOT a pure governance config change — there is no
 * post-hoc "deploy one module" factory the Executor can call — so it is a
 * TWO-PART operation, both performed in a single broadcast here:
 *
 *   PART 1 (plain deploy tx, done by the broadcasting EOA):
 *     a. new SwitchableBeacon(owner=Executor, mirror=<global EduHub beacon>, Mirror)
 *     b. new BeaconProxy(beacon, initData) where initData calls
 *        EducationHub.initialize(token, hats, executor, creatorHats, memberHats)
 *
 *   PART 2 (governance proposal created in the same broadcast; executes on pass):
 *     a. ParticipationToken.setEducationHub(proxy)   -> authorizes EduHub to mint
 *     b. OrgRegistry.registerOrgContract(orgId, EDUCATION_HUB_ID, proxy, beacon,
 *        true, executor, false)                      -> makes it a discoverable,
 *                                                       upgrade-tracked org module
 *
 * Why PART 2 must be governance: TaskManager-era bootstrap is closed for this
 * org, so OrgRegistry.registerOrgContract is Executor-only; and the Executor is
 * only reachable through a passed HybridVoting proposal. setEducationHub's first
 * call is open, but routing it through the same proposal keeps all mutations of
 * existing org contracts under governance and atomic with registration.
 *
 * Prerequisites verified on Gnosis 2026-05-31:
 *   - PoaManager 0x794fD3...789b has a global EducationHub beacon
 *     (0xB48B2d...e2e5, impl 0x00a514...5D40) -> a per-org Mirror beacon can be built.
 *   - ParticipationToken.educationHub == 0x0 -> first-call setEducationHub is open.
 *   - OrgRegistry 0x3744b3...A854 has the org; EducationHub slot is unregistered.
 *
 * ROLE WIRING (defaults — ADJUST IF DESIRED; both are governance-adjustable later
 * via EducationHub.setCreatorHatAllowed / setMemberHatAllowed, Executor-gated):
 *   - creatorHats = [Delegate]            -> who can create/edit/remove modules
 *   - memberHats  = [Neighbor, Delegate]  -> who can complete modules & earn tokens
 *
 * Sim-first per CLAUDE.md: stages deploy -> create proposal -> vote -> execute on a
 * Gnosis fork (permissive Hats shim for one voter), then asserts the post-state:
 * token.educationHub == proxy, registry resolves the proxy, AND a module can be
 * created and completed so a learner is minted participation tokens (proves the
 * mint authorization wiring).
 *
 * Usage:
 *   # Sim (no broadcast — full end-to-end validation on a fork)
 *   FOUNDRY_PROFILE=production forge script \
 *     script/fixes/AddEducationHubDecentralPark.s.sol:SimAddEducationHubDecentralPark \
 *     --fork-url gnosis -vvv
 *
 *   # Broadcast (deploys the module + creates the wiring/registration proposal)
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/fixes/AddEducationHubDecentralPark.s.sol:BroadcastAddEducationHubDecentralPark \
 *     --rpc-url gnosis --broadcast --slow
 *
 * Optional env override:
 *   GRANT_DURATION — voting window in minutes (default 10 = HybridVoting min)
 * ============================================================================
 */

interface IPoaManagerBeacon {
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IParticipationTokenEdu {
    function setEducationHub(address eh) external;
    function educationHub() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface IOrgRegistryEdu {
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external;
    function getOrgContract(bytes32 orgId, bytes32 typeId) external view returns (address);
}

interface IHatsBalance {
    function balanceOf(address user, uint256 hatId) external view returns (uint256);
}

// Decentral Park (Gnosis) — verified via Poa subgraph + on-chain reads 2026-05-31
address constant DP_TM = 0x2D9d397A842B8D691ea2A232062CbC8eF8eBbdB7;
address constant DP_HV = 0x1B80CA1EF7F274E141658A666fc12277957bF7A1;
address constant DP_EXECUTOR = 0x2A01133997abE2a001862cf0B03B22fe958FA4bC;
address constant DP_HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
address constant DP_TOKEN = 0x1A8b31903C98e514332991a70C00566ec2DeE14e; // ParticipationToken
bytes32 constant DP_ORGID = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;

address constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
address constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;

uint256 constant DELEGATE_HAT = 36180248838698575036480031466286475792781881727149517033480474826113024;
uint256 constant NEIGHBOR_HAT = 36180248838698575132261002770404529440178570924043841009651669962588160;

bytes32 constant EDUCATION_HUB_ID = keccak256("EducationHub");
uint32 constant DEFAULT_DURATION_MINUTES = 10;

/// @dev Permissive Hats stand-in for the sim only: returns "wears it" for a single godmode EOA on
/// every hat. Etched over the org's real Hats contract so one test voter satisfies createProposal,
/// vote, and EducationHub creator/member checks.
contract PermissiveHatsShim {
    function balanceOf(
        address user,
        uint256 /*hatId*/
    )
        external
        view
        returns (uint256)
    {
        address g;
        assembly {
            g := sload(0)
        }
        return user == g ? 1 : 0;
    }

    function balanceOfBatch(address[] calldata users, uint256[] calldata hatIds)
        external
        view
        returns (uint256[] memory bal)
    {
        require(users.length == hatIds.length, "len mismatch");
        address g;
        assembly {
            g := sload(0)
        }
        bal = new uint256[](users.length);
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == g) bal[i] = 1;
        }
    }

    function isWearerOfHat(
        address user,
        uint256 /*hatId*/
    )
        external
        view
        returns (bool)
    {
        address g;
        assembly {
            g := sload(0)
        }
        return user == g;
    }
}

abstract contract AddEducationHubBase is Script {
    /// @dev Default creator hats: who can author/edit/remove learning modules.
    function _creatorHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](1);
        hats[0] = DELEGATE_HAT;
    }

    /// @dev Default member hats: who can complete modules and earn participation tokens.
    function _memberHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](2);
        hats[0] = NEIGHBOR_HAT;
        hats[1] = DELEGATE_HAT;
    }

    function _resolveDuration() internal view returns (uint32) {
        return uint32(vm.envOr("GRANT_DURATION", uint256(DEFAULT_DURATION_MINUTES)));
    }

    /// @dev PART 1: deploy a per-org Mirror SwitchableBeacon + BeaconProxy and initialize the
    /// EducationHub. Returns (proxy, beacon). Owner of the beacon is the org Executor.
    function _deployEducationHub() internal returns (address proxy, address beacon) {
        address globalBeacon = IPoaManagerBeacon(POA_MANAGER).getBeaconById(EDUCATION_HUB_ID);
        require(globalBeacon != address(0), "no global EducationHub beacon on PoaManager");

        // Mirror mode (autoUpgrade): follows the protocol's EducationHub beacon. staticImpl = 0.
        beacon = address(new SwitchableBeacon(DP_EXECUTOR, globalBeacon, address(0), SwitchableBeacon.Mode.Mirror));

        bytes memory initData =
            abi.encodeCall(EducationHub.initialize, (DP_TOKEN, DP_HATS, DP_EXECUTOR, _creatorHats(), _memberHats()));
        proxy = address(new BeaconProxy(beacon, initData));
    }

    /// @dev PART 2: the governance batch that wires + registers the freshly-deployed EduHub.
    function _buildGovBatch(address proxy, address beacon) internal pure returns (IExecutor.Call[] memory batch) {
        batch = new IExecutor.Call[](2);
        batch[0] = IExecutor.Call({
            target: DP_TOKEN, value: 0, data: abi.encodeCall(IParticipationTokenEdu.setEducationHub, (proxy))
        });
        batch[1] = IExecutor.Call({
            target: ORG_REGISTRY,
            value: 0,
            data: abi.encodeCall(
                IOrgRegistryEdu.registerOrgContract,
                (DP_ORGID, EDUCATION_HUB_ID, proxy, beacon, true, DP_EXECUTOR, false)
            )
        });
    }
}

/* ─────────────────────────── SIM ─────────────────────────── */

contract SimAddEducationHubDecentralPark is AddEducationHubBase {
    function run() public {
        console.log("\n=== Add EducationHub sim: Decentral Park ===");

        // Pre-state.
        require(IParticipationTokenEdu(DP_TOKEN).educationHub() == address(0), "Sim: educationHub already set");
        address globalBeacon = IPoaManagerBeacon(POA_MANAGER).getBeaconById(EDUCATION_HUB_ID);
        console.log("  Global EduHub beacon:", globalBeacon);

        // PART 1: deploy + initialize.
        (address proxy, address beacon) = _deployEducationHub();
        console.log("  Deployed EduHub proxy: ", proxy);
        console.log("  Per-org beacon:        ", beacon);
        require(proxy.code.length > 0, "Sim: proxy has no code");

        // Etch a permissive Hats shim so one voter can create the proposal, vote, and later act as
        // an EduHub creator/member.
        address voter = makeAddr("add-eduhub-sim-voter");
        PermissiveHatsShim shim = new PermissiveHatsShim();
        vm.etch(DP_HATS, address(shim).code);
        vm.store(DP_HATS, bytes32(uint256(0)), bytes32(uint256(uint160(voter))));

        // PART 2: build + create the governance proposal.
        IExecutor.Call[] memory batch = _buildGovBatch(proxy, beacon);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint32 minutesDuration = 10;
        vm.prank(voter);
        HybridVoting(DP_HV)
            .createProposal(
                bytes("Add EducationHub - Decentral Park"), bytes32(0), minutesDuration, 1, batches, new uint256[](0)
            );
        uint256 proposalId = HybridVoting(DP_HV).proposalsCount() - 1;
        console.log("  Proposal id:", proposalId);

        // Vote 100% for option 0.
        uint8[] memory idxs = new uint8[](1);
        uint8[] memory weights = new uint8[](1);
        idxs[0] = 0;
        weights[0] = 100;
        vm.prank(voter);
        HybridVoting(DP_HV).vote(proposalId, idxs, weights);

        vm.warp(block.timestamp + uint256(minutesDuration) * 60 + 10);
        (uint256 winner, bool valid) = HybridVoting(DP_HV).announceWinner(proposalId);
        require(valid, "Sim: proposal did not pass");
        console.log("  Winner option:", winner, " valid:", valid);

        // Post-state: wired + registered.
        require(IParticipationTokenEdu(DP_TOKEN).educationHub() == proxy, "Sim: token.educationHub != proxy");
        require(
            IOrgRegistryEdu(ORG_REGISTRY).getOrgContract(DP_ORGID, EDUCATION_HUB_ID) == proxy,
            "Sim: registry did not resolve proxy"
        );
        console.log("  token.educationHub wired and registry resolves proxy.");

        // Prove the mint wiring end-to-end: create a module and complete it as the godmode voter.
        uint256 payout = 100e18;
        vm.prank(voter);
        EducationHub(proxy).createModule(bytes("Intro to Decentral Park"), bytes32("content"), payout, 1);
        uint256 balBefore = IParticipationTokenEdu(DP_TOKEN).balanceOf(voter);
        vm.prank(voter);
        EducationHub(proxy).completeModule(0, 1);
        uint256 balAfter = IParticipationTokenEdu(DP_TOKEN).balanceOf(voter);
        require(balAfter == balBefore + payout, "Sim: module completion did not mint participation tokens");
        console.log("  Module completed; minted participation tokens:", balAfter - balBefore);

        console.log("PASS: Decentral Park EducationHub deployed, wired, registered, and minting end-to-end.");
    }
}

/* ─────────────────────────── BROADCAST ─────────────────────────── */

contract BroadcastAddEducationHubDecentralPark is AddEducationHubBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(key);
        uint32 minutesDuration = _resolveDuration();

        console.log("\n=== Add EducationHub broadcast: Decentral Park ===");
        console.log("  Sender:   ", sender);
        console.log("  Duration: ", minutesDuration, "minutes");

        // Sanity: sender must wear a HybridVoting creator hat or createProposal reverts.
        uint256[] memory creatorHats = HybridVoting(DP_HV).creatorHats();
        bool isCreator = false;
        for (uint256 i; i < creatorHats.length; ++i) {
            if (IHatsBalance(DP_HATS).balanceOf(sender, creatorHats[i]) > 0) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Sender does not wear any creator hat on this voting contract");
        require(IParticipationTokenEdu(DP_TOKEN).educationHub() == address(0), "educationHub already set on token");

        vm.startBroadcast(key);

        // PART 1: deploy the module (beacon + proxy + init).
        (address proxy, address beacon) = _deployEducationHub();

        // PART 2: create the wiring/registration proposal referencing the just-deployed addresses.
        IExecutor.Call[] memory batch = _buildGovBatch(proxy, beacon);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;
        HybridVoting(DP_HV)
            .createProposal(
                bytes("Add EducationHub - Decentral Park"), bytes32(0), minutesDuration, 1, batches, new uint256[](0)
            );

        vm.stopBroadcast();

        uint256 proposalId = HybridVoting(DP_HV).proposalsCount() - 1;
        console.log("\n  Deployed EduHub proxy:", proxy);
        console.log("  Per-org beacon:       ", beacon);
        console.log("  Proposal ID:          ", proposalId);
        console.log("  Next: members vote; after expiry anyone calls announceWinner(", proposalId, ")");
        console.log("  On execution: token.setEducationHub(proxy) + OrgRegistry registration land.");
    }
}
