// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {ZkEmailInvites, IExecutorHatMinter} from "../src/ZkEmailInvites.sol";
import {ZkEmailProof, ZkEmailProofV2} from "../src/zkemail/IVerifier.sol";
import {Groth16Verifier} from "../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../src/zkemail/PoaDKIMRegistry.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/// @dev Minimal Hats + eligibility-module stand-in — all hats GATED (probe → false) by default; the
///      claim contract's email-verified grant (viewHat → this module; setEmailVerified) makes ONLY the
///      claimer eligible, mirroring the real EligibilityModule's third path.
contract RealProofMockHats {
    mapping(uint256 => mapping(address => bool)) public emailVerified;

    function isEligible(address wearer, uint256 hatId) external view returns (bool) {
        return emailVerified[hatId][wearer];
    }

    function setEmailVerified(address wearer, uint256[] calldata hatIds) external {
        for (uint256 i; i < hatIds.length; ++i) {
            emailVerified[hatIds[i]][wearer] = true;
        }
    }

    function viewHat(uint256)
        external
        view
        returns (string memory, uint32, uint32, address, address, string memory, uint16, bool, bool)
    {
        return ("", 0, 0, address(this), address(0), "", 0, true, true);
    }
}

/// @notice Records `mintHatsForUser` calls so the test can assert what ZkEmailInvites minted, AND acts
///         as the org executor (governance) so it can activate the allowlist.
contract RecordingExecutor is IExecutorHatMinter {
    address public lastUser;
    uint256[] public lastHats;
    uint256 public mintCount;
    IHats private _hats;

    constructor() {
        _hats = IHats(address(new RealProofMockHats()));
    }

    function hats() external view returns (IHats) {
        return _hats;
    }

    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        lastUser = user;
        delete lastHats;
        for (uint256 i; i < hatIds.length; ++i) {
            lastHats.push(hatIds[i]);
        }
        mintCount++;
    }

    /// @dev Lets the test drive an executor-gated call (e.g. setActiveAllowlist) from this address.
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec call failed");
        return ret;
    }
}

/**
 * @title ZkEmailRealProofTest
 * @notice End-to-end "no mock" test on the FINAL PRODUCTION artifacts. BOTH proofs below are GENUINE
 *         Groth16 proofs produced off-chain by snarkjs against the multi-party CEREMONY zkeys (Blocker
 *         1 closed), for the same test email, and verified by the vendored PRODUCTION verifiers:
 *           - the DOMAIN proof from `circuits/PopRoleClaim.circom` (4 signals incl. the proven
 *             `fromDomainHash`), verified by `Groth16Verifier`, and
 *           - the SPECIFIC-ADDRESS proof from `circuits/PopRoleClaimV2.circom` (5 signals incl.
 *             `emailHash` + `fromDomainHash`), verified by `Groth16VerifierV2`.
 *         Each is claimed against a genuine 2-leaf merkle root activated via governance and mints the
 *         leaf's hat to exactly the in-circuit-bound address. No mock anywhere in the cryptographic path
 *         — real Groth16 pairing + real OZ merkle proof + real mint + real DKIM binding to the PROVEN
 *         domain (Blocker 2). This is the check that caught the stale-circuit v1: `fromDomainHash` here
 *         is the correct `0x1f4e7d8c…` (== off-chain Poseidon("poptest.example")), shared by both proofs.
 */
