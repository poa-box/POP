// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;
import {MockModuleAuthority} from "./mocks/MockModuleAuthority.sol";

/*──────────── forge-std helpers ───────────*/
import "forge-std/Test.sol";
import "forge-std/console.sol";

/*──────────── OpenZeppelin ───────────*/
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/*──────────── Local contracts ───────────*/
import {PasskeyAccount} from "../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../src/PasskeyAccountFactory.sol";
import {IPasskeyAccount} from "../src/interfaces/IPasskeyAccount.sol";
import {P256Verifier} from "../src/libs/P256Verifier.sol";
import {WebAuthnLib} from "../src/libs/WebAuthnLib.sol";
import {QuickJoin} from "../src/QuickJoin.sol";
import {UniversalAccountRegistry} from "../src/UniversalAccountRegistry.sol";
import {Executor} from "../src/Executor.sol";
import {AccessFactory} from "../src/factories/AccessFactory.sol";
import {ModuleTypes} from "../src/libs/ModuleTypes.sol";
import {PackedUserOperation} from "../src/interfaces/PackedUserOperation.sol";

/*──────────── Hats Protocol ───────────*/
import {IHats} from "@hats-protocol/src/Interfaces/IHats.sol";
import {MockHats} from "./mocks/MockHats.sol";

/*────────────────────── Mock Contracts ──────────────────────*/

