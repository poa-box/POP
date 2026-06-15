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
 */
contract PoaDKIMRegistry is IDKIMRegistry {
    /*────────────────────────────  Errors  ───────────────────────────────*/
    error NotOwner();
    error ZeroAddress();
    error LengthMismatch();

    /*────────────────────────────  Events  ───────────────────────────────*/
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KeyHashSet(bytes32 indexed domainHash, bytes32 indexed keyHash, bool valid);

    /*────────────────────────────  Storage  ──────────────────────────────*/
    /// @notice Address allowed to manage key hashes.
    address public owner;

    /// @dev domainHash => keyHash => valid
    mapping(bytes32 => mapping(bytes32 => bool)) private _valid;

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
        return _valid[domainHash][keyHash];
    }

    /*────────────────────────────  Admin writes  ──────────────────────────*/

    /// @notice Set (or clear) a DKIM key hash for a pre-hashed domain.
    /// @param domainHash keccak256 of the lowercase ASCII domain (use `domainHashOf`).
    function setKeyHash(bytes32 domainHash, bytes32 keyHash, bool valid) external onlyOwner {
        _valid[domainHash][keyHash] = valid;
        emit KeyHashSet(domainHash, keyHash, valid);
    }

    /// @notice Convenience: set (or clear) a key hash addressed by the raw domain string.
    /// @dev Hashes the domain identically to ZkEmailInvites (`keccak256(lower(domain))`).
    function setKeyForDomain(string calldata domain, bytes32 keyHash, bool valid) external onlyOwner {
        bytes32 domainHash = domainHashOf(domain);
        _valid[domainHash][keyHash] = valid;
        emit KeyHashSet(domainHash, keyHash, valid);
    }

    /// @notice Batch variant of `setKeyHash`. All entries set to the same `valid` flag.
    function setKeyHashes(bytes32[] calldata domainHashes, bytes32[] calldata keyHashes, bool valid)
        external
        onlyOwner
    {
        if (domainHashes.length != keyHashes.length) revert LengthMismatch();
        for (uint256 i; i < domainHashes.length; ++i) {
            _valid[domainHashes[i]][keyHashes[i]] = valid;
            emit KeyHashSet(domainHashes[i], keyHashes[i], valid);
        }
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
