# Spec — Inter-Session-Push fuer cc-sessions-coord (Channels, v2.1.80+)

Status: DRAFT v4 (2026-05-13, nach Council-Runde 3 — Ziel: Konsens)

Council-Verlauf:
- R1: 1 REWRITE, 3 NEEDS-REVISION.
- R2: 3 NEEDS-REVISION, 1 PASS.
- R3: 2 NEEDS-REVISION, 2 PASS.

R3-Kritik gezielt adressiert in v4:
- **Grok**: seen.json atomic-write + Korruptions-Recovery + Pull-Race + Token-Rotation/Eviction-Timing klargestellt.
- **Codex**: Lease/Connection-Bindung jetzt **server-issued** (`connection_id` von Worker generiert, nicht `Date.now()` vom Client). Behebt Pingpong-Manipulation.
- **GPT-5.5-Nit**: `delivered_at`-Semantik klarer dokumentiert.
- **Mistral**: schon PASS, kein Aenderungsbedarf.

## 1. Ziel & Nicht-Ziel

Push einer Inter-Session-Nachricht vom Worker zu einer laufenden Claude-Code-Sitzung **in ≤ 2 sec**, ohne Polling, ohne Hook-Spam, ohne Userinput-Zwang. Pull ergaenzt, ersetzt nicht. Localhost-only. 1:1.

**Bewusste Limitation**: ACK bedeutet "Bridge hat MCP-Notification erfolgreich an Claude-Host abgesendet". Es gibt KEINE Bestaetigung dass die UI sie tatsaechlich rendert oder der User sie liest — das MCP-Protokoll bietet keinen solchen Round-Trip. `delivered_at` bedeutet daher **"bridge-acked, MCP-Send erfolgreich"**, nicht "UI gerendert".

## 2. Bestaetigte Constraints

