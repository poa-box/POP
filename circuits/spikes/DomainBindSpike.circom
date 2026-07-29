pragma circom 2.1.6;

// Blocker-2 spike: prove the From-address DOMAIN can be extracted in-circuit and committed with
// Poseidon (matching an off-chain commitment), so the on-chain DKIM lookup + domain leaf can bind to
// the PROVEN domain instead of a caller-supplied string. Mirrors V2's email-address extraction exactly,
// but runs EmailDomainRegex (domain only) instead of FromAddrRegex (full address).
include "@zk-email/circuits/utils/array.circom";
include "@zk-email/circuits/utils/regex.circom";
include "@zk-email/circuits/utils/bytes.circom";
include "@zk-email/zk-regex-circom/circuits/common/email_domain_regex.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";

template ToLower() {
    signal input c;
    signal output out;
    signal ge <== GreaterEqThan(8)([c, 65]);
    signal le <== LessEqThan(8)([c, 90]);
    signal isUpper <== ge * le;
    out <== c + isUpper * 32;
}

// WIN = from-window length, DMAX = domain byte bound (192 → Poseidon(7), same shape as emailHash).
template DomainBindSpike(WIN, DMAX) {
    signal input fromWindow[WIN];
    signal input domainIndexInWindow; // start of the domain reveal within the window (prover hint)
    signal output fromDomainHash;

    signal (dOut, dReveal[WIN]) <== EmailDomainRegex(WIN)(fromWindow);
    dOut === 1; // the From field's domain matched

    signal domBuf[DMAX] <== SelectRegexReveal(WIN, DMAX)(dReveal, domainIndexInWindow);

    signal domLower[DMAX];
    component tl[DMAX];
    for (var i = 0; i < DMAX; i++) {
        tl[i] = ToLower();
        tl[i].c <== domBuf[i];
        domLower[i] <== tl[i].out;
    }

    signal packed[7] <== PackBytes(DMAX)(domLower); // ceil(192/31) = 7
    fromDomainHash <== Poseidon(7)(packed);
}

component main = DomainBindSpike(256, 192);
