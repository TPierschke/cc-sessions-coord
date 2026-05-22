# cc-sessions-coord — DB-zentrierte Architektur (Spec)

**Datum:** 2026-05-14
**Status:** Entwurf, gruene Wiese (alte DB wird verworfen) — Council R3
**Basis:** Council-Bericht `2026-05-14-db-centric-architecture-council.md`
**Plattform:** PostgreSQL 14+ (Floor), Bridge auf Primary, kein Streaming-Replica davor.

---

## 1. Uebersicht

Postgres ist die zentrale Push-Achse. Jede Claude-Sitzung haengt mit einer Bridge per LISTEN auf zwei eigenen Channels. Hooks und Worker schreiben in Tabellen, Trigger feuern NOTIFY, die Bridge holt die Row und stellt sie ueber `notifications/claude/channel` an `claude.exe` zu. Der Worker ist reduziert auf `/health` + `/dashboard` + einen JSONL-Tail-Watcher fuer Slash-Commands.

```
+-------------+   spawn   +-----------+  stdio  +---------------+
|  cc-yolo PS |---------> | claude.exe| <-----> | Bridge (TS)   |
|  Wrapper    | ENV=NAME  | (LLM)     |         | stdio-MCP     |
+-------------+           +-----------+         +-------+-------+
                               ^                        |
                               | PreToolUse/PostUse     | LISTEN c_i_<sid>
                               |  Hooks (PS, psql)      | LISTEN c_h_<sid>
                               v                        v
                          +------------------ Postgres -------------+
                          | coord.sessions / .injections /          |
                          | .activities / .hook_messages            |
                          | + triggers: pg_notify('c_i_<sid>', id)  |
                          +-----------------------------------------+
                                          ^
                                          | tail JSONL + watchdog
                                          |
                                    +-----+-----+
                                    | Worker    |
                                    | /health   |
                                    | /dashboard|
                                    +-----------+
```

Komponenten: **cc-yolo** (PS-Wrapper), **Bridge** (Node/TS stdio-MCP), **Hooks** (PowerShell), **Worker** (.NET, schlank), **Postgres-Schema** (`coord.*`).

---

## 2. Komponenten-Detail

### 2.1 `cc-yolo` Wrapper (PowerShell)

Vor jedem `claude`-Start muss ein menschlicher Name gesetzt sein. Aufrufe:

- `cc-yolo MeinName` oder `cc-yolo Mein Name` (Args werden via `($args -join ' ').Trim()` zusammengezogen)
- `cc-yolo -r MeinName` — Resume einer Sitzung mit gleichem Namen, sonst Fehler
- `cc-yolo -r` — Resume-Picker (listet bestehende JSONL-Sessions im aktuellen Projekt)
- `cc-yolo` ohne Arg → `Read-Host -Prompt 'Session-Name'`, leere Eingabe bricht ab

Der Wrapper setzt `$env:CCSC_SESSION_NAME = $name` und ruft `& claude --dangerously-skip-permissions @PassThruArgs`. Vor dem Start wird `claude --version` geprueft. Keine DB-Schreibarbeit im Wrapper — die Bridge legt die Sitzung an, sobald sie startet.

### 2.2 Bridge (Node/TS, stdio-MCP)

Startet als MCP-Subprocess von `claude.exe`. Beim Handshake:

1. Liest `CCSC_SESSION_NAME`, `CCSC_PG_*` aus ENV. Fehlt der Name → MCP-Init-Fehler, claude.exe bricht ab.
2. Connect zu Postgres als Rolle `ccsc_bridge` (siehe 4.3).
3. `SELECT coord.ccsc_register_session($uuid, $name, $host, $pid, $jsonl, $cwd)` — Postgres vergibt `short_id` server-seitig und legt Row idempotent an (Resume sicher). Bridge erhaelt das Ergebnis und merkt es sich fuer die Session.
4. `LISTEN c_i_<short_id>` (Inject) und `LISTEN c_h_<short_id>` (Hook-Push).
5. Pruefung der Client-Capability `experimental.claude/channel`. Fehlt sie → Bridge meldet das via MCP-Tool-Output, faellt auf Pull-Tool `coord_pull_pending` zurueck.

Bei NOTIFY: Bridge ruft `SELECT * FROM coord.ccsc_claim_batch($short_id, 32)` (siehe 4.1) — drained alle pending Rows in einer Loop, sendet jede als `notifications/claude/channel` mit `{role: 'system', content: row.payload, meta: {kind, injection_id, source_session, created_at}}`.

