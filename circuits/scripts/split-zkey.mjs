// Split a Groth16 .zkey into fixed-size parts + a manifest, for reliable chunked browser download.
//
// The browser fetches the parts in parallel (resumable, cacheable), concatenates them into one
// Uint8Array, and passes it to snarkjs as `{ type: 'mem', data }` — so chunking is a DOWNLOAD
// optimization only (no snarkjs fork, no fastfile chunk-format coupling). See
// poa-app/src/lib/zkemail/zkeyLoader.js for the loader.
//
// Usage: node split-zkey.mjs <path/to/circuit_final.zkey> <outDir> [chunkMB=25] [publicName]
//   publicName defaults to the basename minus `_final.zkey` (e.g. PopRoleClaim, PopRoleClaimV2),
//   producing `<name>.zkey.part0..N` + `<name>.zkey.manifest.json` in <outDir>.
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

const [, , zkeyPath, outDir, chunkMbArg, nameArg] = process.argv;
if (!zkeyPath || !outDir) {
  console.error('usage: node split-zkey.mjs <zkey> <outDir> [chunkMB=25] [publicName]');
  process.exit(1);
}
const chunkMB = parseInt(chunkMbArg || '25', 10);
const chunkSize = chunkMB * 1024 * 1024;
const name = nameArg || path.basename(zkeyPath).replace(/(_final)?\.zkey$/, '');

const buf = fs.readFileSync(zkeyPath);
fs.mkdirSync(outDir, { recursive: true });

const numParts = Math.ceil(buf.length / chunkSize);
for (let i = 0; i < numParts; i++) {
  const part = buf.subarray(i * chunkSize, Math.min((i + 1) * chunkSize, buf.length));
  fs.writeFileSync(path.join(outDir, `${name}.zkey.part${i}`), part);
}

const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
const manifest = {
  schema: 'pop.zkey-chunks/1',
  name,
  numParts,
  partSize: chunkSize,
  totalSize: buf.length,
  sha256,
};
fs.writeFileSync(path.join(outDir, `${name}.zkey.manifest.json`), JSON.stringify(manifest, null, 2));

console.log(`split ${name}.zkey: ${(buf.length / 1e6).toFixed(0)} MB -> ${numParts} x ${chunkMB} MB parts in ${outDir}`);
console.log(`sha256 ${sha256}`);
