// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ZkEmailInvites} from "../../src/ZkEmailInvites.sol";
import {
    ZkEmailProof,
    ZkEmailProofV2,
    IZkEmailGroth16Verifier,
    IZkEmailGroth16VerifierV2
} from "../../src/zkemail/IVerifier.sol";
import {IExecutor, Executor} from "../../src/Executor.sol";
import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {Groth16VerifierV2} from "../../src/zkemail/vendor/Groth16VerifierV2.sol";
import {PoaDKIMRegistry} from "../../src/zkemail/PoaDKIMRegistry.sol";
import {DeterministicDeployer} from "../../src/crosschain/DeterministicDeployer.sol";
import {HybridVoting} from "../../src/HybridVoting.sol";

/*
 * ============================================================================
 * CEREMONY DEPLOY — production ZK-Email onto the LIVE Test6 org (Gnosis)
 * ============================================================================
 *
 * Retires the dev trusted-setup + keccak domain binding on Test6 and lands the production stack:
 *   - the 5-party PHASE-2 CEREMONY verifiers (vendor/Groth16Verifier + Groth16VerifierV2, AUDIT PASSED),
 *   - Blocker-2 domain binding (in-circuit Poseidon `fromDomainHash`) end-to-end,
 *   - the H-03 open-hat gate (needs the Executor `hats()` getter this deploy adds), and
 *   - DKIM rotation/expiry (the current-branch PoaDKIMRegistry).
 *
 * Unlike a fresh-org rollout, Test6's ZkEmailInvites proxy (0xADAf24…) ALREADY exists and both its
 * module beacons are Mirror-mode, so impls come from the PROTOCOL-GLOBAL beacons. The deploy is 3 waves:
 *
 *   Step1 (Hudson)      — DD-deploy the two ceremony verifiers + a fresh Poseidon-keyed PoaDKIMRegistry
 *                         at a clean version (v-zkemail-3), seed the DKIM keys by POSEIDON domain hash,
 *                         and wire all three into the OrgDeployer (setZkEmailInfrastructure) so FUTURE
 *                         org deploys stop pointing at the stale v-zkemail-1 dev verifiers.
 *   Step2 (Hudson)      — upgrade the global Executor beacon (adds hats() — the H-03 gate calls it) and
 *                         the global ZkEmailInvites beacon (Blocker 2 + gate) via Satellite; Test6 follows
 *                         in Mirror mode. Then re-set the PaymasterHub rules under the NEW claim selectors
 *                         (the Blocker-2 struct change moved them; the old-selector rules go dead) with
 *                         hint=0 (the deployed-hub accountGasLimits-swap workaround).
 *   Step3 (governance)  — one Executor batch on Test6: setDomainVerifier + setEmailVerifier +
 *                         setDKIMRegistry + setActiveAllowlist(poseidonRoot, cid). Re-stages the same three
 *                         domains (opacitylabs.com, gmail.com, ku.edu -> Member hat) with keccak->Poseidon
 *                         leaf ids. The proxy is already a registered hat minter, so no self-target needed.
 *
 * WHY the order: the new ZkEmailInvites' H-03 gate calls Executor.hats(); if the ZkEmailInvites beacon is
 * upgraded before the Executor beacon, every claim reverts. Step2 upgrades Executor FIRST, then
 * ZkEmailInvites, in the same broadcast. Between Step2 and Step3 (a governance vote) Test6 claims are
 * briefly inconsistent (new module code, old wiring) — acceptable for a testnet org mid-cutover.
 *
 * The ONLY thing the sim cannot do is generate a valid Groth16 proof (off-chain, real .eml + proving key).
 * It deploys the REAL ceremony verifiers and proves they reject a bogus proof at the claim entrypoint, then
 * mocks ONLY the final accept to exercise the real 3-leaf merkle proof + H-03 gate + real Hats mint.
 *
 * Usage:
 *   FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/CeremonyDeployTest6Gnosis.s.sol:SimCeremonyDeployTest6 --fork-url gnosis -vvv
 *
 *   # broadcast (Hudson):
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/CeremonyDeployTest6Gnosis.s.sol:Step1_DeployCeremonyInfraGnosis --rpc-url gnosis --broadcast --slow
 *   source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/CeremonyDeployTest6Gnosis.s.sol:Step2_UpgradeBeaconsGnosis --rpc-url gnosis --broadcast --slow
 *   # governance (creator-hat holder); ZK_CID = digest of the re-pinned Poseidon allowlist doc:
 *   ZK_CID=0x.. source .env && FOUNDRY_PROFILE=production forge script \
 *     script/zkemail/CeremonyDeployTest6Gnosis.s.sol:Step3_Test6GovProposal --rpc-url gnosis --broadcast
 *   forge script script/zkemail/CeremonyDeployTest6Gnosis.s.sol:Step4_VerifyCeremonyGnosis --rpc-url gnosis
 * ============================================================================
 */

