/**
 * Static regression guard for ChannelBridge — must pass before merge/commit on bridge changes.
 * Catches re-introduction of ingress-only bridge and dropped HTTP legacy notify path.
 *
 * Run: node tests/smoke/bridge-contract.mjs
 * Or:  npm run verify (from ChannelBridge package)
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const srcPath = path.join(repoRoot, 'src/CcSessionsCoord.ChannelBridge/src/index.ts');
const distPath = path.join(repoRoot, 'src/CcSessionsCoord.ChannelBridge/dist/index.js');

function fail(msg) {
  console.error(`BRIDGE-CONTRACT FAIL: ${msg}`);
  process.exit(1);
}

function readOrFail(p) {
  if (!fs.existsSync(p)) fail(`missing file: ${p}`);
  return fs.readFileSync(p, 'utf8');
}

const src = readOrFail(srcPath);
const dist = fs.existsSync(distPath) ? readOrFail(distPath) : '';

const forbidden = [
  { re: /ingress-only bridge start/, label: 'ingress-only boot (4951175 regression)' },
  { re: /bridge-session-name-empty/, label: 'expect_session gate reject (9791ca8d regression)' },
  { re: /expect_session/, label: 'expect_session HTTP gate' },
  { re: /role:\s*['"]system['"]/, label: 'invalid role:system in channel params (Anthropic uses content+meta only)' },
  { re: /<<<<<<<|=======|>>>>>>>/, label: 'unresolved git merge conflict markers' },
];

const requiredSrc = [
  { re: /db-deliver bridge start/, label: 'full bridge boot marker' },
  { re: /LISTEN.*c_i_/, label: 'Postgres LISTEN on injection channel' },
  { re: /claimBatch/, label: 'DB claim_batch delivery' },
  { re: /renderHttpInject/, label: 'HTTP content+meta channel params' },
  { re: /renderInjection/, label: 'DB content+meta channel params' },
  { re: /notification-channel-sent/, label: 'single channel notify log' },
  { re: /http-port-busy|CCSC_HTTP_PORT_TRIES/, label: 'HTTP port fallback' },
  { re: /async function startHttpIngress/, label: 'HTTP /inject ingress' },
  { re: /pushInboundInjection/, label: 'NOTIFY -> channel push helper' },
];

for (const { re, label } of forbidden) {
  if (re.test(src)) fail(`src/index.ts contains forbidden: ${label}`);
  if (dist && re.test(dist)) fail(`dist/index.js contains forbidden: ${label}`);
}

for (const { re, label } of requiredSrc) {
  if (!re.test(src)) fail(`src/index.ts missing required: ${label}`);
}

if (dist && !/db-deliver bridge start/.test(dist)) {
  fail('dist/index.js missing db-deliver boot — run npm run build in ChannelBridge');
}

console.log('BRIDGE-CONTRACT PASS (src' + (dist ? ' + dist' : ', dist skipped') + ')');
