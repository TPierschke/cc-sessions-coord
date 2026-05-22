// Verbose push-path trace — separate JSONL for correlating NOTIFY → claim → MCP notify.
import fs from 'node:fs';
import path from 'node:path';
import type { Injection } from './db.js';

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const TRACE_DIR = path.join(HOME, '.claude', 'channels', 'ccsc-channel-bridge');
const TRACE_FILE = path.join(TRACE_DIR, `bridge-${process.pid}-push-trace.jsonl`);

try {
  fs.mkdirSync(TRACE_DIR, { recursive: true });
} catch {
  /* ignore */
}

export interface PushTraceContext {
  bridgePid: number;
  bridgePpid: number;
  sessionName: string;
  shortId: string;
  listenChannels: string[];
  httpPort: number | null;
}

let ctx: PushTraceContext | null = null;

export function setPushTraceContext(next: PushTraceContext): void {
  ctx = next;
}

export function setPushTraceHttpPort(port: number | null): void {
  if (ctx) ctx.httpPort = port;
}

function trimText(s: string, max = 800): string {
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…[+${s.length - max} chars]`;
}

function injSnapshot(inj: Injection): Record<string, unknown> {
  return {
    id: inj.id,
    target_short_id: inj.target_short_id,
    source_short_id: inj.source_short_id,
    kind: inj.kind,
    priority: inj.priority,
    reply_to_injection_id: inj.reply_to_injection_id,
    expects_reply: inj.expects_reply,
    inject_text_preview: trimText(inj.inject_text),
    inject_text_len: inj.inject_text.length,
  };
}

export function logPushTrace(
  event: string,
  extra?: Record<string, unknown>,
  opts?: { params?: unknown },
): void {
  const now = Date.now();
  const row: Record<string, unknown> = {
    ts: new Date(now).toISOString(),
    t_ms: now,
    event,
    bridge_pid: process.pid,
    bridge_ppid: process.ppid,
    ...(ctx
      ? {
          session_name: ctx.sessionName,
          short_id: ctx.shortId,
          listen_channels: ctx.listenChannels,
          http_port: ctx.httpPort,
        }
      : {}),
    ...(extra ?? {}),
  };
  if (opts?.params !== undefined) {
    row.params_json = JSON.stringify(opts.params);
    try {
      const p = opts.params as { content?: string; meta?: Record<string, unknown> };
      if (typeof p.content === 'string') {
        row.content_preview = trimText(p.content);
        row.content_len = p.content.length;
      }
      if (p.meta) row.meta = p.meta;
    } catch {
      /* ignore */
    }
  }
  const line = `${JSON.stringify(row)}\n`;
  try {
    fs.appendFileSync(TRACE_FILE, line, 'utf8');
  } catch {
    /* ignore */
  }
  try {
    process.stderr.write(`[push-trace] ${line}`);
  } catch {
    /* ignore */
  }
}

export function logPushTraceNotify(
  pgChannel: string,
  notifyPayload: string | undefined,
  reason: string,
): void {
  logPushTrace('notify-received', {
    pg_channel: pgChannel,
    notify_payload: notifyPayload ?? '',
    notify_payload_num: notifyPayload ? Number(notifyPayload) : null,
    drain_reason: reason,
  });
}

export function logPushTraceClaim(
  reason: string,
  notifyPayload: string | undefined,
  rows: Injection[],
): void {
  const ids = rows.map((r) => String(r.id));
  const payloadNum = notifyPayload ? Number(notifyPayload) : null;
  const mismatch =
    payloadNum !== null &&
    Number.isFinite(payloadNum) &&
    ids.length > 0 &&
    !ids.includes(String(payloadNum));
  logPushTrace('claim-batch-result', {
    drain_reason: reason,
    notify_payload: notifyPayload ?? '',
    notify_payload_num: payloadNum,
    claimed_count: ids.length,
    claimed_ids: ids,
    claimed_rows: rows.map(injSnapshot),
    notify_id_not_in_claimed: mismatch,
  });
}

export function logPushTracePush(
  pathKind: 'db' | 'http',
  inj: Injection | null,
  shape: 'channel' | 'rendered' | 'legacy' | 'http-legacy' | 'http-meta',
  params: unknown,
  reqId?: string,
): void {
  logPushTrace(
    'mcp-channel-push',
    {
      path: pathKind,
      shape,
      req_id: reqId ?? '',
      ...(inj ? injSnapshot(inj) : {}),
    },
    { params },
  );
}