Zusatz-Pfad: Bridge `fs.watch`-t die eigene JSONL-Datei (`~/.claude/projects/<enc-cwd>/<id>.jsonl`) und parsed neue Zeilen mit `customTitle` → `UPDATE coord.sessions SET display_name = ...`. Defense-in-Depth gegen den Worker-Watcher.

Exposed MCP-Tools: `coord_status`, `coord_inject`, `coord_rename`, `coord_resolve_conflict`, `coord_pull_pending` (Fallback).

### 2.3 Hooks (PowerShell)

Nur noch drei aktive Hooks:

- **PreToolUse** — laeuft synchron vor jedem `Edit|Write|MultiEdit`-Tool-Call. Macht eine `psql -c "SELECT * FROM coord.ccsc_check_conflict($sid, $tool, $path)"`-Query mit **`statement_timeout=80ms`** (lokale DB) bzw. **`200ms`** (Remote, ueber `CCSC_HOOK_TIMEOUT_MS` konfigurierbar). Returnt die Function eine Row, schreibt der Hook `{"decision":"block","reason":"..."}` und exit 2. Fail-Mode ist **konfigurierbar** ueber `CCSC_HOOK_FAILMODE` (`open` = Default lokal, `closed` = Default Remote/Multi-Maschine). Bei `closed` blockt der Hook bis DB antwortet — sicherheits-bewusster, aber schaedlich bei DB-Ausfall.
  - **Fail-Open-Logging mit lokalem Fallback**: Jede Fail-Open-Entscheidung wird zuerst in `~/.claude/ccsc-failopen.log` (append-only, eine Zeile JSON pro Event mit `ts/sid/tool/path/reason`) geschrieben. Wenn der primaere `INSERT INTO coord.activities (tool='hook_failopen', ...)` zur DB nicht erreichbar ist, bleibt der Eintrag in der Lokal-Datei. Sobald die DB wieder antwortet, drained der Worker-Watchdog die Lokal-Datei in die DB (`tool='hook_failopen_late'`, `args_hash` enthaelt Original-Zeitstempel). So gehen keine Konflikt-Events verloren auch wenn DB voellig down ist.
  - **Circuit-Breaker**: Nach 10 aufeinanderfolgenden Fail-Open-Events innerhalb 30 s schaltet der Hook auf **`closed`** um (sperrt Tools), schreibt eine Markdown-Warnung in `~/.claude/ccsc-degraded` (Bridge liest beim naechsten Wakeup) und schickt ueber den naechsten erfolgreichen Bridge-Push eine `notifications/claude/channel`-Warnung. Reset nach 60 s ohne Fail-Open.
- **PostToolUse** — async (Background-Job), schreibt eine Row in `coord.activities` via psql.
- **Stop** — Bridge sieht Stop nicht direkt; der Hook setzt `coord.sessions.status='ended', ended_at=now()`.

Entfernt: `SessionStart`, `UserPromptSubmit`, `SessionEnd`, `Notification`. SessionStart wird durch Bridge-Init ersetzt, UserPromptSubmit durch den JSONL-Tail-Watcher (Worker), SessionEnd durch Stop-Hook + Worker-Watchdog (toter PID → ended).

### 2.4 Worker (.NET)

Drei Endpunkte / Jobs:

- `GET /health` — Postgres-Ping, fuer NSSM-Restart-Logik.
- `GET /dashboard` — statisches HTML, JS pollt `coord.sessions` ueber kleine Read-API (oder direkter Browser-PG via PostgREST — Phase 2).
- **JSONL-Tail-Watcher** — periodischer Loop (`SELECT id, claude_session_id, jsonl_path FROM coord.sessions WHERE status='active'`), pro Eintrag `FileSystemWatcher` + Tail. Parsed `"role":"user"`-Zeilen, matched Praefixe `/coord-rename `, `/coord-priority ` etc. und schreibt entsprechende Updates. Generisches Command-Dispatch-Pattern.
- **Watchdog** — alle 30 s `Process.GetProcessById(pid)` fuer aktive Sessions; tot → `status='ended'`.

Keine SSE, kein Channel-Registry, kein Token-Store mehr.

### 2.5 Schema, Trigger, Bridge-Rolle

Siehe Abschnitt 4.

### 2.6 NOTIFY-Channels

Siehe Abschnitt 5.

---

## 3. Datenfluesse

