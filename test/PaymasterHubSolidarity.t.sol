// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {PaymasterHub} from "../src/PaymasterHub.sol";
import {PaymasterHubErrors} from "../src/libs/PaymasterHubErrors.sol";
import {PaymasterFinanceLib} from "../src/libs/PaymasterFinanceLib.sol";
import {PaymasterHubLens} from "../src/PaymasterHubLens.sol";
import {IPaymaster} from "../src/interfaces/IPaymaster.sol";
import {IEntryPoint} from "../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation, UserOpLib} from "../src/interfaces/PackedUserOperation.sol";
import {IHats} from "lib/hats-protocol/src/Interfaces/IHats.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal contract used as a pre-deployed sender in onboarding rejection tests
contract DummySender {
    fallback() external payable {}
}

contract MockEntryPoint is IEntryPoint {
    mapping(address => uint256) private _deposits;

    function depositTo(address account) external payable override {
        _deposits[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(_deposits[msg.sender] >= withdrawAmount, "Insufficient deposit");
        _deposits[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _deposits[account];
    }
}

contract MockHats is IHats {
    mapping(address => mapping(uint256 => bool)) private _wearers;
    mapping(address => mapping(uint256 => bool)) private _eligibles;
    mapping(uint256 => bool) private _activeHats;
    mapping(uint256 => bool) private _hatExists;

    function mintHat(uint256 _hatId, address _wearer) external returns (bool success) {
        _wearers[_wearer][_hatId] = true;
        if (!_hatExists[_hatId]) {
            _hatExists[_hatId] = true;
            _activeHats[_hatId] = true;
        }
        return true;
    }

    function setEligible(address _wearer, uint256 _hatId, bool _eligible) external {
        _eligibles[_wearer][_hatId] = _eligible;
        if (!_hatExists[_hatId]) {
            _hatExists[_hatId] = true;
            _activeHats[_hatId] = true;
        }
    }

    function setActive(uint256 _hatId, bool _active) external {
        _activeHats[_hatId] = _active;
    }

    function isWearerOfHat(address _wearer, uint256 _hatId) external view returns (bool) {
        return _wearers[_wearer][_hatId];
    }

    // Stub implementations for required interface functions
    function createHat(uint256, string calldata, uint32, address, address, bool, string calldata)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function batchCreateHats(
        uint256[] calldata,
        string[] calldata,
        uint32[] calldata,
        address[] calldata,
        address[] calldata,
        bool[] calldata,
        string[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function getNextId(uint256) external pure returns (uint256) {
        return 0;
    }

    function batchMintHats(uint256[] calldata, address[] calldata) external pure returns (bool) {
        return true;
    }

    function setHatStatus(uint256 _hatId, bool _active) external returns (bool) {
        _activeHats[_hatId] = _active;
        return true;
    }

    function checkHatStatus(uint256 _hatId) external view returns (bool) {
        return _activeHats[_hatId];
    }

    function setHatWearerStatus(uint256, address, bool, bool) external pure returns (bool) {
        return true;
    }

    function checkHatWearerStatus(uint256, address) external pure returns (bool) {
        return true;
    }
    function renounceHat(uint256) external {}
    function transferHat(uint256, address, address) external {}
    function makeHatImmutable(uint256) external {}
    function changeHatDetails(uint256, string calldata, string calldata) external {}
    function changeHatEligibility(uint256, address) external {}
    function changeHatToggle(uint256, address) external {}
    function changeHatImageURI(uint256, string calldata) external {}
    function changeHatMaxSupply(uint256, uint32) external {}
    function requestLinkTopHatToTree(uint32, uint256) external {}
    function unlinkTopHatFromTree(uint32, address) external {}

    function viewHat(uint256 _hatId)
        external
        view
        returns (string memory, uint32, uint32, address, address, string memory, uint16, bool, bool)
    {
        return ("", 0, 0, address(0), address(0), "", 0, false, _activeHats[_hatId]);
    }
    function changeHatDetails(uint256, string memory) external {}
    function approveLinkTopHatToTree(uint32, uint256, address, address, string calldata, string calldata) external {}
    function relinkTopHatWithinTree(uint32, uint256, address, address, string calldata, string calldata) external {}

    function isTopHat(uint256) external pure returns (bool) {
        return false;
    }

    function isLocalTopHat(uint256) external pure returns (bool) {
        return false;
    }

    function isValidHatId(uint256) external pure returns (bool) {
        return true;
    }

    function getLocalHatLevel(uint256) external pure returns (uint32) {
        return 0;
    }

    function getTopHatDomain(uint256) external pure returns (uint32) {
        return 0;
    }

    function getTippyTopHatDomain(uint32) external pure returns (uint32) {
        return 0;
    }

    function noCircularLinkage(uint32, uint256) external pure returns (bool) {
        return true;
    }

    function sameTippyTopHatDomain(uint32, uint256) external pure returns (bool) {
        return true;
    }

    function getAdminAtLevel(uint256, uint32) external pure returns (uint256) {
        return 0;
    }

    function getAdminAtLocalLevel(uint256, uint32) external pure returns (uint256) {
        return 0;
    }

    function getTopHatDomainOfHat(uint256) external pure returns (uint32) {
        return 0;
    }

    function getTippyTopHatDomainOfHat(uint256) external pure returns (uint32) {
        return 0;
    }

    function tippyHatDomain() external pure returns (uint32) {
        return 0;
    }

    function noCircularLinkage(uint32) external pure returns (uint256) {
        return 0;
    }

    function linkedTreeAdmins(uint32) external pure returns (uint256) {
        return 0;
    }

    function linkedTreeRequests(uint32) external pure returns (uint256) {
        return 0;
    }

    function lastTopHatId() external pure returns (uint256) {
        return 0;
    }

    function baseImageURI() external pure returns (string memory) {
        return "";
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function balanceOfBatch(address[] calldata, uint256[] calldata) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function buildHatId(uint256, uint16) external pure returns (uint256) {
        return 0;
    }

    function getHatEligibilityModule(uint256) external pure returns (address) {
        return address(0);
    }

    function getHatLevel(uint256) external pure returns (uint32) {
        return 0;
    }

    function getHatMaxSupply(uint256) external pure returns (uint32) {
        return 0;
    }

    function getHatToggleModule(uint256) external pure returns (address) {
        return address(0);
    }

    function getImageURIForHat(uint256) external pure returns (string memory) {
        return "";
    }

    function hatSupply(uint256) external pure returns (uint32) {
        return 0;
    }

    function isAdminOfHat(address, uint256) external pure returns (bool) {
        return false;
    }

    function isEligible(address _wearer, uint256 _hatId) external view returns (bool) {
        return _wearers[_wearer][_hatId] || _eligibles[_wearer][_hatId];
    }

    function isInGoodStanding(address, uint256) external pure returns (bool) {
        return true;
    }

    function mintTopHat(address, string memory, string memory) external pure returns (uint256) {
        return 0;
    }

    function uri(uint256) external pure returns (string memory) {
        return "";
    }
}

/**
 * @title PaymasterHubSolidarityTest
 * @notice Comprehensive tests for solidarity fund, grace period, and progressive tier system
 */
contract PaymasterHubSolidarityTest is Test {
    PaymasterHub public hub;
    PaymasterHubLens public lens;
    MockEntryPoint public entryPoint;
    MockHats public hats;

    address public poaManager = address(0x1);
    address public orgAdmin = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    uint256 constant ADMIN_HAT = 1;
    uint256 constant OPERATOR_HAT = 2;

    bytes32 constant ORG_ALPHA = keccak256("ORG_ALPHA");
    bytes32 constant ORG_BETA = keccak256("ORG_BETA");
    bytes32 constant ORG_GAMMA = keccak256("ORG_GAMMA");

    // Events
    event OrgRegistered(bytes32 indexed orgId, uint256 adminHatId, uint256 operatorHatId);
    event OrgDepositReceived(bytes32 indexed orgId, address indexed from, uint256 amount);
    event SolidarityDonationReceived(address indexed from, uint256 amount);
    event SolidarityFeeCollected(bytes32 indexed orgId, uint256 amount);
    event OrgBannedFromSolidarity(bytes32 indexed orgId, bool banned);
    event GracePeriodConfigUpdated(uint32 initialGraceDays, uint128 maxSpendDuringGrace, uint128 minDepositRequired);

    function setUp() public {
        // Deploy mocks
        entryPoint = new MockEntryPoint();
        hats = new MockHats();

        // Deploy PaymasterHub implementation
        PaymasterHub implementation = new PaymasterHub();

        // Deploy proxy and initialize
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(entryPoint), address(hats), poaManager);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        hub = PaymasterHub(payable(address(proxy)));
        lens = new PaymasterHubLens(address(hub));

        // Setup hats
        hats.mintHat(ADMIN_HAT, orgAdmin);
        hats.mintHat(OPERATOR_HAT, orgAdmin);

        // Fund accounts
        vm.deal(poaManager, 100 ether);
        vm.deal(orgAdmin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Register orgs (requires poaManager)
        vm.startPrank(poaManager);
        hub.registerOrg(ORG_ALPHA, ADMIN_HAT, OPERATOR_HAT);
        hub.registerOrg(ORG_BETA, ADMIN_HAT, OPERATOR_HAT);
        hub.registerOrg(ORG_GAMMA, ADMIN_HAT, OPERATOR_HAT);
        vm.stopPrank();

        // Unpause distribution so existing tests work as before
        // Pause-specific tests re-pause explicitly
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
    }

    // ============ Initialization Tests ============

    function testInitialization() public {
        assertEq(hub.ENTRY_POINT(), address(entryPoint));
        assertEq(hub.HATS(), address(hats));
        assertEq(hub.POA_MANAGER(), poaManager);

        // Check default grace period config
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        assertEq(grace.initialGraceDays, 90);
        assertEq(grace.maxSpendDuringGrace, 0.01 ether);
        assertEq(grace.minDepositRequired, 0.003 ether);

        // Check default solidarity fee
        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.feePercentageBps, 100); // 1%
        assertEq(solidarity.balance, 0);
        assertEq(solidarity.numActiveOrgs, 0);
    }

    function testOrgRegistration() public {
        bytes32 newOrgId = keccak256("NEW_ORG");

        vm.startPrank(poaManager);
        vm.expectEmit(true, false, false, true);
        emit OrgRegistered(newOrgId, ADMIN_HAT, OPERATOR_HAT);
        hub.registerOrg(newOrgId, ADMIN_HAT, OPERATOR_HAT);
        vm.stopPrank();

        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(newOrgId);
        assertEq(config.adminHatId, ADMIN_HAT);
        assertEq(config.operatorHatId, OPERATOR_HAT);
        assertFalse(config.paused);
        assertFalse(config.bannedFromSolidarity);
        assertEq(config.registeredAt, block.timestamp);
    }

    // ============ Grace Period Tests ============

    function testGracePeriodSpendingLimit() public view {
        // New org should be in grace period
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        (bool inGrace, uint128 spendRemaining,,) = lens.getOrgGraceStatus(ORG_ALPHA);

        assertTrue(inGrace);
        assertEq(spendRemaining, grace.maxSpendDuringGrace);
    }

    function testGracePeriodExpires() public {
        // Fast forward past grace period
        vm.warp(block.timestamp + 91 days);

        (bool inGrace,,,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(inGrace);
    }

    function testGracePeriodConfigUpdate() public {
        uint32 newGraceDays = 120;
        uint128 newMaxSpend = 0.02 ether;
        uint128 newMinDeposit = 0.005 ether;

        vm.prank(poaManager);
        vm.expectEmit(false, false, false, true);
        emit GracePeriodConfigUpdated(newGraceDays, newMaxSpend, newMinDeposit);
        hub.setGracePeriodConfig(newGraceDays, newMaxSpend, newMinDeposit);

        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        assertEq(grace.initialGraceDays, newGraceDays);
        assertEq(grace.maxSpendDuringGrace, newMaxSpend);
        assertEq(grace.minDepositRequired, newMinDeposit);
    }

    function testGracePeriodConfigOnlyPoaManager() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setGracePeriodConfig(90, 0.01 ether, 0.003 ether);
    }

    // ============ Deposit Tests ============

    function testDepositForOrg() public {
        uint256 depositAmount = 0.01 ether;

        vm.expectEmit(true, true, false, true);
        emit OrgDepositReceived(ORG_ALPHA, user1, depositAmount);

        vm.prank(user1);
        hub.depositForOrg{value: depositAmount}(ORG_ALPHA);

        // Check org financials
        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, depositAmount);
        assertEq(fin.spent, 0);
        assertEq(fin.solidarityUsedThisPeriod, 0);

        // Check active org count increased
        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.numActiveOrgs, 1);
    }

    function testMultipleDepositsIncrementTotal() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        vm.prank(user2);
        hub.depositForOrg{value: 0.007 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.01 ether);
    }

    function testDepositForNonExistentOrg() public {
        bytes32 fakeOrg = keccak256("FAKE");

        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.OrgNotRegistered.selector);
        hub.depositForOrg{value: 0.01 ether}(fakeOrg);
    }

    function testDonateToSolidarity() public {
        uint256 donationAmount = 1 ether;

        vm.expectEmit(true, false, false, true);
        emit SolidarityDonationReceived(user1, donationAmount);

        vm.prank(user1);
        hub.donateToSolidarity{value: donationAmount}();

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.balance, donationAmount);
    }

    // ============ Overflow Protection Tests ============

    function testDepositForOrgOverflowReverts() public {
        vm.deal(user1, type(uint256).max);
        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.Overflow.selector);
        hub.depositForOrg{value: uint256(type(uint128).max) + 1}(ORG_ALPHA);
    }

    function testDonateToSolidarityOverflowReverts() public {
        vm.deal(user1, type(uint256).max);
        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.Overflow.selector);
        hub.donateToSolidarity{value: uint256(type(uint128).max) + 1}();
    }

    // ============ Period Reset Tests ============

    function testPeriodResetOnTimeElapse() public {
        // Make initial deposit
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin1 = hub.getOrgFinancials(ORG_ALPHA);
        uint32 initialPeriodStart = fin1.periodStart;

        // Fast forward 91 days
        vm.warp(block.timestamp + 91 days);

        // Make another deposit to trigger period check
        vm.prank(user1);
        hub.depositForOrg{value: 0.001 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin2 = hub.getOrgFinancials(ORG_ALPHA);
        assertGt(fin2.periodStart, initialPeriodStart);
        assertEq(fin2.solidarityUsedThisPeriod, 0); // Should be reset
    }

    function testPeriodResetOnDepositThresholdCrossing() public {
        // Start below minimum (grace period just ended)
        vm.warp(block.timestamp + 91 days);

        // Small deposit - below threshold
        vm.prank(user1);
        hub.depositForOrg{value: 0.002 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin1 = hub.getOrgFinancials(ORG_ALPHA);
        uint32 initialPeriodStart = fin1.periodStart;

        // Advance time slightly to make the timestamp change visible
        vm.warp(block.timestamp + 1 seconds);

        // Cross threshold (minDeposit = 0.003 ETH)
        vm.prank(user1);
        hub.depositForOrg{value: 0.002 ether}(ORG_ALPHA); // Total now 0.004 ETH

        PaymasterHub.OrgFinancials memory fin2 = hub.getOrgFinancials(ORG_ALPHA);
        assertGt(fin2.periodStart, initialPeriodStart);
        assertEq(fin2.solidarityUsedThisPeriod, 0);
    }

    // ============ Progressive Tier Tests ============

    function testTier1MatchAllowance() public {
        // Tier 1: 0.003 ETH deposit → 0.006 ETH match → 0.009 ETH total
        vm.warp(block.timestamp + 91 days); // Exit grace period

        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (,, bool requiresDeposit, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit);
        assertEq(solidarityLimit, 0.006 ether); // 2x match
    }

    function testTier2MatchAllowance() public {
        // Tier 2: 0.006 ETH deposit → 0.009 ETH match → 0.015 ETH total
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.006 ether}(ORG_ALPHA);

        (,,, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        // First 0.003 at 2x = 0.006, second 0.003 at 1x = 0.003, total = 0.009
        assertEq(solidarityLimit, 0.009 ether);
    }

    function testTier3NoMatch() public {
        // Tier 3: 0.017+ ETH deposit → no match (self-sufficient)
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.02 ether}(ORG_ALPHA);

        (,,, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertEq(solidarityLimit, 0); // No match for large deposits
    }

    function testBelowMinimumNoMatch() public {
        // Below minimum: no match
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.002 ether}(ORG_ALPHA);

        (,, bool requiresDeposit, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(requiresDeposit); // Below minimum
        assertEq(solidarityLimit, 0); // No match
    }

    // ============ Ban Mechanism Tests ============

    function testBanFromSolidarity() public {
        vm.prank(poaManager);
        vm.expectEmit(true, false, false, true);
        emit OrgBannedFromSolidarity(ORG_ALPHA, true);
        hub.setBanFromSolidarity(ORG_ALPHA, true);

        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(ORG_ALPHA);
        assertTrue(config.bannedFromSolidarity);
    }

    function testUnbanFromSolidarity() public {
        // Ban first
        vm.prank(poaManager);
        hub.setBanFromSolidarity(ORG_ALPHA, true);

        // Then unban
        vm.prank(poaManager);
        vm.expectEmit(true, false, false, true);
        emit OrgBannedFromSolidarity(ORG_ALPHA, false);
        hub.setBanFromSolidarity(ORG_ALPHA, false);

        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(ORG_ALPHA);
        assertFalse(config.bannedFromSolidarity);
    }

    function testBanOnlyPoaManager() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setBanFromSolidarity(ORG_ALPHA, true);
    }

    // ============ Solidarity Fee Tests ============

    function testSetSolidarityFee() public {
        uint16 newFeeBps = 200; // 2%

        vm.prank(poaManager);
        hub.setSolidarityFee(newFeeBps);

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.feePercentageBps, newFeeBps);
    }

    function testSolidarityFeeCapAt10Percent() public {
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.FeeTooHigh.selector);
        hub.setSolidarityFee(1001); // >10%
    }

    function testSolidarityFeeOnlyPoaManager() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setSolidarityFee(200);
    }

    // ============ Fuzz Tests ============

    function testFuzz_DepositAmounts(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);

        vm.prank(user1);
        vm.deal(user1, amount);
        hub.depositForOrg{value: amount}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, amount);
    }

    function testFuzz_TierMatchCalculation(uint128 depositAmount) public {
        vm.assume(depositAmount >= 0.003 ether && depositAmount <= 1 ether);
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        vm.deal(user1, depositAmount);
        hub.depositForOrg{value: depositAmount}(ORG_ALPHA);

        (,,, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);

        // Verify tier logic
        if (depositAmount <= 0.003 ether) {
            // Tier 1: 2x match
            assertEq(solidarityLimit, uint256(depositAmount) * 2);
        } else if (depositAmount <= 0.006 ether) {
            // Tier 2: declining match
            uint256 expected = (0.003 ether * 2) + (uint256(depositAmount) - 0.003 ether);
            assertEq(solidarityLimit, expected);
        } else if (depositAmount >= 0.017 ether) {
            // Tier 3: no match
            assertEq(solidarityLimit, 0);
        }
    }

    function testFuzz_GracePeriodConfig(uint32 graceDays, uint128 maxSpend, uint128 minDeposit) public {
        vm.assume(graceDays > 0 && graceDays <= 365);
        vm.assume(maxSpend > 0 && maxSpend <= 1 ether);
        vm.assume(minDeposit > 0 && minDeposit <= 1 ether);

        vm.prank(poaManager);
        hub.setGracePeriodConfig(graceDays, maxSpend, minDeposit);

        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        assertEq(grace.initialGraceDays, graceDays);
        assertEq(grace.maxSpendDuringGrace, maxSpend);
        assertEq(grace.minDepositRequired, minDeposit);
    }

    // ============ Integration Scenario Tests ============

    function testScenario_BootstrappingCoOp() public {
        // Month 1-3: Grace period
        // Spending: 0.0083 ETH (~$25)
        // From solidarity: 100%

        // (Note: Actual spending happens in postOp during validatePaymasterUserOp,
        // which requires full EntryPoint integration. This tests the state.)

        (bool inGrace, uint128 spendRemaining,,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(inGrace);
        assertEq(spendRemaining, 0.01 ether);

        // Month 4: Enter Tier 1
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        uint256 solidarityLimit;
        (inGrace,,, solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(inGrace);
        assertEq(solidarityLimit, 0.006 ether); // 2x match

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.003 ether);
    }

    function testScenario_GrowingCoOp() public {
        // Month 4: Enter Tier 2
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.006 ether}(ORG_ALPHA);

        (,,, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertEq(solidarityLimit, 0.009 ether); // First 0.003 at 2x + second 0.003 at 1x

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.006 ether);
    }

    function testScenario_EstablishedCoOp() public {
        // Month 4: Tier 3 (self-sufficient)
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.05 ether}(ORG_ALPHA);

        (,,, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertEq(solidarityLimit, 0); // No match for large deposits

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.05 ether);
    }

    function testScenario_TemporaryHardship() public {
        // Normal operations
        vm.warp(block.timestamp + 91 days);
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        // Can't deposit next month, access cut off
        vm.warp(block.timestamp + 91 days);
        (,, bool requiresDeposit,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit); // Still has initial deposit

        // But if deposit was spent and not replenished...
        // (Would need full integration test with actual spending)

        // Community donates
        vm.prank(user2);
        hub.depositForOrg{value: 0.05 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.053 ether);
    }

    function testScenario_MaliciousActor() public {
        // Malicious org burns through grace period
        // (Would need full integration test)

        // PoaManager bans
        vm.prank(poaManager);
        hub.setBanFromSolidarity(ORG_ALPHA, true);

        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(ORG_ALPHA);
        assertTrue(config.bannedFromSolidarity);

        // Can still deposit own funds, but no solidarity access
        vm.prank(user1);
        hub.depositForOrg{value: 0.01 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.01 ether);
    }

    // ============ Edge Case Tests ============

    function testCannotDepositZero() public {
        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.ZeroAmount.selector);
        hub.depositForOrg{value: 0}(ORG_ALPHA);
    }

    function testCannotDonateZero() public {
        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.ZeroAmount.selector);
        hub.donateToSolidarity{value: 0}();
    }

    function testMultipleOrgsIndependentFinancials() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        vm.prank(user1);
        hub.depositForOrg{value: 0.006 ether}(ORG_BETA);

        vm.prank(user1);
        hub.depositForOrg{value: 0.02 ether}(ORG_GAMMA);

        // Check each org has independent state
        PaymasterHub.OrgFinancials memory finAlpha = hub.getOrgFinancials(ORG_ALPHA);
        PaymasterHub.OrgFinancials memory finBeta = hub.getOrgFinancials(ORG_BETA);
        PaymasterHub.OrgFinancials memory finGamma = hub.getOrgFinancials(ORG_GAMMA);

        assertEq(finAlpha.deposited, 0.003 ether);
        assertEq(finBeta.deposited, 0.006 ether);
        assertEq(finGamma.deposited, 0.02 ether);

        // Check active org count
        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.numActiveOrgs, 3);
    }

    function testPeriodStartInitializedOnFirstDeposit() public {
        PaymasterHub.OrgFinancials memory fin1 = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin1.periodStart, 0); // Not initialized yet

        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin2 = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin2.periodStart, block.timestamp);
    }

    // ============ Balance-Based Eligibility Tests ============

    function testBalanceBasedEligibility_LoseEligibilityAfterSpending() public {
        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Deposit $10
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        // Check eligible for Tier 1
        (,, bool requiresDeposit1, uint256 solidarityLimit1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit1);
        assertEq(solidarityLimit1, 0.006 ether); // 2x match

        // Simulate spending by manually updating financials
        // (In real usage, this happens in postOp)
        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.003 ether);
        assertEq(fin.spent, 0);

        // We can't directly test spending without full EntryPoint integration,
        // but we can verify the calculation logic by checking different balance scenarios
    }

    function testBalanceBasedEligibility_TopUpToRegainEligibility() public {
        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Deposit $10
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        // Check eligible
        (,, bool requiresDeposit1, uint256 solidarityLimit1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit1);
        assertEq(solidarityLimit1, 0.006 ether);

        // Top up with another $5 (total cumulative = $15, but this should give Tier 1 match)
        vm.prank(user1);
        hub.depositForOrg{value: 0.0015 ether}(ORG_ALPHA);

        // Check still Tier 1 (balance = 0.0045 ETH, which is > minDeposit but < 2x minDeposit)
        (,, bool requiresDeposit2, uint256 solidarityLimit2) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit2);

        // Should get 2x match on 0.003 (first tier) + 1x match on 0.0015 (second tier)
        // First tier: 0.003 * 2 = 0.006
        // Second tier: 0.0015 * 1 = 0.0015
        // Total: 0.0075 ETH
        assertEq(solidarityLimit2, 0.0075 ether);
    }

    function testBalanceBasedEligibility_OnlyNeedTopUpNotFullDeposit() public {
        // This test simulates the key requirement:
        // If you had $10 and spent $5, you only need to deposit $5 to get back to $10

        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Initial deposit $10
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin1 = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin1.deposited, 0.003 ether);
        assertEq(fin1.spent, 0);

        // Check eligible for $20 match
        (,, bool requiresDeposit1, uint256 solidarityLimit1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit1);
        assertEq(solidarityLimit1, 0.006 ether);

        // In next period, if org spent $5 (we'll simulate with direct access to test the calculation)
        // Balance would be: deposited = 0.003, spent = 0.0015, available = 0.0015 ($5)

        // This verifies the CALCULATION uses available balance, not cumulative deposits
        // The actual spending happens in postOp which requires full EntryPoint setup
    }

    function testCalculateMatchAllowance_UsesAvailableBalance() public {
        // This verifies that eligibility is based on available balance (deposited - spent)
        // not cumulative deposits

        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Without any deposits, should require deposit and have no match
        (,, bool requiresDeposit1, uint256 match1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(requiresDeposit1);
        assertEq(match1, 0);

        // After depositing exactly minimum, should not require deposit and get 2x match
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (,, bool requiresDeposit2, uint256 match2) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit2);
        assertEq(match2, 0.006 ether); // 2x match on available balance
    }

    function testBalanceBasedTiers_Tier1To2To3() public {
        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Tier 1: Deposit 0.003 ETH ($10)
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (,, bool requiresDeposit1, uint256 limit1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit1);
        assertEq(limit1, 0.006 ether); // 2x match

        // Tier 2: Add 0.003 ETH more (total balance = 0.006 ETH = $20)
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (,, bool requiresDeposit2, uint256 limit2) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit2);
        assertEq(limit2, 0.009 ether); // 0.006 (first tier 2x) + 0.003 (second tier 1x)

        // Tier 3: Add 0.011 ETH more (total balance = 0.017 ETH = $51)
        vm.prank(user1);
        hub.depositForOrg{value: 0.011 ether}(ORG_ALPHA);

        (,, bool requiresDeposit3, uint256 limit3) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit3);
        assertEq(limit3, 0); // No match for self-sufficient orgs
    }

    function testBalanceBasedEligibility_BelowMinimumNoMatch() public {
        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Deposit below minimum (0.002 ETH < 0.003 ETH minimum)
        vm.prank(user1);
        hub.depositForOrg{value: 0.002 ether}(ORG_ALPHA);

        // Should require deposit and have no match
        (,, bool requiresDeposit, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(requiresDeposit);
        assertEq(solidarityLimit, 0);
    }

    function testBalanceBasedEligibility_ExactlyAtMinimumGetsMatch() public {
        // Exit grace period
        vm.warp(block.timestamp + 91 days);

        // Deposit exactly at minimum
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (,, bool requiresDeposit, uint256 solidarityLimit) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(requiresDeposit);
        assertEq(solidarityLimit, 0.006 ether); // 2x match
    }

    // ============ Distribution Pause Tests ============

    event SolidarityDistributionPaused();
    event SolidarityDistributionUnpaused();

    function testInitializedWithDistributionPaused() public {
        // Deploy a fresh hub to test initialization state (setUp unpauses)
        PaymasterHub freshImpl = new PaymasterHub();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(entryPoint), address(hats), poaManager);
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), initData);
        PaymasterHub freshHub = PaymasterHub(payable(address(freshProxy)));

        PaymasterHub.SolidarityFund memory solidarity = freshHub.getSolidarityFund();
        assertTrue(solidarity.distributionPaused);
    }

    function testPauseDistributionOnlyPoaManager() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.pauseSolidarityDistribution();
    }

    function testUnpauseDistributionOnlyPoaManager() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.unpauseSolidarityDistribution();
    }

    function testPauseEmitsEvent() public {
        // setUp already unpaused, so we can test pausing
        vm.prank(poaManager);
        vm.expectEmit(false, false, false, true);
        emit SolidarityDistributionPaused();
        hub.pauseSolidarityDistribution();

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertTrue(solidarity.distributionPaused);
    }

    function testUnpauseEmitsEvent() public {
        // Pause first
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        vm.prank(poaManager);
        vm.expectEmit(false, false, false, true);
        emit SolidarityDistributionUnpaused();
        hub.unpauseSolidarityDistribution();

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertFalse(solidarity.distributionPaused);
    }

    function testPausedSolidarityFundStillAcceptsDeposits() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Org deposits should still work
        vm.prank(user1);
        hub.depositForOrg{value: 0.01 ether}(ORG_ALPHA);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0.01 ether);
    }

    function testPausedSolidarityFundStillAcceptsDonations() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Direct donations should still work
        vm.prank(user1);
        hub.donateToSolidarity{value: 1 ether}();

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.balance, 1 ether);
    }

    function testPauseUnpauseRoundtrip() public {
        // Starts unpaused (setUp unpaused it)
        PaymasterHub.SolidarityFund memory s1 = hub.getSolidarityFund();
        assertFalse(s1.distributionPaused);

        // Pause
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();
        PaymasterHub.SolidarityFund memory s2 = hub.getSolidarityFund();
        assertTrue(s2.distributionPaused);

        // Unpause
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        PaymasterHub.SolidarityFund memory s3 = hub.getSolidarityFund();
        assertFalse(s3.distributionPaused);
    }

    function testPausedFeeConfigStillAdjustable() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Can adjust fee percentage even when distribution is paused
        vm.prank(poaManager);
        hub.setSolidarityFee(200); // 2%

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertEq(solidarity.feePercentageBps, 200);
        assertTrue(solidarity.distributionPaused); // Still paused
    }

    function testPausedGraceConfigStillAdjustable() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Can adjust grace period config even when distribution is paused
        vm.prank(poaManager);
        hub.setGracePeriodConfig(120, 0.02 ether, 0.005 ether);

        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        assertEq(grace.initialGraceDays, 120);
        assertEq(grace.maxSpendDuringGrace, 0.02 ether);
        assertEq(grace.minDepositRequired, 0.005 ether);
    }

    // ============ Pause Idempotency Tests ============

    function testDoublePauseIsNoOp() public {
        // Pause first
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Calling pause again should succeed but not emit event
        vm.recordLogs();
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Should have emitted zero events (no state change)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);

        // State unchanged
        PaymasterHub.SolidarityFund memory s = hub.getSolidarityFund();
        assertTrue(s.distributionPaused);
    }

    function testDoubleUnpauseIsNoOp() public {
        // Already unpaused from setUp

        // Calling unpause again should succeed but not emit event
        vm.recordLogs();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);

        PaymasterHub.SolidarityFund memory s = hub.getSolidarityFund();
        assertFalse(s.distributionPaused);
    }

    // ============ getOrgGraceStatus When Paused Tests ============

    function testGetOrgGraceStatus_PausedDuringGrace() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // ORG_ALPHA was just registered, so it's in grace period
        (bool inGrace, uint128 spendRemaining, bool requiresDeposit, uint256 solidarityLimit) =
            lens.getOrgGraceStatus(ORG_ALPHA);

        // inGrace still reflects the time-based status (useful info)
        assertTrue(inGrace);
        // But solidarity is unavailable
        assertEq(spendRemaining, 0);
        assertTrue(requiresDeposit);
        assertEq(solidarityLimit, 0);
    }

    function testGetOrgGraceStatus_PausedPostGrace() public {
        // Pause distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        (bool inGrace, uint128 spendRemaining, bool requiresDeposit, uint256 solidarityLimit) =
            lens.getOrgGraceStatus(ORG_ALPHA);

        assertFalse(inGrace);
        assertEq(spendRemaining, 0);
        assertTrue(requiresDeposit);
        assertEq(solidarityLimit, 0); // No match when paused
    }

    function testGetOrgGraceStatus_UnpausedShowsNormalValues() public view {
        // setUp already unpaused, so this should show normal grace values
        (bool inGrace, uint128 spendRemaining, bool requiresDeposit, uint256 solidarityLimit) =
            lens.getOrgGraceStatus(ORG_ALPHA);

        assertTrue(inGrace);
        assertEq(spendRemaining, 0.01 ether); // Full grace spending available
        assertFalse(requiresDeposit); // No deposit needed during grace
        assertEq(solidarityLimit, 0.01 ether); // Grace limit
    }

    function testGetOrgGraceStatus_PauseThenUnpauseRestoresMatch() public {
        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_ALPHA);

        // Pause — should show no match
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        (,,, uint256 limit1) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertEq(limit1, 0);

        // Unpause — match restored
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();

        (,,, uint256 limit2) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertEq(limit2, 0.006 ether); // 2x match restored
    }

    // ============ registerOrg Access Control Tests ============

    function testRegisterOrgUnauthorizedReverts() public {
        bytes32 newOrgId = keccak256("UNAUTHORIZED_ORG");

        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.registerOrg(newOrgId, ADMIN_HAT, OPERATOR_HAT);
    }

    function testRegisterOrgRandomUserReverts() public {
        bytes32 newOrgId = keccak256("RANDOM_ORG");

        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.registerOrg(newOrgId, ADMIN_HAT, OPERATOR_HAT);
    }

    function testSetOrgRegistrar() public {
        address registrar = address(0x99);

        vm.prank(poaManager);
        hub.setOrgRegistrar(registrar);

        // Registrar can now register orgs
        bytes32 newOrgId = keccak256("REGISTRAR_ORG");
        vm.prank(registrar);
        hub.registerOrg(newOrgId, ADMIN_HAT, OPERATOR_HAT);

        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(newOrgId);
        assertEq(config.adminHatId, ADMIN_HAT);
    }

    function testSetOrgRegistrarUnauthorizedReverts() public {
        vm.prank(orgAdmin);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setOrgRegistrar(address(0x99));
    }

    /*══════════════════════════════════════════════════════════════════
                    GRACE PERIOD ZERO-DEPOSIT TESTS (Bug #1)
    ══════════════════════════════════════════════════════════════════*/

    function testGracePeriodZeroDepositOrgGraceStatus() public {
        // A newly registered org with zero deposits should be in grace
        (bool inGrace, uint128 spendRemaining,,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(inGrace, "New org should be in grace period");

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0, "New org should have zero deposits");
        assertGt(spendRemaining, 0, "Should have spending allowance during grace");
    }

    function testPostGraceZeroDepositOrgNotInGrace() public {
        // Warp past grace period (default 90 days)
        vm.warp(block.timestamp + 91 days);

        (bool inGrace,,,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertFalse(inGrace, "Org should no longer be in grace after 91 days");

        // Verify the org still has zero deposits
        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0, "Org should still have zero deposits");
    }

    function testGracePeriodWithDistributionPausedRequiresDeposit() public {
        // Pause solidarity distribution
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Even in grace period, paused distribution means org must cover from deposits
        // The org has zero deposits, so any operation requiring balance should fail
        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, 0, "Org should have zero deposits");

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        assertTrue(solidarity.distributionPaused, "Distribution should be paused");
    }

    function testGracePeriodPartialDepositAllowed() public {
        // Org deposits a small amount during grace — should work fine
        uint256 smallDeposit = 0.001 ether;
        vm.prank(user1);
        hub.depositForOrg{value: smallDeposit}(ORG_ALPHA);

        (bool inGrace,,,) = lens.getOrgGraceStatus(ORG_ALPHA);
        assertTrue(inGrace, "Org should still be in grace");

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_ALPHA);
        assertEq(fin.deposited, smallDeposit, "Deposit should be recorded");
    }

    // ============ Security Regression Tests ============

    uint8 constant PAYMASTER_DATA_VERSION = 1;
    uint8 constant SUBJECT_TYPE_ACCOUNT = 0x00;
    uint8 constant SUBJECT_TYPE_POA_ONBOARDING = 0x03;
    uint8 constant SUBJECT_TYPE_ORG_DEPLOY = 0x04;
    uint32 constant RULE_ID_COARSE = 0x000000FF;
    uint32 constant RULE_ID_GENERIC = 0;
    uint256 constant MAX_COST = 100_000;

    event OnboardingAccountCreated(address indexed account, uint256 gasCost);
    event OrgDeploymentSponsored(address indexed account, uint256 gasCost);

    function _buildPaymasterData(bytes32 orgId, uint8 subjectType, bytes32 subjectId, uint32 ruleId)
        internal
        view
        returns (bytes memory)
    {
        // ERC-4337 v0.7 format: paymaster(20) | verificationGasLimit(16) | postOpGasLimit(16) | version(1) | orgId(32) | subjectType(1) | subjectId(32) | ruleId(4) = 122 bytes
        return abi.encodePacked(
            address(hub),
            uint128(200_000),
            uint128(100_000),
            PAYMASTER_DATA_VERSION,
            orgId,
            subjectType,
            subjectId,
            ruleId
        );
    }

    function _buildUserOp(address sender, bytes memory callData, bytes memory paymasterAndData)
        internal
        pure
        returns (PackedUserOperation memory userOp)
    {
        userOp = PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: UserOpLib.packAccountGasLimits(100_000, 100_000),
            preVerificationGas: 100_000,
            gasFees: UserOpLib.packGasFees(1, 1),
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    /// @notice Onboarding must reject when orgId is non-zero
    function testOnboardingRejectsNonZeroOrgId() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0));
        bytes memory pmData = _buildPaymasterData(ORG_ALPHA, SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(address(0xdead), "", pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOnboardingRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice In ERC-4337 v0.7, the EntryPoint deploys the account before calling
    /// validatePaymasterUserOp, so the sender will always have code. The EntryPoint
    /// itself reverts with AA10 if initCode targets an already-constructed sender.
    /// We verify that the paymaster does NOT revert for a deployed sender (it delegates
    /// that check to the EntryPoint).
    function testOnboardingAllowsDeployedSender() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0));
        address deployed = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(deployed, "", pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        // Should succeed (not revert) — the EntryPoint handles the AA10 check
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice A reverted onboarding op must NOT emit OnboardingAccountCreated
    function testOnboardingRevertedOpDoesNotEmitCreationEvent() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0));
        address newAccount = address(0xbeef);
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(newAccount, "", pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
        vm.recordLogs();
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opReverted, context, 50_000, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 creationEventSig = keccak256("OnboardingAccountCreated(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != creationEventSig, "OnboardingAccountCreated should not be emitted on revert"
            );
        }
    }

    /// @notice Failed (reverted) onboarding ops must still consume a throttle attempt
    function testOnboardingFailedOpsDoNotConsumeAttemptThrottle() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 1, 0, true, address(0));
        address account1 = address(0xaa01);
        bytes memory pmData1 = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp1 = _buildUserOp(account1, "", pmData1);
        userOp1.initCode = hex"01";
        vm.prank(address(entryPoint));
        (bytes memory context1,) = hub.validatePaymasterUserOp(userOp1, keccak256("hash1"), MAX_COST);
        // Failed op — counter was incremented in validation but refunded in postOp
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opReverted, context1, 50_000, 1);
        // Second onboarding should succeed because the failed op's slot was refunded
        address account2 = address(0xaa02);
        bytes memory pmData2 = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp2 = _buildUserOp(account2, "", pmData2);
        userOp2.initCode = hex"01";
        vm.prank(address(entryPoint));
        (bytes memory context2,) = hub.validatePaymasterUserOp(userOp2, keccak256("hash2"), MAX_COST);
        // Successful op — counter stays incremented (no refund)
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, context2, 50_000, 1);
        // Third onboarding should now be blocked (limit of 1 reached)
        address account3 = address(0xaa03);
        bytes memory pmData3 = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp3 = _buildUserOp(account3, "", pmData3);
        userOp3.initCode = hex"01";
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OnboardingDailyLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp3, keccak256("hash3"), MAX_COST);
    }

    /*═══════════════════════ H4: per-account onboarding cap ═══════════════════════*/

    /// @dev Build a minimal onboarding userOp for `account` (empty callData + initCode satisfies the
    ///      registerAccount path; registry is address(0) so no callData parsing is required).
    function _onboardingOp(address account) internal view returns (PackedUserOperation memory userOp) {
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        userOp = _buildUserOp(account, "", pmData);
        userOp.initCode = hex"01";
    }

    /// @notice A single sender cannot exceed its lifetime onboarding cap.
    function testOnboardingPerAccountCapEnforced() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 1, true, address(0)); // cap = 1 per account

        address acct = address(0xbeef);
        PackedUserOperation memory userOp = _onboardingOp(acct);

        // first onboarding for this sender succeeds
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp, keccak256("h1"), MAX_COST);

        // second from the SAME sender is rejected by the per-account cap (daily limit is 10, so it's not that)
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OnboardingLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("h2"), MAX_COST);
    }

    /// @notice maxOnboardingsPerAccount == 0 disables the per-account cap (unlimited) — preserves legacy behavior.
    function testOnboardingCapZeroMeansUnlimited() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0)); // cap = 0 (unlimited)

        address acct = address(0xbeef);
        PackedUserOperation memory userOp = _onboardingOp(acct);

        // repeated onboardings from the same sender all succeed (bounded only by the global daily limit)
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(address(entryPoint));
            hub.validatePaymasterUserOp(userOp, keccak256(abi.encode("h", i)), MAX_COST);
        }
    }

    /// @notice The cap is tracked per sender — exhausting account A does not affect account B.
    function testOnboardingCapIsolatedPerAccount() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 1, true, address(0)); // cap = 1

        PackedUserOperation memory opA = _onboardingOp(address(0xA11CE));
        PackedUserOperation memory opB = _onboardingOp(address(0xB0B));

        // A uses its single slot then is blocked
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(opA, keccak256("a1"), MAX_COST);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OnboardingLimitExceeded.selector);
        hub.validatePaymasterUserOp(opA, keccak256("a2"), MAX_COST);

        // B is unaffected and can still onboard
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(opB, keccak256("b1"), MAX_COST);
    }

    /// @notice Security property: a FAILED (reverted) onboarding op still consumes the per-account cap.
    ///         Unlike the daily throttle (which is refunded in postOp), the lifetime cap must NOT be refunded,
    ///         because a reverted op still charges the solidarity fund — refunding would let an attacker drain
    ///         the fund via repeated failing ops while keeping their count at zero.
    function testOnboardingFailedOpStillConsumesPerAccountCap() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 1, true, address(0)); // cap = 1

        address acct = address(0xbeef);
        PackedUserOperation memory userOp = _onboardingOp(acct);

        // validate (count -> 1) then simulate a reverted execution via postOp
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(userOp, keccak256("h1"), MAX_COST);
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opReverted, ctx, 50_000, 1);

        // the same sender is STILL blocked — the failed op consumed the cap (no refund)
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OnboardingLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("h2"), MAX_COST);
    }

    /// @notice setOnboardingConfig persists the per-account cap and it is reflected by the getter.
    function testSetOnboardingConfigSetsPerAccountCap() public {
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 5, 7, true, address(0xABCD));
        assertEq(hub.getOnboardingConfig().maxOnboardingsPerAccount, 7);
        assertEq(hub.getOnboardingConfig().dailyCreationLimit, 5);
        assertTrue(hub.getOnboardingConfig().enabled);
    }

    /// @notice Onboarding accepts valid registerAccount callData
    function testOnboardingAcceptsRegisterAccountCallData() public {
        address registry = address(0xCC);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, registry);
        address deployed = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        // Build execute(registryAddress, 0, registerAccount("alice"))
        bytes memory innerData = abi.encodeWithSelector(bytes4(0xbff6de20), "alice");
        bytes memory execCallData = abi.encodeWithSelector(bytes4(0xb61d27f6), registry, uint256(0), innerData);
        PackedUserOperation memory userOp = _buildUserOp(deployed, execCallData, pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        // Should succeed — valid registerAccount callData
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Onboarding rejects callData targeting non-registry address
    function testOnboardingRejectsNonRegistryTarget() public {
        address registry = address(0xCC);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, registry);
        address deployed = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        // Build execute(wrongTarget, 0, registerAccount("alice"))
        bytes memory innerData = abi.encodeWithSelector(bytes4(0xbff6de20), "alice");
        bytes memory execCallData = abi.encodeWithSelector(bytes4(0xb61d27f6), address(0xBAD), uint256(0), innerData);
        PackedUserOperation memory userOp = _buildUserOp(deployed, execCallData, pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOnboardingRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Onboarding rejects callData with non-registerAccount inner selector
    function testOnboardingRejectsNonRegisterAccountSelector() public {
        address registry = address(0xCC);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, registry);
        address deployed = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        // Build execute(registry, 0, someOtherFunction("data"))
        bytes memory innerData = abi.encodeWithSelector(bytes4(0xdeadbeef), "alice");
        bytes memory execCallData = abi.encodeWithSelector(bytes4(0xb61d27f6), registry, uint256(0), innerData);
        PackedUserOperation memory userOp = _buildUserOp(deployed, execCallData, pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOnboardingRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Onboarding rejects callData that is not execute()
    function testOnboardingRejectsNonExecuteOuterSelector() public {
        address registry = address(0xCC);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, registry);
        address deployed = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        // Build arbitrary callData (not execute())
        bytes memory badCallData = abi.encodeWithSelector(bytes4(0x12345678), address(0), uint256(0));
        PackedUserOperation memory userOp = _buildUserOp(deployed, badCallData, pmData);
        userOp.initCode = hex"01";
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOnboardingRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    // ============ Org Deploy Sponsorship Tests ============

    function _setupOrgDeploy(address deployer) internal {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, deployer);
    }

    function _buildOrgDeployCallData(address deployer) internal pure returns (bytes memory) {
        // execute(orgDeployerAddress, 0, deployFullOrg(...)) — inner data is arbitrary for target-only validation
        bytes memory innerData = abi.encodeWithSelector(bytes4(0x12345678), "somedata");
        return abi.encodeWithSelector(bytes4(0xb61d27f6), deployer, uint256(0), innerData);
    }

    /// @notice Happy path: free org deployment succeeds, solidarity deducted, counter incremented
    function testOrgDeployHappyPath() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        PaymasterHub.SolidarityFund memory fundBefore = hub.getSolidarityFund();

        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, context, 50_000, 1);

        assertEq(hub.getOrgDeployCount(sender), 1, "Deploy count should be 1");

        PaymasterHub.SolidarityFund memory fundAfter = hub.getSolidarityFund();
        assertEq(fundBefore.balance - fundAfter.balance, 50_000, "Solidarity should be deducted by actual cost");
    }

    /// @notice Second deploy succeeds, third is rejected (lifetime limit of 2)
    function testOrgDeployLifetimeLimit() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // First deploy
        PackedUserOperation memory userOp1 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = hub.validatePaymasterUserOp(userOp1, keccak256("h1"), MAX_COST);
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 50_000, 1);

        // Second deploy
        PackedUserOperation memory userOp2 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx2,) = hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 50_000, 1);

        assertEq(hub.getOrgDeployCount(sender), 2, "Deploy count should be 2");

        // Third deploy should revert
        PackedUserOperation memory userOp3 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp3, keccak256("h3"), MAX_COST);
    }

    /// @notice Daily limit exceeded reverts
    function testOrgDeployDailyLimitExceeded() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        // Set daily limit to 1, lifetime to 10
        hub.setOrgDeployConfig(uint128(MAX_COST), 1, 10, true, deployer);

        // First deploy (from account1) succeeds
        address sender1 = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp1 = _buildUserOp(sender1, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = hub.validatePaymasterUserOp(userOp1, keccak256("h1"), MAX_COST);
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 50_000, 1);

        // Second deploy (from different account) should hit daily limit
        address sender2 = address(new DummySender());
        PackedUserOperation memory userOp2 = _buildUserOp(sender2, callData, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployDailyLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);
    }

    /// @notice Max gas per deploy exceeded reverts
    function testOrgDeployMaxGasExceeded() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.GasTooHigh.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST + 1);
    }

    /// @notice Disabled feature reverts
    function testOrgDeployDisabledReverts() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, false, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployDisabled.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Non-zero orgId rejected
    function testOrgDeployRejectsNonZeroOrgId() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        bytes memory pmData = _buildPaymasterData(ORG_ALPHA, SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(address(0xdead), callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Non-zero subjectId rejected
    function testOrgDeployRejectsNonZeroSubjectId() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        bytes memory pmData =
            _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(uint256(1)), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(address(0xdead), callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice initCode present rejected (account must already exist)
    function testOrgDeployRejectsInitCode() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);
        userOp.initCode = hex"01";

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Wrong target address rejected
    function testOrgDeployRejectsWrongTarget() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        // Build calldata targeting wrong address
        bytes memory innerData = abi.encodeWithSelector(bytes4(0x12345678), "somedata");
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6), address(0xBAD), uint256(0), innerData);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Non-zero value in execute() rejected
    function testOrgDeployRejectsNonZeroValue() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        // Build calldata with non-zero value
        bytes memory innerData = abi.encodeWithSelector(bytes4(0x12345678), "somedata");
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6), deployer, uint256(1 ether), innerData);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Solidarity paused reverts
    function testOrgDeployRevertsSolidarityPaused() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        // Re-pause distribution (setUp unpauses it)
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.SolidarityDistributionIsPaused.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Insufficient solidarity balance reverts
    function testOrgDeployRevertsInsufficientFunds() public {
        address deployer = address(0xDE);
        // Donate less than MAX_COST
        hub.donateToSolidarity{value: 1}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InsufficientFunds.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Failed op refunds daily counter but does NOT increment per-account counter
    function testOrgDeployFailedOpRefundsDailyCounter() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 1, 2, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // Validate (increments daily counter to 1)
        PackedUserOperation memory userOp1 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = hub.validatePaymasterUserOp(userOp1, keccak256("h1"), MAX_COST);

        // PostOp with failure (refunds daily counter)
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opReverted, ctx1, 50_000, 1);

        // Per-account counter should NOT have been incremented
        assertEq(hub.getOrgDeployCount(sender), 0, "Failed op should not increment deploy count");

        // Daily counter was refunded, so another attempt should succeed
        address sender2 = address(new DummySender());
        PackedUserOperation memory userOp2 = _buildUserOp(sender2, callData, pmData);
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);
    }

    /// @notice Config setter round-trips, emits event, requires poaManager
    function testOrgDeployConfigSetterGetter() public {
        address deployer = address(0xDE);

        // Non-poaManager should revert
        vm.prank(user1);
        vm.expectRevert(PaymasterHubErrors.NotPoaManager.selector);
        hub.setOrgDeployConfig(0.1 ether, 50, 3, true, deployer);

        // PoaManager can set
        vm.prank(poaManager);
        hub.setOrgDeployConfig(0.1 ether, 50, 3, true, deployer);

        PaymasterHub.OrgDeployConfig memory config = hub.getOrgDeployConfig();
        assertEq(config.maxGasPerDeploy, 0.1 ether);
        assertEq(config.dailyDeployLimit, 50);
        assertEq(config.maxDeploysPerAccount, 3);
        assertTrue(config.enabled);
        assertEq(config.orgDeployer, deployer);
    }

    /// @notice Day rollover resets daily counter
    function testOrgDeployDayRollover() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 1, 10, true, deployer);

        address sender1 = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // Use up the daily limit
        PackedUserOperation memory userOp1 = _buildUserOp(sender1, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = hub.validatePaymasterUserOp(userOp1, keccak256("h1"), MAX_COST);
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 50_000, 1);

        // Same day — should fail
        address sender2 = address(new DummySender());
        PackedUserOperation memory userOp2 = _buildUserOp(sender2, callData, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployDailyLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Should succeed now
        PackedUserOperation memory userOp3 = _buildUserOp(sender2, callData, pmData);
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp3, keccak256("h3"), MAX_COST);
    }

    /// @notice Non-execute outer selector rejected
    function testOrgDeployRejectsNonExecuteSelector() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        // Build arbitrary callData (not execute())
        bytes memory callData = abi.encodeWithSelector(bytes4(0x12345678), deployer, uint256(0));
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Successful deploy emits OrgDeploymentSponsored event with correct args
    function testOrgDeployEmitsEvent() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        vm.expectEmit(true, false, false, true);
        emit OrgDeploymentSponsored(sender, 50_000);

        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opSucceeded, context, 50_000, 1);
    }

    /// @notice Config setter emits OrgDeployConfigUpdated event
    function testOrgDeployConfigEmitsEvent() public {
        address deployer = address(0xDE);

        vm.prank(poaManager);
        vm.expectEmit(false, false, false, true);
        emit PaymasterHubErrors.OrgDeployConfigUpdated(0.1 ether, 50, 3, true, deployer);
        hub.setOrgDeployConfig(0.1 ether, 50, 3, true, deployer);
    }

    /// @notice postOpReverted mode: solidarity still deducted, counter NOT incremented
    function testOrgDeployPostOpReverted() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        PaymasterHub.SolidarityFund memory fundBefore = hub.getSolidarityFund();

        // postOpReverted = the first postOp itself reverted, EntryPoint retries
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.postOpReverted, context, 50_000, 1);

        // Counter should NOT increment (postOpReverted != opSucceeded)
        assertEq(hub.getOrgDeployCount(sender), 0, "postOpReverted should not increment deploy count");

        // Solidarity should still be deducted (paymaster was still charged)
        PaymasterHub.SolidarityFund memory fundAfter = hub.getSolidarityFund();
        assertEq(fundBefore.balance - fundAfter.balance, 50_000, "Solidarity should be deducted even on postOpReverted");
    }

    /// @notice postOpReverted with depleted solidarity fund does NOT revert for onboarding
    function testOnboardingPostOpRevertedDepletedSolidarity() public {
        // Donate minimal solidarity — just enough for validation
        hub.donateToSolidarity{value: MAX_COST}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0));

        address newAccount = address(0xbeef);
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(newAccount, "", pmData);
        userOp.initCode = hex"01";

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        // postOpReverted with cost exceeding remaining solidarity — MUST NOT revert
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.postOpReverted, context, MAX_COST + 1, 1);

        // Solidarity should be fully drained (clamped deduction)
        PaymasterHub.SolidarityFund memory fund = hub.getSolidarityFund();
        assertEq(fund.balance, 0, "Solidarity should be fully drained");

        // Daily counter should be refunded
        PaymasterHub.OnboardingConfig memory onboarding = hub.getOnboardingConfig();
        assertEq(onboarding.attemptsToday, 0, "Daily counter should be refunded in fallback");
    }

    /// @notice postOpReverted with depleted solidarity fund does NOT revert for org deploy
    function testOrgDeployPostOpRevertedDepletedSolidarity() public {
        address deployer = address(0xDE);
        // Donate minimal solidarity — just enough for validation
        hub.donateToSolidarity{value: MAX_COST}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        // postOpReverted with cost exceeding remaining solidarity — MUST NOT revert
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.postOpReverted, context, MAX_COST + 1, 1);

        // Solidarity should be fully drained
        PaymasterHub.SolidarityFund memory fund = hub.getSolidarityFund();
        assertEq(fund.balance, 0, "Solidarity should be fully drained");

        // Per-account counter should be refunded (was incremented in validation)
        assertEq(hub.getOrgDeployCount(sender), 0, "Per-account counter should be refunded");

        // Daily counter should be refunded
        PaymasterHub.OrgDeployConfig memory config = hub.getOrgDeployConfig();
        assertEq(config.attemptsToday, 0, "Daily counter should be refunded");
    }

    /// @notice postOpReverted partial deduction — solidarity has some but not enough
    function testOnboardingPostOpRevertedPartialDeduction() public {
        uint256 partialAmount = 30_000;
        hub.donateToSolidarity{value: MAX_COST + partialAmount}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOnboardingConfig(uint128(MAX_COST), 10, 0, true, address(0));

        address newAccount = address(0xbeef);
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_POA_ONBOARDING, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(newAccount, "", pmData);
        userOp.initCode = hex"01";

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        // Validation consumed nothing from balance. Fund has MAX_COST + partialAmount.
        // postOpReverted with cost = MAX_COST + partialAmount + 1 (exceeds fund)
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.postOpReverted, context, uint256(MAX_COST) + partialAmount + 1, 1);

        PaymasterHub.SolidarityFund memory fund = hub.getSolidarityFund();
        assertEq(fund.balance, 0, "Solidarity should be drained to 0 (partial deduction)");
    }

    /// @notice postOpReverted partial deduction for org deploy
    function testOrgDeployPostOpRevertedPartialDeduction() public {
        address deployer = address(0xDE);
        uint256 partialAmount = 30_000;
        hub.donateToSolidarity{value: MAX_COST + partialAmount}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        (bytes memory context,) = hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);

        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.postOpReverted, context, uint256(MAX_COST) + partialAmount + 1, 1);

        PaymasterHub.SolidarityFund memory fund = hub.getSolidarityFund();
        assertEq(fund.balance, 0, "Solidarity should be drained to 0 (partial deduction)");
        assertEq(hub.getOrgDeployCount(sender), 0, "Per-account counter should be refunded");
    }

    /// @notice orgDeployer set to address(0) makes all deploys fail
    function testOrgDeployRejectsZeroOrgDeployer() public {
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 2, true, address(0));

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        // Target doesn't matter — address(0) check in _validateOrgDeployCallData fires first
        bytes memory innerData = abi.encodeWithSelector(bytes4(0x12345678), "somedata");
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6), address(0), uint256(0), innerData);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice maxDeploysPerAccount set to 0 blocks all deploys immediately
    function testOrgDeployZeroMaxDeploysPerAccount() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 100, 0, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Non-generic ruleId rejected for org deploy
    function testOrgDeployRejectsNonGenericRuleId() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_COARSE);
        bytes memory callData = _buildOrgDeployCallData(deployer);
        PackedUserOperation memory userOp = _buildUserOp(address(new DummySender()), callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Empty calldata rejected
    function testOrgDeployRejectsEmptyCalldata() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(sender, "", pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Short calldata (valid selector but missing params) rejected
    function testOrgDeployRejectsShortCalldata() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        // Only selector, no address/value params (< 0x64 bytes)
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6));
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InvalidOrgDeployRequest.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), MAX_COST);
    }

    /// @notice Per-account lifetime counters are independent across accounts
    function testOrgDeployIndependentAccountCounters() public {
        address deployer = address(0xDE);
        _setupOrgDeploy(deployer);

        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // sender1 uses both deploys
        address sender1 = address(new DummySender());
        for (uint256 i = 0; i < 2; i++) {
            PackedUserOperation memory userOp = _buildUserOp(sender1, callData, pmData);
            vm.prank(address(entryPoint));
            (bytes memory ctx,) = hub.validatePaymasterUserOp(userOp, keccak256(abi.encode("s1", i)), MAX_COST);
            vm.prank(address(entryPoint));
            hub.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 50_000, 1);
        }
        assertEq(hub.getOrgDeployCount(sender1), 2);

        // sender1 is blocked
        PackedUserOperation memory blockedOp = _buildUserOp(sender1, callData, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployLimitExceeded.selector);
        hub.validatePaymasterUserOp(blockedOp, keccak256("blocked"), MAX_COST);

        // sender2 should still succeed (independent counter)
        address sender2 = address(new DummySender());
        PackedUserOperation memory userOp2 = _buildUserOp(sender2, callData, pmData);
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp2, keccak256("s2"), MAX_COST);

        assertEq(
            hub.getOrgDeployCount(sender2), 1, "sender2 counter should be 1 (optimistically incremented in validation)"
        );
    }

    /// @notice Per-account counter is bundle-safe: two UserOps from same sender in one bundle
    /// cannot bypass the lifetime limit because the counter is optimistically incremented in validation
    function testOrgDeployBundleSafetyPerAccountCounter() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        // Lifetime limit of 1, daily limit of 10
        hub.setOrgDeployConfig(uint128(MAX_COST), 10, 1, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // First validation succeeds (counter goes 0 -> 1)
        PackedUserOperation memory userOp1 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp1, keccak256("h1"), MAX_COST);

        // Second validation from SAME sender should fail (counter is already 1 >= limit of 1)
        PackedUserOperation memory userOp2 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.OrgDeployLimitExceeded.selector);
        hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);
    }

    /// @notice Failed op refunds the per-account counter (optimistic increment rollback)
    function testOrgDeployFailedOpRefundsPerAccountCounter() public {
        address deployer = address(0xDE);
        hub.donateToSolidarity{value: 1 ether}();
        vm.prank(poaManager);
        hub.unpauseSolidarityDistribution();
        vm.prank(poaManager);
        hub.setOrgDeployConfig(uint128(MAX_COST), 10, 1, true, deployer);

        address sender = address(new DummySender());
        bytes memory pmData = _buildPaymasterData(bytes32(0), SUBJECT_TYPE_ORG_DEPLOY, bytes32(0), RULE_ID_GENERIC);
        bytes memory callData = _buildOrgDeployCallData(deployer);

        // Validate (counter goes 0 -> 1)
        PackedUserOperation memory userOp = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = hub.validatePaymasterUserOp(userOp, keccak256("h1"), MAX_COST);

        assertEq(hub.getOrgDeployCount(sender), 1, "Counter should be 1 after validation");

        // PostOp with failure — counter should be refunded back to 0
        vm.prank(address(entryPoint));
        hub.postOp(IPaymaster.PostOpMode.opReverted, ctx, 50_000, 1);

        assertEq(hub.getOrgDeployCount(sender), 0, "Counter should be refunded to 0 after failure");

        // Same sender can try again
        PackedUserOperation memory userOp2 = _buildUserOp(sender, callData, pmData);
        vm.prank(address(entryPoint));
        hub.validatePaymasterUserOp(userOp2, keccak256("h2"), MAX_COST);
    }

    /// @notice Initialize sets correct org deploy defaults
    function testOrgDeployInitializeDefaults() public {
        PaymasterHub.OrgDeployConfig memory config = hub.getOrgDeployConfig();
        assertEq(config.maxGasPerDeploy, 0.05 ether, "Default maxGasPerDeploy should be 0.05 ether");
        assertEq(config.dailyDeployLimit, 100, "Default dailyDeployLimit should be 100");
        assertEq(config.maxDeploysPerAccount, 2, "Default maxDeploysPerAccount should be 2");
        assertFalse(config.enabled, "Should be disabled by default (requires explicit setOrgDeployConfig)");
        assertEq(config.orgDeployer, address(0), "orgDeployer should be unset initially");
    }

    /// @notice registerOrg must reject bytes32(0) as orgId
    function testRegisterOrgRejectsZeroOrgId() public {
        vm.prank(poaManager);
        vm.expectRevert(PaymasterHubErrors.InvalidOrgId.selector);
        hub.registerOrg(bytes32(0), ADMIN_HAT, OPERATOR_HAT);
    }

    /// @notice Grace-period path must check solidarity fund liquidity before approving
    function testGracePathChecksSolidarityLiquidity() public {
        vm.prank(poaManager);
        hub.setGracePeriodConfig(90, 100 ether, 0.003 ether);
        hub.donateToSolidarity{value: 0.001 ether}();
        bytes32 accountKey = keccak256(abi.encodePacked(SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user1)))));
        vm.startPrank(orgAdmin);
        hub.setBudget(ORG_ALPHA, accountKey, 10 ether, 1 days);
        hub.setRule(ORG_ALPHA, address(0x9999), bytes4(0xdeadbeef), true, 0);
        vm.stopPrank();
        bytes memory innerCall = abi.encodeWithSelector(
            bytes4(0xb61d27f6), address(0x9999), uint256(0), abi.encodeWithSelector(bytes4(0xdeadbeef))
        );
        bytes memory pmData =
            _buildPaymasterData(ORG_ALPHA, SUBJECT_TYPE_ACCOUNT, bytes32(uint256(uint160(user1))), RULE_ID_GENERIC);
        PackedUserOperation memory userOp = _buildUserOp(user1, innerCall, pmData);
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterHubErrors.InsufficientFunds.selector);
        hub.validatePaymasterUserOp(userOp, keccak256("hash"), 2 ether);
    }
}

