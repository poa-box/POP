// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ValidationLib} from "./libs/ValidationLib.sol";
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";

/* ─────────── Custom errors ─────────── */
error InvalidParam();
error OrgExists();
error OrgUnknown();
error TypeTaken();
error ContractUnknown();
error NotOrgExecutor();
error NotOrgMetadataAdmin();
error OwnerOnlyDuringBootstrap(); // deployer tried after bootstrap
error AutoUpgradeRequired(); // deployer must set autoUpgrade=true
error NotRegistryAdmin(); // neither the registry owner nor the PoaManager

/// @notice Minimal `owner()` view used to resolve the PoaManager from this proxy's beacon.
interface IBeaconOwner {
    function owner() external view returns (address);
}

/* ────────────────── Org Registry ────────────────── */
contract OrgRegistry is Initializable, OwnableUpgradeable {
    /* ───── Data structs ───── */
    struct ContractInfo {
        address proxy; // BeaconProxy address
        address beacon; // Beacon address
        bool autoUpgrade; // true ⇒ proxy follows beacon
        address owner; // module owner (immutable metadata)
    }

    struct OrgInfo {
        address executor; // DAO / governor / timelock that controls the org
        uint32 contractCount;
        bool bootstrap; // TRUE until the executor (or deployer via `lastRegister`)
        // finishes initial deployment. Afterwards the registry
        // owner can no longer add contracts.
        bool exists;
    }

    /**
     * @dev Struct for batch contract registration
     * @param typeId The module type identifier (keccak256 of module name)
     * @param proxy The BeaconProxy address
     * @param beacon The Beacon address
     * @param owner The module owner address
     */
    struct ContractRegistration {
        bytes32 typeId;
        address proxy;
        address beacon;
        address owner;
    }

    /*───────────── ERC-7201 Storage ───────────*/
    /// @custom:storage-location erc7201:poa.orgregistry.storage
    struct Layout {
        /* ───── Storage ───── */
        mapping(bytes32 => OrgInfo) orgOf; // orgId to OrgInfo
        mapping(bytes32 => ContractInfo) contractOf; // contractId to ContractInfo
        mapping(bytes32 => mapping(bytes32 => address)) proxyOf; // (orgId,typeId) to proxy
        mapping(bytes32 => uint256) topHatOf; // orgId to topHatId
        mapping(bytes32 => mapping(uint256 => uint256)) roleHatOf; // orgId => roleIndex => hatId
        bytes32[] orgIds;
        uint256 totalContracts;
        // Optional per-org metadata admin hat (if 0, falls back to topHat)
        mapping(bytes32 => uint256) metadataAdminHatOf;
        // Hats Protocol address for permission checks
        IHats hats;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.orgregistry.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /* ───── Events ───── */
    event OrgRegistered(bytes32 indexed orgId, address indexed executor, bytes name, bytes32 metadataHash);
    event MetaUpdated(bytes32 indexed orgId, bytes newName, bytes32 newMetadataHash);
    event ContractRegistered(
        bytes32 indexed contractId,
        bytes32 indexed orgId,
        bytes32 indexed typeId,
        address proxy,
        address beacon,
        bool autoUpgrade,
        address owner
    );
    event HatsTreeRegistered(bytes32 indexed orgId, uint256 topHatId, uint256[] roleHatIds);
    event OrgMetadataAdminHatSet(bytes32 indexed orgId, uint256 hatId);
    event HatsSet(address indexed hats);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract, replacing the constructor for upgradeable pattern
     * @param initialOwner The address that will own this registry
     * @param _hats The Hats Protocol contract address
     */
    function initialize(address initialOwner, address _hats) external initializer {
        if (initialOwner == address(0) || _hats == address(0)) revert InvalidParam();
        __Ownable_init(initialOwner);
        _layout().hats = IHats(_hats);
        emit HatsSet(_hats); // mirror {setHats} so indexers see the deploy-time pointer
    }

    /**
     * @dev Returns the Hats Protocol contract address
     */
    function getHats() external view returns (address) {
        return address(_layout().hats);
    }

    /**
     * @notice Repoint the registry's membership-read surface (Access v2 §5 / §6 step 0.5).
     * @dev The `hats` slot was previously written only at {initialize}. Access-v2 orgs carry a
     *      NEW-STYLE metadata-admin subject id (`uint160(authority) << 64 | seq`, always < 2^224),
     *      which real Hats Protocol resolves to balance 0 — so {updateOrgMetaAsAdmin} is dead for
     *      those orgs until this points at the chain's AuthorityRouter. The router passes legacy
     *      Hats ids straight through, so the repoint is behaviour-neutral for unmigrated orgs.
     *      Gated on the registry owner (the OrgDeployer, or the deployer EOA during genesis) OR the
     *      PoaManager, resolved as the owner of this proxy's beacon — that is the protocol upgrade
     *      authority reachable from `PoaManagerHub`/`PoaManagerSatellite.adminCall`. Mirrors
     *      `PaymasterHub.setHats`: zero-check + event.
     * @param newHats The new membership-read surface (the AuthorityRouter, or a Hats address for rollback).
     */
    function setHats(address newHats) external {
        if (newHats == address(0)) revert InvalidParam();
        if (msg.sender != owner() && msg.sender != _poaManager()) revert NotRegistryAdmin();
        _layout().hats = IHats(newHats);
        emit HatsSet(newHats);
    }

    /**
     * @dev The PoaManager for this deployment = the owner of this proxy's beacon. Returns
     *      address(0) when this instance is not behind a BeaconProxy, or when the beacon does not
     *      expose `owner()` — in which case only the registry owner can repoint.
     */
    function _poaManager() private view returns (address) {
        // ERC-1967 beacon slot: bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)
        bytes32 beaconSlot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        address beacon;
        assembly {
            beacon := sload(beaconSlot)
        }
        if (beacon == address(0)) return address(0);
        try IBeaconOwner(beacon).owner() returns (address beaconOwner) {
            return beaconOwner;
        } catch {
            return address(0);
        }
    }

    /* ═════════════════ ORG  LOGIC ═════════════════ */
    function registerOrg(bytes32 orgId, address executorAddr, bytes calldata name, bytes32 metadataHash)
        external
        onlyOwner
    {
        ValidationLib.requireValidTitle(name);
        if (orgId == bytes32(0) || executorAddr == address(0)) revert InvalidParam();

        Layout storage l = _layout();
        if (l.orgOf[orgId].exists) revert OrgExists();

        l.orgOf[orgId] = OrgInfo({
            executor: executorAddr,
            contractCount: 0,
            bootstrap: true, // owner can add modules while true
            exists: true
        });
        l.orgIds.push(orgId);
        emit OrgRegistered(orgId, executorAddr, name, metadataHash);
    }

    /**
     * @dev Creates an org in bootstrap mode without an executor (for deployment scenarios)
     * @param orgId The org identifier
     * @param name Name of the org (required, raw UTF-8)
     * @param metadataHash IPFS CID sha256 digest (optional, bytes32(0) is valid)
     */
    function createOrgBootstrap(bytes32 orgId, bytes calldata name, bytes32 metadataHash) external onlyOwner {
        ValidationLib.requireValidTitle(name);
        if (orgId == bytes32(0)) revert InvalidParam();

        Layout storage l = _layout();
        if (l.orgOf[orgId].exists) revert OrgExists();

        l.orgOf[orgId] = OrgInfo({
            executor: address(0), // no executor yet
            contractCount: 0,
            bootstrap: true, // in bootstrap mode
            exists: true
        });
        l.orgIds.push(orgId);
        emit OrgRegistered(orgId, address(0), name, metadataHash);
    }

    /**
     * @dev Sets the executor for an org (only during bootstrap)
     * @param orgId The org identifier
     * @param executorAddr The executor address
     */
    function setOrgExecutor(bytes32 orgId, address executorAddr) external onlyOwner {
        if (orgId == bytes32(0) || executorAddr == address(0)) revert InvalidParam();

        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();
        if (!o.bootstrap) revert OwnerOnlyDuringBootstrap();

        o.executor = executorAddr;
    }

    /**
     * @dev Updates org metadata (governance path - only executor)
     * @param orgId The organization ID
     * @param newName New organization name (bytes, validated by ValidationLib)
     * @param newMetadataHash New IPFS metadata hash (bytes32)
     */
    function updateOrgMeta(bytes32 orgId, bytes calldata newName, bytes32 newMetadataHash) external {
        ValidationLib.requireValidTitle(newName);
        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();
        if (msg.sender != o.executor) revert NotOrgExecutor();

        emit MetaUpdated(orgId, newName, newMetadataHash);
    }

    /**
     * @dev Allows a metadata admin hat wearer to update org metadata directly (no governance)
     * @param orgId The organization ID
     * @param newName New organization name (bytes, validated by ValidationLib)
     * @param newMetadataHash New IPFS metadata hash (bytes32)
     */
    function updateOrgMetaAsAdmin(bytes32 orgId, bytes calldata newName, bytes32 newMetadataHash) external {
        ValidationLib.requireValidTitle(newName);

        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();

        // Ensure hats protocol is configured
        IHats hats = l.hats;
        if (address(hats) == address(0)) revert InvalidParam();

        // Check if caller wears the org's metadata admin hat (optional, falls back to topHat)
        uint256 metadataAdminHat = l.metadataAdminHatOf[orgId];
        if (metadataAdminHat == 0) {
            metadataAdminHat = l.topHatOf[orgId];
        }
        if (metadataAdminHat == 0) revert NotOrgMetadataAdmin();

        if (!hats.isWearerOfHat(msg.sender, metadataAdminHat)) revert NotOrgMetadataAdmin();

        emit MetaUpdated(orgId, newName, newMetadataHash);
    }

    /**
     * @dev Set the metadata admin hat for an org
     *      During bootstrap: callable by registry owner (OrgDeployer)
     *      After bootstrap: callable by executor only (governance path)
     * @param orgId The organization ID
     * @param hatId The hat ID that can edit metadata directly (0 to use topHat as fallback)
     */
    function setOrgMetadataAdminHat(bytes32 orgId, uint256 hatId) external {
        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();

        bool callerIsOwner = (msg.sender == owner());
        bool callerIsExecutor = (o.executor != address(0) && msg.sender == o.executor);

        if (callerIsOwner) {
            if (!o.bootstrap) revert OwnerOnlyDuringBootstrap();
        } else if (!callerIsExecutor) {
            revert NotOrgExecutor();
        }

        l.metadataAdminHatOf[orgId] = hatId;
        emit OrgMetadataAdminHatSet(orgId, hatId);
    }

    /**
     * @dev Get the metadata admin hat for an org (returns 0 if not set, meaning topHat is used)
     */
    function getOrgMetadataAdminHat(bytes32 orgId) external view returns (uint256) {
        return _layout().metadataAdminHatOf[orgId];
    }

    /* ══════════ CONTRACT  REGISTRATION  ══════════ */
    /**
     *  ‑ During **bootstrap** (`o.bootstrap == true`) the registry owner _may_
     *    register contracts **if and only if `autoUpgrade == true`.**
     *  ‑ Pass `lastRegister = true` on the deployer's final call, or let the
     *    executor register at least once, to end the bootstrap phase.
     *
     *  @param lastRegister  set TRUE when this is the deployer's last module;
     *                       it flips `bootstrap` to false.
     */
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external {
        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();

        bool callerIsOwner = (msg.sender == owner());
        bool callerIsExecutor = (o.executor != address(0) && msg.sender == o.executor);

        if (callerIsOwner) {
            // owner path allowed only during bootstrap, _and_ must opt‑in to auto‑upgrade
            if (!o.bootstrap) revert OwnerOnlyDuringBootstrap();
            if (!autoUp) revert AutoUpgradeRequired();
        } else if (!callerIsExecutor) {
            revert NotOrgExecutor();
        }

        if (typeId == bytes32(0) || proxy == address(0) || beacon == address(0) || moduleOwner == address(0)) {
            revert InvalidParam();
        }
        if (l.proxyOf[orgId][typeId] != address(0)) revert TypeTaken();

        bytes32 contractId = keccak256(abi.encodePacked(orgId, typeId));

        l.contractOf[contractId] = ContractInfo({proxy: proxy, beacon: beacon, autoUpgrade: autoUp, owner: moduleOwner});
        l.proxyOf[orgId][typeId] = proxy;

        unchecked {
            ++o.contractCount;
            ++l.totalContracts;
        }
        emit ContractRegistered(contractId, orgId, typeId, proxy, beacon, autoUp, moduleOwner);

        // Finish bootstrap if executor registered OR deployer signalled completion
        if ((o.executor != address(0) && callerIsExecutor) || (callerIsOwner && lastRegister)) {
            o.bootstrap = false;
        }
    }

    /**
     * @notice Register multiple contracts in a single transaction (batch operation)
     * @dev Optimized for standard 10-contract deployments. Reduces gas by ~60-80k vs individual calls.
     * @param orgId The organization identifier
     * @param registrations Array of contracts to register
     * @param autoUpgrade Whether contracts auto-upgrade with their beacons
     * @param lastRegister Set true when this is the final batch; finalizes bootstrap phase
     */
    function batchRegisterOrgContracts(
        bytes32 orgId,
        ContractRegistration[] calldata registrations,
        bool autoUpgrade,
        bool lastRegister
    ) external {
        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];

        // Validation
        if (!o.exists) revert OrgUnknown();
        if (registrations.length == 0) revert InvalidParam();

        // Check caller permissions (same logic as single registration)
        bool callerIsOwner = (msg.sender == owner());
        bool callerIsExecutor = (o.executor != address(0) && msg.sender == o.executor);

        if (callerIsOwner) {
            // owner path allowed only during bootstrap, and must opt-in to auto-upgrade
            if (!o.bootstrap) revert OwnerOnlyDuringBootstrap();
            if (!autoUpgrade) revert AutoUpgradeRequired();
        } else if (!callerIsExecutor) {
            revert NotOrgExecutor();
        }

        // Batch register all contracts
        uint256 len = registrations.length;
        for (uint256 i = 0; i < len; i++) {
            ContractRegistration calldata reg = registrations[i];

            // Validate parameters
            if (
                reg.typeId == bytes32(0) || reg.proxy == address(0) || reg.beacon == address(0)
                    || reg.owner == address(0)
            ) {
                revert InvalidParam();
            }

            // Check not already registered
            if (l.proxyOf[orgId][reg.typeId] != address(0)) {
                revert TypeTaken();
            }

            // Store contract info
            bytes32 contractId = keccak256(abi.encodePacked(orgId, reg.typeId));
            l.contractOf[contractId] =
                ContractInfo({proxy: reg.proxy, beacon: reg.beacon, autoUpgrade: autoUpgrade, owner: reg.owner});
            l.proxyOf[orgId][reg.typeId] = reg.proxy;

            // Emit event for each contract
            emit ContractRegistered(contractId, orgId, reg.typeId, reg.proxy, reg.beacon, autoUpgrade, reg.owner);
        }

        // Update counts once at the end
        unchecked {
            o.contractCount += uint32(len);
            l.totalContracts += len;
        }

        // Finalize bootstrap if executor registered OR deployer signalled completion
        if ((o.executor != address(0) && callerIsExecutor) || (callerIsOwner && lastRegister)) {
            o.bootstrap = false;
        }
    }

    /* ═════════════════  VIEW HELPERS  ═════════════════ */
    function getOrgContract(bytes32 orgId, bytes32 typeId) external view returns (address proxy) {
        Layout storage l = _layout();
        if (!l.orgOf[orgId].exists) revert OrgUnknown();
        proxy = l.proxyOf[orgId][typeId];
        if (proxy == address(0)) revert ContractUnknown();
    }

    function getContractBeacon(bytes32 contractId) external view returns (address beacon) {
        Layout storage l = _layout();
        beacon = l.contractOf[contractId].beacon;
        if (beacon == address(0)) revert ContractUnknown();
    }

    function isAutoUpgrade(bytes32 contractId) external view returns (bool) {
        Layout storage l = _layout();
        ContractInfo storage c = l.contractOf[contractId];
        if (c.proxy == address(0)) revert ContractUnknown();
        return c.autoUpgrade;
    }

    /* enumeration helpers */
    function orgCount() external view returns (uint256) {
        return _layout().orgIds.length;
    }

    function getOrgIds() external view returns (bytes32[] memory) {
        return _layout().orgIds;
    }

    /* Public getters for storage variables */
    function orgOf(bytes32 orgId)
        external
        view
        returns (address executor, uint32 contractCount, bool bootstrap, bool exists)
    {
        OrgInfo storage o = _layout().orgOf[orgId];
        return (o.executor, o.contractCount, o.bootstrap, o.exists);
    }

    function contractOf(bytes32 contractId)
        external
        view
        returns (address proxy, address beacon, bool autoUpgrade, address owner)
    {
        ContractInfo storage c = _layout().contractOf[contractId];
        return (c.proxy, c.beacon, c.autoUpgrade, c.owner);
    }

    function proxyOf(bytes32 orgId, bytes32 typeId) external view returns (address) {
        return _layout().proxyOf[orgId][typeId];
    }

    function totalContracts() external view returns (uint256) {
        return _layout().totalContracts;
    }

    function orgIds(uint256 index) external view returns (bytes32) {
        return _layout().orgIds[index];
    }

    /* ══════════ HATS TREE REGISTRATION ══════════ */
    function registerHatsTree(bytes32 orgId, uint256 topHatId, uint256[] calldata roleHatIds) external {
        Layout storage l = _layout();
        OrgInfo storage o = l.orgOf[orgId];
        if (!o.exists) revert OrgUnknown();

        bool callerIsOwner = (msg.sender == owner());
        bool callerIsExecutor = (o.executor != address(0) && msg.sender == o.executor);

        if (callerIsOwner) {
            // owner path allowed only during bootstrap
            if (!o.bootstrap) revert OwnerOnlyDuringBootstrap();
        } else if (!callerIsExecutor) {
            revert NotOrgExecutor();
        }

        l.topHatOf[orgId] = topHatId;
        for (uint256 i = 0; i < roleHatIds.length; i++) {
            l.roleHatOf[orgId][i] = roleHatIds[i];
        }

        emit HatsTreeRegistered(orgId, topHatId, roleHatIds);
    }

    function getTopHat(bytes32 orgId) external view returns (uint256) {
        return _layout().topHatOf[orgId];
    }

    function getRoleHat(bytes32 orgId, uint256 roleIndex) external view returns (uint256) {
        return _layout().roleHatOf[orgId][roleIndex];
    }
}
