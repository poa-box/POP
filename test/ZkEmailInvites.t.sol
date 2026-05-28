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
import {EmailProof, IVerifier} from "../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../src/zkemail/IDKIMRegistry.sol";
import {CommandUtils} from "../src/zkemail/CommandUtils.sol";
import {WebAuthnLib} from "../src/libs/WebAuthnLib.sol";

/*──────────────────────────────  Mocks  ──────────────────────────────*/

contract MockVerifier is IVerifier {
    bool public result = true;

    function setResult(bool v) external {
        result = v;
    }

    function commandBytes() external pure returns (uint256) {
        return 605;
    }

    function verifyEmailProof(EmailProof memory) external view returns (bool) {
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

/// @notice External wrapper so vm.expectRevert can catch CommandUtils library reverts.
contract CommandUtilsTester {
    function extract(string calldata cmd) external pure returns (address) {
        return CommandUtils.extractTrailingEthAddr(cmd);
    }
}

/// @notice Reentrancy probe — wired as a malicious executor that calls back into ZkEmailInvites.
contract ReentrancyExecutor is IExecutorHatMinter {
    ZkEmailInvites public zk;
    EmailProof public proof;
    address public claimer;
    bool public attempted;

    function arm(ZkEmailInvites _zk, EmailProof memory _proof, address _claimer) external {
        zk = _zk;
        proof = _proof;
        claimer = _claimer;
    }

    function mintHatsForUser(address, uint256[] calldata) external {
        if (attempted) return;
        attempted = true;
        // Recurse — should be blocked by nonReentrant
        zk.claimRoleByDomain(proof, claimer);
    }
}

/*──────────────────────────────  Tests  ──────────────────────────────*/

contract ZkEmailInvitesTest is Test {
    ZkEmailInvites zk;
    MockVerifier verifier;
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
    bytes32 constant SALT_ALICE = bytes32(uint256(0xA11CE));
    bytes32 constant SALT_BOB = bytes32(uint256(0xB0B));

    event RoleClaimedByDomain(address indexed claimer, bytes32 indexed domainHash, uint256[] hatIds, bytes32 nullifier);
    event RoleClaimedByEmail(address indexed claimer, bytes32 indexed accountSalt, uint256[] hatIds, bytes32 nullifier);
    event DomainRuleSet(bytes32 indexed domainHash, uint256[] hatIds, uint64 expiry);
    event DomainRuleRemoved(bytes32 indexed domainHash);
    event EmailRuleSet(bytes32 indexed accountSalt, uint256[] hatIds, uint64 expiry);
    event EmailRuleRemoved(bytes32 indexed accountSalt);
    event VerifierUpdated(address indexed verifier);
    event DKIMRegistryUpdated(address indexed registry);
    event AccountRegistryUpdated(address indexed registry);
    event UniversalFactoryUpdated(address indexed factory);

    function setUp() public {
        verifier = new MockVerifier();
        dkim = new MockDKIMRegistry();
        acctRegistry = new MockAccountRegistry();
        factory = new MockUniversalFactory();
        executorMock = new MockExecutor();
        executorAddr = address(executorMock);

        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        zk = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));

        zk.initialize(executorAddr, address(verifier), address(dkim), address(acctRegistry), address(factory));
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

    function _addrToHexLower(address a) internal pure returns (string memory out) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint256 v = uint256(uint160(a));
        for (uint256 i = 0; i < 40; ++i) {
            s[41 - i] = alphabet[v & 0xf];
            v >>= 4;
        }
        out = string(s);
    }

    function _makeProof(bytes32 accountSalt, bytes32 nullifier, address forClaimer)
        internal
        view
        returns (EmailProof memory p)
    {
        p.domainName = DOMAIN;
        p.publicKeyHash = KEY_HASH;
        p.timestamp = block.timestamp;
        p.maskedCommand = string.concat("Claim POP role for ", _addrToHexLower(forClaimer));
        p.emailNullifier = nullifier;
        p.accountSalt = accountSalt;
        p.isCodeExist = true;
        p.proof = hex"deadbeef";
    }

    function _setDomain(uint256[] memory ids, uint64 expiry) internal {
        vm.prank(executorAddr);
        zk.setDomainRule(DOMAIN, ids, expiry);
    }

    function _setEmail(bytes32 salt, uint256[] memory ids, uint64 expiry) internal {
        vm.prank(executorAddr);
        zk.setEmailRule(salt, ids, expiry);
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
        zk.initialize(executorAddr, address(verifier), address(dkim), address(acctRegistry), address(factory));
    }

    function testCannotInitializeImpl() public {
        ZkEmailInvites impl = new ZkEmailInvites();
        vm.expectRevert();
        impl.initialize(executorAddr, address(verifier), address(dkim), address(acctRegistry), address(factory));
    }

    /*────────── Admin gating ──────────*/

    function testSetDomainRule_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setDomainRule(DOMAIN, _hatIds(1), 0);
    }

    function testSetEmailRule_onlyExecutor() public {
        vm.expectRevert(ZkEmailInvites.Unauthorized.selector);
        zk.setEmailRule(SALT_ALICE, _hatIds(1), 0);
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
        zk.setEmailRule(SALT_ALICE, none, 0);
    }

    function testRemoveDomainRule() public {
        _setDomain(_hatIds(1), 0);
        vm.expectEmit(true, false, false, false);
        emit DomainRuleRemoved(DOMAIN_HASH);
        vm.prank(executorAddr);
        zk.removeDomainRule(DOMAIN);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testRemoveEmailRule() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        vm.expectEmit(true, false, false, false);
        emit EmailRuleRemoved(SALT_ALICE);
        vm.prank(executorAddr);
        zk.removeEmailRule(SALT_ALICE);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.EmailNotAllowed.selector);
        zk.claimRoleByEmail(p, user);
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

    /*────────── Bare claim — domain rule ──────────*/

    function testClaimRoleByDomain_success() public {
        _setDomain(_hatIds(42), 0);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(0x1111)), user);

        uint256[] memory expectedHats = _hatIds(42);
        vm.expectEmit(true, true, false, true);
        emit RoleClaimedByDomain(user, DOMAIN_HASH, expectedHats, p.emailNullifier);

        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        assertTrue(zk.isNullifierUsed(p.emailNullifier));
        assertTrue(zk.hasEmailClaimedDomain(SALT_ALICE, DOMAIN_HASH));
        assertEq(executorMock.mintCount(), 1);
        (address mintedTo, uint256[] memory mintedHats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(mintedHats.length, 1);
        assertEq(mintedHats[0], 42);
    }

    function testClaimRoleByDomain_revertOnUnknownDomain() public {
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.DomainNotAllowed.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnExpiredRule() public {
        _setDomain(_hatIds(1), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.RuleExpired.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnNullifierReuse() public {
        _setDomain(_hatIds(1), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        // Same nullifier in a fresh proof — second attempt blocks at the nullifier check.
        EmailProof memory p2 = _makeProof(SALT_BOB, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.NullifierAlreadyUsed.selector);
        zk.claimRoleByDomain(p2, user);
    }

    function testClaimRoleByDomain_revertOnAddressMismatch() public {
        _setDomain(_hatIds(1), 0);
        // maskedCommand encodes `user`, but the claim is for a different address.
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        address other = address(0xDEAD);
        vm.prank(other);
        vm.expectRevert(ZkEmailInvites.AddressMismatch.selector);
        zk.claimRoleByDomain(p, other);
    }

    function testClaimRoleByDomain_revertOnInvalidDKIM() public {
        _setDomain(_hatIds(1), 0);
        dkim.setResult(false);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidDKIMKey.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnInvalidProof() public {
        _setDomain(_hatIds(1), 0);
        verifier.setResult(false);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        zk.claimRoleByDomain(p, user);
    }

    function testClaimRoleByDomain_revertOnDoubleClaim() public {
        _setDomain(_hatIds(1), 0);
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p1, user);

        // Same accountSalt, same domain, different nullifier — should hit AlreadyClaimed.
        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AlreadyClaimed.selector);
        zk.claimRoleByDomain(p2, user);
    }

    function testClaimRoleByDomain_sameSaltDifferentDomain() public {
        _setDomain(_hatIds(1), 0);

        // Register a second domain for the same accountSalt
        string memory altDomain = "example.org";
        bytes32 altHash = keccak256(bytes(altDomain));
        vm.prank(executorAddr);
        zk.setDomainRule(altDomain, _hatIds(2), 0);

        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p1, user);

        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), user);
        p2.domainName = altDomain;
        vm.prank(user);
        zk.claimRoleByDomain(p2, user);

        assertTrue(zk.hasEmailClaimedDomain(SALT_ALICE, DOMAIN_HASH));
        assertTrue(zk.hasEmailClaimedDomain(SALT_ALICE, altHash));
        assertEq(executorMock.mintCount(), 2);
    }

    function testClaimRoleByDomain_normalizesCase() public {
        // Domain rule registered with mixed case; proof reports lowercase — should match.
        vm.prank(executorAddr);
        zk.setDomainRule("ANTHROPIC.com", _hatIds(7), 0);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p, user);
        assertEq(executorMock.mintCount(), 1);
    }

    function testClaimRoleByDomain_revertOnZeroClaimer() public {
        _setDomain(_hatIds(1), 0);
        // Even if maskedCommand encodes address(0), explicit ZeroClaimer guard fires first.
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), address(0));
        vm.expectRevert(ZkEmailInvites.ZeroClaimer.selector);
        zk.claimRoleByDomain(p, address(0));
    }

    function testClaimRoleByDomain_permissionless() public {
        // Anyone may submit a proof on behalf of the address it's bound to.
        // The relayer pays gas; the bound `claimer` receives the hat.
        _setDomain(_hatIds(42), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);

        address relayer = address(0xBEEF);
        vm.prank(relayer);
        zk.claimRoleByDomain(p, user); // relayer submits, user receives

        (address mintedTo,) = executorMock.mintAt(0);
        assertEq(mintedTo, user, "hat minted to bound claimer, not relayer");
    }

    function testClaimRoleByDomain_multiHatRule() public {
        _setDomain(_hatIds(100, 200), 0);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        (address mintedTo, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(mintedTo, user);
        assertEq(hats.length, 2, "both hats minted in one call");
        assertEq(hats[0], 100);
        assertEq(hats[1], 200);
    }

    /// @dev Documents the per-domain rule limitation: same email + different accountCode
    ///      yields a different accountSalt, bypassing the `claimedByDomain[salt][domain]` guard.
    ///      This is intrinsic to using the standard zk-email circuit's `accountSalt` (which
    ///      depends on user-chosen accountCode). Mitigation = per-email rules or a custom circuit.
    function testClaimRoleByDomain_accountSaltRotation_documentedLimit() public {
        _setDomain(_hatIds(1), 0);

        // First proof: accountSalt = SALT_ALICE (Poseidon(alice@x, code1))
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(0xAAA)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p1, user);

        // Same email, different accountCode → different accountSalt. Contract has no way
        // to tell it's the same email, so it allows the second claim.
        bytes32 rotatedSalt = bytes32(uint256(0xA11CE2));
        EmailProof memory p2 = _makeProof(rotatedSalt, bytes32(uint256(0xBBB)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p2, user);

        assertEq(executorMock.mintCount(), 2, "limitation: same email under rotated salt re-claims");
    }

    function testReSetDomainRule_preservesClaimedByDomain() public {
        _setDomain(_hatIds(1), 0);
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p1, user);
        assertEq(executorMock.mintCount(), 1);

        // Admin re-issues the rule (same domain, new hat list).
        vm.prank(executorAddr);
        zk.setDomainRule(DOMAIN, _hatIds(99), 0);

        // Same email, fresh proof under that domain → still blocked by claimedByDomain.
        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AlreadyClaimed.selector);
        zk.claimRoleByDomain(p2, user);
    }

    function testOverwriteDomainRule_replacesHats_forFreshSalt() public {
        _setDomain(_hatIds(1), 0);
        vm.prank(executorAddr);
        zk.setDomainRule(DOMAIN, _hatIds(99), 0);

        // A different email under the same domain gets the NEW hat list.
        EmailProof memory p = _makeProof(SALT_BOB, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByDomain(p, user);

        (, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(hats.length, 1);
        assertEq(hats[0], 99, "new rule hat applied");
    }

    /*────────── Bare claim — email rule ──────────*/

    function testClaimRoleByEmail_success() public {
        _setEmail(SALT_ALICE, _hatIds(99), 0);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(0xABCD)), user);

        uint256[] memory expectedHats = _hatIds(99);
        vm.expectEmit(true, true, false, true);
        emit RoleClaimedByEmail(user, SALT_ALICE, expectedHats, p.emailNullifier);

        vm.prank(user);
        zk.claimRoleByEmail(p, user);

        (,,, bool claimed) = zk.getEmailRule(SALT_ALICE);
        assertTrue(claimed);
        assertEq(executorMock.mintCount(), 1);
    }

    function testClaimRoleByEmail_revertOnUnknownEmail() public {
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.EmailNotAllowed.selector);
        zk.claimRoleByEmail(p, user);
    }

    function testClaimRoleByEmail_oneShot() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByEmail(p1, user);

        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AlreadyClaimed.selector);
        zk.claimRoleByEmail(p2, user);
    }

    function testClaimRoleByEmail_revertOnAddressMismatch() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        address other = address(0xBEEF);
        vm.prank(other);
        vm.expectRevert(ZkEmailInvites.AddressMismatch.selector);
        zk.claimRoleByEmail(p, other);
    }

    function testClaimRoleByEmail_revertOnExpiredRule() public {
        _setEmail(SALT_ALICE, _hatIds(1), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.RuleExpired.selector);
        zk.claimRoleByEmail(p, user);
    }

    function testClaimRoleByEmail_multiHatRule() public {
        _setEmail(SALT_ALICE, _hatIds(10, 20), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByEmail(p, user);

        (, uint256[] memory hats) = executorMock.mintAt(0);
        assertEq(hats.length, 2, "both hats minted");
    }

    function testReSetEmailRule_resetsClaimedFlag() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        vm.prank(user);
        zk.claimRoleByEmail(p1, user);

        (,,, bool claimed) = zk.getEmailRule(SALT_ALICE);
        assertTrue(claimed, "first claim sets flag");

        // Admin re-issues the invitation with a different hat — the documented re-claim semantic.
        vm.prank(executorAddr);
        zk.setEmailRule(SALT_ALICE, _hatIds(99), 0);

        (,,, claimed) = zk.getEmailRule(SALT_ALICE);
        assertFalse(claimed, "re-set clears claimed flag");

        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), user);
        vm.prank(user);
        zk.claimRoleByEmail(p2, user);

        assertEq(executorMock.mintCount(), 2, "re-issued rule is claimable");
        (, uint256[] memory hats) = executorMock.mintAt(1);
        assertEq(hats[0], 99, "second claim mints the new hat");
    }

    function testClaimRoleByEmail_revertOnZeroClaimer() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), address(0));
        vm.expectRevert(ZkEmailInvites.ZeroClaimer.selector);
        zk.claimRoleByEmail(p, address(0));
    }

    /*────────── Combined register + claim — domain ──────────*/

    function testRegisterAndClaimByDomainWithPasskey_success() public {
        _setDomain(_hatIds(11, 12), 0);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), expectedAccount);

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
        // Reinitialize the contract without the factory bound.
        vm.prank(executorAddr);
        zk.setUniversalFactory(address(0));

        _setDomain(_hatIds(1), 0);
        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);

        vm.expectRevert(ZkEmailInvites.PasskeyFactoryNotSet.selector);
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenRegistryRejectsSig() public {
        _setDomain(_hatIds(1), 0);
        acctRegistry.setShouldRevert(true);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);

        vm.expectRevert(); // bubbles "MockRegistry: rejected"
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        // Nothing should have happened post-revert.
        assertEq(factory.callCount(), 0);
        assertEq(executorMock.mintCount(), 0);
        assertFalse(zk.isNullifierUsed(p.emailNullifier));
    }

    function testRegisterAndClaimByDomainWithPasskey_revertOnAddressMismatch() public {
        _setDomain(_hatIds(1), 0);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        // proof encodes a different address than the one the factory will derive
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), address(0xDEAD));

        vm.expectRevert(ZkEmailInvites.AddressMismatch.selector);
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        // The username got registered + the account got created, but the email proof bound to
        // the wrong address so the whole tx reverts — atomic.
        // (callCount values pre-revert are not observable post-revert; just assert no mint.)
        assertEq(executorMock.mintCount(), 0);
    }

    /*────────── Combined register + claim — email ──────────*/

    function testRegisterAndClaimByEmailWithPasskey_success() public {
        _setEmail(SALT_ALICE, _hatIds(7), 0);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), expectedAccount);

        address result =
            zk.registerAndClaimByEmailWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);

        assertEq(result, expectedAccount);
        (,,, bool claimed) = zk.getEmailRule(SALT_ALICE);
        assertTrue(claimed);
        assertEq(executorMock.mintCount(), 1);
    }

    function testRegisterAndClaimByEmailWithPasskey_oneShot() public {
        _setEmail(SALT_ALICE, _hatIds(7), 0);

        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));
        EmailProof memory p1 = _makeProof(SALT_ALICE, bytes32(uint256(1)), expectedAccount);
        zk.registerAndClaimByEmailWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p1);

        EmailProof memory p2 = _makeProof(SALT_ALICE, bytes32(uint256(2)), expectedAccount);
        vm.expectRevert(ZkEmailInvites.AlreadyClaimed.selector);
        zk.registerAndClaimByEmailWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p2);
    }

    /*────────── Account-code requirement (isCodeExist) ──────────*/

    function testClaimRoleByDomain_revertWhenCodeNotEmbedded() public {
        _setDomain(_hatIds(1), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        p.isCodeExist = false;
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AccountCodeMissing.selector);
        zk.claimRoleByDomain(p, user);
        // Nullifier must NOT have been consumed (whole tx reverted).
        assertFalse(zk.isNullifierUsed(p.emailNullifier), "nullifier untouched on revert");
    }

    function testClaimRoleByEmail_revertWhenCodeNotEmbedded() public {
        _setEmail(SALT_ALICE, _hatIds(1), 0);
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        p.isCodeExist = false;
        vm.prank(user);
        vm.expectRevert(ZkEmailInvites.AccountCodeMissing.selector);
        zk.claimRoleByEmail(p, user);

        (,,, bool claimed) = zk.getEmailRule(SALT_ALICE);
        assertFalse(claimed, "email rule not consumed on revert");
    }

    function testRegisterAndClaimByDomainWithPasskey_revertWhenCodeNotEmbedded() public {
        _setDomain(_hatIds(1), 0);
        ZkEmailInvites.PasskeyEnrollment memory passkey = _enroll();
        address expectedAccount = address(uint160(uint256(keccak256(abi.encode("acct", passkey.credentialId)))));
        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), expectedAccount);
        p.isCodeExist = false;
        vm.expectRevert(ZkEmailInvites.AccountCodeMissing.selector);
        zk.registerAndClaimByDomainWithPasskey(passkey, "alice", block.timestamp + 1 hours, 0, _emptyAuth(), p);
        assertEq(executorMock.mintCount(), 0, "no hats minted on revert");
    }

    /*────────── Reentrancy ──────────*/

    function testReentrancy_isBlocked() public {
        // Re-init zk with a malicious executor that calls back in.
        ZkEmailInvites impl = new ZkEmailInvites();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        ZkEmailInvites attacker = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));
        ReentrancyExecutor rx = new ReentrancyExecutor();
        attacker.initialize(address(rx), address(verifier), address(dkim), address(acctRegistry), address(factory));

        uint256[] memory ids = _hatIds(1);
        vm.prank(address(rx));
        attacker.setDomainRule(DOMAIN, ids, 0);

        EmailProof memory p = _makeProof(SALT_ALICE, bytes32(uint256(1)), user);
        rx.arm(attacker, p, user);

        vm.prank(user);
        vm.expectRevert(); // ReentrancyGuardUpgradeable: ReentrancyGuardReentrantCall
        attacker.claimRoleByDomain(p, user);
    }

    /*────────── CommandUtils sanity ──────────*/

    function testCommandUtils_extractTrailingEthAddr_lowercase() public pure {
        address a = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        string memory cmd = string.concat("hello ", _addrToHexLower2(a));
        assertEq(CommandUtils.extractTrailingEthAddr(cmd), a);
    }

    function testCommandUtils_extractTrailingEthAddr_short_reverts() public {
        CommandUtilsTester tester = new CommandUtilsTester();
        vm.expectRevert(CommandUtils.InvalidCommand.selector);
        tester.extract("0xtooshort");
    }

    function testCommandUtils_extractTrailingEthAddr_badPrefix_reverts() public {
        CommandUtilsTester tester = new CommandUtilsTester();
        // 42-char string but doesn't start with "0x"
        vm.expectRevert(CommandUtils.InvalidCommand.selector);
        tester.extract("xx1234567890abcdef1234567890abcdef12345678");
    }

    function testCommandUtils_extractTrailingEthAddr_badHexInMiddle_reverts() public {
        CommandUtilsTester tester = new CommandUtilsTester();
        // 42-char "0x..." string with a 'g' (invalid hex digit) in the middle
        vm.expectRevert(CommandUtils.InvalidCommand.selector);
        tester.extract("0x1234567890abcdef1234567890gbcdef12345678");
    }

    function testCommandUtils_extractTrailingEthAddr_acceptsUppercaseAndUppercasePrefix() public {
        // The address itself is upper-case hex and the prefix is "0X" — both legal.
        // (Literal prepended with 00 so solc doesn't try to checksum-validate it.)
        address expected = address(uint160(0x001234567890ABCDEF1234567890ABCDEF12345678));
        CommandUtilsTester tester = new CommandUtilsTester();
        // 0X + 40 upper-case hex chars
        assertEq(tester.extract("hello 0X1234567890ABCDEF1234567890ABCDEF12345678"), expected);
    }

    function testCommandUtils_extractTrailingEthAddr_allF() public {
        CommandUtilsTester tester = new CommandUtilsTester();
        assertEq(
            tester.extract("prefix 0xffffffffffffffffffffffffffffffffffffffff"), address(uint160(type(uint160).max))
        );
    }

    // duplicate helper as a `pure` variant for use inside pure tests
    function _addrToHexLower2(address a) internal pure returns (string memory out) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint256 v = uint256(uint160(a));
        for (uint256 i = 0; i < 40; ++i) {
            s[41 - i] = alphabet[v & 0xf];
            v >>= 4;
        }
        out = string(s);
    }
}