/* ─────────────────────── Minimal interfaces ─────────────────────── */
interface ISatelliteC {
    function adminCall(address target, bytes calldata data) external returns (bytes memory);
    function upgradeBeaconDirect(string calldata typeName, address newImpl, string calldata version) external;
    function owner() external view returns (address);
}

interface IPoaManagerViewC {
    function getCurrentImplementationById(bytes32 typeId) external view returns (address);
    function getBeaconById(bytes32 typeId) external view returns (address);
}

interface IPaymasterHubRuleC {
    struct Rule {
        uint32 maxCallGasHint;
        bool allowed;
    }

    function getRule(bytes32 orgId, address target, bytes4 sel) external view returns (Rule memory);
}

interface IEligibilityC {
    function setWearerEligibility(address wearer, uint256 hatId, bool eligible, bool standing) external;
}

interface IHatsLikeC {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
}

/* ─── Sim-only mock: forces ONLY the final Groth16 accept (Foundry can't gen a real proof) ─── */
contract SimMockDomainVerifier is IZkEmailGroth16Verifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

abstract contract CeremonyBase is Script {
    /* ── Protocol + Gnosis + Test6 addresses (verified on-chain via recon) ── */
    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9;
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    address internal constant SATELLITE = 0x4Ad70029a9247D369a5bEA92f90840B9ee58eD06;
    address internal constant POA_MANAGER = 0x794fD39e75140ee1545B1B022E5486B7c863789b;
    address internal constant ORG_DEPLOYER = 0x1Ad59E785E3aec1c53069f78bEcC24EcFE6a5d1c;
    address internal constant PAYMASTER = 0xdEf1038C297493c0b5f82F0CDB49e929B53B4108;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    bytes32 internal constant TEST6_ORG = 0x263b2b29f392647f0fb8ddbb26f099e812ab4ba2777e5e07b906277164181f6b;
    address internal constant TEST6_PROXY = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2; // live ZkEmailInvites proxy
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant TEST6_HV = 0xF642DdE77848dC195c8089F4042A311Ed650d7a6; // executor allowedCaller
    address internal constant TEST6_ELIGIBILITY = 0xf01F2bDd5C86E7B676117cB0d6E2c07aa36E8c8B;
    uint256 internal constant TEST6_MEMBER_HAT =
        29035862971903655586674243772344327311664727652070589302159213246545920;

    // Clean version string — probed FREE on both surfaces (DD CREATE3 + ImplementationRegistry) on BOTH
    // chains (Gnosis + Arbitrum). v-zkemail-1 = VOID dev verifiers, v-zkemail-2 = partial (ZkDomainVerifier).
    string internal constant VERSION = "v-zkemail-3";

    // ERC-1967 beacon slot (to read a proxy's beacon) + namespaced storage roots.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 internal constant OD_SLOT = keccak256("poa.orgdeployer.storage");

    uint8 internal constant LEAF_DOMAIN = 0;

    /* ── Poseidon domain-commitment hashes (Blocker 2 fromDomainHash). MUST match the circuit's
     *    Poseidon(packBytes(ascii-lower(domain),192)) and the frontend allowlist.js poseidonCommit —
     *    Solidity can't compute Poseidon-over-packed-bytes cheaply, so they're precomputed constants. ── */
    bytes32 internal constant OPACITYLABS_POSEIDON = 0x29e7dedcdb5e509c3f276fb5d689700f0eaaa74bfaa75259b4c545cd2241a5c2;
    bytes32 internal constant GMAIL_POSEIDON = 0x14d46e073cbff5944a738ea295de6c7447606fa5a270571229d8a4b1e7ca77e5;
    bytes32 internal constant KU_POSEIDON = 0x256f370d0033263e95a6c486e2a0280c7843b2e0d586e92e6557382f776d6c58;

    /* ── DKIM key hashes (== circuit pubkeyHash), validated 2026-06-24 (~/pop-zk-work/dkim-hash.mjs).
     *    opacitylabs.com has no constant yet (needs its DNS DKIM key) — supply OPACITY_KEY_HASH at
     *    broadcast to seed it; without it opacitylabs.com stays in the allowlist root but unseeded
     *    (matches CURRENT on-chain state, where only gmail.com + ku.edu are seeded). ── */
    bytes32 internal constant GMAIL_KEYHASH = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
    bytes32 internal constant KU_KEYHASH = 0x198aa490f98ff2e619b0f48d7cd1885d604a1753b6c46b5f45b5ae2a8e8bc45f;

    /* ── Claim selectors — COMPILER-COMPUTED from the current ABI, so they can never drift from the
     *    struct. The Blocker-2 struct change (ZkEmailProof `...,bytes32,string` -> `...,bytes32,bytes32`)
     *    moved every claim selector; the live paymaster rules sit under the OLD selectors and would stop
     *    matching after the upgrade, so Step2 re-sets these. ── */
    bytes4 internal constant SEL_CLAIM_DOMAIN = ZkEmailInvites.claimRoleByDomain.selector;
    bytes4 internal constant SEL_CLAIM_EMAIL = ZkEmailInvites.claimRoleByEmail.selector;
    bytes4 internal constant SEL_REG_CLAIM_DOMAIN = ZkEmailInvites.registerAndClaimByDomainWithPasskey.selector;
    bytes4 internal constant SEL_REG_CLAIM_EMAIL = ZkEmailInvites.registerAndClaimByEmailWithPasskey.selector;

    /* ─────────────────── DD (CREATE3) deploy — idempotent ─────────────────── */
    function _ddDeploy(string memory typeName, bytes memory creationCode) internal returns (address addr) {
        DeterministicDeployer dd = DeterministicDeployer(DD);
        bytes32 salt = dd.computeSalt(typeName, VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, creationCode); // onlyOwner(Hudson)
            require(deployed == addr, "DD address mismatch");
        }
    }

    function _deployInfra() internal returns (address domainVerifier, address emailVerifier, address registry) {
        domainVerifier = _ddDeploy("ZkDomainVerifier", type(Groth16Verifier).creationCode);
        emailVerifier = _ddDeploy("ZkEmailVerifier", type(Groth16VerifierV2).creationCode);
        // Bake Hudson (owner) into the creationCode so the CREATE3 address is identical on every chain.
        registry =
            _ddDeploy("PoaDKIMRegistry", abi.encodePacked(type(PoaDKIMRegistry).creationCode, abi.encode(HUDSON)));
    }

    /// @dev Seed DKIM keys keyed by POSEIDON domain hash via setKeyHash (raw bytes32). NOT setKeyForDomain,
    ///      which computes keccak and would never match the circuit-proven fromDomainHash post-Blocker-2.
    function _seedKeysPoseidon(PoaDKIMRegistry registry) internal {
        registry.setKeyHash(GMAIL_POSEIDON, vm.envOr("GMAIL_KEY_HASH", GMAIL_KEYHASH), true);
        registry.setKeyHash(KU_POSEIDON, vm.envOr("KU_KEY_HASH", KU_KEYHASH), true);
        bytes32 opacityKey = vm.envOr("OPACITY_KEY_HASH", bytes32(0));
        if (opacityKey != bytes32(0)) registry.setKeyHash(OPACITYLABS_POSEIDON, opacityKey, true);
    }

    function _setInfraCalldata(address dv, address ev, address dkim) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setZkEmailInfrastructure(address,address,address)", dv, ev, dkim);
    }

    function _odAddr(uint256 slotOffset) internal view returns (address) {
        return address(uint160(uint256(vm.load(ORG_DEPLOYER, bytes32(uint256(OD_SLOT) + slotOffset)))));
    }

    /* ─────────────────── Merkle (OZ StandardMerkleTree, matches ZkEmailInvites._leaf) ─────────────────── */
    function _memberHats() internal pure returns (uint256[] memory hats) {
        hats = new uint256[](1);
        hats[0] = TEST6_MEMBER_HAT;
    }

    /// @dev Double-keccak leaf over abi.encode(kind, id, hatIds) — identical to ZkEmailInvites._leaf.
    function _leaf(uint8 kind, bytes32 id, uint256[] memory hatIds) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(kind, id, hatIds))));
    }

    /// @dev The three Test6 domain leaf ids (Poseidon), in the on-chain allowlist doc's order.
    function _domainPoseidonHashes() internal pure returns (bytes32[] memory h) {
        h = new bytes32[](3);
        h[0] = OPACITYLABS_POSEIDON;
        h[1] = GMAIL_POSEIDON;
        h[2] = KU_POSEIDON;
    }

    function _domainLeaves() internal pure returns (bytes32[] memory leaves) {
        bytes32[] memory h = _domainPoseidonHashes();
        leaves = new bytes32[](h.length);
        for (uint256 i; i < h.length; ++i) {
            leaves[i] = _leaf(LEAF_DOMAIN, h[i], _memberHats());
        }
    }

    /// @dev OZ commutative pair hash: sort the pair, then keccak the concatenation.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Build an OZ StandardMerkleTree: sort leaves ASCENDING, place them at tree[2n-2-i], then hash
    ///      parents bottom-up with the commutative pair hash. Reproduces the OpenZeppelin merkle-tree lib.
    function _buildStdTree(bytes32[] memory leaves) internal pure returns (bytes32[] memory tree) {
        uint256 n = leaves.length;
        require(n > 0, "no leaves");
        bytes32[] memory s = _sortAsc(leaves);
        if (n == 1) {
            tree = new bytes32[](1);
            tree[0] = s[0];
            return tree;
        }
        tree = new bytes32[](2 * n - 1);
        for (uint256 i; i < n; ++i) {
            tree[2 * n - 2 - i] = s[i];
        }
        // internal nodes are [0 .. n-2]
        for (uint256 i = n - 1; i > 0; --i) {
            uint256 node = i - 1;
            tree[node] = _hashPair(tree[2 * node + 1], tree[2 * node + 2]);
        }
    }

    /// @dev Merkle proof (siblings, bottom-up) for the leaf stored at tree node `nodeIndex`.
    function _getProof(bytes32[] memory tree, uint256 nodeIndex) internal pure returns (bytes32[] memory proof) {
        uint256 count;
        for (uint256 k = nodeIndex; k > 0; k = (k - 1) / 2) {
            ++count;
        }
        proof = new bytes32[](count);
        uint256 idx;
        uint256 j = nodeIndex;
        while (j > 0) {
            uint256 sibling = j % 2 == 1 ? j + 1 : j - 1;
            proof[idx++] = tree[sibling];
            j = (j - 1) / 2;
        }
    }

    /// @dev The (root, proof) for one domain's leaf within the full 3-domain tree.
    function _rootAndProof(bytes32 domainPoseidon) internal pure returns (bytes32 root, bytes32[] memory proof) {
        bytes32 target = _leaf(LEAF_DOMAIN, domainPoseidon, _memberHats());
        bytes32[] memory tree = _buildStdTree(_domainLeaves());
        root = tree[0];
        uint256 n = _domainLeaves().length;
        uint256 nodeIndex = type(uint256).max;
        for (uint256 i = n - 1; i < tree.length; ++i) {
            if (tree[i] == target) {
                nodeIndex = i;
                break;
            }
        }
        require(nodeIndex != type(uint256).max, "leaf not in tree");
        proof = _getProof(tree, nodeIndex);
    }

    function _poseidonRoot() internal pure returns (bytes32) {
        return _buildStdTree(_domainLeaves())[0];
    }

    function _sortAsc(bytes32[] memory a) private pure returns (bytes32[] memory s) {
        s = new bytes32[](a.length);
        for (uint256 i; i < a.length; ++i) {
            s[i] = a[i];
        }
        for (uint256 i = 1; i < s.length; ++i) {
            bytes32 key = s[i];
            uint256 j = i;
            while (j > 0 && s[j - 1] > key) {
                s[j] = s[j - 1];
                --j;
            }
            s[j] = key;
        }
    }

    /* ─────────────────── Paymaster: re-set 4 claim rules under the NEW selectors ─────────────────── */
    /// @dev hint = 0 — the deployed PaymasterHub unpacks v0.7 accountGasLimits reversed, so a non-zero hint
    ///      caps the WRONG gas field (see memory paymasterhub-accountgaslimits-swap). Matches the live rules.
    function _paymasterInner() internal pure returns (bytes memory) {
        address[] memory targets = new address[](4);
        bytes4[] memory sels = new bytes4[](4);
        bool[] memory allowed = new bool[](4);
        uint32[] memory hints = new uint32[](4); // all zero
        for (uint256 i; i < 4; ++i) {
            targets[i] = TEST6_PROXY;
            allowed[i] = true;
        }
        sels[0] = SEL_CLAIM_DOMAIN;
        sels[1] = SEL_CLAIM_EMAIL;
        sels[2] = SEL_REG_CLAIM_DOMAIN;
        sels[3] = SEL_REG_CLAIM_EMAIL;
        return abi.encodeWithSignature(
            "setRulesBatch(bytes32,address[],bytes4[],bool[],uint32[])", TEST6_ORG, targets, sels, allowed, hints
        );
    }

    /* ─────────────────── Step3 governance batch: repoint the live Test6 proxy ─────────────────── */
    function _repointBatch(address dv, address ev, address dkim, bytes32 root, bytes32 cid)
        internal
        view
        returns (IExecutor.Call[] memory batch)
    {
        batch = new IExecutor.Call[](4);
        batch[0] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.setDomainVerifier, (dv))
        });
        batch[1] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.setEmailVerifier, (ev))
        });
        batch[2] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.setDKIMRegistry, (dkim))
        });
        batch[3] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.setActiveAllowlist, (root, cid))
        });
    }

    function _beaconImpl(address beacon) internal view returns (address impl) {
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok, "beacon impl() failed");
        impl = abi.decode(ret, (address));
    }
}

