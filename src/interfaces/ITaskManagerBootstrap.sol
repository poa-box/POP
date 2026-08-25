// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @notice TaskManager's deploy-window bootstrap surface, callable only by the OrgDeployer.
/// @dev Lives in its own file so both OrgDeployer and AccessFactory can name the config structs —
///      AccessFactory turns a project's role lists into the authority's per-project TM_PERMS rows.
interface ITaskManagerBootstrap {
    /// @dev The four `*Hats` lists carry ROLE INDICES from the deploy params and are rewritten to
    ///      authority subject ids before TaskManager sees them.
    struct BootstrapProjectConfig {
        bytes title;
        bytes32 metadataHash;
        uint256 cap;
        address[] managers;
        uint256[] createHats;
        uint256[] claimHats;
        uint256[] reviewHats;
        uint256[] assignHats;
        address[] bountyTokens;
        uint256[] bountyCaps;
    }

    struct BootstrapTaskConfig {
        uint8 projectIndex;
        uint256 payout;
        bytes title;
        bytes32 metadataHash;
        address bountyToken;
        uint256 bountyPayout;
        bool requiresApplication;
    }

    function bootstrapProjectsAndTasks(BootstrapProjectConfig[] calldata projects, BootstrapTaskConfig[] calldata tasks)
        external
        returns (bytes32[] memory projectIds);

    function clearDeployer() external;
}