/// @notice Mock P256 Precompile that always returns valid
contract MockP256Precompile {
    function verify(bytes32, bytes32, bytes32, bytes32, bytes32) external pure returns (uint256) {
        return 1;
    }

    fallback() external {
        assembly {
            // Return 1 (valid signature)
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}

/// @notice Mock EntryPoint for testing
contract MockEntryPoint {
    address public account;

    function setAccount(address _account) external {
        account = _account;
    }

    function validateUserOp(
        address accountAddr,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256) {
        return PasskeyAccount(payable(accountAddr)).validateUserOp(userOp, userOpHash, missingAccountFunds);
    }

    function executeFromEntryPoint(address target, bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = target.call(data);
        require(success, "EntryPoint call failed");
        return result;
    }
}

/// @notice Mock Executor for testing hat minting
contract MockExecutor {
    mapping(address => uint256[]) public mintedHats;

    function mintHatsForUser(address user, uint256[] calldata hatIds) external {
        for (uint256 i = 0; i < hatIds.length; i++) {
            mintedHats[user].push(hatIds[i]);
        }
    }

    function getMintedHats(address user) external view returns (uint256[] memory) {
        return mintedHats[user];
    }
}

/*────────────────────── Test Contract ──────────────────────*/

contract PasskeyTest is Test {
    /*──────── Constants ────────*/
    bytes32 constant CREDENTIAL_ID = keccak256("test_credential_1");
    bytes32 constant CREDENTIAL_ID_2 = keccak256("test_credential_2");

    // Test P256 public key (not real - just for structure testing)
    bytes32 constant PUB_KEY_X = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    bytes32 constant PUB_KEY_Y = 0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321;

    // Real on-curve NIST P-256 public key (used for recovery, which now requires isValidPublicKey)
    bytes32 constant CURVE_X = 0x1ccbe91c075fc7f4f033bfa248db8fccd3565de94bbfb12f3c59ff46c271bf83;
    bytes32 constant CURVE_Y = 0xce4014c68811f9a21a1fdb2c0e6113e06db7ca93b7404e78dc7ccd5ca89a4ca9;

    /*──────── State ────────*/
    PasskeyAccount accountImpl;
    PasskeyAccountFactory factoryImpl;
    UpgradeableBeacon accountBeacon;
    UpgradeableBeacon factoryBeacon;
    PasskeyAccountFactory factory;
    MockEntryPoint entryPoint;
    MockExecutor mockExecutor;
    QuickJoin quickJoinImpl;
    UpgradeableBeacon quickJoinBeacon;
    QuickJoin quickJoin;
    UniversalAccountRegistry accountRegistry;
    MockHats hats;

    address owner = address(0x1);
    address guardian = address(0x2);
    address user = address(0x3);
    address attacker = address(0x4);
    // Three M-of-N recovery guardians for H-04 tests.
    address guardianA = address(0xA1);
    address guardianB = address(0xB2);
    address guardianC = address(0xC3);

    /*──────── Events ────────*/
    event CredentialAdded(bytes32 indexed credentialId, uint64 createdAt);
    event CredentialRemoved(bytes32 indexed credentialId);
    event CredentialStatusChanged(bytes32 indexed credentialId, bool active);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event RecoveryThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event RecoveryApproved(bytes32 indexed proposalId, address indexed guardian, uint256 approvals);
    event RecoveryInitiated(
        bytes32 indexed recoveryId, bytes32 credentialId, address indexed initiator, uint48 executeAfter
    );
    event RecoveryCompleted(bytes32 indexed recoveryId, bytes32 indexed credentialId);
    event RecoveryCancelled(bytes32 indexed recoveryId);
    event AccountCreated(address indexed account, bytes32 credentialId, address indexed owner);
    event GlobalConfigUpdated(address indexed poaGuardian, uint48 recoveryDelay, uint8 maxCredentials);

    /*──────── Setup ────────*/
    function setUp() public {
        vm.startPrank(owner);

        // Deploy Mock Hats
        hats = new MockHats();

        // Deploy implementations
        accountImpl = new PasskeyAccount();
        factoryImpl = new PasskeyAccountFactory();

        // Deploy beacons
        accountBeacon = new UpgradeableBeacon(address(accountImpl), owner);
        factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);

        // Deploy factory via beacon proxy with universal config
        bytes memory factoryInitData = abi.encodeWithSelector(
            PasskeyAccountFactory.initialize.selector,
            owner, // poaManager
            address(accountBeacon), // account beacon
            guardian, // poaGuardian
            uint48(7 days) // recoveryDelay
        );
        factory = PasskeyAccountFactory(address(new BeaconProxy(address(factoryBeacon), factoryInitData)));

        // Deploy mock entry point
        entryPoint = new MockEntryPoint();

        // Deploy mock executor
        mockExecutor = new MockExecutor();

        // Deploy account registry via beacon proxy (constructor has _disableInitializers)
        UniversalAccountRegistry registryImpl = new UniversalAccountRegistry();
        UpgradeableBeacon registryBeacon = new UpgradeableBeacon(address(registryImpl), owner);
        accountRegistry = UniversalAccountRegistry(
            address(
                new BeaconProxy(
                    address(registryBeacon), abi.encodeWithSelector(UniversalAccountRegistry.initialize.selector, owner)
                )
            )
        );

        vm.stopPrank();
    }

    /*════════════════════════════════════════════════════════════════════
                        PASSKEY ACCOUNT FACTORY TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testFactoryInitialization() public view {
        assertEq(factory.poaManager(), owner);
        assertEq(factory.accountBeacon(), address(accountBeacon));

        PasskeyAccountFactory.GlobalConfig memory config = factory.getGlobalConfig();
        assertEq(config.poaGuardian, guardian);
        assertEq(config.recoveryDelay, 7 days);
        assertEq(config.maxCredentialsPerAccount, 10); // Default
        assertFalse(config.paused);
    }

    function testFactorySetPoaGuardian() public {
        vm.startPrank(owner);

        address newGuardian = address(0x999);

        factory.setPoaGuardian(newGuardian);

        PasskeyAccountFactory.GlobalConfig memory config = factory.getGlobalConfig();
        assertEq(config.poaGuardian, newGuardian);

        vm.stopPrank();
    }

    function testFactorySetRecoveryDelay() public {
        vm.startPrank(owner);

        factory.setRecoveryDelay(14 days);

        PasskeyAccountFactory.GlobalConfig memory config = factory.getGlobalConfig();
        assertEq(config.recoveryDelay, 14 days);

        vm.stopPrank();
    }

    function testFactorySetMaxCredentials() public {
        vm.startPrank(owner);

        factory.setMaxCredentials(15);

        PasskeyAccountFactory.GlobalConfig memory config = factory.getGlobalConfig();
        assertEq(config.maxCredentialsPerAccount, 15);

        vm.stopPrank();
    }

    function testFactorySetPoaGuardianUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(PasskeyAccountFactory.Unauthorized.selector);
        factory.setPoaGuardian(guardian);
    }

    function testFactoryCreateAccount() public {
        // Compute expected address before the prank
        address expectedAccount = factory.getAddress(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);

        vm.expectEmit(true, true, false, true);
        emit AccountCreated(expectedAccount, CREDENTIAL_ID, user);

        vm.prank(user);
        address account = factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);

        assertTrue(account != address(0));
        assertTrue(factory.isDeployedAccount(account));

        PasskeyAccount pa = PasskeyAccount(payable(account));
        assertEq(pa.factory(), address(factory));
        // M-06/H-04: no guardian is baked in at creation; recovery starts DISABLED.
        assertEq(pa.getGuardians().length, 0);
        assertEq(pa.recoveryThreshold(), 0);

        IPasskeyAccount.PasskeyCredential memory cred = pa.getCredential(CREDENTIAL_ID);
        assertEq(cred.publicKeyX, PUB_KEY_X);
        assertEq(cred.publicKeyY, PUB_KEY_Y);
        assertTrue(cred.active);
    }

    function testFactoryCreateAccountDeterministic() public {
        // Get predicted address
        address predicted = factory.getAddress(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);

        // Create account
        vm.prank(user);
        address actual = factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);

        assertEq(actual, predicted);
    }

    function testFactoryCreateAccountSameTwice() public {
        vm.startPrank(user);

        address first = factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);
        address second = factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);

        // Should return same address (idempotent)
        assertEq(first, second);

        vm.stopPrank();
    }

    function testFactoryCreateAccountWhenPaused() public {
        vm.prank(owner);
        factory.setPaused(true);

        vm.prank(user);
        vm.expectRevert(PasskeyAccountFactory.Paused.selector);
        factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);
    }

    function testFactorySetPoaManager() public {
        vm.startPrank(owner);

        address newManager = address(0x888);
        factory.setPoaManager(newManager);

        assertEq(factory.poaManager(), newManager);

        vm.stopPrank();
    }

    function testFactorySetPoaManagerZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PasskeyAccountFactory.ZeroAddress.selector);
        factory.setPoaManager(address(0));
    }

    /*════════════════════════════════════════════════════════════════════
                        PASSKEY ACCOUNT TESTS
    ════════════════════════════════════════════════════════════════════*/

    function _createAccount() internal returns (PasskeyAccount) {
        vm.prank(user);
        address account = factory.createAccount(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y, 0);
        return PasskeyAccount(payable(account));
    }

    /// @notice Configure a 2-of-3 M-of-N guardian set on the account (via self-calls).
    function _setupThreshold2of3(PasskeyAccount account) internal {
        vm.startPrank(address(account));
        account.addGuardian(guardianA);
        account.addGuardian(guardianB);
        account.addGuardian(guardianC);
        account.setRecoveryThreshold(2);
        vm.stopPrank();
    }

    /// @notice Create an account and configure a 2-of-3 guardian set.
    function _createAccountWithGuardians() internal returns (PasskeyAccount account) {
        account = _createAccount();
        _setupThreshold2of3(account);
    }

    function testAccountInitialization() public {
        PasskeyAccount account = _createAccount();

        assertEq(account.factory(), address(factory));
        // M-06/H-04: recovery disabled at init (no guardians, threshold 0). Legacy field is empty.
        assertEq(account.guardian(), address(0));
        assertEq(account.getGuardians().length, 0);
        assertEq(account.recoveryThreshold(), 0);
        assertGe(account.recoveryDelay(), 1 days); // MIN_RECOVERY_DELAY

        bytes32[] memory credIds = account.getCredentialIds();
        assertEq(credIds.length, 1);
        assertEq(credIds[0], CREDENTIAL_ID);

        IPasskeyAccount.PasskeyCredential memory cred = account.getCredential(CREDENTIAL_ID);
        assertEq(cred.publicKeyX, PUB_KEY_X);
        assertEq(cred.publicKeyY, PUB_KEY_Y);
        assertTrue(cred.active);
        assertEq(cred.signCount, 0);
    }

    function testAccountAddCredentialOnlySelf() public {
        PasskeyAccount account = _createAccount();

        // Try to add credential directly (should fail)
        vm.prank(user);
        vm.expectRevert(IPasskeyAccount.OnlySelf.selector);
        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, PUB_KEY_Y);
    }

    function testAccountAddCredentialViaSelf() public {
        PasskeyAccount account = _createAccount();

        // Simulate a self-call (would normally come from UserOp execution)
        vm.prank(address(account));

        vm.expectEmit(true, false, false, true);
        emit CredentialAdded(CREDENTIAL_ID_2, uint64(block.timestamp));

        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, PUB_KEY_Y);

        bytes32[] memory credIds = account.getCredentialIds();
        assertEq(credIds.length, 2);
    }

    function testAccountAddCredentialDuplicate() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.CredentialExists.selector);
        account.addCredential(CREDENTIAL_ID, PUB_KEY_X, PUB_KEY_Y);
    }

    function testAccountRemoveCredential() public {
        PasskeyAccount account = _createAccount();

        // Add a second credential first
        vm.prank(address(account));
        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, PUB_KEY_Y);

        // Now remove the first one
        vm.prank(address(account));

        vm.expectEmit(true, false, false, false);
        emit CredentialRemoved(CREDENTIAL_ID);

        account.removeCredential(CREDENTIAL_ID);

        bytes32[] memory credIds = account.getCredentialIds();
        assertEq(credIds.length, 1);
        assertEq(credIds[0], CREDENTIAL_ID_2);
    }

    function testAccountCannotRemoveLastCredential() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.CannotRemoveLastCredential.selector);
        account.removeCredential(CREDENTIAL_ID);
    }

    function testAccountSetCredentialActive() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));

        vm.expectEmit(true, false, false, true);
        emit CredentialStatusChanged(CREDENTIAL_ID, false);

        account.setCredentialActive(CREDENTIAL_ID, false);

        IPasskeyAccount.PasskeyCredential memory cred = account.getCredential(CREDENTIAL_ID);
        assertFalse(cred.active);
    }

    /*════════════════════════════════════════════════════════════════════
                    H-04: M-of-N GUARDIAN MANAGEMENT TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testAddGuardian() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectEmit(true, false, false, false);
        emit GuardianAdded(guardianA);
        account.addGuardian(guardianA);

        assertTrue(account.isGuardian(guardianA));
        assertEq(account.getGuardians().length, 1);
        assertEq(account.getGuardians()[0], guardianA);
    }

    function testAddGuardianOnlySelf() public {
        PasskeyAccount account = _createAccount();
        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.OnlySelf.selector);
        account.addGuardian(guardianA);
    }

    function testAddGuardianZeroReverts() public {
        PasskeyAccount account = _createAccount();
        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.ZeroAddress.selector);
        account.addGuardian(address(0));
    }

    function testAddGuardianDuplicateReverts() public {
        PasskeyAccount account = _createAccount();
        vm.startPrank(address(account));
        account.addGuardian(guardianA);
        vm.expectRevert(IPasskeyAccount.GuardianAlreadyExists.selector);
        account.addGuardian(guardianA);
        vm.stopPrank();
    }

    function testRemoveGuardian() public {
        PasskeyAccount account = _createAccountWithGuardians(); // 2-of-3

        vm.prank(address(account));
        vm.expectEmit(true, false, false, false);
        emit GuardianRemoved(guardianB);
        account.removeGuardian(guardianB);

        assertFalse(account.isGuardian(guardianB));
        assertEq(account.getGuardians().length, 2);
        // Threshold 2 still <= 2 guardians, so it is preserved.
        assertEq(account.recoveryThreshold(), 2);
    }

    function testRemoveGuardianOnlySelf() public {
        PasskeyAccount account = _createAccountWithGuardians();
        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.OnlySelf.selector);
        account.removeGuardian(guardianA);
    }

    function testRemoveNonexistentGuardianReverts() public {
        PasskeyAccount account = _createAccount();
        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.GuardianDoesNotExist.selector);
        account.removeGuardian(guardianA);
    }

    function testRemoveGuardianLowersThresholdBelowCount() public {
        PasskeyAccount account = _createAccountWithGuardians(); // 3 guardians, threshold 2

        // Remove two guardians -> count drops to 1, threshold auto-lowered to 1.
        vm.startPrank(address(account));
        account.removeGuardian(guardianA);
        vm.expectEmit(false, false, false, true);
        emit RecoveryThresholdUpdated(2, 1);
        account.removeGuardian(guardianB);
        vm.stopPrank();

        assertEq(account.getGuardians().length, 1);
        assertEq(account.recoveryThreshold(), 1);

        // Remove the last one -> threshold auto-lowered to 0 (recovery disabled).
        vm.prank(address(account));
        account.removeGuardian(guardianC);
        assertEq(account.getGuardians().length, 0);
        assertEq(account.recoveryThreshold(), 0);
    }

    function testSetRecoveryThreshold() public {
        PasskeyAccount account = _createAccount();
        vm.startPrank(address(account));
        account.addGuardian(guardianA);
        account.addGuardian(guardianB);
        vm.expectEmit(false, false, false, true);
        emit RecoveryThresholdUpdated(0, 2);
        account.setRecoveryThreshold(2);
        vm.stopPrank();
        assertEq(account.recoveryThreshold(), 2);
    }

    function testSetRecoveryThresholdOnlySelf() public {
        PasskeyAccount account = _createAccountWithGuardians();
        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.OnlySelf.selector);
        account.setRecoveryThreshold(1);
    }

    function testSetRecoveryThresholdExceedsCountReverts() public {
        PasskeyAccount account = _createAccount();
        vm.startPrank(address(account));
        account.addGuardian(guardianA);
        // Only 1 guardian; threshold of 2 must revert.
        vm.expectRevert(IPasskeyAccount.ThresholdExceedsGuardianCount.selector);
        account.setRecoveryThreshold(2);
        vm.stopPrank();
    }

    function testAccountSetRecoveryDelay() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        account.setRecoveryDelay(14 days);

        assertEq(account.recoveryDelay(), 14 days);
    }

    function testAccountSetRecoveryDelayMinimum() public {
        PasskeyAccount account = _createAccount();

        // Try to set below minimum - should be capped
        vm.prank(address(account));
        account.setRecoveryDelay(1 hours);

        assertEq(account.recoveryDelay(), 1 days); // MIN_RECOVERY_DELAY
    }

    /*════════════════════════════════════════════════════════════════════
                        H-04: M-of-N RECOVERY TESTS
    ════════════════════════════════════════════════════════════════════*/

    bytes32 constant REC_CRED = keccak256("recovery_credential");

    /// @notice Have two distinct guardians approve, staging the recovery, and return the recoveryId.
    /// @dev The recoveryId is deterministic: keccak256(proposalId, block.timestamp) at staging.
    function _stageRecovery(PasskeyAccount account, bytes32 credId, bytes32 x, bytes32 y)
        internal
        returns (bytes32 recoveryId)
    {
        vm.prank(guardianA);
        account.approveRecovery(credId, x, y);
        // Second distinct guardian approval reaches quorum and stages.
        vm.recordLogs();
        vm.prank(guardianB);
        account.approveRecovery(credId, x, y);
        bytes32 proposalId = account.computeRecoveryProposalId(credId, x, y);
        recoveryId = keccak256(abi.encodePacked(proposalId, block.timestamp));
    }

    function testApproveRecoveryDisabledWhenNoGuardians() public {
        PasskeyAccount account = _createAccount(); // no guardians configured

        // Even a would-be guardian is not registered; onlyGuardian fires first.
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.NotAGuardian.selector);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);
    }

    function testApproveRecoveryDisabledWithZeroThreshold() public {
        PasskeyAccount account = _createAccount();
        // Add guardians but leave threshold 0 -> recovery is DISABLED.
        vm.startPrank(address(account));
        account.addGuardian(guardianA);
        account.addGuardian(guardianB);
        vm.stopPrank();

        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.RecoveryDisabled.selector);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);
    }

    function testApproveRecoveryUnauthorized() public {
        PasskeyAccount account = _createAccountWithGuardians();
        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.NotAGuardian.selector);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);
    }

    /// @notice H-04 CORE: a single guardian cannot stage/complete a recovery under threshold 2.
    function testSingleGuardianCannotCompleteRecovery() public {
        PasskeyAccount account = _createAccountWithGuardians(); // 2-of-3

        // One guardian approves — this must NOT stage the recovery.
        vm.prank(guardianA);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);

        bytes32 proposalId = account.computeRecoveryProposalId(REC_CRED, CURVE_X, CURVE_Y);
        assertEq(account.recoveryApprovalCount(proposalId), 1);

        // No recovery request exists yet: the deterministic recoveryId is not staged.
        bytes32 wouldBeId = keccak256(abi.encodePacked(proposalId, block.timestamp));
        IPasskeyAccount.RecoveryRequest memory req = account.getRecoveryRequest(wouldBeId);
        assertEq(req.executeAfter, 0, "single approval must not stage recovery");

        // Attempting to complete reverts (nothing pending).
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(wouldBeId);
    }

    /// @notice H-04 CORE: a guardian cannot approve twice to fake quorum.
    function testGuardianCannotApproveTwice() public {
        PasskeyAccount account = _createAccountWithGuardians(); // 2-of-3

        vm.prank(guardianA);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);

        // Same guardian approving again must revert; quorum (2) still not reached.
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.AlreadyApproved.selector);
        account.approveRecovery(REC_CRED, CURVE_X, CURVE_Y);

        bytes32 proposalId = account.computeRecoveryProposalId(REC_CRED, CURVE_X, CURVE_Y);
        assertEq(account.recoveryApprovalCount(proposalId), 1, "double approve must not increment");
    }

    /// @notice H-04 CORE: two DISTINCT guardians stage the recovery; after delay it finalizes.
    function testTwoGuardiansStageAndComplete() public {
        PasskeyAccount account = _createAccountWithGuardians(); // 2-of-3

        bytes32 recoveryId = _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);

        // Recovery is now staged.
        IPasskeyAccount.RecoveryRequest memory req = account.getRecoveryRequest(recoveryId);
        assertTrue(req.executeAfter > 0, "quorum should stage recovery");

        // Cannot complete before the delay.
        vm.expectRevert(IPasskeyAccount.RecoveryDelayNotPassed.selector);
        account.completeRecovery(recoveryId);

        // After the delay, anyone can finalize.
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectEmit(true, true, false, false);
        emit RecoveryCompleted(recoveryId, REC_CRED);
        account.completeRecovery(recoveryId);

        IPasskeyAccount.PasskeyCredential memory cred = account.getCredential(REC_CRED);
        assertEq(cred.publicKeyX, CURVE_X);
        assertEq(cred.publicKeyY, CURVE_Y);
        assertTrue(cred.active);
    }

    /// @notice H-04 hardening: an off-curve recovery key is rejected before staging.
    function testApproveRecoveryOffCurveKeyReverts() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // keccak-derived coordinates are (almost surely) not on the P-256 curve.
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.InvalidPublicKey.selector);
        account.approveRecovery(REC_CRED, keccak256("off_x"), keccak256("off_y"));
    }

    function testApproveRecoveryZeroKeyReverts() public {
        PasskeyAccount account = _createAccountWithGuardians();
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        account.approveRecovery(REC_CRED, bytes32(0), CURVE_Y);
    }

    function testApproveRecoveryExistingCredentialReverts() public {
        PasskeyAccount account = _createAccountWithGuardians();
        // CREDENTIAL_ID already exists on the account.
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.CredentialExists.selector);
        account.approveRecovery(CREDENTIAL_ID, CURVE_X, CURVE_Y);
    }

    /// @notice After a completed recovery, the approval accounting is reset (fresh future recovery).
    function testApprovalsResetAfterStaging() public {
        PasskeyAccount account = _createAccountWithGuardians();
        _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);
        bytes32 proposalId = account.computeRecoveryProposalId(REC_CRED, CURVE_X, CURVE_Y);
        assertEq(account.recoveryApprovalCount(proposalId), 0, "approvals cleared after staging");
        assertFalse(account.hasApprovedRecovery(proposalId, guardianA));
        assertFalse(account.hasApprovedRecovery(proposalId, guardianB));
    }

    function testCancelRecoveryByGuardian() public {
        PasskeyAccount account = _createAccountWithGuardians();
        bytes32 recoveryId = _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);

        vm.prank(guardianA);
        vm.expectEmit(true, false, false, false);
        emit RecoveryCancelled(recoveryId);
        account.cancelRecovery(recoveryId);

        IPasskeyAccount.RecoveryRequest memory request = account.getRecoveryRequest(recoveryId);
        assertTrue(request.cancelled);
    }

    function testCancelRecoveryBySelf() public {
        PasskeyAccount account = _createAccountWithGuardians();
        bytes32 recoveryId = _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);

        vm.prank(address(account));
        account.cancelRecovery(recoveryId);

        IPasskeyAccount.RecoveryRequest memory request = account.getRecoveryRequest(recoveryId);
        assertTrue(request.cancelled);
    }

    function testCancelRecoveryUnauthorized() public {
        PasskeyAccount account = _createAccountWithGuardians();
        bytes32 recoveryId = _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);

        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.OnlyGuardianOrSelf.selector);
        account.cancelRecovery(recoveryId);
    }

    /*════════════════════════════════════════════════════════════════════
                        EXECUTION TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testExecuteFromSelf() public {
        PasskeyAccount account = _createAccount();

        // Fund the account
        vm.deal(address(account), 1 ether);

        address recipient = address(0x999);
        uint256 amount = 0.1 ether;

        vm.prank(address(account));
        account.execute(recipient, amount, "");

        assertEq(recipient.balance, amount);
    }

    function testExecuteUnauthorized() public {
        PasskeyAccount account = _createAccount();

        vm.deal(address(account), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(IPasskeyAccount.OnlySelf.selector);
        account.execute(address(0x999), 0.1 ether, "");
    }

    function testExecuteBatch() public {
        PasskeyAccount account = _createAccount();

        vm.deal(address(account), 1 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);

        targets[0] = address(0x111);
        targets[1] = address(0x222);
        values[0] = 0.1 ether;
        values[1] = 0.2 ether;
        datas[0] = "";
        datas[1] = "";

        vm.prank(address(account));
        account.executeBatch(targets, values, datas);

        assertEq(address(0x111).balance, 0.1 ether);
        assertEq(address(0x222).balance, 0.2 ether);
    }

    function testExecuteBatchLengthMismatch() public {
        PasskeyAccount account = _createAccount();

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1); // Mismatched
        bytes[] memory datas = new bytes[](2);

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.ArrayLengthMismatch.selector);
        account.executeBatch(targets, values, datas);
    }

    function testReceiveEth() public {
        PasskeyAccount account = _createAccount();

        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(account).call{value: 0.5 ether}("");

        assertTrue(success);
        assertEq(address(account).balance, 0.5 ether);
    }

    /*════════════════════════════════════════════════════════════════════
                        GLOBAL CREDENTIAL LIMIT TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testMaxCredentialsGlobal() public {
        // Update global config to have max 2 credentials
        vm.prank(owner);
        factory.setMaxCredentials(2);

        PasskeyAccount account = _createAccount();

        // Add second credential (should work)
        vm.prank(address(account));
        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, PUB_KEY_Y);

        // Try to add third credential (should fail)
        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.MaxCredentialsReached.selector);
        account.addCredential(keccak256("cred3"), PUB_KEY_X, PUB_KEY_Y);
    }

    /*════════════════════════════════════════════════════════════════════
                        QUICK JOIN PASSKEY TESTS
    ════════════════════════════════════════════════════════════════════*/

    function _setupQuickJoin() internal returns (QuickJoin) {
        vm.startPrank(owner);

        // Deploy QuickJoin
        quickJoinImpl = new QuickJoin();
        quickJoinBeacon = new UpgradeableBeacon(address(quickJoinImpl), owner);

        uint256[] memory memberHatIds = new uint256[](0);

        bytes memory qjInitData = abi.encodeWithSelector(
            QuickJoin.initialize.selector,
            owner, // hats
            address(accountRegistry), // account registry
            owner
        );

        quickJoin = QuickJoin(address(new BeaconProxy(address(quickJoinBeacon), qjInitData)));

        // Configure universal passkey factory in QuickJoin
        quickJoin.setUniversalFactory(address(factory));
        quickJoin.setMembershipAuthority(address(new MockModuleAuthority(address(hats), owner)));

        vm.stopPrank();

        return quickJoin;
    }

    function testQuickJoinWithPasskeyMasterDeploy() public {
        QuickJoin qj = _setupQuickJoin();

        vm.prank(owner); // Master deploy address

        QuickJoin.PasskeyEnrollment memory enrollment = QuickJoin.PasskeyEnrollment({
            credentialId: CREDENTIAL_ID, publicKeyX: PUB_KEY_X, publicKeyY: PUB_KEY_Y, salt: 0
        });

        address account = qj.quickJoinWithPasskeyMasterDeploy(enrollment);

        assertTrue(account != address(0));
        assertTrue(factory.isDeployedAccount(account));
    }

    function testQuickJoinWithPasskeyMasterDeployUnauthorized() public {
        QuickJoin qj = _setupQuickJoin();

        vm.prank(attacker);

        QuickJoin.PasskeyEnrollment memory enrollment = QuickJoin.PasskeyEnrollment({
            credentialId: CREDENTIAL_ID, publicKeyX: PUB_KEY_X, publicKeyY: PUB_KEY_Y, salt: 0
        });

        vm.expectRevert(QuickJoin.OnlyMasterDeploy.selector);
        qj.quickJoinWithPasskeyMasterDeploy(enrollment);
    }

    /*════════════════════════════════════════════════════════════════════
                        WEBAUTHN LIBRARY TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testWebAuthnAuthDataTooShort() public view {
        WebAuthnLib.WebAuthnAuth memory auth = WebAuthnLib.WebAuthnAuth({
            authenticatorData: new bytes(30), // Too short (min is 37)
            clientDataJSON: new bytes(0),
            challengeIndex: 0,
            typeIndex: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        bool valid = WebAuthnLib.verify(auth, bytes32(0), PUB_KEY_X, PUB_KEY_Y, false);

        assertFalse(valid);
    }

    function testWebAuthnUserNotPresent() public view {
        // Create auth data with UP flag NOT set
        bytes memory authData = new bytes(37);
        // flags byte at index 32, UP flag is bit 0
        authData[32] = 0x00; // No flags set

        WebAuthnLib.WebAuthnAuth memory auth = WebAuthnLib.WebAuthnAuth({
            authenticatorData: authData,
            clientDataJSON: new bytes(100),
            challengeIndex: 0,
            typeIndex: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        bool valid = WebAuthnLib.verify(auth, bytes32(0), PUB_KEY_X, PUB_KEY_Y, false);

        assertFalse(valid);
    }

    /*════════════════════════════════════════════════════════════════════
                        VIEW FUNCTION TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testGetMaxCredentials() public view {
        PasskeyAccountFactory.GlobalConfig memory config = factory.getGlobalConfig();
        assertEq(config.maxCredentialsPerAccount, 10); // Default
    }

    function testQuickJoinViewFunctions() public {
        QuickJoin qj = _setupQuickJoin();

        assertEq(address(qj.universalFactory()), address(factory));
    }

    /*════════════════════════════════════════════════════════════════════
                        EDGE CASES AND SECURITY TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testFactoryInitializeZeroPoaManager() public {
        vm.expectRevert(PasskeyAccountFactory.ZeroAddress.selector);
        new BeaconProxy(
            address(factoryBeacon),
            abi.encodeWithSelector(
                PasskeyAccountFactory.initialize.selector,
                address(0), // Zero poaManager
                address(accountBeacon),
                guardian,
                uint48(7 days)
            )
        );
    }

    function testFactoryInitializeZeroBeacon() public {
        vm.expectRevert(PasskeyAccountFactory.ZeroAddress.selector);
        new BeaconProxy(
            address(factoryBeacon),
            abi.encodeWithSelector(
                PasskeyAccountFactory.initialize.selector,
                owner,
                address(0), // Zero beacon
                guardian,
                uint48(7 days)
            )
        );
    }

    function testAccountInitializeZeroFactory() public {
        // M-06: initialize no longer takes guardian/recoveryDelay.
        bytes memory initData = abi.encodeWithSelector(
            PasskeyAccount.initialize.selector,
            address(0), // Zero factory
            CREDENTIAL_ID,
            PUB_KEY_X,
            PUB_KEY_Y
        );

        vm.expectRevert(IPasskeyAccount.ZeroAddress.selector);
        new BeaconProxy(address(accountBeacon), initData);
    }

    function testAccountInitializeZeroPubKey() public {
        bytes memory initData = abi.encodeWithSelector(
            PasskeyAccount.initialize.selector,
            address(factory),
            CREDENTIAL_ID,
            bytes32(0), // Zero public key X
            PUB_KEY_Y
        );

        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        new BeaconProxy(address(accountBeacon), initData);
    }

    function testRemoveCredentialNotFound() public {
        PasskeyAccount account = _createAccount();

        // Add second credential so we can attempt removal
        vm.prank(address(account));
        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, PUB_KEY_Y);

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.CredentialNotFound.selector);
        account.removeCredential(keccak256("nonexistent"));
    }

    function testSetCredentialActiveNotFound() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.CredentialNotFound.selector);
        account.setCredentialActive(keccak256("nonexistent"), false);
    }

    function testInitiateRecoveryExistingCredential() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // Try to approve recovery with existing credential ID
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.CredentialExists.selector);
        account.approveRecovery(CREDENTIAL_ID, CURVE_X, CURVE_Y);
    }

    function testCompleteRecoveryNotPending() public {
        PasskeyAccount account = _createAccount();

        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(keccak256("nonexistent_recovery"));
    }

    function testCompleteCancelledRecovery() public {
        PasskeyAccount account = _createAccountWithGuardians();

        bytes32 recoveryId = _stageRecovery(account, REC_CRED, CURVE_X, CURVE_Y);

        // Cancel the recovery (guardian).
        vm.prank(guardianA);
        account.cancelRecovery(recoveryId);

        // Try to complete after cancelled
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(recoveryId);
    }

    function testCancelRecoveryNotPending() public {
        PasskeyAccount account = _createAccountWithGuardians();

        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.cancelRecovery(keccak256("nonexistent_recovery"));
    }

    function testMultipleCredentials() public {
        PasskeyAccount account = _createAccount();

        // Add more credentials
        vm.startPrank(address(account));
        account.addCredential(keccak256("cred2"), PUB_KEY_X, PUB_KEY_Y);
        account.addCredential(keccak256("cred3"), PUB_KEY_X, PUB_KEY_Y);
        vm.stopPrank();

        // Verify total credentials
        assertEq(account.getCredentialIds().length, 3);
    }

    /*════════════════════════════════════════════════════════════════════
                    QUICKJOIN DUPLICATE ACCOUNT TESTS
    ════════════════════════════════════════════════════════════════════*/

    /*════════════════════════════════════════════════════════════════════
                    STORAGE SLOT VERIFICATION TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testStorageSlotCorrectness() public pure {
        // Verify PasskeyAccountFactory storage slot matches keccak256("poa.passkeyaccountfactory.storage")
        bytes32 expectedFactorySlot = keccak256("poa.passkeyaccountfactory.storage");
        assertEq(expectedFactorySlot, 0x827e9908968f666e42b67f932c7b1de44a3c55e267a1f6ed05a8d68576716a25);

        // Verify PasskeyAccount storage slot matches keccak256("poa.passkeyaccount.storage")
        bytes32 expectedAccountSlot = keccak256("poa.passkeyaccount.storage");
        assertEq(expectedAccountSlot, 0x7cfc8294c1be3fa32b08d50f0668cc2726e1306f195499e2d5283b8967b03fef);
    }

    /*════════════════════════════════════════════════════════════════════
                    P256 VERIFIER OPTIMIZATION TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testP256VerifierWithHint() public view {
        // Test verifyWithHint function
        bytes32 testHash = bytes32(uint256(1));
        bytes32 r = bytes32(uint256(2));
        bytes32 s = bytes32(uint256(3));

        // With hasPrecompile = true, should use precompile path
        bool result = P256Verifier.verifyWithHint(testHash, r, s, PUB_KEY_X, PUB_KEY_Y, true);
        // Result depends on whether precompile exists and if signature is valid
        console.log("verifyWithHint (precompile=true):", result);

        // With hasPrecompile = false, should use fallback path
        result = P256Verifier.verifyWithHint(testHash, r, s, PUB_KEY_X, PUB_KEY_Y, false);
        console.log("verifyWithHint (precompile=false):", result);
    }

    function testP256VerifierPrecompileAvailable() public view {
        bool available = P256Verifier.isPrecompileAvailable();
        console.log("P256 precompile available:", available);

        uint256 estimatedGas = P256Verifier.estimateVerificationGas();
        console.log("Estimated verification gas:", estimatedGas);

        if (available) {
            // Should return precompile gas cost
            assertTrue(estimatedGas == 6900 || estimatedGas == 3450);
        } else {
            // Should return fallback gas cost
            assertEq(estimatedGas, 350000);
        }
    }

    function testP256VerifierValidationHelpers() public pure {
        // Test isValidPublicKey with a real NIST P-256 test vector (on-curve point)
        bytes32 validX = 0x1ccbe91c075fc7f4f033bfa248db8fccd3565de94bbfb12f3c59ff46c271bf83;
        bytes32 validY = 0xce4014c68811f9a21a1fdb2c0e6113e06db7ca93b7404e78dc7ccd5ca89a4ca9;
        assertTrue(P256Verifier.isValidPublicKey(validX, validY));
        assertFalse(P256Verifier.isValidPublicKey(bytes32(0), validY));
        assertFalse(P256Verifier.isValidPublicKey(validX, bytes32(0)));

        // Test isValidSignature
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        assertTrue(P256Verifier.isValidSignature(r, s));
        assertFalse(P256Verifier.isValidSignature(bytes32(0), s));
        assertFalse(P256Verifier.isValidSignature(r, bytes32(0)));
    }

    /*════════════════════════════════════════════════════════════════════
                    ZERO PUBKEY VALIDATION TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testAddCredentialZeroPubKeyXReverts() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        account.addCredential(CREDENTIAL_ID_2, bytes32(0), PUB_KEY_Y);
    }

    function testAddCredentialZeroPubKeyYReverts() public {
        PasskeyAccount account = _createAccount();

        vm.prank(address(account));
        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        account.addCredential(CREDENTIAL_ID_2, PUB_KEY_X, bytes32(0));
    }

    function testInitiateRecoveryZeroPubKeyXReverts() public {
        PasskeyAccount account = _createAccountWithGuardians();

        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        account.approveRecovery(keccak256("new_cred"), bytes32(0), PUB_KEY_Y);
    }

    function testInitiateRecoveryZeroPubKeyYReverts() public {
        PasskeyAccount account = _createAccountWithGuardians();

        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.InvalidSignature.selector);
        account.approveRecovery(keccak256("new_cred"), PUB_KEY_X, bytes32(0));
    }

    /*════════════════════════════════════════════════════════════════════
                RECOVERY EDGE CASE & CREDENTIAL INTEGRITY TESTS
    ════════════════════════════════════════════════════════════════════*/

    function testCompleteCancelledRecovery_Reverts() public {
        PasskeyAccount account = _createAccountWithGuardians();

        bytes32 recoveryCredId = keccak256("cancelled_cred");
        bytes32 recoveryId = _stageRecovery(account, recoveryCredId, CURVE_X, CURVE_Y);

        // Cancel the recovery
        vm.prank(guardianA);
        account.cancelRecovery(recoveryId);

        // Warp past delay
        vm.warp(block.timestamp + 7 days + 1);

        // Attempt to complete cancelled recovery
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(recoveryId);
    }

    function testRecoveryNonExistentRecoveryId_Reverts() public {
        PasskeyAccount account = _createAccount();

        bytes32 fakeRecoveryId = keccak256("nonexistent");
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(fakeRecoveryId);
    }

    function testInitiateRecoveryForExistingCredential_Reverts() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // Try to approve recovery for a credential that already exists (created with the account)
        vm.prank(guardianA);
        vm.expectRevert(IPasskeyAccount.CredentialExists.selector);
        account.approveRecovery(CREDENTIAL_ID, CURVE_X, CURVE_Y);
    }

    function testRecoveryCredentialArrayIntegrity() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // Recover a credential (2-of-3 quorum).
        bytes32 recoveryCredId = keccak256("integrity_check");
        bytes32 recoveryId = _stageRecovery(account, recoveryCredId, CURVE_X, CURVE_Y);

        vm.warp(block.timestamp + 7 days + 1);
        account.completeRecovery(recoveryId);

        // Recovery now fully replaces all credentials (prevents unbounded array growth)
        bytes32[] memory credIds = account.getCredentialIds();
        assertEq(credIds.length, 1, "Recovery should leave exactly 1 credential");
        assertEq(credIds[0], recoveryCredId, "Only the recovery credential should remain");

        // Original credential should be fully deleted (not just deactivated)
        IPasskeyAccount.PasskeyCredential memory origCred = account.getCredential(CREDENTIAL_ID);
        assertEq(origCred.createdAt, 0, "Original credential should be deleted after recovery");

        // Recovery credential should be active
        IPasskeyAccount.PasskeyCredential memory recoveryCred = account.getCredential(recoveryCredId);
        assertTrue(recoveryCred.active, "Recovery credential should be active");
    }

    // ──────── M-02 Fix: Simultaneous recovery race condition ────────

    function testCompletingRecoveryCancelsOtherPendingRecoveries() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // Stage two recovery requests (via quorum) with different credentials.
        // Same on-curve key is reused with a distinct credentialId (address is per-credential).
        bytes32 credA = keccak256("recovery_A");
        bytes32 credB = keccak256("recovery_B");

        bytes32 recoveryIdA = _stageRecovery(account, credA, CURVE_X, CURVE_Y);

        vm.warp(block.timestamp + 1); // different timestamp for a unique recovery ID
        bytes32 recoveryIdB = _stageRecovery(account, credB, CURVE_X, CURVE_Y);

        // Both recoveries should be pending
        IPasskeyAccount.RecoveryRequest memory reqA = account.getRecoveryRequest(recoveryIdA);
        IPasskeyAccount.RecoveryRequest memory reqB = account.getRecoveryRequest(recoveryIdB);
        assertTrue(reqA.executeAfter > 0, "Recovery A should be pending");
        assertTrue(reqB.executeAfter > 0, "Recovery B should be pending");

        // Warp past both delays
        vm.warp(block.timestamp + 7 days + 1);

        // Complete recovery A
        account.completeRecovery(recoveryIdA);

        // Verify credential A is active
        bytes32[] memory credIds = account.getCredentialIds();
        assertEq(credIds.length, 1, "Should have exactly 1 credential after recovery");
        assertEq(credIds[0], credA, "Should be credA");

        // Recovery B should now be cancelled
        IPasskeyAccount.RecoveryRequest memory reqBAfter = account.getRecoveryRequest(recoveryIdB);
        assertTrue(reqBAfter.cancelled, "Recovery B should be cancelled after A completes");

        // Attempting to complete recovery B should revert
        vm.expectRevert(IPasskeyAccount.RecoveryNotPending.selector);
        account.completeRecovery(recoveryIdB);
    }

    function testRepeatedRecoveriesDoNotGrowArray() public {
        PasskeyAccount account = _createAccountWithGuardians();

        // Perform 5 sequential recoveries. Each reuses the on-curve key with a distinct credentialId.
        for (uint256 round = 1; round <= 5; round++) {
            bytes32 newCredId = keccak256(abi.encodePacked("recovery_round_", round));

            bytes32 recoveryId = _stageRecovery(account, newCredId, CURVE_X, CURVE_Y);

            vm.warp(block.timestamp + 7 days + 1);
            account.completeRecovery(recoveryId);

            // After each recovery, array should have exactly 1 credential
            bytes32[] memory credIds = account.getCredentialIds();
            assertEq(credIds.length, 1, "Array must stay at length 1 after each recovery");
            assertEq(credIds[0], newCredId, "Should be the latest recovery credential");
        }
    }
}
