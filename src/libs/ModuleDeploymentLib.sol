// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../OrgRegistry.sol";
import {ModuleTypes} from "./ModuleTypes.sol";
import {ZkEmailInvites} from "../ZkEmailInvites.sol";

// Moved interfaces here to break circular dependency
interface IPoaManager {
    function getBeaconById(bytes32 typeId) external view returns (address);
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    /// @dev Public `beacons` mapping getter. Unlike `getBeaconById`, returns address(0)
    ///      for an unregistered type instead of reverting `TypeUnknown` — lets callers
    ///      probe for optional module types without bricking on absence.
    function beacons(bytes32 typeId) external view returns (address);
}

interface IHybridVotingInit {
    enum ClassStrategy {
        DIRECT,
        ERC20_BAL
    }

    struct ClassConfig {
        ClassStrategy strategy;
        uint8 slicePct;
        bool quadratic;
        uint256 minBalance;
        address asset;
        uint256[] hatIds;
    }

    function initialize(
        address hats_,
        address executor_,
        uint256[] calldata initialCreatorHats,
        address[] calldata targets,
        uint8 thresholdPct,
        uint32 quorum_,
        ClassConfig[] calldata initialClasses
    ) external;
}

interface IParticipationToken {
    function setTaskManager(address) external;
    function setEducationHub(address) external;
}

// Micro-interfaces for initializer functions (selector optimization)
interface IExecutorInit {
    function initialize(address owner, address hats) external;
}

interface IQuickJoinInit {
    function initialize(address executor, address hats, address registry, address master, uint256[] calldata memberHats)
        external;
}

interface IParticipationTokenInit {
    function initialize(
        address executor,
        string calldata name,
        string calldata symbol,
        address hats,
        uint256[] calldata memberHats,
        uint256[] calldata approverHats
    ) external;
}

interface ITaskManagerInit {
    function initialize(address token, address hats, uint256[] calldata creatorHats, address executor, address deployer)
        external;
}

interface IEducationHubInit {
    function initialize(
        address token,
        address hats,
        address executor,
        uint256[] calldata creatorHats,
        uint256[] calldata memberHats
    ) external;
}

interface IEligibilityModuleInit {
    function initialize(address deployer, address hats, address toggleModule) external;
}

interface IToggleModuleInit {
    function initialize(address admin) external;
}

interface IPaymentManagerInit {
    function initialize(address _owner, address _revenueShareToken) external;
}

interface IPasskeyAccountFactoryInit {
    function initialize(address poaManager_, address accountBeacon_, address poaGuardian_, uint48 recoveryDelay_)
        external;
}

// ZkEmailInvites init uses the contract's own struct types (InitDomainRule/InitEmailRule),
// so we reference ZkEmailInvites directly rather than a micro-interface.

