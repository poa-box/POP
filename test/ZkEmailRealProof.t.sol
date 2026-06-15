// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {ZkEmailInvites, IExecutorHatMinter} from "../src/ZkEmailInvites.sol";
import {ZkEmailProof} from "../src/zkemail/IVerifier.sol";
import {Groth16Verifier} from "../src/zkemail/vendor/Groth16Verifier.sol";
import {PoaDKIMRegistry} from "../src/zkemail/PoaDKIMRegistry.sol";

/// @notice Records `mintHatsForUser` calls so the test can assert what ZkEmailInvites minted.
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
}

/**
 * @title ZkEmailRealProofTest
 * @notice End-to-end "no mock" spike. The proof below is a GENUINE Groth16 proof produced entirely
 *         off-chain by snarkjs from `circuits/PopRoleClaim.circom` over a REAL DKIM-signed email
 *         whose subject is "Claim POP role for 0xA6F4...b2c9". It is verified ON-CHAIN by the
 *         snarkjs-generated `Groth16Verifier` (the actual cryptographic path — no mock verifier),
 *         and drives a real `ZkEmailInvites.claimRoleByDomain` that mints the domain rule's hat to
 *         exactly the address bound inside the signed command.
 */
contract ZkEmailRealProofTest is Test {
    // ── Public signals of the real proof ──
    address constant CLAIMER = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    string constant DOMAIN = "poptest.example";
    bytes32 constant PUBKEY_HASH = 0x2e4ff3252e8029094f7b65899a07343d89647563707d1e4c88858801e2a748c8;
    bytes32 constant NULLIFIER = 0x08a2fcc91dc786ec874237679a23f128510892138de379554951a6eddab65b87;
    uint256 constant MEMBER_HAT = 42;

    Groth16Verifier verifier;
    PoaDKIMRegistry registry;
    ZkEmailInvites invites;
    RecordingExecutor executor;

    /// @dev The genuine proof points (snarkjs `groth16 export soliditycalldata`; G2 pairs already in
    ///      the verifier's expected order).
    function _proof() internal pure returns (ZkEmailProof memory p) {
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
        p.pubkeyHash = PUBKEY_HASH;
        p.emailNullifier = NULLIFIER;
        p.domainName = DOMAIN;
    }

    function setUp() public {
        verifier = new Groth16Verifier();
        registry = new PoaDKIMRegistry(address(this));
        registry.setKeyForDomain(DOMAIN, PUBKEY_HASH, true);
        executor = new RecordingExecutor();

        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        invites = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));

        ZkEmailInvites.InitDomainRule[] memory dr = new ZkEmailInvites.InitDomainRule[](1);
        uint256[] memory hats = new uint256[](1);
        hats[0] = MEMBER_HAT;
        dr[0] = ZkEmailInvites.InitDomainRule({domain: DOMAIN, hatIds: hats, expiry: 0});

        invites.initialize(
            address(executor), // executor / mint sink
            address(verifier), // the REAL generated Groth16 verifier
            address(registry),
            address(0xdead), // accountRegistry (unused on the bare domain path; must be non-zero)
            address(0), // universalFactory (late-bind)
            dr,
            new ZkEmailInvites.InitEmailRule[](0)
        );
    }

    /// The generated verifier accepts the genuine proof for the bound claimer.
    function testGeneratedVerifier_acceptsRealProof() public view {
        ZkEmailProof memory p = _proof();
        uint256[3] memory signals = [uint256(PUBKEY_HASH), uint256(NULLIFIER), uint256(uint160(CLAIMER))];
        assertTrue(verifier.verifyProof(p.pA, p.pB, p.pC, signals), "real proof must verify on-chain");
    }

    /// Soundness of the address binding: flip the claimer signal and the same proof no longer verifies.
    function testGeneratedVerifier_rejectsTamperedClaimer() public view {
        ZkEmailProof memory p = _proof();
        uint256[3] memory signals = [uint256(PUBKEY_HASH), uint256(NULLIFIER), uint256(uint160(address(0xBEEF)))];
        assertFalse(verifier.verifyProof(p.pA, p.pB, p.pC, signals), "tampered claimer must fail");
    }

    /// Full path: genuine proof -> claimRoleByDomain -> on-chain verify -> hat minted to the bound address.
    function testClaimRoleByDomain_withRealProof_mintsHat() public {
        invites.claimRoleByDomain(_proof(), CLAIMER);
        assertEq(executor.mintCount(), 1, "exactly one mint");
        assertEq(executor.lastUser(), CLAIMER, "minted to the in-circuit-bound claimer");
        assertEq(executor.lastHats(0), MEMBER_HAT, "minted the domain rule's hat");
        assertTrue(invites.isNullifierUsed(NULLIFIER), "nullifier consumed");
    }

    /// Replaying the same proof is blocked by the nullifier guard.
    function testClaimRoleByDomain_replayBlocked() public {
        invites.claimRoleByDomain(_proof(), CLAIMER);
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        invites.claimRoleByDomain(_proof(), CLAIMER);
    }

    /// A different submitter cannot redirect the proof: the claimer is a public signal, so any address
    /// other than the bound one fails on-chain verification.
    function testClaimRoleByDomain_wrongClaimerReverts() public {
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        invites.claimRoleByDomain(_proof(), address(0xBEEF));
    }

    /// The DKIM registry binding is enforced: an unseeded domain fails before proof verification.
    function testClaimRoleByDomain_unregisteredDomainReverts() public {
        registry.setKeyForDomain(DOMAIN, PUBKEY_HASH, false);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        invites.claimRoleByDomain(_proof(), CLAIMER);
    }
}
