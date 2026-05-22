-- V002 — one active short_id per session_name on bridge (re)register without claude_session_id
-- Fixes NOTIFY to c_i_<stale_short_id> when bridge restarts and gets a new short_id.

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
               ended_at = NULL,
               last_seen = now()
         WHERE claude_session_id = p_claude_session_id
        RETURNING short_id INTO v_short;
        IF v_short IS NOT NULL THEN RETURN v_short; END IF;
    END IF;

    UPDATE coord.sessions
       SET status = 'ended',
           ended_at = now()
     WHERE lower(session_name) = lower(p_session_name)
       AND status = 'active';

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
