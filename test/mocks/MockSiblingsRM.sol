// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @dev Recorder mocks for the sibling modules RoleManager fans permission wiring out to. Each
///      records the calls it receives so tests can assert the exact fan-out. Enum parameters are
///      ABI-encoded as `uint8`, so `setConfig(uint8,bytes)` here shares a selector with the concrete
///      modules' `setConfig(ConfigKey,bytes)`.

contract MockDDVotingRM {
    struct ConfigCall {
        uint8 key;
        bytes value;
    }

    ConfigCall[] public calls;

    function setConfig(uint8 key, bytes calldata value) external {
        calls.push(ConfigCall(key, value));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function callAt(uint256 i) external view returns (uint8 key, bytes memory value) {
        ConfigCall storage c = calls[i];
        return (c.key, c.value);
    }
}

contract MockHVVotingRM {
    mapping(uint256 => bool) public creatorAllowed;
    uint256 public creatorCallCount;

    struct ClassEdit {
        uint8 classIdx;
        uint256 hatId;
        bool added;
    }

    ClassEdit[] public classEdits;

    function setCreatorHatAllowed(uint256 h, bool ok) external {
        creatorAllowed[h] = ok;
        creatorCallCount += 1;
    }

    function addHatToClass(uint8 classIdx, uint256 hatId) external {
        classEdits.push(ClassEdit(classIdx, hatId, true));
    }

    function removeHatFromClass(uint8 classIdx, uint256 hatId) external {
        classEdits.push(ClassEdit(classIdx, hatId, false));
    }

    function classEditCount() external view returns (uint256) {
        return classEdits.length;
    }
}

contract MockTaskManagerRM {
    struct ConfigCall {
        uint8 key;
        bytes value;
    }

    ConfigCall[] public calls;

    function setConfig(uint8 key, bytes calldata value) external {
        calls.push(ConfigCall(key, value));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function callAt(uint256 i) external view returns (uint8 key, bytes memory value) {
        ConfigCall storage c = calls[i];
        return (c.key, c.value);
    }
}

contract MockPTRM {
    mapping(uint256 => bool) public memberAllowed;
    mapping(uint256 => bool) public approverAllowed;
    uint256 public memberCallCount;
    uint256 public approverCallCount;

    function setMemberHatAllowed(uint256 h, bool ok) external {
        memberAllowed[h] = ok;
        memberCallCount += 1;
    }

    function setApproverHatAllowed(uint256 h, bool ok) external {
        approverAllowed[h] = ok;
        approverCallCount += 1;
    }
}

contract MockEduRM {
    mapping(uint256 => bool) public creatorAllowed;
    mapping(uint256 => bool) public memberAllowed;
    uint256 public creatorCallCount;
    uint256 public memberCallCount;

    function setCreatorHatAllowed(uint256 h, bool ok) external {
        creatorAllowed[h] = ok;
        creatorCallCount += 1;
    }

    function setMemberHatAllowed(uint256 h, bool ok) external {
        memberAllowed[h] = ok;
        memberCallCount += 1;
    }
}

contract MockQuickJoinRM {
    uint256[] internal _memberHatIds;

    function seed(uint256[] calldata ids) external {
        _memberHatIds = ids;
    }

    function memberHatIds() external view returns (uint256[] memory) {
        return _memberHatIds;
    }

    function updateMemberHatIds(uint256[] calldata memberHatIds_) external {
        _memberHatIds = memberHatIds_;
    }
}

contract MockPaymasterHubRM {
    struct BudgetCall {
        bytes32 orgId;
        bytes32 subjectKey;
        uint128 cap;
        uint32 epochLen;
    }

    BudgetCall[] public calls;
    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setBudget(bytes32 orgId, bytes32 subjectKey, uint128 cap, uint32 epochLen) external {
        require(!shouldRevert, "paymaster: revert");
        calls.push(BudgetCall(orgId, subjectKey, cap, epochLen));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}
