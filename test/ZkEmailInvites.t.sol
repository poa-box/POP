// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {
    ZkEmailInvites,
    IUniversalAccountRegistry,
    IUniversalPasskeyAccountFactory,
    IExecutorHatMinter
} from "../src/ZkEmailInvites.sol";
import {
    IZkEmailGroth16Verifier,
    IZkEmailGroth16VerifierV2,
    ZkEmailProof,
    ZkEmailProofV2
} from "../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../src/zkemail/IDKIMRegistry.sol";
import {WebAuthnLib} from "../src/libs/WebAuthnLib.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/*──────────────────────────────  Mocks  ──────────────────────────────*/

/// @notice Minimal Hats stand-in for the H-03 open-hat gate. Only isEligible is exercised; by default
///         every hat is GATED (probe → false) so normal claims pass. `setOpen(hatId)` marks a hat
///         open-to-everyone (probe → true) to exercise the reject path; `setReverting(true)` makes
///         isEligible revert to exercise the FAIL-CLOSED path.
contract MockHats {
    mapping(uint256 => bool) public openHat;
    mapping(uint256 => mapping(address => bool)) public emailVerified;
    bool public reverting;
    bool public blockEmailVerify; // grant becomes a revert → exercises the ClaimerNotEligible fail-closed path

    function setOpen(uint256 hatId, bool v) external {
        openHat[hatId] = v;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function setBlockEmailVerify(bool v) external {
        blockEmailVerify = v;
    }

    function isEligible(address wearer, uint256 hatId) external view returns (bool) {
        require(!reverting, "eligibility module down");
        return openHat[hatId] || emailVerified[hatId][wearer];
    }

    /// @dev Doubles as the hat's eligibility module (viewHat points here), mirroring the real
    ///      EligibilityModule's email-verified third path.
    function setEmailVerified(address wearer, uint256[] calldata hatIds) external {
        require(!blockEmailVerify, "email verify disabled");
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

/// @notice Stand-in for the snarkjs `Groth16Verifier` (domain circuit, 3 signals). Ignores the proof
///         points entirely and returns a settable `result` (default true) so tests can toggle validity.
contract MockDomainVerifier is IZkEmailGroth16Verifier {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

/// @notice Stand-in for the snarkjs `Groth16VerifierV2` (specific-email circuit, 4 signals).
contract MockEmailVerifier is IZkEmailGroth16VerifierV2 {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

contract MockDKIMRegistry is IDKIMRegistry {
    bool public result = true;
    mapping(bytes32 => mapping(bytes32 => bool)) public overrides;
    mapping(bytes32 => mapping(bytes32 => bool)) public overrideSet;

    function setResult(bool v) external {
        result = v;
    }

    function setKey(bytes32 domainHash, bytes32 keyHash, bool ok) external {
        overrides[domainHash][keyHash] = ok;
        overrideSet[domainHash][keyHash] = true;
    }

    function isKeyHashValid(bytes32 domainHash, bytes32 keyHash) external view returns (bool) {
        if (overrideSet[domainHash][keyHash]) return overrides[domainHash][keyHash];
        return result;
    }
}

contract MockAccountRegistry is IUniversalAccountRegistry {
    bool public shouldRevert;
    bytes32 public lastCredentialId;
    string public lastUsername;
    uint256 public callCount;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function registerAccountByPasskeySig(
        bytes32 credentialId,
        bytes32,
        bytes32,
        uint256,
        string calldata username,
        uint256 deadline,
        uint256,
        WebAuthnLib.WebAuthnAuth calldata
    ) external {
        if (shouldRevert) revert("MockRegistry: rejected");
        require(block.timestamp <= deadline, "expired");
        lastCredentialId = credentialId;
        lastUsername = username;
        callCount++;
    }
}

contract MockUniversalFactory is IUniversalPasskeyAccountFactory {
    mapping(bytes32 => address) public deployed;
    uint256 public callCount;

    function pin(bytes32 credentialId, address acct) external {
        deployed[credentialId] = acct;
    }

    function createAccount(bytes32 credentialId, bytes32, bytes32, uint256) external returns (address account) {
        callCount++;
        account = deployed[credentialId];
        if (account == address(0)) {
            // Deterministically derive a fresh address from credentialId
            account = address(uint160(uint256(keccak256(abi.encode("acct", credentialId)))));
            deployed[credentialId] = account;
        }
    }
}

contract MockExecutor is IExecutorHatMinter {
    struct Mint {
        address user;
        uint256[] hatIds;
    }

    Mint[] private _mints;
    IHats private _hats;

    constructor() {
        _hats = IHats(address(new MockHats()));
    }

    function hats() external view returns (IHats) {
        return _hats;
    }

    /// @dev Test hook: reach the underlying MockHats to flip open/reverting flags.
    function mockHats() external view returns (MockHats) {
        return MockHats(address(_hats));
    }

    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        uint256[] memory copy = new uint256[](hatIds.length);
        for (uint256 i; i < hatIds.length; ++i) {
            copy[i] = hatIds[i];
        }
        _mints.push(Mint(user, copy));
    }

    function mintCount() external view returns (uint256) {
        return _mints.length;
    }

    function mintAt(uint256 i) external view returns (address user, uint256[] memory hatIds) {
        Mint storage m = _mints[i];
        return (m.user, m.hatIds);
    }
}

/// @notice Reentrancy probe — wired as a malicious executor that calls back into ZkEmailInvites.
contract ReentrancyExecutor is IExecutorHatMinter {
    ZkEmailInvites public zk;
    ZkEmailProof internal _proof;
    address public claimer;
    uint256[] internal _hatIds;
    bytes32[] internal _merkleProof;
    bool public attempted;
    IHats private _hats;

    constructor() {
        _hats = IHats(address(new MockHats()));
    }

    function hats() external view returns (IHats) {
        return _hats;
    }

    function arm(
        ZkEmailInvites _zk,
        ZkEmailProof memory p,
        address _claimer,
        uint256[] memory hatIds,
        bytes32[] memory merkleProof
    ) external {
        zk = _zk;
        _proof = p;
        claimer = _claimer;
        _hatIds = hatIds;
        _merkleProof = merkleProof;
    }

    function mintHatsForUser(address, uint256[] calldata) external {
        if (attempted) return;
        attempted = true;
        // Recurse — should be blocked by nonReentrant
        zk.claimRoleByDomain(_proof, claimer, _hatIds, _merkleProof);
    }
}

/*──────────────────────────────  Tests  ──────────────────────────────*/

contract ZkEmailInvitesTest is Test {
    ZkEmailInvites zk;
    MockDomainVerifier domainVerifier;
    MockEmailVerifier emailVerifier;
    MockDKIMRegistry dkim;
    MockAccountRegistry acctRegistry;
    MockUniversalFactory factory;
    MockExecutor executorMock;

    address executorAddr;
    address user = address(0xC0FFEE);

    // Standard fixture template
    string constant DOMAIN = "anthropic.com";
    bytes32 DOMAIN_HASH = keccak256(bytes("anthropic.com"));
    bytes32 constant KEY_HASH = bytes32(uint256(0xAA));
    bytes32 constant EMAIL_HASH_ALICE = bytes32(uint256(0xA11CE));
    bytes32 constant EMAIL_HASH_BOB = bytes32(uint256(0xB0B));
    bytes32 constant CID = bytes32(uint256(0xC1D));

    uint8 constant LEAF_DOMAIN = 0;
    uint8 constant LEAF_EMAIL = 1;

    event ActiveAllowlistSet(bytes32 indexed merkleRoot, bytes32 indexed allowlistCid);
    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event RegisteredEmailCleared(bytes32 indexed emailHash);
    event RoleClaimedByEmail(address indexed claimer, bytes32 indexed emailHash, uint256[] hatIds, bytes32 nullifier);
    event DomainVerifierUpdated(address indexed verifier);
    event EmailVerifierUpdated(address indexed verifier);
    event DKIMRegistryUpdated(address indexed registry);
    event AccountRegistryUpdated(address indexed registry);
    event UniversalFactoryUpdated(address indexed factory);

    function setUp() public {
        domainVerifier = new MockDomainVerifier();
        emailVerifier = new MockEmailVerifier();
        dkim = new MockDKIMRegistry();
        acctRegistry = new MockAccountRegistry();
        factory = new MockUniversalFactory();
        executorMock = new MockExecutor();
        executorAddr = address(executorMock);

        zk = _deployInitProxy(bytes32(0), bytes32(0));
    }

    /*────────── Deploy helpers ──────────*/

    /// @dev Deploy an uninitialized ZkEmailInvites proxy.
    function _deployUninitProxy() internal returns (ZkEmailInvites zkp) {
        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        zkp = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
    }

    /// @dev Deploy + initialize a proxy with both mock verifiers and the given (root, cid).
    function _deployInitProxy(bytes32 root, bytes32 cid) internal returns (ZkEmailInvites zkp) {
        zkp = _deployUninitProxy();
        zkp.initialize(
            executorAddr,
            address(domainVerifier),
            address(emailVerifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            root,
            cid
        );
    }

    /*────────── Merkle helpers ──────────*/

    /// @dev OZ StandardMerkleTree leaf: double-keccak of abi.encode(kind, id, hatIds). Mirrors
    ///      `ZkEmailInvites._leaf`.
    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    /// @dev OZ MerkleProof pair-hash: keccak of the sorted 32-byte pair.
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _proofOf(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    /*────────── Fixture helpers ──────────*/

    function _hatIds(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _hatIds(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    /// @dev Builds a `ZkEmailProof`. The mock verifier ignores `pA/pB/pC`, so they stay zero; only
    ///      `pubkeyHash`, `emailNullifier`, and `fromDomainHash` carry meaning here. `fromDomainHash` is
    ///      the circuit-proven domain commitment used as BOTH the DKIM lookup key and the domain leaf id
    ///      — so it must equal the allowlisted domain id (DOMAIN_HASH).
    function _makeProof(bytes32 nullifier) internal view returns (ZkEmailProof memory p) {
        return _makeProof(nullifier, DOMAIN_HASH);
    }

    function _makeProof(bytes32 nullifier, bytes32 fromDomainHash) internal pure returns (ZkEmailProof memory p) {
        p.pubkeyHash = KEY_HASH;
        p.emailNullifier = nullifier;
        p.fromDomainHash = fromDomainHash;
    }

    function _makeProofV2(bytes32 nullifier, bytes32 emailHash) internal view returns (ZkEmailProofV2 memory p) {
        p.pubkeyHash = KEY_HASH;
        p.emailNullifier = nullifier;
        p.emailHash = emailHash;
        p.fromDomainHash = DOMAIN_HASH;
    }

    function _enroll() internal pure returns (ZkEmailInvites.PasskeyEnrollment memory e) {
        e.credentialId = bytes32(uint256(0x11));
        e.publicKeyX = bytes32(uint256(0x22));
        e.publicKeyY = bytes32(uint256(0x33));
        e.salt = 0;
    }

    function _emptyAuth() internal pure returns (WebAuthnLib.WebAuthnAuth memory a) {
        // zero-valued struct; mock registry doesn't verify
    }

    /// @dev Activate a single-leaf domain allowlist (root == the only leaf, empty merkle proofs).
    function _activateSingleDomain(uint256[] memory hatIds) internal returns (bytes32 root) {
        root = _leaf(LEAF_DOMAIN, DOMAIN_HASH, hatIds);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(root, CID);
    }

    /// @dev Activate a single-leaf email allowlist.
    function _activateSingleEmail(bytes32 emailHash, uint256[] memory hatIds) internal returns (bytes32 root) {
        root = _leaf(LEAF_EMAIL, emailHash, hatIds);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(root, CID);
    }

    /*────────── Storage slot guard ──────────*/

    /// @dev Confirms the contract reads/writes at `keccak256("poa.zkemailinvites.storage")` with
    ///      `executor` as field 0.
    function testStorageSlot_isExpected() public view {
        bytes32 slot = keccak256("poa.zkemailinvites.storage");
        bytes32 stored = vm.load(address(zk), slot);
        assertEq(address(uint160(uint256(stored))), executorAddr);
    }

    /*────────── Init guards ──────────*/

    function testCannotInitializeTwice() public {
        vm.expectRevert();
        zk.initialize(
            executorAddr,
            address(domainVerifier),
            address(emailVerifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            bytes32(0),
            bytes32(0)
        );
    }

    function testCannotInitializeImpl() public {
        ZkEmailInvites impl = new ZkEmailInvites();
        vm.expectRevert();
        impl.initialize(
            executorAddr,
            address(domainVerifier),
            address(emailVerifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            bytes32(0),
            bytes32(0)
        );
    }

    function testInitializeWiresVerifiersAndDeps() public view {
        assertEq(address(zk.executor()), executorAddr);
        assertEq(address(zk.domainVerifier()), address(domainVerifier));
        assertEq(address(zk.emailVerifier()), address(emailVerifier));
        assertEq(address(zk.dkimRegistry()), address(dkim));
        assertEq(address(zk.accountRegistry()), address(acctRegistry));
        assertEq(address(zk.universalFactory()), address(factory));
        // Dormant by default — no root.
        assertEq(zk.merkleRoot(), bytes32(0));
        assertEq(zk.allowlistCid(), bytes32(0));
    }

    function testInitializeWithRoot_setsActiveAllowlist() public {
        bytes32 root = bytes32(uint256(0xDEAD));
        ZkEmailInvites zkp = _deployInitProxy(root, CID);
        assertEq(zkp.merkleRoot(), root);
        assertEq(zkp.allowlistCid(), CID);
    }

    /*────────── setActiveAllowlist ──────────*/

    function testSetActiveAllowlist_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setActiveAllowlist(bytes32(uint256(1)), CID);
    }

    function testSetActiveAllowlist_storesAndEmits() public {
        bytes32 root = bytes32(uint256(0xABCDEF));
        vm.expectEmit(true, true, false, false);
        emit ActiveAllowlistSet(root, CID);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(root, CID);

        assertEq(zk.merkleRoot(), root);
        assertEq(zk.allowlistCid(), CID);
    }

    function testSetActiveAllowlist_canDormant() public {
        vm.prank(executorAddr);
        zk.setActiveAllowlist(bytes32(uint256(1)), CID);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(bytes32(0), bytes32(0));
        assertEq(zk.merkleRoot(), bytes32(0));
    }

    /*────────── Setter gating ──────────*/

    function testSetDomainVerifier_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setDomainVerifier(address(0xBEEF));
    }

    function testSetEmailVerifier_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setEmailVerifier(address(0xBEEF));
    }

    function testSetDKIMRegistry_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setDKIMRegistry(address(0xBEEF));
    }

    function testSetAccountRegistry_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setAccountRegistry(address(0xBEEF));
    }

    function testSetUniversalFactory_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setUniversalFactory(address(0xBEEF));
    }

    function testSetters_updateAddressesAndEmit() public {
        address newAddr = address(0xABCD);

        vm.expectEmit(true, false, false, false);
        emit DomainVerifierUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setDomainVerifier(newAddr);
        assertEq(address(zk.domainVerifier()), newAddr);

        vm.expectEmit(true, false, false, false);
        emit EmailVerifierUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setEmailVerifier(newAddr);
        assertEq(address(zk.emailVerifier()), newAddr);

        vm.expectEmit(true, false, false, false);
        emit DKIMRegistryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setDKIMRegistry(newAddr);
        assertEq(address(zk.dkimRegistry()), newAddr);

        vm.expectEmit(true, false, false, false);
        emit AccountRegistryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setAccountRegistry(newAddr);
        assertEq(address(zk.accountRegistry()), newAddr);

        vm.expectEmit(true, false, false, false);
        emit UniversalFactoryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setUniversalFactory(newAddr);
        assertEq(address(zk.universalFactory()), newAddr);
    }

    /*────────── Dormant module ──────────*/

    function testClaimRoleByDomain_dormantReverts() public {
        // No allowlist active → AllowlistNotActive.
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AllowlistNotActive.selector);
        zk.claimRoleByDomain(p, user, _hatIds(1), _emptyProof());
    }

    function testClaimRoleByEmail_dormantReverts() public {
        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AllowlistNotActive.selector);
        zk.claimRoleByEmail(p, user, _hatIds(1), _emptyProof());
    }

    /*────────── claimRoleByDomain ──────────*/

    function testClaimRoleByDomain_success() public {
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(0x1111)));

        vm.expectEmit(true, true, false, true);
        emit RoleClaimedByDomain(user, DOMAIN_HASH, hats, p.emailNullifier);

        vm.prank(user);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());

        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory mintedHats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(mintedHats.length, 1);
        assertEq(mintedHats[0], 42);
    }

    function testClaimRoleByDomain_multiHat() public {
        uint256[] memory hats = _hatIds(100, 200);
        _activateSingleDomain(hats);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());

        (address mintedTo, uint256[] memory minted) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(minted.length, 2);
        assertEq(minted[0], 100);
        assertEq(minted[1], 200);
    }

    function testClaimRoleByDomain_wrongDomainHashReverts() public {
        // Blocker 2: the domain identity is the circuit-proven `fromDomainHash`, used as BOTH the DKIM
        // key and the domain leaf id. A proof committing to a DIFFERENT domain than the allowlisted one
        // fails the merkle check (NotInAllowlist) — an attacker can't retarget the claim to another org's
        // domain. (Case-normalization is now in-circuit/off-chain, not an on-chain concern.)
        uint256[] memory hats = _hatIds(7);
        _activateSingleDomain(hats); // allowlists DOMAIN_HASH

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)), keccak256("evil.com"));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 0);
    }

    function testClaimRoleByDomain_permissionlessRelayer() public {
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        address relayer = address(0xBEEF);
        vm.prank(relayer);
        zk.claimRoleByDomain(p, user, hats, _emptyProof()); // relayer submits, user receives

        (address mintedTo,) = executorMock.mintAt(0);
        assertEq(mintedTo, user, "hat minted to bound claimer, not relayer");
    }

    /*────────── H-03 open-hat gate ──────────*/

    function testClaimRoleByDomain_revertOpenHat() public {
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        // Mark hat 42 open-to-everyone (eligibility module reports the sentinel eligible).
        executorMock.mockHats().setOpen(42, true);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("HatOpenlyClaimable(uint256)", uint256(42)));
        zk.claimRoleByDomain(p, user, hats, _emptyProof());

        // Reject happens before the state write: nothing minted, nullifier preserved.
        assertEq(executorMock.mintCount(), 0, "no mint on reject");
        assertFalse(zk.isNullifierUsed(p.emailNullifier), "nullifier preserved on reject");
    }

    function testClaimRoleByDomain_multiHat_revertIfAnyOpen() public {
        uint256[] memory hats = _hatIds(100, 200);
        _activateSingleDomain(hats);
        executorMock.mockHats().setOpen(200, true); // second hat is open → whole claim rejected

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("HatOpenlyClaimable(uint256)", uint256(200)));
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
    }

    function testClaimRoleByDomain_failsClosedWhenProbeReverts() public {
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        // A non-conforming / missing eligibility module makes isEligible revert → fail CLOSED (reject).
        executorMock.mockHats().setReverting(true);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("HatOpenlyClaimable(uint256)", uint256(42)));
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
    }

    function testClaimRoleByEmail_revertOpenHat() public {
        uint256[] memory hats = _hatIds(42);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);
        executorMock.mockHats().setOpen(42, true);

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("HatOpenlyClaimable(uint256)", uint256(42)));
        zk.claimRoleByEmail(p, user, hats, _emptyProof());
    }

    function testClaimRoleByDomain_gatedHatPasses() public {
        // Explicit positive control: a gated hat (probe → false, the default) sails through the gate.
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        assertFalse(executorMock.mockHats().openHat(42), "hat is gated by default");

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 1, "gated hat mints normally");
        assertTrue(executorMock.mockHats().emailVerified(42, user), "claim marked the claimer email-verified");
    }

    function testClaimRoleByDomain_revertWhenEligibilityUngrantable() public {
        // FAIL-CLOSED: if the hat's eligibility module cannot grant email-verified eligibility (e.g. a
        // pre-upgrade module without the third path), the claim must revert with a clear error — not
        // reach mintHat and revert cryptically there.
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        executorMock.mockHats().setBlockEmailVerify(true);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ZkEmailInvites.ClaimerNotEligible.selector, 42));
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 0, "nothing minted when eligibility cannot be granted");
    }

    function testClaimRoleByDomain_revertNotInAllowlist_wrongHats() public {
        // Activate for hats [42] but claim with hats [99] → leaf differs → not in allowlist.
        _activateSingleDomain(_hatIds(42));

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        zk.claimRoleByDomain(p, user, _hatIds(99), _emptyProof());
    }

    function testClaimRoleByDomain_revertNotInAllowlist_badProof() public {
        // 2-leaf tree [A, B]; claim leaf A but supply the WRONG sibling so the proof fails.
        uint256[] memory hatsA = _hatIds(1);
        bytes32 leafA = _leaf(LEAF_DOMAIN, DOMAIN_HASH, hatsA);
        bytes32 leafB = _leaf(LEAF_DOMAIN, keccak256(bytes("other.com")), _hatIds(2));
        bytes32 root = _pair(leafA, leafB);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(root, CID);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        // Wrong sibling (zero) → MerkleProof.verify fails.
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        zk.claimRoleByDomain(p, user, hatsA, _proofOf(bytes32(0)));
    }

    function testClaimRoleByDomain_twoLeafTree_validProofSucceeds() public {
        // 2-leaf tree [A, B]; claim leaf A with the correct sibling B.
        uint256[] memory hatsA = _hatIds(1);
        bytes32 leafA = _leaf(LEAF_DOMAIN, DOMAIN_HASH, hatsA);
        bytes32 leafB = _leaf(LEAF_DOMAIN, keccak256(bytes("other.com")), _hatIds(2));
        bytes32 root = _pair(leafA, leafB);
        vm.prank(executorAddr);
        zk.setActiveAllowlist(root, CID);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user, hatsA, _proofOf(leafB));
        assertEq(executorMock.mintCount(), 1);
    }

    function testClaimRoleByDomain_revertNullifierReuse() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());

        ZkEmailProof memory p2 = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        zk.claimRoleByDomain(p2, user, hats, _emptyProof());
    }

    function testClaimRoleByDomain_revertInvalidDKIM() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        dkim.setResult(false);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
    }

    function testClaimRoleByDomain_revertInvalidProof() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        domainVerifier.setResult(false);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        zk.claimRoleByDomain(p, user, hats, _emptyProof());
    }

    function testClaimRoleByDomain_revertZeroClaimer() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.expectRevert(ZkEmailInvites.ZeroClaimer.selector);
        zk.claimRoleByDomain(p, address(0), hats, _emptyProof());
    }

    function testClaimRoleByDomain_revertEmptyHats() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        uint256[] memory none = new uint256[](0);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.EmptyHats.selector);
        zk.claimRoleByDomain(p, user, none, _emptyProof());
    }

    /*────────── claimRoleByEmail ──────────*/

    function testClaimRoleByEmail_success() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(0x2222)), EMAIL_HASH_ALICE);

        vm.expectEmit(true, true, false, true);
        emit RoleClaimedByEmail(user, EMAIL_HASH_ALICE, hats, p.emailNullifier);

        vm.prank(user);
        zk.claimRoleByEmail(p, user, hats, _emptyProof());

        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory mintedHats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(mintedHats[0], 7);
    }

    function testClaimRoleByEmail_revertDuplicateRegistration_freshNullifier() public {
        // The core dedup: same ADDRESS (emailHash), brand-new email (fresh nullifier) must NOT
        // register twice — the per-message nullifier alone would have allowed this.
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        vm.prank(user);
        zk.claimRoleByEmail(_makeProofV2(bytes32(uint256(0x2222)), EMAIL_HASH_ALICE), user, hats, _emptyProof());
        assertTrue(zk.isEmailRegistered(EMAIL_HASH_ALICE));

        address secondAccount = makeAddr("second-account");
        ZkEmailProofV2 memory p2 = _makeProofV2(bytes32(uint256(0x3333)), EMAIL_HASH_ALICE); // fresh email
        vm.prank(secondAccount);
        vm.expectRevert(ZkEmailInvites.EmailAlreadyRegistered.selector);
        zk.claimRoleByEmail(p2, secondAccount, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 1, "second registration must not mint");
    }

    function testClearRegisteredEmail_reopensRegistration() public {
        // Lost-wallet recovery: governance clears the address, a NEW email re-registers to a NEW account.
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);
        vm.prank(user);
        zk.claimRoleByEmail(_makeProofV2(bytes32(uint256(0x2222)), EMAIL_HASH_ALICE), user, hats, _emptyProof());

        // onlyExecutor gate
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.clearRegisteredEmail(EMAIL_HASH_ALICE);

        vm.expectEmit(true, false, false, false);
        emit RegisteredEmailCleared(EMAIL_HASH_ALICE);
        vm.prank(address(executorMock));
        zk.clearRegisteredEmail(EMAIL_HASH_ALICE);
        assertFalse(zk.isEmailRegistered(EMAIL_HASH_ALICE));

        address recovered = makeAddr("recovered-account");
        vm.prank(recovered);
        zk.claimRoleByEmail(_makeProofV2(bytes32(uint256(0x4444)), EMAIL_HASH_ALICE), recovered, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 2, "recovery claim mints to the new account");
    }

    function testClaimRoleByDomain_unaffectedByEmailDedup() public {
        // Documented interim behavior: domain entries can still claim repeatedly with fresh emails
        // (the v1 proof exposes no address commitment) — dedup must not break the domain path.
        uint256[] memory hats = _hatIds(42);
        _activateSingleDomain(hats);
        vm.prank(user);
        zk.claimRoleByDomain(_makeProof(bytes32(uint256(0x1))), user, hats, _emptyProof());
        address second = makeAddr("second-domain-claimer");
        vm.prank(second);
        zk.claimRoleByDomain(_makeProof(bytes32(uint256(0x2))), second, hats, _emptyProof());
        assertEq(executorMock.mintCount(), 2);
    }

    function testClaimRoleByEmail_revertNotInAllowlist_wrongEmailHash() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        // Proof carries BOB's emailHash → leaf differs from the ALICE-keyed root.
        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_BOB);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NotInAllowlist.selector);
        zk.claimRoleByEmail(p, user, hats, _emptyProof());
    }

    function testClaimRoleByEmail_revertNullifierReuse() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        zk.claimRoleByEmail(p, user, hats, _emptyProof());

        ZkEmailProofV2 memory p2 = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        zk.claimRoleByEmail(p2, user, hats, _emptyProof());
    }

    function testClaimRoleByEmail_revertInvalidProof() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);
        emailVerifier.setResult(false);

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        zk.claimRoleByEmail(p, user, hats, _emptyProof());
    }

    function testClaimRoleByEmail_revertInvalidDKIM() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);
        dkim.setResult(false);

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        zk.claimRoleByEmail(p, user, hats, _emptyProof());
    }

    function testClaimRoleByEmail_revertZeroClaimer() public {
        uint256[] memory hats = _hatIds(7);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);
        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);
        vm.expectRevert(ZkEmailInvites.ZeroClaimer.selector);
        zk.claimRoleByEmail(p, address(0), hats, _emptyProof());
    }

    /*────────── Combined register + claim — domain ──────────*/

    function testRegisterAndClaimByDomainWithPasskey_success() public {
        uint256[] memory hats = _hatIds(11, 12);
        _activateSingleDomain(hats);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        address result = zk.registerAndClaimByDomainWithPasskey(
            passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p, hats, _emptyProof()
        );

        assertEq(result, expectedAccount);
        assertEq(acctRegistry.callCount(), 1);
        assertEq(acctRegistry.lastUsername(), "alice");
        assertEq(factory.callCount(), 1);
        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory minted) = executorMock.mintAt(0);
        assertEq(mintedTo, expectedAccount);
        assertEq(minted.length, 2);
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenFactoryUnset() public {
        vm.prank(executorAddr);
        zk.setUniversalFactory(address(0));

        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        vm.expectRevert(ZkEmailInvites.PasskeyFactoryNotSet.selector);
        zk.registerAndClaimByDomainWithPasskey(
            passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p, hats, _emptyProof()
        );
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenRegistryRejects() public {
        uint256[] memory hats = _hatIds(1);
        _activateSingleDomain(hats);
        acctRegistry.setShouldRevert(true);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        vm.expectRevert(); // bubbles "MockRegistry: rejected"
        zk.registerAndClaimByDomainWithPasskey(
            passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p, hats, _emptyProof()
        );

        assertEq(factory.callCount(), 0);
        assertEq(executorMock.mintCount(), 0);
        assertFalse(zk.isNullifierUsed(p.emailNullifier));
    }

    /*────────── Combined register + claim — email ──────────*/

    function testRegisterAndClaimByEmailWithPasskey_success() public {
        uint256[] memory hats = _hatIds(21);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));

        ZkEmailProofV2 memory p = _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE);

        address result = zk.registerAndClaimByEmailWithPasskey(
            passkey, "bob", block.timestamp + 1 hours, 0, _emptyAuth(), p, hats, _emptyProof()
        );

        assertEq(result, expectedAccount);
        assertEq(acctRegistry.callCount(), 1);
        assertEq(factory.callCount(), 1);
        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        (address mintedTo, uint256[] memory minted) = executorMock.mintAt(0);
        assertEq(mintedTo, expectedAccount);
        assertEq(minted[0], 21);
    }

    function testRegisterAndClaimByEmailWithPasskey_revertDuplicateRegistration() public {
        // The PRIMARY onboarding path must dedup too: same emailHash, a fresh email (fresh nullifier)
        // and a fresh passkey/account cannot register a second time.
        uint256[] memory hats = _hatIds(21);
        _activateSingleEmail(EMAIL_HASH_ALICE, hats);

        zk.registerAndClaimByEmailWithPasskey(
            _enroll(),
            "bob",
            block.timestamp + 1 hours,
            0,
            _emptyAuth(),
            _makeProofV2(bytes32(uint256(1)), EMAIL_HASH_ALICE),
            hats,
            _emptyProof()
        );
        assertTrue(zk.isEmailRegistered(EMAIL_HASH_ALICE));

        ZkEmailInvites.PasskeyEnrollment memory passkey2 = _enroll();
        passkey2.credentialId = bytes32(uint256(0xB0B2)); // different credential -> different account
        vm.expectRevert(ZkEmailInvites.EmailAlreadyRegistered.selector);
        zk.registerAndClaimByEmailWithPasskey(
            passkey2,
            "carol",
            block.timestamp + 1 hours,
            0,
            _emptyAuth(),
            _makeProofV2(bytes32(uint256(2)), EMAIL_HASH_ALICE),
            hats,
            _emptyProof()
        );
        assertEq(executorMock.mintCount(), 1, "duplicate one-step registration must not mint");
    }

    /*────────── Reentrancy ──────────*/

    function testReentrancy_isBlocked() public {
        // Spin up a fresh proxy whose executor is a malicious re-entrant minter.
        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        ZkEmailInvites attacker = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
        ReentrancyExecutor rx = new ReentrancyExecutor();
        attacker.initialize(
            address(rx),
            address(domainVerifier),
            address(emailVerifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            bytes32(0),
            bytes32(0)
        );

        uint256[] memory hats = _hatIds(1);
        bytes32 root = _leaf(LEAF_DOMAIN, DOMAIN_HASH, hats);
        vm.prank(address(rx));
        attacker.setActiveAllowlist(root, CID);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        rx.arm(attacker, p, user, hats, _emptyProof());

        vm.prank(user);
        vm.expectRevert(); // ReentrancyGuardUpgradeable: ReentrancyGuardReentrantCall
        attacker.claimRoleByDomain(p, user, hats, _emptyProof());
    }
}