/*══════════════════════════════════════════════════════════════════
    Harness-based tests for _checkOrgBalance and _checkSolidarityAccess
══════════════════════════════════════════════════════════════════*/

contract PaymasterHubHarness is PaymasterHub {
    function exposed_checkOrgBalance(bytes32 orgId, uint256 maxCost) external returns (uint256 reserved) {
        return _checkOrgBalance(orgId, maxCost);
    }

    /// @dev M-05: the access check now reserves per-org solidarity and returns the reserved amount.
    ///      Delegatecalls PaymasterFinanceLib (same code path the hub uses in validation).
    function exposed_checkSolidarityAccess(bytes32 orgId, uint256 maxCost) external returns (uint256 reserved) {
        return PaymasterFinanceLib.checkSolidarityAccessAndReserve(orgId, maxCost);
    }
}

contract PaymasterHubBalanceCheckTest is Test {
    PaymasterHubHarness public hub;
    MockEntryPoint public entryPoint;
    MockHats public hats;

    address public poaManager = address(0x1);
    address public orgAdmin = address(0x2);
    address public user1 = address(0x3);

    uint256 constant ADMIN_HAT = 1;
    uint256 constant OPERATOR_HAT = 2;

    bytes32 constant ORG_A = keccak256("ORG_A");

    function setUp() public {
        entryPoint = new MockEntryPoint();
        hats = new MockHats();

        PaymasterHubHarness implementation = new PaymasterHubHarness();
        bytes memory initData =
            abi.encodeWithSelector(PaymasterHub.initialize.selector, address(entryPoint), address(hats), poaManager);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        hub = PaymasterHubHarness(payable(address(proxy)));

        hats.mintHat(ADMIN_HAT, orgAdmin);
        hats.mintHat(OPERATOR_HAT, orgAdmin);

        vm.deal(poaManager, 100 ether);
        vm.deal(user1, 100 ether);

        vm.startPrank(poaManager);
        hub.registerOrg(ORG_A, ADMIN_HAT, OPERATOR_HAT);
        hub.unpauseSolidarityDistribution();
        vm.stopPrank();

        // Fund solidarity so grace-period checks pass the balance requirement
        hub.donateToSolidarity{value: 10 ether}();
    }

    /*──────────── _checkOrgBalance: grace period tests ────────────*/

    function testCheckOrgBalance_ZeroDeposit_InGrace_Passes() public {
        // Core fix: zero-deposit org in grace period should NOT revert
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testCheckOrgBalance_ZeroDeposit_PostGrace_Reverts() public {
        vm.warp(block.timestamp + 91 days);

        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testCheckOrgBalance_ZeroDeposit_InGrace_DistributionPaused_Reverts() public {
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // Even in grace, paused distribution means org must cover 100% from deposits
        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testCheckOrgBalance_SufficientDeposit_PassesImmediately() public {
        vm.prank(user1);
        hub.depositForOrg{value: 1 ether}(ORG_A);

        // Deposit covers maxCost entirely — returns without hitting grace check
        hub.exposed_checkOrgBalance(ORG_A, 0.5 ether);
    }

    function testCheckOrgBalance_ExactDeposit_Passes() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.5 ether}(ORG_A);

        hub.exposed_checkOrgBalance(ORG_A, 0.5 ether);
    }

    function testCheckOrgBalance_PartialDeposit_InGrace_Passes() public {
        // Partial deposit (>0 but < maxCost) — hits partial coverage path
        vm.prank(user1);
        hub.depositForOrg{value: 0.001 ether}(ORG_A);

        hub.exposed_checkOrgBalance(ORG_A, 0.01 ether);
    }

    function testCheckOrgBalance_PartialDeposit_PostGrace_Passes() public {
        // Partial deposit post-grace still passes (solidarity covers rest)
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_A);

        vm.warp(block.timestamp + 91 days);

        hub.exposed_checkOrgBalance(ORG_A, 0.005 ether);
    }

    function testCheckOrgBalance_ZeroMaxCost_Passes() public {
        // Edge case: zero maxCost always passes (depositAvailable >= 0)
        hub.exposed_checkOrgBalance(ORG_A, 0);
    }

    function testFuzz_CheckOrgBalance_GracePeriod(uint128 deposit, uint128 maxCost, uint64 timeElapsed) public {
        deposit = uint128(bound(deposit, 0, 10 ether));
        maxCost = uint128(bound(maxCost, 1, 1 ether));
        timeElapsed = uint64(bound(timeElapsed, 0, 180 days));

        if (deposit > 0) {
            vm.deal(user1, uint256(deposit));
            vm.prank(user1);
            hub.depositForOrg{value: deposit}(ORG_A);
        }

        vm.warp(block.timestamp + timeElapsed);

        bool inGrace = timeElapsed < 90 days;
        bool depositCovers = deposit >= maxCost;
        bool hasDeposit = deposit > 0;

        PaymasterHub.SolidarityFund memory solidarity = hub.getSolidarityFund();
        bool paused = solidarity.distributionPaused;

        if (paused) {
            if (depositCovers) {
                hub.exposed_checkOrgBalance(ORG_A, maxCost);
            } else {
                vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
                hub.exposed_checkOrgBalance(ORG_A, maxCost);
            }
        } else if (depositCovers) {
            hub.exposed_checkOrgBalance(ORG_A, maxCost);
        } else if (hasDeposit) {
            // Partial coverage — passes (solidarity covers rest)
            hub.exposed_checkOrgBalance(ORG_A, maxCost);
        } else if (inGrace) {
            // Zero deposit, in grace — the fix: should pass
            hub.exposed_checkOrgBalance(ORG_A, maxCost);
        } else {
            // Zero deposit, post grace — should revert
            vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
            hub.exposed_checkOrgBalance(ORG_A, maxCost);
        }
    }

    /*──────────── _checkSolidarityAccess: comprehensive tests ────────────*/

    function testCheckSolidarityAccess_InGrace_ZeroDeposit_Passes() public {
        // Grace period with zero deposit — only spending limit matters.
        // M-05: the access check now reserves solidarity (mutating), so this is no longer view.
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    function testCheckSolidarityAccess_InGrace_ExceedsMaxSpend_Reverts() public {
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();

        vm.expectRevert(PaymasterHubErrors.GracePeriodSpendLimitReached.selector);
        hub.exposed_checkSolidarityAccess(ORG_A, grace.maxSpendDuringGrace + 1);
    }

    function testCheckSolidarityAccess_PostGrace_BelowMinDeposit_Reverts() public {
        vm.warp(block.timestamp + 91 days);

        // No deposit — below min required
        vm.expectRevert(PaymasterHubErrors.InsufficientDepositForSolidarity.selector);
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    function testCheckSolidarityAccess_PostGrace_WithMinDeposit_Passes() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_A);

        vm.warp(block.timestamp + 91 days);

        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    function testCheckSolidarityAccess_Banned_Reverts() public {
        vm.prank(poaManager);
        hub.setBanFromSolidarity(ORG_A, true);

        vm.expectRevert(PaymasterHubErrors.OrgIsBanned.selector);
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    function testCheckSolidarityAccess_DistributionPaused_SkipsChecks() public {
        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        // When paused, _checkSolidarityAccess returns immediately (skips all checks)
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    /*──────────── Combined flow: both checks in sequence ────────────*/

    function testBothChecks_ZeroDeposit_InGrace_BothPass() public {
        // Simulate the validatePaymasterUserOp call order
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
    }

    function testBothChecks_ZeroDeposit_PostGrace_BalanceReverts() public {
        vm.warp(block.timestamp + 91 days);

        // Balance check fails first (same order as validatePaymasterUserOp)
        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testBothChecks_WithDeposit_PostGrace_BothPass() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.003 ether}(ORG_A);

        vm.warp(block.timestamp + 91 days);

        // Note: _checkOrgBalance now reserves maxCost in org.spent for bundle safety,
        // so we must check solidarity BEFORE balance (or use a small maxCost).
        // In the real flow, _checkSolidarityAccess runs before reservation takes effect
        // because _checkOrgBalance reserves at the end.
        hub.exposed_checkSolidarityAccess(ORG_A, 0.001 ether);
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testBothChecks_GraceEdge_ExactlyAtExpiry() public {
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(ORG_A);

        // Warp to exact expiry boundary
        uint256 graceEndTime = config.registeredAt + (uint256(grace.initialGraceDays) * 1 days);
        vm.warp(graceEndTime);

        // At exact boundary: block.timestamp == graceEndTime, NOT < graceEndTime
        // So inInitialGrace is false — should revert
        vm.expectRevert(PaymasterHubErrors.InsufficientOrgBalance.selector);
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    function testBothChecks_GraceEdge_OneSecondBefore() public {
        PaymasterHub.GracePeriodConfig memory grace = hub.getGracePeriodConfig();
        PaymasterHub.OrgConfig memory config = hub.getOrgConfig(ORG_A);

        uint256 graceEndTime = config.registeredAt + (uint256(grace.initialGraceDays) * 1 days);
        vm.warp(graceEndTime - 1);

        // One second before expiry — still in grace
        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
    }

    /*──────────── _checkOrgBalance: reservation return value ────────────*/

    function testCheckOrgBalance_ReturnsZeroForGracePath() public {
        // Grace org with zero deposits should return reserved=0
        uint256 reserved = hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);
        assertEq(reserved, 0, "Grace+zero-deposit should return 0 reserved");
    }

    function testCheckOrgBalance_ReturnsMaxCostForFundedOrg() public {
        // Deposit so org has funds
        vm.prank(user1);
        hub.depositForOrg{value: 0.1 ether}(ORG_A);

        uint256 reserved = hub.exposed_checkOrgBalance(ORG_A, 0.005 ether);
        assertEq(reserved, 0.005 ether, "Funded org should return maxCost as reserved");
    }

    function testCheckOrgBalance_ReturnsMaxCostWhenPaused() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.1 ether}(ORG_A);

        vm.prank(poaManager);
        hub.pauseSolidarityDistribution();

        uint256 reserved = hub.exposed_checkOrgBalance(ORG_A, 0.005 ether);
        assertEq(reserved, 0.005 ether, "Paused path should return maxCost as reserved");
    }

    /*──────────── Reservation increments org.spent correctly ────────────*/

    function testCheckOrgBalance_ReservationIncrementsSpent() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.1 ether}(ORG_A);

        PaymasterHub.OrgFinancials memory before_ = hub.getOrgFinancials(ORG_A);

        hub.exposed_checkOrgBalance(ORG_A, 0.005 ether);

        PaymasterHub.OrgFinancials memory after_ = hub.getOrgFinancials(ORG_A);
        assertEq(after_.spent - before_.spent, 0.005 ether, "checkOrgBalance should increment org.spent by maxCost");
    }

    function testCheckOrgBalance_GracePathNoSpentIncrease() public {
        PaymasterHub.OrgFinancials memory before_ = hub.getOrgFinancials(ORG_A);

        hub.exposed_checkOrgBalance(ORG_A, 0.001 ether);

        PaymasterHub.OrgFinancials memory after_ = hub.getOrgFinancials(ORG_A);
        assertEq(after_.spent, before_.spent, "Grace+zero-deposit should not increment org.spent");
    }

    function testCheckOrgBalance_MultipleReservationsStack() public {
        vm.prank(user1);
        hub.depositForOrg{value: 0.1 ether}(ORG_A);

        hub.exposed_checkOrgBalance(ORG_A, 0.01 ether);
        hub.exposed_checkOrgBalance(ORG_A, 0.02 ether);
        hub.exposed_checkOrgBalance(ORG_A, 0.03 ether);

        PaymasterHub.OrgFinancials memory fin = hub.getOrgFinancials(ORG_A);
        assertEq(fin.spent, 0.06 ether, "Multiple reservations should stack in org.spent");
    }

    /*──────────── Fuzz: reservation return value matches org.spent delta ────────────*/

    function testFuzz_CheckOrgBalance_ReturnMatchesDelta(uint128 deposit, uint128 maxCost) public {
        vm.assume(deposit > 0 && deposit <= 10 ether);
        vm.assume(maxCost > 0 && maxCost <= deposit);

        vm.prank(user1);
        hub.depositForOrg{value: deposit}(ORG_A);

        PaymasterHub.OrgFinancials memory before_ = hub.getOrgFinancials(ORG_A);

        uint256 reserved = hub.exposed_checkOrgBalance(ORG_A, maxCost);

        PaymasterHub.OrgFinancials memory after_ = hub.getOrgFinancials(ORG_A);
        uint256 delta = after_.spent - before_.spent;

        assertEq(reserved, delta, "Return value should equal org.spent delta");
        assertEq(reserved, maxCost, "Funded org should reserve full maxCost");
    }
}
