import os from 'node:os';
import http from 'node:http';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { loadConfig } from './config.js';
import { Db, type Injection } from './db.js';
import { resolveClaudeNameFromParent, resolveClaudePidAndStartMs } from './pid-utils.js';
import { log, logFatal } from './log.js';

function quoteIdent(name: string): string {
  if (!/^[a-z][a-z0-9_]{0,62}$/i.test(name)) {
    throw new Error(`invalid channel name: ${name}`);
  }
  return name;
}

function toLegacyChannelParams(inj: Injection): Record<string, unknown> {
  return {
    channel: 'ccsc',
    injection_id: String(inj.id),
    source_session_id: inj.source_short_id ?? '',
    kind: inj.kind || 'inject',
    priority: inj.priority,
    payload: inj.inject_text,
    expires_at: new Date(Date.now() + 3600_000).toISOString(),
  };
}

function toDocChannelParams(inj: Injection): Record<string, unknown> {
  return {
    content: inj.inject_text,
    meta: {
      source_session_id: inj.source_short_id ?? '',
      target_short_id: inj.target_short_id,
      injection_id: String(inj.id),
      kind: inj.kind || 'inject',
      priority: String(inj.priority),
    },
  };
}

async function startHttpIngress(mcp: Server): Promise<void> {
  const host = process.env.CCSC_HTTP_HOST || '127.0.0.1';
  const port = Number(process.env.CCSC_HTTP_PORT || '45777');
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/inject') {
      res.statusCode = 404;
      res.end('not-found');
      return;
    }
    let raw = '';
    req.on('data', (d) => { raw += d.toString('utf8'); });
    req.on('end', async () => {
      try {
        const body = JSON.parse(raw) as {
          content?: string;
          payload?: string;
          kind?: string;
          priority?: number;
          source_session_id?: string;
        };
        const payload = String(body.content ?? body.payload ?? '');
        if (!payload) {
          res.statusCode = 400;
          res.end('content-required');
          return;
        }
        await mcp.notification({
          method: 'notifications/claude/channel',
          params: {
            channel: 'ccsc',
            injection_id: `http-${Date.now()}`,
            source_session_id: String(body.source_session_id ?? 'http'),
            kind: String(body.kind ?? 'inject'),
            priority: Number.isFinite(body.priority as number) ? Number(body.priority) : 5,
            payload,
            expires_at: new Date(Date.now() + 3600_000).toISOString(),
          },
        } as never);
        // #region agent log
        fetch('http://127.0.0.1:7915/ingest/389c2d2e-b626-4002-818a-45cb78da7d56',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'fa9281'},body:JSON.stringify({sessionId:'fa9281',runId:'pre-fix',hypothesisId:'H13',location:'index.ts:startHttpIngress',message:'http ingress forwarded to claude/channel',data:{host,port,payloadLen:payload.length},timestamp:Date.now()})}).catch(()=>{});
        // #endregion
        log('http-inject-forwarded', '', { host, port });
        res.statusCode = 202;
        res.end('ok');
      } catch (e) {
        log('http-inject-failed', String(e));
        res.statusCode = 500;
        res.end('error');
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve());
  });
  log('http-ingress-listening', '', { host, port });
}

