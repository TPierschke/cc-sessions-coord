// Smoke-Test: Bridge-DB-Logic ohne MCP-Stack.
// Simuliert zwei Sessions, sendet Inject + Reply, prueft NOTIFY/LISTEN end-to-end.
//
// Usage (vom Bridge-Verzeichnis aus, damit node 'pg' findet):
//   cd src/CcSessionsCoord.ChannelBridge
//   node ../../../tests/smoke/pingpong-smoke.mjs

import pg from 'pg';
const { Client } = pg;

const url = process.env.CCSC_DB_URL ||
  'postgres://ccsc_bridge:CHANGE_ME_ON_INSTALL@localhost:5432/cc_sessions_coord';
const adminUrl = process.env.CCSC_ADMIN_DB_URL || '';

async function client(u = url) {
  const c = new Client({ connectionString: u });
  await c.connect();
  return c;
}

function delay(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  if (adminUrl) {
    const admin = await client(adminUrl);
    await admin.query("TRUNCATE coord.activities, coord.hook_messages, coord.injections, coord.sessions CASCADE;");
    await admin.end();
  }

  const A_query = await client();
  const A_listen = await client();
  const B_query = await client();
  const B_listen = await client();

  const shortA = (await A_query.query(
    `SELECT coord.ccsc_register_session($1,$2,$3,$4,$5,$6,$7,$8,$9) AS short_id`,
    ['SmokeA', 1001, 1000, 9001, null, 'C:/test', null, 'C:/test', 'localhost']
  )).rows[0].short_id.trim();
  const shortB = (await B_query.query(
    `SELECT coord.ccsc_register_session($1,$2,$3,$4,$5,$6,$7,$8,$9) AS short_id`,
    ['SmokeB', 1002, 1000, 9002, null, 'C:/test', null, 'C:/test', 'localhost']
  )).rows[0].short_id.trim();
  console.log('A=', shortA, 'B=', shortB);

  const notifs = { A: [], B: [] };
  A_listen.on('notification', (m) => { notifs.A.push(m); console.log('A got notify:', m.channel, m.payload); });
  B_listen.on('notification', (m) => { notifs.B.push(m); console.log('B got notify:', m.channel, m.payload); });
  await A_listen.query(`LISTEN c_i_${shortA}`);
  await B_listen.query(`LISTEN c_i_${shortB}`);

  const insertedA = await A_query.query(
    `INSERT INTO coord.injections(source_short_id, target_short_id, inject_text, expects_reply)
     VALUES ($1,$2,$3,$4) RETURNING id`,
    [shortA, shortB, 'antworte mit Pong', true]
  );
  console.log('A inserted inject id=', insertedA.rows[0].id);
  await delay(500);

  const claimed = await B_query.query(
    `SELECT * FROM coord.ccsc_claim_batch($1::char(8), 32)`, [shortB]
  );
  console.log('B claimed', claimed.rowCount, 'rows');
  if (claimed.rowCount === 0) { console.error('FAIL: B claimed nothing'); process.exit(1); }
  const origId = claimed.rows[0].id;
  if (!claimed.rows[0].expects_reply) { console.error('FAIL: expects_reply lost'); process.exit(1); }

  const replyR = await B_query.query(
    `SELECT coord.ccsc_reply($1::char(8), $2::bigint, $3) AS reply_id`,
    [shortB, origId, 'Pong']
  );
  console.log('B sent reply id=', replyR.rows[0].reply_id);
  await delay(500);

  const aClaim = await A_query.query(
    `SELECT * FROM coord.ccsc_claim_batch($1::char(8), 32)`, [shortA]
  );
  if (aClaim.rowCount === 0) { console.error('FAIL: A claimed nothing on reply'); process.exit(1); }
  const reply = aClaim.rows[0];
  if (Number(reply.reply_to_injection_id) !== Number(origId)) {
    console.error('FAIL: reply_to_injection_id mismatch', { expect: origId, got: reply.reply_to_injection_id });
    process.exit(1);
  }
  if (reply.kind !== 'reply') { console.error('FAIL: kind not reply'); process.exit(1); }
  console.log('OK: pingpong roundtrip',
    { origId, replyId: reply.id, replyText: reply.inject_text, kind: reply.kind });
  console.log('notifs counts:', { A: notifs.A.length, B: notifs.B.length });

  await A_query.end(); await A_listen.end();
  await B_query.end(); await B_listen.end();
  console.log('SMOKE PASS');
}

main().catch(e => { console.error('SMOKE FAIL', e); process.exit(1); });
