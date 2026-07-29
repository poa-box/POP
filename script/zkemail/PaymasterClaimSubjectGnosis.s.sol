// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {PaymasterHub} from "../../src/PaymasterHub.sol";
import {IPaymaster} from "../../src/interfaces/IPaymaster.sol";
import {PackedUserOperation, UserOpLib} from "../../src/interfaces/PackedUserOperation.sol";
import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {ZkEmailProof, IZkEmailGroth16Verifier} from "../../src/zkemail/IVerifier.sol";
import {EligibilityModule} from "../../src/EligibilityModule.sol";

/*
 * ============================================================================
 * GASLESS CLAIMS — PaymasterHub SUBJECT_TYPE_CLAIM upgrade (Gnosis)
 * ============================================================================
 *
 * Completes the gasless self-service email claim. The live failure was paymaster AA33 `Ineligible()`:
 * SUBJECT_TYPE_HAT requires `isEligible(sender, hat)` at VALIDATION time, which can never hold for the
 * hat being claimed. This wave ships:
 *
 *   - PaymasterHub v-zkemail-4:
 *       * SUBJECT_TYPE_CLAIM (0x05): sponsors ops whose callData is exactly execute(claimContract, 0, …)
 *         where claimContract == subjectId. NO eligibility pre-check — the claim contract is the gate
 *         (ZK proof + allowlist + open-hat guard + email-verified eligibility grant). Spend bounded by
 *         the org Budget for keccak(0x05, claimContract) + the existing target/selector Rules.
 *       * UserOpLib v0.7 packing FIX: accountGasLimits/gasFees were unpacked reversed (deployed bug) —
 *         rule gas hints + fee caps capped the WRONG fields. Hints now cap call gas as documented.
 *       * PaymasterSponsorshipLib extraction (delegatecall, shared ERC-7201 slots) — EIP-170 headroom
 *         (hub: 23,594 B, +982 margin at production runs=200).
 *   - Test6 config: Budget for the ZkEmailInvites proxy's CLAIM subject (rules already allowed, hint=0).
 *
 * BROADCAST ORDER: run BroadcastEmailEligibilityUpgrade (EmailEligibilityUpgradeGnosis.s.sol) FIRST —
 * the claim's execution path needs the email-verified eligibility wave. The SIM below applies all three
 * beacon upgrades in-fork and proves the ENTIRE flow: the exact userOp shape that failed live now
 * validates, the claim executes, and postOp settles the budget.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/PaymasterClaimSubjectGnosis.s.sol:SimPaymasterClaimSubject --fork-url gnosis -vvv
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/PaymasterClaimSubjectGnosis.s.sol:BroadcastPaymasterClaimUpgrade --rpc-url gnosis --broadcast --slow
 *   forge script script/zkemail/PaymasterClaimSubjectGnosis.s.sol:VerifyPaymasterClaimGnosis --rpc-url gnosis
 * ============================================================================
 */

