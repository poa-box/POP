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
import {IZkEmailGroth16Verifier, ZkEmailProof} from "../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../src/zkemail/IDKIMRegistry.sol";
import {WebAuthnLib} from "../src/libs/WebAuthnLib.sol";

/*──────────────────────────────  Mocks  ──────────────────────────────*/

/// @notice Stand-in for the snarkjs `Groth16Verifier`. Ignores the proof points entirely and
///         returns a settable `result` (default true) so tests can toggle proof validity.
contract MockZkEmailVerifier is IZkEmailGroth16Verifier {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[3] calldata)
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
    bool public attempted;

    function arm(ZkEmailInvites _zk, ZkEmailProof memory p, address _claimer) external {
        zk = _zk;
        _proof = p;
        claimer = _claimer;
    }

    function mintHatsForUser(address, uint256[] calldata) external {
        if (attempted) return;
        attempted = true;
        // Recurse — should be blocked by nonReentrant
        zk.claimRoleByDomain(_proof, claimer);
    }
}

/*──────────────────────────────  Tests  ──────────────────────────────*/

contract ZkEmailInvitesTest is Test {
    ZkEmailInvites zk;
    MockZkEmailVerifier verifier;
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

    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event DomainRuleSet(bytes32 indexed domainHash, uint256[] hatIds, uint64 expiry);
    event DomainRuleRemoved(bytes32 indexed domainHash);
    event EmailRuleSet(bytes32 indexed emailHash, uint256[] hatIds, uint64 expiry);
    event EmailRuleRemoved(bytes32 indexed emailHash);
    event VerifierUpdated(address indexed verifier);
    event DKIMRegistryUpdated(address indexed registry);
    event AccountRegistryUpdated(address indexed registry);
    event UniversalFactoryUpdated(address indexed factory);

    function setUp() public {
        verifier = new MockZkEmailVerifier();
        dkim = new MockDKIMRegistry();
        acctRegistry = new MockAccountRegistry();
        factory = new MockUniversalFactory();
        executorMock = new MockExecutor();
        executorAddr = address(executorMock);

        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        zk = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));

        zk.initialize(
            executorAddr,
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _noDomainRules(),
            _noEmailRules()
        );
    }

    /*────────── Helpers ──────────*/

    function _hatIds(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _hatIds(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    /// @dev Builds a `ZkEmailProof`. The mock verifier ignores `pA/pB/pC`, so they stay zero;
    ///      only `pubkeyHash`, `emailNullifier`, and `domainName` carry meaning. The claimer is
    ///      NOT in the struct — it is bound by being public-signal[2] of the proof, which the mock
    ///      ignores, so any `claimer` arg succeeds against the (default-true) mock.
    function _makeProof(bytes32 nullifier) internal view returns (ZkEmailProof memory p) {
        return _makeProof(nullifier, DOMAIN);
    }

    function _makeProof(bytes32 nullifier, string memory domain) internal pure returns (ZkEmailProof memory p) {
        p.pubkeyHash = KEY_HASH;
        p.emailNullifier = nullifier;
        p.domainName = domain;
        // pA / pB / pC left as zeros — the mock verifier ignores them.
    }

    function _setDomain(uint256[] memory ids, uint64 expiry) internal {
        vm.prank(executorAddr);
        zk.setDomainRule(DOMAIN, ids, expiry);
    }

    function _setEmail(bytes32 emailHash, uint256[] memory ids, uint64 expiry) internal {
        vm.prank(executorAddr);
        zk.setEmailRule(emailHash, ids, expiry);
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

    function _noDomainRules() internal pure returns (ZkEmailInvites.InitDomainRule[] memory) {
        return new ZkEmailInvites.InitDomainRule[](0);
    }

    function _noEmailRules() internal pure returns (ZkEmailInvites.InitEmailRule[] memory) {
        return new ZkEmailInvites.InitEmailRule[](0);
    }

    /// @dev Deploy an uninitialized ZkEmailInvites proxy (so initialize can be called/tested directly).
    function _deployUninitProxy() internal returns (ZkEmailInvites zkp) {
        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        zkp = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
    }

    /// @dev Deploy a fresh ZkEmailInvites proxy initialized with the given deploy-time rules.
    function _freshProxyWithRules(
        ZkEmailInvites.InitDomainRule[] memory dRules,
        ZkEmailInvites.InitEmailRule[] memory eRules
    ) internal returns (ZkEmailInvites zkp) {
        zkp = _deployUninitProxy();
        zkp.initialize(
            executorAddr, address(verifier), address(dkim), address(acctRegistry), address(factory), dRules, eRules
        );
    }

    function _oneDomainRule(string memory domain, uint256[] memory hatIds, uint64 expiry)
        internal
        pure
        returns (ZkEmailInvites.InitDomainRule[] memory r)
    {
        r = new ZkEmailInvites.InitDomainRule[](1);
        r[0] = ZkEmailInvites.InitDomainRule({domain: domain, hatIds: hatIds, expiry: expiry});
    }

    function _oneEmailRule(bytes32 emailHash, uint256[] memory hatIds, uint64 expiry)
        internal
        pure
        returns (ZkEmailInvites.InitEmailRule[] memory r)
    {
        r = new ZkEmailInvites.InitEmailRule[](1);
        r[0] = ZkEmailInvites.InitEmailRule({emailHash: emailHash, hatIds: hatIds, expiry: expiry});
    }

    /*────────── Storage slot guard ──────────*/

    /// @dev Confirms that the contract reads/writes at `keccak256("poa.zkemailinvites.storage")`.
    ///      `executor` is the first field of `Layout` — if anyone reorders the struct or renames
    ///      the slot string, this test catches it before it ships.
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
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _noDomainRules(),
            _noEmailRules()
        );
    }

    function testCannotInitializeImpl() public {
        ZkEmailInvites impl = new ZkEmailInvites();
        vm.expectRevert();
        impl.initialize(
            executorAddr,
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _noDomainRules(),
            _noEmailRules()
        );
    }

    /*────────── Deploy-time rules (initialize with rules) ──────────*/

    function testInitializeWithDomainRule_immediatelyClaimable() public {
        // A proxy initialized with a domain rule is claimable with NO follow-up governance call.
        ZkEmailInvites zkp = _freshProxyWithRules(_oneDomainRule(DOMAIN, _hatIds(42), 0), _noEmailRules());

        (uint256[] memory hatIds, uint64 expiry, bool exists) = zkp.getDomainRule(DOMAIN_HASH);
        assertTrue(exists, "rule preloaded at init");
        assertEq(expiry, 0);
        assertEq(hatIds.length, 1);
        assertEq(hatIds[0], 42);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zkp.claimRoleByDomain(p, user);

        assertEq(executorMock.mintCount(), 1, "claim works immediately after deploy");
        (address mintedTo, uint256[] memory minted) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(minted[0], 42);
    }

    /// @dev Email rules can be PRE-LOADED at init (admin scaffolding) but are NOT claimable in v1.
    function testInitializeWithEmailRule_setButNotClaimable() public {
        ZkEmailInvites zkp = _freshProxyWithRules(_noDomainRules(), _oneEmailRule(EMAIL_HASH_ALICE, _hatIds(7), 0));

        (uint256[] memory hatIds, uint64 expiry, bool exists, bool claimed) = zkp.getEmailRule(EMAIL_HASH_ALICE);
        assertTrue(exists, "email rule preloaded");
        assertFalse(claimed);
        assertEq(expiry, 0);
        assertEq(hatIds.length, 1);
        assertEq(hatIds[0], 7);
    }

    function testInitializeWithBothRuleTypes() public {
        ZkEmailInvites.InitDomainRule[] memory d = _oneDomainRule(DOMAIN, _hatIds(1), 0);
        ZkEmailInvites.InitEmailRule[] memory e = _oneEmailRule(EMAIL_HASH_BOB, _hatIds(2), 0);
        ZkEmailInvites zkp = _freshProxyWithRules(d, e);

        (,, bool dExists) = zkp.getDomainRule(DOMAIN_HASH);
        (,, bool eExists,) = zkp.getEmailRule(EMAIL_HASH_BOB);
        assertTrue(dExists && eExists, "both rule types preloaded");
    }

    function testInitializeWithMultiHatDomainRule() public {
        ZkEmailInvites zkp = _freshProxyWithRules(_oneDomainRule(DOMAIN, _hatIds(11, 22), 0), _noEmailRules());
        (uint256[] memory hatIds,,) = zkp.getDomainRule(DOMAIN_HASH);
        assertEq(hatIds.length, 2);
        assertEq(hatIds[0], 11);
        assertEq(hatIds[1], 22);
    }

    function testInitializeWithNoRules_nothingClaimable() public {
        ZkEmailInvites zkp = _freshProxyWithRules(_noDomainRules(), _noEmailRules());
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zkp.claimRoleByDomain(p, user);
    }

    function testInitializeRevertsOnEmptyDomainInRule() public {
        ZkEmailInvites zkp = _deployUninitProxy();
        vm.expectRevert(ZkEmailInvites.EmptyDomain.selector);
        zkp.initialize(
            executorAddr,
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _oneDomainRule("", _hatIds(1), 0),
            _noEmailRules()
        );
    }

    function testInitializeRevertsOnEmptyHatsInRule() public {
        uint256[] memory empty = new uint256[](0);
        ZkEmailInvites zkp = _deployUninitProxy();
        vm.expectRevert(ZkEmailInvites.EmptyHats.selector);
        zkp.initialize(
            executorAddr,
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _oneDomainRule(DOMAIN, empty, 0),
            _noEmailRules()
        );
    }

    function testInitializeRevertsOnEmptyHatsInEmailRule() public {
        uint256[] memory empty = new uint256[](0);
        ZkEmailInvites zkp = _deployUninitProxy();
        vm.expectRevert(ZkEmailInvites.EmptyHats.selector);
        zkp.initialize(
            executorAddr,
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _noDomainRules(),
            _oneEmailRule(EMAIL_HASH_ALICE, empty, 0)
        );
    }

    /*────────── Admin gating ──────────*/

    function testSetDomainRule_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setDomainRule(DOMAIN, _hatIds(1), 0);
    }

    function testSetEmailRule_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setEmailRule(EMAIL_HASH_ALICE, _hatIds(1), 0);
    }

    function testSetVerifier_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setVerifier(address(0xBEEF));
    }

    function testSetDKIMRegistry_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setDKIMRegistry(address(0xBEEF));
    }

    function testSetDomainRule_emptyHatsReverts() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(executorAddr);
        vm.expectRevert(ZkEmailInvites.EmptyHats.selector);
        zk.setDomainRule(DOMAIN, none, 0);
    }

    function testSetDomainRule_emptyDomainReverts() public {
        vm.prank(executorAddr);
        vm.expectRevert(ZkEmailInvites.EmptyDomain.selector);
        zk.setDomainRule("", _hatIds(1), 0);
    }

    function testSetEmailRule_emptyHatsReverts() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(executorAddr);
        vm.expectRevert(ZkEmailInvites.EmptyHats.selector);
        zk.setEmailRule(EMAIL_HASH_ALICE, none, 0);
    }

    /*────────── Admin: email-rule set/get/remove (no claim path in v1) ──────────*/

    function testSetEmailRule_storesAndEmits() public {
        uint256[] memory ids = _hatIds(7, 8);
        vm.expectEmit(true, false, false, true);
        emit EmailRuleSet(EMAIL_HASH_ALICE, ids, uint64(0));
        vm.prank(executorAddr);
        zk.setEmailRule(EMAIL_HASH_ALICE, ids, 0);

        (uint256[] memory hatIds, uint64 expiry, bool exists, bool claimed) = zk.getEmailRule(EMAIL_HASH_ALICE);
        assertTrue(exists, "rule stored");
        assertFalse(claimed, "never claimed (no claim path in v1)");
        assertEq(expiry, 0);
        assertEq(hatIds.length, 2);
        assertEq(hatIds[0], 7);
        assertEq(hatIds[1], 8);
    }

    function testGetEmailRule_unsetReturnsEmpty() public view {
        (uint256[] memory hatIds, uint64 expiry, bool exists, bool claimed) = zk.getEmailRule(EMAIL_HASH_BOB);
        assertEq(hatIds.length, 0);
        assertEq(expiry, 0);
        assertFalse(exists);
        assertFalse(claimed);
    }

    function testRemoveEmailRule() public {
        _setEmail(EMAIL_HASH_ALICE, _hatIds(1), 0);
        (,, bool existsBefore,) = zk.getEmailRule(EMAIL_HASH_ALICE);
        assertTrue(existsBefore);

        vm.expectEmit(true, false, false, false);
        emit EmailRuleRemoved(EMAIL_HASH_ALICE);
        vm.prank(executorAddr);
        zk.removeEmailRule(EMAIL_HASH_ALICE);

        (,, bool existsAfter,) = zk.getEmailRule(EMAIL_HASH_ALICE);
        assertFalse(existsAfter, "rule removed");
    }

    function testRemoveDomainRule() public {
        _setDomain(_hatIds(1), 0);
        vm.expectEmit(true, false, false, false);
        emit DomainRuleRemoved(DOMAIN_HASH);
        vm.prank(executorAddr);
        zk.removeDomainRule(DOMAIN);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testSetters_updateAddressesAndEmit() public {
        address newAddr = address(0xABCD);

        vm.expectEmit(true, false, false, false);
        emit VerifierUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setVerifier(newAddr);

        vm.expectEmit(true, false, false, false);
        emit DKIMRegistryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setDKIMRegistry(newAddr);

        vm.expectEmit(true, false, false, false);
        emit AccountRegistryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setAccountRegistry(newAddr);

        vm.expectEmit(true, false, false, false);
        emit UniversalFactoryUpdated(newAddr);
        vm.prank(executorAddr);
        zk.setUniversalFactory(newAddr);
    }

    function testVerifierGetter_reflectsType() public view {
        assertEq(address(zk.verifier()), address(verifier));
    }

    /*────────── claimRoleByDomain ──────────*/

    function testClaimRoleByDomain_success() public {
        _setDomain(_hatIds(42), 0);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(0x1111)));

        uint256[] memory expectedHats = _hatIds(42);
        vm.expectEmit(true, true, false, true);
        emit RoleClaimedByDomain(user, DOMAIN_HASH, expectedHats, p.emailNullifier);

        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory mintedHats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(mintedHats.length, 1);
        assertEq(mintedHats[0], 42);
    }

    function testClaimRoleByDomain_revertOnUnknownDomain() public {
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnExpiredRule() public {
        _setDomain(_hatIds(1), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.RuleExpired.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnNullifierReuse() public {
        _setDomain(_hatIds(1), 0);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        // Same nullifier in a fresh proof — second attempt blocks at the nullifier check.
        ZkEmailProof memory p2 = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        zk.claimRoleByDomain(p2, user);
    }

    function testClaimRoleByDomain_revertOnInvalidDKIM() public {
        _setDomain(_hatIds(1), 0);
        dkim.setResult(false);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnInvalidProof() public {
        _setDomain(_hatIds(1), 0);
        verifier.setResult(false);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_normalizesCase() public {
        // Domain rule registered with mixed case; proof reports lowercase — should match.
        vm.prank(executorAddr);
        zk.setDomainRule("ANTHROPIC.com", _hatIds(7), 0);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user);
        assertEq(executorMock.mintCount(), 1);
    }

    function testClaimRoleByDomain_revertOnZeroClaimer() public {
        _setDomain(_hatIds(1), 0);
        // Explicit ZeroClaimer guard fires before any proof work.
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.expectRevert(ZkEmailInvites.ZeroClaimer.selector);
        zk.claimRoleByDomain(p, address(0));
    }

    function testClaimRoleByDomain_permissionless() public {
        // Anyone may submit a proof on behalf of the address it's bound to (signal[2]).
        // The relayer pays gas; the bound `claimer` receives the hat.
        _setDomain(_hatIds(42), 0);
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        address relayer = address(0xBEEF);
        vm.prank(relayer);
        zk.claimRoleByDomain(p, user); // relayer submits, user receives

        (address mintedTo,) = executorMock.mintAt(0);
        assertEq(mintedTo, user, "hat minted to bound claimer, not relayer");
    }

    function testClaimRoleByDomain_multiHatRule() public {
        _setDomain(_hatIds(100, 200), 0);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        (address mintedTo, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(hats.length, 2, "both hats minted in one call");
        assertEq(hats[0], 100);
        assertEq(hats[1], 200);
    }

    function testClaimRoleByDomain_differentNullifiersBothClaim() public {
        // Two distinct emails (distinct nullifiers) under the same domain both mint — the only
        // replay guard in v1 is the nullifier, not a per-claimer / per-email flag.
        _setDomain(_hatIds(1), 0);

        ZkEmailProof memory p1 = _makeProof(bytes32(uint256(0xAAA)));
        vm.prank(user);
        zk.claimRoleByDomain(p1, user);

        ZkEmailProof memory p2 = _makeProof(bytes32(uint256(0xBBB)));
        vm.prank(user);
        zk.claimRoleByDomain(p2, user);

        assertEq(executorMock.mintCount(), 2, "distinct nullifiers each claim");
    }

    function testOverwriteDomainRule_replacesHats() public {
        _setDomain(_hatIds(1), 0);
        vm.prank(executorAddr);
        zk.setDomainRule(DOMAIN, _hatIds(99), 0);

        // A claim under the same domain gets the NEW hat list.
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        (, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(hats.length, 1);
        assertEq(hats[0], 99, "new rule hat applied");
    }

    /*────────── Combined register + claim — domain ──────────*/

    function testRegisterAndClaimByDomainWithPasskey_success() public {
        _setDomain(_hatIds(11, 12), 0);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        address result =
            zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        assertEq(result, expectedAccount);
        assertEq(acctRegistry.callCount(), 1);
        assertEq(acctRegistry.lastUsername(), "alice");
        assertEq(factory.callCount(), 1);
        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(mintedTo, expectedAccount);
        assertEq(hats.length, 2);
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenFactoryUnset() public {
        // Unbind the factory.
        vm.prank(executorAddr);
        zk.setUniversalFactory(address(0));

        _setDomain(_hatIds(1), 0);
        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        vm.expectRevert(ZkEmailInvites.PasskeyFactoryNotSet.selector);
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenRegistryRejectsSig() public {
        _setDomain(_hatIds(1), 0);
        acctRegistry.setShouldRevert(true);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        vm.expectRevert(); // bubbles "MockRegistry: rejected"
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        // Nothing should have happened post-revert.
        assertEq(factory.callCount(), 0);
        assertEq(executorMock.mintCount(), 0);
        assertFalse(zk.isNullifierUsed(p.emailNullifier));
    }

    function testRegisterAndClaimByDomainWithPasskey_revertOnUnknownDomain() public {
        // No domain rule set — register+create succeed but the claim hits DomainNotAllowed, so the
        // whole tx reverts atomically (no mint).
        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));

        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        assertEq(executorMock.mintCount(), 0);
    }

    /*────────── Reentrancy ──────────*/

    function testReentrancy_isBlocked() public {
        // Re-init zk with a malicious executor that calls back in.
        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        ZkEmailInvites attacker = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
        ReentrancyExecutor rx = new ReentrancyExecutor();
        attacker.initialize(
            address(rx),
            address(verifier),
            address(dkim),
            address(acctRegistry),
            address(factory),
            _noDomainRules(),
            _noEmailRules()
        );

        uint256[] memory ids = _hatIds(1);
        vm.prank(address(rx));
        attacker.setDomainRule(DOMAIN, ids, 0);

        ZkEmailProof memory p = _makeProof(bytes32(uint256(1)));
        rx.arm(attacker, p, user);

        vm.prank(user);
        vm.expectRevert(); // ReentrancyGuardUpgradeable: ReentrancyGuardReentrantCall
        attacker.claimRoleByDomain(p, user);
    }
}