contract ZkEmailRealProofTest is Test {
    // Both proofs were generated for the same test claimer + email + domain.
    address constant CLAIMER = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    uint256 constant DOMAIN_HAT = 42;
    uint256 constant EMAIL_HAT = 43;

    // Shared public signals (both proofs are from the same DKIM-signed email).
    bytes32 constant PUBKEY = 0x14e227eafc6e00310ecf9335af19dbd7c26bcfb73cd88822cf1e19f4182122a4;
    bytes32 constant NULLIFIER = 0x21e7a322ea8b904894df539aff05fb5323c6aa2640157dcecde4bbe2db7ccf18;
    bytes32 constant FROM_DOMAIN_HASH = 0x1f4e7d8c94d826f5672db3a3242cbbfa8bf6c98fa20c0223ab7094bb3438c5ca;
    bytes32 constant EMAIL_HASH = 0x1f9fc5fda5d9befbc5ebcf87f0f6079da44b6ae8b88fad1ff132c77fcb696fd9;

    Groth16Verifier domainVerifier;
    Groth16VerifierV2 emailVerifier;
    PoaDKIMRegistry registry;
    ZkEmailInvites invites;
    RecordingExecutor executor;

    // 2-leaf allowlist: [domain entry -> DOMAIN_HAT, email entry -> EMAIL_HAT].
    bytes32 domainLeaf;
    bytes32 emailLeaf;
    bytes32 root;

    /// @dev Genuine domain proof (snarkjs `groth16 export soliditycalldata`, pB already in verifier order).
    function _domainProof() internal pure returns (ZkEmailProof memory p) {
        p.pA = [
            uint256(0x0b1fd3ac4af6af5200fcadd837a7df5b97fef330adb7b7bca5ec407057d25fda),
            0x21151913c6727be3730ac6c82378614d4dc3b8d5307072875e0abd72a72b1038
        ];
        p.pB = [
            [
                uint256(0x1c69f14f37e2d5cf1cd0dcc8039b4fe4f97494f0c846d8f04a5956773244e144),
                0x0bae46fb5a47abe8511b1cbc4d4f6bc10d8a0b600174e60d6942b98aaad45dad
            ],
            [
                uint256(0x2a9b73fcf869088473c534b4e92bdf46a6f8cdb496abea026cd6f5c333fb2b39),
                0x11230d276c17d0a4a6daaffe8e954f22ecf798b3b506a318978c0a9bde1d79df
            ]
        ];
        p.pC = [
            uint256(0x1c605172ec6f7ea0ea9b5e6b4f3c3e7ec4180111da76ae547a910cb7908da947),
            0x27e5d56e644a5fab25ebb71275087baea1a1a6d38c13772632f83f0f103ddd83
        ];
        p.pubkeyHash = PUBKEY;
        p.emailNullifier = NULLIFIER;
        p.fromDomainHash = FROM_DOMAIN_HASH;
    }

    /// @dev Genuine specific-address (v2) proof — 5 public signals (emailHash + fromDomainHash).
    function _emailProof() internal pure returns (ZkEmailProofV2 memory p) {
        p.pA = [
            uint256(0x193109906196d030745117b404f76d4086e3acfd24b89cc121ec2b314008ebbe),
            0x0e3c38c8c32a82c574dd3841e2c380a40d17db81e1bcd89d2cd7957fa1ad4cd8
        ];
        p.pB = [
            [
                uint256(0x259e661c684a162d641569fc2ce78d8f4a2e218227838d873053d64c6c9d2e57),
                0x23688988e89ef444eab095d089b481ab27bc0a0b5ffec1e16ebedd0f64f59661
            ],
            [
                uint256(0x0a8d2d870386332d3e6362cb638b0a6a5fdcfa09615db3d8a46f4a16643794a2),
                0x0bee83d965e8613fa4eba5a0874207ea22373ac354b9bc0c7fc79ef291422060
            ]
        ];
        p.pC = [
            uint256(0x1714c99c69dec6a43ff8da03a3e61969fefeb22f1af7cb1590396eb9773e6fe3),
            0x0202ec3a75203bb9d8a98ccc783549fecf5b4de805902b321ff5ad30b7482fa2
        ];
        p.pubkeyHash = PUBKEY;
        p.emailNullifier = NULLIFIER;
        p.emailHash = EMAIL_HASH;
        p.fromDomainHash = FROM_DOMAIN_HASH;
    }

    // OZ StandardMerkleTree leaf + sorted-pair node hashing (matches ZkEmailInvites._leaf + MerkleProof).
    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _sibling(bytes32 s) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = s;
    }

    function _activate(bytes32 r) internal {
        executor.call(address(invites), abi.encodeCall(ZkEmailInvites.setActiveAllowlist, (r, bytes32("cid"))));
    }

    function setUp() public {
        domainVerifier = new Groth16Verifier();
        emailVerifier = new Groth16VerifierV2();
        registry = new PoaDKIMRegistry(address(this));
        // Blocker 2: the DKIM lookup key is the PROVEN fromDomainHash (Poseidon), not keccak(domain).
        // Seed the (fromDomainHash, pubkeyHash) pair the genuine proofs commit to.
        registry.setKeyHash(FROM_DOMAIN_HASH, PUBKEY, true);
        executor = new RecordingExecutor();

        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        invites = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
        invites.initialize(
            address(executor), // executor / mint sink / governance
            address(domainVerifier),
            address(emailVerifier),
            address(registry),
            address(0xdead), // accountRegistry (unused on the bare paths; must be non-zero)
            address(0), // universalFactory (late-bind)
            bytes32(0), // dormant at init
            bytes32(0)
        );

        // Blocker 2: the domain leaf id is the proven fromDomainHash (not keccak(domain)).
        domainLeaf = _leaf(0, FROM_DOMAIN_HASH, _one(DOMAIN_HAT));
        emailLeaf = _leaf(1, EMAIL_HASH, _one(EMAIL_HAT));
        root = _pair(domainLeaf, emailLeaf);
        _activate(root);
    }

    /// The real domain verifier accepts the genuine 4-signal proof for the bound claimer.
    function testDomainVerifier_acceptsRealProof() public view {
        ZkEmailProof memory p = _domainProof();
        uint256[4] memory s =
            [uint256(PUBKEY), uint256(NULLIFIER), uint256(uint160(CLAIMER)), uint256(FROM_DOMAIN_HASH)];
        assertTrue(domainVerifier.verifyProof(p.pA, p.pB, p.pC, s), "real domain proof must verify");
    }

    /// The real specific-address verifier accepts the genuine 5-signal proof (emailHash + fromDomainHash).
    function testEmailVerifier_acceptsRealV2Proof() public view {
        ZkEmailProofV2 memory p = _emailProof();
        uint256[5] memory s = [
            uint256(PUBKEY),
            uint256(NULLIFIER),
            uint256(uint160(CLAIMER)),
            uint256(EMAIL_HASH),
            uint256(FROM_DOMAIN_HASH)
        ];
        assertTrue(emailVerifier.verifyProof(p.pA, p.pB, p.pC, s), "real v2 proof must verify");
    }

    /// Soundness of the email commitment: flip the emailHash signal and the same proof fails.
    function testEmailVerifier_rejectsTamperedEmailHash() public view {
        ZkEmailProofV2 memory p = _emailProof();
        uint256[5] memory s = [
            uint256(PUBKEY),
            uint256(NULLIFIER),
            uint256(uint160(CLAIMER)),
            uint256(bytes32("not-the-email")),
            uint256(FROM_DOMAIN_HASH)
        ];
        assertFalse(emailVerifier.verifyProof(p.pA, p.pB, p.pC, s), "tampered emailHash must fail");
    }

    /// Soundness of the domain binding: flip the fromDomainHash signal and the same proof fails.
    function testDomainVerifier_rejectsTamperedDomainHash() public view {
        ZkEmailProof memory p = _domainProof();
        uint256[4] memory s =
            [uint256(PUBKEY), uint256(NULLIFIER), uint256(uint160(CLAIMER)), uint256(bytes32("not-the-domain"))];
        assertFalse(domainVerifier.verifyProof(p.pA, p.pB, p.pC, s), "tampered fromDomainHash must fail");
    }

    /// Headline #1: genuine domain proof + genuine merkle proof -> on-chain verify -> hat minted.
    function testClaimRoleByDomain_withRealProofAndMerkle_mintsHat() public {
        invites.claimRoleByDomain(_domainProof(), CLAIMER, _one(DOMAIN_HAT), _sibling(emailLeaf));
        assertEq(executor.mintCount(), 1, "one mint");
        assertEq(executor.lastUser(), CLAIMER, "minted to bound claimer");
        assertEq(executor.lastHats(0), DOMAIN_HAT, "minted the domain entry's hat");
        assertTrue(invites.isNullifierUsed(NULLIFIER), "nullifier consumed");
    }

    /// Headline #2: genuine SPECIFIC-ADDRESS proof + email merkle leaf -> mint.
    function testClaimRoleByEmail_withRealV2ProofAndMerkle_mintsHat() public {
        invites.claimRoleByEmail(_emailProof(), CLAIMER, _one(EMAIL_HAT), _sibling(domainLeaf));
        assertEq(executor.mintCount(), 1, "one mint");
        assertEq(executor.lastUser(), CLAIMER, "minted to bound claimer");
        assertEq(executor.lastHats(0), EMAIL_HAT, "minted the specific-address entry's hat");
        assertTrue(invites.isNullifierUsed(NULLIFIER), "nullifier consumed");
    }

    /// A claimer cannot inflate hats: the hatIds are committed in the signed leaf, so a wrong hat fails.
    function testClaimRoleByEmail_wrongHatReverts() public {
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        invites.claimRoleByEmail(_emailProof(), CLAIMER, _one(999), _sibling(domainLeaf));
    }

    /// A wrong merkle sibling fails the proof.
    function testClaimRoleByDomain_badMerkleProofReverts() public {
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        invites.claimRoleByDomain(_domainProof(), CLAIMER, _one(DOMAIN_HAT), _sibling(bytes32("wrong")));
    }

    /// Replaying the same proof is blocked by the nullifier guard.
    function testClaimRoleByEmail_replayBlocked() public {
        invites.claimRoleByEmail(_emailProof(), CLAIMER, _one(EMAIL_HAT), _sibling(domainLeaf));
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        invites.claimRoleByEmail(_emailProof(), CLAIMER, _one(EMAIL_HAT), _sibling(domainLeaf));
    }

    /// Wrong claimer fails on-chain verification (claimer is a public signal).
    function testClaimRoleByDomain_wrongClaimerReverts() public {
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        invites.claimRoleByDomain(_domainProof(), address(0xBEEF), _one(DOMAIN_HAT), _sibling(emailLeaf));
    }

    /// DKIM binding enforced: revoking the proven domain's key fails before proof verification.
    function testClaim_unregisteredDomainReverts() public {
        registry.setKeyHash(FROM_DOMAIN_HASH, PUBKEY, false);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        invites.claimRoleByDomain(_domainProof(), CLAIMER, _one(DOMAIN_HAT), _sibling(emailLeaf));
    }

    /// Dormant module (no active root) rejects every claim.
    function testClaim_dormantReverts() public {
        _activate(bytes32(0)); // governance dormants the module
        vm.expectRevert(ZkEmailInvites.AllowlistNotActive.selector);
        invites.claimRoleByDomain(_domainProof(), CLAIMER, _one(DOMAIN_HAT), _sibling(emailLeaf));
    }
}
