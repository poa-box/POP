// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {EmailProof, IVerifier} from "../../src/zkemail/IVerifier.sol";
import {IDKIMRegistry} from "../../src/zkemail/IDKIMRegistry.sol";
import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {IExecutor, Executor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Integrate ZkEmailInvites into the live Test6 org (Gnosis)
 * ============================================================================
 *
 * Test6 was deployed before ZkEmailInvites existed, so it has no per-org proxy.
 * Retrofitting it takes three on-chain actions:
 *
 *   1. Deploy a ZkEmailInvites proxy for Test6 UNINITIALIZED — so the vote can
 *      register it BEFORE initializing it (see below).      [Hudson broadcast]
 *   2. Whitelist the 4 claim selectors on the Gnosis PaymasterHub so claims are
 *      gasless, via Satellite.adminCall (same path as the createTasksBatch /
 *      setFolders retro-fixes).                             [Hudson broadcast]
 *   3. ONE governance vote, in order: register the proxy in OrgRegistry
 *      (ContractRegistered -> the subgraph's per-org template is created), then
 *      initialize it (the rule + config events the template now catches), then
 *      authorize it as a hat minter.                        [governance vote]
 *
 * Registering before initializing is what lets the subgraph index the deploy-time
 * rules/config without eth_calls (init events follow ContractRegistered). New orgs
 * get this for free in ModulesFactory; existing orgs do it via the step-3 batch.
 *
 * Why step 3 needs governance (and an Executor upgrade): Test6's executor has
 * renounced ownership (owner() == 0), so the only authorized caller of its admin
 * functions is the HybridVoting contract. But governance reaches modules via
 * executor.execute(batch), which forbids self-targeting (TargetSelf) — so a
 * vote cannot call the executor's OWN setHatMinterAuthorization on today's impl.
 * Enabling step 3 requires the one-time Executor beacon upgrade (path A,
 * UpgradeExecutorForZkEmail) that lets a governance batch self-target exactly
 * that selector. The SIM below performs that beacon upgrade and then drives the
 * REAL executor.execute(batch) as the allowedCaller — the exact call announceWinner
 * makes — so the authorization is genuine, not a vm.store stand-in.
 *
 * Verified on-chain 2026-05-29 (Gnosis): Test6 executor owner == 0x0 (renounced),
 * allowedCaller == HybridVoting, Satellite owner == Hudson.
 *
 * Usage:
 *   # Sim (mocks ONLY the Groth16 accept; gov authorization is the REAL Executor-upgrade + execute path):
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/IntegrateZkEmailTest6.s.sol:SimIntegrateZkEmailTest6 --fork-url gnosis -vvv
 *
 *   # Broadcast (after DeployZkEmailInfra + UpgradeProtocolForZkEmail; pass the deployed addresses via env):
 *   ZK_VERIFIER=0x.. ZK_DKIM_REGISTRY=0x.. ZK_BEACON=0x.. source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/IntegrateZkEmailTest6.s.sol:BroadcastDeployAndWhitelistTest6 --rpc-url gnosis --broadcast --slow
 *   # then, after UpgradeExecutorForZkEmail, a creator-hat holder runs:
 *   ZKEMAIL_PROXY=0x... source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/IntegrateZkEmailTest6.s.sol:BroadcastGovProposalTest6 --rpc-url gnosis --broadcast
 * ============================================================================
 */

/* ─────────────────────── Minimal interfaces ─────────────────────── */
interface ISatellite {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPaymasterHubRule {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function getRule(bytes32 orgId, address target, bytes4 sel) external view returns (Rule memory);
}

interface IEligibility {
    function setWearerEligibility(address wearer, uint256 hatId, bool eligible, bool standing) external;
}

interface IHatsLike {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
}

/* ─────────────────────── Sim-only mocks ─────────────────────── */
contract SimMockVerifier is IVerifier {
    function commandBytes() external pure returns (uint256) {
        return 605;
    }

    function verifyEmailProof(EmailProof memory) external pure returns (bool) {
        return true;
    }
}

contract SimMockDKIM is IDKIMRegistry {
    function isKeyHashValid(bytes32, bytes32) external pure returns (bool) {
        return true;
    }
}

interface IOrgRegistryRegister {
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external;
}

abstract contract Test6Base is Script {
    /* ── Verified Test6 + Gnosis addresses (subgraph + cast, 2026-05-29) ── */
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant GNOSIS_PM = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    bytes32 internal constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6;
    address internal constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    address internal constant TEST6_ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
    // OrgRegistry (owned by the OrgDeployer). Registering the proxy here BEFORE initialize lets the
    // subgraph's per-org template (created on ContractRegistered) catch initialize's config + rule events.
    address internal constant TEST6_ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    bytes32 internal constant ZKEMAIL_INVITES_ID = keccak256("ZkEmailInvites");
    // Member role hat (entry-level) — the role granted to anyone proving the invite domain.
    uint256 internal constant TEST6_MEMBER_HAT =
        29035862971903655586674243772344327311664727652070589302159213246545920;

    address internal constant UNIVERSAL_FACTORY = address(0); // optional: passkey factory (0 = bare claims only)

    /* ── Invite policy: who can auto-claim, and which role ── */
    string internal constant INVITE_DOMAIN = "gmail.com"; // test/example domain — set the real one per-org

    /* ── ZK Email infra addresses — supplied via env (from the deploy/upgrade steps): ──
     *   ZK_VERIFIER, ZK_DKIM_REGISTRY  ← DeployZkEmailInfra:BroadcastDeployInfraGnosis output
     *   ZK_BEACON                       ← PoaManager.getBeaconById("ZkEmailInvites") after UpgradeProtocolForZkEmail
     * vm.envAddress reverts if unset, which is the desired "must be filled" guard for broadcast. */
    function _zkVerifier() internal view returns (address) {
        return vm.envAddress("ZK_VERIFIER");
    }

    function _zkDkimRegistry() internal view returns (address) {
        return vm.envAddress("ZK_DKIM_REGISTRY");
    }

    function _zkBeacon() internal view returns (address) {
        return vm.envAddress("ZK_BEACON");
    }

    /* ── Selectors (must match ZkEmailInvites external signatures exactly) ── */
    bytes4 internal constant SEL_CLAIM_DOMAIN =
        bytes4(keccak256("claimRoleByDomain((string,bytes32,uint256,string,bytes32,bytes32,bool,bytes),address)"));
    bytes4 internal constant SEL_CLAIM_EMAIL =
        bytes4(keccak256("claimRoleByEmail((string,bytes32,uint256,string,bytes32,bytes32,bool,bytes),address)"));
    bytes4 internal constant SEL_REG_CLAIM_DOMAIN = bytes4(
        keccak256(
            "registerAndClaimByDomainWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(string,bytes32,uint256,string,bytes32,bytes32,bool,bytes))"
        )
    );
    bytes4 internal constant SEL_REG_CLAIM_EMAIL = bytes4(
        keccak256(
            "registerAndClaimByEmailWithPasskey((bytes32,bytes32,bytes32,uint256),string,uint256,uint256,(bytes,bytes,uint256,uint256,bytes32,bytes32),(string,bytes32,uint256,string,bytes32,bytes32,bool,bytes))"
        )
    );

    /// @dev One domain rule: INVITE_DOMAIN -> Member hat, never expires.
    function _initDomainRules() internal pure returns (ZkEmailInvites.InitDomainRule[] memory r) {
        uint256[] memory hats = new uint256[](1);
        hats[0] = TEST6_MEMBER_HAT;
        r = new ZkEmailInvites.InitDomainRule[](1);
        r[0] = ZkEmailInvites.InitDomainRule({domain: INVITE_DOMAIN, hatIds: hats, expiry: 0});
    }

    function _noEmailRules() internal pure returns (ZkEmailInvites.InitEmailRule[] memory) {
        return new ZkEmailInvites.InitEmailRule[](0);
    }

    /// @dev Build the Satellite -> PaymasterHub.setRulesBatch calldata for the proxy's 4 selectors.
    function _paymasterInner(address proxy) internal pure returns (bytes memory) {
        address[] memory targets = new address[](4);
        bytes4[] memory sels = new bytes4[](4);
        bool[] memory allowed = new bool[](4);
        uint32[] memory hints = new uint32[](4);
        for (uint256 i; i < 4; ++i) {
            targets[i] = proxy;
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

    function _initData(address verifier, address dkim) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ZkEmailInvites.initialize,
            (
                TEST6_EXECUTOR,
                verifier,
                dkim,
                TEST6_ACCOUNT_REGISTRY,
                UNIVERSAL_FACTORY,
                _initDomainRules(),
                _noEmailRules()
            )
        );
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimIntegrateZkEmailTest6 is Test6Base {
    function run() public {
        console.log("\n=== SIM: Integrate ZkEmailInvites into Test6 (Gnosis fork) ===");
        require(ISatellite(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");

        // 1. Deploy mock verifier + DKIM (the real ones land in slice 3).
        address verifier = address(new SimMockVerifier());
        address dkim = address(new SimMockDKIM());

        // 2. Deploy the ZkEmailInvites proxy UNINITIALIZED, register it in Test6's OrgRegistry (as the
        //    executor), THEN initialize — so initialize's config + rule events fire AFTER ContractRegistered
        //    and the subgraph's per-org template (created on ContractRegistered) catches them. No eth_calls.
        ZkEmailInvites impl = new ZkEmailInvites();
        // Local beacon for the sim (broadcast uses a SwitchableBeacon mirroring the protocol beacon).
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), HUDSON);
        ZkEmailInvites proxy = ZkEmailInvites(address(new BeaconProxy(address(beacon), "")));

        vm.prank(TEST6_EXECUTOR);
        IOrgRegistryRegister(TEST6_ORG_REGISTRY)
            .registerOrgContract(
                TEST6_ORG, ZKEMAIL_INVITES_ID, address(proxy), address(beacon), true, TEST6_EXECUTOR, false
            );
        proxy.initialize(
            TEST6_EXECUTOR,
            verifier,
            dkim,
            TEST6_ACCOUNT_REGISTRY,
            UNIVERSAL_FACTORY,
            _initDomainRules(),
            _noEmailRules()
        );

        require(proxy.executor() == TEST6_EXECUTOR, "executor not wired");
        (uint256[] memory hatIds,, bool exists) = proxy.getDomainRule(keccak256(bytes(INVITE_DOMAIN)));
        require(exists && hatIds.length == 1 && hatIds[0] == TEST6_MEMBER_HAT, "domain rule not preloaded");
        console.log("  Proxy deployed (uninit) -> registered in OrgRegistry -> initialized:", address(proxy));

        // 3. Whitelist the 4 selectors via the REAL Satellite.adminCall (pranked as Hudson).
        require(!IPaymasterHubRule(GNOSIS_PM).getRule(TEST6_ORG, address(proxy), SEL_CLAIM_DOMAIN).allowed, "pre-set?");
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _paymasterInner(address(proxy)));
        IPaymasterHubRule.Rule memory r =
            IPaymasterHubRule(GNOSIS_PM).getRule(TEST6_ORG, address(proxy), SEL_CLAIM_DOMAIN);
        require(r.allowed && r.maxCallGasHint == 800_000, "claim rule not set");
        require(
            IPaymasterHubRule(GNOSIS_PM).getRule(TEST6_ORG, address(proxy), SEL_REG_CLAIM_DOMAIN).maxCallGasHint
                == 1_200_000,
            "register+claim rule not set"
        );
        console.log("  Paymaster: all 4 selectors whitelisted via Satellite.adminCall");

        // 4. Authorize the proxy as a hat minter — the REAL governance path (no vm.store):
        //    (a) upgrade the Executor beacon (path A) so a vote can self-target the admin selector;
        //        Test6's executor follows in Mirror mode. (Deploy impl BEFORE prank — `new` would
        //        otherwise consume the prank, leaving upgradeBeaconDirect with the default sender.)
        address newExec = address(new Executor());
        vm.prank(HUDSON);
        ISatellite(GNOSIS_SATELLITE).upgradeBeaconDirect("Executor", newExec, "v-zkemail-1");
        //    (b) drive executor.execute(batch) as the allowedCaller (HybridVoting) — exactly what
        //        announceWinner does — with the batch self-targeting setHatMinterAuthorization.
        IExecutor.Call[] memory authBatch = new IExecutor.Call[](1);
        authBatch[0] = IExecutor.Call({
            target: TEST6_EXECUTOR,
            value: 0,
            data: abi.encodeWithSignature("setHatMinterAuthorization(address,bool)", address(proxy), true)
        });
        vm.prank(TEST6_HV);
        IExecutor(TEST6_EXECUTOR).execute(1, authBatch);
        bytes32 minterSlot =
            keccak256(abi.encode(address(proxy), bytes32(uint256(keccak256("poa.executor.storage")) + 2)));
        require(uint256(vm.load(TEST6_EXECUTOR, minterSlot)) == 1, "minter not authorized via governance");
        console.log("  Authorized proxy as hat minter via REAL governance (Executor upgrade + execute)");

        // 5. Make a fresh claimer eligible for the Member hat (EligibilityModule superAdmin == executor).
        address claimer = makeAddr("zk-test6-claimer");
        vm.prank(TEST6_EXECUTOR);
        IEligibility(TEST6_ELIGIBILITY).setWearerEligibility(claimer, TEST6_MEMBER_HAT, true, true);

        // 6. Claim end-to-end against the REAL Test6 executor + REAL Hats.
        require(!IHatsLike(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "already wears hat");
        EmailProof memory p = _proof(claimer);
        vm.prank(claimer);
        proxy.claimRoleByDomain(p, claimer);

        require(IHatsLike(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "claimer did not receive Member hat");
        require(proxy.isNullifierUsed(p.emailNullifier), "nullifier not consumed");
        console.log("  Claim minted Member hat to:", claimer);
        console.log("PASS: Test6 ZkEmailInvites integration verified end-to-end on Gnosis fork.");
    }

    function _proof(address claimer) internal view returns (EmailProof memory p) {
        p.domainName = INVITE_DOMAIN;
        p.publicKeyHash = bytes32(uint256(0xAA));
        p.timestamp = block.timestamp;
        p.maskedCommand = string.concat("Claim POP role for ", _hex(claimer));
        p.emailNullifier = keccak256(abi.encode("nullifier", claimer));
        p.accountSalt = keccak256(abi.encode("salt", claimer));
        p.isCodeExist = true;
        p.proof = hex"00";
    }

    function _hex(address a) internal pure returns (string memory out) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint256 v = uint256(uint160(a));
        for (uint256 i = 0; i < 40; ++i) {
            s[41 - i] = alphabet[v & 0xf];
            v >>= 4;
        }
        out = string(s);
    }
}

/* ════════════════════════════ BROADCASTS ════════════════════════════ */

/// @notice Step 1+2 (Hudson): deploy the Test6 proxy (rules baked in) + whitelist paymaster selectors.
/// @dev Requires the slice-3 infra addresses above to be filled. The proxy's SwitchableBeacon mirrors
///      the protocol ZkEmailInvites beacon and is owned by Test6's executor (org-governed upgrades).
contract BroadcastDeployAndWhitelistTest6 is Test6Base {
    function run() public {
        address zkBeacon = _zkBeacon();
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        require(ISatellite(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner mismatch");

        vm.startBroadcast(key);
        SwitchableBeacon sb = new SwitchableBeacon(TEST6_EXECUTOR, zkBeacon, address(0), SwitchableBeacon.Mode.Mirror);
        // Deploy UNINITIALIZED — the governance proposal (step 3) registers it in OrgRegistry and THEN
        // initializes it, so initialize's events follow ContractRegistered for the subgraph template.
        BeaconProxy proxy = new BeaconProxy(address(sb), "");
        ISatellite(GNOSIS_SATELLITE).adminCall(GNOSIS_PM, _paymasterInner(address(proxy)));
        vm.stopBroadcast();

        require(
            IPaymasterHubRule(GNOSIS_PM).getRule(TEST6_ORG, address(proxy), SEL_CLAIM_DOMAIN).allowed,
            "paymaster rule not set"
        );
        console.log("Test6 ZkEmailInvites proxy (uninitialized):", address(proxy));
        console.log("NEXT (after Executor upgrade): run BroadcastGovProposalTest6 with");
        console.log("  ZKEMAIL_PROXY=", address(proxy));
        console.log("  ZKEMAIL_BEACON=", address(sb));
        console.log("  (one vote registers + initializes + authorizes the proxy)");
    }
}

/// @notice Step 3 (governance): create the proposal authorizing the proxy as a hat minter.
/// @dev Sender must wear a Test6 creator hat. REQUIRES the Executor beacon upgrade that lets a
///      governance batch self-target admin selectors (see header). Members vote; on announceWinner
///      the executor lands setHatMinterAuthorization(proxy, true).
contract BroadcastGovProposalTest6 is Test6Base {
    uint32 internal constant DURATION_MINUTES = 30;

    function run() public {
        address proxy = vm.envAddress("ZKEMAIL_PROXY");
        address beacon = vm.envAddress("ZKEMAIL_BEACON");
        address verifier = _zkVerifier();
        address dkim = _zkDkimRegistry();
        uint256 key = vm.envUint("PRIVATE_KEY");

        // One vote does it all, in order: (1) register the proxy in OrgRegistry -> ContractRegistered
        // creates the subgraph's per-org template; (2) initialize -> config + rule events the template
        // now catches; (3) authorize the minter (self-targets the executor -> needs the Executor upgrade).
        IExecutor.Call[] memory batch = new IExecutor.Call[](3);
        batch[0] = IExecutor.Call({
            target: TEST6_ORG_REGISTRY,
            value: 0,
            data: abi.encodeWithSignature(
                "registerOrgContract(bytes32,bytes32,address,address,bool,address,bool)",
                TEST6_ORG,
                ZKEMAIL_INVITES_ID,
                proxy,
                beacon,
                true,
                TEST6_EXECUTOR,
                false
            )
        });
        batch[1] = IExecutor.Call({target: proxy, value: 0, data: _initData(verifier, dkim)});
        batch[2] = IExecutor.Call({
            target: TEST6_EXECUTOR,
            value: 0,
            data: abi.encodeWithSignature("setHatMinterAuthorization(address,bool)", proxy, true)
        });
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(TEST6_HV).proposalsCount();
        vm.startBroadcast(key);
        HybridVoting(TEST6_HV)
            .createProposal(
                bytes("Authorize ZkEmailInvites as hat minter"),
                bytes32(0),
                DURATION_MINUTES,
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        require(HybridVoting(TEST6_HV).proposalsCount() == idBefore + 1, "proposal not created");
        console.log("Proposal created on Test6 HybridVoting. Members vote; then anyone calls announceWinner.");
    }
}
