// -----------------------------------------------------------------------------
// Postgres helpers — query client + dedicated LISTEN client.
// -----------------------------------------------------------------------------
import pg from 'pg';
import { log } from './log.js';

const { Client } = pg;

export interface RegisterArgs {
  sessionName: string;
  claudePid: number | null;
  claudePidStartMs: number | null;
  bridgePid: number;
  claudeSessionId: string | null;
  projectPath: string | null;
  jsonlPath: string | null;
  cwd: string | null;
  host: string;
}

export interface Injection {
  id: number;
  source_short_id: string | null;
  target_short_id: string;
  inject_text: string;
  kind: string;
  priority: number;
  expects_reply: boolean;
  reply_to_injection_id: number | null;
  payload: unknown;
  created_at: Date | string;
  delivered_at?: Date | string | null;
  delivered_via?: string | null;
  retry_count?: number;
}

export interface Session {
  short_id: string;
  session_name: string;
  display_name: string;
  status: string;
  claude_pid: number | null;
  bridge_pid: number | null;
  cwd: string | null;
  started_at: Date | string;
  last_seen: Date | string;
}

export interface HealthSummary {
  total: number;
  active: number;
  ended: number;
  unknown: number;
  stale: number;
  reachable: number;
  unreachable: number;
}

export class Db {
  readonly query: pg.Client;
  readonly listen: pg.Client;
  shortId: string = '';

  private constructor(query: pg.Client, listen: pg.Client) {
    this.query = query;
    this.listen = listen;
  }

  static async connect(connStr: string): Promise<Db> {
    const q = new Client({ connectionString: connStr });
    await q.connect();
    const l = new Client({ connectionString: connStr });
    await l.connect();
    return new Db(q, l);
  }

  async register(args: RegisterArgs): Promise<string> {
    const r = await this.query.query<{ ccsc_register_session: string }>(
      `SELECT coord.ccsc_register_session($1,$2,$3,$4,$5,$6,$7,$8,$9) AS short_id`,
      [
        args.sessionName,
        args.claudePid,
        args.claudePidStartMs,
        args.bridgePid,
        args.claudeSessionId,
        args.projectPath,
        args.jsonlPath,
        args.cwd,
        args.host,
      ],
    );
    const row = r.rows[0] as unknown as { short_id?: string; ccsc_register_session?: string };
    const shortId = (row?.short_id || row?.ccsc_register_session || '').trim();
    if (!shortId) throw new Error('ccsc_register_session returned no short_id');
    this.shortId = shortId;
    return shortId;
  }

  async claimBatch(): Promise<Injection[]> {
    const r = await this.query.query<Injection>(
      `SELECT id, source_short_id, target_short_id, inject_text, kind, priority,
              expects_reply, reply_to_injection_id, payload, created_at
         FROM coord.ccsc_claim_batch($1::char(8), 32)`,
      [this.shortId],
    );
    return r.rows;
  }

  async pullInbox(limit = 20, includeDelivered = true): Promise<Injection[]> {
    const n = Math.max(1, Math.min(100, Math.trunc(limit)));
    const base = `SELECT id, source_short_id, target_short_id, inject_text, kind, priority,
                         expects_reply, reply_to_injection_id, payload, created_at,
                         delivered_at, delivered_via, retry_count
                    FROM coord.injections
                   WHERE target_short_id = $1
                     AND (expires_at IS NULL OR expires_at > now())`;
    const sql = includeDelivered
      ? `${base} ORDER BY id DESC LIMIT $2`
      : `${base} AND delivered_at IS NULL ORDER BY id DESC LIMIT $2`;
    const r = await this.query.query<Injection>(sql, [this.shortId, n]);
    return r.rows.reverse();
  }

  async insertInjection(args: {
    sourceShort: string | null;
    targetShort: string;
    text: string;
    expectsReply: boolean;
    replyToId: number | null;
    priority: number;
    kind: string;
  }): Promise<number> {
    const r = await this.query.query<{ id: number }>(
      `INSERT INTO coord.injections
        (source_short_id, target_short_id, inject_text, kind, priority, expects_reply, reply_to_injection_id)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       RETURNING id`,
      [args.sourceShort, args.targetShort, args.text, args.kind, args.priority, args.expectsReply, args.replyToId],
    );
    return r.rows[0]!.id;
  }

  async reply(originalInjectId: number, text: string): Promise<number> {
    const r = await this.query.query<{ ccsc_reply: number }>(
      `SELECT coord.ccsc_reply($1::char(8), $2::bigint, $3) AS reply_id`,
      [this.shortId, originalInjectId, text],
    );
    const row = r.rows[0] as unknown as { reply_id?: number; ccsc_reply?: number };
    const id = row?.reply_id ?? row?.ccsc_reply;
    if (!id) throw new Error('ccsc_reply returned no id');
    return id;
  }