### 3.1 Inject-Flow

1. Sitzung A ruft MCP-Tool `coord_inject(target='B', kind='nudge', text='...')`.
2. Bridge A `INSERT INTO coord.injections (...)` als Rolle `ccsc_bridge`.
3. Trigger `trg_injections_notify` feuert `pg_notify('c_i_<short_B>', new.id::text)`.
4. Bridge B (LISTEN-Loop) bekommt das Payload.
5. Bridge B ruft `SELECT * FROM coord.ccsc_claim_batch($short_B, 32)` — atomar `FOR UPDATE SKIP LOCKED` ueber alle pending Rows, set `delivered_at=now()`.
6. Bridge B sendet `notifications/claude/channel` an claude.exe B.
7. claude.exe rendert die Nachricht im Chat.

### 3.2 Hook-Flow (PreToolUse-Conflict)

1. claude.exe will `Edit /path/foo.cs`.
2. PreToolUse-Hook ruft `psql -c "SELECT * FROM coord.ccsc_check_conflict(...)"`.
3. Function prueft `coord.activities` der letzten N Sekunden auf gleiche Datei in anderer Sitzung.
4. Bei Konflikt: Hook gibt `{"decision":"block","reason":"Konflikt mit Sitzung 'foo'"}` auf stdout, exit 2 — claude.exe blockt.
5. PostToolUse-Hook (nach erfolgreichem Tool) inserted Row in `coord.activities`. Trigger feuert optional `pg_notify('c_h_<short_other>', activity_id)` an interessierte Bridges (z.B. fuer Live-Dashboard-Push, optional).

### 3.3 Rename-Flow (Race-frei)

1. User tippt `/coord-rename Neuer Name` in claude.exe.
2. claude.exe schreibt die Zeile in die JSONL — beide Watcher sehen sie.
3. **Race-Resolution**: Beide Watcher schreiben den UPDATE als `UPDATE coord.sessions SET display_name=$1, last_seen_at=now() WHERE short_id=$2 AND (display_name IS DISTINCT FROM $1)`. Der zweite UPDATE ist No-Op (kein Trigger, kein Event-Spam). Idempotent per Definition.
4. Wenn zwei parallele `/coord-rename`-Zeilen schnell hintereinander kommen, gewinnt zeitlich der spaetere — beide Watcher konvergieren weil sie aus derselben JSONL lesen und denselben Endwert sehen.
5. **Watcher-Hierarchie**: Worker ist Primary (laeuft auch wenn die Sitzung selbst tot ist und JSONL nur historisch geupdatet wird). Bridge-Filewatch ist Fallback fuer Live-Sessions wenn der Worker-Service down ist. Wer den UPDATE schreibt ist egal — End-State ist gleich.

Keine echte Race-Condition, weil beide Watcher dieselbe Quelle lesen und dieselbe Operation (idempotent) machen. Klassischer "Last-Write-Wins"-Konvergenz-Pfad.

---

## 4. Schema-Definition

```sql
CREATE SCHEMA coord;

-- Zentrale Type-Definition: einmalig, ueberall wiederverwendet (DRY-Constraint).
CREATE DOMAIN coord.short_id AS varchar(8)
  CHECK (VALUE ~ '^[0-9a-f]{8}$');

CREATE TABLE coord.sessions (
  id                bigserial PRIMARY KEY,
  short_id          coord.short_id NOT NULL UNIQUE,
  claude_session_id uuid        NOT NULL UNIQUE,
  display_name      text        NOT NULL,
  host              text        NOT NULL,
  pid               int         NOT NULL,
  jsonl_path        text        NOT NULL,
  cwd               text        NOT NULL,
  status            text        NOT NULL DEFAULT 'active' CHECK (status IN ('active','ended','stale')),
  started_at        timestamptz NOT NULL DEFAULT now(),
  ended_at          timestamptz,
  last_seen_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_sessions_status ON coord.sessions(status);

CREATE TABLE coord.injections (
  id              bigserial PRIMARY KEY,
  target_short_id coord.short_id NOT NULL REFERENCES coord.sessions(short_id) ON DELETE CASCADE,
  source_short_id coord.short_id REFERENCES coord.sessions(short_id) ON DELETE SET NULL,
  kind            text        NOT NULL,
  payload         jsonb       NOT NULL CHECK (octet_length(payload::text) <= 65536),
  created_at      timestamptz NOT NULL DEFAULT now(),
  delivered_at    timestamptz,
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  retry_count     int         NOT NULL DEFAULT 0
);
-- Composite Index passt zu FIFO-Drain in ccsc_claim_batch:
CREATE INDEX ix_injections_target_undeliv
  ON coord.injections(target_short_id, created_at, id)
  WHERE delivered_at IS NULL;

CREATE TABLE coord.activities (
  id              bigserial PRIMARY KEY,
  short_id        coord.short_id NOT NULL REFERENCES coord.sessions(short_id) ON DELETE CASCADE,
  tool            text        NOT NULL,
  path            text,
  args_hash       text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_activities_path_time ON coord.activities(path, created_at DESC);

CREATE TABLE coord.hook_messages (
  id              bigserial PRIMARY KEY,
  target_short_id coord.short_id NOT NULL REFERENCES coord.sessions(short_id) ON DELETE CASCADE,
  kind            text        NOT NULL,
  payload         jsonb       NOT NULL CHECK (octet_length(payload::text) <= 65536),
  created_at      timestamptz NOT NULL DEFAULT now(),
  delivered_at    timestamptz
);
```

