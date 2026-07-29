pragma circom 2.1.6;

// Shared From-address extraction + Poseidon commitments for the POP role-claim circuits
// (Blocker 2 — see docs/ZKEMAIL_BLOCKER2_DOMAIN_BINDING.md).
//
// Soundness note: the DOMAIN is derived from the FROM address that `FromAddrRegex` extracts —
// NOT from a standalone domain regex. FromAddrRegex anchors to a line-start `from:`, which in the
// DKIM-signed header is the unique From field, so the extracted address (and therefore its domain) can
// only be the sender's. (A bare `EmailDomainRegex` over the header reveals *every* `@domain` — from:,
// to:, message-id — so it is unsuitable for binding the sender.) We then split the extracted address at
// its single '@' in-circuit to commit to the domain.

include "@zk-email/circuits/utils/array.circom";
include "@zk-email/circuits/utils/regex.circom";
include "@zk-email/circuits/utils/bytes.circom";
include "@zk-email/zk-regex-circom/circuits/common/from_addr_regex.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";

/// @title ToLower — ASCII-lowercase one byte (A-Z -> a-z; other bytes unchanged).
/// @dev Matches the contract's `_lower`/`domainHashOf` and the off-chain ASCII `norm`.
template ToLower() {
    signal input c;
    signal output out;
    signal ge <== GreaterEqThan(8)([c, 65]);
    signal le <== LessEqThan(8)([c, 90]);
    signal isUpper <== ge * le;
    out <== c + isUpper * 32;
}

/// @title FromAddrCommit
/// @notice Extract the sender's From address (from-anchored) and commit to BOTH the full address
///         (emailHash) and its domain (fromDomainHash), each = Poseidon(packBytes(lowercase(x), 192)),
///         matching the off-chain builder exactly.
/// @dev The domain is `emailLower` shifted past its single '@'. `atIndex` is a prover hint constrained
///      to be THE '@' (it is '@', and no earlier byte is '@'), so the split is sound. `emailLower` is
///      zero-padded past the address, so the shifted domain is the real domain + trailing zeros.
/// @param maxHeadersLength the enclosing circuit's signed-header length.
template FromAddrCommit(maxHeadersLength) {
    signal input emailHeader[maxHeadersLength];
    signal input fromWindowIndex;     // start of a window containing the From field (prover hint)
    signal input emailIndexInWindow;  // start of the From address within that window (prover hint)
    signal input atIndex;             // index of '@' within the extracted address (prover hint)
    signal output emailHash;          // commitment to the full lowercased From address
    signal output fromDomainHash;     // commitment to the lowercased From domain (bytes after '@')

    var FROM_WINDOW = 256;
    var EMAX = 192; // ceil(192/31) = 7 field chunks

    // 1. From-anchored address extraction (identical to v2's original inline block).
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
    signal emailPacked[7] <== PackBytes(EMAX)(emailLower);
    emailHash <== Poseidon(7)(emailPacked);

    // 2. Constrain `atIndex` to be the FIRST (and, for a valid address, only) '@'.
    signal atChar <== ItemAtIndex(EMAX)(emailLower, atIndex);
    atChar === 64; // '@'
    component isAt[EMAX];
    component before[EMAX];
    signal earlyAt[EMAX + 1];
    earlyAt[0] <== 0;
    for (var i = 0; i < EMAX; i++) {
        isAt[i] = IsEqual();
        isAt[i].in[0] <== emailLower[i];
        isAt[i].in[1] <== 64;
        before[i] = LessThan(9);
        before[i].in[0] <== i;
        before[i].in[1] <== atIndex;
        earlyAt[i + 1] <== earlyAt[i] + isAt[i].out * before[i].out;
    }
    earlyAt[EMAX] === 0; // no '@' before atIndex

    // 3. Domain = address bytes AFTER the '@'. VarShiftLeft is a CIRCULAR rotate, so first zero the
    //    local-part + '@' (indices <= atIndex); then shifting left by atIndex+1 wraps in those zeros,
    //    leaving a clean `domain + trailing zeros` buffer == the off-chain padded-domain commitment.
    signal masked[EMAX];
    component keep[EMAX];
    for (var i = 0; i < EMAX; i++) {
        keep[i] = GreaterThan(9);
        keep[i].in[0] <== i;
        keep[i].in[1] <== atIndex; // keep bytes strictly AFTER '@'
        masked[i] <== emailLower[i] * keep[i].out;
    }
    signal domain[EMAX] <== VarShiftLeft(EMAX, EMAX)(masked, atIndex + 1);
    signal domainPacked[7] <== PackBytes(EMAX)(domain);
    fromDomainHash <== Poseidon(7)(domainPacked);
}
