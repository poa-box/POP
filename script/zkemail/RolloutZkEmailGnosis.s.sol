// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {ZkEmailProof, IZkEmailGroth16Verifier, IZkEmailGroth16VerifierV2} from "../../src/zkemail/IVerifier.sol";
import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {IExecutor} from "../../src/Executor.sol";
import {Executor} from "../../src/Executor.sol";
import {OrgDeployer} from "../../src/OrgDeployer.sol";
import {ModulesFactory} from "../../src/factories/ModulesFactory.sol";
import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";

/*
 * ============================================================================
 * FULL ROLLOUT SIM — ZK Email invites onto live Test6 (Gnosis fork)
 * ============================================================================
 *
 * Chains EVERY step of the production rollout end-to-end on a real Gnosis fork, in order, and
 * asserts each effect against live state:
 *
 *   1. Deploy the REAL ZK crypto infra (Groth16Verifier + Groth16VerifierV2 + PoaDKIMRegistry) and
 *      prove BOTH real verifiers execute the pairing check (reject a bogus proof).
 *   2. Upgrade the OrgDeployer beacon, repoint the ModulesFactory, register the ZkEmailInvites beacon.
 *   3. Upgrade the Executor beacon (reaches Test6 via its Mirror-mode SwitchableBeacon).
 *   4. Wire BOTH verifiers + the registry into the OrgDeployer (setZkEmailInfrastructure).
 *   5. Deploy Test6's ZkEmailInvites proxy (real verifiers + registry; dormant at init).
 *   6. Whitelist the 4 claim selectors on the real PaymasterHub (gasless).
 *   7. Authorize the proxy as a hat minter AND activate the org's allowlist root through the REAL
 *      upgraded Executor, via the exact call announceWinner makes — executor.execute(batch) pranked
 *      as the org's allowedCaller (HybridVoting), self-targeting setHatMinterAuthorization (impossible
 *      before the Executor upgrade) plus calling setActiveAllowlist on the proxy.
 *   8. Prove the REAL verifier guards the claim entrypoint: a bogus proof reverts InvalidProof.
 *   9. Drive a successful claim end-to-end (verifier boundary = the off-chain proving step, mocked) and
 *      confirm REAL Hats mints the Member hat to the claimer.
 *
 * Allowlist model: a single-leaf allowlist (root == leaf, empty merkle proof) — INVITE_DOMAIN -> Member
 * hat. That's the simplest valid OZ StandardMerkleTree proof; production roots commit a full JSON file.
 *
 * The ONLY thing not real is generating a valid Groth16 proof — that's an off-chain proving step
 * (a real .eml + proving key), not something Foundry can do. Phase 1 proves the real verifiers run
 * and reject invalid proofs; phase 8 proves it guards the actual claim; phase 9 mocks ONLY that final
 * accept to exercise the full mint + gasless path.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/RolloutZkEmailGnosis.s.sol:SimRolloutGnosis --fork-url gnosis -vvv
 * ============================================================================
 */

