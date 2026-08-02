// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {ZkEmailProof, IZkEmailGroth16Verifier} from "../../src/zkemail/IVerifier.sol";
import {SwitchableBeacon} from "../../src/SwitchableBeacon.sol";
import {IExecutor} from "../../src/Executor.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * Integrate ZkEmailInvites into the live KUBI org (Gnosis) — ku.edu domain claims
 * ============================================================================
 *
 * KUBI predates ZkEmailInvites, so it has no per-org proxy. This retrofit mirrors
 * the Test6 ceremony integration (CeremonyDeployTest6Gnosis + IntegrateZkEmailTest6):
 *
 *   1. [Hudson broadcast]  Deploy KUBI's ZkEmailInvites proxy UNINITIALIZED behind
 *      an org-owned Mirror SwitchableBeacon, and whitelist the 4 CURRENT claim
 *      selectors + the SUBJECT_TYPE_CLAIM budget on the PaymasterHub via
 *      Satellite.adminCall (gasless claims).
 *   2. [governance vote]   ONE proposal, in order: register the proxy in OrgRegistry
 *      (ContractRegistered -> subgraph per-org template), initialize it (config
 *      events indexed by that template), authorize it as a hat minter (executor
 *      self-target), and activate the single-leaf ku.edu allowlist root + CID.
 *   3. announceWinner (explicit --gas-limit 3000000) lands the batch.
 *
 * ku.edu artifacts are the ceremony-validated ones (same as Test6's live tree):
 *   - KU_POSEIDON: in-circuit Poseidon commitment of "ku.edu" (merkle-leaf id)
 *   - KU_KEYHASH:  ku.edu DKIM pubkey hash, ALREADY seeded + valid in the live
 *     PoaDKIMRegistry (verified on-chain 2026-07-31) — no DKIM action needed.
 *
 * The allowlist is a single domain leaf: ku.edu -> KUBI Member hat. Root == leaf,
 * so claims carry an EMPTY merkle proof. KUBI's Member hat is NOT default-open
 * (verified), so the H-03 HatOpenlyClaimable gate passes and the claim path's
 * _grantEmailEligibility supplies eligibility — claimers need no vouch.
 *
 * NOTE (found while building this): OrgDeployer._appendZkEmailInvitesRules still
 * hashes the pre-Blocker-2 `...,string)` claim signatures (0xc8864f92...) — the
 * live struct's selector is 0x24b5e3ba. New-org auto-whitelists are dead until
 * that's fixed; THIS script uses ZkEmailInvites.<fn>.selector directly.
 *
 * Sybil note (#184): the v1 domain circuit has no emailHash, so domain claims
 * dedup per-message only — one ku.edu mailbox can onboard multiple wallets. Same
 * accepted posture as Test6; revisit when the v2 domain circuit ships.
 *
 * Usage (all FOUNDRY_PROFILE=production):
 *   # Sim (must PASS first):
 *   forge script script/zkemail/IntegrateZkEmailKubi.s.sol:SimIntegrateZkEmailKubi --fork-url gnosis -vvv
 *
 *   # Step 1 (Hudson):
 *   source .env && forge script script/zkemail/IntegrateZkEmailKubi.s.sol:Step1_DeployAndWhitelistKubi \
 *     --rpc-url gnosis --broadcast --private-key $DEPLOYER_PRIVATE_KEY --sender <hudson> -vvv
 *
 *   # Step 2 (creator-hat holder; ZK_CID = digest of the pinned KUBI allowlist JSON):
 *   ZKEMAIL_PROXY=0x.. ZKEMAIL_BEACON=0x.. ZK_CID=0x.. source .env && forge script \
 *     script/zkemail/IntegrateZkEmailKubi.s.sol:Step2_GovProposalKubi --rpc-url gnosis --broadcast \
 *     --private-key $DEPLOYER_PRIVATE_KEY --sender <hudson> -vvv
 *
 *   # Step 3: after the vote window, finalize with an explicit gas limit:
 *   cast send <KUBI_HV> 'announceWinner(uint256)' <id> --rpc-url gnosis --gas-limit 3000000 ...
 * ============================================================================
 */

/* ─────────────────────── Minimal interfaces ─────────────────────── */
interface ISatelliteK {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function owner() external view returns (address);
}

interface IPaymasterHubK {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    struct Budget {
        uint128 capPerEpoch;
        uint128 usedThisEpoch;
        uint32 epochLen;
        uint32 epochStart;
    }

    function getRule(bytes32 orgId, address target, bytes4 sel) external view returns (Rule memory);
    function getBudget(bytes32 orgId, bytes32 key) external view returns (Budget memory);
}

interface IDKIMRegistryK {
    function isKeyHashValid(bytes32 domainHash, bytes32 keyHash) external view returns (bool);
}

interface IOrgRegistryK {
    function registerOrgContract(
        bytes32 orgId,
        bytes32 typeId,
        address proxy,
        address beacon,
        bool autoUp,
        address moduleOwner,
        bool lastRegister
    ) external;
    function getOrgContract(bytes32 orgId, bytes32 typeId) external view returns (address);
}

interface IPoaManagerK {
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IHatsK {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
}

/* ── Sim-only mock: accepts any Groth16 proof so the claim path (merkle + DKIM +
 *    H-03 gate + eligibility grant + Hats mint) can be driven end-to-end. ── */
contract KubiSimMockDomainVerifier is IZkEmailGroth16Verifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

abstract contract KubiZkBase is Script {
    /* ── Gnosis protocol addresses ── */
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant GNOSIS_SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address internal constant GNOSIS_POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;
    address internal constant ORG_REGISTRY = 0x3744b372abc41589226313F2bB1dB3aCAa22A854;
    address internal constant ACCOUNT_REGISTRY = 0x55F72CEB09cBC1fAAED734b6505b99b0a1DFA1cA;
    address internal constant UNIVERSAL_FACTORY = 0x6B5E116688A0903a80d9eb9E0CbBDbd3aD3ce025;
    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");
    bytes32 internal constant ZKEMAIL_INVITES_ID = keccak256("ZkEmailInvites");

    /* ── KUBI (subgraph + cast, 2026-07-31) ── */
    bytes32 internal constant KUBI_ORG = 0xc0f2765d555e21bfad5c6b05accef86a5758e0dee3e9a5b4ee3c3f3069c2102e;
    address internal constant KUBI_EXECUTOR = 0x23f90B3859818A843C3a848627A304Bc53947342;
    address internal constant KUBI_HV = 0x13CBd5eD47bF177968B24D84516a75879c23971E;
    address internal constant KUBI_ELIGIBILITY = 0x27114Cb757BeDF77E30EeB0Ca635e3368d8C2914;
    // Role 0 "Member" (verified via Hats.viewHat details; NOT default-open).
    uint256 internal constant KUBI_MEMBER_HAT = 29089782865237956866263577802518366573012001940915670447121420467044352;

    /* ── ku.edu ceremony artifacts (same values as Test6's live tree + registry) ── */
    bytes32 internal constant KU_POSEIDON = 0x256f370d0033263e95a6c486e2a0280c7843b2e0d586e92e6557382f776d6c58;
    bytes32 internal constant KU_KEYHASH = 0x198aa490f98ff2e619b0f48d7cd1885d604a1753b6c46b5f45b5ae2a8e8bc45f;

    /* ── Paymaster claim sponsorship (Test6 precedent values) ── */
    uint8 internal constant SUBJECT_TYPE_CLAIM = 0x05;
    uint128 internal constant CLAIM_BUDGET = 0.05 ether;
    uint32 internal constant CLAIM_EPOCH = 7 days;
    uint8 internal constant LEAF_DOMAIN = 0;

    /* ── CURRENT claim selectors, taken from the contract itself (the pre-Blocker-2
     *    `...,string)` hand-hashed variants are dead — see header note). ── */
    function _sels() internal pure returns (bytes4[4] memory s) {
        s[0] = ZkEmailInvites.claimRoleByDomain.selector;
        s[1] = ZkEmailInvites.claimRoleByEmail.selector;
        s[2] = ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector;
        s[3] = ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector;
    }

    /* ── zk infra resolved from OrgDeployer storage (written by setZkEmailInfrastructure) ── */
    function _odAddr(uint256 slotOffset) internal view returns (address) {
        return address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_SLOT) + slotOffset)))));
    }

    function _zkDomainVerifier() internal view returns (address) {
        return _odAddr(10);
    }

    function _zkEmailVerifier() internal view returns (address) {
        return _odAddr(11);
    }

    function _zkDkimRegistry() internal view returns (address) {
        return _odAddr(12);
    }

    function _zkBeacon() internal view returns (address b) {
        b = IPoaManagerK(GNOSIS_POA_MANAGER).getBeaconById(ZKEMAIL_INVITES_ID);
        require(b != address(0), "ZkEmailInvites beacon not registered on Gnosis");
    }

    /* ── Single-leaf ku.edu allowlist: root == leaf, empty merkle proof ── */
    function _memberHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](1);
        hats[0] = KUBI_MEMBER_HAT;
    }

    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    function _kuRoot() internal pure returns (bytes32) {
        return _leaf(LEAF_DOMAIN, KU_POSEIDON, _memberHats());
    }

    /* ── PaymasterHub calldatas (sent via Satellite.adminCall == poaManager path) ── */
    function _rulesCalldata(address proxy) internal pure returns (bytes memory) {
        bytes4[4] memory s = _sels();
        address[] memory targets = new address[](4);
        bytes4[] memory sels = new bytes4[](4);
        bool[] memory allowed = new bool[](4);
        uint32[] memory hints = new uint32[](4);
        for (uint256 i; i < 4; ++i) {
            targets[i] = proxy;
            sels[i] = s[i];
            allowed[i] = true;
        }
        // Groth16 verify (~250k) + DKIM + merkle + mint; combined passkey variants add
        // registration + account deploy. Hub v19 unpacks gas words correctly, so real
        // hints work (the old hint=0 accountGasLimits-swap workaround is obsolete).
        hints[0] = 800_000;
        hints[1] = 800_000;
        hints[2] = 1_200_000;
        hints[3] = 1_200_000;
        return abi.encodeWithSignature(
            "setRulesBatch(bytes32,address[],bytes4[],bool[],uint32[])", KUBI_ORG, targets, sels, allowed, hints
        );
    }

    function _claimSubjectKey(address proxy) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SUBJECT_TYPE_CLAIM, bytes32(uint256(uint160(proxy)))));
    }

    function _budgetCalldata(address proxy) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "setBudget(bytes32,bytes32,uint128,uint32)", KUBI_ORG, _claimSubjectKey(proxy), CLAIM_BUDGET, CLAIM_EPOCH
        );
    }

    /* ── The ONE governance batch: register -> initialize -> authorize -> activate ── */
    function _govBatch(address proxy, address beacon, bytes32 cid) internal view returns (IExecutor.Call[] memory b) {
        b = new IExecutor.Call[](4);
        b[0] = IExecutor.Call({
            target: ORG_REGISTRY,
            value: 0,
            data: abi.encodeCall(
                IOrgRegistryK.registerOrgContract,
                (KUBI_ORG, ZKEMAIL_INVITES_ID, proxy, beacon, true, KUBI_EXECUTOR, false)
            )
        });
        b[1] = IExecutor.Call({
            target: proxy,
            value: 0,
            data: abi.encodeCall(
                ZkEmailInvites.initialize,
                (
                    KUBI_EXECUTOR,
                    _zkDomainVerifier(),
                    _zkEmailVerifier(),
                    _zkDkimRegistry(),
                    ACCOUNT_REGISTRY,
                    UNIVERSAL_FACTORY, // real passkey factory: combined register+claim flows enabled
                    bytes32(0), // dormant at init; activated by call 4 (subgraph event ordering)
                    bytes32(0)
                )
            )
        });
        b[2] = IExecutor.Call({
            target: KUBI_EXECUTOR,
            value: 0,
            data: abi.encodeWithSignature("setHatMinterAuthorization(address,bool)", proxy, true)
        });
        b[3] = IExecutor.Call({
            target: proxy, value: 0, data: abi.encodeCall(ZkEmailInvites.setActiveAllowlist, (_kuRoot(), cid))
        });
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimIntegrateZkEmailKubi is KubiZkBase {
    function run() external {
        console.log("\n=== SIM: Integrate ZkEmailInvites into KUBI (ku.edu -> Member) on Gnosis fork ===");

        /* ── 0. Preconditions on LIVE state ── */
        require(ISatelliteK(GNOSIS_SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");
        require(
            _zkDomainVerifier() != address(0) && _zkEmailVerifier() != address(0) && _zkDkimRegistry() != address(0),
            "zk infra not wired in OrgDeployer"
        );
        require(
            IDKIMRegistryK(_zkDkimRegistry()).isKeyHashValid(KU_POSEIDON, KU_KEYHASH),
            "ku.edu DKIM key not seeded in live registry"
        );
        // getOrgContract REVERTS ContractUnknown for an unregistered type — that's the expected state.
        try IOrgRegistryK(ORG_REGISTRY).getOrgContract(KUBI_ORG, ZKEMAIL_INVITES_ID) returns (address existing) {
            require(existing == address(0), "KUBI already has a ZkEmailInvites module");
        } catch {}
        require(IHatsK(HATS).isWearerOfHat(HUDSON, KUBI_MEMBER_HAT), "Hudson lost KUBI Member hat?");
        console.log("[0] Live preconditions OK (ku.edu DKIM seeded; KUBI has no zk module yet)");

        /* ── 1. Deploy org-owned Mirror beacon + uninitialized proxy (Hudson) ── */
        vm.startPrank(HUDSON);
        SwitchableBeacon sb = new SwitchableBeacon(KUBI_EXECUTOR, _zkBeacon(), address(0), SwitchableBeacon.Mode.Mirror);
        ZkEmailInvites proxy = ZkEmailInvites(address(new BeaconProxy(address(sb), "")));
        vm.stopPrank();
        console.log("[1] Proxy (uninitialized) + Mirror beacon deployed:", address(proxy));

        /* ── 2. Paymaster rules + claim budget via Satellite.adminCall (Hudson) ── */
        vm.startPrank(HUDSON);
        ISatelliteK(GNOSIS_SATELLITE).adminCall(PAYMASTER, _rulesCalldata(address(proxy)));
        ISatelliteK(GNOSIS_SATELLITE).adminCall(PAYMASTER, _budgetCalldata(address(proxy)));
        vm.stopPrank();
        bytes4[4] memory s = _sels();
        for (uint256 i; i < 4; ++i) {
            IPaymasterHubK.Rule memory r = IPaymasterHubK(PAYMASTER).getRule(KUBI_ORG, address(proxy), s[i]);
            require(r.allowed, "claim rule not set");
            require(r.maxCallGasHint == (i < 2 ? 800_000 : 1_200_000), "claim rule hint wrong");
        }
        require(
            IPaymasterHubK(PAYMASTER).getBudget(KUBI_ORG, _claimSubjectKey(address(proxy))).capPerEpoch == CLAIM_BUDGET,
            "claim budget not set"
        );
        console.log("[2] Paymaster: 4 claim rules (800k/1.2M hints) + 0.05 ETH/7d claim budget set");

        /* ── 3. REAL governance: proposal -> Hudson votes -> announceWinner executes the batch ── */
        uint256 pid = HybridVoting(payable(KUBI_HV)).proposalsCount();
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _govBatch(address(proxy), address(sb), bytes32(uint256(0xC1D)));
        vm.startPrank(HUDSON);
        HybridVoting(payable(KUBI_HV))
            .createProposal(
                bytes("Enable ku.edu zk-email claims (ZkEmailInvites)"), bytes32(0), 30, 1, batches, new uint256[](0)
            );
        uint8[] memory idx = new uint8[](1);
        uint8[] memory w = new uint8[](1);
        idx[0] = 0;
        w[0] = 100;
        HybridVoting(payable(KUBI_HV)).vote(pid, idx, w);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        (uint256 winner, bool valid) = HybridVoting(payable(KUBI_HV)).announceWinner(pid);
        require(winner == 0 && valid, "governance proposal did not pass");

        require(
            IOrgRegistryK(ORG_REGISTRY).getOrgContract(KUBI_ORG, ZKEMAIL_INVITES_ID) == address(proxy),
            "proxy not registered"
        );
        require(proxy.executor() == KUBI_EXECUTOR, "executor not wired");
        require(address(proxy.dkimRegistry()) == _zkDkimRegistry(), "dkim registry not wired");
        require(proxy.merkleRoot() == _kuRoot(), "ku.edu allowlist root not active");
        bytes32 minterSlot =
            keccak256(abi.encode(address(proxy), bytes32(uint256(keccak256("poa.executor.storage")) + 2)));
        require(uint256(vm.load(KUBI_EXECUTOR, minterSlot)) == 1, "minter not authorized via governance");
        console.log("[3] Governance batch executed: registered + initialized + authorized + ku.edu root active");

        /* ── 4. REAL ceremony verifier rejects a bogus proof (InvalidProof) ── */
        {
            address guard = makeAddr("kubi-guard-claimer");
            ZkEmailProof memory bogus = _domainProof(guard);
            bytes32[] memory empty = new bytes32[](0);
            vm.prank(guard);
            vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
            proxy.claimRoleByDomain(bogus, guard, _memberHats(), empty);
            console.log("[4] Real ceremony verifier rejected a bogus proof at the claim entrypoint");
        }

        /* ── 5. e2e claim with Groth16 mocked ONLY (merkle + DKIM + H-03 gate + eligibility
         *       grant + Hats mint all REAL). Verifier swap rides the real governance path. ── */
        {
            address mock = address(new KubiSimMockDomainVerifier());
            IExecutor.Call[] memory b = new IExecutor.Call[](1);
            b[0] = IExecutor.Call({
                target: address(proxy), value: 0, data: abi.encodeCall(ZkEmailInvites.setDomainVerifier, (mock))
            });
            vm.prank(KUBI_HV);
            IExecutor(KUBI_EXECUTOR).execute(999, b);

            address claimer = makeAddr("kubi-ku-claimer");
            require(!IHatsK(HATS).isWearerOfHat(claimer, KUBI_MEMBER_HAT), "already wears hat");
            ZkEmailProof memory p = _domainProof(claimer);
            bytes32[] memory empty = new bytes32[](0);
            // NO manual eligibility: the claim's _grantEmailEligibility must supply it.
            vm.prank(claimer);
            proxy.claimRoleByDomain(p, claimer, _memberHats(), empty);
            require(IHatsK(HATS).isWearerOfHat(claimer, KUBI_MEMBER_HAT), "claimer did not receive Member hat");
            require(proxy.isNullifierUsed(p.emailNullifier), "nullifier not consumed");
            // replay of the same nullifier is blocked
            vm.prank(claimer);
            vm.expectRevert();
            proxy.claimRoleByDomain(p, claimer, _memberHats(), empty);
            console.log("[5] e2e claim minted Member hat (no vouch needed) + nullifier replay blocked");
        }

        console.log("\n=== PASS: KUBI ku.edu zk-email integration verified end-to-end on Gnosis fork ===");
    }

    /// @dev Structurally valid, cryptographically bogus proof carrying the REAL ku.edu Poseidon
    ///      commitment + DKIM keyHash (the pre-checks + merkle leaf + registry lookup bind to these).
    function _domainProof(address claimer) internal pure returns (ZkEmailProof memory p) {
        p.pA = [uint256(1), 2];
        p.pB = [[uint256(1), 2], [uint256(3), 4]];
        p.pC = [uint256(5), 6];
        p.pubkeyHash = KU_KEYHASH;
        p.emailNullifier = keccak256(abi.encode("kubi-ku-nullifier", claimer));
        p.fromDomainHash = KU_POSEIDON;
    }
}

/* ════════════════════════════ BROADCASTS ════════════════════════════ */

/// @notice Step 1 (Hudson): deploy KUBI's proxy (uninitialized, org-owned Mirror beacon) and
///         whitelist the 4 claim selectors + SUBJECT_TYPE_CLAIM budget on the PaymasterHub.
contract Step1_DeployAndWhitelistKubi is KubiZkBase {
    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "sender must be Hudson (Satellite owner)");
        address zkBeacon = _zkBeacon();

        vm.startBroadcast(key);
        SwitchableBeacon sb = new SwitchableBeacon(KUBI_EXECUTOR, zkBeacon, address(0), SwitchableBeacon.Mode.Mirror);
        BeaconProxy proxy = new BeaconProxy(address(sb), "");
        ISatelliteK(GNOSIS_SATELLITE).adminCall(PAYMASTER, _rulesCalldata(address(proxy)));
        ISatelliteK(GNOSIS_SATELLITE).adminCall(PAYMASTER, _budgetCalldata(address(proxy)));
        vm.stopBroadcast();

        require(
            IPaymasterHubK(PAYMASTER)
            .getRule(KUBI_ORG, address(proxy), ZkEmailInvites.claimRoleByDomain.selector)
            .allowed,
            "paymaster rule not set"
        );
        console.log("KUBI ZkEmailInvites proxy (uninitialized):", address(proxy));
        console.log("KUBI Mirror beacon:", address(sb));
        console.log("NEXT: pin the ku.edu allowlist JSON, then run Step2_GovProposalKubi with");
        console.log("  ZKEMAIL_PROXY=<proxy>  ZKEMAIL_BEACON=<beacon>  ZK_CID=<allowlist CID digest>");
    }
}

/// @notice Step 2 (creator-hat holder): create the governance proposal (register + initialize +
///         authorize + activate ku.edu allowlist) and cast a YES vote in the same broadcast.
contract Step2_GovProposalKubi is KubiZkBase {
    function run() external {
        address proxy = vm.envAddress("ZKEMAIL_PROXY");
        address beacon = vm.envAddress("ZKEMAIL_BEACON");
        bytes32 cid = vm.envBytes32("ZK_CID");
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));

        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = _govBatch(proxy, beacon, cid);

        uint256 pid = HybridVoting(payable(KUBI_HV)).proposalsCount();
        uint8[] memory idx = new uint8[](1);
        uint8[] memory w = new uint8[](1);
        idx[0] = 0;
        w[0] = 100;

        vm.startBroadcast(key);
        HybridVoting(payable(KUBI_HV))
            .createProposal(
                bytes("Enable ku.edu zk-email claims (ZkEmailInvites)"),
                bytes32(0),
                uint32(vm.envOr("VOTE_MINUTES", uint256(30))),
                1,
                batches,
                new uint256[](0)
            );
        HybridVoting(payable(KUBI_HV)).vote(pid, idx, w);
        vm.stopBroadcast();

        console.log("=== KUBI governance proposal created + YES vote cast; proposal id:", pid);
        console.log("After the vote window, finalize with an explicit gas limit:");
        console.log("  cast send", KUBI_HV);
        console.log("    'announceWinner(uint256)'", pid);
        console.log("    --rpc-url gnosis --gas-limit 3000000 --private-key $DEPLOYER_PRIVATE_KEY");
    }
}