/* ════════════════════════════ SIMULATION ════════════════════════════ */

contract SimCeremonyDeployTest6 is CeremonyBase {
    Groth16Verifier domainVerifier;
    Groth16VerifierV2 emailVerifier;
    PoaDKIMRegistry registry;

    function run() public {
        console.log("\n=== SIM: ceremony deploy -> live Test6 (Gnosis fork) ===");
        require(ISatelliteC(SATELLITE).owner() == HUDSON, "Satellite owner != Hudson");
        require(ZkEmailInvites(TEST6_PROXY).executor() == TEST6_EXECUTOR, "proxy/executor drift");

        _step1DeployInfra();
        _step2UpgradeBeaconsAndPaymaster();
        _step3GovRepoint();
        _realVerifierGuardsClaim();
        _successfulClaim();

        console.log("\nPASS: ceremony deploy verified end-to-end on a real Gnosis fork.");
    }

    /* ── Step1: DD-deploy ceremony infra, prove verifiers reject bogus, seed Poseidon keys, wire OrgDeployer ── */
    function _step1DeployInfra() internal {
        vm.startPrank(HUDSON);
        (address dv, address ev, address reg) = _deployInfra();
        domainVerifier = Groth16Verifier(dv);
        emailVerifier = Groth16VerifierV2(ev);
        registry = PoaDKIMRegistry(reg);

        // REAL verifiers must run the pairing check and reject a bogus proof (not stubs). Cap gas so the
        // bn256 precompiles don't starve the rest of the script.
        require(!_domainRejects(), "domain verifier accepted a bogus proof!");
        require(!_emailRejects(), "email verifier accepted a bogus proof!");

        _seedKeysPoseidon(registry);
        require(registry.isKeyHashValid(GMAIL_POSEIDON, GMAIL_KEYHASH), "gmail Poseidon key not seeded");
        require(registry.isKeyHashValid(KU_POSEIDON, KU_KEYHASH), "ku Poseidon key not seeded");

        ISatelliteC(SATELLITE).adminCall(ORG_DEPLOYER, _setInfraCalldata(dv, ev, reg));
        vm.stopPrank();

        require(_odAddr(10) == dv, "OrgDeployer domain verifier not wired");
        require(_odAddr(11) == ev, "OrgDeployer email verifier not wired");
        require(_odAddr(12) == reg, "OrgDeployer dkim registry not wired");
        console.log("[1] Ceremony infra deployed + Poseidon keys seeded + OrgDeployer wired.");
        console.log("    domainVerifier:", dv);
        console.log("    emailVerifier :", ev);
        console.log("    dkimRegistry  :", reg);
    }

    function _domainRejects() internal view returns (bool) {
        uint256[4] memory s = [uint256(0xAA), uint256(7), uint256(uint160(address(0))), uint256(GMAIL_POSEIDON)];
        return domainVerifier.verifyProof{gas: 10_000_000}(
            [uint256(1), 2], [[uint256(1), 2], [uint256(3), 4]], [uint256(5), 6], s
        );
    }

    function _emailRejects() internal view returns (bool) {
        uint256[5] memory s =
            [uint256(0xAA), uint256(7), uint256(uint160(address(0))), uint256(0xE), uint256(GMAIL_POSEIDON)];
        return emailVerifier.verifyProof{gas: 10_000_000}(
            [uint256(1), 2], [[uint256(1), 2], [uint256(3), 4]], [uint256(5), 6], s
        );
    }

    /* ── Step2: upgrade Executor (adds hats()) THEN ZkEmailInvites beacons; re-set paymaster ── */
    function _step2UpgradeBeaconsAndPaymaster() internal {
        // Sanity: the LIVE Executor lacks hats() today — that's exactly why the H-03 gate needs this upgrade.
        (bool hadHats,) = TEST6_EXECUTOR.staticcall(abi.encodeWithSignature("hats()"));
        require(!hadHats, "unexpected: live Executor already exposes hats()");

        address newExec = address(new Executor());
        address newZk = address(new ZkEmailInvites());

        vm.startPrank(HUDSON);
        ISatelliteC(SATELLITE).upgradeBeaconDirect("Executor", newExec, VERSION);
        ISatelliteC(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        ISatelliteC(SATELLITE).adminCall(PAYMASTER, _paymasterInner());
        vm.stopPrank();

        // Test6 follows both global beacons via Mirror mode.
        require(_beaconImpl(_test6Beacon(TEST6_EXECUTOR)) == newExec, "Test6 executor did not follow beacon");
        require(_beaconImpl(_test6Beacon(TEST6_PROXY)) == newZk, "Test6 proxy did not follow beacon");

        // Executor now exposes hats() (the H-03 gate reads it).
        (bool hasHats, bytes memory ret) = TEST6_EXECUTOR.staticcall(abi.encodeWithSignature("hats()"));
        require(hasHats && abi.decode(ret, (address)) == HATS, "Executor.hats() missing/wrong after upgrade");

        // Paymaster: the NEW claim selectors are now gasless (old ones went dead with the struct change).
        IPaymasterHubRuleC.Rule memory r =
            IPaymasterHubRuleC(PAYMASTER).getRule(TEST6_ORG, TEST6_PROXY, SEL_CLAIM_DOMAIN);
        require(r.allowed && r.maxCallGasHint == 0, "new domain-claim paymaster rule not set (hint must be 0)");
        require(
            IPaymasterHubRuleC(PAYMASTER).getRule(TEST6_ORG, TEST6_PROXY, SEL_CLAIM_EMAIL).allowed,
            "new email-claim paymaster rule not set"
        );
        console.log("[2] Executor + ZkEmailInvites beacons upgraded (Test6 followed); paymaster re-set (hint=0).");
    }

    /* ── Step3: governance repoint via the REAL executor.execute path (announceWinner's call) ── */
    function _step3GovRepoint() internal {
        bytes32 root = _poseidonRoot();
        IExecutor.Call[] memory batch = _repointBatch(
            address(domainVerifier), address(emailVerifier), address(registry), root, bytes32(uint256(0xC1D))
        );
        vm.prank(TEST6_HV);
        IExecutor(TEST6_EXECUTOR).execute(1, batch);

        ZkEmailInvites proxy = ZkEmailInvites(TEST6_PROXY);
        require(address(proxy.domainVerifier()) == address(domainVerifier), "domain verifier not repointed");
        require(address(proxy.emailVerifier()) == address(emailVerifier), "email verifier not repointed");
        require(address(proxy.dkimRegistry()) == address(registry), "dkim registry not repointed");
        require(proxy.merkleRoot() == root, "Poseidon allowlist root not activated");
        console.log("[3] Governance repointed Test6: ceremony verifiers + Poseidon registry + Poseidon root.");
    }

    /* ── The REAL ceremony verifier guards the claim entrypoint: a bogus proof reverts InvalidProof ── */
    function _realVerifierGuardsClaim() internal {
        ZkEmailInvites proxy = ZkEmailInvites(TEST6_PROXY);
        ZkEmailProof memory bogus = _domainProof(GMAIL_POSEIDON, GMAIL_KEYHASH, makeAddr("guard-claimer"));
        (, bytes32[] memory gmProof) = _rootAndProof(GMAIL_POSEIDON);
        vm.prank(makeAddr("guard-claimer"));
        vm.expectRevert(ZkEmailInvites.InvalidProof.selector);
        proxy.claimRoleByDomain(bogus, makeAddr("guard-claimer"), _memberHats(), gmProof);
        console.log("[4] Real ceremony verifier rejected a bogus proof at the claim entrypoint (InvalidProof).");
    }

    /* ── Successful claim: mock ONLY the Groth16 accept; everything else is REAL (3-leaf merkle proof,
     *    Poseidon DKIM lookup, H-03 gate via the upgraded Executor.hats(), real Hats mint). ── */
    function _successfulClaim() internal {
        ZkEmailInvites proxy = ZkEmailInvites(TEST6_PROXY);
        address claimer = makeAddr("ceremony-test6-claimer");

        // Mock the accept via governance (setDomainVerifier is onlyExecutor).
        address mock = address(new SimMockDomainVerifier());
        IExecutor.Call[] memory b = new IExecutor.Call[](1);
        b[0] = IExecutor.Call({
            target: TEST6_PROXY, value: 0, data: abi.encodeCall(ZkEmailInvites.setDomainVerifier, (mock))
        });
        vm.prank(TEST6_HV);
        IExecutor(TEST6_EXECUTOR).execute(2, b);

        // Make the claimer eligible (EligibilityModule superAdmin == executor).
        vm.prank(TEST6_EXECUTOR);
        IEligibilityC(TEST6_ELIGIBILITY).setWearerEligibility(claimer, TEST6_MEMBER_HAT, true, true);

        require(!IHatsLikeC(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "already wears hat");
        (, bytes32[] memory gmProof) = _rootAndProof(GMAIL_POSEIDON);
        ZkEmailProof memory p = _domainProof(GMAIL_POSEIDON, GMAIL_KEYHASH, claimer);
        vm.prank(claimer);
        proxy.claimRoleByDomain(p, claimer, _memberHats(), gmProof);

        require(IHatsLikeC(HATS).isWearerOfHat(claimer, TEST6_MEMBER_HAT), "claimer did not receive Member hat");
        require(proxy.isNullifierUsed(p.emailNullifier), "nullifier not consumed");
        console.log("[5] Real 3-leaf merkle proof + H-03 gate + Hats mint verified. Claimer:", claimer);
    }

    function _test6Beacon(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
    }

    /// @dev Structurally valid (coords < q) but cryptographically bogus. claimer is bound by the call site
    ///      (signal[2]); nullifier is claimer-derived to stay unique; fromDomainHash/pubkeyHash carry the
    ///      Poseidon domain commitment + DKIM key the pre-checks + merkle leaf bind to.
    function _domainProof(bytes32 domainPoseidon, bytes32 keyHash, address claimer)
        internal
        pure
        returns (ZkEmailProof memory p)
    {
        p.pA = [uint256(1), 2];
        p.pB = [[uint256(1), 2], [uint256(3), 4]];
        p.pC = [uint256(5), 6];
        p.pubkeyHash = keyHash;
        p.emailNullifier = keccak256(abi.encode("ceremony-nullifier", claimer, domainPoseidon));
        p.fromDomainHash = domainPoseidon;
    }
}

/* ════════════════════════════ BROADCASTS ════════════════════════════ */

/// @notice Step 1 (Hudson): DD-deploy the ceremony verifiers + fresh Poseidon-keyed registry, seed DKIM
///         keys, and wire all three into the OrgDeployer for future org deploys.
contract Step1_DeployCeremonyInfraGnosis is CeremonyBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (DD/registry/Satellite owner)");
        console.log("\n=== Step 1: DD-deploy ceremony ZK infra on Gnosis (v-zkemail-3) ===");

        vm.startBroadcast(key);
        (address dv, address ev, address reg) = _deployInfra();
        _seedKeysPoseidon(PoaDKIMRegistry(reg));
        ISatelliteC(SATELLITE).adminCall(ORG_DEPLOYER, _setInfraCalldata(dv, ev, reg));
        vm.stopBroadcast();

        require(PoaDKIMRegistry(reg).isKeyHashValid(GMAIL_POSEIDON, vm.envOr("GMAIL_KEY_HASH", GMAIL_KEYHASH)), "gmail");
        require(PoaDKIMRegistry(reg).isKeyHashValid(KU_POSEIDON, vm.envOr("KU_KEY_HASH", KU_KEYHASH)), "ku");
        require(_odAddr(10) == dv && _odAddr(11) == ev && _odAddr(12) == reg, "OrgDeployer not wired");
        console.log("  ZK_DOMAIN_VERIFIER:", dv);
        console.log("  ZK_EMAIL_VERIFIER: ", ev);
        console.log("  ZK_DKIM_REGISTRY:  ", reg);
        if (vm.envOr("OPACITY_KEY_HASH", bytes32(0)) == bytes32(0)) {
            console.log("  NOTE: opacitylabs.com NOT seeded (no OPACITY_KEY_HASH) - set it to close the gap.");
        }
        console.log("\nNext: Step2_UpgradeBeaconsGnosis.");
    }
}

