// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../OrgRegistry.sol";
import {ModuleTypes} from "./ModuleTypes.sol";

// Moved interfaces here to break circular dependency
interface IPoaManager {
    function getBeaconById(bytes32 typeId) external view returns (address);
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
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
        uint256 hatId;
    }

    function initialize(
        address hats_,
        address executor_,
        uint256 proposalCreatorHat,
        address[] calldata targets,
        uint8 thresholdPct,
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
    function initialize(
        address executor,
        address hats,
        address registry,
        address master,
        uint256 memberHat,
        address roleBundleHatter
    ) external;
}

interface IParticipationTokenInit {
    function initialize(
        address executor,
        string calldata name,
        string calldata symbol,
        address hats,
        uint256 memberHat,
        uint256 approverHat
    ) external;
}

interface ITaskManagerInit {
    function initialize(address token, address hats, uint256 projectCreatorHat, address executor, address deployer)
        external;
}

interface IEducationHubInit {
    function initialize(address token, address hats, address executor, uint256 creatorHat, uint256 memberHat) external;
}

interface IEligibilityModuleInit {
    function initialize(address deployer, address hats, address toggleModule) external;
}

interface IToggleModuleInit {
    function initialize(address admin) external;
}

interface IRoleBundleHatterInit {
    function initialize(address hats, address executor, address deployer) external;
}

interface IPaymentManagerInit {
    function initialize(address _owner, address _revenueShareToken) external;
}

interface IPasskeyAccountFactoryInit {
    function initialize(address poaManager_, address accountBeacon_, address poaGuardian_, uint48 recoveryDelay_)
        external;
}

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

    function deployRoleBundleHatter(DeployConfig memory config, address executorAddr, address deployer, address beacon)
        internal
        returns (address rbhProxy)
    {
        bytes memory init =
            abi.encodeWithSelector(IRoleBundleHatterInit.initialize.selector, config.hats, executorAddr, deployer);
        rbhProxy = deployCore(config, ModuleTypes.ROLE_BUNDLE_HATTER_ID, init, beacon);
    }

    function deployQuickJoin(
        DeployConfig memory config,
        address executorAddr,
        address registry,
        address masterDeploy,
        uint256 memberHat,
        address roleBundleHatter,
        address beacon
    ) internal returns (address qjProxy) {
        bytes memory init = abi.encodeWithSelector(
            IQuickJoinInit.initialize.selector,
            executorAddr,
            config.hats,
            registry,
            masterDeploy,
            memberHat,
            roleBundleHatter
        );
        qjProxy = deployCore(config, ModuleTypes.QUICK_JOIN_ID, init, beacon);
    }

    function deployParticipationToken(
        DeployConfig memory config,
        address executorAddr,
        string memory name,
        string memory symbol,
        uint256 memberHat,
        uint256 approverHat,
        address beacon
    ) internal returns (address ptProxy) {
        bytes memory init = abi.encodeWithSelector(
            IParticipationTokenInit.initialize.selector, executorAddr, name, symbol, config.hats, memberHat, approverHat
        );
        ptProxy = deployCore(config, ModuleTypes.PARTICIPATION_TOKEN_ID, init, beacon);
    }

    function deployTaskManager(
        DeployConfig memory config,
        address executorAddr,
        address token,
        uint256 projectCreatorHat,
        address beacon,
        address deployer
    ) internal returns (address tmProxy) {
        bytes memory init = abi.encodeWithSelector(
            ITaskManagerInit.initialize.selector, token, config.hats, projectCreatorHat, executorAddr, deployer
        );
        tmProxy = deployCore(config, ModuleTypes.TASK_MANAGER_ID, init, beacon);
    }

    function deployEducationHub(
        DeployConfig memory config,
        address executorAddr,
        address token,
        uint256 creatorHat,
        uint256 memberHat,
        address beacon
    ) internal returns (address ehProxy) {
        bytes memory init = abi.encodeWithSelector(
            IEducationHubInit.initialize.selector, token, config.hats, executorAddr, creatorHat, memberHat
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
        uint256 proposalCreatorHat,
        uint8 thresholdPct,
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
            proposalCreatorHat,
            targets,
            thresholdPct,
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
        uint256 votingHat,
        uint256 proposalCreatorHat,
        address[] memory initialTargets,
        uint8 thresholdPct,
        address beacon
    ) internal returns (address ddProxy) {
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,uint256,uint256,address[],uint8)",
            config.hats,
            executorAddr,
            votingHat,
            proposalCreatorHat,
            initialTargets,
            thresholdPct
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
}