  async listSessions(): Promise<Session[]> {
    const r = await this.query.query<Session>(
      `SELECT short_id, session_name, COALESCE(display_name, session_name) AS display_name,
              status, claude_pid, bridge_pid, cwd, started_at, last_seen
         FROM coord.sessions
        ORDER BY (status='active') DESC, started_at DESC
        LIMIT 100`,
    );
    return r.rows;
  }

  /** Human label for channel render (display_name or session_name); empty if unknown. */
  async getSessionLabel(shortId: string | null | undefined): Promise<string> {
    if (!shortId?.trim()) return '';
    const r = await this.query.query<{ label: string }>(
      `SELECT COALESCE(display_name, session_name) AS label
         FROM coord.sessions
        WHERE short_id = $1
        LIMIT 1`,
      [shortId.toLowerCase()],
    );
    return r.rows[0]?.label?.trim() ?? '';
  }

  async getSession(target: string): Promise<Session | null> {
    const short = await this.resolveTarget(target);
    if (!short) return null;
    const r = await this.query.query<Session>(
      `SELECT short_id, session_name, COALESCE(display_name, session_name) AS display_name,
              status, claude_pid, bridge_pid, cwd, started_at, last_seen
         FROM coord.sessions
        WHERE short_id = $1
        LIMIT 1`,
      [short],
    );
    return r.rows[0] ?? null;
  }

  async getSessionByName(name: string): Promise<Session | null> {
    if (!name.trim()) return null;
    const r = await this.query.query<Session>(
      `SELECT short_id, session_name, COALESCE(display_name, session_name) AS display_name,
              status, claude_pid, bridge_pid, cwd, started_at, last_seen
         FROM coord.sessions
        WHERE lower(session_name) = lower($1) OR lower(display_name) = lower($1)
        ORDER BY (status='active') DESC, last_seen DESC
        LIMIT 1`,
      [name],
    );
    return r.rows[0] ?? null;
  }

  async healthSummary(staleSeconds = 120): Promise<HealthSummary> {
    const s = Math.max(30, Math.min(3600, Math.trunc(staleSeconds)));
    const r = await this.query.query<HealthSummary>(
      `SELECT
          COUNT(*)::int AS total,
          COUNT(*) FILTER (WHERE status='active')::int AS active,
          COUNT(*) FILTER (WHERE status='ended')::int AS ended,
          COUNT(*) FILTER (WHERE status NOT IN ('active','ended'))::int AS unknown,
          COUNT(*) FILTER (WHERE status='active' AND last_seen < now() - make_interval(secs => $1))::int AS stale,
          COUNT(*) FILTER (WHERE status='active' AND last_seen >= now() - make_interval(secs => $1))::int AS reachable,
          COUNT(*) FILTER (WHERE status='active' AND last_seen < now() - make_interval(secs => $1))::int AS unreachable
        FROM coord.sessions`,
      [s],
    );
    return (
      r.rows[0] ?? {
        total: 0,
        active: 0,
        ended: 0,
        unknown: 0,
        stale: 0,
        reachable: 0,
        unreachable: 0,
      }
    );
  }

  async resolveTarget(target: string): Promise<string | null> {
    if (/^[0-9a-f]{8}$/i.test(target)) {
      const r = await this.query.query<{ short_id: string; session_name: string; status: string }>(
        `SELECT short_id, session_name, status
           FROM coord.sessions
          WHERE short_id = $1`,
        [target.toLowerCase()],
      );
      const row = r.rows[0];
      if (!row) return null;
      const canonical = await this.query.query<{ short_id: string }>(
        `SELECT short_id FROM coord.sessions
          WHERE lower(session_name) = lower($1) AND status = 'active'
          ORDER BY last_seen DESC
          LIMIT 1`,
        [row.session_name],
      );
      return canonical.rows[0]?.short_id ?? (row.status === 'active' ? row.short_id : null);
    }
    const r = await this.query.query<{ short_id: string }>(
      `SELECT short_id FROM coord.sessions
        WHERE (lower(session_name)=lower($1) OR lower(display_name)=lower($1))
        ORDER BY (status='active') DESC, last_seen DESC
        LIMIT 1`, [target],
    );
    return r.rows[0]?.short_id ?? null;
  }

  async markEnded(): Promise<void> {
    if (!this.shortId) return;
    try {
      await this.query.query(
        `UPDATE coord.sessions SET status='ended', ended_at=now() WHERE short_id=$1 AND status='active'`,
        [this.shortId],
      );
    } catch (e) { log('mark-ended-failed', String(e)); }
  }

  async close(): Promise<void> {
    try { await this.listen.end(); } catch { /* ignore */ }
    try { await this.query.end();  } catch { /* ignore */ }
  }
}
