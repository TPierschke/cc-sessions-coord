// -----------------------------------------------------------------------------
// Bridge config (env vars + ~/.claude/coord-bridge.conf).
// -----------------------------------------------------------------------------
import fs from 'node:fs';
import path from 'node:path';

export interface BridgeConfig {
  pgUrl: string;
  sessionName: string;
  cwd: string;
}

function readConfFile(): Record<string, string> {
  const home = process.env.USERPROFILE || process.env.HOME || '';
  const file = path.join(home, '.claude', 'coord-bridge.conf');
  if (!fs.existsSync(file)) return {};
  const out: Record<string, string> = {};
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return out;
}

export function loadConfig(): BridgeConfig {
  const conf = readConfFile();
  const pgUrl =
    process.env.CCSC_DB_URL ||
    process.env.CCSC_PG_URL ||
    conf.CCSC_DB_URL ||
    conf.CCSC_PG_URL ||
    'postgres://ccsc_bridge@localhost:5432/cc_sessions_coord';

  // Optional: name can come from `claude --name ...` commandline parsing in index.ts.
  // Keep env as fallback only.
  const sessionName = (process.env.CCSC_SESSION_NAME || '').trim();
  return { pgUrl, sessionName, cwd: process.cwd() };
}

export function jsonlDirForCwd(cwd: string): string {
  // Anthropic encodes the cwd as: replace path separators / drive colons with '-'
  // Bsp:  C:\Users\Thomas\source\repos\Foo  ->  C--Users-Thomas-source-repos-Foo
  const enc = cwd.replace(/[\\/:]/g, '-');
  const home = process.env.USERPROFILE || process.env.HOME || '';
  return path.join(home, '.claude', 'projects', enc);
}
