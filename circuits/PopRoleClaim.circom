pragma circom 2.1.6;

include "@zk-email/circuits/email-verifier.circom";
include "@zk-email/circuits/helpers/email-nullifier.circom";
include "@zk-email/circuits/utils/array.circom";
include "circomlib/circuits/comparators.circom";

/// @title HexCharToNibble
/// @notice Decode one ASCII hex character (0-9, a-f, A-F) into its 0..15 nibble value.
/// @dev Asserts the character is a valid hex digit (exactly one of the three ranges holds).
template HexCharToNibble() {
    signal input c;       // ASCII code of the hex char
    signal output nibble; // 0..15

    // '0'..'9' -> c-48 ; 'A'..'F' -> c-55 ; 'a'..'f' -> c-87
    // (anonymous components must be bound to a signal before use in an operation)
    signal geD <== GreaterEqThan(8)([c, 48]);
    signal leD <== LessEqThan(8)([c, 57]);
    signal isD <== geD * leD;

    signal geU <== GreaterEqThan(8)([c, 65]);
    signal leU <== LessEqThan(8)([c, 70]);
    signal isU <== geU * leU;

    signal geL <== GreaterEqThan(8)([c, 97]);
    signal leL <== LessEqThan(8)([c, 102]);
    signal isL <== geL * leL;

    isD + isU + isL === 1; // must be a valid hex digit

    signal tD <== isD * (c - 48);
    signal tU <== isU * (c - 55);
    signal tL <== isL * (c - 87);
    nibble <== tD + tU + tL;
}

/// @title PopRoleClaim
/// @notice Client-side ZK Email role-claim circuit for POP.
/// @notice Proves: an email was DKIM-signed by some domain (exposes pubkeyHash), and the signed
///         headers contain the command "Claim POP role for 0x<addr>"; binds and exposes <addr>.
/// @dev Header-only (body hash ignored). Public outputs: [pubkeyHash, emailNullifier, claimerAddress].
///      - pubkeyHash    : Poseidon hash of the DKIM RSA pubkey (the contract maps domain->this hash
///                        via PoaDKIMRegistry, so the domain need not be extracted in-circuit).
///      - emailNullifier: poseidon(poseidon(signature)) — single-use replay guard.
///      - claimerAddress: uint160 of the address parsed from the signed command (binds the claim).
/// @param maxHeadersLength Max canonicalized signed-header length (multiple of 64).
/// @param n RSA chunk bit width (121).
/// @param k RSA chunk count (17) -> supports RSA-2048.
template PopRoleClaim(maxHeadersLength, n, k) {
    signal input emailHeader[maxHeadersLength];
    signal input emailHeaderLength;
    signal input pubkey[k];
    signal input signature[k];
    signal input commandIndex; // start index of "Claim POP role for 0x" within emailHeader

    signal output pubkeyHash;
    signal output emailNullifier;
    signal output claimerAddress;

    // --- 1. DKIM signature verification over the header (body ignored) ---
    component ev = EmailVerifier(maxHeadersLength, 64, n, k, 1, 0, 0, 0);
    ev.emailHeader <== emailHeader;
    ev.emailHeaderLength <== emailHeaderLength;
    ev.pubkey <== pubkey;
    ev.signature <== signature;
    pubkeyHash <== ev.pubkeyHash;

    // --- 2. Email nullifier (single-use) ---
    emailNullifier <== EmailNullifier(n, k)(signature);

    // --- 3. Parse "Claim POP role for 0x<40 hex>" from the signed header, bind the address ---
    // "Claim POP role for 0x" (21 bytes). Security note: the sender controls all signed-header
    // bytes and can only ever mint to the address THEY write here, so the command need not be
    // anchored to a specific header field — matching anywhere in the signed header is sufficient.
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

    // hex-decode the 40 chars following the prefix into a 160-bit address field
    component nib[ADDR_HEX];
    signal acc[ADDR_HEX + 1];
    acc[0] <== 0;
    for (var i = 0; i < ADDR_HEX; i++) {
        nib[i] = HexCharToNibble();
        nib[i].c <== span[PREFIX_LEN + i];
        acc[i + 1] <== acc[i] * 16 + nib[i].nibble;
    }
    claimerAddress <== acc[ADDR_HEX];
}

component main = PopRoleClaim(1024, 121, 17);
