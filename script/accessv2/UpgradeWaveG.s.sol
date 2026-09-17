// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DirectDemocracyVoting} from "../../src/DirectDemocracyVoting.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";
import {TaskManager} from "../../src/TaskManager.sol";
import {ParticipationToken} from "../../src/ParticipationToken.sol";
import {EducationHub} from "../../src/EducationHub.sol";
import {QuickJoin} from "../../src/QuickJoin.sol";
import {Executor} from "../../src/Executor.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {MembershipAuthority} from "../../src/MembershipAuthority.sol";
import {AuthorityRouter} from "../../src/AuthorityRouter.sol";
import {ImplementationRegistry} from "../../src/ImplementationRegistry.sol";
import {GovernanceFactory} from "../../src/factories/GovernanceFactory.sol";
import {AccessFactory} from "../../src/factories/AccessFactory.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {DefaultGlobalRules} from "../helpers/DefaultGlobalRules.sol";
import {ModuleTypes} from "../../src/libs/ModuleTypes.sol";
import {RoleConfigStructs} from "../../src/libs/RoleConfigStructs.sol";
import {IHybridVotingInit} from "../../src/libs/ModuleDeploymentLib.sol";
import {AccessV2PermKeys} from "../../src/libs/AccessV2PermKeys.sol";

interface IWaveGManager {
    function owner() external view returns (address);
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
    function registry() external view returns (address);
}

interface IWaveGAdmin {
    function owner() external view returns (address);
    function poaManager() external view returns (address);
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address implementation, string calldata version) external;
    function upgradeBeaconLocal(string calldata typeName, address implementation, string calldata version) external;
}

interface IWaveGPaymaster {
    // Deployed ABI field order is gas hint, then allowed.
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }
    function HATS() external view returns (address);
    function getGlobalRule(bytes32 typeId, bytes4 selector) external view returns (Rule memory);
    function setGlobalRulesBatch(bytes32[] calldata, bytes4[] calldata, bool[] calldata, uint32[] calldata) external;
}

