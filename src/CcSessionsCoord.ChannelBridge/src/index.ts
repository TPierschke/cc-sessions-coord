import http from 'node:http';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { loadConfig } from './config.js';
import { Db, type Injection, type Session } from './db.js';
import { log, logFatal } from './log.js';
import { resolveClaudeNameFromParent, resolveClaudePidAndStartMs } from './pid-utils.js';
import {
  logPushTrace,
  logPushTraceClaim,
  logPushTraceNotify,
  logPushTracePush,
  setPushTraceContext,
  setPushTraceHttpPort,
} from './push-trace.js';
import { renderHttpInject, renderInjection } from './render.js';

function quoteIdent(name: string): string {
  if (!/^[a-z][a-z0-9_]{0,62}$/i.test(name)) {
    throw new Error(`invalid channel name: ${name}`);
  }
  return name;
}

async function pushInboundInjection(mcp: McpServer, inj: Injection): Promise<void> {
  const params = renderInjection(inj);
  logPushTracePush('db', inj, 'channel', params);
  try {
    await mcp.server.notification({
      method: 'notifications/claude/channel',
      params: params as never,
    });
    log('notification-channel-sent', '', { id: inj.id });
    logPushTrace('mcp-channel-push-ok', { path: 'db', shape: 'channel', injection_id: inj.id });
  } catch (e) {
    log('notification-channel-failed', String(e), { id: inj.id });
    logPushTrace('mcp-channel-push-failed', {
      path: 'db',
      shape: 'channel',
      injection_id: inj.id,
      error: String(e),
    });
    throw e;
  }
}

let reqSeq = 0;
function nextReqId(): string {
  reqSeq += 1;
  return `${process.pid}-${Date.now()}-${reqSeq}`;
}

function toolText(text: string): { content: Array<{ type: 'text'; text: string }> } {
  return { content: [{ type: 'text', text }] };
}

function toolJson(data: unknown): { content: Array<{ type: 'text'; text: string }> } {
  return toolText(JSON.stringify(data, null, 2));
}

function formatSession(row: Session): Record<string, unknown> {
  return {
    short_id: row.short_id,
    session_name: row.session_name,
    display_name: row.display_name,
    status: row.status,
    claude_pid: row.claude_pid,
    bridge_pid: row.bridge_pid,
    cwd: row.cwd,
    started_at: row.started_at,
    last_seen: row.last_seen,
  };
}

function pickSelfSession(sessions: Session[], sessionName: string): Session | null {
  const name = sessionName.trim().toLowerCase();
  if (!name) return null;
  return (
    sessions.find((s) => s.session_name.toLowerCase() === name || s.display_name.toLowerCase() === name) ??
    null
  );
}

async function resolveSelfShortId(db: Db, sessionName: string): Promise<string | null> {
  if (!sessionName.trim()) return null;
  const self = await db.getSessionByName(sessionName);
  return self?.short_id ?? null;
}

async function enqueueToTarget(db: Db, args: {
  target: string;
  text: string;
  kind: string;
  priority?: number;
  expectsReply?: boolean;
  replyToId?: number | null;
  sourceShort?: string | null;
}): Promise<{ ok: boolean; injection_id?: number; target_short_id?: string; error?: string }> {
  const targetShort = await db.resolveTarget(args.target);
  if (!targetShort) {
    return { ok: false, error: `target not found: ${args.target}` };
  }

  const id = await db.insertInjection({
    sourceShort: args.sourceShort ?? null,
    targetShort,
    text: args.text,
    kind: args.kind,
    priority: args.priority ?? 10,
    expectsReply: args.expectsReply ?? false,
    replyToId: args.replyToId ?? null,
  });
  return { ok: true, injection_id: id, target_short_id: targetShort };
}

async function enqueueToMany(db: Db, args: {
  targets: string[];
  text: string;
  kind: string;
  priority?: number;
  sourceShort?: string | null;
}): Promise<Array<{ target_short_id: string; injection_id: number }>> {
  const rows: Array<{ target_short_id: string; injection_id: number }> = [];
  for (const targetShort of args.targets) {
    const id = await db.insertInjection({
      sourceShort: args.sourceShort ?? null,
      targetShort,
      text: args.text,
      kind: args.kind,
      priority: args.priority ?? 10,
      expectsReply: false,
      replyToId: null,
    });
    rows.push({ target_short_id: targetShort, injection_id: id });
  }
  return rows;
}