library ModuleDeploymentLib {
    error InvalidAddress();
    error EmptyInit();
    error UnsupportedType();
    error InitFailed();

    event ModuleDeployed(
        bytes32 indexed orgId, bytes32 indexed typeId, address proxy, address beacon, bool autoUpgrade, address owner
    );

    struct DeployConfig {
        IPoaManager poaManager;
        OrgRegistry orgRegistry;
        address hats;
        bytes32 orgId;
        address moduleOwner;
        bool autoUpgrade;
        address customImpl;
    }

    function deployCore(
        DeployConfig memory config,
        bytes32 typeId, // Pass pre-computed hash instead of string
        bytes memory initData,
        address beacon
    )
        internal
        returns (address proxy)
    {
        if (initData.length == 0) revert EmptyInit();

        // Create proxy using the provided beacon
        proxy = address(new BeaconProxy(beacon, ""));

        // Initialize the proxy (registration happens later via batch registration)
        (bool success, bytes memory returnData) = proxy.call(initData);
        if (!success) {
            // If initialization fails, bubble up the revert reason
            if (returnData.length > 0) {
                assembly {
                    revert(add(32, returnData), mload(returnData))
                }
            } else {
                revert InitFailed();
            }
        }

        emit ModuleDeployed(config.orgId, typeId, proxy, beacon, config.autoUpgrade, config.moduleOwner);
        return proxy;
    }

    function deployExecutor(DeployConfig memory config, address deployer, address beacon)
        internal
        returns (address execProxy)
    {
        // Initialize with Deployer as owner so we can set up governance
        bytes memory init = abi.encodeWithSelector(IExecutorInit.initialize.selector, deployer, config.hats);

        // Deploy using provided beacon
        execProxy = deployCore(config, ModuleTypes.EXECUTOR_ID, init, beacon);
    }

    function deployQuickJoin(
        DeployConfig memory config,
        address executorAddr,
        address registry,
        address masterDeploy,
        uint256[] memory memberHats,
        address beacon
    ) internal returns (address qjProxy) {
        bytes memory init = abi.encodeWithSelector(
            IQuickJoinInit.initialize.selector, executorAddr, config.hats, registry, masterDeploy, memberHats
        );
        qjProxy = deployCore(config, ModuleTypes.QUICK_JOIN_ID, init, beacon);
    }

    function deployParticipationToken(
        DeployConfig memory config,
        address executorAddr,
        string memory name,
        string memory symbol,
        uint256[] memory memberHats,
        uint256[] memory approverHats,
        address beacon
    ) internal returns (address ptProxy) {
        bytes memory init = abi.encodeWithSelector(
            IParticipationTokenInit.initialize.selector,
            executorAddr,
            name,
            symbol,
            config.hats,
            memberHats,
            approverHats
        );
        ptProxy = deployCore(config, ModuleTypes.PARTICIPATION_TOKEN_ID, init, beacon);
    }

    function deployTaskManager(
        DeployConfig memory config,
        address executorAddr,
        address token,
        uint256[] memory creatorHats,
        address beacon,
        address deployer
    ) internal returns (address tmProxy) {
        bytes memory init = abi.encodeWithSelector(
            ITaskManagerInit.initialize.selector, token, config.hats, creatorHats, executorAddr, deployer
        );
        tmProxy = deployCore(config, ModuleTypes.TASK_MANAGER_ID, init, beacon);
    }

    function deployEducationHub(
        DeployConfig memory config,
        address executorAddr,
        address token,
        uint256[] memory creatorHats,
        uint256[] memory memberHats,
        address beacon
    ) internal returns (address ehProxy) {
        bytes memory init = abi.encodeWithSelector(
            IEducationHubInit.initialize.selector, token, config.hats, executorAddr, creatorHats, memberHats
        );
        ehProxy = deployCore(config, ModuleTypes.EDUCATION_HUB_ID, init, beacon);
    }

    function deployEligibilityModule(DeployConfig memory config, address deployer, address toggleModule, address beacon)
        internal
        returns (address emProxy)
    {
        bytes memory init =
            abi.encodeWithSelector(IEligibilityModuleInit.initialize.selector, deployer, config.hats, toggleModule);

        emProxy = deployCore(config, ModuleTypes.ELIGIBILITY_MODULE_ID, init, beacon);
    }

    function deployToggleModule(DeployConfig memory config, address adminAddr, address beacon)
        internal
        returns (address tmProxy)
    {
        bytes memory init = abi.encodeWithSelector(IToggleModuleInit.initialize.selector, adminAddr);

        tmProxy = deployCore(config, ModuleTypes.TOGGLE_MODULE_ID, init, beacon);
    }

    function deployHybridVoting(
        DeployConfig memory config,
        address executorAddr,
        uint256[] memory creatorHats,
        uint8 thresholdPct,
        uint32 quorum,
        IHybridVotingInit.ClassConfig[] memory classes,
        address beacon
    ) internal returns (address hvProxy) {
        // Targets array is kept for backwards compatibility with initialize signature
        // but not validated - HybridVoting just passes batches to Executor
        address[] memory targets = new address[](0);

        bytes memory init = abi.encodeWithSelector(
            IHybridVotingInit.initialize.selector,
            config.hats,
            executorAddr,
            creatorHats,
            targets,
            thresholdPct,
            quorum,
            classes
        );
        hvProxy = deployCore(config, ModuleTypes.HYBRID_VOTING_ID, init, beacon);
    }

    function deployPaymentManager(DeployConfig memory config, address owner, address revenueShareToken, address beacon)
        internal
        returns (address pmProxy)
    {
        bytes memory init = abi.encodeWithSelector(IPaymentManagerInit.initialize.selector, owner, revenueShareToken);
        pmProxy = deployCore(config, ModuleTypes.PAYMENT_MANAGER_ID, init, beacon);
    }

    function deployDirectDemocracyVoting(
        DeployConfig memory config,
        address executorAddr,
        uint256[] memory votingHats,
        uint256[] memory creatorHats,
        address[] memory initialTargets,
        uint8 thresholdPct,
        uint32 quorum,
        address beacon
    ) internal returns (address ddProxy) {
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,uint256[],uint256[],address[],uint8,uint32)",
            config.hats,
            executorAddr,
            votingHats,
            creatorHats,
            initialTargets,
            thresholdPct,
            quorum
        );
        ddProxy = deployCore(config, ModuleTypes.DIRECT_DEMOCRACY_VOTING_ID, init, beacon);
    }

    function deployPasskeyAccountFactory(
        DeployConfig memory config,
        address poaManager,
        address accountBeacon,
        address poaGuardian,
        uint48 recoveryDelay,
        address factoryBeacon
    ) internal returns (address factoryProxy) {
        bytes memory init = abi.encodeWithSelector(
            IPasskeyAccountFactoryInit.initialize.selector, poaManager, accountBeacon, poaGuardian, recoveryDelay
        );
        factoryProxy = deployCore(config, ModuleTypes.PASSKEY_ACCOUNT_FACTORY_ID, init, factoryBeacon);
    }

    /// @notice Deploy a module proxy WITHOUT initializing it. The caller initializes it AFTER the
    ///         module is registered in OrgRegistry, so a per-org subgraph data-source template (created
    ///         on ContractRegistered) catches the config/rule events that initialize() emits — avoiding
    ///         eth_calls and indexing the deploy-time snapshot. (See CLAUDE.md "Events & subgraph indexing".)
    function deployUninitializedProxy(DeployConfig memory config, bytes32 typeId, address beacon)
        internal
        returns (address proxy)
    {
        proxy = address(new BeaconProxy(beacon, ""));
        emit ModuleDeployed(config.orgId, typeId, proxy, beacon, config.autoUpgrade, config.moduleOwner);
    }
}
