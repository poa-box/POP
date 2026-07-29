// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {ZkEmailProof, IZkEmailGroth16Verifier} from "../../src/zkemail/IVerifier.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";

/*
 * ============================================================================
 * EMAIL-VERIFIED ELIGIBILITY — beacon upgrade onto live Test6 (Gnosis)
 * ============================================================================
 *
 * The verified email IS the eligibility grant. Adds the EligibilityModule's THIRD eligibility path
 * (email-verified, alongside hierarchy rules + vouching) and makes ZkEmailInvites set it during a
 * claim, closing the chicken-and-egg the ceremony deploy surfaced: gated hats (H-03) meant a fresh
 * claimer could never satisfy `Hats.mintHat`'s eligibility check — earlier "working" claims
 * (emailTest) only worked via a MANUAL per-wearer grant.
 *
 *   - EligibilityModule: `setEmailVerified(wearer, hatIds)` — callable by the superAdmin (Executor)
 *     or any org-authorized hat minter (ZkEmailInvites already is, since the original integration) —
 *     ORed into getWearerStatus; explicit per-wearer rules (kicks/bans) always win.
 *   - ZkEmailInvites: after proof + allowlist + open-hat gate pass, marks the claimer email-verified
 *     on each hat's own eligibility module (resolved from Hats), then mints. Fail-closed.
 *
 * Both Test6 module beacons are Mirror-mode, so upgrading the two PROTOCOL-GLOBAL beacons via the
 * Satellite propagates immediately. No per-org governance needed: authorization rides on the
 * existing hat-minter approval.
 *
 * NOTE: full one-step GASLESS claims additionally need a paymaster-subject decision (validation-time
 * eligibility + per-subject budgets) — tracked separately; this upgrade fixes the on-chain claim path
 * itself (an EOA-paid or pre-funded claim works immediately).
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/EmailEligibilityUpgradeGnosis.s.sol:SimEmailEligibilityUpgrade --fork-url gnosis -vvv
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/EmailEligibilityUpgradeGnosis.s.sol:BroadcastEmailEligibilityUpgrade --rpc-url gnosis --broadcast --slow
 *   forge script script/zkemail/EmailEligibilityUpgradeGnosis.s.sol:VerifyEmailEligibilityGnosis --rpc-url gnosis
 * ============================================================================
 */

interface ISatelliteE {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewE {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

interface IHatsLikeE {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
}

/* ─── Sim-only mock: forces ONLY the final Groth16 accept (Foundry can't gen a real proof) ─── */
contract SimMockDomainVerifierE is IZkEmailGroth16Verifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

abstract contract EmailEligibilityBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    address internal constant TEST6_PROXY = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    address internal constant TEST6_EMAILTEST = 0x3d93687219B992e286eD3fC2B4f54f402cdF0450; // manual-grant era
    uint256 internal constant TEST6_MEMBER_HAT =
        29035862971903655586674243772344327311664727652070589302159213246545920;

    // Probed FREE on the ImplementationRegistry for both typeNames (v-zkemail-3 = ceremony wave).
    string internal constant VERSION = "v-zkemail-4";
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /* Poseidon domain commitments + DKIM key hash (same as the live ceremony wiring). */
    bytes32 internal constant OPACITYLABS_POSEIDON = 0x29e7dedcdb5e509c3f276fb5d689700f0eaaa74bfaa75259b4c545cd2241a5c2;
    bytes32 internal constant GMAIL_POSEIDON = 0x14d46e073cbff5944a738ea295de6c7447606fa5a270571229d8a4b1e7ca77e5;
    bytes32 internal constant KU_POSEIDON = 0x256f370d0033263e95a6c486e2a0280c7843b2e0d586e92e6557382f776d6c58;
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    uint8 internal constant LEAF_DOMAIN = 0;

    function _beaconImpl(address proxy) internal view returns (address impl) {
        address beacon = address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok, "beacon impl() failed");
        impl = abi.decode(ret, (address));
    }

