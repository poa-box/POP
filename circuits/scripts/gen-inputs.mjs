// Generate a genuine PopRoleClaim witness input from a locally DKIM-signed test email.
// No external DNS/email: we mint a throwaway RSA "DKIM" key, sign a real email with the exact
// command subject via nodemailer, then monkeypatch zk-email's DoH resolver to return that key so
// generateEmailVerifierInputs performs a real DKIM verification offline.
import crypto from 'node:crypto';
import fs from 'node:fs';
import nodemailer from 'nodemailer';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { generateEmailVerifierInputs } = require('@zk-email/helpers/dist/input-generators.js');

const CLAIMER = (process.argv[2] || '0xA6F4D9f44Dd980b7168D829d5f74c2b00a46b2c9');
const DOMAIN = 'poptest.example';
const SELECTOR = 'test';
const PREFIX = 'Claim POP role for 0x';

function die(m) { console.error('ERROR:', m); process.exit(1); }
if (!/^0x[0-9a-fA-F]{40}$/.test(CLAIMER)) die(`bad claimer address: ${CLAIMER}`);

const main = async () => {
  // 1. throwaway DKIM keypair
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const pubB64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');

  // 2. build + DKIM-sign the email (relaxed/relaxed, rsa-sha256; subject is signed by default)
  const transport = nodemailer.createTransport({
    streamTransport: true,
    buffer: true,
    newline: 'windows', // CRLF
    dkim: { domainName: DOMAIN, keySelector: SELECTOR, privateKey: privPem },
  });
  const info = await transport.sendMail({
    from: `claimer@${DOMAIN}`,
    to: `invites@${DOMAIN}`,
    subject: `${PREFIX}${CLAIMER.slice(2)}`,
    text: 'POP role claim',
    date: new Date('2024-01-01T00:00:00Z'),
    messageId: `<pop-claim-test@${DOMAIN}>`,
  });
  const rawEml = info.message.toString();
  fs.writeFileSync('build/test.eml', rawEml);

  // 3. monkeypatch the DoH resolver to return our test key (same cached module dkim/index.js reads)
  const doh = require('@zk-email/helpers/dist/dkim/dns-over-http.js');
  doh.resolveDNSHTTP = async () => [`v=DKIM1; k=rsa; p=${pubB64}`];

  // 4. real DKIM verification + circuit input generation (header-only)
  const inputs = await generateEmailVerifierInputs(
    rawEml,
    { ignoreBodyHashCheck: true, maxHeadersLength: 1024 },
    { domain: DOMAIN, enableSanitization: false },
  );

  // 5. locate the command prefix in the canonicalized signed header
  const header = inputs.emailHeader.map(Number);
  const prefix = [...PREFIX].map((c) => c.charCodeAt(0));
  let commandIndex = -1;
  for (let i = 0; i + prefix.length <= header.length; i++) {
    let ok = true;
    for (let j = 0; j < prefix.length; j++) if (header[i + j] !== prefix[j]) { ok = false; break; }
    if (ok) { commandIndex = i; break; }
  }
  if (commandIndex < 0) die('command prefix not found in signed header (subject not signed?)');

  inputs.commandIndex = String(commandIndex);

  // 5b. (v2) locate the From-field window + the email address within it.
  const find = (needleBytes, from = 0) => {
    for (let i = from; i + needleBytes.length <= header.length; i++) {
      let ok = true;
      for (let j = 0; j < needleBytes.length; j++) if (header[i + j] !== needleBytes[j]) { ok = false; break; }
      if (ok) return i;
    }
    return -1;
  };
  const bytesOf = (s) => [...s].map((c) => c.charCodeAt(0));
  const EMAIL = `claimer@${DOMAIN}`;
  const fromIdx = find(bytesOf('from:'));
  const emailIdx = find(bytesOf(EMAIL));
  if (fromIdx < 0) die('from field not found in signed header');
  if (emailIdx < 0) die('from email not found in signed header');
  // FromAddrRegex anchors to (\r\n|^)from: — window starts at the preceding CRLF, or 0 if From is first.
  let fromWindowIndex;
  if (fromIdx === 0) fromWindowIndex = 0;
  else if (header[fromIdx - 2] === 13 && header[fromIdx - 1] === 10) fromWindowIndex = fromIdx - 2;
  else die('from field not preceded by CRLF (unexpected canonicalization)');
  const FROM_WINDOW = 256;
  if (emailIdx < fromWindowIndex || emailIdx + EMAIL.length > fromWindowIndex + FROM_WINDOW) {
    die('from email not within the 256-byte window');
  }
  inputs.fromWindowIndex = String(fromWindowIndex);
  inputs.emailIndexInWindow = String(emailIdx - fromWindowIndex);

  fs.writeFileSync('build/input.json', JSON.stringify(inputs));
  fs.writeFileSync('build/test-key.json', JSON.stringify(
    { domain: DOMAIN, selector: SELECTOR, claimer: CLAIMER, privateKeyPem: privPem, pubSpkiB64: pubB64 }, null, 2));

  console.log('OK  commandIndex=%d  headerLen=%s  pubkeyChunks=%d  sigChunks=%d',
    commandIndex, inputs.emailHeaderLength, inputs.pubkey.length, inputs.signature.length);
};
main().catch((e) => die(e.stack || e.message));