/// @notice Step 2 (Hudson): upgrade the Executor + ZkEmailInvites global beacons and re-set the Test6
///         paymaster rules under the NEW claim selectors (hint=0).
contract Step2_UpgradeBeaconsGnosis is CeremonyBase {
    function run() public {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(vm.addr(key) == HUDSON, "Sender must be Hudson (Satellite owner)");
        console.log("\n=== Step 2: upgrade Executor + ZkEmailInvites beacons + re-set paymaster ===");

        vm.startBroadcast(key);
        address newExec = address(new Executor());
        address newZk = address(new ZkEmailInvites());
        // Executor FIRST — the new ZkEmailInvites H-03 gate calls Executor.hats().
        ISatelliteC(SATELLITE).upgradeBeaconDirect("Executor", newExec, VERSION);
        ISatelliteC(SATELLITE).upgradeBeaconDirect("ZkEmailInvites", newZk, VERSION);
        ISatelliteC(SATELLITE).adminCall(PAYMASTER, _paymasterInner());
        vm.stopBroadcast();

        require(
            IPoaManagerViewC(POA_MANAGER).getCurrentImplementationById(keccak256("Executor")) == newExec,
            "Executor beacon not upgraded"
        );
        require(
            IPoaManagerViewC(POA_MANAGER).getCurrentImplementationById(keccak256("ZkEmailInvites")) == newZk,
            "ZkEmailInvites beacon not upgraded"
        );
        (bool ok, bytes memory ret) = TEST6_EXECUTOR.staticcall(abi.encodeWithSignature("hats()"));
        require(ok && abi.decode(ret, (address)) == HATS, "Test6 Executor.hats() missing after upgrade");
        require(
            IPaymasterHubRuleC(PAYMASTER).getRule(TEST6_ORG, TEST6_PROXY, SEL_CLAIM_DOMAIN).allowed,
            "new domain-claim paymaster rule not set"
        );
        console.log("  new Executor impl:      ", newExec);
        console.log("  new ZkEmailInvites impl:", newZk);
        console.log("\nNext (governance): Step3_Test6GovProposal with ZK_CID=<Poseidon allowlist doc digest>.");
    }
}