interface ISatelliteR {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function addContractType(string calldata typeName, address impl) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewR {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IPaymasterHubRuleR {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function getRule(bytes32 orgId, address target, bytes4 sel) external view returns (Rule memory);
}

interface IEligibilityR {
    function setWearerEligibility(address wearer, uint256 hatId, bool eligible, bool standing) external;
}

interface IHatsLikeR {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
}

contract SimMockVerifierR is IZkEmailGroth16Verifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

contract SimMockVerifierV2R is IZkEmailGroth16VerifierV2 {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

contract SimRolloutGnosis is Script {
    /* ── Verified Gnosis + Test6 addresses ── */
    address constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;
    address constant PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    bytes32 constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
    address constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    address constant TEST6_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
    uint256 constant TEST6_MEMBER_HAT = 29035862971903655586674243772344327311664727652070589302159213246545920;

    string constant INVITE_DOMAIN = "gmail.com";
    bytes32 constant SIM_ALLOWLIST_CID = bytes32(uint256(0xC1D));
    uint8 constant LEAF_DOMAIN = 0;
    string constant VERSION = "v-zkemail-1";
    bytes32 constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 constant OD_SLOT = keccak256("poa.orgdeployer.storage");
    bytes32 constant EXEC_SLOT = keccak256("poa.executor.storage");

    bytes4 constant SEL_CLAIM_DOMAIN = bytes4(
        keccak256(
            "claimRoleByDomain((uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,string),address,uint256[],bytes32[])"
        )
    );
    bytes4 constant SEL_CLAIM_EMAIL = bytes4(
        keccak256(
            "claimRoleByEmail((uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,string,bytes32),address,uint256[],bytes32[])"
        )
    );
    bytes4 constant SEL_REG_CLAIM_DOMAIN = bytes4(
        keccak256(
            "registerAndClaimByDomainWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,string),uint256[],bytes32[])"
        )
    );
    bytes4 constant SEL_REG_CLAIM_EMAIL = bytes4(
        keccak256(
            "registerAndClaimByEmailWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(uint256[2],uint256[2][2],uint256[2],bytes32,bytes32,string,bytes32),uint256[],bytes32[])"
        )
    );

    /* ── State threaded across phases ── */
    Groth16Verifier domainVerifier;
    Groth16VerifierV2 emailVerifier;
    PoaDKIMRegistry registry;
    ZkEmailInvites proxy;
    bytes32 dkimKeyHash;
    address claimer;

    function run() public {
        console.log("\n=== FULL ROLLOUT SIM: ZK Email -> live Test6 (Gnosis) ===");
        require(ISatelliteR(SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");
        dkimKeyHash = keccak256("rollout-sim-dkim-key");
        claimer = makeAddr("zk-rollout-claimer");

        _phase1DeployInfra();
        _phase2UpgradeOrgDeployer();
        _phase3UpgradeExecutor();
        _phase4Wire();
        _phase5DeployProxy();
        _phase6Paymaster();
        _phase7AuthorizeAndActivate();
        _phase8RealVerifierGuards();
        _phase9Claim();

        console.log("\nPASS: full ZK Email rollout verified end-to-end on a real Gnosis fork.");
    }

    /* ─── 1. Deploy real crypto infra ─── */
    function _phase1DeployInfra() internal {
        domainVerifier = new Groth16Verifier();
        emailVerifier = new Groth16VerifierV2();
        registry = new PoaDKIMRegistry(HUDSON);

        ZkEmailProof memory bogus = _bogusProof();
        uint256[3] memory dSignals =
            [uint256(bogus.pubkeyHash), uint256(bogus.emailNullifier), uint256(uint160(address(0)))];
        uint256[4] memory eSignals =
            [uint256(bogus.pubkeyHash), uint256(bogus.emailNullifier), uint256(uint160(address(0))), uint256(0xE)];
        // Cap gas forwarded to each pairing check. A real Groth16 verify is ~250k gas; forge's script
        // executor otherwise forwards the whole frame to the bn256 precompiles, starving later phases'
        // deploys (OOG). 10M is a generous ceiling that still leaves the script budget intact.
        require(!_verifyDomainBogus(bogus, dSignals), "real domain verifier accepted a bogus proof!");
        require(!_verifyEmailBogus(bogus, eSignals), "real email verifier accepted a bogus proof!");
        console.log("[1] Real infra deployed; both verifiers rejected bogus proofs. Domain:", address(domainVerifier));
        console.log("    Email verifier:", address(emailVerifier));
    }

    function _verifyDomainBogus(ZkEmailProof memory bogus, uint256[3] memory signals) internal view returns (bool ok) {
        ok = domainVerifier.verifyProof{gas: 10_000_000}(bogus.pA, bogus.pB, bogus.pC, signals);
    }

    function _verifyEmailBogus(ZkEmailProof memory bogus, uint256[4] memory signals) internal view returns (bool ok) {
        ok = emailVerifier.verifyProof{gas: 10_000_000}(bogus.pA, bogus.pB, bogus.pC, signals);
    }

    /* ─── 2. Upgrade OrgDeployer + register ZkEmailInvites beacon ─── */
    function _phase2UpgradeOrgDeployer() internal {
        address newMF = address(new ModulesFactory());
        address newOD = address(new OrgDeployer());
        address zkImpl = address(new ZkEmailInvites());

        vm.startPrank(HUDSON);
        ISatelliteR(SATELLITE).upgradeBeaconDirect("OrgDeployer", newOD, VERSION);
        ISatelliteR(SATELLITE).adminCall(ORG_DEPLOYER, abi.encodeWithSignature("setModulesFactory(address)", newMF));
        ISatelliteR(SATELLITE).addContractType("ZkEmailInvites", zkImpl);
        vm.stopPrank();

        require(
            IPoaManagerViewR(POA_MANAGER).getCurrentImplementationById(keccak256("OrgDeployer")) == newOD,
            "OrgDeployer not upgraded"
        );
        require(
            IPoaManagerViewR(POA_MANAGER).getBeaconById(keccak256("ZkEmailInvites")) != address(0),
            "beacon not registered"
        );
        console.log("[2] OrgDeployer upgraded, factory repointed, ZkEmailInvites beacon registered.");
    }

    /* ─── 3. Upgrade Executor (reaches Test6 via Mirror) ─── */
    function _phase3UpgradeExecutor() internal {
        address newExec = address(new Executor());
        vm.prank(HUDSON);
        ISatelliteR(SATELLITE).upgradeBeaconDirect("Executor", newExec, VERSION);

        address test6Beacon = address(uint160(uint256(vm.load(TEST6_EXECUTOR, BEACON_SLOT))));
        (bool ok, bytes memory ret) = test6Beacon.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && abi.decode(ret, (address)) == newExec, "Test6 executor did not follow beacon");
        console.log("[3] Executor upgraded; Test6 executor (Mirror) now on new impl.");
    }

    /* ─── 4. Wire infra into OrgDeployer ─── */
    function _phase4Wire() internal {
        vm.prank(HUDSON);
        ISatelliteR(SATELLITE)
            .adminCall(
                ORG_DEPLOYER,
                abi.encodeWithSignature(
                    "setZkEmailInfrastructure(address,address,address)",
                    address(domainVerifier),
                    address(emailVerifier),
                    address(registry)
                )
            );
        // OrgDeployer.Layout: ... hatsV2(9), zkEmailDomainVerifier(10), zkEmailEmailVerifier(11), dkim(12).
        address wiredDomain = address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_SLOT) + 10)))));
        address wiredEmail = address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_SLOT) + 11)))));
        require(wiredDomain == address(domainVerifier), "domain verifier not wired into OrgDeployer");
        require(wiredEmail == address(emailVerifier), "email verifier not wired into OrgDeployer");
        console.log("[4] setZkEmailInfrastructure wired both verifiers + registry into OrgDeployer.");
    }

    /* ─── 5. Deploy Test6 proxy (real verifiers + registry, dormant at init) ─── */
    function _phase5DeployProxy() internal {
        address zkBeacon = IPoaManagerViewR(POA_MANAGER).getBeaconById(keccak256("ZkEmailInvites"));
        SwitchableBeacon sb = new SwitchableBeacon(TEST6_EXECUTOR, zkBeacon, address(0), SwitchableBeacon.Mode.Mirror);
        proxy = ZkEmailInvites(address(new BeaconProxy(address(sb), _initData())));

        require(proxy.executor() == TEST6_EXECUTOR, "executor not wired");
        require(address(proxy.domainVerifier()) == address(domainVerifier), "domain verifier not wired");
        require(address(proxy.emailVerifier()) == address(emailVerifier), "email verifier not wired");
        require(proxy.merkleRoot() == bytes32(0), "should be dormant until governance activation");
        console.log("[5] Test6 ZkEmailInvites proxy deployed (dormant, real verifiers):", address(proxy));
    }

    /* ─── 6. Whitelist paymaster selectors ─── */
    function _phase6Paymaster() internal {
        vm.prank(HUDSON);
        ISatelliteR(SATELLITE).adminCall(PAYMASTER, _paymasterInner(address(proxy)));
        IPaymasterHubRuleR.Rule memory r =
            IPaymasterHubRuleR(PAYMASTER).getRule(TEST6_ORG, address(proxy), SEL_CLAIM_DOMAIN);
        require(r.allowed && r.maxCallGasHint == 800_000, "claim rule not set");
        require(
            IPaymasterHubRuleR(PAYMASTER).getRule(TEST6_ORG, address(proxy), SEL_CLAIM_EMAIL).allowed,
            "email claim rule not set"
        );
        console.log("[6] Paymaster: 4 claim selectors whitelisted (gasless).");
    }

    /* ─── 7. Authorize minter + activate allowlist through the REAL upgraded Executor ─── */
    function _phase7AuthorizeAndActivate() internal {
        IExecutor.Call[] memory batch = new IExecutor.Call[](2);
        batch[0] = IExecutor.Call({
            target: TEST6_EXECUTOR,
            value: 0,
            data: abi.encodeWithSignature("setHatMinterAuthorization(address,bool)", address(proxy), true)
        });
        batch[1] = IExecutor.Call({
            target: address(proxy),
            value: 0,
            data: abi.encodeCall(ZkEmailInvites.setActiveAllowlist, (_domainRoot(), SIM_ALLOWLIST_CID))
        });
        // This is exactly the call announceWinner makes: executor.execute(id, batch) from the allowedCaller.
        vm.prank(TEST6_HV);
        IExecutor(TEST6_EXECUTOR).execute(1, batch);

        bytes32 slot = keccak256(abi.encode(address(proxy), bytes32(uint256(EXEC_SLOT) + 2)));
        require(uint256(vm.load(TEST6_EXECUTOR, slot)) == 1, "minter not authorized");
        require(proxy.merkleRoot() == _domainRoot(), "allowlist root not activated");
        console.log("[7] Governance batch self-authorized the minter + activated the allowlist (real Executor).");
    }

    /* ─── 8. Real verifier guards the claim entrypoint ─── */
    function _phase8RealVerifierGuards() internal {
        // DKIM check runs before the verifier, so seed the key the proof claims.
        vm.prank(HUDSON);
        registry.setKeyForDomain(INVITE_DOMAIN, dkimKeyHash, true);

        ZkEmailProof memory bogus = _claimProof();
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(claimer);
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        proxy.claimRoleByDomain(bogus, claimer, _memberHats(), emptyProof);
        console.log("[8] Real verifier rejected a bogus proof at the claim entrypoint (InvalidProof).");
    }

    /* ─── 9. Successful claim -> real Hats mint (verifier boundary mocked) ─── */
    function _phase9Claim() internal {
        // The off-chain proving step is the only thing Foundry can't do: mock ONLY the final accept.
        address mock = address(new SimMockVerifierR());
        vm.prank(TEST6_EXECUTOR);
        proxy.setDomainVerifier(mock);

        vm.prank(TEST6_EXECUTOR);
        IEligibilityR(TEST6_ELIGIBILITY).setWearerEligibility(claimer, TEST6_MEMBER_HAT, true, true);

        require(!IHatsLikeR(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "already wears hat");
        ZkEmailProof memory p = _claimProof();
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(claimer);
        proxy.claimRoleByDomain(p, claimer, _memberHats(), emptyProof);

        require(IHatsLikeR(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "claimer did not receive Member hat");
        require(proxy.isNullifierUsed(p.emailNullifier), "nullifier not consumed");
        console.log("[9] Claim minted the real Member hat to:", claimer);
    }

    /* ──────────────────── helpers ──────────────────── */

    function _memberHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](1);
        hats[0] = TEST6_MEMBER_HAT;
    }

    /// @dev OZ StandardMerkleTree leaf (matches ZkEmailInvites._leaf): single-leaf root == leaf.
    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _domainRoot() internal pure returns (bytes32) {
        return _leaf(LEAF_DOMAIN, keccak256(bytes(INVITE_DOMAIN)), _memberHats());
    }

    function _initData() internal view returns (bytes memory) {
        // Dormant at init (root/cid = 0); governance activates via setActiveAllowlist in phase 7.
        return abi.encodeCall(
            ZkEmailInvites.initialize,
            (
                TEST6_EXECUTOR,
                address(domainVerifier),
                address(emailVerifier),
                address(registry),
                TEST6_ACCOUNT_REGISTRY,
                address(0),
                bytes32(0),
                bytes32(0)
            )
        );
    }

    function _paymasterInner(address p) internal pure returns (bytes memory) {
        address[] memory targets = new address[](4);
        bytes4[] memory sels = new bytes4[](4);
        bool[] memory allowed = new bool[](4);
        uint32[] memory hints = new uint32[](4);
        for (uint256 i; i < 4; ++i) {
            targets[i] = p;
            allowed[i] = true;
        }
        sels[0] = SEL_CLAIM_DOMAIN;
        hints[0] = 800_000;
        sels[1] = SEL_CLAIM_EMAIL;
        hints[1] = 800_000;
        sels[2] = SEL_REG_CLAIM_DOMAIN;
        hints[2] = 1_200_000;
        sels[3] = SEL_REG_CLAIM_EMAIL;
        hints[3] = 1_200_000;
        return abi.encodeWithSignature(
            "setRulesBatch(bytes32,address[],bytes4[],bool[],uint32[])", TEST6_ORG, targets, sels, allowed, hints
        );
    }

    /// @dev Structurally valid (coords < field q) but cryptographically bogus proof. The claimer is
    ///      bound via the third public signal supplied by the call site, not carried in the struct.
    function _claimProof() internal view returns (ZkEmailProof memory p) {
        p = ZkEmailProof({
            pA: [uint256(1), uint256(2)],
            pB: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            pC: [uint256(5), uint256(6)],
            pubkeyHash: dkimKeyHash,
            emailNullifier: keccak256(abi.encode("nullifier", claimer)),
            fromDomainHash: keccak256(bytes(INVITE_DOMAIN))
        });
    }

    function _bogusProof() internal pure returns (ZkEmailProof memory p) {
        p = ZkEmailProof({
            pA: [uint256(1), uint256(2)],
            pB: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            pC: [uint256(5), uint256(6)],
            pubkeyHash: bytes32(uint256(0xAA)),
            emailNullifier: bytes32(uint256(7)),
            fromDomainHash: keccak256(bytes("gmail.com"))
        });
    }
}
