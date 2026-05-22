/**
 * E2E: spawn bridge, POST /inject with legacy payload, assert stdout gets
 * notifications/claude/channel with channel=ccsc (visible inject contract).
 *
 * Requires: npm run build in ChannelBridge, free TCP port (default 45888).
 * DB optional — bridge still serves HTTP if Postgres is down.
 */
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const BRIDGE = path.join(repoRoot, 'src/CcSessionsCoord.ChannelBridge/dist/index.js');
const HTTP_PORT = Number(process.env.CCSC_HTTP_PORT || '45888');

function delay(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function httpReq(port, method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port,
        path,
        method,
        headers: body
          ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
          : {},
        timeout: 3000,
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => resolve({ status: res.statusCode, body: raw }));
      },
    );
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('timeout'));
    });
    if (body) req.write(data);
    req.end();
  });
}

function postInject(port, body) {
  return httpReq(port, 'POST', '/inject', body);
}

/** Bridge may take several seconds for DB before HTTP listen. */
async function waitForHttpListener(basePort, tries = 32, timeoutMs = 45_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    for (let i = 0; i < tries; i++) {
      const port = basePort + i;
      try {
        const res = await httpReq(port, 'GET', '/inject');
        if (res.status === 404) return port;
      } catch (e) {
        if (e.code !== 'ECONNREFUSED' && e.message !== 'timeout') throw e;
      }
    }
    await delay(400);
  }
  throw new Error(`no HTTP listener on ${basePort}..${basePort + tries - 1} within ${timeoutMs}ms`);
}

async function main() {
  if (!process.env.CCSC_DB_URL) {
    process.env.CCSC_DB_URL =
      'postgres://ccsc_bridge:CHANGE_ME_ON_INSTALL@localhost:5432/cc_sessions_coord';
  }
  process.env.CCSC_SESSION_NAME = 'E2E-HttpInject';
  process.env.CCSC_HTTP_PORT = String(HTTP_PORT);

  const notifications = [];
  let buf = '';
  const proc = spawn(process.execPath, [BRIDGE], {
    env: { ...process.env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  proc.stdout.setEncoding('utf8');
  proc.stderr.setEncoding('utf8');
  proc.stdout.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj.method === 'notifications/claude/channel') notifications.push(obj.params);
      } catch { /* ignore */ }
    }
  });
  proc.stderr.on('data', (d) => process.stderr.write(`[bridge] ${d}`));

  const port = await waitForHttpListener(HTTP_PORT);
  const res = await postInject(port, {
    channel: 'ccsc',
    payload: 'bridge-http-inject e2e',
    injection_id: `e2e-${Date.now()}`,
    kind: 'inject',
    priority: 10,
    source_session_id: 'e2e-test',
  });

  if (res.status !== 202) {
    console.error('HTTP inject failed', res);
    proc.kill();
    process.exit(1);
  }

  await delay(500);

  const doc = notifications.find((p) => p && p.content && p.meta);

  if (!doc) {
    console.error('FAIL: no content+meta channel notification on stdout', notifications);
    proc.kill();
    process.exit(1);
  }
  if (typeof doc.meta.injection_id !== 'string') {
    console.error('FAIL: meta.injection_id must be string', doc.meta);
    proc.kill();
    process.exit(1);
  }

  console.log('OK: channel notification content=', String(doc.content).slice(0, 40));
  proc.stdin.end();
  await delay(300);
  try { proc.kill(); } catch { /* ignore */ }
  console.log('BRIDGE-HTTP-INJECT PASS');
}

main().catch((e) => {
  console.error('BRIDGE-HTTP-INJECT FAIL', e);
  process.exit(1);
});
