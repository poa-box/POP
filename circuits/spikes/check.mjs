import { readFileSync, writeFileSync } from 'fs';
import { execSync } from 'child_process';
import { buildPoseidon } from 'circomlibjs';

const WIN = 256, DMAX = 192;
const email = 'from:Alice <ALICE@Example.COM>\r\n'; // mixed case + display name — exercises ToLower + regex
// Build the from-window bytes.
const win = new Uint8Array(WIN);
const bytes = new TextEncoder().encode(email);
win.set(bytes.slice(0, WIN));
// EmailDomainRegex reveals the domain; SelectRegexReveal needs the domain's start index in the window.
const domainStr = 'Example.COM'; // as it appears in the header (pre-lowercase)
const domainIndexInWindow = email.indexOf(domainStr);

writeFileSync('spike/input.json', JSON.stringify({
  fromWindow: Array.from(win).map(String),
  domainIndexInWindow: String(domainIndexInWindow),
}));

// Witness → read the single public output (witness[1]).
execSync('node --max-old-space-size=8000 node_modules/snarkjs/build/cli.cjs wtns calculate spike/DomainBindSpike_js/DomainBindSpike.wasm spike/input.json spike/w.wtns', { stdio: 'inherit' });
execSync('node node_modules/snarkjs/build/cli.cjs wtns export json spike/w.wtns spike/w.json', { stdio: 'inherit' });
const w = JSON.parse(readFileSync('spike/w.json'));
const circuitHash = BigInt(w[1]);

// Off-chain commitment: SAME as allowlist.js emailHash, applied to the lowercased DOMAIN.
const poseidon = await buildPoseidon();
const norm = (s) => s.trim().replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
const buf = new Uint8Array(DMAX);
buf.set(new TextEncoder().encode(norm(domainStr)).slice(0, DMAX));
const chunks = [];
for (let i = 0; i < 7; i++) {
  let acc = 0n;
  for (let j = 0; j < 31; j++) { const idx = 31 * i + j; acc += (idx < DMAX ? BigInt(buf[idx]) : 0n) << BigInt(8 * j); }
  chunks.push(acc);
}
const offchain = BigInt(poseidon.F.toString(poseidon(chunks)));

console.log('domain (header)  :', domainStr, '-> normalized:', norm(domainStr));
console.log('circuit  fromDomainHash:', circuitHash.toString());
console.log('offchain Poseidon(dom):', offchain.toString());
console.log(circuitHash === offchain ? '\n✅ MATCH — in-circuit domain extraction == off-chain commitment' : '\n❌ MISMATCH');
process.exit(circuitHash === offchain ? 0 : 1);