1. `mcpServers.env` ist Replacement, nicht Merge.
2. Session-UUID intern, kein Wrapper-Wissen vor Start.
3. MCP-Bridge ist DIREKTER Kind-Prozess von `claude.exe`. Tree-Walking bis 3 Ebenen up als Sicherheitsnetz.
4. Hook-Tree ist tief, schon geloest durch `Get-ClaudeCodePid`.
5. Service als `NT AUTHORITY\LocalService`, alle Pfade aus `C:\ProgramData\CcSessionsCoord\`.

## 3. Architektur

```
+-----------------+   SSE (event:hello → event:inject ...)   +------------------+
| cc-sessions-    |  S→B (event:hello): {connection_id, ...} |  Channel-Bridge  |
| coord (Worker)  | ──────────────────────────────────────►  |  (stdio MCP)     |
| .NET 8, :7733   |  S→B (event:inject, id:event_seq)        |                  |
|                 |  B→S: POST /channel/ack                  |                  |
|                 |        { injection_id, connection_id }   |                  |
+-----------------+ ◄──────────────────────────────────────  +------------------+
        ▲                                                            │
        │ POST /coord/injections (Sitzung A)                         │ sendNotification(
        │                                                            │   "notifications/
        │                                                            │    claude/channel")
        │                                                            ▼
+-----------------+                                          +------------------+
| Session A       |                                          |  Session B       |
| (Claude Code)   |                                          |  (Claude Code)   |
+-----------------+                                          +------------------+
```

### 3.1 Worker — Connection-State (server-issued)

**In-Memory `ConcurrentDictionary<string SessionId, ActiveConnection>`** mit:
- `connection_id` (UUID, vom Worker generiert beim Connect — Source of Truth fuer Bindung)
- `connection_started_at_utc`
- `token_hash` (SHA256 des verifizierten Tokens)
- `bridge_epoch_advertised` (vom Bridge mitgesendet, nur fuer Logging/Tracing — NICHT autoritativ)
- `last_event_seq` (hoechster gesendeter `event_seq`)
- `http_response` (Stream-Referenz fuer Server-Push)

Bei `INSERT INTO coord.injections`: falls aktive Connection fuer `target_session_id` existiert → push frame.

**Worker-Restart**: Registry leer. Reconnect-Bridges schicken `Last-Event-ID: <event_seq>` Header. Worker replayed alle Injections mit `event_seq > Last-Event-ID AND target_session_id = X AND expires_at > now() AND delivered_at IS NULL AND cancelled_at IS NULL ORDER BY event_seq ASC`.

**DB-Migration:**
```sql
ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS event_seq BIGINT GENERATED ALWAYS AS IDENTITY;
ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS last_pushed_at TIMESTAMPTZ NULL;
ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS push_connection_id UUID NULL;
ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS delivered_via TEXT NULL;
CREATE INDEX IF NOT EXISTS injections_event_seq_idx ON coord.injections(event_seq);
CREATE INDEX IF NOT EXISTS injections_pending_target_idx
    ON coord.injections(target_session_id, expires_at)
    WHERE delivered_at IS NULL AND cancelled_at IS NULL;
ALTER TABLE coord.sessions ADD COLUMN IF NOT EXISTS pid_start_time BIGINT NULL;
```
- `event_seq` ist IDENTITY → Postgres befuellt automatisch bei INSERT. Existierende Rows bekommen NULL bis zum naechsten Update; das ist OK weil sie bereits delivered/expired sind (Migration-Zeitpunkt im Cleanup-Fenster).

### 3.2 Bridge — Start-Sequenz

1. **Token lesen**: `C:\ProgramData\CcSessionsCoord\channel-token.txt`.
   - Fehlt/leer → stderr `[ccsc-bridge] missing-token at <iso>` (alle 60s erneut, throttled). Bridge bleibt am Leben als reiner stdio-MCP (kein Push, Pull-Pfad bleibt aktiv).
   - Bridge re-checkt Datei alle 30s.
2. **Claude-PID resolven**: `process.ppid` → `wmic process where ProcessId=<pid> get Name /VALUE` → wenn nicht `claude.exe`, walke parent bis zu 3 Ebenen up. Nach 3 erfolglos → stderr `[ccsc-bridge] no-claude-in-tree`, terminate.
3. **Claude-PID-Start-Time**: `wmic process where ProcessId=<claude-pid> get CreationDate /VALUE` → konvertiere CIM-Datetime zu Unix-Millisekunden.
4. **Session-ID resolven**: `GET /coord/sessions/by-pid?pid=<claude-pid>&pid_start_time=<unix_ms>` mit Header `X-Coord-Channel-Token`.
   - 200 → JSON `{ session_id, started_at }`.
   - 404 → Backoff `[0.5, 1, 2, 4]s`, max 10s. Danach silent poll alle 5s, throttled stderr alle 60s.
   - 401 → Token-Datei neu lesen (manuelle Rotation moeglich), backoff 5s, retry.
5. **SSE-Connect**: `GET /coord/channel/stream` mit Headers:
   - `X-Coord-Channel-Token: <token>`
   - `X-Coord-Session-Id: <session_id>`
   - `X-Coord-Bridge-Epoch: <unix_ms>` (informativ, nicht autoritativ)
   - `Last-Event-ID: <last_seen_event_seq aus seen.json oder 0>`
   - `X-Coord-Evict-Existing: 1` (Bridge bittet um Takeover; Worker entscheidet)
6. **Erstes Event muss `event: hello`** sein mit Daten `{ connection_id: "<uuid>", server_time: "<iso>" }`. Bridge speichert `connection_id` lokal, nutzt sie in jedem ACK.
7. **Event-Loop**: bei jedem `event: inject` mit `data: {json}`:
   1. Schema validieren (siehe 3.4). Bei Fehler: stderr-Log, kein ACK, kein sendNotification.
   2. Dedupe-Check: `injection_id` in `seen.json` mit `at > now-1h`? → ACK schicken (idempotent), kein sendNotification.
   3. `sendNotification("notifications/claude/channel", params)`.
   4. Bei Erfolg: persistiere `injection_id, seen_at, event_seq` in `seen.json` (atomic write — siehe 3.6.2). Feuere `POST /coord/channel/ack`.
   5. Bei Fehler beim sendNotification: KEIN ACK. Worker timed nach 7s aus, Resend.

### 3.3 PID-Start-Time — verbindliche Konvention

- Hook (PowerShell, in `db.ps1::Update-SessionHeartbeat`):
  ```powershell
  $proc = Get-Process -Id $resolvedPid -ErrorAction SilentlyContinue
  $startMs = if ($proc) {
      [DateTimeOffset]::new($proc.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
  } else { $null }
  ```
- Bridge (Node, via `wmic`):
  ```js
  // wmic Output: CreationDate=20260513143025.000000+000
  const match = output.match(/CreationDate=(\d{14})\.(\d{6})\+(\d{3,4})/);
  // → Date in UTC, .getTime() = Unix-ms
  ```
- Worker-Match mit Toleranz ±100 ms:
  ```sql
  SELECT session_id FROM coord.sessions
   WHERE pid = $1 AND pid_start_time IS NOT NULL
     AND ABS(pid_start_time - $2) < 100
   ORDER BY last_heartbeat DESC LIMIT 1;
  ```

### 3.4 MCP-Notification-Format

JSON-RPC 2.0, gesendet via `Server.notification()`:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/claude/channel",
  "params": {
    "channel": "ccsc",
    "injection_id": "<uuid>",
    "source_session_id": "<uuid>",
    "kind": "inject|alert|exec|ask",
    "priority": 0,
    "payload": "<text, kann markdown, ≤64 KB>",
    "expires_at": "<iso8601>"
  }
}
```

Bridge-Validation vor sendNotification:
- `injection_id` ↔ UUID-Regex
- `kind` ↔ Enum
- `priority` 0-9 int
- `payload` non-empty string ≤ 64 KB
- `expires_at` parseable, > now

### 3.5 Security

- Token 128-Bit GUID (`Guid.NewGuid().ToString("N")`).
- Datei `C:\ProgramData\CcSessionsCoord\channel-token.txt` (UTF-8 ohne BOM, kein trailing newline).
- ACL via `icacls`:
  ```
  icacls "<path>" /inheritance:r ^
    /grant:r "NT AUTHORITY\SYSTEM:(F)" ^
            "NT AUTHORITY\LocalService:(R)" ^
            "%COMPUTERNAME%\\<YOUR_WINDOWS_USER>:(R)"
  ```
- Token **nur Header** `X-Coord-Channel-Token`. Query-Param → 400.
- `CryptographicOperations.FixedTimeEquals` gegen SHA256.
- **Rate-Limit**: max 10 Connect-Attempts pro Minute pro `SHA256(token)`, via `IMemoryCache` Sliding-Window. Bei Ueberschreitung 429.
- Listener `127.0.0.1:7733`.
- TLS not required, documented.
- `/coord/sessions/by-pid` benoetigt `X-Coord-Channel-Token` (gleicher Token wie SSE).

#### 3.5.1 Token-Rotation

Endpoint: `POST /coord/admin/rotate-channel-token` (Admin-Token-geschuetzt).

Sequenz:
1. Worker generiert neues Token.
2. Worker schreibt Datei atomic (`tmp + Move-Item -Force`).
3. Worker iteriert alle aktiven Connections: schickt `event: token-rotated {at: <iso>}` → `event: bye {reason:"rotated"}` → schliesst Stream.
4. Worker leert seinen `connection_id`-Registry-Eintrag fuer alle.

Bridge-Reaktion auf `event: token-rotated`:
1. Setze internen Flag `tokenRotationInProgress = true`.
2. Empfange auch `event: bye`, schliesse SSE-Stream.
3. **Vorrang vor Eviction-Cool-Down**: bei `tokenRotationInProgress` ist die Connection vom Worker geschlossen, also kein "alter Connection-Konflikt" — neue Connection bekommt sofort `connection_id`.
4. Warte 500-1500 ms Jitter (`500 + Math.random()*1000`).
5. Lese Token-Datei neu. Wenn gleicher Inhalt (NTFS-Cache): warte 1s, lese erneut, bis zu 3 Versuche.
6. Reconnect mit neuem Token.

### 3.6 Delivery — at-least-once + Idempotenz

**Wire-Format SSE** (UTF-8, line-based):

```
event: hello
data: {"connection_id":"<uuid>","server_time":"<iso>"}

event: inject
id: 17234
data: {"injection_id":"<uuid>","source_session_id":"<uuid>","kind":"inject","priority":0,"payload":"<text>","expires_at":"<iso>"}

event: ping
data: {}

event: token-rotated
data: {"at":"<iso>"}

event: evicted
data: {"reason":"takeover","by_connection_id":"<uuid>"}

event: bye
data: {"reason":"rotated|shutdown|takeover"}
```

#### 3.6.1 Delivery-Flow

1. Worker pusht event:inject, setzt in DB `last_pushed_at = now(), push_connection_id = <active_connection_id>`. Setzt **NICHT** `delivered_at`.
2. Bridge sendNotification → `POST /coord/channel/ack`:
   ```http
   POST /coord/channel/ack
   X-Coord-Channel-Token: <token>
   X-Coord-Session-Id: <session_id>
   Content-Type: application/json

   { "injection_id": "<uuid>", "connection_id": "<uuid>" }
   ```
3. Worker-Validation (server-issued auth):
   - Token-SHA-Match.
   - Session-Header == Active-Connection-Session.
   - `connection_id` im Body == aktuelles `connection_id` der Connection (server-issued, NICHT manipulierbar).
   - injection_id existiert, `target_session_id == session_id`, `cancelled_at IS NULL`.
   - **`push_connection_id` in DB == `connection_id` im ACK** (verhindert dass eine alte Bridge fuer eine neue Connection ACKt).
4. Bei Validation OK: `UPDATE coord.injections SET delivered_at = now(), delivered_via = 'channel' WHERE id = $1 AND delivered_at IS NULL`. Bei 0 Rows: idempotent 200 OK.
5. Bei Validation Fehler: 403 mit `{"error":"connection-mismatch"}` oder 401.

#### 3.6.2 seen.json — Persistenz & Korruption

- Pfad: `C:\Users\<user>\.claude\coord-bridge-state\<session_id>.seen.json`.
- Schreibstrategie:
  1. Bridge serialisiert JSON.
  2. Schreibt nach `<file>.tmp` (`fs.writeFileSync` ohne fsync — Node hat das nicht out-of-the-box; akzeptiert).
  3. `fs.renameSync(<file>.tmp, <file>)` (atomic auf NTFS).
- Lesestrategie beim Start:
  1. `fs.readFileSync(<file>)` → JSON.parse. Bei Exception (Korruption, leer): log warning, treat as empty `{seen:[], last_event_seq:0}`. KEINE Bridge-Abbruch.
  2. TTL-Cleanup: entferne Eintraege mit `at < now-1h`.
- Format:
  ```json
  { "seen": [{"id":"<uuid>","at":"<iso>","event_seq":17234}], "last_event_seq": 17234 }
  ```
- Max 500 Eintraege. Bei Ueberlauf: oldest entry FIFO raus.
- Last-Event-ID-Quelle beim Reconnect: `max(event_seq aller seen-Eintraege)`. Wenn seen leer → `0`.

#### 3.6.3 Pull-Race-Lock

Damit Pull-Hook und Worker-Watchdog nicht doppelt zustellen:

- Pull-Hook (existierend) liest Injections mit:
  ```sql
  SELECT * FROM coord.injections
   WHERE target_session_id = $1
     AND delivered_at IS NULL
     AND cancelled_at IS NULL
     AND expires_at > now()
     AND (last_pushed_at IS NULL OR last_pushed_at < now() - INTERVAL '8 seconds')
   ORDER BY priority DESC, id ASC
   FOR UPDATE SKIP LOCKED;
  ```
- Das "8-Sekunden-Schweben"-Fenster ueberlappt mit Watchdog-Resend (7s). Bei Worker-Watchdog-Resend: nach Resend wird `last_pushed_at` aktualisiert → neuer 8s-Lock. Pull skippt.
- Wenn ACK kommt waehrend Pull bereits zugestellt hat: ACK-UPDATE `WHERE delivered_at IS NULL` matched 0 Rows → idempotent 200 OK.
- Wenn Pull-Hook zustellt (setzt `delivered_at`) und parallel Worker-Resend kommt: zweiter Resend findet via `WHERE delivered_at IS NULL` → 0 rows → nicht erneut pushen.

#### 3.6.4 Watchdog

- Worker: pro pushed Injection ein `Task.Delay(7s)`. Nach Ablauf prueft DB: `delivered_at IS NULL AND last_pushed_at = <my_push_ts>`?
- Wenn ja UND Connection lebt UND `push_connection_id` immer noch = aktive `connection_id` → einmaliger Resend.
- Sonst: Pull-Pfad uebernimmt.

### 3.7 Stale-Bridge / Eviction — server-autoritaer

Worker speichert pro `session_id`:
- `last_eviction_at` (UTC, in-memory)
- `eviction_lock_until` (`last_eviction_at + 3s`)

Connect-Logik (atomar pro session_id-Lock):
1. Bestehende Connection vorhanden?
   - **Nein** → akzeptiere, generiere `connection_id`, sende `event: hello`. fertig.
   - **Ja** und `now < eviction_lock_until` → 409 mit `{retry_after_ms: <ms_bis_lock_ende>}`. Bridge wartet, retry.
   - **Ja** und `now >= eviction_lock_until`:
     - Wenn Request-Header `X-Coord-Evict-Existing: 1` (Bridge-Default) → schicke `event: evicted` an alte, schliesse, akzeptiere neue, generiere neue `connection_id`, set `last_eviction_at=now`. fertig.
     - Wenn Request **ohne** Header → 409 mit `{existing_started_at, since_seconds}`. (Wird in der Praxis nie passieren; Bridge-Code sendet immer Header.)
2. Bei Token-Rotation (3.5.1) schliesst Worker alle Connections selbst — `last_eviction_at` wird auf `now()` gesetzt, aber der Cool-Down gilt nicht fuer den Worker-initiierten Reconnect-Storm (Special-Flag `bypass_cool_down_after_rotation`, 5s gueltig).

### 3.8 Heartbeat / Liveness

- Worker `event: ping` alle 5s pro Connection.
- Bridge: 12s ohne irgendwelche Bytes → Reconnect.
- Worker erkennt tote Connection via `HttpResponse.WriteAsync()` exception → Registry-Cleanup, `last_eviction_at = now` (verhindert sofortige Re-Use bei Reconnect-Storm).

### 3.9 Service-Account

- NSSM-Service `"DT - cc-sessions-coord"` als `NT AUTHORITY\LocalService`.
- Pfade aus `C:\ProgramData\CcSessionsCoord\`.
- `install-service.ps1`:
  - NSSM `ObjectName=LocalService`, kein Passwort.
  - `sc.exe sdset` Patch fuer Service-ACL `(A;;LCRPWPDTRC;;;NS)` (Authenticated Users → Start/Stop).
  - `icacls` auf ProgramData-Verzeichnis fuer LocalService + User.

## 4. Akzeptanzkriterien

`scripts/smoke-channel-push.ps1` testet:

| # | Test | Erwartung |
|---|------|-----------|
| A1 | `injection-send <B> "ping"` | B zeigt `<channel>...</channel>` ≤ 2s |
| A2 | Bridge-Kill | Disconnect ≤ 12s, Pull uebernimmt |
| A3 | Worker-Restart | Bridge reconnect ≤ 5s + Replay |
| A4 | Falsches Token | 401, kein Spin, throttled stderr |
| A5 | Race Insert vor Connect | Replay-from-Last-Event-ID liefert nach |
| A6 | 10× Ping-Pong | alle 10 zugestellt, kein Duplikat |
| A7 | Heartbeat 8s verzoegert | Bridge silent-poll, dann connect |
| A8 | Stale-Bridge mit Header | Eviction nach Cool-Down |
| A9 | Token-Rotation | event:token-rotated + reconnect, neue connection_id |
| A10 | PID-Reuse | by-pid 404 (start_time mismatch) |
| A11 | ACK-Spoof: zweite Bridge versucht ACK mit falscher connection_id | 403, delivered_at bleibt NULL |
| A12 | Bridge-Crash zwischen Send und ACK | Watchdog, Resend, Bridge-Restart, Dedupe greift |
| A13 | seen.json korrupt | Bridge startet trotzdem, leere seen-State, Pull-Pfad live |
| A14 | Manipulierter bridge_epoch hoch | egal — server-issued connection_id ist Source of Truth |

## 5. NFR

- Latenz P50 ≤ 300 ms, P95 ≤ 1.5s.
- Reconnect-Cap 4s.
- Bridge-RSS < 100 MB.
- Bridge-Dependencies: `@modelcontextprotocol/sdk`, `eventsource`, `undici` (kommt mit SDK).
- TLS not required (localhost), documented.

## 6. Migration

Greenfield `src/CcSessionsCoord.ChannelBridge/`.

Worker:
- `src/CcSessionsCoord.Worker/Endpoints/ChannelEndpoints.cs`:
  - `GET /coord/channel/stream` (SSE)
  - `POST /coord/channel/ack`
  - `GET /coord/sessions/by-pid`
- `AdminEndpoints.cs` ergaenzt `POST /coord/admin/rotate-channel-token`.
- DB-Migration (siehe 3.1).

Hook:
- `~/.claude/scripts/session-coord/db.ps1::Update-SessionHeartbeat` schickt `pid_start_time_unix_ms`.

`~/.claude.json`:
- `mcpServers.ccsc-channel` mit `command: "node"`, `args: ["<absolute path>/dist/index.js"]`, `env: {}`.

## 7. Definition of Done

- [ ] Bridge-Code laeuft End-to-End.
- [ ] A1–A14 als pwsh-Smoke-Tests gruen.
- [ ] Worker mit Endpoints + Migration.
- [ ] NSSM-Service als LocalService.
- [ ] `~/.claude.json` MCP-Eintrag.
- [ ] Pull-Pfad regressionsfrei.
- [ ] Spec + Plan committed.

## 8. Offene Punkte (bewusst akzeptiert)

- TLS: nicht erforderlich (localhost), dokumentiert.
- Token-Rotation: manuell ueber Admin-Endpoint.
- PID-Wraparound Windows: praktisch irrelevant.
- ACK-Semantik: bestaetigt nur MCP-Send-Erfolg, nicht UI-Render.

## 9. Changelog v3 → v4

- **Lease/Connection-Bindung server-issued** (`connection_id` vom Worker generiert, nicht `Date.now()` vom Client). Codex-Showstopper geloest.
- **seen.json Korruptions-Recovery**: leere State + log statt Abbruch. Grok-Punkt.
- **Pull-Race-Lock**: 8-Sekunden-Schwebewindow via `last_pushed_at`. Grok-Punkt.
- **Token-Rotation vs. Eviction-Cool-Down**: explizit `bypass_cool_down_after_rotation`. Grok-Punkt.
- **delivered_at-Semantik**: klar dokumentiert als "Bridge MCP-Send acked", nicht "UI gerendert". GPT-5.5-Nit.
- **event:hello mit connection_id** als verpflichtendes erstes Event nach Connect.
- A13/A14 neue Akzeptanztests.
