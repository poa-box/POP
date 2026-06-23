pragma circom 2.1.6;

include "@zk-email/circuits/email-verifier.circom";
include "@zk-email/circuits/helpers/email-nullifier.circom";
include "@zk-email/circuits/utils/array.circom";
include "@zk-email/circuits/utils/regex.circom";
include "@zk-email/circuits/utils/bytes.circom";
include "@zk-email/zk-regex-circom/circuits/common/from_addr_regex.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";

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

/// @title ToLower — ASCII-lowercase one byte (A-Z -> a-z; other bytes unchanged).
template ToLower() {
    signal input c;
    signal output out;
    signal ge <== GreaterEqThan(8)([c, 65]);
    signal le <== LessEqThan(8)([c, 90]);
    signal isUpper <== ge * le;
    out <== c + isUpper * 32;
}

/// @title PopRoleClaimV2
/// @notice v2 of the POP client-side ZK Email role-claim circuit. Same DKIM verification + subject
///         address binding as v1, plus an in-circuit commitment to the sender's From email address so
///         the contract can enforce SPECIFIC-address allowlist entries (not just whole domains).
/// @dev Public outputs (order fixed): [pubkeyHash, emailNullifier, claimerAddress, emailHash].
///      Signals 0..2 are byte-identical to v1; emailHash is appended.
///      - emailHash = Poseidon(packBytes(lowercase(From email address), 192)) — matches the off-chain
///        builder (gen-inputs.mjs / the frontend), which lowercases + zero-pads to EMAX=192 bytes (-> 7
///        31-byte field chunks) identically. The 192 here MUST match `EMAX` below and the off-chain code.
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

    signal output pubkeyHash;
    signal output emailNullifier;
    signal output claimerAddress;
    signal output emailHash;

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

    // --- 4. From-email commitment (specific-address allowlist support) ---
    // Run the (expensive) From-address regex over a small WINDOW around the From field rather than the
    // whole header — ~4x fewer constraints. Soundness: FromAddrRegex anchors to a line-start `from:`,
    // which is the unique DKIM-signed From field, so a match can only land on the real From email; the
    // prover-supplied window just has to contain it. FromAddrRegex matches both "from:Name <addr>" and
    // bare "from:addr" (relaxed-canonicalized) and reveals only the email address bytes.
    var FROM_WINDOW = 256;
    var EMAX = 192; // generous bound for a real email address (< FROM_WINDOW)

    signal fromWindow[FROM_WINDOW] <==
        SelectSubArray(maxHeadersLength, FROM_WINDOW)(emailHeader, fromWindowIndex, FROM_WINDOW);
    signal (fromOut, fromReveal[FROM_WINDOW]) <== FromAddrRegex(FROM_WINDOW)(fromWindow);
    fromOut === 1;

    signal emailBuf[EMAX] <== SelectRegexReveal(FROM_WINDOW, EMAX)(fromReveal, emailIndexInWindow);

    signal emailLower[EMAX];
    component tl[EMAX];
    for (var i = 0; i < EMAX; i++) {
        tl[i] = ToLower();
        tl[i].c <== emailBuf[i];
        emailLower[i] <== tl[i].out;
    }

    signal emailPacked[7] <== PackBytes(EMAX)(emailLower); // ceil(192/31) = 7 field elements
    emailHash <== Poseidon(7)(emailPacked);
}

component main = PopRoleClaimV2(1024, 121, 17);