async function main(): Promise<void> {
  log('boot', 'minimal bridge start', { pid: process.pid, cwd: process.cwd() });
  const httpOnly = process.env.CCSC_HTTP_ONLY === '1';
  const cfg = loadConfig();
  let effectiveSessionName = cfg.sessionName;
  try {
    const nameFromClaude = await resolveClaudeNameFromParent(process.ppid);
    if (nameFromClaude) {
      if (effectiveSessionName && nameFromClaude !== effectiveSessionName) {
        log('session-name-overridden', `${effectiveSessionName} -> ${nameFromClaude}`, { source: 'claude-commandline' });
      }
      effectiveSessionName = nameFromClaude;
      // #region agent log
      fetch('http://127.0.0.1:7915/ingest/389c2d2e-b626-4002-818a-45cb78da7d56',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'fa9281'},body:JSON.stringify({sessionId:'fa9281',runId:'pre-fix',hypothesisId:'H15',location:'index.ts:main',message:'override session name from claude --name argument',data:{configName:cfg.sessionName,derivedName:nameFromClaude},timestamp:Date.now()})}).catch(()=>{});
      // #endregion
    }
  } catch (e) {
    log('session-name-derive-failed', String(e));
  }
  if (!effectiveSessionName) {
    throw new Error('session name unresolved: neither CCSC_SESSION_NAME nor claude --name detected');
  }

  const mcp = new Server(
    { name: 'ccsc-channel-bridge', version: '0.2.0-minimal' },
    { capabilities: { tools: {}, experimental: { 'claude/channel': {} } } },
  );
  const transport = new StdioServerTransport();
  await mcp.connect(transport);
  log('mcp-connected');

  if (httpOnly) {
    await startHttpIngress(mcp);
    process.stdin.on('end', () => process.exit(0));
    process.stdin.on('close', () => process.exit(0));
    return;
  }

  const db = await Db.connect(cfg.pgUrl);

  const shortId = await db.register({
    sessionName: effectiveSessionName,
    claudePid: null,
    claudePidStartMs: null,
    bridgePid: process.pid,
    claudeSessionId: null,
    projectPath: cfg.cwd,
    jsonlPath: null,
    cwd: cfg.cwd,
    host: os.hostname(),
  });
  log('session-registered', shortId);

  void (async () => {
    try {
      const probe = await resolveClaudePidAndStartMs(process.ppid);
      if (!probe) return;
      await db.query.query(
        `UPDATE coord.sessions SET claude_pid=$2, claude_pid_start_time=$3 WHERE short_id=$1`,
        [shortId, probe.pid, probe.startMs],
      );
      log('pid-probe', `claude.exe=${probe.pid}`);
    } catch (e) {
      log('pid-probe-failed', String(e));
    }
  })();

  async function pushInjection(inj: Injection): Promise<void> {
    try {
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: toDocChannelParams(inj),
      } as never);
      log('notification-doc-sent', `id=${inj.id}`);
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: toLegacyChannelParams(inj),
      } as never);
      log('notification-legacy-sent', `id=${inj.id}`);
      // #region agent log
      fetch('http://127.0.0.1:7915/ingest/389c2d2e-b626-4002-818a-45cb78da7d56',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'fa9281'},body:JSON.stringify({sessionId:'fa9281',runId:'pre-fix',hypothesisId:'H14',location:'index.ts:minimal.pushInjection',message:'minimal bridge sent doc+legacy channel notifications',data:{shortId,injectionId:inj.id,targetShortId:inj.target_short_id},timestamp:Date.now()})}).catch(()=>{});
      // #endregion
    } catch (e) {
      log('notification-failed', String(e), { id: inj.id });
    }
  }

  async function drain(reason: string): Promise<void> {
    try {
      const rows = await db.claimBatch();
      if (rows.length > 0) {
        log('drain', reason, { count: rows.length, ids: rows.map((x) => x.id) });
      }
      for (const r of rows) await pushInjection(r);
    } catch (e) {
      log('drain-failed', String(e), { reason });
    }
  }

  db.listen.on('notification', (msg) => {
    log('notify', msg.channel ?? '?', { payload: msg.payload });
    void drain(msg.channel ?? 'unknown');
  });

  await db.listen.query(`LISTEN ${quoteIdent(`c_i_${shortId}`)}`);
  await db.listen.query(`LISTEN ${quoteIdent(`c_h_${shortId}`)}`);
  log('listening', '', { channels: [`c_i_${shortId}`, `c_h_${shortId}`] });

  await drain('initial');

  const heartbeat = setInterval(() => {
    void db.query.query(
      `UPDATE coord.sessions SET last_seen=now() WHERE short_id=$1`,
      [shortId],
    ).catch((e) => log('heartbeat-failed', String(e)));
  }, 30_000);

  const shutdown = async (why: string) => {
    log('shutdown', why);
    clearInterval(heartbeat);
    try { await db.markEnded(); } catch { /* ignore */ }
    try { await db.close(); } catch { /* ignore */ }
    process.exit(0);
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));

  process.stdin.on('end', () => void shutdown('stdin-end'));
  process.stdin.on('close', () => void shutdown('stdin-close'));
}

main().catch((e) => {
  logFatal(e);
  process.exit(1);
});
