// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Groth16Verifier} from "../../src/zkemail/vendor/Groth16Verifier.sol";
import {ZkEmailProof} from "../../src/zkemail/IVerifier.sol";

/*
 * The deployed ZkDomainVerifier (v-zkemail-1, 0xE66BBEC7…) was vendored from an OLDER Groth16
 * trusted-setup run of PopRoleClaim.circom than the zkey the frontend hosts: its delta/IC constants
 * match the stale circuits/fixtures, not build/PopRoleClaim.zkey. Every browser-generated domain
 * proof is VALID under the current zkey but fails the on-chain pairing (`InvalidProof`, 0x09bde339 —
 * observed live on a Test6 one-step claim, 2026-07-10; the submitted proof verifies locally under
 * the current zkey and the old fixtures do NOT).
 *
 * This script DD-deploys the RE-VENDORED verifier (regenerated from build/PopRoleClaim.zkey; the
 * real-proof forge suite passes against it) at salt ("ZkDomainVerifier", "v-zkemail-2").
 * Rewiring Test6's proxy is a separate governance step: setDomainVerifier(new) (onlyExecutor).
 *
 * The SIM replays the USER'S EXACT failing proof (lifted verbatim from the reverted UserOp calldata)
 * through the full path on a Gnosis fork: deploy → prank-executor rewire → claimRoleByDomain →
 * require the Member hat actually minted. If that passes, the live claim passes.
 */
interface IDD {
    function computeSalt(string calldata, string calldata) external pure returns (bytes32);
    function computeAddress(bytes32) external view returns (address);
    function deploy(bytes32, bytes memory) external returns (address);
}

interface IZkInvitesLike {
    function setDomainVerifier(address v) external;
    function domainVerifier() external view returns (address);
    function claimRoleByDomain(
        ZkEmailProof calldata p,
        address claimer,
        uint256[] calldata hatIds,
        bytes32[] calldata merkleProof
    ) external;
}

interface IHatsView {
    function isWearerOfHat(address, uint256) external view returns (bool);
}

abstract contract RedeployBase is Script {
    address internal constant DD = 0x4aC8B5ebEb9D8C3dE3180ddF381D552d59e8835a;
    string internal constant TYPE_NAME = "ZkDomainVerifier";
    string internal constant NEW_VERSION = "v-zkemail-2";

    address internal constant HUDSON = 0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9; // DD owner
    address internal constant TEST6_PROXY = 0xADAf24f05EE0D647A7c2AF5cAD0F377F1B159FD2;
    address internal constant TEST6_EXECUTOR = 0xA09F1035Ff97d17ccA40048F027c654b66B83183;
    address internal constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address internal constant CLAIMER = 0x3d93687219B992e286eD3fC2B4f54f402cdF0450;
    uint256 internal constant MEMBER_HAT = 0x0000043500010001000100000000000000000000000000000000000000000000;

    function _deployNewVerifier() internal returns (address addr) {
        IDD dd = IDD(DD);
        bytes32 salt = dd.computeSalt(TYPE_NAME, NEW_VERSION);
        addr = dd.computeAddress(salt);
        if (addr.code.length == 0) {
            address deployed = dd.deploy(salt, type(Groth16Verifier).creationCode);
            require(deployed == addr, "CREATE2 address mismatch");
        }
    }

    /// @dev The user's ACTUAL proof, verbatim from the reverted UserOp of 2026-07-10.
    function _userProof() internal pure returns (ZkEmailProof memory p) {
        p.pA = [
            uint256(0x0647dea62449d3a5554d981d526163008900cbc561b22c748d5141004fe39549),
            0x000802a29a8dc666b2d6b4e491bb4b53087e88723153b66391498cbd1affed9f
        ];
        p.pB = [
            [
                uint256(0x1615cbb2d91d0308f321b1a9a128a11876d68b61cada7cec562d2e71f845eb8a),
                0x293d43966a4da0347e6da9fa60c2720d93139fd38b273251da36804442a1036d
            ],
            [
                uint256(0x0cfdfc3648aacf84ec4e14d09417db36f07852452b978fe75f7bef86b70770a1),
                0x2d383d6d29d5d82a24ad6c03adcea6feaf2ca064c0bb20a40227e0530d91e3ca
            ]
        ];
        p.pC = [
            uint256(0x2f3ae48da63df2de95fb623e257e979503abfb7071047f6cd72e79ec457d6dab),
            0x2b3ac2e225c2b940712e9c391024dd204777d119765736ad331a016293b9dfc0
        ];
        p.pubkeyHash = 0x280b10886d6d3cb6a9f870d942996b420bbfc51e3bd1f430e18690a6859b6d8f;
        p.emailNullifier = 0x1b451e09f9b080499e788da278eda7a8d16c6c4d69f7280476bb2be9fadac236;
        p.domainName = "gmail.com";
    }

    function _userClaimArgs() internal pure returns (uint256[] memory hats, bytes32[] memory merkle) {
        hats = new uint256[](1);
        hats[0] = MEMBER_HAT;
        merkle = new bytes32[](2);
        merkle[0] = 0x0864186ba1c55ba4dd6065e32008caedb1c461cc00757956ba6fa4b49e072c7b;
        merkle[1] = 0xc6655a79a83be6e708b3dd4a3aa8834666393db57ed02583bc1d97db524c13b7;
    }
}

/// @notice Deploy the corrected verifier on Gnosis (permissionless CREATE2; any funded sender).
contract BroadcastRedeployDomainVerifier is RedeployBase {
    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vm.startBroadcast(key);
        address v = _deployNewVerifier();
        vm.stopBroadcast();
        console.log("ZkDomainVerifier v-zkemail-2 deployed:", v);
        console.log("Next: governance vote -> ZkEmailInvites.setDomainVerifier(", v, ")");
    }
}

/// @notice Fork sim: deploy -> rewire (pranked executor) -> replay the USER'S exact claim -> hat minted.
contract SimRedeployDomainVerifier is RedeployBase {
    function run() external {
        // DD.deploy is owner-gated; the broadcast signs as Hudson (DEPLOYER_PRIVATE_KEY).
        vm.startPrank(HUDSON);
        address v = _deployNewVerifier();
        vm.stopPrank();
        console.log("new verifier:", v);

        // 1. The new verifier must accept the user's proof (raw pairing check).
        ZkEmailProof memory p = _userProof();
        uint256[3] memory signals = [uint256(p.pubkeyHash), uint256(p.emailNullifier), uint256(uint160(CLAIMER))];
        require(Groth16Verifier(v).verifyProof(p.pA, p.pB, p.pC, signals), "new verifier rejects user proof");
        console.log("  user proof verifies against new verifier");

        // 2. Rewire Test6's proxy (governance does this live; prank the executor here).
        vm.prank(TEST6_EXECUTOR);
        IZkInvitesLike(TEST6_PROXY).setDomainVerifier(v);
        require(IZkInvitesLike(TEST6_PROXY).domainVerifier() == v, "rewire failed");

        // 3. Replay the user's EXACT claim end-to-end (permissionless submitter).
        (uint256[] memory hats, bytes32[] memory merkle) = _userClaimArgs();
        require(!IHatsView(HATS).isWearerOfHat(CLAIMER, MEMBER_HAT), "claimer already has the hat?");
        IZkInvitesLike(TEST6_PROXY).claimRoleByDomain(p, CLAIMER, hats, merkle);
        require(IHatsView(HATS).isWearerOfHat(CLAIMER, MEMBER_HAT), "hat not minted");
        console.log("  PASS: user's exact claim mints the Member hat after rewiring");
    }
}
