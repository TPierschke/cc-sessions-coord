import fs from 'node:fs';
import path from 'node:path';

export interface QueuedInject {
  id: string;
  target_session_name: string;
  source_short_id: string;
  text: string;
  kind: string;
  priority: number;
  expects_reply: boolean;
  created_at: number;
}

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const DIR = path.join(HOME, '.claude', 'channels', 'ccsc-channel-bridge');
const FILE = path.join(DIR, 'pre-session-queue.jsonl');

function ensureDir(): void {
  try { fs.mkdirSync(DIR, { recursive: true }); } catch { /* ignore */ }
}

function parseLines(): QueuedInject[] {
  ensureDir();
  if (!fs.existsSync(FILE)) return [];
  const rows: QueuedInject[] = [];
  const lines = fs.readFileSync(FILE, 'utf8').split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    try {
      const x = JSON.parse(line) as QueuedInject;
      if (!x?.id || !x?.target_session_name || !x?.source_short_id || !x?.text) continue;
      rows.push(x);
    } catch {
      // ignore malformed line
    }
  }
  return rows;
}

function writeAll(rows: QueuedInject[]): void {
  ensureDir();
  if (rows.length === 0) {
    try { fs.rmSync(FILE, { force: true }); } catch { /* ignore */ }
    return;
  }
  const body = rows.map((r) => JSON.stringify(r)).join('\n') + '\n';
  fs.writeFileSync(FILE, body, 'utf8');
}

export function enqueuePreSessionInject(x: Omit<QueuedInject, 'id' | 'created_at'>): QueuedInject {
  const row: QueuedInject = {
    ...x,
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    created_at: Date.now(),
  };
  const rows = parseLines();
  rows.push(row);
  writeAll(rows);
  return row;
}

export function claimPreSessionInjects(targetSessionName: string): QueuedInject[] {
  const rows = parseLines();
  const want = targetSessionName.trim().toLowerCase();
  const claimed: QueuedInject[] = [];
  const keep: QueuedInject[] = [];
  for (const r of rows) {
    if ((r.target_session_name || '').trim().toLowerCase() === want) claimed.push(r);
    else keep.push(r);
  }
  writeAll(keep);
  return claimed;
}