    /* ── OZ StandardMerkleTree over the LIVE Test6 3-domain allowlist (matches the active root) ── */
    function _memberHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](1);
        hats[0] = TEST6_MEMBER_HAT;
    }

    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev 3-leaf tree: root + the gmail leaf's proof. Leaves sorted ASC, placed at tree[2n-2-i].
    function _gmailRootAndProof() internal pure returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(LEAF_DOMAIN, OPACITYLABS_POSEIDON, _memberHats());
        leaves[1] = _leaf(LEAF_DOMAIN, GMAIL_POSEIDON, _memberHats());
        leaves[2] = _leaf(LEAF_DOMAIN, KU_POSEIDON, _memberHats());
        bytes32 target = leaves[1];
        // insertion sort ASC
        for (uint256 i = 1; i < 3; ++i) {
            bytes32 key = leaves[i];
            uint256 j = i;
            while (j > 0 && leaves[j - 1] > key) {
                leaves[j] = leaves[j - 1];
                --j;
            }
            leaves[j] = key;
        }
        bytes32[] memory tree = new bytes32[](5);
        for (uint256 i = 0; i < 3; ++i) {
            tree[4 - i] = leaves[i];
        }
        tree[1] = _hashPair(tree[3], tree[4]);
        tree[0] = _hashPair(tree[1], tree[2]);
        root = tree[0];
        // locate target node, collect sibling path
        uint256 node = type(uint256).max;
        for (uint256 i = 2; i < 5; ++i) {
            if (tree[i] == target) {
                node = i;
                break;
            }
        }
        require(node != type(uint256).max, "gmail leaf not in tree");
        uint256 count;
        for (uint256 k = node; k > 0; k = (k - 1) / 2) {
            ++count;
        }
        proof = new bytes32[](count);
        uint256 idx;
        while (node > 0) {
            proof[idx++] = tree[node % 2 == 1 ? node + 1 : node - 1];
            node = (node - 1) / 2;
        }
    }

    function _gmailProofStruct(address claimer) internal pure returns (ZkEmailProof memory p) {
        p.pA = [uint256(1), 2];
        p.pB = [[uint256(1), 2], [uint256(3), 4]];
        p.pC = [uint256(5), 6];
        p.pubkeyHash = GMAIL_KEYHASH;
        p.emailNullifier = keccak256(abi.encode("email-eligibility-sim", claimer));
        p.fromDomainHash = GMAIL_POSEIDON;
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimEmailEligibilityUpgrade is EmailEligibilityBase {
    function run() public {
        console.log("\n=== SIM: email-verified eligibility upgrade -> live Test6 (Gnosis fork) ===");
        require(ISatelliteE(SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        // Baseline: a FRESH claimer is NOT eligible for the gated Member hat (the exact live failure).
        address claimer = makeAddr("email-eligibility-claimer");
        require(!IHatsLikeE(HATS).isEligible(claimer, TEST6_MEMBER_HAT), "fresh claimer unexpectedly eligible");

        // 1. Upgrade both global beacons (deploy impls BEFORE pranking — `new` would consume the prank).
        address newElig = address(new EligibilityModule());
        address newZk = address(new ZkEmailInvites());
        vm.startPrank(HUDSON);
        ISatelliteE(SATELLITE).upgradeBeaconDirect("EligibilityModule", newElig, VERSION);
        ISatelliteE(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        vm.stopPrank();
        require(_beaconImpl(TEST6_ELIGIBILITY) == newElig, "Test6 eligibility module did not follow beacon");
        require(_beaconImpl(TEST6_PROXY) == newZk, "Test6 ZkEmailInvites did not follow beacon");
        console.log("[1] Both beacons upgraded; Test6 followed (Mirror).");

        // 2. Live-state sanity: the active root is the ceremony Poseidon root this sim's tree reproduces.
        (bytes32 root, bytes32[] memory gmailProof) = _gmailRootAndProof();
        require(ZkEmailInvites(TEST6_PROXY).merkleRoot() == root, "live root != computed 3-domain root");

        // 3. Mock ONLY the Groth16 accept (setDomainVerifier is onlyExecutor). Deploy BEFORE the prank —
        //    an inline `new` inside the call arguments would consume the prank.
        address mockVerifier = address(new SimMockDomainVerifierE());
        vm.prank(TEST6_EXECUTOR);
        ZkEmailInvites(TEST6_PROXY).setDomainVerifier(mockVerifier);

        // 4. THE claim a fresh user makes — NO manual grant, NO governance, NO vouches.
        ZkEmailProof memory p = _gmailProofStruct(claimer);
        vm.prank(claimer);
        ZkEmailInvites(TEST6_PROXY).claimRoleByDomain(p, claimer, _memberHats(), gmailProof);

        require(IHatsLikeE(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "claimer did not receive Member hat");
        require(ZkEmailInvites(TEST6_PROXY).isNullifierUsed(p.emailNullifier), "nullifier not consumed");
        require(
            EligibilityModule(TEST6_ELIGIBILITY).isEmailVerified(claimer, TEST6_MEMBER_HAT),
            "email-verified flag not set on the LIVE module"
        );
        console.log("[2] Fresh claimer claimed self-service: email-verified -> eligible -> minted. ", claimer);

        // 5. H-03 unchanged: the sentinel probe is still gated; emailTest's manual grant still stands.
        address probe = address(uint160(uint256(keccak256("poa.zkemailinvites.claim.probe"))));
        require(!IHatsLikeE(HATS).isEligible(probe, TEST6_MEMBER_HAT), "probe must stay ineligible (H-03)");
        require(IHatsLikeE(HATS).isEligible(TEST6_EMAILTEST, TEST6_MEMBER_HAT), "emailTest regression");
        console.log("[3] H-03 probe still gated; existing explicit grants unaffected.");

        // 6. Governance kicks always win over email verification.
        vm.prank(TEST6_EXECUTOR);
        EligibilityModule(TEST6_ELIGIBILITY).setWearerEligibility(claimer, TEST6_MEMBER_HAT, false, false);
        require(!IHatsLikeE(HATS).isEligible(claimer, TEST6_MEMBER_HAT), "explicit kick must beat email flag");
        console.log("[4] Explicit kick overrides the email-verified flag.");

        console.log("\nPASS: email-verified eligibility verified end-to-end on a real Gnosis fork.");
    }
}

/* ════════════════════════════ BROADCAST ════════════════════════════ */

/// @notice Hudson: upgrade the EligibilityModule + ZkEmailInvites global beacons (v-zkemail-4).
contract BroadcastEmailEligibilityUpgrade is EmailEligibilityBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        console.log("\n=== Broadcast: email-verified eligibility beacon upgrades (v-zkemail-4) ===");

        vm.startBroadcast(key);
        address newElig = address(new EligibilityModule());
        address newZk = address(new ZkEmailInvites());
        ISatelliteE(SATELLITE).upgradeBeaconDirect("EligibilityModule", newElig, VERSION);
        ISatelliteE(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        vm.stopBroadcast();

        require(
            IPoaManagerViewE(POA_MANAGER).getCurrentImplementationById(keccak256("EligibilityModule")) == newElig,
            "EligibilityModule beacon not upgraded"
        );
        require(
            IPoaManagerViewE(POA_MANAGER).getCurrentImplementationById(keccak256("ZkEmailInvites")) == newZk,
            "ZkEmailInvites beacon not upgraded"
        );
        require(_beaconImpl(TEST6_ELIGIBILITY) == newElig, "Test6 module did not follow");
        require(_beaconImpl(TEST6_PROXY) == newZk, "Test6 proxy did not follow");
        console.log("  new EligibilityModule impl:", newElig);
        console.log("  new ZkEmailInvites impl:   ", newZk);
        console.log("Done. Fresh email claims now self-grant eligibility (claimer-paid path live immediately).");
    }
}

/// @notice Read-only: confirm the live Test6 wiring exposes the email-verified path.
contract VerifyEmailEligibilityGnosis is EmailEligibilityBase {
    function run() public view {
        (bool ok, bytes memory ret) = TEST6_ELIGIBILITY.staticcall(
            abi.encodeWithSignature("isEmailVerified(address,uint256)", address(0xdead), TEST6_MEMBER_HAT)
        );
        bool pathLive = ok && ret.length == 32;
        (bytes32 root,) = _gmailRootAndProof();
        bool rootOk = ZkEmailInvites(TEST6_PROXY).merkleRoot() == root;
        console.log("\n=== Verify email-verified eligibility (Test6) ===");
        console.log("  module exposes isEmailVerified():", pathLive);
        console.log("  Poseidon allowlist root active:  ", rootOk);
        if (pathLive && rootOk) {
            console.log("PASS: the third eligibility path is live on Test6.");
        } else {
            console.log("INCOMPLETE: broadcast the beacon upgrades first.");
        }
    }
}
