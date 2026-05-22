-- V001 — cc-sessions-coord DB-zentrierte Architektur (greenfield rewrite)
-- Datum: 2026-05-14
-- Quelle: docs/spec/2026-05-14-db-centric-architecture-spec.md
--
-- Komplettes Greenfield. Vorher:
--   psql -U postgres -f scripts/reset-db.sql
--   psql -U postgres -d cc_sessions_coord -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
--   psql -U postgres -d cc_sessions_coord -f migrations/V001__initial.sql

CREATE SCHEMA IF NOT EXISTS coord;

-- 1. Sessions ----------------------------------------------------------------
CREATE TABLE coord.sessions (
    short_id              char(8)     PRIMARY KEY CHECK (short_id ~ '^[0-9a-f]{8}$'),
    claude_session_id     uuid        UNIQUE,
    session_name          text        NOT NULL,
    display_name          text,
    host                  text        NOT NULL DEFAULT 'localhost',
    claude_pid            int,
    claude_pid_start_time bigint,
    bridge_pid            int,
    project_path          text,
    jsonl_path            text,
    cwd                   text,
    status                text        NOT NULL DEFAULT 'active'
                                      CHECK (status IN ('active','ended','stale')),
    started_at            timestamptz NOT NULL DEFAULT now(),
    ended_at              timestamptz,
    last_seen             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_sessions_status ON coord.sessions(status);
CREATE INDEX ix_sessions_claude_pid ON coord.sessions(claude_pid) WHERE claude_pid IS NOT NULL;

-- 2. Injections --------------------------------------------------------------
CREATE TABLE coord.injections (
    id                    bigserial   PRIMARY KEY,
    source_short_id       char(8)     REFERENCES coord.sessions(short_id),
    target_short_id       char(8)     NOT NULL REFERENCES coord.sessions(short_id),
    inject_text           text        NOT NULL,
    kind                  text        NOT NULL DEFAULT 'inject',
    priority              int         NOT NULL DEFAULT 2,
    expects_reply         boolean     NOT NULL DEFAULT false,
    reply_to_injection_id bigint      REFERENCES coord.injections(id),
    payload               jsonb       NOT NULL DEFAULT '{}'::jsonb
                                      CHECK (octet_length(payload::text) <= 65536),
    created_at            timestamptz NOT NULL DEFAULT now(),
    expires_at            timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    delivered_at          timestamptz,
    delivered_via         text,
    retry_count           int         NOT NULL DEFAULT 0
);
CREATE INDEX ix_injections_target_undeliv
    ON coord.injections(target_short_id, priority DESC, id)
    WHERE delivered_at IS NULL;

-- 3. Activities --------------------------------------------------------------
CREATE TABLE coord.activities (
    id          bigserial   PRIMARY KEY,
    short_id    char(8)     NOT NULL REFERENCES coord.sessions(short_id),
    tool        text        NOT NULL,
    path        text,
    args_hash   text,
    payload     jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_activities_path_time
    ON coord.activities(path, created_at DESC)
    WHERE path IS NOT NULL;
CREATE INDEX ix_activities_short_time ON coord.activities(short_id, created_at DESC);

-- 4. Hook-Messages -----------------------------------------------------------
CREATE TABLE coord.hook_messages (
    id              bigserial   PRIMARY KEY,
    target_short_id char(8)     NOT NULL REFERENCES coord.sessions(short_id),
    kind            text        NOT NULL,
    payload         jsonb       NOT NULL DEFAULT '{}'::jsonb
                                CHECK (octet_length(payload::text) <= 65536),
    created_at      timestamptz NOT NULL DEFAULT now(),
    delivered_at    timestamptz
);
CREATE INDEX ix_hook_messages_target_undeliv
    ON coord.hook_messages(target_short_id, id)
    WHERE delivered_at IS NULL;

-- 5. Triggers ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION coord.trg_inj_notify() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('c_i_' || NEW.target_short_id, NEW.id::text);
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_injections_notify
    AFTER INSERT ON coord.injections
    FOR EACH ROW EXECUTE FUNCTION coord.trg_inj_notify();

CREATE OR REPLACE FUNCTION coord.trg_hook_notify() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('c_h_' || NEW.target_short_id, NEW.id::text);
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_hook_messages_notify
    AFTER INSERT ON coord.hook_messages
    FOR EACH ROW EXECUTE FUNCTION coord.trg_hook_notify();

-- 6. Claim-Functions ---------------------------------------------------------
CREATE OR REPLACE FUNCTION coord.ccsc_claim_batch(p_short char(8), p_max int DEFAULT 32)
RETURNS TABLE (
    id                    bigint,
    source_short_id       char(8),
    target_short_id       char(8),
    inject_text           text,
    kind                  text,
    priority              int,
    expects_reply         boolean,
    reply_to_injection_id bigint,
    payload               jsonb,
    created_at            timestamptz
) LANGUAGE sql AS $$
    WITH c AS (
        SELECT i.id FROM coord.injections i
         WHERE i.target_short_id = p_short
           AND i.delivered_at IS NULL
           AND (i.expires_at IS NULL OR i.expires_at > now())
         ORDER BY i.priority DESC, i.id ASC
         FOR UPDATE SKIP LOCKED
         LIMIT p_max
    )
    UPDATE coord.injections i
       SET delivered_at = now(), delivered_via = 'channel'
      FROM c
     WHERE i.id = c.id
    RETURNING i.id, i.source_short_id, i.target_short_id, i.inject_text, i.kind,
              i.priority, i.expects_reply, i.reply_to_injection_id, i.payload,
              i.created_at;
$$;

CREATE OR REPLACE FUNCTION coord.ccsc_claim_next(p_short char(8))
RETURNS TABLE (
    id                    bigint,
    source_short_id       char(8),
    target_short_id       char(8),
    inject_text           text,
    kind                  text,
    priority              int,
    expects_reply         boolean,
    reply_to_injection_id bigint,
    payload               jsonb,
    created_at            timestamptz
) LANGUAGE sql AS $$
    SELECT * FROM coord.ccsc_claim_batch(p_short, 1);
$$;

-- 7. Conflict-Check ----------------------------------------------------------
CREATE OR REPLACE FUNCTION coord.ccsc_check_conflict(
    p_short char(8), p_tool text, p_path text
) RETURNS TABLE (
    conflict_short    char(8),
    conflict_display  text,
    last_touch        timestamptz
) LANGUAGE sql STABLE AS $$
    SELECT a.short_id, COALESCE(s.display_name, s.session_name), a.created_at
      FROM coord.activities a
      JOIN coord.sessions s ON s.short_id = a.short_id
     WHERE a.path = p_path
       AND a.short_id <> p_short
       AND a.tool IN ('Edit','Write','MultiEdit')
       AND a.created_at > now() - interval '30 seconds'
     ORDER BY a.created_at DESC
     LIMIT 1;
$$;

-- 8. Session-Registrierung ---------------------------------------------------
CREATE OR REPLACE FUNCTION coord.ccsc_register_session(
    p_session_name        text,
    p_claude_pid          int,
    p_claude_pid_start    bigint,
    p_bridge_pid          int,
    p_claude_session_id   uuid,
    p_project_path        text,
    p_jsonl_path          text,
    p_cwd                 text,
    p_host                text DEFAULT 'localhost'
) RETURNS char(8) LANGUAGE plpgsql AS $$
DECLARE
    v_short char(8);
    v_try   int := 0;
BEGIN
    IF p_claude_session_id IS NOT NULL THEN
        UPDATE coord.sessions
           SET session_name = COALESCE(session_name, p_session_name),
               claude_pid = p_claude_pid,
               claude_pid_start_time = p_claude_pid_start,
               bridge_pid = p_bridge_pid,
               project_path = COALESCE(project_path, p_project_path),
               jsonl_path = COALESCE(jsonl_path, p_jsonl_path),
               cwd = COALESCE(cwd, p_cwd),
               host = p_host,
               status = 'active',
               last_seen = now()
         WHERE claude_session_id = p_claude_session_id
        RETURNING short_id INTO v_short;
        IF v_short IS NOT NULL THEN RETURN v_short; END IF;
    END IF;

    LOOP
        v_short := lower(encode(gen_random_bytes(4), 'hex'));
        BEGIN
            INSERT INTO coord.sessions(
                short_id, claude_session_id, session_name,
                claude_pid, claude_pid_start_time, bridge_pid,
                project_path, jsonl_path, cwd, host
            ) VALUES (
                v_short, p_claude_session_id, p_session_name,
                p_claude_pid, p_claude_pid_start, p_bridge_pid,
                p_project_path, p_jsonl_path, p_cwd, p_host
            );
            RETURN v_short;
        EXCEPTION WHEN unique_violation THEN
            v_try := v_try + 1;
            IF v_try > 5 THEN RAISE EXCEPTION 'short_id exhausted after % retries', v_try; END IF;
        END;
    END LOOP;
END $$;

-- 9. Reply-Helper ------------------------------------------------------------
CREATE OR REPLACE FUNCTION coord.ccsc_reply(
    p_source_short       char(8),
    p_original_inject_id bigint,
    p_text               text
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_orig coord.injections%ROWTYPE;
    v_id   bigint;
BEGIN
    SELECT * INTO v_orig FROM coord.injections WHERE id = p_original_inject_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'original injection % not found', p_original_inject_id;
    END IF;
    IF v_orig.source_short_id IS NULL THEN
        RAISE EXCEPTION 'original injection % has no source', p_original_inject_id;
    END IF;

    INSERT INTO coord.injections(
        source_short_id, target_short_id, inject_text, kind,
        priority, expects_reply, reply_to_injection_id
    ) VALUES (
        p_source_short, v_orig.source_short_id, p_text, 'reply',
        2, false, p_original_inject_id
    )
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- 10. Rollen -----------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ccsc_bridge') THEN
        CREATE ROLE ccsc_bridge LOGIN PASSWORD 'CHANGE_ME_ON_INSTALL';
    END IF;
END $$;

GRANT USAGE ON SCHEMA coord TO ccsc_bridge;
GRANT SELECT, INSERT, UPDATE ON coord.sessions, coord.injections, coord.hook_messages TO ccsc_bridge;
GRANT SELECT, INSERT ON coord.activities TO ccsc_bridge;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA coord TO ccsc_bridge;
GRANT EXECUTE ON FUNCTION
    coord.ccsc_claim_batch(char, int),
    coord.ccsc_claim_next(char),
    coord.ccsc_register_session(text, int, bigint, int, uuid, text, text, text, text),
    coord.ccsc_reply(char, bigint, text)
    TO ccsc_bridge;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ccsc_hook') THEN
        CREATE ROLE ccsc_hook LOGIN PASSWORD 'CHANGE_ME_ON_INSTALL';
    END IF;
END $$;

GRANT USAGE ON SCHEMA coord TO ccsc_hook;
GRANT SELECT ON coord.sessions, coord.activities TO ccsc_hook;
GRANT INSERT ON coord.activities, coord.injections TO ccsc_hook;
GRANT UPDATE (status, ended_at, last_seen, display_name) ON coord.sessions TO ccsc_hook;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA coord TO ccsc_hook;
GRANT EXECUTE ON FUNCTION coord.ccsc_check_conflict(char, text, text) TO ccsc_hook;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ccsc_worker') THEN
        CREATE ROLE ccsc_worker LOGIN PASSWORD 'CHANGE_ME_ON_INSTALL';
    END IF;
END $$;

GRANT USAGE ON SCHEMA coord TO ccsc_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA coord TO ccsc_worker;
GRANT UPDATE (display_name, session_name, status, ended_at, last_seen) ON coord.sessions TO ccsc_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA coord TO ccsc_worker;
