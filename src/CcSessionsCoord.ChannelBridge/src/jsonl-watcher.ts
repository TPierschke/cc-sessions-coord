// -----------------------------------------------------------------------------
// JSONL-Watcher for own session. Defense-in-Depth against worker tail watcher:
// parses user-slash commands from our JSONL file and applies UPDATE idempotently.
// -----------------------------------------------------------------------------
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import type { Db } from './db.js';
import { jsonlDirForCwd } from './config.js';
import { log } from './log.js';

interface State { filePath: string; offset: number; }

export function startJsonlWatcher(db: Db, cwd: string, abort: AbortController): void {
  void (async () => {
    const dir = jsonlDirForCwd(cwd);
    let state: State | null = null;
    while (!abort.signal.aborted) {
      try {
        const file = pickLatestJsonl(dir);
        if (file) {
          if (!state || state.filePath !== file) {
            state = { filePath: file, offset: 0 };
            log('jsonl-tracking', file);
          }
          await tailOnce(state, db);
        }
      } catch (e) {
        log('jsonl-watch-error', String(e));
      }
      await delay(2000, undefined, { signal: abort.signal }).catch(() => undefined);
    }
  })();
}

function pickLatestJsonl(dir: string): string | null {
  try {
    if (!fs.existsSync(dir)) return null;
    const files = fs.readdirSync(dir)
      .filter(n => n.endsWith('.jsonl'))
      .map(n => ({ full: path.join(dir, n), mt: fs.statSync(path.join(dir, n)).mtimeMs }))
      .sort((a, b) => b.mt - a.mt);
    return files[0]?.full ?? null;
  } catch {
    return null;
  }
}

async function tailOnce(state: State, db: Db): Promise<void> {
  let stat: fs.Stats;
  try { stat = fs.statSync(state.filePath); }
  catch { return; }
  if (stat.size === state.offset) return;
  if (stat.size < state.offset) state.offset = 0;

  const fh = await fs.promises.open(state.filePath, 'r');
  try {
    let pos = state.offset;
    let leftover = '';
    const buf = Buffer.alloc(64 * 1024);
    while (pos < stat.size) {
      const { bytesRead } = await fh.read(buf, 0, buf.length, pos);
      if (bytesRead <= 0) break;
      const chunk = leftover + buf.subarray(0, bytesRead).toString('utf8');
      const lines = chunk.split('\n');
      leftover = lines.pop() ?? '';
      for (const line of lines) {
        await processLine(line, db);
      }
      pos += bytesRead;
    }
    state.offset = pos - Buffer.byteLength(leftover, 'utf8');
  } finally {
    await fh.close();
  }
}

async function processLine(line: string, db: Db): Promise<void> {
  const s = line.trim();
  if (!s || !s.startsWith('{')) return;
  if (!s.includes('"role":"user"')) return;
  let obj: any;
  try { obj = JSON.parse(s); } catch { return; }
  const msg = obj?.message;
  if (!msg || msg.role !== 'user') return;
  let content = '';
  if (typeof msg.content === 'string') content = msg.content;
  else if (Array.isArray(msg.content)) {
    content = msg.content
      .map((c: any) => (typeof c?.text === 'string' ? c.text : ''))
      .join(' ');
  }
  content = content.trim();
  if (!content) return;

  for (const prefix of ['/coord-rename ', '/rename ']) {
    if (content.toLowerCase().startsWith(prefix)) {
      const name = content.substring(prefix.length).trim();
      if (!name) return;
      try {
        await db.query.query(
          `UPDATE coord.sessions SET session_name=$2, display_name=$2, last_seen=now()
            WHERE short_id=$1 AND (session_name IS DISTINCT FROM $2 OR display_name IS DISTINCT FROM $2)`,
          [db.shortId, name],
        );
        log('rename-applied', name);
      } catch (e) {
        log('rename-failed', String(e));
      }
      return;
    }
  }
}
