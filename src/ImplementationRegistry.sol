// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.17;

/*───────────────────  ImplementationRegistry  ───────────────────*/
import "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

contract ImplementationRegistry is Initializable, OwnableUpgradeable {
    /*──────────── Custom errors ───────────*/
    error EmptyString();
    error ImplZero();
    error VersionExists();
    error TypeUnknown();
    error VersionUnknown();

    /*──────────── Storage ────────────────*/
    struct Meta {
        bytes32[] versions; // ordered list of versionIds
        bytes32 latest; // latest versionId
        bool exists; // type exists flag
    }

    /*───────────── ERC-7201 Storage ───────────*/
    /// @custom:storage-location erc7201:poa.implementationregistry.storage
    struct Layout {
        //  typeId ⇒ (versionId ⇒ impl)
        mapping(bytes32 => mapping(bytes32 => address)) _impls;
        //  typeId ⇒ Meta
        mapping(bytes32 => Meta) _meta;
        // master list of typeIds for off‑chain iteration
        bytes32[] typeIds;
    }

    bytes32 private constant _STORAGE_SLOT = keccak256("poa.implementationregistry.storage");

    function _layout() private pure returns (Layout storage s) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /*──────────── Events ────────────────*/
    event ImplementationRegistered(
        bytes32 indexed typeId,
        string typeName,
        bytes32 indexed versionId,
        string version,
        address implementation,
        bool latest
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*───────── Initializer ─────────────*/
    function initialize(address owner) external initializer {
        __Ownable_init(owner);
    }

    /*───────── Internal utils ───────────*/
    function _id(string calldata s) internal pure returns (bytes32) {
        if (bytes(s).length == 0) revert EmptyString();
        return keccak256(bytes(s));
    }

    /*───────── External API ─────────────*/
    function registerImplementation(string calldata typeName, string calldata version, address impl, bool setLatest)
        external
        onlyOwner
    {
        if (impl == address(0)) revert ImplZero();

        Layout storage l = _layout();
        bytes32 tId = _id(typeName);
        bytes32 vId = _id(version);

        if (l._impls[tId][vId] != address(0)) revert VersionExists();

        // first time this type?
        bool firstForType = !l._meta[tId].exists;
        if (firstForType) {
            l._meta[tId].exists = true;
            l.typeIds.push(tId);
        }
        // store
        l._impls[tId][vId] = impl;
        l._meta[tId].versions.push(vId);

        // L-58: the very first version of a type MUST become `latest`, even if the caller
        // passed setLatest=false. Otherwise `latest` stays bytes32(0) and
        // getLatestImplementation reverts TypeUnknown despite a valid registered impl,
        // leaving the type unresolvable-by-latest until an explicit setLatestVersion call.
        bool becameLatest = setLatest || firstForType;
        if (becameLatest) l._meta[tId].latest = vId;

        emit ImplementationRegistered(tId, typeName, vId, version, impl, becameLatest);
    }

    function setLatestVersion(string calldata typeName, string calldata version) external onlyOwner {
        Layout storage l = _layout();
        bytes32 tId = _id(typeName);
        bytes32 vId = _id(version);

        if (l._impls[tId][vId] == address(0)) revert VersionUnknown();
        l._meta[tId].latest = vId;
    }

    /*──────── View helpers ────────*/
    function getLatestImplementation(string calldata typeName) external view returns (address) {
        Layout storage l = _layout();
        bytes32 tId = _id(typeName);
        bytes32 vId = l._meta[tId].latest;
        if (vId == bytes32(0)) revert TypeUnknown();
        return l._impls[tId][vId];
    }

    function getImplementation(string calldata typeName, string calldata version) external view returns (address) {
        Layout storage l = _layout();
        bytes32 tId = _id(typeName);
        bytes32 vId = _id(version);
        address impl = l._impls[tId][vId];
        if (impl == address(0)) revert VersionUnknown();
        return impl;
    }

    function getVersionCount(string calldata typeName) external view returns (uint256) {
        return _layout()._meta[_id(typeName)].versions.length;
    }

    function getVersionIdAt(string calldata typeName, uint256 index) external view returns (bytes32) {
        Layout storage l = _layout();
        Meta storage m = l._meta[_id(typeName)];
        if (index >= m.versions.length) revert VersionUnknown();
        return m.versions[index];
    }

    function typeCount() external view returns (uint256) {
        return _layout().typeIds.length;
    }

    /// @notice Public getter for typeIds
    function typeIds(uint256 index) external view returns (bytes32) {
        return _layout().typeIds[index];
    }
}