/// @notice Step 3 (governance, creator-hat holder): propose the Test6 repoint — ceremony verifiers +
///         Poseidon registry + re-staged Poseidon allowlist root. Members vote; announceWinner lands it
///         (pass an explicit --gas-limit on announceWinner, the batch is non-trivial).
contract Step3_Test6GovProposal is CeremonyBase {
    uint32 internal constant DURATION_MINUTES = 30;

    function run() public {
        // Resolve the deployed infra from the OrgDeployer slots Step1 wired (env-overridable).
        address dv = vm.envOr("ZK_DOMAIN_VERIFIER", _odAddr(10));
        address ev = vm.envOr("ZK_EMAIL_VERIFIER", _odAddr(11));
        address dkim = vm.envOr("ZK_DKIM_REGISTRY", _odAddr(12));
        bytes32 root = vm.envOr("ZK_ROOT", _poseidonRoot());
        bytes32 cid = vm.envBytes32("ZK_CID"); // digest of the re-pinned Poseidon allowlist doc
        require(dv != address(0) && ev != address(0) && dkim != address(0), "infra unresolved - run Step1 first");
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));

        IExecutor.Call[] memory batch = _repointBatch(dv, ev, dkim, root, cid);
        IExecutor.Call[][] memory batches = new IExecutor.Call[][](1);
        batches[0] = batch;

        uint256 idBefore = HybridVoting(TEST6_HV).proposalsCount();
        vm.startBroadcast(key);
        HybridVoting(TEST6_HV)
            .createProposal(
                bytes("Ceremony repoint: production ZK-Email verifiers + Poseidon allowlist"),
                bytes32(0),
                uint32(vm.envOr("VOTE_MINUTES", uint256(DURATION_MINUTES))),
                1,
                batches,
                new uint256[](0)
            );
        vm.stopBroadcast();

        require(HybridVoting(TEST6_HV).proposalsCount() == idBefore + 1, "proposal not created");
        console.log("\nProposal created on Test6 HybridVoting (root):");
        console.logBytes32(root);
        console.log("Members vote; then: cast send <HV> 'announceWinner(uint256)' <id> --gas-limit 3000000");
    }
}

