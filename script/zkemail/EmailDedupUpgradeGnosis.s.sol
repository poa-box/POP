// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {ZkEmailProofV2, IZkEmailGroth16VerifierV2} from "../../src/zkemail/IVerifier.sol";
import {IExecutor} from "../../src/Executor.sol";

/*
 * ============================================================================
 * EMAIL-ADDRESS DEDUP — ZkEmailInvites upgrade (Gnosis)
 * ============================================================================
 *
 * The circuit's `emailNullifier` is poseidon(poseidon(DKIM signature)) — unique per EMAIL MESSAGE, so
 * it only blocks replaying the same .eml. A fresh send yields a fresh nullifier, letting one
 * allowlisted ADDRESS register unlimited accounts. This upgrade adds ONE-REGISTRATION-PER-ADDRESS for
 * SPECIFIC-ADDRESS entries, keyed by the v2 proof's `emailHash` (Poseidon commitment of the From
 * address): `registeredEmails[emailHash]` marks on claim, duplicate claims revert
 * EmailAlreadyRegistered, and governance can re-open an address via `clearRegisteredEmail` (lost-wallet
 * recovery).
 *
 * DOMAIN entries are NOT deduped yet (documented interim): the v1 proof exposes no address commitment.
 * Follow-up tracked in the repo issue (route domain claims through the v2 circuit, or extend v1 with a
 * new ceremony).
 *
 * Selectors are UNCHANGED (internal check only) — no paymaster rule churn.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/EmailDedupUpgradeGnosis.s.sol:SimEmailDedupUpgrade --fork-url gnosis -vvv
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/EmailDedupUpgradeGnosis.s.sol:BroadcastEmailDedupUpgrade --rpc-url gnosis --broadcast --slow
 * ============================================================================
 */

interface ISatelliteD {
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewD {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

contract SimMockEmailVerifierD is IZkEmailGroth16VerifierV2 {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

abstract contract EmailDedupBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;

    address internal constant TEST6_PROXY = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
    address internal constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    uint256 internal constant TEST6_MEMBER_HAT =
        29035862971903655586674243772344327311664727652070589302159213246545920;

    string internal constant VERSION = "v-zkemail-5"; // probed FREE on the Gnosis registry
    bytes32 internal constant GMAIL_POSEIDON = 0x14d46e073cbff5944a738ea295de6c7447606fa5a270571229d8a4b1e7ca77e5;
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    uint8 internal constant LEAF_EMAIL = 1;

    function _implOf(string memory typeName) internal view returns (address) {
        return IPoaManagerViewD(POA_MANAGER).getCurrentImplementationById(keccak256(bytes(typeName)));
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimEmailDedupUpgrade is EmailDedupBase {
    function run() public {
        console.log("\n=== SIM: email-address dedup upgrade -> live Test6 (Gnosis fork) ===");
        require(ISatelliteD(SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        // 1. Upgrade the ZkEmailInvites beacon (impl BEFORE prank).
        address newZk = address(new ZkEmailInvites());
        vm.prank(HUDSON);
        ISatelliteD(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        require(_implOf("ZkEmailInvites") == newZk, "beacon not upgraded");
        console.log("[1] ZkEmailInvites beacon upgraded (Test6 follows via Mirror).");

        // 2. Stage a single-EMAIL-leaf allowlist + mock the v2 verifier accept (sim-only fork state).
        bytes32 emailHash = bytes32(uint256(0xA11CE));
        uint256[] memory hats = new uint256[](1);
        hats[0] = TEST6_MEMBER_HAT;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(LEAF_EMAIL, emailHash, hats))));
        address mockV2 = address(new SimMockEmailVerifierD());
        vm.startPrank(TEST6_EXECUTOR);
        ZkEmailInvites(TEST6_PROXY).setActiveAllowlist(root, bytes32(uint256(0xC1D)));
        ZkEmailInvites(TEST6_PROXY).setEmailVerifier(mockV2);
        vm.stopPrank();

        // 3. First registration succeeds.
        address first = makeAddr("first-account");
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(first);
        ZkEmailInvites(TEST6_PROXY).claimRoleByEmail(_proofV2(bytes32(uint256(1)), emailHash), first, hats, emptyProof);
        require(ZkEmailInvites(TEST6_PROXY).isEmailRegistered(emailHash), "email not marked registered");
        console.log("[2] First registration for the address succeeded and is marked.");

        // 4. THE FIX: a FRESH email (fresh nullifier) from the SAME address must NOT register again.
        address second = makeAddr("second-account");
        vm.prank(second);
        vm.expectRevert(ZkEmailInvites.EmailAlreadyRegistered.selector);
        ZkEmailInvites(TEST6_PROXY).claimRoleByEmail(_proofV2(bytes32(uint256(2)), emailHash), second, hats, emptyProof);
        console.log("[3] Duplicate registration with a fresh nullifier REVERTED (EmailAlreadyRegistered).");

        // 5. Governance recovery: clear -> a new email registers to a new account.
        IExecutor.Call[] memory batch = new IExecutor.Call[](1);
        batch[0] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.clearRegisteredEmail, (emailHash))
        });
        vm.prank(TEST6_HV);
        IExecutor(TEST6_EXECUTOR).execute(99, batch);
        require(!ZkEmailInvites(TEST6_PROXY).isEmailRegistered(emailHash), "clear failed");
        vm.prank(second);
        ZkEmailInvites(TEST6_PROXY).claimRoleByEmail(_proofV2(bytes32(uint256(3)), emailHash), second, hats, emptyProof);
        console.log("[4] Governance clear re-opened the address; recovery claim succeeded.");

        console.log("\nPASS: email-address dedup verified end-to-end on a real Gnosis fork.");
    }

    function _proofV2(bytes32 nullifier, bytes32 emailHash) internal pure returns (ZkEmailProofV2 memory p) {
        p.pA = [uint256(1), 2];
        p.pB = [[uint256(1), 2], [uint256(3), 4]];
        p.pC = [uint256(5), 6];
        p.pubkeyHash = GMAIL_KEYHASH;
        p.emailNullifier = nullifier;
        p.emailHash = emailHash;
        p.fromDomainHash = GMAIL_POSEIDON; // live registry has this key seeded
    }
}

/* ════════════════════════════ BROADCAST ════════════════════════════ */

/// @notice Hudson: upgrade the ZkEmailInvites beacon to the dedup impl (v-zkemail-5).
contract BroadcastEmailDedupUpgrade is EmailDedupBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        vm.startBroadcast(key);
        address newZk = address(new ZkEmailInvites());
        ISatelliteD(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        vm.stopBroadcast();
        require(_implOf("ZkEmailInvites") == newZk, "beacon not upgraded");
        // The live proxy must expose the new surface.
        require(!ZkEmailInvites(TEST6_PROXY).isEmailRegistered(bytes32(uint256(1))), "new getter not live");
        console.log("  new ZkEmailInvites impl:", newZk);
        console.log("Done: one registration per email address (specific-address entries).");
    }
}