FKs verhindern verwaiste Injection/Activity-Eintraege auf nicht existierende Sessions. Domain `coord.short_id` zentralisiert die Format-Constraint.

### 4.1 Atomares Claim (P0 aus Council)

Bridge ruft nach jedem NOTIFY-Wakeup **`ccsc_claim_batch`** und drained alle bereits-vorhandenen Rows in einer Loop. Damit ist NOTIFY-Coalescing harmlos (mehrere INSERTs → ein Wakeup → trotzdem alle Rows geclaimed).

```sql
-- Batched Claim: holt bis zu p_max undelivered Rows fuer die Sitzung atomar.
CREATE FUNCTION coord.ccsc_claim_batch(p_short coord.short_id, p_max int DEFAULT 32)
RETURNS SETOF coord.injections AS $$
  WITH c AS (
    SELECT id FROM coord.injections
    WHERE target_short_id = p_short
      AND delivered_at IS NULL
      AND expires_at > now()
    ORDER BY created_at, id           -- FIFO, matched ix_injections_target_undeliv
    FOR UPDATE SKIP LOCKED
    LIMIT p_max
  )
  UPDATE coord.injections i
     SET delivered_at = now()
   FROM c
   WHERE i.id = c.id
   RETURNING i.*;
$$ LANGUAGE sql;
```

`FOR UPDATE SKIP LOCKED` garantiert, dass zwei parallele Bridges (z.B. Crash-Reconnect-Race) niemals dieselbe Row claimen — der UPDATE im selben Statement schliesst den Race endgueltig. Bridge muss bei Fehler (z.B. Push an claude.exe fehlgeschlagen) einen Compensating-`UPDATE coord.injections SET delivered_at=NULL, retry_count=retry_count+1 WHERE id=$1 AND retry_count<3` ausfuehren — sonst geht die Nachricht still verloren.

### 4.1.1 Conflict-Check (PreToolUse)

```sql
-- Liefert blockierende Konflikt-Sitzung (NULL = kein Konflikt). Window 30s.
CREATE FUNCTION coord.ccsc_check_conflict(p_short coord.short_id, p_tool text, p_path text)
RETURNS TABLE(conflict_session_short coord.short_id, conflict_display text, last_touch timestamptz) AS $$
  SELECT a.short_id, s.display_name, a.created_at
    FROM coord.activities a
    JOIN coord.sessions s ON s.short_id = a.short_id
   WHERE a.path = p_path
     AND a.short_id <> p_short
     AND a.tool IN ('Edit','Write','MultiEdit')
     AND a.created_at > now() - interval '30 seconds'
   ORDER BY a.created_at DESC
   LIMIT 1;
$$ LANGUAGE sql STABLE;
```

### 4.2 Trigger

```sql
CREATE FUNCTION coord.trg_inj_notify() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify('c_i_' || NEW.target_short_id, NEW.id::text);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_injections_notify AFTER INSERT ON coord.injections
  FOR EACH ROW EXECUTE FUNCTION coord.trg_inj_notify();
```

Analog `trg_hook_notify` auf `coord.hook_messages` → Channel `c_h_<short>`.

### 4.3 Rollen (minimal, getrennt)

Drei dedizierte Rollen statt einer geteilten — verhindert dass ein abgestuerztes Hook-Skript versehentlich Bridge-Operationen ausfuehren kann.

