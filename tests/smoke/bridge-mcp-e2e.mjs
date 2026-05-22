// E2E: spawn 2 Bridge-Instanzen als stdio-MCP, schicke initialize+listTools,
// dann inject A->B mit expects_reply, claim by B via direct SQL (simuliert MCP-Tool),
// dann reply by B via SQL, claim by A.
//
// Idee: Wir koennen die Bridge nicht echt LLM-driven testen, aber wir koennen
// pruefen dass:
//   - Beide Bridges starten, registrieren sich, hoeren auf channels
//   - DB-INSERTs feuern NOTIFY auf richtigen channels
//   - Bridges senden notifications/claude/channel (via stdout JSON-RPC -- wir
//     parsen die Frames die ueber stdout kommen)

import { spawn } from 'node:child_process';
import pg from 'pg';
import path from 'node:path';
const { Client } = pg;

const BRIDGE = path.resolve('<repo-root>/src/CcSessionsCoord.ChannelBridge/dist/index.js');
const PG_URL = 'postgres://ccsc_bridge:CHANGE_ME_ON_INSTALL@localhost:5432/cc_sessions_coord';
const ADMIN_URL = 'postgres://postgres:mLgV64cbPnr2J1fiXAWsAIw07dVj@localhost:5432/cc_sessions_coord';

function delay(ms) { return new Promise(r => setTimeout(r, ms)); }

class BridgeProc {
  constructor(label, sessionName) {
    this.label = label;
    this.sessionName = sessionName;
    this.notifications = [];
    this.shortId = '';
    this._buf = '';
  }
  async start() {
    this.proc = spawn(process.execPath, [BRIDGE], {
      env: { ...process.env, CCSC_SESSION_NAME: this.sessionName, CCSC_DB_URL: PG_URL },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.proc.stdout.setEncoding('utf8');
    this.proc.stderr.setEncoding('utf8');
    this.proc.stdout.on('data', d => this._onStdout(d));
    this.proc.stderr.on('data', d => process.stderr.write(`[${this.label}] ${d}`));
    // MCP handshake (initialize + initialized)
    this._reqId = 1;
    await this._send({ jsonrpc: '2.0', id: this._reqId++, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: { experimental: { 'claude/channel': {} } }, clientInfo: { name: 'e2e-test', version: '1.0' } }});
    await delay(500);
    await this._send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    await delay(500);
    // Find own short_id via DB (we registered with CCSC_SESSION_NAME)
    const admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    const r = await admin.query(
      `SELECT short_id FROM coord.sessions WHERE session_name=$1 ORDER BY started_at DESC LIMIT 1`,
      [this.sessionName],
    );
    await admin.end();
    this.shortId = r.rows[0]?.short_id?.trim() || '';
    console.log(`[${this.label}] registered short_id=${this.shortId}`);
  }
  _send(obj) {
    return new Promise((resolve) => {
      this.proc.stdin.write(JSON.stringify(obj) + '\n', resolve);
    });
  }
  _onStdout(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf('\n')) >= 0) {
      const line = this._buf.substring(0, nl);
      this._buf = this._buf.substring(nl + 1);
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj.method === 'notifications/claude/channel') {
          this.notifications.push(obj.params);
          console.log(`[${this.label}] got channel notification: id=${obj.params?.meta?.injection_id} text="${obj.params?.content?.split('\n')[2]?.slice(0,40)}"`);
        }
      } catch { /* not JSON */ }
    }
  }
  async stop() {
    try {
      this.proc.stdin.end();
      await new Promise(r => this.proc.on('exit', r));
    } catch { /* ignore */ }
  }
}

async function main() {
  // Clean state
  const admin = new Client({ connectionString: ADMIN_URL });
  await admin.connect();
  await admin.query("TRUNCATE coord.activities, coord.hook_messages, coord.injections, coord.sessions CASCADE;");
  await admin.end();

  const A = new BridgeProc('A', 'E2E-Alice');
  const B = new BridgeProc('B', 'E2E-Bob');
  await A.start();
  await B.start();
  if (!A.shortId || !B.shortId) {
    console.error('FAIL: bridges did not register');
    await A.stop(); await B.stop();
    process.exit(1);
  }

  // A injects B with expects_reply (via SQL — same as MCP coord_inject would do)
  const sql = new Client({ connectionString: PG_URL });
  await sql.connect();
  const i1 = await sql.query(
    `INSERT INTO coord.injections(source_short_id, target_short_id, inject_text, expects_reply)
     VALUES ($1,$2,$3,$4) RETURNING id`,
    [A.shortId, B.shortId, 'antworte mit Pong', true],
  );
  const origId = i1.rows[0].id;
  console.log(`-> A injected #${origId} to B`);

  await delay(1500);

  // Verify B got the notification
  const aMsg = B.notifications.find(n => n.meta?.injection_id == origId);
  if (!aMsg) {
    console.error('FAIL: B did not receive notification', { count: B.notifications.length });
    await A.stop(); await B.stop(); await sql.end();
    process.exit(1);
  }
  console.log('OK: B received notification id=' + origId);

  // B replies
  const r1 = await sql.query(
    `SELECT coord.ccsc_reply($1::char(8), $2::bigint, $3) AS reply_id`,
    [B.shortId, origId, 'Pong'],
  );
  const replyId = r1.rows[0].reply_id;
  console.log(`-> B replied with #${replyId}`);

  await delay(1500);

  const reply = A.notifications.find(n => n.meta?.injection_id == replyId);
  if (!reply) {
    console.error('FAIL: A did not receive reply notification', { count: A.notifications.length });
    await A.stop(); await B.stop(); await sql.end();
    process.exit(1);
  }
  if (reply.meta?.reply_to_injection_id != origId) {
    console.error('FAIL: reply_to mismatch', reply.meta);
    await A.stop(); await B.stop(); await sql.end();
    process.exit(1);
  }
  console.log(`OK: A received reply id=${replyId} reply_to=${origId}`);

  await sql.end();
  await A.stop();
  await B.stop();

  console.log('E2E PINGPONG PASS');
}

main().catch(async e => { console.error('E2E FAIL', e); process.exit(1); });
