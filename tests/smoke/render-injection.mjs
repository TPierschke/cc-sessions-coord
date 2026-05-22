/**
 * Minimal render smoke — JSON body unpacked; meta matches 0.3.9 contract.
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const renderPath = path.join(
  repoRoot,
  'src/CcSessionsCoord.ChannelBridge/dist/render.js',
);

function fail(msg) {
  console.error(`RENDER-SMOKE FAIL: ${msg}`);
  process.exit(1);
}

const renderUrl = new URL(`file:///${renderPath.replace(/\\/g, '/')}`).href;
let renderInjection;
let parseInjectBody;
try {
  ({ renderInjection, parseInjectBody } = await import(renderUrl));
} catch (e) {
  fail(`import: ${e.message} — run npm run build in ChannelBridge`);
}

const base = {
  id: 41,
  source_short_id: '0229d248',
  target_short_id: '91ed9313',
  kind: 'exec_dialog',
  priority: 0,
  expects_reply: true,
  reply_to_injection_id: null,
  payload: null,
  created_at: '2026-05-17T12:00:00.000Z',
};

const jsonInj = {
  ...base,
  inject_text:
    '{"payload":"Ping von mir --> Du antwortest mit Pong","dialog_id":"49b048cc-a22e-4ad1-8ac8-ebf680d783be"}',
};

const out = renderInjection(jsonInj);
if (out.content.includes('{"payload"')) fail('no raw JSON in content');
if (!out.content.includes('Ping von mir')) fail('payload text missing');
if (!out.content.includes('reply_to_injection_id=41')) fail('pong hint needs injection id');
if (out.meta.injection_id !== '41') fail('meta.injection_id');
if (out.meta.source_short_id !== '0229d248') fail('meta.source_short_id');
if (out.meta.dialog_id !== '49b048cc-a22e-4ad1-8ac8-ebf680d783be') fail('meta.dialog_id');

const parsed = parseInjectBody(jsonInj.inject_text);
if (parsed.payload !== 'Ping von mir --> Du antwortest mit Pong') fail('parseInjectBody');

console.log('RENDER-SMOKE PASS');
