pragma circom 2.1.6;

include "@zk-email/circuits/email-verifier.circom";
include "@zk-email/circuits/helpers/email-nullifier.circom";
include "@zk-email/circuits/utils/array.circom";
include "@zk-email/circuits/utils/regex.circom";
include "@zk-email/circuits/utils/bytes.circom";
include "@zk-email/zk-regex-circom/circuits/common/from_addr_regex.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";
include "from_domain.circom";

/// @title HexCharToNibble — decode one ASCII hex char (0-9,a-f,A-F) to its 0..15 nibble (asserts valid).
template HexCharToNibble() {
    signal input c;
    signal output nibble;

    signal geD <== GreaterEqThan(8)([c, 48]);
    signal leD <== LessEqThan(8)([c, 57]);
    signal isD <== geD * leD;
    signal geU <== GreaterEqThan(8)([c, 65]);
    signal leU <== LessEqThan(8)([c, 70]);
    signal isU <== geU * leU;
    signal geL <== GreaterEqThan(8)([c, 97]);
    signal leL <== LessEqThan(8)([c, 102]);
    signal isL <== geL * leL;

    isD + isU + isL === 1;

    signal tD <== isD * (c - 48);
    signal tU <== isU * (c - 55);
    signal tL <== isL * (c - 87);
    nibble <== tD + tU + tL;
}

// ToLower is provided by from_domain.circom (shared with the domain extraction).

/// @title PopRoleClaimV2
/// @notice v2 of the POP client-side ZK Email role-claim circuit. Same DKIM verification + subject
///         address binding as v1, plus an in-circuit commitment to the sender's From email address so
///         the contract can enforce SPECIFIC-address allowlist entries (not just whole domains).
/// @dev Public outputs (order fixed):
///      [pubkeyHash, emailNullifier, claimerAddress, emailHash, fromDomainHash].
///      Signals 0..2 are byte-identical to v1; emailHash then fromDomainHash are appended.
///      - emailHash = Poseidon(packBytes(lowercase(From email address), 192)) — matches the off-chain
///        builder (gen-inputs.mjs / the frontend), which lowercases + zero-pads to EMAX=192 bytes (-> 7
///        31-byte field chunks) identically. The 192 here MUST match `EMAX` below and the off-chain code.
///      - fromDomainHash = Poseidon commitment of the PROVEN From-address DOMAIN (Blocker 2). Lets the
///        contract bind the DKIM registry lookup to the actual sending domain, same as v1.
/// @param maxHeadersLength canonicalized signed-header length (multiple of 64).
/// @param n RSA chunk bit width (121). @param k RSA chunk count (17) -> RSA-2048.
template PopRoleClaimV2(maxHeadersLength, n, k) {
    signal input emailHeader[maxHeadersLength];
    signal input emailHeaderLength;
    signal input pubkey[k];
    signal input signature[k];
    signal input commandIndex;       // start of "Claim POP role for 0x" within emailHeader
    signal input fromWindowIndex;    // start of a small window containing the From field (prover hint)
    signal input emailIndexInWindow; // start of the From email address within that window
    signal input atIndex;            // index of '@' within the extracted From address (prover hint)

    signal output pubkeyHash;
    signal output emailNullifier;
    signal output claimerAddress;
    signal output emailHash;
    signal output fromDomainHash;

    // --- 1. DKIM signature verification over the header (body ignored) ---
    component ev = EmailVerifier(maxHeadersLength, 64, n, k, 1, 0, 0, 0);
    ev.emailHeader <== emailHeader;
    ev.emailHeaderLength <== emailHeaderLength;
    ev.pubkey <== pubkey;
    ev.signature <== signature;
    pubkeyHash <== ev.pubkeyHash;

    // --- 2. Email nullifier (single-use) ---
    emailNullifier <== EmailNullifier(n, k)(signature);

    // --- 3. Parse "Claim POP role for 0x<40 hex>" from the signed header, bind the claimer address ---
    var PREFIX_LEN = 21;
    var ADDR_HEX = 40;
    var SPAN = PREFIX_LEN + ADDR_HEX; // 61
    var prefix[PREFIX_LEN] =
        [67, 108, 97, 105, 109, 32, 80, 79, 80, 32, 114, 111, 108, 101, 32, 102, 111, 114, 32, 48, 120];

    signal span[SPAN] <== SelectSubArray(maxHeadersLength, SPAN)(emailHeader, commandIndex, SPAN);
    component matcher = CheckSubstringMatch(PREFIX_LEN);
    for (var i = 0; i < PREFIX_LEN; i++) {
        matcher.in[i] <== span[i];
        matcher.substring[i] <== prefix[i];
    }
    matcher.isMatch === 1;

    component nib[ADDR_HEX];
    signal acc[ADDR_HEX + 1];
    acc[0] <== 0;
    for (var i = 0; i < ADDR_HEX; i++) {
        nib[i] = HexCharToNibble();
        nib[i].c <== span[PREFIX_LEN + i];
        acc[i + 1] <== acc[i] * 16 + nib[i].nibble;
    }
    claimerAddress <== acc[ADDR_HEX];

    // --- 4. From-address commitments (specific-address allowlist support + Blocker 2 domain binding) ---
    // One from-anchored extraction yields BOTH emailHash (full address, for specific-address entries) and
    // fromDomainHash (its domain, bound to the DKIM signer). See from_domain.circom for the soundness of
    // deriving the domain from the FromAddrRegex address (vs a standalone, non-anchored domain regex).
    (emailHash, fromDomainHash) <==
        FromAddrCommit(maxHeadersLength)(emailHeader, fromWindowIndex, emailIndexInWindow, atIndex);
}

component main = PopRoleClaimV2(1024, 121, 17);
