// -----------------------------------------------------------------------------
// Bridge logger — per-PID file in %USERPROFILE%/.claude/channels/ccsc-channel-bridge,
// stderr mirror. stdout is reserved for MCP JSON-RPC.
// -----------------------------------------------------------------------------
import fs from 'node:fs';
import path from 'node:path';

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const LOG_DIR = path.join(HOME, '.claude', 'channels', 'ccsc-channel-bridge');
const LOG_FILE = path.join(LOG_DIR, `bridge-${process.pid}.log`);

try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch { /* ignore */ }

export function log(event: string, msg: string = '', extra?: Record<string, unknown>): void {
  const now = Date.now();
  const ts = new Date(now).toISOString();
  const uptimeMs = Math.round(process.uptime() * 1000);
  const payload = {
    ts,
    t_ms: now,
    uptime_ms: uptimeMs,
    pid: process.pid,
    ppid: process.ppid,
    event,
    msg,
    ...(extra ?? {}),
  };
  const line = `${JSON.stringify(payload)}\n`;
  try { fs.appendFileSync(LOG_FILE, line, 'utf8'); } catch { /* ignore */ }
  try { process.stderr.write(line); } catch { /* ignore */ }
}

export function logFatal(e: unknown): void {
  log('fatal', String(e), { stack: (e as Error)?.stack });
}