interface ISatelliteP {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewP {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
}

interface IHatsLikeP {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
    function isEligible(address wearer, uint256 hatId) external view returns (bool);
}

contract SimMockDomainVerifierP is IZkEmailGroth16Verifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

abstract contract PaymasterClaimBase is Script {
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032; // canonical v0.7

    bytes32 internal constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address internal constant TEST6_PROXY = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    uint256 internal constant TEST6_MEMBER_HAT =
        29035862971903655586674243772344327311664727652070589302159213246545920;

    string internal constant VERSION = "v-zkemail-4"; // probed FREE for PaymasterHub on the registry

    uint8 internal constant PAYMASTER_DATA_VERSION = 1;
    uint8 internal constant SUBJECT_TYPE_CLAIM = 0x05;

    // Test6 claim-budget policy (env-overridable at broadcast): 0.05 xDAI per 7 days ≈ 25-50 claims.
    uint128 internal constant DEFAULT_CLAIM_BUDGET = 0.05 ether;
    uint32 internal constant DEFAULT_CLAIM_EPOCH = 7 days;

    /* Poseidon domain commitments + DKIM key (live ceremony wiring) — for the sim's real claim. */
    bytes32 internal constant OPACITYLABS_POSEIDON = 0x29e7dedcdb5e509c3f276fb5d689700f0eaaa74bfaa75259b4c545cd2241a5c2;
    bytes32 internal constant GMAIL_POSEIDON = 0x14d46e073cbff5944a738ea295de6c7447606fa5a270571229d8a4b1e7ca77e5;
    bytes32 internal constant KU_POSEIDON = 0x256f370d0033263e95a6c486e2a0280c7843b2e0d586e92e6557382f776d6c58;
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    uint8 internal constant LEAF_DOMAIN = 0;

    function _claimSubjectKey(address claimContract) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SUBJECT_TYPE_CLAIM, bytes32(uint256(uint160(claimContract)))));
    }

    function _setBudgetCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "setBudget(bytes32,bytes32,uint128,uint32)",
            TEST6_ORG,
            _claimSubjectKey(TEST6_PROXY),
            uint128(vm.envOr("CLAIM_BUDGET_WEI", uint256(DEFAULT_CLAIM_BUDGET))),
            uint32(vm.envOr("CLAIM_EPOCH_SECONDS", uint256(DEFAULT_CLAIM_EPOCH)))
        );
    }

    /* ── merkle helpers (same 3-domain live tree as the ceremony scripts) ── */
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

    function _gmailRootAndProof() internal pure returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(LEAF_DOMAIN, OPACITYLABS_POSEIDON, _memberHats());
        leaves[1] = _leaf(LEAF_DOMAIN, GMAIL_POSEIDON, _memberHats());
        leaves[2] = _leaf(LEAF_DOMAIN, KU_POSEIDON, _memberHats());
        bytes32 target = leaves[1];
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
        p.emailNullifier = keccak256(abi.encode("paymaster-claim-sim", claimer));
        p.fromDomainHash = GMAIL_POSEIDON;
    }

    /// @dev The exact op shape the frontend submits: execute(proxy, 0, claimRoleByDomain(...)) with a
    ///      CLAIM-subject paymasterAndData and spec-packed v0.7 gas fields.
    function _claimUserOp(address sender, bytes memory innerCallData)
        internal
        pure
        returns (PackedUserOperation memory op)
    {
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6), TEST6_PROXY, uint256(0), innerCallData);
        op = PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: UserOpLib.packAccountGasLimits(500_000, 800_000),
            preVerificationGas: 100_000,
            gasFees: UserOpLib.packGasFees(1 gwei, 2 gwei),
            paymasterAndData: abi.encodePacked(
                PAYMASTER,
                uint128(200_000),
                uint128(100_000),
                PAYMASTER_DATA_VERSION,
                TEST6_ORG,
                SUBJECT_TYPE_CLAIM,
                bytes32(uint256(uint160(TEST6_PROXY))),
                uint32(0)
            ),
            signature: ""
        });
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimPaymasterClaimSubject is PaymasterClaimBase {
    function run() public {
        console.log("\n=== SIM: gasless CLAIM sponsorship -> live Test6 (Gnosis fork) ===");
        require(ISatelliteP(SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        // 1. All three beacon upgrades (eligibility wave + paymaster wave). Deploy impls BEFORE prank.
        address newElig = address(new EligibilityModule());
        address newZk = address(new ZkEmailInvites());
        address newHub = address(new PaymasterHub());
        vm.startPrank(HUDSON);
        ISatelliteP(SATELLITE).upgradeBeaconDirect("EligibilityModule", newElig, VERSION);
        ISatelliteP(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        ISatelliteP(SATELLITE).upgradeBeaconDirect("PaymasterHub", newHub, VERSION);
        // 2. Budget for the Test6 claim subject (rules for the 4 claim selectors are already live).
        ISatelliteP(SATELLITE).adminCall(PAYMASTER, _setBudgetCalldata());
        vm.stopPrank();
        require(
            IPoaManagerViewP(POA_MANAGER).getCurrentImplementationById(keccak256("PaymasterHub")) == newHub,
            "hub beacon not upgraded"
        );
        PaymasterHub.Budget memory b =
            PaymasterHub(payable(PAYMASTER)).getBudget(TEST6_ORG, _claimSubjectKey(TEST6_PROXY));
        require(b.capPerEpoch == DEFAULT_CLAIM_BUDGET, "claim budget not set");
        console.log("[1] Beacons upgraded (elig/zk/hub) + Test6 claim budget set:", uint256(b.capPerEpoch));

        // 3. Fresh claimer + mock ONLY the Groth16 accept (deploy mock BEFORE prank).
        address claimer = makeAddr("gasless-claimer");
        require(!IHatsLikeP(HATS).isEligible(claimer, TEST6_MEMBER_HAT), "fresh claimer unexpectedly eligible");
        address mockVerifier = address(new SimMockDomainVerifierP());
        vm.prank(TEST6_EXECUTOR);
        ZkEmailInvites(TEST6_PROXY).setDomainVerifier(mockVerifier);

        (bytes32 root, bytes32[] memory gmailProof) = _gmailRootAndProof();
        require(ZkEmailInvites(TEST6_PROXY).merkleRoot() == root, "live root drift");
        ZkEmailProof memory p = _gmailProofStruct(claimer);
        bytes memory innerCallData =
            abi.encodeCall(ZkEmailInvites.claimRoleByDomain, (p, claimer, _memberHats(), gmailProof));

        // 4. THE MOMENT: the exact op shape that failed live (AA33 Ineligible) must now VALIDATE.
        PackedUserOperation memory op = _claimUserOp(claimer, innerCallData);
        uint256 maxCost = 0.002 ether;
        vm.prank(ENTRY_POINT);
        (bytes memory context, uint256 validationData) =
            PaymasterHub(payable(PAYMASTER)).validatePaymasterUserOp(op, keccak256("op"), maxCost);
        require(validationData == 0 && context.length > 0, "claim op did not validate");
        console.log("[2] validatePaymasterUserOp PASSED for a fresh, ineligible claimer (CLAIM subject).");

        // 5. Execute the sponsored call (the account's execute would do exactly this inner call).
        vm.prank(claimer);
        ZkEmailInvites(TEST6_PROXY).claimRoleByDomain(p, claimer, _memberHats(), gmailProof);
        require(IHatsLikeP(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "hat not minted");
        console.log("[3] Claim executed: email-verified -> eligible -> Member hat minted.");

        // 6. postOp settles the budget at actual cost.
        uint256 actualCost = 0.0009 ether;
        vm.prank(ENTRY_POINT);
        PaymasterHub(payable(PAYMASTER)).postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 1 gwei);
        b = PaymasterHub(payable(PAYMASTER)).getBudget(TEST6_ORG, _claimSubjectKey(TEST6_PROXY));
        require(uint256(b.usedInEpoch) == actualCost, "budget not settled to actual cost");
        console.log("[4] postOp settled the claim budget:", uint256(b.usedInEpoch));

        // 7. Bindings hold: an op pointed at another target must NOT validate.
        PackedUserOperation memory evil = _claimUserOp(claimer, innerCallData);
        evil.callData = abi.encodeWithSelector(bytes4(0xb61d27f6), address(0xBEEF), uint256(0), innerCallData);
        vm.prank(ENTRY_POINT);
        (bool ok,) = PAYMASTER.call(
            abi.encodeWithSelector(PaymasterHub.validatePaymasterUserOp.selector, evil, keccak256("evil"), maxCost)
        );
        require(!ok, "op targeting another contract must be rejected");
        console.log("[5] Target binding enforced (op to another contract rejected).");

        console.log("\nPASS: gasless CLAIM sponsorship verified end-to-end on a real Gnosis fork.");
    }
}

/* ════════════════════════════ BROADCAST ════════════════════════════ */

/// @notice Hudson: upgrade the PaymasterHub beacon (v-zkemail-4) + set Test6's claim budget.
/// @dev Run AFTER BroadcastEmailEligibilityUpgrade (the claim execution path needs that wave).
contract BroadcastPaymasterClaimUpgrade is PaymasterClaimBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        console.log("\n=== Broadcast: PaymasterHub SUBJECT_TYPE_CLAIM upgrade (v-zkemail-4) ===");

        vm.startBroadcast(key);
        address newHub = address(new PaymasterHub());
        ISatelliteP(SATELLITE).upgradeBeaconDirect("PaymasterHub", newHub, VERSION);
        ISatelliteP(SATELLITE).adminCall(PAYMASTER, _setBudgetCalldata());
        vm.stopBroadcast();

        require(
            IPoaManagerViewP(POA_MANAGER).getCurrentImplementationById(keccak256("PaymasterHub")) == newHub,
            "hub beacon not upgraded"
        );
        PaymasterHub.Budget memory b =
            PaymasterHub(payable(PAYMASTER)).getBudget(TEST6_ORG, _claimSubjectKey(TEST6_PROXY));
        require(b.capPerEpoch > 0, "claim budget not set");
        console.log("  new PaymasterHub impl:", newHub);
        console.log("  Test6 claim budget capPerEpoch:", uint256(b.capPerEpoch));
        console.log("Done. Frontend can now sponsor claims with SUBJECT_TYPE_CLAIM (0x05).");
    }
}

/// @notice Read-only: confirm the CLAIM subject is live for Test6.
contract VerifyPaymasterClaimGnosis is PaymasterClaimBase {
    function run() public view {
        PaymasterHub.Budget memory b =
            PaymasterHub(payable(PAYMASTER)).getBudget(TEST6_ORG, _claimSubjectKey(TEST6_PROXY));
        bool budgetOk = b.capPerEpoch > 0;
        console.log("\n=== Verify Test6 CLAIM sponsorship ===");
        console.log("  claim budget capPerEpoch:", uint256(b.capPerEpoch));
        console.log("  claim budget epochLen:   ", uint256(b.epochLen));
        if (budgetOk) {
            console.log("PASS: CLAIM budget live (upgrade state verified by the broadcast asserts).");
        } else {
            console.log("INCOMPLETE: run BroadcastPaymasterClaimUpgrade.");
        }
    }
}
