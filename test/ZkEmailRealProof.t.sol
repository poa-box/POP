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

/// @notice Records `mintHatsForUser` calls so the test can assert what ZkEmailInvites minted, AND acts
///         as the org executor (governance) so it can activate the allowlist.
contract RecordingExecutor is IExecutorHatMinter {
    address public lastUser;
    uint256[] public lastHats;
    uint256 public mintCount;

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
 * @notice End-to-end "no mock" spike for the merkle-allowlist model. BOTH proofs below are GENUINE
 *         Groth16 proofs produced off-chain by snarkjs:
 *           - the DOMAIN proof from `circuits/PopRoleClaim.circom` (3 signals), verified by the real
 *             vendored `Groth16Verifier`, and
 *           - the SPECIFIC-ADDRESS proof from `circuits/PopRoleClaimV2.circom` (4 signals incl. the
 *             in-circuit `emailHash` commitment to the From address), verified by `Groth16VerifierV2`.
 *         Each is claimed against a genuine 2-leaf merkle root (domain leaf + email leaf) activated via
 *         governance, and mints the leaf's hat to exactly the in-circuit-bound address. No mock anywhere
 *         in the cryptographic path — real Groth16 pairing + real OZ merkle proof + real mint.
 */
contract ZkEmailRealProofTest is Test {
    // Both proofs were generated for the same test claimer + domain.
    address constant CLAIMER = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    string constant DOMAIN = "poptest.example";
    uint256 constant DOMAIN_HAT = 42;
    uint256 constant EMAIL_HAT = 43;

    // ── domain (v1) proof public signals ──
    bytes32 constant D_PUBKEY = 0x2e4ff3252e8029094f7b65899a07343d89647563707d1e4c88858801e2a748c8;
    bytes32 constant D_NULLIFIER = 0x08a2fcc91dc786ec874237679a23f128510892138de379554951a6eddab65b87;
    // ── specific-address (v2) proof public signals ──
    bytes32 constant E_PUBKEY = 0x19c269549a0daff958a83b50b87e8122eb133c100ada2b48f626175fd4b7e38a;
    bytes32 constant E_NULLIFIER = 0x2a8996a8657746c76bf2dda0d2378cc09a7826a6d55bc4db2ec9521ff6a073fa;
    bytes32 constant E_EMAILHASH = 0x1f9fc5fda5d9befbc5ebcf87f0f6079da44b6ae8b88fad1ff132c77fcb696fd9;

    Groth16Verifier domainVerifier;
    Groth16VerifierV2 emailVerifier;
    PoaDKIMRegistry registry;
    ZkEmailInvites invites;
    RecordingExecutor executor;

    // 2-leaf allowlist: [domain entry -> DOMAIN_HAT, email entry -> EMAIL_HAT].
    bytes32 domainLeaf;
    bytes32 emailLeaf;
    bytes32 root;

    /// @dev Genuine domain proof (snarkjs `groth16 export soliditycalldata`, G2 pairs in verifier order).
    function _domainProof() internal pure returns (ZkEmailProof memory p) {
        p.pA = [
            uint256(0x24fd79e232746db34babe0598330c6615b99b29a611da08ad8c737bd1619358f),
            0x07f75c25a6539622668ff45f33b83fdafcf292e524f008b0974db220b7a30843
        ];
        p.pB = [
            [
                uint256(0x11123e5d41f6bed1e0a23b927aa0e96f9351a66b89275c20158d4098c35acbbc),
                0x14d7676ed4f9b1ac7426636c0c996b8fc0aaf81f0e44920573b1fa576eb4eb86
            ],
            [
                uint256(0x010ebcc685be5bc062a6fa5f61a0d1b446a85d78db61f6bc2befccd9587df41e),
                0x2264b0e47ca21b669752d950c4a1c5b35214c295d51220946fedcc7149688050
            ]
        ];
        p.pC = [
            uint256(0x24560c48c0971eda9e3a0d6a8672152101e416f59670d7f5ddfb6efb7b0e70f6),
            0x2a3f6e5a123573350c556de5f84c2dc1e829f5973222d009892e57de23dca26e
        ];
        p.pubkeyHash = D_PUBKEY;
        p.emailNullifier = D_NULLIFIER;
        p.domainName = DOMAIN;
    }

    /// @dev Genuine specific-address (v2) proof — 4 public signals, the 4th being `emailHash`.
    function _emailProof() internal pure returns (ZkEmailProofV2 memory p) {
        p.pA = [
            uint256(0x12c9a76044c24ac59c4aba388e8dca0ed46ceffa52e76bbd02ca825c03a84c2b),
            0x0ea548d9e6cdfcc292af10efb67100b8abd080de96061a2c917a7ad67f370266
        ];
        p.pB = [
            [
                uint256(0x1cc90ebe4ba7d168fdd2b799c465ce9c8e6e3000c74d4d490a1aad49f7dbe3e7),
                0x0abfeccb186713b50bf28f4741f1e5a890d171467c26e7000e7b050bce4de532
            ],
            [
                uint256(0x1dadcb8162681333a3a2d813521b44ae8d4d12bf8a03a864e5439f43075f0b24),
                0x291ae45a810f875840e7ac43679bf0bb0e747aa2941c39d4b24f5478d4f458de
            ]
        ];
        p.pC = [
            uint256(0x0ede8f9bb6f87a18926deadcbfc12fa41a9e5731668040fd9b77586eff0bc021),
            0x121f46fc33c2a96534a27b1cb9ad5d2a7067bc52b8d21b61bb1e35c5e2604c22
        ];
        p.pubkeyHash = E_PUBKEY;
        p.emailNullifier = E_NULLIFIER;
        p.domainName = DOMAIN;
        p.emailHash = E_EMAILHASH;
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
        // Each proof was generated with its own throwaway DKIM key for poptest.example; seed both.
        registry.setKeyForDomain(DOMAIN, D_PUBKEY, true);
        registry.setKeyForDomain(DOMAIN, E_PUBKEY, true);
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

        domainLeaf = _leaf(0, keccak256(bytes(DOMAIN)), _one(DOMAIN_HAT));
        emailLeaf = _leaf(1, E_EMAILHASH, _one(EMAIL_HAT));
        root = _pair(domainLeaf, emailLeaf);
        _activate(root);
    }

    /// The real domain verifier accepts the genuine 3-signal proof for the bound claimer.
    function testDomainVerifier_acceptsRealProof() public view {
        ZkEmailProof memory p = _domainProof();
        uint256[3] memory s = [uint256(D_PUBKEY), uint256(D_NULLIFIER), uint256(uint160(CLAIMER))];
        assertTrue(domainVerifier.verifyProof(p.pA, p.pB, p.pC, s), "real domain proof must verify");
    }

    /// The real specific-address verifier accepts the genuine 4-signal proof (incl. emailHash).
    function testEmailVerifier_acceptsRealV2Proof() public view {
        ZkEmailProofV2 memory p = _emailProof();
        uint256[4] memory s = [uint256(E_PUBKEY), uint256(E_NULLIFIER), uint256(uint160(CLAIMER)), uint256(E_EMAILHASH)];
        assertTrue(emailVerifier.verifyProof(p.pA, p.pB, p.pC, s), "real v2 proof must verify");
    }

    /// Soundness of the email commitment: flip the emailHash signal and the same proof fails.
    function testEmailVerifier_rejectsTamperedEmailHash() public view {
        ZkEmailProofV2 memory p = _emailProof();
        uint256[4] memory s =
            [uint256(E_PUBKEY), uint256(E_NULLIFIER), uint256(uint160(CLAIMER)), uint256(bytes32("not-the-email"))];
        assertFalse(emailVerifier.verifyProof(p.pA, p.pB, p.pC, s), "tampered emailHash must fail");
    }

    /// Headline #1: genuine domain proof + genuine merkle proof -> on-chain verify -> hat minted.
    function testClaimRoleByDomain_withRealProofAndMerkle_mintsHat() public {
        invites.claimRoleByDomain(_domainProof(), CLAIMER, _one(DOMAIN_HAT), _sibling(emailLeaf));
        assertEq(executor.mintCount(), 1, "one mint");
        assertEq(executor.lastUser(), CLAIMER, "minted to bound claimer");
        assertEq(executor.lastHats(0), DOMAIN_HAT, "minted the domain entry's hat");
        assertTrue(invites.isNullifierUsed(D_NULLIFIER), "nullifier consumed");
    }

    /// Headline #2 (the new capability): genuine SPECIFIC-ADDRESS proof + email merkle leaf -> mint.
    function testClaimRoleByEmail_withRealV2ProofAndMerkle_mintsHat() public {
        invites.claimRoleByEmail(_emailProof(), CLAIMER, _one(EMAIL_HAT), _sibling(domainLeaf));
        assertEq(executor.mintCount(), 1, "one mint");
        assertEq(executor.lastUser(), CLAIMER, "minted to bound claimer");
        assertEq(executor.lastHats(0), EMAIL_HAT, "minted the specific-address entry's hat");
        assertTrue(invites.isNullifierUsed(E_NULLIFIER), "nullifier consumed");
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

    /// DKIM binding enforced: an unregistered domain key fails before proof verification.
    function testClaim_unregisteredDomainReverts() public {
        registry.setKeyForDomain(DOMAIN, D_PUBKEY, false);
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