function registerBatch1Tools(mcp: McpServer, db: Db | null, sessionName: string): void {
  mcp.registerTool('coord_whoami', {
    description: 'Show current bridge session identity and DB mapping.',
  }, async () => {
    if (!db) return toolText('coord_whoami: DB unavailable');
    const sessions = await db.listSessions();
    const self = pickSelfSession(sessions, sessionName);
    return toolJson({
      session_name: sessionName || null,
      resolved_self: self ? formatSession(self) : null,
      db_connected: true,
      visible_sessions: sessions.length,
    });
  });

  mcp.registerTool('coord_health', {
    description: 'Summarize global coord session health.',
    inputSchema: {
      stale_seconds: z.number().int().min(30).max(3600).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_health: DB unavailable');
    const staleSeconds = args.stale_seconds ?? 120;
    const health = await db.healthSummary(staleSeconds);
    return toolJson({
      stale_seconds: staleSeconds,
      ...health,
      checked_at: new Date().toISOString(),
    });
  });

  mcp.registerTool('coord_info_self', {
    description: 'Show detail information for this session.',
  }, async () => {
    if (!db) return toolText('coord_info_self: DB unavailable');
    const sessions = await db.listSessions();
    const self = pickSelfSession(sessions, sessionName);
    if (!self) {
      return toolJson({
        session_name: sessionName || null,
        found: false,
        reason: 'self session not found in coord.sessions',
      });
    }
    return toolJson({
      found: true,
      session: formatSession(self),
    });
  });

  mcp.registerTool('coord_info_session', {
    description: 'Show detail information for a target session.',
    inputSchema: {
      target: z.string().min(1),
    },
  }, async (args) => {
    if (!db) return toolText('coord_info_session: DB unavailable');
    const row = await db.getSession(args.target);
    if (!row) {
      return toolJson({
        target: args.target,
        found: false,
      });
    }
    return toolJson({
      target: args.target,
      found: true,
      session: formatSession(row),
    });
  });

  mcp.registerTool('coord_neighbours', {
    description: 'List neighbour sessions in the same project cwd.',
    inputSchema: {
      limit: z.number().int().min(1).max(200).optional(),
      include_ended: z.boolean().optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_neighbours: DB unavailable');
    const limit = args.limit ?? 20;
    const includeEnded = args.include_ended ?? false;
    const sessions = await db.listSessions();
    const self = pickSelfSession(sessions, sessionName);
    if (!self?.cwd) {
      return toolJson({
        session_name: sessionName || null,
        found: false,
        reason: 'self session cwd missing',
      });
    }

    let neighbours = sessions.filter((s) => s.short_id !== self.short_id && s.cwd === self.cwd);
    if (!includeEnded) neighbours = neighbours.filter((s) => s.status === 'active');
    neighbours = neighbours.slice(0, limit);

    return toolJson({
      self_short_id: self.short_id,
      cwd: self.cwd,
      count: neighbours.length,
      sessions: neighbours.map(formatSession),
    });
  });

  mcp.registerTool('coord_all', {
    description: 'List all visible sessions with optional filtering.',
    inputSchema: {
      limit: z.number().int().min(1).max(200).optional(),
      status: z.enum(['active', 'ended', 'all']).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_all: DB unavailable');
    const limit = args.limit ?? 100;
    const status = args.status ?? 'all';
    let sessions = await db.listSessions();
    if (status !== 'all') sessions = sessions.filter((s) => s.status === status);
    sessions = sessions.slice(0, limit);
    return toolJson({
      count: sessions.length,
      status_filter: status,
      sessions: sessions.map(formatSession),
    });
  });

  mcp.registerTool('coord_exec', {
    description: 'Send fire-and-forget execution order to one target session.',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_exec: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.payload,
      kind: 'exec',
      priority: args.priority ?? 10,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_exec_dialog', {
    description: 'Send execution dialog request (response expected) to one target session.',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1),
      dialog_id: z.string().min(1).optional(),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_exec_dialog: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const dialogId = args.dialog_id ?? randomUUID();
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: JSON.stringify({ dialog_id: dialogId, payload: args.payload }),
      kind: 'exec_dialog',
      priority: args.priority ?? 10,
      expectsReply: true,
      sourceShort,
    });
    return toolJson({ dialog_id: dialogId, ...result });
  });

  mcp.registerTool('coord_exec_response', {
    description: 'Send textual response for an exec dialog step.',
    inputSchema: {
      target: z.string().min(1),
      dialog_id: z.string().min(1),
      reply_to_injection_id: z.number().int().positive(),
      payload: z.string().min(1),
      status: z.enum(['ok', 'error']).optional(),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_exec_response: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: JSON.stringify({
        dialog_id: args.dialog_id,
        status: args.status ?? 'ok',
        payload: args.payload,
      }),
      kind: 'exec_response',
      priority: args.priority ?? 10,
      replyToId: args.reply_to_injection_id,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_exec_reply', {
    description: 'Send short ack/ping style reply (non-dialog).',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1),
      reply_to_injection_id: z.number().int().positive().optional(),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_exec_reply: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.payload,
      kind: 'exec_reply',
      priority: args.priority ?? 10,
      replyToId: args.reply_to_injection_id ?? null,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_info', {
    description: 'Send informational message to one target session.',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_info: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.payload,
      kind: 'info',
      priority: args.priority ?? 7,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_alert', {
    description: 'Send alert message to one target session.',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1),
      priority: z.number().int().min(1).max(10).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_alert: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.payload,
      kind: 'alert',
      priority: args.priority ?? 10,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_stop', {
    description: 'Request cooperative stop for one target session.',
    inputSchema: {
      target: z.string().min(1),
      reason: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_stop: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.reason ?? 'stop requested',
      kind: 'stop',
      priority: 10,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_alertstop', {
    description: 'Request immediate emergency stop for one target session.',
    inputSchema: {
      target: z.string().min(1),
      reason: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_alertstop: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.reason ?? 'alert stop requested',
      kind: 'alertstop',
      priority: 10,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_broadcast_status', {
    description: 'Broadcast status request to all active neighbour sessions.',
    inputSchema: {
      payload: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_broadcast_status: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const sessions = await db.listSessions();
    const targets = sessions
      .filter((s) => s.status === 'active' && s.short_id !== sourceShort)
      .map((s) => s.short_id);
    const sent = await enqueueToMany(db, {
      targets,
      text: args.payload ?? 'broadcast_status',
      kind: 'broadcast_status',
      priority: 7,
      sourceShort,
    });
    return toolJson({ count: sent.length, sent });
  });

  mcp.registerTool('coord_broadcast_ping', {
    description: 'Broadcast ping to all active neighbour sessions.',
  }, async () => {
    if (!db) return toolText('coord_broadcast_ping: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const sessions = await db.listSessions();
    const targets = sessions
      .filter((s) => s.status === 'active' && s.short_id !== sourceShort)
      .map((s) => s.short_id);
    const sent = await enqueueToMany(db, {
      targets,
      text: 'broadcast_ping',
      kind: 'broadcast_ping',
      priority: 7,
      sourceShort,
    });
    return toolJson({ count: sent.length, sent });
  });

  mcp.registerTool('coord_broadcast_sync', {
    description: 'Broadcast sync request to all active neighbour sessions.',
    inputSchema: {
      payload: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_broadcast_sync: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const sessions = await db.listSessions();
    const targets = sessions
      .filter((s) => s.status === 'active' && s.short_id !== sourceShort)
      .map((s) => s.short_id);
    const sent = await enqueueToMany(db, {
      targets,
      text: args.payload ?? 'broadcast_sync',
      kind: 'broadcast_sync',
      priority: 7,
      sourceShort,
    });
    return toolJson({ count: sent.length, sent });
  });

  mcp.registerTool('coord_notaus', {
    description: 'Emergency stop for one target session.',
    inputSchema: {
      target: z.string().min(1),
      reason: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_notaus: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: args.reason ?? 'notaus',
      kind: 'notaus',
      priority: 10,
      sourceShort,
    });
    return toolJson(result);
  });

  mcp.registerTool('coord_notaus_all', {
    description: 'Emergency stop broadcast to all active sessions (except self).',
    inputSchema: {
      reason: z.string().min(1).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_notaus_all: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const sessions = await db.listSessions();
    const targets = sessions
      .filter((s) => s.status === 'active' && s.short_id !== sourceShort)
      .map((s) => s.short_id);
    const sent = await enqueueToMany(db, {
      targets,
      text: args.reason ?? 'notaus_all',
      kind: 'notaus',
      priority: 10,
      sourceShort,
    });
    return toolJson({ count: sent.length, sent });
  });

  mcp.registerTool('coord_pong', {
    description:
      'Reply to a ping/exec_dialog (pong). Sends exec_response to the peer that expects an answer.',
    inputSchema: {
      target: z.string().min(1),
      reply_to_injection_id: z.number().int().positive(),
      payload: z.string().min(1),
      dialog_id: z.string().min(1).optional(),
      status: z.enum(['ok', 'error']).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_pong: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const dialogId = args.dialog_id ?? `pong-${args.reply_to_injection_id}`;
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: JSON.stringify({
        dialog_id: dialogId,
        status: args.status ?? 'ok',
        payload: args.payload,
      }),
      kind: 'exec_response',
      priority: 10,
      replyToId: args.reply_to_injection_id,
      sourceShort,
    });
    return toolJson({ dialog_id: dialogId, ...result });
  });

  mcp.registerTool('coord_start_pingpong', {
    description:
      'Start ping-pong with another session: sends a ping (expects pong). Target sees how to answer via coord_pong.',
    inputSchema: {
      target: z.string().min(1),
      payload: z.string().min(1).optional(),
      rounds: z.number().int().min(1).max(20).optional(),
    },
  }, async (args) => {
    if (!db) return toolText('coord_start_pingpong: DB unavailable');
    const sourceShort = await resolveSelfShortId(db, sessionName);
    const fromLabel = sessionName || sourceShort || '?';
    const pingText = args.payload ?? `Ping from ${fromLabel}`;
    const rounds = args.rounds ?? 5;
    const dialogId = randomUUID();
    const body = [
      `PING from ${fromLabel} (ping-pong, up to ${rounds} rounds).`,
      '',
      pingText,
      '',
      'How to PONG:',
      `  coord_pong(target="${fromLabel}", reply_to_injection_id=<see injection_id below>, payload="<your text>")`,
      '  dialog_id is returned in the ping tool result.',
      '  Or use coord_exec_response with the same parameters.',
      '',
      'If this session is idle: press Enter or run /mcp once, then call the tool.',
    ].join('\n');
    const result = await enqueueToTarget(db, {
      target: args.target,
      text: JSON.stringify({ dialog_id: dialogId, payload: body }),
      kind: 'pingpong',
      priority: 10,
      expectsReply: true,
      sourceShort,
    });
    return toolJson({
      dialog_id: dialogId,
      rounds_planned: rounds,
      ping_text: pingText,
      ...result,
    });
  });
}

async function startHttpIngress(mcp: McpServer): Promise<void> {
  const host = process.env.CCSC_HTTP_HOST || '127.0.0.1';
  const basePort = Number(process.env.CCSC_HTTP_PORT || '45777');
  log('http-ingress-config', '', { host, basePort });

  const server = http.createServer((req, res) => {
    const reqId = nextReqId();
    const startMs = Date.now();
    const remoteAddress = req.socket.remoteAddress ?? '';
    const remotePort = req.socket.remotePort ?? null;
    const userAgent = String(req.headers['user-agent'] ?? '');
    log('http-request-start', '', {
      reqId,
      method: req.method ?? '',
      url: req.url ?? '',
      remoteAddress,
      remotePort,
      contentLength: String(req.headers['content-length'] ?? ''),
      contentType: String(req.headers['content-type'] ?? ''),
      userAgent,
    });

    res.on('finish', () => {
      log('http-response-finish', '', {
        reqId,
        statusCode: res.statusCode,
        durationMs: Date.now() - startMs,
      });
    });

    if (req.method !== 'POST' || req.url !== '/inject') {
      res.statusCode = 404;
      res.end('not-found');
      log('http-request-ignored', '', { reqId, reason: 'route-not-found' });
      return;
    }

    let raw = '';
    req.on('data', (d) => {
      raw += d.toString('utf8');
      log('http-request-chunk', '', { reqId, chunkBytes: d.length, totalBytes: raw.length });
    });
    req.on('error', (e) => {
      log('http-request-error', String(e), { reqId });
    });

    req.on('end', async () => {
      log('http-request-end', '', { reqId, rawBytes: raw.length });
      try {
        const body = JSON.parse(raw) as {
          content?: string;
          payload?: string;
          kind?: string;
          priority?: number;
          source_session_id?: string;
        };
        log('http-body-parsed', '', {
          reqId,
          hasContent: body.content !== undefined,
          hasPayload: body.payload !== undefined,
          hasKind: body.kind !== undefined,
          hasPriority: body.priority !== undefined,
          hasSourceSessionId: body.source_session_id !== undefined,
        });

        const payload = String(body.content ?? body.payload ?? '');
        if (!payload) {
          res.statusCode = 400;
          res.end('content-required');
          log('http-inject-rejected', '', { reqId, reason: 'empty-payload' });
          return;
        }

        const injectionId = `http-${Date.now()}`;
        const kind = String(body.kind ?? 'inject');
        const priority = String(
          Number.isFinite(body.priority as number) ? Number(body.priority) : 5,
        );
        const sourceSessionId = String(body.source_session_id ?? 'http');
        log('mcp-notification-send-start', '', {
          reqId,
          injectionId,
          payloadChars: payload.length,
          kind,
          priority,
          sourceSessionId,
        });

        const sendStart = Date.now();
        const prioNum = Number.isFinite(body.priority as number) ? Number(body.priority) : 5;
        const channelParams = renderHttpInject({
          content: payload,
          injectionId,
          kind,
          priority: prioNum,
          sourceSessionId,
        });
        logPushTracePush('http', null, 'channel', channelParams, reqId);
        try {
          await mcp.server.notification({
            method: 'notifications/claude/channel',
            params: channelParams as never,
          });
          log('mcp-notification-channel-sent', '', { reqId, injectionId });
          logPushTrace('mcp-channel-push-ok', {
            path: 'http',
            shape: 'channel',
            req_id: reqId,
            injection_id: injectionId,
          });
        } catch (e) {
          log('mcp-notification-channel-failed', String(e), { reqId, injectionId });
          logPushTrace('mcp-channel-push-failed', {
            path: 'http',
            shape: 'channel',
            req_id: reqId,
            error: String(e),
          });
          throw e;
        }
        log('mcp-notification-send-ok', '', {
          reqId,
          injectionId,
          durationMs: Date.now() - sendStart,
        });

        log('http-inject-forwarded', '', {
          reqId,
          host,
          port: process.env.CCSC_HTTP_ACTUAL_PORT ?? basePort,
          injectionId,
          payloadChars: payload.length,
        });
        res.statusCode = 202;
        res.end('ok');
      } catch (e) {
        log('http-inject-failed', String(e), { reqId, rawSample: raw.slice(0, 300) });
        res.statusCode = 500;
        res.end('error');
      }
    });
  });

  server.on('error', (e) => {
    log('http-server-error', String(e), { host, basePort });
  });

  const maxAttempts = Number(process.env.CCSC_HTTP_PORT_TRIES || '32');
  let boundPort = basePort;
  let lastErr: Error | undefined;
  for (let i = 0; i < maxAttempts; i++) {
    boundPort = basePort + i;
    try {
      await new Promise<void>((resolve, reject) => {
        const onErr = (e: Error): void => {
          server.off('error', onErr);
          reject(e);
        };
        server.once('error', onErr);
        server.listen(boundPort, host, () => {
          server.off('error', onErr);
          resolve();
        });
      });
      lastErr = undefined;
      break;
    } catch (e) {
      const err = e as NodeJS.ErrnoException;
      lastErr = err as Error;
      if (err.code !== 'EADDRINUSE') throw err;
      log('http-port-busy', '', { host, triedPort: boundPort, next: boundPort + 1 });
    }
  }
  if (lastErr) throw lastErr;

  process.env.CCSC_HTTP_ACTUAL_PORT = String(boundPort);
  log('http-ingress-listening', '', {
    host,
    port: boundPort,
    note: boundPort !== basePort ? 'CCSC_HTTP_PORT was busy; using next free port' : 'using requested base port',
  });
}

async function main(): Promise<void> {
  log('boot', 'db-deliver bridge start', {
    pid: process.pid,
    ppid: process.ppid,
    cwd: process.cwd(),
    node: process.version,
    platform: process.platform,
    argv: process.argv,
  });

  let db: Db | null = null;
  let heartbeat: ReturnType<typeof setInterval> | undefined;

  const shutdown = (why: string): void => {
    log('shutdown', why);
    void (async () => {
      if (heartbeat) clearInterval(heartbeat);
      try {
        await db?.markEnded();
      } catch {
        // ignore
      }
      try {
        await db?.close();
      } catch {
        // ignore shutdown close errors
      }
      process.exit(0);
    })();
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('beforeExit', (code) => {
    log('process-before-exit', '', { code });
  });
  process.on('exit', (code) => {
    log('process-exit', '', { code });
  });
  process.on('uncaughtException', (e) => {
    logFatal(e);
  });
  process.on('unhandledRejection', (reason) => {
    log('unhandled-rejection', String(reason));
  });

  const cfg = loadConfig();
  const nameFromParents = await resolveClaudeNameFromParent(process.ppid).catch(() => null);
  const sessionFromClaude = (nameFromParents ?? '').trim();
  let effectiveSessionName = (cfg.sessionName || '').trim();
  if (sessionFromClaude) {
    if (effectiveSessionName && effectiveSessionName !== sessionFromClaude) {
      log('session-name-overridden', `${effectiveSessionName} -> ${sessionFromClaude}`, {
        source: 'claude-commandline',
      });
    }
    effectiveSessionName = sessionFromClaude;
  }

  const mcp = new McpServer(
    { name: 'ccsc-channel-bridge', version: '0.3.11' },
    {
      capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
      instructions:
        'Coordinator injections arrive as <channel> messages from ccsc-channel-bridge. ' +
        'When you receive one, read meta.injection_id and meta.source_short_id. ' +
        'Prefer target session names (e.g. T92) over hex short_id when calling coord_* tools. ' +
        'If expects_reply is true, reply with coord_pong or coord_exec_response. ' +
        'Treat channel messages like a coworker interrupt — acknowledge and act, do not ignore.',
    },
  );

  try {
    db = await Db.connect(cfg.pgUrl);
    log('db-connected', '', { hasSessionName: !!effectiveSessionName });
  } catch (e) {
    log('db-connect-failed', String(e));
  }
  registerBatch1Tools(mcp, db, effectiveSessionName);

  const transport = new StdioServerTransport();
  log('mcp-connect-start');
  await mcp.connect(transport);
  log('mcp-connected');

  if (db && effectiveSessionName) {
    let shortId: string;
    try {
      shortId = await db.register({
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
          await db!.query.query(
            `UPDATE coord.sessions SET claude_pid=$2, claude_pid_start_time=$3 WHERE short_id=$1`,
            [shortId, probe.pid, probe.startMs],
          );
          log('pid-probe', `claude.exe=${probe.pid}`);
        } catch (e) {
          log('pid-probe-failed', String(e));
        }
      })();

      const listenChannels = [`c_i_${shortId}`, `c_h_${shortId}`];
      setPushTraceContext({
        bridgePid: process.pid,
        bridgePpid: process.ppid,
        sessionName: effectiveSessionName,
        shortId,
        listenChannels,
        httpPort: null,
      });
      logPushTrace('bridge-push-trace-ready', {
        note: 'full MCP channel params logged to bridge-*-push-trace.jsonl',
      });

      async function drain(reason: string, notifyPayload?: string): Promise<void> {
        try {
          if (notifyPayload !== undefined) {
            logPushTraceNotify(reason, notifyPayload, reason);
          }
          const rows = await db!.claimBatch();
          logPushTraceClaim(reason, notifyPayload, rows);
          if (rows.length > 0) {
            log('drain', reason, { count: rows.length, ids: rows.map((x) => x.id) });
          }
          for (const inj of rows) {
            try {
              await pushInboundInjection(mcp, inj);
            } catch {
              /* pushInboundInjection already logged */
            }
          }
        } catch (e) {
          log('drain-failed', String(e), { reason });
          logPushTrace('drain-failed', { reason, error: String(e) });
        }
      }

      db.listen.on('notification', (msg) => {
        log('notify', msg.channel ?? '?', { payload: msg.payload });
        void drain(msg.channel ?? 'unknown', msg.payload ?? undefined);
      });

      await db.listen.query(`LISTEN ${quoteIdent(`c_i_${shortId}`)}`);
      await db.listen.query(`LISTEN ${quoteIdent(`c_h_${shortId}`)}`);
      log('listening', '', { channels: listenChannels });

      await drain('initial');

      heartbeat = setInterval(() => {
        void db!
          .query.query(`UPDATE coord.sessions SET last_seen=now() WHERE short_id=$1`, [shortId])
          .catch((e) => log('heartbeat-failed', String(e)));
      }, 30_000);
    } catch (e) {
      log('session-register-or-listen-failed', String(e));
    }
  } else if (db && !effectiveSessionName) {
    log(
      'listen-skipped',
      'No session name: use claude --name ... or CCSC_SESSION_NAME — DB tools without target id, no NOTIFY receive',
      {},
    );
  }

  await startHttpIngress(mcp);
  const httpPort = Number(process.env.CCSC_HTTP_ACTUAL_PORT || process.env.CCSC_HTTP_PORT || '0') || null;
  if (httpPort) {
    setPushTraceHttpPort(httpPort);
    logPushTrace('http-ingress-bound', { http_port: httpPort });
  }
  process.stdin.on('end', () => shutdown('stdin-end'));
  process.stdin.on('close', () => shutdown('stdin-close'));
}

main().catch((e) => {
  logFatal(e);
  process.exit(1);
});