/// @notice Step 4 (read-only): verify the live Test6 wiring after the governance batch lands.
contract Step4_VerifyCeremonyGnosis is CeremonyBase {
    function run() public view {
        ZkEmailInvites proxy = ZkEmailInvites(TEST6_PROXY);
        address dv = _odAddr(10);
        address ev = _odAddr(11);
        address dkim = _odAddr(12);
        bytes32 wantRoot = _poseidonRoot();

        bool dvOk = address(proxy.domainVerifier()) == dv;
        bool evOk = address(proxy.emailVerifier()) == ev;
        bool dkimOk = address(proxy.dkimRegistry()) == dkim;
        bool rootOk = proxy.merkleRoot() == wantRoot;
        (bool hatsOk, bytes memory ret) = TEST6_EXECUTOR.staticcall(abi.encodeWithSignature("hats()"));
        hatsOk = hatsOk && abi.decode(ret, (address)) == HATS;
        bool keysOk = PoaDKIMRegistry(dkim).isKeyHashValid(GMAIL_POSEIDON, GMAIL_KEYHASH)
            && PoaDKIMRegistry(dkim).isKeyHashValid(KU_POSEIDON, KU_KEYHASH);
        bool pmOk = IPaymasterHubRuleC(PAYMASTER).getRule(TEST6_ORG, TEST6_PROXY, SEL_CLAIM_DOMAIN).allowed;

        console.log("\n=== Verify Test6 ceremony wiring ===");
        console.log("  expected Poseidon allowlist root (ZK_ROOT default):");
        console.logBytes32(wantRoot);
        console.log("  domain verifier repointed:", dvOk);
        console.log("  email verifier repointed: ", evOk);
        console.log("  dkim registry repointed:  ", dkimOk);
        console.log("  Poseidon allowlist root:  ", rootOk);
        console.log("  Executor.hats() present:  ", hatsOk);
        console.log("  gmail+ku Poseidon keys:   ", keysOk);
        console.log("  new-selector paymaster:   ", pmOk);
        if (dvOk && evOk && dkimOk && rootOk && hatsOk && keysOk && pmOk) {
            console.log("PASS: Test6 is on the production ceremony stack.");
        } else {
            console.log("INCOMPLETE: some wiring not yet landed (governance batch may still be pending).");
        }
    }
}