```sql
-- Bridge: Push-Pfad. Darf claimen, schreiben, lesen.
CREATE ROLE ccsc_bridge LOGIN PASSWORD :'bridge_pw';
GRANT USAGE ON SCHEMA coord TO ccsc_bridge;
GRANT SELECT, INSERT, UPDATE ON coord.sessions, coord.injections, coord.hook_messages TO ccsc_bridge;
GRANT SELECT, INSERT ON coord.activities TO ccsc_bridge;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA coord TO ccsc_bridge;
GRANT EXECUTE ON FUNCTION coord.ccsc_claim_batch(coord.short_id, int) TO ccsc_bridge;
GRANT EXECUTE ON FUNCTION coord.ccsc_register_session(uuid, text, text, int, text, text) TO ccsc_bridge;

-- Hooks: Nur Activity-Insert + Conflict-Check + eigenes Sessions-UPDATE (ended_at).
CREATE ROLE ccsc_hook LOGIN PASSWORD :'hook_pw';
GRANT USAGE ON SCHEMA coord TO ccsc_hook;
GRANT INSERT ON coord.activities TO ccsc_hook;
GRANT INSERT ON coord.injections TO ccsc_hook;  -- siehe 7.1 Privilege-Rationale unten
GRANT UPDATE (status, ended_at, last_seen_at) ON coord.sessions TO ccsc_hook;
GRANT SELECT ON coord.sessions, coord.activities TO ccsc_hook;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA coord TO ccsc_hook;
GRANT EXECUTE ON FUNCTION coord.ccsc_check_conflict(coord.short_id, text, text) TO ccsc_hook;

-- Worker: Read-only + JSONL-Tail-Updates auf display_name + Status-Watchdog.
CREATE ROLE ccsc_worker LOGIN PASSWORD :'worker_pw';
GRANT USAGE ON SCHEMA coord TO ccsc_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA coord TO ccsc_worker;
GRANT UPDATE (display_name, status, ended_at, last_seen_at) ON coord.sessions TO ccsc_worker;
```

Credentials liegen pro Rolle in **`.pgpass`** (FS-Permissions `0600` unter `%USERPROFILE%`), NICHT in `PGPASSWORD`-Env (sichtbar fuer alle Geschwister-Prozesse). Lokal optional `scram-sha-256` mit Peer-Auth ueber `pg_hba.conf` (Service-Konto). Bei Remote-Postgres TLS Pflicht (`sslmode=verify-full`).

---

## 5. NOTIFY-Channel-Naming-Schema

Postgres-Limit ist NAMEDATALEN-1 = 63 Bytes. Schema:

- `c_i_<short_id>` — Injection-Push (5 + 8 = 13 Zeichen)
- `c_h_<short_id>` — Hook-Push (13 Zeichen)
- `c_r_<short_id>` — reserviert fuer Rename/Lifecycle (Phase 2)

`short_id` wird in der Bridge **server-seitig** vergeben, nicht aus der UUID abgeleitet — vermeidet Inter-Maschinen-Kollisionen bei UUID-Praefixen:

```sql
-- Versucht bis zu 5x eine freie short_id zu finden. Bei Erschoepfung Bridge-Fehler.
CREATE FUNCTION coord.ccsc_register_session(
  p_claude_session_id uuid, p_display text, p_host text, p_pid int,
  p_jsonl_path text, p_cwd text
) RETURNS coord.short_id AS $$
DECLARE v_short coord.short_id; v_try int := 0;
BEGIN
  LOOP
    v_short := lower(encode(gen_random_bytes(4), 'hex'));
    BEGIN
      INSERT INTO coord.sessions(short_id, claude_session_id, display_name, host, pid, jsonl_path, cwd)
      VALUES (v_short, p_claude_session_id, p_display, p_host, p_pid, p_jsonl_path, p_cwd)
      ON CONFLICT (claude_session_id)
        DO UPDATE SET display_name = EXCLUDED.display_name,
                      host = EXCLUDED.host, pid = EXCLUDED.pid,
                      jsonl_path = EXCLUDED.jsonl_path, cwd = EXCLUDED.cwd,
                      status = 'active', last_seen_at = now()
      RETURNING short_id INTO v_short;
      RETURN v_short;
    EXCEPTION WHEN unique_violation THEN
      v_try := v_try + 1;
      IF v_try > 5 THEN RAISE EXCEPTION 'short_id exhausted'; END IF;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

Bei 8 Hex-Zeichen (4.3 Mrd Werte) und realistischen <50 gleichzeitigen aktiven Sitzungen ist die Geburtstags-Paradox-Kollisions-Wahrscheinlichkeit verschwindend klein. Bei mehr als 10k Sitzungen (Phase 2) auf 12 Hex erweitern — Channel-Namen bleiben im 63-Byte-Limit (`c_i_<12hex>` = 16 Zeichen).

---

## 6. Failure-Modi

| Modus | Erkennung | Reaktion |
|---|---|---|
| **Bridge-Disconnect** | Postgres-FATAL oder TCP-Reset | Reconnect-Loop mit Exponential-Backoff (1s, 2s, 4s, max 30s), re-LISTEN, dann `SELECT ... WHERE delivered_at IS NULL` einmalig nachholen. NOTIFY-Coalescing → wir verlassen uns nie auf NOTIFY-Anzahl. |
| **Postgres-Restart** | wie oben | Gleicher Pfad. Bridge bleibt am Leben, claude.exe sieht nur kurze Stille. |
| **Race: zwei Bridges hoeren denselben Channel** | (sollte nicht, aber Crash-Reconnect-Race moeglich) | `ccsc_claim_batch` mit `FOR UPDATE SKIP LOCKED` macht das atomar — nur eine Bridge bekommt die Rows. |
| **NOTIFY-Coalescing** | Mehrere INSERTs in einer TX → ein NOTIFY | Bridge selektiert immer alle undelivered Rows, nicht eine pro NOTIFY. |
| **Async-Notification-Queue voll** | `pg_notification_queue_usage() > 0.5` im Worker-Health-Check | Warnung im Dashboard. Bridges drosseln Inserts (Burst-Limit pro Sitzung). |
| **Bridge-Crash (claude.exe lebt)** | Worker-Watchdog: `Process.HasExited == false` aber DB-Connection weg | Sitzung bleibt `active`; Bridge-Restart erfolgt durch claude.exe-MCP-Auto-Reconnect. |
| **claude.exe-Crash (Bridge lebt)** | Bridge stdio-pipe EOF | Bridge setzt `status='ended', ended_at=now()` und beendet sich. |
| **PreToolUse-Hook DB-Hang** | psql-Timeout > 80 ms | Hook returnt `decision=allow` (fail-open) und loggt einen Eintrag in `coord.activities` mit `tool='hook_timeout'`. |
| **JSONL-Watcher-Lag** | Tail-Watcher Lese-Backlog > 5 s | Worker re-scans alle aktiven JSONLs vom letzten Offset. Bridge-Filewatch wirkt als zweiter Pfad. |
| **Reconnect-Storm** | viele Bridges reconnecten parallel nach PG-Restart | Backoff hat Jitter (`base * (0.5 + rand())`). Worker drosselt nicht — Postgres haelt es aus. |
| **Channel-Name-Kollision** | UNIQUE-Constraint auf `short_id` schlaegt fehl | `ccsc_register_session` retried bis zu 5x im SP, dann Bridge-Init-Fehler. |
| **Partieller DB-Ausfall (Read OK, Write blockt)** | Hook-Insert `coord.activities` schlaegt nach 80ms fehl, Read im Conflict-Check geht | Hook geht in fail-open (geloggt), aber Bridge kann ggf. nicht mehr in `coord.injections` schreiben → Cross-Session-Inject schlaegt fehl mit klarer MCP-Error-Message. |
| **Fail-Open-Storm** | DB komplett down, alle Hooks fail-open | Dashboard zeigt rote `hook_failopen`-Counter; Watchdog setzt nach 60s **alle** Sessions auf `degraded`-Flag (Phase 2). Phase 1: rote Warnung im `/health`. |
| **JSONB-Payload zu gross** | CHECK-Constraint feuert (>64 KiB) | Bridge wirft MCP-Tool-Error an Caller-Sitzung. Schutz gegen WAL-Bloat + DoS. |
| **Bridge unter falscher Rolle** | `ccsc_hook` versucht `INSERT coord.injections` ohne Erlaubnis | Postgres lehnt mit `42501` ab — explizite Rollen-Isolierung verhindert Privilege-Confusion. |

### 6.1 Recovery nach DB-Ausfall

Bei totalem DB-Ausfall und Wiederanlauf:

1. **Bridge-Reconnect**: Exponential-Backoff (siehe oben). Sobald connect klappt → `SELECT * FROM coord.ccsc_claim_batch($short, 100)` drained alles was waehrend des Ausfalls aufgelaufen ist.
2. **Worker-Watchdog**: prueft `pg_stat_activity` + `coord.sessions WHERE status='active'`. Tote PIDs werden auf `status='ended'` gesetzt.
3. **Lokale Fail-Open-Logs nachholen**: Worker liest `~/.claude/ccsc-failopen.log` jeder bekannten Sitzung (Pfad aus `coord.sessions.cwd`), parsed Eintraege mit `delivered_at IS NULL`, INSERTs sie als `tool='hook_failopen_late'`, markiert lokale Zeilen mit `"flushed_at": <ts>`. Reparatur-Reihenfolge: gestoppte Sessions zuerst (deren Logs werden sonst nie geleert).
4. **Konsistenz-Check**: `SELECT count(*) FROM coord.injections WHERE delivered_at IS NULL AND created_at < now() - interval '5 minutes'` — Liefert pending Eintraege die zu lange unfertig sind. Dashboard zeigt sie als "stuck". Operator-Entscheidung: re-process (`UPDATE delivered_at=NULL`) oder als expired markieren.
5. **Optional Schema-Healcheck** beim Worker-Start: `SELECT relname FROM pg_class WHERE relname IN (...)` und im Mismatch-Fall `/health` rot — verhindert dass alte Migration-Stand schweigend weiter laeuft.

Es gibt **keine** Transaktions-Logs ausserhalb der DB selbst — die Konsistenz-Garantie ist "eventually consistent" mit Worker als Reconciler. Akzeptiert weil alle Operationen idempotent sind (UPDATE...WHERE...DISTINCT FROM, INSERT mit ON CONFLICT).

---

## 7. Sicherheits-Modell

- **Drei Rollen** (`ccsc_bridge`, `ccsc_hook`, `ccsc_worker`) — siehe 4.3. Keine teilt sich Berechtigungen mit den anderen ueber das Noetigste hinaus.
- **Credentials**: `.pgpass` mit `0600`-Permissions, nicht `PGPASSWORD`-Env. Lokal optional Peer-Auth oder `scram-sha-256` ueber `pg_hba.conf`.
- **Token-Management entfaellt** — die alte Welt brauchte Bearer-Tokens fuer den HTTP-Push-Pfad. Mit DB-Push gibt es keinen Push-Pfad mehr ausserhalb Postgres. claude.exe akzeptiert die Bridge per stdio (vertrauenswuerdig per OS-User).
- **Postgres-TLS**: bei Remote-DB Pflicht (`sslmode=verify-full` mit CA-Bundle). Lokal optional.
- **Audit**: `coord.activities` ist append-only fuer alle Sitzungen, Forensik via SQL. Retention 90 Tage (Worker-Cron loescht aelter).
- **Single-User-Workstation-Annahme**: derselbe Windows-User betreibt alle Sessions auf der Maschine; lokale Prozess-Isolation via Windows-ACL reicht. Bei Multi-User-Host (Citrix, Terminal-Server) muss Row-Level-Security in Phase 2 zwingend dazukommen.
- **Lokaler Angriffsvektor (Malware/Phishing)**: nicht im Threat-Model von Phase 1. cc-yolo wird mit `--dangerously-skip-permissions` aufgerufen — das ist die deutlich groessere Angriffsflaeche und liegt ausserhalb dieser Spec.
- **Row-Level-Security**: NICHT in Phase 1 — alle Bridges sehen alles. Phase 2 mit MCP-Proxy zwingend (siehe Out-of-Scope).
- **GRANT-Audit**: Quartal-Review der drei Rollen-GRANTs. SQL-Skript `scripts/audit-grants.sql` listet `pg_role_member` und `information_schema.role_table_grants` fuer das `coord`-Schema und vergleicht gegen Soll-Liste in `migrations/V001`. Abweichungen → Worker-Health rot.

### 7.1 Hook-INSERT-Privilege Rationale + Mitigation

`ccsc_hook` darf in `coord.injections` schreiben — das ist die einzige nicht-triviale Privilegie der Hook-Rolle. Begruendung und Schutzmechanismen:

- **Warum unvermeidbar in Phase 1**: Slash-Commands wie `/coord-inject` werden vom Worker-Tail-Watcher aus der JSONL erkannt, aber Hook-Pfade brauchen denselben Schreib-Pfad wenn ein PreToolUse-Hook (z.B. bei `bash`-Aufruf eines Konflikt-Tools) eine Inject an die andere Sitzung auslosen muss. Ein 4. Helfer-Service waere die saubere Alternative, kostet aber einen weiteren NSSM-Service mit eigener Credentials-Rotation.
- **Eingabe-Validierung**: Alle Hook-Inserts gehen ueber eine SQL-Function `coord.ccsc_emit_injection(p_source, p_target, p_kind, p_payload)` (statt direkten `INSERT`). Die Function prueft: `p_kind IN ('nudge','warn','info')`, `p_source` existiert und gehoert dem aufrufenden OS-User (via `current_setting('coord.session_id')` aus dem Hook-Kontext), `p_payload` ≤ 32 KiB. Die Hook-Rolle bekommt `EXECUTE` auf diese Function, aber **kein direktes INSERT** — der `GRANT INSERT` oben ist nur Fallback fuer Worker-Inserts.
- **Rate-Limit**: Function zaehlt pro source `count(*) FROM coord.injections WHERE source_short_id=$1 AND created_at > now() - interval '10 seconds'`. Bei > 20 → Exception. Verhindert dass ein abgestuerzter Hook in einer Endlosschleife die DB flutet.
- **Audit-Trail**: Jeder Hook-Insert schreibt zusaetzlich Row in `coord.activities` mit `tool='hook_inject_emit'`. Operator sieht im Dashboard pro Sitzung wie oft Hooks Cross-Session-Injects ausloesen — ungewoehnliche Spikes sind sichtbar.
- **Credentials-Rotation**: `.pgpass`-Datei wird alle 90 Tage rotiert ueber `scripts/rotate-pgpass.ps1` (Worker-Cron). Bei Hook-Crash oder OS-Wechsel wird das Passwort als kompromittiert behandelt und sofort rotiert.

Damit ist die Privilegie eingehegt: Function als kontrollierter Pfad, Rate-Limit gegen Flooding, Audit-Trail gegen heimliche Nutzung, Credentials-Rotation gegen Diebstahl.

---

## 7a. Pingpong (Reply-Roundtrip)

Ein Inject kann `expects_reply=true` setzen + optionalen `reply_to_injection_id`. Empfänger-Bridge zeigt einen entsprechenden Hinweis im rendered Channel-Frame ("antworte zurück an <source>"). Empfänger nutzt MCP-Tool `coord_reply <injection_id> <text>` oder Slash-Command, der einen neuen Inject anlegt mit `reply_to_injection_id=<original>`, `target_session_id=<original-source>`. Sender-Bridge sieht den Reply via ihres LISTEN-Channels. Use-Case: Head-Session-Konzept — eine zentrale Session kann andere fragen und auf Antworten warten.

Schema-Erweiterung auf `coord.injections`:
- `expects_reply BOOLEAN NOT NULL DEFAULT FALSE`
- `reply_to_injection_id BIGINT REFERENCES coord.injections(id)`

Bridge-MCP-Tool `coord_reply(injection_id, text)` legt einen neuen Inject an mit `source_short_id=<own>`, `target_short_id=<source of original inject>`, `reply_to_injection_id=<original>`. Render-Hint in Empfänger-Notification: wenn `expects_reply=true`, hängt die Bridge im rendered Frame die Zeile "Antworte mit `coord_reply ${injection_id} \"...\"`" an, sodass die Claude-Sitzung die Mechanik im Kontext sieht.

---

## 8. Out-of-Scope (Phase 2)

- **MCP-Proxy via Postgres** — gemeinsamer Daemon-Pool fuer hindsight/socraticode/gitnexus/shodh, NOTIFY-basiertes Request-Response. Setzt RLS, DLQ-Tabelle, Priorisierung voraus.
- **PostgREST/Hasura-direkt-Dashboard** — Browser haengt direkt auf DB statt Worker-HTML.
- **Remote-Maschine-Sessions** — derselbe Postgres, andere Maschine. Setup-mechanik im naechsten Sprint.
- **PgBouncer-Setup** — falls jemals noetig: nur Session-Pooling, kein Transaction-Pooling (Council P0).
- **Heartbeat-NOTIFY** — Bridge sendet alle 30 s ein `pg_notify('c_h_<sid>', 'hb')` als Liveness-Beweis. Heute nicht noetig, Watchdog via Process-Existenz reicht.

---

**Naechster Schritt:** Council-Review dieser Spec, dann Umsetzungs-Plan.
