// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import {IDKIMRegistry} from "./IDKIMRegistry.sol";

/**
 * @title PoaDKIMRegistry
 * @notice Owner-managed ERC-7969 DKIM public-key-hash allowlist consumed by ZkEmailInvites.
 * @dev    `ZkEmailInvites` checks `isKeyHashValid(keccak256(lower(domain)), proof.publicKeyHash)`
 *         before accepting any email proof. This registry is the trusted source of "which DKIM
 *         public keys are valid for which domains" — fabricating or misconfiguring an entry would
 *         let forged emails pass, so the setter is owner-gated and entries should mirror the keys
 *         published in each domain's DNS TXT records (the same hashes zk-email's own registries hold).
 *
 *         Non-upgradeable by design: if it must be replaced, deploy a fresh instance and repoint via
 *         `ZkEmailInvites.setDKIMRegistry` (governance). Domain hashing matches the module exactly
 *         (`domainHashOf`), so callers can seed by domain string without computing the hash off-chain.
 *
 *         Key lifecycle (rotation/staleness): each (domainHash, keyHash) carries an expiry.
 *         `0` = invalid (unset or revoked), `NO_EXPIRY` = valid until explicitly revoked, any other
 *         value = valid while `block.timestamp <= validUntil`. A key rotated out of a domain's DNS can
 *         thus be given a hard cut-off (or revoked immediately), so a leaked-but-retired key does not
 *         stay valid forever. The boolean setters map `true -> NO_EXPIRY`, `false -> revoked`, so
 *         existing callers keep working unchanged.
 */
contract PoaDKIMRegistry is IDKIMRegistry {
    /*────────────────────────────  Errors  ───────────────────────────────*/
    error NotOwner();
    error ZeroAddress();
    error LengthMismatch();
    error ExpiryInPast();

    /*────────────────────────────  Events  ───────────────────────────────*/
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev Emitted on every key state change. `valid` = "is (re)enabled" (false = revoked); `validUntil`
    ///      is the raw expiry stored (0 when revoked, NO_EXPIRY for permanent, else the cut-off unix ts).
    event KeyHashSet(bytes32 indexed domainHash, bytes32 indexed keyHash, bool valid, uint256 validUntil);
    event KeyHashRevoked(bytes32 indexed domainHash, bytes32 indexed keyHash);

    /*────────────────────────────  Constants  ─────────────────────────────*/
    /// @notice Expiry sentinel for a key that is valid until explicitly revoked (no time cut-off).
    uint256 public constant NO_EXPIRY = type(uint256).max;

    /*────────────────────────────  Storage  ──────────────────────────────*/
    /// @notice Address allowed to manage key hashes.
    address public owner;

    /// @dev domainHash => keyHash => validUntil (0 = invalid/revoked, NO_EXPIRY = permanent, else expiry ts)
    mapping(bytes32 => mapping(bytes32 => uint256)) private _validUntil;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /*────────────────────────────  ERC-7969 read  ─────────────────────────*/

    /// @inheritdoc IDKIMRegistry
    function isKeyHashValid(bytes32 domainHash, bytes32 keyHash) external view returns (bool) {
        uint256 exp = _validUntil[domainHash][keyHash];
        if (exp == 0) return false; // unset or revoked
        if (exp == NO_EXPIRY) return true; // permanent
        return block.timestamp <= exp; // time-bounded
    }

    /// @notice Raw stored expiry for a key: 0 (invalid/revoked), NO_EXPIRY (permanent), or a unix ts.
    /// @dev    Observability for operators (a nonzero, past ts distinguishes "expired" from "never set").
    function keyValidUntil(bytes32 domainHash, bytes32 keyHash) external view returns (uint256) {
        return _validUntil[domainHash][keyHash];
    }

    /*────────────────────────────  Admin writes  ──────────────────────────*/

    /// @notice Set (as permanent) or revoke a DKIM key hash for a pre-hashed domain.
    /// @dev    `valid == true` maps to NO_EXPIRY; `valid == false` revokes. For a hard expiry use
    ///         {setKeyHashWithExpiry}. `domainHash` = keccak256 of the lowercase ASCII domain (`domainHashOf`).
    function setKeyHash(bytes32 domainHash, bytes32 keyHash, bool valid) external onlyOwner {
        _set(domainHash, keyHash, valid ? NO_EXPIRY : 0);
    }

    /// @notice Set a DKIM key hash valid until `validUntil` (a future unix timestamp), for rotation.
    /// @dev    Pass NO_EXPIRY for permanent. To revoke, use {setKeyHash}(...,false) or {revokeKeyHash}.
    function setKeyHashWithExpiry(bytes32 domainHash, bytes32 keyHash, uint256 validUntil) external onlyOwner {
        if (validUntil != NO_EXPIRY && validUntil <= block.timestamp) revert ExpiryInPast();
        _set(domainHash, keyHash, validUntil);
    }

    /// @notice Convenience: set (permanent) or revoke a key addressed by the raw domain string.
    /// @dev Hashes the domain identically to ZkEmailInvites (`keccak256(lower(domain))`).
    function setKeyForDomain(string calldata domain, bytes32 keyHash, bool valid) external onlyOwner {
        _set(domainHashOf(domain), keyHash, valid ? NO_EXPIRY : 0);
    }

    /// @notice Convenience: set a key valid until `validUntil`, addressed by the raw domain string.
    function setKeyForDomainWithExpiry(string calldata domain, bytes32 keyHash, uint256 validUntil) external onlyOwner {
        if (validUntil != NO_EXPIRY && validUntil <= block.timestamp) revert ExpiryInPast();
        _set(domainHashOf(domain), keyHash, validUntil);
    }

    /// @notice Batch variant of `setKeyHash`. All entries set to the same `valid` flag (permanent/revoked).
    function setKeyHashes(bytes32[] calldata domainHashes, bytes32[] calldata keyHashes, bool valid)
        external
        onlyOwner
    {
        if (domainHashes.length != keyHashes.length) revert LengthMismatch();
        uint256 exp = valid ? NO_EXPIRY : 0;
        for (uint256 i; i < domainHashes.length; ++i) {
            _set(domainHashes[i], keyHashes[i], exp);
        }
    }

    /// @notice Immediately revoke a key hash (e.g. on key compromise / DNS rotation).
    function revokeKeyHash(bytes32 domainHash, bytes32 keyHash) external onlyOwner {
        _set(domainHash, keyHash, 0);
    }

    /// @notice Owner bulk-revoke — kill many keys in one tx (compromise response / mass rotation).
    function revokeKeyHashes(bytes32[] calldata domainHashes, bytes32[] calldata keyHashes) external onlyOwner {
        if (domainHashes.length != keyHashes.length) revert LengthMismatch();
        for (uint256 i; i < domainHashes.length; ++i) {
            _set(domainHashes[i], keyHashes[i], 0);
        }
    }

    /// @dev Single write path so every key state change emits consistent events.
    function _set(bytes32 domainHash, bytes32 keyHash, uint256 validUntil) private {
        _validUntil[domainHash][keyHash] = validUntil;
        emit KeyHashSet(domainHash, keyHash, validUntil != 0, validUntil);
        if (validUntil == 0) emit KeyHashRevoked(domainHash, keyHash);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*────────────────────────────  Helpers  ───────────────────────────────*/

    /// @notice Domain hash exactly as ZkEmailInvites computes it: keccak256 of the lowercased ASCII domain.
    function domainHashOf(string memory domain) public pure returns (bytes32) {
        bytes memory b = bytes(domain);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 32);
            }
        }
        return keccak256(b);
    }
}