/// @notice Wave G retires unmigrated V1 modules without deleting any organization or history.
/// @dev Eight fresh implementations, three fresh non-proxy factories, and eleven global rule
///      tombstones. Every chain uses the same _ceremony in simulation and broadcast. There is no
///      migration, authority reset, router rebinding, or subgraph change in this ceremony.
///
/// Production simulations (no broadcast):
/// FOUNDRY_PROFILE=production forge script script/accessv2/UpgradeWaveG.s.sol:SimGnosis --fork-url gnosis-gateway -vvv
/// FOUNDRY_PROFILE=production forge script script/accessv2/UpgradeWaveG.s.sol:SimArbitrum --fork-url arbitrum -vvv
///
/// BroadcastGnosis / BroadcastArbitrum are explicit, separate entry points for a later authorized
/// release. They require PRIVATE_KEY resolving to HUDSON. Do not use --broadcast on simulation
/// entry points. Versions must still be free on BOTH registry and CREATE3 surfaces at release time.
abstract contract WaveGBase is Script {
    error CheckFailed(string check, address target);
    error ReadFailed(address target, bytes data, bytes reason);
    error VersionOccupied(string typeName, string version);
    error Create3Occupied(string typeName, string version, address target);
    error UnexpectedRegistryResponse(bytes reason);
    error HistoryChanged(bytes32 orgId);
    error UnexpectedAuthority(bytes32 orgId, address actual, address expected);
    error HistoryScanLimit(address target);

    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant CREATE3 = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    bytes32 internal constant TEST6 = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    bytes32 internal constant DP = 0x3721271eb827a52a5adf676136d302efe19c34e72f08e080b07b225eecf27d78;
    bytes32 internal constant KANSAS = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
    bytes32 internal constant POA = 0xa71879ef0e38b15fe7080196c0102f859e0ca8e7b8c0703ec8df03c66befd069;

    struct ChainConfig {
        address admin;
        address manager;
        address implementations;
        OrgRegistry organizations;
        address paymaster;
        bool gnosis;
    }

    struct Snapshot {
        bytes32 orgId;
        address authority;
        bytes32 digest;
    }

    struct Deployment {
        address[8] implementations;
        address governance;
        address access;
        address modules;
    }

    function _chain(bool gnosis) internal view returns (ChainConfig memory c) {
        _check(block.chainid == (gnosis ? 100 : 42161), "chain id", address(0));
        if (gnosis) {
            c = ChainConfig(
                0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06,
                0x794fD39e75140ee1545B1B022E5486B7c863789b,
                0x72c16812aE2a6819F4d0D9E432A3818712fa5c63,
                OrgRegistry(0x3744b372abc41589226313F2bB1dB3aCAa22A854),
                0xdEf1038C297493c0b5f82F0CDB49e929B53B4108,
                true
            );
        } else {
            c = ChainConfig(
                0xB72840B343654eAfb2CFf7acC4Fc6b59E6c3CC71,
                0xFF585Fae4A944cD173B19158C6FC5E08980b0815,
                0x5e5F4269ef727FFDE6A62509C27A7C6c0D39dBB9,
                OrgRegistry(0x7B023B9566b96616D54935AE8De80579c93f62aC),
                0xD6659bCaFAdCB9CC2F57B7aE923c7F1Ca4438a11,
                false
            );
        }
    }

    function _check(bool condition, string memory label, address target) internal pure {
        if (!condition) revert CheckFailed(label, target);
    }

    function _names() internal pure returns (string[8] memory) {
        return [
            "DirectDemocracyVoting",
            "HybridVoting",
            "TaskManager",
            "ParticipationToken",
            "EducationHub",
            "QuickJoin",
            "Executor",
            "OrgDeployer"
        ];
    }

    function _versions() internal pure returns (string[8] memory) {
        return ["v14", "v14", "v9", "v9", "v5", "v10", "v6", "v21"];
    }

    function _expectedAuthority(bytes32 orgId) internal pure returns (address) {
        if (orgId == TEST6) return 0x11A6A93Ca42Ae9C9f74af492362D1D7a8B2B0449;
        if (orgId == DP) return 0xFAa657f9efcd6E663D067a0D1E84567958201fe0;
        if (orgId == KANSAS) return 0x340FA3b15b4F66734200C56C78dE7eeC240C462B;
        if (orgId == POA) return 0x348584d47327502e23a372fEA32aAAe9d8D0B55D;
        return address(0);
    }

    function _assertOwners(ChainConfig memory c) internal view {
        _check(IWaveGAdmin(c.admin).owner() == HUDSON, "admin owner", c.admin);
        _check(DeterministicDeployer(CREATE3).owner() == HUDSON, "CREATE3 owner", CREATE3);
        _check(IWaveGAdmin(c.admin).poaManager() == c.manager, "admin manager", c.admin);
        _check(IWaveGManager(c.manager).owner() == c.admin, "manager owner", c.manager);
        _check(IWaveGManager(c.manager).registry() == c.implementations, "implementation registry", c.manager);
        address deployer = c.organizations.owner();
        _check(deployer.code.length != 0, "OrgRegistry owner is deployer", deployer);
        bytes32 beaconSlot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        _check(
            address(uint160(uint256(vm.load(deployer, beaconSlot))))
                == IWaveGManager(c.manager).getBeaconById(keccak256("OrgDeployer")),
            "OrgDeployer beacon",
            deployer
        );
        address router = c.organizations.getHats();
        _check(IWaveGPaymaster(c.paymaster).HATS() == router, "shared router", c.paymaster);
        _check(AuthorityRouter(router).orgRegistry() == address(c.organizations), "router registry", router);
        _check(AuthorityRouter(router).paymasterHub() == c.paymaster, "router paymaster", router);
    }

    function _assertFree(ChainConfig memory c) internal view {
        string[8] memory names = _names();
        string[8] memory versions = _versions();
        for (uint256 i; i < names.length; ++i) {
            (bool ok, bytes memory reason) = c.implementations
                .staticcall(abi.encodeCall(ImplementationRegistry.getImplementation, (names[i], versions[i])));
            if (ok) revert VersionOccupied(names[i], versions[i]);
            if (reason.length != 4 || bytes4(reason) != ImplementationRegistry.VersionUnknown.selector) {
                revert UnexpectedRegistryResponse(reason);
            }
            _assertCreate3Free(names[i], versions[i]);
        }
        _assertCreate3Free("GovernanceFactory", "wave-g-v1");
        _assertCreate3Free("AccessFactory", "wave-g-v1");
        _assertCreate3Free("ModulesFactory", "wave-g-v1");
    }

    function _assertCreate3Free(string memory name, string memory version) internal view {
        address predicted =
            DeterministicDeployer(CREATE3).computeAddress(DeterministicDeployer(CREATE3).computeSalt(name, version));
        if (predicted.code.length != 0) revert Create3Occupied(name, version, predicted);
    }

    function _deploy(string memory name, string memory version, bytes memory creationCode)
        internal
        returns (address deployed)
    {
        DeterministicDeployer d = DeterministicDeployer(CREATE3);
        bytes32 salt = d.computeSalt(name, version);
        deployed = d.deploy(salt, creationCode);
        _check(deployed == d.computeAddress(salt), "CREATE3 address", deployed);
        _check(deployed.code.length > 0 && deployed.code.length <= 24_576, "EIP170 runtime size", deployed);
        console.log(name, version, deployed);
    }

    function _deployAll() internal returns (Deployment memory d) {
        d.implementations[0] = _deploy("DirectDemocracyVoting", "v14", type(DirectDemocracyVoting).creationCode);
        d.implementations[1] = _deploy("HybridVoting", "v14", type(HybridVoting).creationCode);
        d.implementations[2] = _deploy("TaskManager", "v9", type(TaskManager).creationCode);
        d.implementations[3] = _deploy("ParticipationToken", "v9", type(ParticipationToken).creationCode);
        d.implementations[4] = _deploy("EducationHub", "v5", type(EducationHub).creationCode);
        d.implementations[5] = _deploy("QuickJoin", "v10", type(QuickJoin).creationCode);
        d.implementations[6] = _deploy("Executor", "v6", type(Executor).creationCode);
        d.implementations[7] = _deploy("OrgDeployer", "v21", type(OrgDeployer).creationCode);
        d.governance = _deploy("GovernanceFactory", "wave-g-v1", type(GovernanceFactory).creationCode);
        d.access = _deploy("AccessFactory", "wave-g-v1", type(AccessFactory).creationCode);
        d.modules = _deploy("ModulesFactory", "wave-g-v1", type(ModulesFactory).creationCode);
    }

    function _ceremony(ChainConfig memory c) internal returns (Deployment memory d) {
        d = _deployAll();
        string[8] memory names = _names();
        string[8] memory versions = _versions();
        for (uint256 i; i < names.length; ++i) {
            if (c.gnosis) IWaveGAdmin(c.admin).upgradeBeaconDirect(names[i], d.implementations[i], versions[i]);
            else IWaveGAdmin(c.admin).upgradeBeaconLocal(names[i], d.implementations[i], versions[i]);
        }
        address deployer = c.organizations.owner();
        IWaveGAdmin(c.admin).adminCall(deployer, abi.encodeCall(OrgDeployer.setGovernanceFactory, (d.governance)));
        IWaveGAdmin(c.admin).adminCall(deployer, abi.encodeCall(OrgDeployer.setAccessFactory, (d.access)));
        IWaveGAdmin(c.admin).adminCall(deployer, abi.encodeCall(OrgDeployer.setModulesFactory, (d.modules)));
        DefaultGlobalRules.Entry[] memory retired = DefaultGlobalRules.retiredEntries();
        bytes32[] memory types = new bytes32[](retired.length);
        bytes4[] memory selectors = new bytes4[](retired.length);
        bool[] memory allowed = new bool[](retired.length);
        uint32[] memory hints = new uint32[](retired.length);
        for (uint256 i; i < retired.length; ++i) {
            types[i] = retired[i].typeId;
            selectors[i] = retired[i].selector;
        }
        IWaveGAdmin(c.admin)
            .adminCall(
                c.paymaster, abi.encodeCall(IWaveGPaymaster.setGlobalRulesBatch, (types, selectors, allowed, hints))
            );
    }

    function _assertEffects(ChainConfig memory c, Deployment memory d) internal view {
        string[8] memory names = _names();
        string[8] memory versions = _versions();
        for (uint256 i; i < names.length; ++i) {
            _check(
                IWaveGManager(c.manager).getCurrentImplementationById(keccak256(bytes(names[i])))
                    == d.implementations[i],
                "current implementation",
                d.implementations[i]
            );
            _check(
                ImplementationRegistry(c.implementations).getImplementation(names[i], versions[i])
                    == d.implementations[i],
                "registered implementation",
                d.implementations[i]
            );
        }
        (address governance, address access, address modules) = OrgDeployer(c.organizations.owner()).factories();
        _check(
            governance == d.governance && access == d.access && modules == d.modules,
            "all factories switched",
            c.organizations.owner()
        );
        DefaultGlobalRules.Entry[] memory retired = DefaultGlobalRules.retiredEntries();
        _check(retired.length == 11, "eleven retired rules", c.paymaster);
        for (uint256 i; i < retired.length; ++i) {
            IWaveGPaymaster.Rule memory rule =
                IWaveGPaymaster(c.paymaster).getGlobalRule(retired[i].typeId, retired[i].selector);
            _check(!rule.allowed && rule.maxCallGasHint == 0, "retired global rule disabled", c.paymaster);
        }
    }

    /// @dev Compare every surviving default Rule, including preexisting disabled entries and gas
    /// hints. The retirement ceremony must never rewrite a surviving rule as a side effect.
    function _activeRulesHash(address paymaster) internal view returns (bytes32 digest) {
        DefaultGlobalRules.Entry[] memory active = DefaultGlobalRules.entries();
        _check(active.length == 56, "fifty-six surviving rules", paymaster);
        for (uint256 i; i < active.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    active[i].typeId,
                    active[i].selector,
                    IWaveGPaymaster(paymaster).getGlobalRule(active[i].typeId, active[i].selector)
                )
            );
        }
    }

    function _readRetiredRulesBefore(address paymaster) internal view {
        DefaultGlobalRules.Entry[] memory retired = DefaultGlobalRules.retiredEntries();
        uint256 allowedBefore;
        bytes32 digest;
        for (uint256 i; i < retired.length; ++i) {
            IWaveGPaymaster.Rule memory rule =
                IWaveGPaymaster(paymaster).getGlobalRule(retired[i].typeId, retired[i].selector);
            if (rule.allowed) ++allowedBefore;
            digest = keccak256(abi.encode(digest, retired[i].typeId, retired[i].selector, rule));
        }
        console.log("Retired global rules allowed before ceremony:", allowedBefore);
        console.log("Retired global rule baseline digest:");
        console.logBytes32(digest);
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory result) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || target.code.length == 0) revert ReadFailed(target, data, ret);
        return ret;
    }

    function _fold(bytes32 previous, address target, string memory signature) internal view returns (bytes32) {
        return keccak256(abi.encode(previous, _read(target, abi.encodeWithSignature(signature))));
    }

    function _pointer(address module, uint256 index) internal view returns (address) {
        if (index == 2) return abi.decode(TaskManager(module).getLensData(12, ""), (address));
        return abi.decode(_read(module, abi.encodeWithSignature("membershipAuthority()")), (address));
    }

    /// @dev Voting outcomes have no public getter. The frozen Proposal array begins at layout
    /// slot +6 on BOTH voting contracts; DD's Proposal stride is 8 words, HV's is 10. Preserve
    /// headers (totalWeight / executed / voterCount) plus complete raw totals and option tallies.
    /// These are read-only vm.load snapshots, never writes or synthetic test state.
    function _outcomeStorage(address module, bool hybrid, uint256 proposalId) internal view returns (bytes32 digest) {
        bytes32 layout = hybrid ? keccak256("poa.hybridvoting.v2.storage") : keccak256("poa.directdemocracy.storage");
        uint256 stride = hybrid ? 10 : 8;
        uint256 base = uint256(keccak256(abi.encode(uint256(layout) + 6))) + proposalId * stride;
        uint256 header = uint256(vm.load(module, bytes32(base)));
        uint64 storedEnd = uint64(hybrid ? header : header >> 128);
        _check(
            storedEnd
                == abi.decode(
                    _read(module, abi.encodeWithSignature("proposalEndTimestamp(uint256)", proposalId)), (uint64)
                ),
            "proposal storage stride",
            module
        );
        for (uint256 j; j < stride; ++j) {
            digest = keccak256(abi.encode(digest, vm.load(module, bytes32(base + j))));
        }
        uint256 optionsSlot = base + (hybrid ? 2 : 1);
        uint256 optionCount = uint256(vm.load(module, bytes32(optionsSlot)));
        _check(optionCount <= 256, "proposal option bound", module);
        uint256 optionsBase = uint256(keccak256(abi.encode(optionsSlot)));
        for (uint256 j; j < optionCount; ++j) {
            uint256 slot = optionsBase + j;
            if (hybrid) digest = keccak256(abi.encode(digest, _arrayStorage(module, slot, true)));
            else digest = keccak256(abi.encode(digest, vm.load(module, bytes32(slot))));
        }
        if (hybrid) digest = keccak256(abi.encode(digest, _arrayStorage(module, base + 1, false)));
    }

    function _arrayStorage(address module, uint256 slot, bool packed128) internal view returns (bytes32 digest) {
        uint256 count = uint256(vm.load(module, bytes32(slot)));
        _check(count <= 256, "proposal class bound", module);
        digest = keccak256(abi.encode(count));
        uint256 words = packed128 ? (count + 1) / 2 : count;
        uint256 base = uint256(keccak256(abi.encode(slot)));
        for (uint256 j; j < words; ++j) {
            digest = keccak256(abi.encode(digest, vm.load(module, bytes32(base + j))));
        }
    }

    function _votingHistory(address module, bool hybrid) internal view returns (bytes32 digest) {
        uint256 count = abi.decode(_read(module, abi.encodeWithSignature("proposalsCount()")), (uint256));
        digest = keccak256(abi.encode(count));
        for (uint256 i; i < count; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    _read(module, abi.encodeWithSignature("proposalEndTimestamp(uint256)", i)),
                    _read(module, abi.encodeWithSignature("proposalCreatedAt(uint256)", i)),
                    _read(module, abi.encodeWithSignature("pollRestricted(uint256)", i)),
                    _outcomeStorage(module, hybrid, i)
                )
            );
            if (hybrid) {
                digest = keccak256(
                    abi.encode(digest, _read(module, abi.encodeWithSignature("getProposalClasses(uint256)", i)))
                );
            }
        }
    }

    /// @dev Complete task/applicant histories for survivors; task zero remains a storage-continuity
    ///      sample on retired orgs. Every existing proposal's timestamps and HV classes are checked.
    function _taskHistory(address module, bool survivor) internal view returns (bytes32 digest) {
        for (uint256 i; i < (survivor ? 2048 : 1); ++i) {
            (bool ok, bytes memory ret) = module.staticcall(abi.encodeCall(TaskManager.getLensData, (1, abi.encode(i))));
            if (!ok) {
                if (ret.length != 4 || bytes4(ret) != TaskManager.NotFound.selector) {
                    revert ReadFailed(module, abi.encode(i), ret);
                }
                return keccak256(abi.encode(digest, i));
            }
            bytes memory task = abi.decode(ret, (bytes));
            bytes32 project = abi.decode(task, (bytes32));
            // Deleted projects are a legitimate historical state; preserve the exact success/revert.
            (bool projectExists, bytes memory projectRet) =
                module.staticcall(abi.encodeCall(TaskManager.getLensData, (2, abi.encode(project))));
            digest = keccak256(
                abi.encode(digest, task, projectExists, projectRet, TaskManager(module).getLensData(7, abi.encode(i)))
            );
        }
        if (survivor) revert HistoryScanLimit(module);
    }

    function _snapshot(ChainConfig memory c, bytes32 orgId) internal view returns (Snapshot memory s) {
        s.orgId = orgId;
        s.authority = _expectedAuthority(orgId);
        address router = c.organizations.getHats();
        uint256 topHat = c.organizations.getTopHat(orgId);
        _check(AuthorityRouter(router).authorityOf(topHat) == s.authority, "router binding", router);
        s.digest = keccak256(
            abi.encode(
                orgId,
                c.organizations.orgCount(),
                c.organizations.totalContracts(),
                topHat,
                router,
                _read(address(c.organizations), abi.encodeCall(OrgRegistry.orgOf, (orgId))),
                c.organizations.getOrgMetadataAdminHat(orgId)
            )
        );
        string[8] memory names = _names();
        for (uint256 i; i < 7; ++i) {
            address module = c.organizations.proxyOf(orgId, keccak256(bytes(names[i])));
            // EducationHub was optional; an absent module must remain absent.
            s.digest = keccak256(abi.encode(s.digest, module));
            if (module == address(0)) {
                _check(i == 4, "required module", module);
                continue;
            }
            address authority = _pointer(module, i);
            if (authority != s.authority) revert UnexpectedAuthority(orgId, authority, s.authority);
            _check(
                c.organizations.isAutoUpgrade(keccak256(abi.encodePacked(orgId, keccak256(bytes(names[i]))))),
                "org follows beacon",
                module
            );
            s.digest = keccak256(abi.encode(s.digest, authority));
            if (i == 2) {
                for (uint8 t = 3; t <= 6; ++t) {
                    s.digest = keccak256(abi.encode(s.digest, TaskManager(module).getLensData(t, "")));
                }
                s.digest = keccak256(
                    abi.encode(
                        s.digest,
                        TaskManager(module).getLensData(10, ""),
                        TaskManager(module).getLensData(11, ""),
                        _taskHistory(module, s.authority != address(0))
                    )
                );
            } else {
                s.digest = _fold(s.digest, module, "hats()");
                s.digest = _fold(s.digest, module, i == 6 ? "allowedCaller()" : "executor()");
                if (i <= 1) {
                    s.digest = _fold(s.digest, module, "creatorHats()");
                    s.digest = keccak256(abi.encode(s.digest, _votingHistory(module, i == 1)));
                }
                if (i == 0) s.digest = _fold(s.digest, module, "votingHats()");
                if (i >= 3 && i <= 5) s.digest = _fold(s.digest, module, "memberHatIds()");
                if (i == 3) {
                    s.digest = _fold(s.digest, module, "approverHatIds()");
                    s.digest = _fold(s.digest, module, "totalSupply()");
                    s.digest = _fold(s.digest, module, "requestCounter()");
                }
                if (i == 4) {
                    s.digest = _fold(s.digest, module, "creatorHatIds()");
                    s.digest = _fold(s.digest, module, "nextModuleId()");
                }
            }
        }
        if (s.authority != address(0)) {
            MembershipAuthority a = MembershipAuthority(s.authority);
            _check(!a.paused(), "surviving authority unpaused", s.authority);
            _check(
                a.orgId() == orgId && a.executor() == c.organizations.proxyOf(orgId, ModuleTypes.EXECUTOR_ID),
                "authority identity",
                s.authority
            );
            s.digest = keccak256(
                abi.encode(
                    s.digest,
                    a.executor(),
                    a.orgId(),
                    a.paused(),
                    a.subjectCount(),
                    a.userSubjects(HUDSON),
                    a.hasPerm(HUDSON, AccessV2PermKeys.DD_VOTE, bytes32(0))
                )
            );
        }
    }

    function _snapshots(ChainConfig memory c) internal view returns (Snapshot[] memory snapshots) {
        bytes32[] memory orgIds = c.organizations.getOrgIds();
        snapshots = new Snapshot[](orgIds.length);
        uint256 survivors;
        for (uint256 i; i < orgIds.length; ++i) {
            snapshots[i] = _snapshot(c, orgIds[i]);
            if (snapshots[i].authority != address(0)) ++survivors;
        }
        _check(survivors == (c.gnosis ? 3 : 1), "all migrated orgs checked", address(c.organizations));
    }

    function _assertSnapshots(ChainConfig memory c, Snapshot[] memory before_) internal view {
        _check(c.organizations.orgCount() == before_.length, "organization count retained", address(c.organizations));
        for (uint256 i; i < before_.length; ++i) {
            Snapshot memory after_ = _snapshot(c, before_[i].orgId);
            if (after_.digest != before_[i].digest) revert HistoryChanged(before_[i].orgId);
        }
        console.log("Organizations with unchanged authority/router/history:", before_.length);
    }

    /// @dev Only called outside broadcast. A retired org's user-facing role gates must reject even
    ///      the known protocol admin; zero authorities may never fall back to legacy Hats.
    function _assertRetiredGates(ChainConfig memory c, Snapshot[] memory snapshots) internal {
        for (uint256 i; i < snapshots.length; ++i) {
            if (snapshots[i].authority != address(0)) continue;
            address token = c.organizations.proxyOf(snapshots[i].orgId, ModuleTypes.PARTICIPATION_TOKEN_ID);
            vm.expectCall(
                address(0),
                abi.encodeWithSignature(
                    "hasPerm(address,bytes32,bytes32)", HUDSON, AccessV2PermKeys.PT_MEMBER, bytes32(0)
                )
            );
            (bool tokenOk,) = token.call(abi.encodeCall(ParticipationToken.requestTokens, (uint96(1), "")));
            _check(!tokenOk, "retired token zero-authority gate", token);
            address edu = c.organizations.proxyOf(snapshots[i].orgId, ModuleTypes.EDUCATION_HUB_ID);
            if (edu != address(0)) {
                vm.expectCall(
                    address(0),
                    abi.encodeWithSignature(
                        "hasPerm(address,bytes32,bytes32)", HUDSON, AccessV2PermKeys.EDU_CREATE, bytes32(0)
                    )
                );
                (bool eduOk,) =
                    edu.call(abi.encodeCall(EducationHub.createModule, (bytes("Wave G gate check"), bytes32(0), 1, 0)));
                _check(!eduOk, "retired education zero-authority gate", edu);
            }
        }
    }

    /// @dev Fork-only smoke exercises the complete new initializer/factory ceremony after upgrading.
    ///      Uses no username registration, signature, deposit, or external metadata publication.
    function _smokeNativeOrg(ChainConfig memory c) internal {
        OrgDeployer.DeploymentParams memory p;
        p.orgId = keccak256(abi.encode("Wave G fork-only native smoke", block.chainid));
        p.orgName = "Wave G fork smoke";
        bytes32 existingOrg = c.gnosis ? TEST6 : POA;
        address existingQj = c.organizations.proxyOf(existingOrg, ModuleTypes.QUICK_JOIN_ID);
        p.registryAddr = address(QuickJoin(existingQj).accountRegistry());
        p.deployerAddress = HUDSON;
        p.autoUpgrade = true;
        p.hybridThresholdPct = 51;
        p.ddThresholdPct = 51;
        p.hybridClasses = new IHybridVotingInit.ClassConfig[](1);
        p.hybridClasses[0].slicePct = 100;
        p.roles = new RoleConfigStructs.RoleConfig[](1);
        p.roles[0].name = "Member";
        p.roles[0].canVote = true;
        p.roles[0].open = true;
        p.roles[0].distribution.mintToDeployer = true;
        p.roleAssignments = OrgDeployer.RoleAssignments(1, 1, 1, 1, 1, 1, 1, 1, 1);
        p.educationHubConfig.enabled = true;
        p.paymasterConfig.autoWhitelistContracts = true;
        OrgDeployer.DeploymentResult memory result = OrgDeployer(c.organizations.owner()).deployFullOrg(p);
        MembershipAuthority a = MembershipAuthority(result.membershipAuthority);
        _check(
            a.executor() == result.executor && a.orgId() == p.orgId && !a.paused(),
            "native authority initialized",
            result.membershipAuthority
        );
        _check(
            a.userSubjects(HUDSON).length > 0 && a.hasPerm(HUDSON, AccessV2PermKeys.DD_VOTE, bytes32(0)) != 0,
            "native founder membership and permission",
            result.membershipAuthority
        );
        _check(
            c.organizations.proxyOf(p.orgId, ModuleTypes.ELIGIBILITY_MODULE_ID) == address(0)
                && c.organizations.proxyOf(p.orgId, ModuleTypes.TOGGLE_MODULE_ID) == address(0),
            "native org has no legacy modules",
            address(c.organizations)
        );
        address[7] memory modules = [
            result.directDemocracyVoting,
            result.hybridVoting,
            result.taskManager,
            result.participationToken,
            result.educationHub,
            result.quickJoin,
            result.executor
        ];
        for (uint256 i; i < modules.length; ++i) {
            _check(_pointer(modules[i], i) == result.membershipAuthority, "native module authority wired", modules[i]);
        }
        EducationHub(result.educationHub).createModule(bytes("Native authority smoke"), bytes32(0), 1, 0);
        _check(
            EducationHub(result.educationHub).nextModuleId() == 1, "native authority creator gate", result.educationHub
        );
        console.log("Fork-only native org deployment and authority write passed:", result.membershipAuthority);
    }

    function _simulate(bool gnosis) internal {
        ChainConfig memory c = _chain(gnosis);
        _assertOwners(c);
        _assertFree(c);
        Snapshot[] memory before_ = _snapshots(c);
        bytes32 activeRulesBefore = _activeRulesHash(c.paymaster);
        _readRetiredRulesBefore(c.paymaster);
        vm.startPrank(HUDSON);
        Deployment memory d = _ceremony(c);
        _assertEffects(c, d);
        _check(_activeRulesHash(c.paymaster) == activeRulesBefore, "surviving global rules unchanged", c.paymaster);
        _assertSnapshots(c, before_);
        _assertRetiredGates(c, before_);
        _smokeNativeOrg(c);
        vm.stopPrank();
        console.log("Wave G production fork ceremony passed on chain", block.chainid);
    }

    function _broadcast(bool gnosis) internal {
        ChainConfig memory c = _chain(gnosis);
        _assertOwners(c);
        _assertFree(c);
        Snapshot[] memory before_ = _snapshots(c);
        bytes32 activeRulesBefore = _activeRulesHash(c.paymaster);
        _readRetiredRulesBefore(c.paymaster);
        uint256 key = vm.envUint("PRIVATE_KEY");
        _check(vm.addr(key) == HUDSON, "broadcast signer", vm.addr(key));
        vm.startBroadcast(key);
        Deployment memory d = _ceremony(c);
        vm.stopBroadcast();
        _assertEffects(c, d);
        _check(_activeRulesHash(c.paymaster) == activeRulesBefore, "surviving global rules unchanged", c.paymaster);
        _assertSnapshots(c, before_);
    }
}

contract SimGnosis is WaveGBase {
    function run() external {
        _simulate(true);
    }
}

contract SimArbitrum is WaveGBase {
    function run() external {
        _simulate(false);
    }
}

contract BroadcastGnosis is WaveGBase {
    function run() external {
        _broadcast(true);
    }
}

contract BroadcastArbitrum is WaveGBase {
    function run() external {
        _broadcast(false);
    }
}
